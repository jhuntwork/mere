// Generation activation - atomic switching between profile generations
//
// Key properties:
// - Atomic switching via temp symlink + rename
// - Single symlink change (<profile_dir>/current)
// - Symlink is sole source of truth for current generation
// - Idempotent operation (cleans up stale temp symlinks)
// - GC roots updated after activation
//
// Layout:
//   /mere/profiles/<name>/
//   ├── current -> gen-N  (this is what we atomically switch)
//   ├── gen-1/
//   ├── gen-2/
//   └── ...

const std = @import("std");
const generation = @import("generation.zig");
const gcroots = @import("gcroots.zig");
const etc = @import("etc.zig");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const hash = @import("hash.zig");
const path_safety = @import("path_safety.zig");

/// Activation error set
const Std = errors.StandardErrors;
pub const ActivationError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    GenerationNotFound, // Target generation doesn't exist
    ManifestNotFound, // Generation exists but manifest is missing/unreadable
    DuplicateEtcTemplate, // Two packages provide same /etc path
};

const CURRENT_SYMLINK = "current";
const CURRENT_SYMLINK_TEMP = ".current-new";

pub const VerificationMode = enum {
    fast,
    full_store,
};

pub const SystemActivationResult = struct {
    etc_copied: usize,
    etc_skipped: usize,
    etc_differing: usize,
};

/// Switch the active generation for a profile and update its GC roots.
pub fn switchProfileGeneration(
    ctx: *mere.Context,
    profile_name: []const u8,
    gen_num: u32,
    verification: VerificationMode,
) ActivationError!void {
    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, profile_name);
    defer ctx.allocator.free(profile_dir);

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();

    try switchProfileGenerationAtPath(ctx, profile_dir, gen_num);

    const gc_roots_dir = try getGCRootsDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(gc_roots_dir);
    gcroots.updateRoots(ctx.allocator, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
        return mapGCRootError(err);
    };
}

/// Switch the active generation for the system profile and apply system activation policy.
pub fn activateSystemGeneration(
    ctx: *mere.Context,
    gen_num: u32,
    verification: VerificationMode,
) ActivationError!SystemActivationResult {
    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, "system");
    defer ctx.allocator.free(profile_dir);

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();

    const etc_dir = try getEtcDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(etc_dir);

    var etc_result = try applyEtcTemplatesForManifest(ctx, &manifest, etc_dir);
    errdefer {
        etc.rollbackCreatedFiles(ctx, &etc_result) catch {};
        etc_result.deinit();
    }

    try switchProfileGenerationAtPath(ctx, profile_dir, gen_num);

    const gc_roots_dir = try getGCRootsDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(gc_roots_dir);
    gcroots.updateRoots(ctx.allocator, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
        return mapGCRootError(err);
    };

    const result = SystemActivationResult{
        .etc_copied = etc_result.copied,
        .etc_skipped = etc_result.skipped,
        .etc_differing = etc_result.differing,
    };
    etc_result.deinit();

    return result;
}

/// Activate a specific generation atomically.
/// 1. Validate the target generation exists and has a readable manifest
/// 2. Remove any stale temp symlink (idempotent)
/// 3. Create temp symlink: .current-new -> gen-<N>
/// 4. Atomic rename: .current-new -> current
fn switchProfileGenerationAtPath(
    ctx: *mere.Context,
    profile_dir: []const u8,
    gen_num: u32,
) ActivationError!void {
    // Open profile directory for symlink operations
    var profile_dir_handle = std.fs.openDirAbsolute(profile_dir, .{}) catch {
        return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to open profile directory for activation");
    };
    defer profile_dir_handle.close();

    // Remove stale temp symlink if it exists (idempotent)
    profile_dir_handle.deleteFile(CURRENT_SYMLINK_TEMP) catch |err| {
        switch (err) {
            error.FileNotFound => {}, // OK, doesn't exist
            else => {
                return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to remove stale temp symlink");
            },
        }
    };

    // Create the symlink target (relative path within profile_dir: gen-N)
    const target = generation.formatGenerationName(ctx.allocator, gen_num) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to allocate generation name");
    };
    defer ctx.allocator.free(target);

    // Create temp symlink: .current-new -> gen-<N>
    profile_dir_handle.symLink(target, CURRENT_SYMLINK_TEMP, .{}) catch {
        return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to create temporary symlink .current-new");
    };

    // Atomic rename: .current-new -> current
    // This is the atomic operation that makes the switch visible
    std.posix.renameat(
        profile_dir_handle.fd,
        CURRENT_SYMLINK_TEMP,
        profile_dir_handle.fd,
        CURRENT_SYMLINK,
    ) catch {
        // Record diagnostic context and clean up temp symlink on failure
        const err = ctx.fail(ActivationError.FileSystem, profile_dir, "failed to atomically rename .current-new -> current");
        profile_dir_handle.deleteFile(CURRENT_SYMLINK_TEMP) catch {};
        return err;
    };
}

fn loadValidatedTargetManifest(
    ctx: *mere.Context,
    profile_dir: []const u8,
    gen_num: u32,
    verify_store: bool,
) ActivationError!generation.GenerationManifest {
    // Validate target generation exists (profile_dir/gen-N)
    const gen_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to construct generation path");
    };
    defer ctx.allocator.free(gen_path);

    // Check generation directory exists
    std.fs.accessAbsolute(gen_path, .{}) catch {
        return ctx.fail(ActivationError.GenerationNotFound, gen_path, "generation not found");
    };

    // Check manifest exists and parses (completion marker)
    const manifest_path = std.fs.path.join(ctx.allocator, &.{ gen_path, generation.MANIFEST_FILENAME }) catch {
        return ctx.fail(ActivationError.OutOfMemory, gen_path, "failed to construct manifest path");
    };
    defer ctx.allocator.free(manifest_path);

    var manifest = generation.readManifest(ctx.allocator, gen_path) catch |err| {
        const detail = switch (err) {
            generation.GenerationError.GenerationNotFound,
            generation.GenerationError.InvalidManifest,
            generation.GenerationError.ParseError,
            => "manifest.json missing or invalid",
            generation.GenerationError.NoCurrentGeneration,
            generation.GenerationError.NoPreviousGeneration,
            => "unexpected generation query error",
            generation.GenerationError.PermissionDenied => "permission denied reading manifest.json",
            generation.GenerationError.FileSystem => "failed to read manifest.json",
            generation.GenerationError.OutOfMemory => "out of memory",
            generation.GenerationError.InvalidInput => "invalid manifest path",
            generation.GenerationError.ProfilesNotFound => "profile directory missing",
        };
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ActivationError.OutOfMemory,
            generation.GenerationError.GenerationNotFound,
            generation.GenerationError.InvalidManifest,
            generation.GenerationError.ParseError,
            => ActivationError.ManifestNotFound,
            else => ActivationError.FileSystem,
        }, manifest_path, detail);
    };
    errdefer manifest.deinit();

    try validateGenerationStorePaths(ctx, profile_dir, &manifest, verify_store);
    return manifest;
}

fn applyEtcTemplatesForManifest(
    ctx: *mere.Context,
    manifest: *const generation.GenerationManifest,
    etc_dir: []const u8,
) ActivationError!etc.TemplateResult {
    return etc.processTemplates(ctx, manifest, etc_dir) catch |err| {
        const detail = switch (err) {
            etc.EtcError.DuplicateTemplate => "duplicate /etc template",
            etc.EtcError.OutOfMemory => "out of memory",
            etc.EtcError.PermissionDenied => "permission denied",
            etc.EtcError.FileSystem => "file system error",
        };
        const mapped_err = mapEtcError(err);
        if (ctx.diagnostic_context == null) {
            return ctx.fail(mapped_err, etc_dir, detail);
        }
        return mapped_err;
    };
}

fn isSystemProfile(profile_dir: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(profile_dir), "system");
}

fn verificationEnabled(mode: VerificationMode) bool {
    return switch (mode) {
        .fast => false,
        .full_store => true,
    };
}

fn getProfileDir(allocator: std.mem.Allocator, root_path: []const u8, profile_name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, "mere", "profiles", profile_name });
}

fn getGCRootsDir(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, "mere", "gc-roots" });
}

fn getEtcDir(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, "etc" });
}

fn mapEtcError(err: etc.EtcError) ActivationError {
    return switch (err) {
        etc.EtcError.DuplicateTemplate => ActivationError.DuplicateEtcTemplate,
        etc.EtcError.OutOfMemory => ActivationError.OutOfMemory,
        etc.EtcError.PermissionDenied => ActivationError.PermissionDenied,
        etc.EtcError.FileSystem => ActivationError.FileSystem,
    };
}

fn mapGCRootError(err: gcroots.GCRootsError) ActivationError {
    return switch (err) {
        gcroots.GCRootsError.OutOfMemory => ActivationError.OutOfMemory,
        gcroots.GCRootsError.PermissionDenied => ActivationError.PermissionDenied,
        gcroots.GCRootsError.InvalidInput => ActivationError.InvalidInput,
        gcroots.GCRootsError.GenerationNotFound => ActivationError.GenerationNotFound,
        else => ActivationError.FileSystem,
    };
}

fn validateGenerationStorePaths(
    ctx: *mere.Context,
    profile_dir: []const u8,
    manifest: *const generation.GenerationManifest,
    verify_store: bool,
) ActivationError!void {
    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to construct store root path");
    };
    defer ctx.allocator.free(store_root);
    const normalized_store_root = std.fs.path.resolve(ctx.allocator, &.{store_root}) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to normalize store root path");
    };
    defer ctx.allocator.free(normalized_store_root);

    const require_root_owned = isSystemProfile(profile_dir);

    for (manifest.packages.items) |pkg| {
        const normalized_store_path = std.fs.path.resolve(ctx.allocator, &.{pkg.store_path}) catch {
            return ctx.fail(ActivationError.OutOfMemory, pkg.store_path, "failed to normalize store path");
        };
        defer ctx.allocator.free(normalized_store_path);

        if (!path_safety.isWithinBoundary(normalized_store_path, normalized_store_root)) {
            return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "store path outside store root");
        }

        const stat_buf = std.posix.fstatat(std.posix.AT.FDCWD, pkg.store_path, 0) catch |err| {
            return ctx.fail(switch (err) {
                error.FileNotFound => ActivationError.FileSystem,
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, pkg.store_path, "failed to stat store path");
        };

        if ((stat_buf.mode & std.posix.S.IFMT) != std.posix.S.IFDIR) {
            return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "store path is not a directory");
        }

        if (require_root_owned) {
            if (stat_buf.uid != 0 or stat_buf.gid != 0) {
                return ctx.fail(ActivationError.PermissionDenied, pkg.store_path, "store path is not root-owned");
            }
            if ((stat_buf.mode & 0o222) != 0) {
                return ctx.fail(ActivationError.PermissionDenied, pkg.store_path, "store path is writable");
            }
        }

        if (verify_store) {
            if (pkg.content_hash.len != 64) {
                return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "invalid content hash length in manifest");
            }

            const computed = hash.calculateStoreContentHash(ctx.allocator, pkg.store_path, null) catch |err| {
                return ctx.fail(switch (err) {
                    hash.HashError.OutOfMemory => ActivationError.OutOfMemory,
                    hash.HashError.PermissionDenied => ActivationError.PermissionDenied,
                    hash.HashError.InvalidInput => ActivationError.InvalidInput,
                    else => ActivationError.FileSystem,
                }, pkg.store_path, "failed to compute store content hash");
            };
            defer ctx.allocator.free(computed);

            if (!std.mem.eql(u8, computed, pkg.content_hash)) {
                return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "store content hash mismatch");
            }
        }
    }
}

test "switchProfileGeneration creates atomic symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create a generation with manifest
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);

    // Create a minimal manifest
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try generation.writeManifest(allocator, gen_path, &manifest);

    // Activate the generation
    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Verify symlink was created
    const current = try generation.getCurrentGeneration(profile_dir);
    try std.testing.expectEqual(@as(?u32, 1), current);
}

test "switchProfileGeneration fails for non-existent generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create profile directory
    const profile_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer test_env.ctx.allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Try to activate non-existent generation
    const result = switchProfileGeneration(&test_env.ctx, "system", 999, .fast);
    try std.testing.expectError(ActivationError.GenerationNotFound, result);
}

test "switchProfileGeneration cleans up stale temp symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create a stale temp symlink
    var profile_dir_handle = try std.fs.openDirAbsolute(profile_dir, .{});
    defer profile_dir_handle.close();
    try profile_dir_handle.symLink("gen-old", CURRENT_SYMLINK_TEMP, .{});

    // Create a generation with manifest
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try generation.writeManifest(allocator, gen_path, &manifest);

    // Activate should succeed despite stale temp symlink
    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Verify correct generation is active
    const current = try generation.getCurrentGeneration(profile_dir);
    try std.testing.expectEqual(@as(?u32, 1), current);
}

test "switchProfileGeneration can switch between generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create two generations
    for ([_]u32{ 1, 2 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        try std.fs.cwd().makePath(gen_path);

        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(allocator, gen_path, &manifest);
    }

    // Activate gen 1
    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);
    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));

    // Switch to gen 2
    _ = try switchProfileGeneration(&test_env.ctx, "system", 2, .fast);
    try std.testing.expectEqual(@as(?u32, 2), try generation.getCurrentGeneration(profile_dir));

    // Switch back to gen 1
    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);
    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));
}

test "switchProfileGeneration creates GC roots" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "gc-roots" });
    defer allocator.free(gc_roots_dir);

    // Create generations 1-3 with manifests
    for ([_]u32{ 1, 2, 3 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        try std.fs.cwd().makePath(gen_path);

        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(allocator, gen_path, &manifest);
    }

    // Activate generation 3 with roots (retention_count=2)
    _ = try switchProfileGeneration(&test_env.ctx, "system", 3, .fast);

    // Check that current root was created in the nested structure (profiles/system/current)
    const profile_gc_dir = try std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", "system" });
    defer allocator.free(profile_gc_dir);

    const current_root = try std.fs.path.join(allocator, &.{ profile_gc_dir, "current" });
    defer allocator.free(current_root);
    std.fs.accessAbsolute(current_root, .{}) catch {
        return error.TestUnexpectedResult;
    };

    // Check that generation roots were created (should have gen-2 and gen-3 in kept/)
    const roots = try gcroots.listGenerationRoots(allocator, profile_gc_dir);
    defer allocator.free(roots);

    try std.testing.expectEqual(@as(usize, 2), roots.len);
}

test "switchProfileGeneration rejects store path that shares prefix but escapes store root" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);

    const escaped_store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store-evil", "badpkg" });
    defer allocator.free(escaped_store_path);

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "badpkg",
        "1.0.0",
        1,
        "x86_64",
        escaped_store_path,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );
    try generation.writeManifest(allocator, gen_path, &manifest);

    try std.testing.expectError(
        ActivationError.InvalidInput,
        switchProfileGeneration(&test_env.ctx, "system", 1, .fast),
    );
}

test "applyEtcTemplatesForManifest preserves PermissionDenied from etc template processing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "user" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "hash-testpkg-1.0.0" });
    defer allocator.free(store_path);
    const template_subdir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults", "subdir" });
    defer allocator.free(template_subdir);
    try std.fs.cwd().makePath(template_subdir);

    const template_file = try std.fs.path.join(allocator, &.{ template_subdir, "service.conf" });
    defer allocator.free(template_file);
    var tf = try std.fs.createFileAbsolute(template_file, .{});
    defer tf.close();
    try tf.writeAll("key=value\n");

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "testpkg",
        "1.0.0",
        1,
        "x86_64",
        store_path,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );
    try generation.writeManifest(allocator, gen_path, &manifest);

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);
    try std.posix.fchmodat(std.posix.AT.FDCWD, etc_dir, 0o555, 0);
    defer std.posix.fchmodat(std.posix.AT.FDCWD, etc_dir, 0o755, 0) catch {};

    var loaded_manifest = try loadValidatedTargetManifest(&test_env.ctx, profile_dir, 1, false);
    defer loaded_manifest.deinit();

    try std.testing.expectError(
        ActivationError.PermissionDenied,
        applyEtcTemplatesForManifest(&test_env.ctx, &loaded_manifest, etc_dir),
    );
}

test "activateSystemGeneration rolls back created /etc files and does not switch on failure" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    try std.fs.cwd().makePath(gen1_path);

    var manifest1 = generation.GenerationManifest.init(allocator, 1);
    defer manifest1.deinit();
    try generation.writeManifest(allocator, gen1_path, &manifest1);

    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    const gen2_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2" });
    defer allocator.free(gen2_path);
    try std.fs.cwd().makePath(gen2_path);

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "hash-testpkg-2.0.0" });
    defer allocator.free(store_path);

    const defaults_root = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults" });
    defer allocator.free(defaults_root);
    try std.fs.cwd().makePath(defaults_root);

    const copied_template = try std.fs.path.join(allocator, &.{ defaults_root, "copied.conf" });
    defer allocator.free(copied_template);
    {
        var copied = try std.fs.createFileAbsolute(copied_template, .{});
        defer copied.close();
        try copied.writeAll("copied=true\n");
    }

    const conflict_dir = try std.fs.path.join(allocator, &.{ defaults_root, "service" });
    defer allocator.free(conflict_dir);
    try std.fs.cwd().makePath(conflict_dir);

    const conflict_template = try std.fs.path.join(allocator, &.{ conflict_dir, "config.conf" });
    defer allocator.free(conflict_template);
    {
        var conflict = try std.fs.createFileAbsolute(conflict_template, .{});
        defer conflict.close();
        try conflict.writeAll("new-value=true\n");
    }

    var manifest2 = generation.GenerationManifest.init(allocator, 2);
    defer manifest2.deinit();
    try manifest2.addPackage(
        "testpkg",
        "2.0.0",
        1,
        "x86_64",
        store_path,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );
    try generation.writeManifest(allocator, gen2_path, &manifest2);

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);

    const existing_dir = try std.fs.path.join(allocator, &.{ etc_dir, "service" });
    defer allocator.free(existing_dir);
    try std.fs.cwd().makePath(existing_dir);

    const existing_file = try std.fs.path.join(allocator, &.{ existing_dir, "config.conf" });
    defer allocator.free(existing_file);
    {
        var existing = try std.fs.createFileAbsolute(existing_file, .{});
        defer existing.close();
        try existing.writeAll("old-value=true\n");
    }

    const created_file = try std.fs.path.join(allocator, &.{ etc_dir, "copied.conf" });
    defer allocator.free(created_file);
    const new_file = try std.fmt.allocPrint(allocator, "{s}.new", .{existing_file});
    defer allocator.free(new_file);

    std.fs.accessAbsolute(created_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.fs.accessAbsolute(new_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };

    try std.posix.fchmodat(std.posix.AT.FDCWD, etc_dir, 0o555, 0);
    defer std.posix.fchmodat(std.posix.AT.FDCWD, etc_dir, 0o755, 0) catch {};

    try std.testing.expectError(
        ActivationError.PermissionDenied,
        activateSystemGeneration(&test_env.ctx, 2, .fast),
    );

    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));

    std.fs.accessAbsolute(created_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.fs.accessAbsolute(new_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}
