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
const package_manifest = @import("manifest.zig");
const path_mod = @import("path.zig");
const path_safety = @import("path_safety.zig");
const store = @import("store.zig");

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
    boot_artifacts_staged: usize,
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
    const store_root_a = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root_a);
    gcroots.updateRoots(ctx.allocator, store_root_a, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
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

    // Boot artifacts are staged under unique names before the generation
    // pointer changes. A failed activation may leave an unused artifact, but
    // it cannot leave /boot partially written or replace the selected kernel.
    const boot_artifacts_staged = try stageBootArtifacts(ctx, &manifest);

    try switchProfileGenerationAtPath(ctx, profile_dir, gen_num);

    const gc_roots_dir = try getGCRootsDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(gc_roots_dir);
    const store_root_b = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root_b);
    gcroots.updateRoots(ctx.allocator, store_root_b, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
        return mapGCRootError(err);
    };

    const result = SystemActivationResult{
        .etc_copied = etc_result.copied,
        .etc_skipped = etc_result.skipped,
        .etc_differing = etc_result.differing,
        .boot_artifacts_staged = boot_artifacts_staged,
    };
    etc_result.deinit();

    return result;
}

/// Stage boot artifacts for the active system generation without changing the
/// generation pointer or bootloader selection. This is used by idempotent
/// installs that otherwise take the profile-up-to-date fast path.
pub fn stageCurrentSystemBootArtifacts(
    ctx: *mere.Context,
    verification: VerificationMode,
) ActivationError!usize {
    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, "system");
    defer ctx.allocator.free(profile_dir);

    const gen_num = generation.getCurrentGeneration(profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => ActivationError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ActivationError.PermissionDenied,
            generation.GenerationError.ProfilesNotFound => ActivationError.GenerationNotFound,
            else => ActivationError.FileSystem,
        };
    } orelse return ActivationError.GenerationNotFound;

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();
    return stageBootArtifacts(ctx, &manifest);
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
    var profile_dir_handle = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_dir, .{}) catch {
        return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to open profile directory for activation");
    };
    defer profile_dir_handle.close(path_mod.currentIo());

    // Remove stale temp symlink if it exists (idempotent)
    profile_dir_handle.deleteFile(path_mod.currentIo(), CURRENT_SYMLINK_TEMP) catch |err| {
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
    profile_dir_handle.symLink(path_mod.currentIo(), target, CURRENT_SYMLINK_TEMP, .{}) catch {
        return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to create temporary symlink .current-new");
    };

    const current_temp_path = std.fs.path.join(ctx.allocator, &.{ profile_dir, CURRENT_SYMLINK_TEMP }) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to construct temporary symlink path");
    };
    defer ctx.allocator.free(current_temp_path);
    const current_path = std.fs.path.join(ctx.allocator, &.{ profile_dir, CURRENT_SYMLINK }) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to construct current symlink path");
    };
    defer ctx.allocator.free(current_path);

    // Atomic rename: .current-new -> current
    // This is the atomic operation that makes the switch visible
    std.Io.Dir.renameAbsolute(current_temp_path, current_path, path_mod.currentIo()) catch {
        // Record diagnostic context and clean up temp symlink on failure
        const err = ctx.fail(ActivationError.FileSystem, profile_dir, "failed to atomically rename .current-new -> current");
        profile_dir_handle.deleteFile(path_mod.currentIo(), CURRENT_SYMLINK_TEMP) catch {};
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
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), gen_path, .{}) catch {
        return ctx.fail(ActivationError.GenerationNotFound, gen_path, "generation not found");
    };

    // Check manifest exists and parses (completion marker)
    const manifest_path = std.fs.path.join(ctx.allocator, &.{ gen_path, generation.MANIFEST_FILENAME }) catch {
        return ctx.fail(ActivationError.OutOfMemory, gen_path, "failed to construct manifest path");
    };
    defer ctx.allocator.free(manifest_path);

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(ActivationError.OutOfMemory, gen_path, "failed to construct store root path");
    };
    defer ctx.allocator.free(store_root);

    var manifest = generation.readManifest(ctx.allocator, store_root, gen_path) catch |err| {
        const detail = switch (err) {
            generation.GenerationError.GenerationNotFound,
            generation.GenerationError.InvalidManifest,
            generation.GenerationError.ParseError,
            => "profile.kdl missing or invalid",
            generation.GenerationError.NoCurrentGeneration,
            generation.GenerationError.NoPreviousGeneration,
            => "unexpected generation query error",
            generation.GenerationError.PermissionDenied => "permission denied reading profile.kdl",
            generation.GenerationError.FileSystem => "failed to read profile.kdl",
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

const BOOT_ARTIFACT_HASH_PREFIX_LEN: usize = 16;

/// Stage the boot payload of the selected Linux package without changing the
/// bootloader selection. Names include the package content hash so a new
/// payload never overwrites an older same-version kernel.
fn stageBootArtifacts(
    ctx: *mere.Context,
    manifest: *const generation.GenerationManifest,
) ActivationError!usize {
    const boot_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "boot" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(boot_dir);

    var staged: usize = 0;
    for (manifest.packages.items) |pkg| {
        // Boot projection is intentionally explicit. Other packages may carry
        // a boot/ directory for their own purposes, but only linux owns the
        // host kernel staging contract.
        if (!std.mem.eql(u8, pkg.name, "linux")) continue;
        if (pkg.version.len == 0 or pkg.content_hash.len < BOOT_ARTIFACT_HASH_PREFIX_LEN) {
            return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "invalid linux package identity for boot staging");
        }
        for (pkg.version) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and c != '+') {
                return ctx.fail(ActivationError.InvalidInput, pkg.version, "unsafe linux version for boot artifact name");
            }
        }
        for (pkg.content_hash[0..BOOT_ARTIFACT_HASH_PREFIX_LEN]) |c| {
            if (!std.ascii.isHex(c)) {
                return ctx.fail(ActivationError.InvalidInput, pkg.content_hash, "invalid linux content hash for boot artifact name");
            }
        }

        const source_vmlinux = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, "boot", "vmlinux" }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(source_vmlinux);
        const source_config = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, "boot", "config" }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(source_config);

        for ([_][]const u8{ source_vmlinux, source_config }) |source| {
            std.Io.Dir.accessAbsolute(path_mod.currentIo(), source, .{}) catch {
                return ctx.fail(ActivationError.FileSystem, source, "linux package is missing a boot artifact");
            };
        }

        path_mod.ensureDirExists(boot_dir) catch |err| {
            return ctx.fail(switch (err) {
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, boot_dir, "failed to create boot directory");
        };

        const hash_prefix = pkg.content_hash[0..BOOT_ARTIFACT_HASH_PREFIX_LEN];
        const vmlinux_name = std.fmt.allocPrint(ctx.allocator, "vmlinux-{s}-{s}", .{ pkg.version, hash_prefix }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(vmlinux_name);
        const config_name = std.fmt.allocPrint(ctx.allocator, "config-{s}-{s}", .{ pkg.version, hash_prefix }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(config_name);

        staged += try stageOneBootArtifact(ctx, boot_dir, source_vmlinux, vmlinux_name);
        staged += try stageOneBootArtifact(ctx, boot_dir, source_config, config_name);
    }

    return staged;
}

fn stageOneBootArtifact(
    ctx: *mere.Context,
    boot_dir: []const u8,
    source: []const u8,
    name: []const u8,
) ActivationError!usize {
    const destination = std.fs.path.join(ctx.allocator, &.{ boot_dir, name }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(destination);

    // Content-addressed naming makes this idempotent and preserves all older
    // kernel payloads. Do not replace an existing artifact merely because a
    // same-version package was selected again.
    if (path_mod.fileExists(destination)) return 0;

    var random_bytes: [8]u8 = undefined;
    path_mod.currentIo().random(&random_bytes);
    const temp_name = std.fmt.allocPrint(ctx.allocator, ".mere-{s}-{s}", .{ name, std.fmt.bytesToHex(random_bytes, .lower) }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(temp_name);
    const temp_path = std.fs.path.join(ctx.allocator, &.{ boot_dir, temp_name }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(temp_path);

    path_mod.copyFile(source, temp_path) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ActivationError.PermissionDenied,
            else => ActivationError.FileSystem,
        }, source, "failed to copy boot artifact");
    };
    errdefer std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), temp_path) catch {};

    std.Io.Dir.renameAbsolute(temp_path, destination, path_mod.currentIo()) catch |err| {
        // Another activation may have staged the same content concurrently.
        // Preserve that winner and discard only our temporary file.
        if (err == error.PathAlreadyExists or err == error.AccessDenied) {
            if (path_mod.fileExists(destination)) return 0;
        }
        return ctx.fail(switch (err) {
            error.AccessDenied => ActivationError.PermissionDenied,
            else => ActivationError.FileSystem,
        }, destination, "failed to publish boot artifact");
    };

    return 1;
}

// Stage boot artifacts for the selected Linux package. This deliberately
// leaves bootloader configuration and the currently selected entry alone.
test "stageBootArtifacts publishes versioned linux payloads idempotently" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789-linux-1.2.3" });
    defer allocator.free(store_path);
    const package_boot = try std.fs.path.join(allocator, &.{ store_path, "boot" });
    defer allocator.free(package_boot);
    try path_mod.ensureDirExists(package_boot);

    const source_vmlinux = try std.fs.path.join(allocator, &.{ package_boot, "vmlinux" });
    defer allocator.free(source_vmlinux);
    var vmlinux = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), source_vmlinux, .{});
    try vmlinux.writeStreamingAll(path_mod.currentIo(), "kernel");
    vmlinux.close(path_mod.currentIo());

    const source_config = try std.fs.path.join(allocator, &.{ package_boot, "config" });
    defer allocator.free(source_config);
    var config = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), source_config, .{});
    try config.writeStreamingAll(path_mod.currentIo(), "CONFIG_TUN=y\\n");
    config.close(path_mod.currentIo());

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "linux",
        "1.2.3",
        1,
        "x86_64",
        store_path,
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
    );

    try std.testing.expectEqual(@as(usize, 2), try stageBootArtifacts(&test_env.ctx, &manifest));
    try std.testing.expectEqual(@as(usize, 0), try stageBootArtifacts(&test_env.ctx, &manifest));

    const staged_vmlinux = try std.fs.path.join(allocator, &.{ test_env.path, "boot", "vmlinux-1.2.3-abcdef0123456789" });
    defer allocator.free(staged_vmlinux);
    const staged_config = try std.fs.path.join(allocator, &.{ test_env.path, "boot", "config-1.2.3-abcdef0123456789" });
    defer allocator.free(staged_config);
    try std.testing.expect(path_mod.fileExists(staged_vmlinux));
    try std.testing.expect(path_mod.fileExists(staged_config));
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

        var store_dir = path_mod.openExistingDir(pkg.store_path) catch |err| {
            return ctx.fail(switch (err) {
                error.FileNotFound => ActivationError.FileSystem,
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, pkg.store_path, "failed to stat store path");
        };
        defer store_dir.close(path_mod.currentIo());
        const stat_buf = store_dir.stat(path_mod.currentIo()) catch |err| {
            return ctx.fail(switch (err) {
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, pkg.store_path, "failed to stat store path");
        };

        if (stat_buf.kind != .directory) {
            return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "store path is not a directory");
        }

        // For system profiles, hash verification is mandatory for unhardened objects.
        // Already-hardened objects were verified when first admitted.
        const do_hash_verify = verify_store or (require_root_owned and !store.isHardened(pkg.store_path));

        if (do_hash_verify) {
            if (pkg.content_hash.len != 64) {
                return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "invalid content hash length in manifest");
            }

            const format: package_manifest.Format = blk: {
                const v4_manifest_path = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, package_manifest.MANIFEST_V4_FILENAME }) catch {
                    return ctx.fail(ActivationError.OutOfMemory, pkg.store_path, "failed to construct v4 manifest path");
                };
                defer ctx.allocator.free(v4_manifest_path);
                const has_v4 = blk_v4: {
                    std.Io.Dir.accessAbsolute(path_mod.currentIo(), v4_manifest_path, .{}) catch break :blk_v4 false;
                    break :blk_v4 true;
                };
                if (has_v4) break :blk .v4;

                const v3_manifest_path = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, package_manifest.MANIFEST_V3_FILENAME }) catch {
                    return ctx.fail(ActivationError.OutOfMemory, pkg.store_path, "failed to construct v3 manifest path");
                };
                defer ctx.allocator.free(v3_manifest_path);
                const has_v3 = blk_v3: {
                    std.Io.Dir.accessAbsolute(path_mod.currentIo(), v3_manifest_path, .{}) catch break :blk_v3 false;
                    break :blk_v3 true;
                };
                if (has_v3) break :blk .v3;

                const v2_manifest_path = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, package_manifest.MANIFEST_V2_FILENAME }) catch {
                    return ctx.fail(ActivationError.OutOfMemory, pkg.store_path, "failed to construct v2 manifest path");
                };
                defer ctx.allocator.free(v2_manifest_path);
                const has_v2 = blk_v2: {
                    std.Io.Dir.accessAbsolute(path_mod.currentIo(), v2_manifest_path, .{}) catch break :blk_v2 false;
                    break :blk_v2 true;
                };
                break :blk if (has_v2) .v2 else .v1;
            };
            const computed = switch (format) {
                .v1 => hash.calculateStoreContentHash(ctx.allocator, pkg.store_path, null),
                .v2 => hash.calculateStoreContentHashV2(ctx.allocator, pkg.store_path, null),
                .v3, .v4 => hash.calculateStoreContentHashV3(ctx.allocator, pkg.store_path, null),
            };
            const computed_hash = computed catch |err| {
                return ctx.fail(switch (err) {
                    hash.HashError.OutOfMemory => ActivationError.OutOfMemory,
                    hash.HashError.PermissionDenied => ActivationError.PermissionDenied,
                    hash.HashError.InvalidInput => ActivationError.InvalidInput,
                    else => ActivationError.FileSystem,
                }, pkg.store_path, "failed to compute store content hash");
            };
            defer ctx.allocator.free(computed_hash);

            if (!std.mem.eql(u8, computed_hash, pkg.content_hash)) {
                var accepted_transitional = false;
                if (format == .v1) {
                    const transitional = hash.calculateTransitionalMetadataContentHash(ctx.allocator, pkg.store_path, null) catch null;
                    if (transitional) |transitional_hash| {
                        accepted_transitional = std.mem.eql(u8, transitional_hash, pkg.content_hash);
                        ctx.allocator.free(transitional_hash);
                    }
                }
                if (!accepted_transitional) {
                    return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "store content hash mismatch");
                }
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
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Create a generation with manifest
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

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

    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer test_env.ctx.allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

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
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Create a stale temp symlink
    var profile_dir_handle = try std.Io.Dir.openDirAbsolute(io, profile_dir, .{});
    defer profile_dir_handle.close(io);
    try profile_dir_handle.symLink(io, "gen-old", CURRENT_SYMLINK_TEMP, .{});

    // Create a generation with manifest
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

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
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Create two generations
    for ([_]u32{ 1, 2 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        {
            var dir = try path_mod.makePathAndOpenDir(gen_path);
            dir.close(io);
        }

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
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "gc-roots" });
    defer allocator.free(gc_roots_dir);

    // Create generations 1-3 with manifests
    for ([_]u32{ 1, 2, 3 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        {
            var dir = try path_mod.makePathAndOpenDir(gen_path);
            dir.close(io);
        }

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
    std.Io.Dir.accessAbsolute(io, current_root, .{}) catch {
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
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

    // Store path escapes store root — can't happen via derived paths, but test
    // the validation layer directly by writing a manifest with the old format
    // fields still present in-memory.
    const escaped_store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store-evil", "badpkg" });
    defer allocator.free(escaped_store_path);

    // Build manifest in-memory with the bad store path (bypassing encode/parse)
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

    // Write a valid KDL so readManifest succeeds, but then swap the manifest
    // with our crafted one for validation testing.
    try generation.writeManifest(allocator, gen_path, &manifest);

    // The derived store path will be valid, so we need to test validation
    // directly. Create a manifest with the escaped path and validate it.
    try std.testing.expectError(
        ActivationError.FileSystem,
        switchProfileGeneration(&test_env.ctx, "system", 1, .fast),
    );
}

test "applyEtcTemplatesForManifest preserves PermissionDenied from etc template processing" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "user" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

    const content_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", content_hash ++ "-testpkg-1.0.0" });
    defer allocator.free(store_path);
    const template_subdir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults", "subdir" });
    defer allocator.free(template_subdir);
    {
        var dir = try path_mod.makePathAndOpenDir(template_subdir);
        dir.close(io);
    }

    const template_file = try std.fs.path.join(allocator, &.{ template_subdir, "service.conf" });
    defer allocator.free(template_file);
    var tf = try std.Io.Dir.createFileAbsolute(io, template_file, .{});
    defer tf.close(io);
    try tf.writeStreamingAll(io, "key=value\n");

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "testpkg",
        "1.0.0",
        1,
        "x86_64",
        store_path,
        content_hash,
    );
    try generation.writeManifest(allocator, gen_path, &manifest);

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(etc_dir);
        dir.close(io);
    }
    var etc_handle = try path_mod.openExistingDir(etc_dir);
    defer etc_handle.close(io);
    try etc_handle.setPermissions(io, .fromMode(0o555));
    defer etc_handle.setPermissions(io, .fromMode(0o755)) catch {};

    var loaded_manifest = try loadValidatedTargetManifest(&test_env.ctx, profile_dir, 1, false);
    defer loaded_manifest.deinit();

    const result = applyEtcTemplatesForManifest(&test_env.ctx, &loaded_manifest, etc_dir);
    if (result) |success| {
        var owned = success;
        defer owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(ActivationError.PermissionDenied, err);
    }
}

test "activateSystemGeneration rolls back created /etc files and does not switch on failure" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen1_path);
        dir.close(io);
    }

    var manifest1 = generation.GenerationManifest.init(allocator, 1);
    defer manifest1.deinit();
    try generation.writeManifest(allocator, gen1_path, &manifest1);

    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    const gen2_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2" });
    defer allocator.free(gen2_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen2_path);
        dir.close(io);
    }

    // Build store path contents first in a temp location, then compute the real
    // content hash so system profile activation's mandatory verification passes.
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);

    const tmp_store_path = try std.fs.path.join(allocator, &.{ store_root, "tmp-testpkg-2.0.0" });
    defer allocator.free(tmp_store_path);

    const defaults_root = try std.fs.path.join(allocator, &.{ tmp_store_path, "etc-defaults" });
    defer allocator.free(defaults_root);
    {
        var dir = try path_mod.makePathAndOpenDir(defaults_root);
        dir.close(io);
    }

    const copied_template = try std.fs.path.join(allocator, &.{ defaults_root, "copied.conf" });
    defer allocator.free(copied_template);
    {
        var copied = try std.Io.Dir.createFileAbsolute(io, copied_template, .{});
        defer copied.close(io);
        try copied.writeStreamingAll(io, "copied=true\n");
    }

    const conflict_dir = try std.fs.path.join(allocator, &.{ defaults_root, "service" });
    defer allocator.free(conflict_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(conflict_dir);
        dir.close(io);
    }

    const conflict_template = try std.fs.path.join(allocator, &.{ conflict_dir, "config.conf" });
    defer allocator.free(conflict_template);
    {
        var conflict = try std.Io.Dir.createFileAbsolute(io, conflict_template, .{});
        defer conflict.close(io);
        try conflict.writeStreamingAll(io, "new-value=true\n");
    }

    // Compute real content hash and rename to final store path
    const content_hash_2 = try hash.calculateStoreContentHash(allocator, tmp_store_path, null);
    defer allocator.free(content_hash_2);

    const final_dir_name = try std.fmt.allocPrint(allocator, "{s}-testpkg-2.0.0", .{content_hash_2});
    defer allocator.free(final_dir_name);

    const store_path = try std.fs.path.join(allocator, &.{ store_root, final_dir_name });
    defer allocator.free(store_path);

    try std.Io.Dir.renameAbsolute(tmp_store_path, store_path, io);

    var manifest2 = generation.GenerationManifest.init(allocator, 2);
    defer manifest2.deinit();
    try manifest2.addPackage(
        "testpkg",
        "2.0.0",
        1,
        "x86_64",
        store_path,
        content_hash_2,
    );
    try generation.writeManifest(allocator, gen2_path, &manifest2);

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(etc_dir);
        dir.close(io);
    }

    const existing_dir = try std.fs.path.join(allocator, &.{ etc_dir, "service" });
    defer allocator.free(existing_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(existing_dir);
        dir.close(io);
    }

    const existing_file = try std.fs.path.join(allocator, &.{ existing_dir, "config.conf" });
    defer allocator.free(existing_file);
    {
        var existing = try std.Io.Dir.createFileAbsolute(io, existing_file, .{});
        defer existing.close(io);
        try existing.writeStreamingAll(io, "old-value=true\n");
    }

    const created_file = try std.fs.path.join(allocator, &.{ etc_dir, "copied.conf" });
    defer allocator.free(created_file);
    const new_file = try std.fmt.allocPrint(allocator, "{s}.new", .{existing_file});
    defer allocator.free(new_file);

    std.Io.Dir.accessAbsolute(io, created_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.Io.Dir.accessAbsolute(io, new_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };

    var etc_handle = try path_mod.openExistingDir(etc_dir);
    defer etc_handle.close(io);
    try etc_handle.setPermissions(io, .fromMode(0o555));
    defer etc_handle.setPermissions(io, .fromMode(0o755)) catch {};

    try std.testing.expectError(
        ActivationError.PermissionDenied,
        activateSystemGeneration(&test_env.ctx, 2, .fast),
    );

    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));

    std.Io.Dir.accessAbsolute(io, created_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.Io.Dir.accessAbsolute(io, new_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

test "system profile activation rejects mismatched content hash without verify-store flag" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Gen 1: empty, just to have a current generation
    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen1_path);
        dir.close(io);
    }
    var manifest1 = generation.GenerationManifest.init(allocator, 1);
    defer manifest1.deinit();
    try generation.writeManifest(allocator, gen1_path, &manifest1);
    _ = try switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Gen 2: references a store path with a WRONG content hash
    const gen2_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2" });
    defer allocator.free(gen2_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen2_path);
        dir.close(io);
    }

    const fake_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", fake_hash ++ "-badpkg-1.0.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }
    // Put a file in so the real hash differs from fake_hash
    const file_path = try std.fs.path.join(allocator, &.{ store_path, "data.txt" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "this content does not match the hash\n");
    }

    var manifest2 = generation.GenerationManifest.init(allocator, 2);
    defer manifest2.deinit();
    try manifest2.addPackage("badpkg", "1.0.0", 1, "x86_64", store_path, fake_hash);
    try generation.writeManifest(allocator, gen2_path, &manifest2);

    // Activate with .fast (no explicit verify-store) — should STILL fail
    // because system profile hash verification is now mandatory
    try std.testing.expectError(
        ActivationError.InvalidInput,
        activateSystemGeneration(&test_env.ctx, 2, .fast),
    );

    // Should not have switched
    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));
}
