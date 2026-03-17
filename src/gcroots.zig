const std = @import("std");
const generation = @import("generation.zig");
const mere = @import("mere.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const GCRootsError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    GenerationNotFound,
    CannotDeleteActive,
};

fn mapGCRootFsError(err: anyerror) GCRootsError {
    return switch (err) {
        error.OutOfMemory => GCRootsError.OutOfMemory,
        error.AccessDenied => GCRootsError.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => GCRootsError.InvalidInput,
        else => GCRootsError.FileSystem,
    };
}

fn mapGenerationError(err: generation.GenerationError) GCRootsError {
    return switch (err) {
        generation.GenerationError.OutOfMemory => GCRootsError.OutOfMemory,
        generation.GenerationError.PermissionDenied => GCRootsError.PermissionDenied,
        generation.GenerationError.InvalidInput => GCRootsError.InvalidInput,
        else => GCRootsError.FileSystem,
    };
}

pub const DEFAULT_RETENTION_COUNT: u32 = 2;

pub const KEEP_MARKER = ".keep";
pub const KEEP_NOTE = ".keep.note";

/// Check if a generation has an explicit keep marker.
pub fn isExplicitlyKept(
    allocator: std.mem.Allocator,
    profile_dir: []const u8,
    gen_num: u32,
) GCRootsError!bool {
    const gen_path = generation.getGenerationPath(allocator, profile_dir, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(gen_path);

    const keep_path = std.fs.path.join(allocator, &.{ gen_path, KEEP_MARKER }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(keep_path);

    std.fs.accessAbsolute(keep_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => false,
            else => mapGCRootFsError(err),
        };
    };
    return true;
}

/// Mark a generation as explicitly kept.
pub fn keepGeneration(
    allocator: std.mem.Allocator,
    profile_dir: []const u8,
    gen_num: u32,
    note: ?[]const u8,
) GCRootsError!void {
    const gen_path = generation.getGenerationPath(allocator, profile_dir, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(gen_path);

    std.fs.accessAbsolute(gen_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => GCRootsError.GenerationNotFound,
            else => mapGCRootFsError(err),
        };
    };

    const keep_path = std.fs.path.join(allocator, &.{ gen_path, KEEP_MARKER }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(keep_path);

    var file = std.fs.createFileAbsolute(keep_path, .{}) catch |err| {
        return mapGCRootFsError(err);
    };
    file.close();

    if (note) |n| {
        const note_path = std.fs.path.join(allocator, &.{ gen_path, KEEP_NOTE }) catch {
            return GCRootsError.OutOfMemory;
        };
        defer allocator.free(note_path);

        var note_file = std.fs.createFileAbsolute(note_path, .{}) catch {
            return; // Best effort
        };
        defer note_file.close();
        note_file.writeAll(n) catch {};
    }
}

/// Remove explicit keep marker from a generation.
pub fn unkeepGeneration(
    allocator: std.mem.Allocator,
    profile_dir: []const u8,
    gen_num: u32,
) GCRootsError!void {
    const gen_path = generation.getGenerationPath(allocator, profile_dir, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(gen_path);

    const keep_path = std.fs.path.join(allocator, &.{ gen_path, KEEP_MARKER }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(keep_path);

    std.fs.deleteFileAbsolute(keep_path) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return mapGCRootFsError(err),
        }
    };

    const note_path = std.fs.path.join(allocator, &.{ gen_path, KEEP_NOTE }) catch {
        return;
    };
    defer allocator.free(note_path);

    std.fs.deleteFileAbsolute(note_path) catch {};
}

/// Determine which generations should be kept according to retention policy.
///
/// Returns a list of generation numbers that should have GC roots.
/// Caller owns returned slice.
pub fn getKeptGenerations(
    allocator: std.mem.Allocator,
    profile_dir: []const u8,
    retention_count: u32,
) GCRootsError![]u32 {
    const all_gens = generation.listGenerations(allocator, profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => GCRootsError.OutOfMemory,
            else => mapGenerationError(err),
        };
    };
    defer allocator.free(all_gens);

    if (all_gens.len == 0) {
        return allocator.alloc(u32, 0) catch {
            return GCRootsError.OutOfMemory;
        };
    }

    var kept: std.ArrayList(u32) = .{};
    errdefer kept.deinit(allocator);

    const start_idx = if (all_gens.len > retention_count)
        all_gens.len - retention_count
    else
        0;

    for (all_gens[start_idx..]) |gen| {
        kept.append(allocator, gen) catch {
            return GCRootsError.OutOfMemory;
        };
    }

    for (all_gens[0..start_idx]) |gen| {
        if (try isExplicitlyKept(allocator, profile_dir, gen)) {
            kept.append(allocator, gen) catch {
                return GCRootsError.OutOfMemory;
            };
        }
    }

    return kept.toOwnedSlice(allocator) catch {
        return GCRootsError.OutOfMemory;
    };
}

pub fn updateRoots(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    profile_dir: []const u8,
    retention_count: u32,
) GCRootsError!void {
    const profile_name = extractProfileName(profile_dir);

    const profile_gc_dir = std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", profile_name }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(profile_gc_dir);

    const state = try buildRootUpdateState(allocator, profile_gc_dir, profile_dir, retention_count);
    defer {
        allocator.free(state.kept_gens);
        allocator.free(state.all_gens);
    }

    try ensureRequiredRoots(allocator, profile_gc_dir, profile_dir, state.kept_gens);
    try pruneObsoleteRoots(allocator, profile_gc_dir, state.all_gens, state.kept_gens);
}

pub fn ensureRequiredRootsForProfile(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    profile_dir: []const u8,
    retention_count: u32,
) GCRootsError!void {
    const profile_name = extractProfileName(profile_dir);
    const profile_gc_dir = std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", profile_name }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(profile_gc_dir);

    const state = try buildRootUpdateState(allocator, profile_gc_dir, profile_dir, retention_count);
    defer {
        allocator.free(state.kept_gens);
        allocator.free(state.all_gens);
    }

    try ensureRequiredRoots(allocator, profile_gc_dir, profile_dir, state.kept_gens);
}

pub fn pruneObsoleteRootsForProfile(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    profile_dir: []const u8,
    retention_count: u32,
) GCRootsError!void {
    const profile_name = extractProfileName(profile_dir);
    const profile_gc_dir = std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", profile_name }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(profile_gc_dir);

    const state = try buildRootUpdateState(allocator, profile_gc_dir, profile_dir, retention_count);
    defer {
        allocator.free(state.kept_gens);
        allocator.free(state.all_gens);
    }

    try pruneObsoleteRoots(allocator, profile_gc_dir, state.all_gens, state.kept_gens);
}

const RootUpdateState = struct {
    kept_gens: []u32,
    all_gens: []u32,
};

fn buildRootUpdateState(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
    profile_dir: []const u8,
    retention_count: u32,
) GCRootsError!RootUpdateState {
    std.fs.cwd().makePath(profile_gc_dir) catch |err| {
        return mapGCRootFsError(err);
    };

    const kept_gens = try getKeptGenerations(allocator, profile_dir, retention_count);
    errdefer allocator.free(kept_gens);

    const all_gens = generation.listGenerations(allocator, profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => GCRootsError.OutOfMemory,
            else => mapGenerationError(err),
        };
    };
    errdefer allocator.free(all_gens);

    return .{
        .kept_gens = kept_gens,
        .all_gens = all_gens,
    };
}

fn ensureRequiredRoots(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
    profile_dir: []const u8,
    kept_gens: []const u32,
) GCRootsError!void {
    try updateCurrentRoot(allocator, profile_gc_dir, profile_dir);

    for (kept_gens) |gen| {
        try ensureGenerationRoot(allocator, profile_gc_dir, profile_dir, gen);
    }
}

fn pruneObsoleteRoots(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
    all_gens: []const u32,
    kept_gens: []const u32,
) GCRootsError!void {
    for (all_gens) |gen| {
        var is_kept = false;
        for (kept_gens) |kept| {
            if (gen == kept) {
                is_kept = true;
                break;
            }
        }
        if (!is_kept) {
            try removeGenerationRoot(allocator, profile_gc_dir, gen);
        }
    }
}

fn extractProfileName(profile_dir: []const u8) []const u8 {
    // Find last path separator
    var i = profile_dir.len;
    while (i > 0) {
        i -= 1;
        if (profile_dir[i] == '/' or profile_dir[i] == '\\') {
            return profile_dir[i + 1 ..];
        }
    }
    // No separator found, return whole string
    return profile_dir;
}

/// Update the current root symlink.
/// Creates symlink at <profile_gc_dir>/current -> <profile_dir>/current
fn updateCurrentRoot(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
    profile_dir: []const u8,
) GCRootsError!void {
    const root_path = std.fs.path.join(allocator, &.{ profile_gc_dir, "current" }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(root_path);

    const target = std.fs.path.join(allocator, &.{ profile_dir, "current" }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(target);

    // Remove existing symlink if present
    std.fs.deleteFileAbsolute(root_path) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return mapGCRootFsError(err),
        }
    };

    // Create new symlink
    std.posix.symlinkat(target, std.fs.cwd().fd, root_path) catch |err| {
        return mapGCRootFsError(err);
    };
}

/// Ensure a generation has a root symlink.
/// Creates symlink at <profile_gc_dir>/kept/gen-N -> <profile_dir>/gen-N
fn ensureGenerationRoot(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
    profile_dir: []const u8,
    gen_num: u32,
) GCRootsError!void {
    // Ensure kept/ subdirectory exists
    const kept_dir = std.fs.path.join(allocator, &.{ profile_gc_dir, "kept" }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(kept_dir);

    std.fs.cwd().makePath(kept_dir) catch |err| {
        return mapGCRootFsError(err);
    };

    const root_name = generation.formatGenerationName(allocator, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(root_name);

    const root_path = std.fs.path.join(allocator, &.{ kept_dir, root_name }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(root_path);

    const target = generation.getGenerationPath(allocator, profile_dir, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(target);

    // Check if root already exists and points to correct target
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(root_path, &link_buf)) |existing_target| {
        if (std.mem.eql(u8, existing_target, target)) {
            return; // Already correct
        }
        // Remove incorrect symlink
        std.fs.deleteFileAbsolute(root_path) catch {};
    } else |_| {
        // Doesn't exist, will create
    }

    // Create symlink
    std.posix.symlinkat(target, std.fs.cwd().fd, root_path) catch |err| {
        return mapGCRootFsError(err);
    };
}

/// Remove a generation root symlink (if it exists).
/// Removes symlink at <profile_gc_dir>/kept/gen-N
fn removeGenerationRoot(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
    gen_num: u32,
) GCRootsError!void {
    const kept_dir = std.fs.path.join(allocator, &.{ profile_gc_dir, "kept" }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(kept_dir);

    const root_name = generation.formatGenerationName(allocator, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(root_name);

    const root_path = std.fs.path.join(allocator, &.{ kept_dir, root_name }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(root_path);

    std.fs.deleteFileAbsolute(root_path) catch |err| {
        switch (err) {
            error.FileNotFound => {}, // OK
            else => return mapGCRootFsError(err),
        }
    };
}

/// Delete a generation and its root.
///
/// Fails if trying to delete the active generation.
pub fn deleteGeneration(
    ctx: *mere.Context,
    gc_roots_dir: []const u8,
    profile_dir: []const u8,
    gen_num: u32,
) GCRootsError!void {
    // Check if this is the active generation
    const current = generation.getCurrentGeneration(profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => GCRootsError.OutOfMemory,
            else => mapGenerationError(err),
        };
    };

    if (current != null and current.? == gen_num) {
        return GCRootsError.CannotDeleteActive;
    }

    // Extract profile name and build profile_gc_dir
    const profile_name = extractProfileName(profile_dir);
    const profile_gc_dir = std.fs.path.join(ctx.allocator, &.{ gc_roots_dir, "profiles", profile_name }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_gc_dir);

    // Remove the root symlink first
    try removeGenerationRoot(ctx.allocator, profile_gc_dir, gen_num);

    // Remove the generation directory
    const gen_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch {
        return GCRootsError.OutOfMemory;
    };
    defer ctx.allocator.free(gen_path);

    std.fs.deleteTreeAbsolute(gen_path) catch |err| {
        return switch (err) {
            error.FileNotFound => GCRootsError.GenerationNotFound,
            else => mapGCRootFsError(err),
        };
    };
}

/// List all generation roots (symlinks named gen-N in profile_gc_dir/kept/).
pub fn listGenerationRoots(
    allocator: std.mem.Allocator,
    profile_gc_dir: []const u8,
) GCRootsError![]u32 {
    const kept_dir = std.fs.path.join(allocator, &.{ profile_gc_dir, "kept" }) catch {
        return GCRootsError.OutOfMemory;
    };
    defer allocator.free(kept_dir);

    var dir = std.fs.openDirAbsolute(kept_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => allocator.alloc(u32, 0) catch return GCRootsError.OutOfMemory,
            else => mapGCRootFsError(err),
        };
    };
    defer dir.close();

    var roots: std.ArrayList(u32) = .{};
    errdefer roots.deinit(allocator);

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next() catch |err| {
            return mapGCRootFsError(err);
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind == .sym_link) {
            // Parse gen-N format
            if (generation.parseGenerationNumber(e.name)) |num| {
                roots.append(allocator, num) catch {
                    return GCRootsError.OutOfMemory;
                };
            }
        }
    }

    const items = roots.toOwnedSlice(allocator) catch {
        return GCRootsError.OutOfMemory;
    };
    std.mem.sort(u32, items, {}, std.sort.asc(u32));

    return items;
}

test "gcroots mapGCRootFsError preserves actionable classes" {
    try std.testing.expectEqual(GCRootsError.PermissionDenied, mapGCRootFsError(error.AccessDenied));
    try std.testing.expectEqual(GCRootsError.OutOfMemory, mapGCRootFsError(error.OutOfMemory));
    try std.testing.expectEqual(GCRootsError.InvalidInput, mapGCRootFsError(error.BadPathName));
    try std.testing.expectEqual(GCRootsError.FileSystem, mapGCRootFsError(error.InputOutput));
}

test "gcroots mapGenerationError preserves actionable classes" {
    try std.testing.expectEqual(
        GCRootsError.PermissionDenied,
        mapGenerationError(generation.GenerationError.PermissionDenied),
    );
    try std.testing.expectEqual(
        GCRootsError.OutOfMemory,
        mapGenerationError(generation.GenerationError.OutOfMemory),
    );
    try std.testing.expectEqual(
        GCRootsError.InvalidInput,
        mapGenerationError(generation.GenerationError.InvalidInput),
    );
    try std.testing.expectEqual(
        GCRootsError.FileSystem,
        mapGenerationError(generation.GenerationError.InvalidManifest),
    );
}

// Tests

// Spec #12: .keep marker detection
test "isExplicitlyKept returns false when no marker" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory with a generation
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try generation.writeManifest(allocator, gen_path, &manifest);

    const kept = try isExplicitlyKept(allocator, profile_dir, 1);
    try std.testing.expect(!kept);
}

// Spec #12: .keep marker creation
test "keepGeneration creates marker" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);

    // Keep with a note
    try keepGeneration(allocator, profile_dir, 1, "Important release");

    // Verify marker exists
    try std.testing.expect(try isExplicitlyKept(allocator, profile_dir, 1));

    // Verify note exists
    const note_path = try std.fs.path.join(allocator, &.{ gen_path, KEEP_NOTE });
    defer allocator.free(note_path);
    std.fs.accessAbsolute(note_path, .{}) catch {
        return error.TestUnexpectedResult;
    };
}

// Spec #12: .keep marker removal
test "unkeepGeneration removes marker" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);

    try keepGeneration(allocator, profile_dir, 1, null);
    try std.testing.expect(try isExplicitlyKept(allocator, profile_dir, 1));

    try unkeepGeneration(allocator, profile_dir, 1);
    try std.testing.expect(!try isExplicitlyKept(allocator, profile_dir, 1));
}

// Spec #12: Retention policy - last K generations kept
test "getKeptGenerations returns last K generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create generations 1-5
    for ([_]u32{ 1, 2, 3, 4, 5 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        try std.fs.cwd().makePath(gen_path);
        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(allocator, gen_path, &manifest);
    }

    // With retention_count=2, should keep 4 and 5
    const kept = try getKeptGenerations(allocator, profile_dir, 2);
    defer allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expect(kept[0] == 4 or kept[0] == 5);
    try std.testing.expect(kept[1] == 4 or kept[1] == 5);
}

// Spec #12: Retention policy includes explicitly kept generations
test "getKeptGenerations includes explicitly kept" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create generations 1-5
    for ([_]u32{ 1, 2, 3, 4, 5 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        try std.fs.cwd().makePath(gen_path);
        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(allocator, gen_path, &manifest);
    }

    // Explicitly keep generation 1
    try keepGeneration(allocator, profile_dir, 1, null);

    // With retention_count=2, should keep 1 (explicit), 4, and 5 (recent)
    const kept = try getKeptGenerations(allocator, profile_dir, 2);
    defer allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 3), kept.len);
}

// Spec #12: GC root symlink management
test "updateRoots creates correct symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);

    // Create generations 1-3
    for ([_]u32{ 1, 2, 3 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        try std.fs.cwd().makePath(gen_path);
        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(allocator, gen_path, &manifest);
    }

    // Create current symlink in profile (simulating activation)
    var profile_handle = try std.fs.openDirAbsolute(profile_dir, .{});
    defer profile_handle.close();
    profile_handle.symLink("gen-3", "current", .{}) catch {};

    // Update roots with retention_count=2
    try updateRoots(allocator, gc_roots_dir, profile_dir, 2);

    // Check roots exist in the nested structure (profiles/system/kept/)
    const profile_gc_dir = try std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", "system" });
    defer allocator.free(profile_gc_dir);

    const roots = try listGenerationRoots(allocator, profile_gc_dir);
    defer allocator.free(roots);

    // Should have gen-2 and gen-3 (last 2)
    try std.testing.expectEqual(@as(usize, 2), roots.len);

    // Check current root exists at profiles/system/current
    const current_root = try std.fs.path.join(allocator, &.{ profile_gc_dir, "current" });
    defer allocator.free(current_root);
    std.fs.accessAbsolute(current_root, .{}) catch {
        return error.TestUnexpectedResult;
    };
}

// Spec #12: Generation deletion removes directory and GC root
test "deleteGeneration removes directory and root" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    // Create generations 1 and 2
    for ([_]u32{ 1, 2 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        try std.fs.cwd().makePath(gen_path);
        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(allocator, gen_path, &manifest);
    }

    // Activate generation 2
    var profile_handle = try std.fs.openDirAbsolute(profile_dir, .{});
    defer profile_handle.close();
    profile_handle.symLink("gen-2", "current", .{}) catch {};

    // Create root for generation 1 using the profile-specific gc dir
    const profile_gc_dir = try std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", "system" });
    defer allocator.free(profile_gc_dir);
    try ensureGenerationRoot(allocator, profile_gc_dir, profile_dir, 1);

    // Delete generation 1 (not active)
    try deleteGeneration(&test_env.ctx, gc_roots_dir, profile_dir, 1);

    // Verify directory is gone
    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    std.fs.accessAbsolute(gen1_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestUnexpectedResult;
}

// Spec #12: Cannot delete active generation
test "deleteGeneration fails for active generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    // Create and activate generation 1
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try std.fs.cwd().makePath(gen_path);
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try generation.writeManifest(allocator, gen_path, &manifest);

    var profile_handle = try std.fs.openDirAbsolute(profile_dir, .{});
    defer profile_handle.close();
    profile_handle.symLink("gen-1", "current", .{}) catch {};

    // Try to delete active generation - should fail
    const result = deleteGeneration(&test_env.ctx, gc_roots_dir, profile_dir, 1);
    try std.testing.expectError(GCRootsError.CannotDeleteActive, result);
}
