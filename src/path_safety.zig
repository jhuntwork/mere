const std = @import("std");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const PathSafetyError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput || error{
    ChainTooDeep, // Exceeded max depth (64)
    SymlinkLoop, // Detected cycle in symlink chain
    EscapesBoundary, // Symlink target escapes allowed boundary
    InvalidSymlink, // Malformed or unreadable symlink
};

pub const MAX_SYMLINK_DEPTH: u32 = 64;

pub const ResolveResult = struct {
    path: []const u8,
    is_symlink: bool,
    depth: u32,
};

pub fn resolveWithinBoundary(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    boundary: []const u8,
) PathSafetyError!ResolveResult {
    if (start_path.len == 0 or boundary.len == 0) {
        return PathSafetyError.InvalidInput;
    }
    if (!std.fs.path.isAbsolute(start_path) or !std.fs.path.isAbsolute(boundary)) {
        return PathSafetyError.InvalidInput;
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        visited.deinit();
    }

    var current: []const u8 = try allocator.dupe(u8, start_path);

    var depth: u32 = 0;

    while (depth < MAX_SYMLINK_DEPTH) {
        const normalized = normalizePath(allocator, current) catch |err| {
            allocator.free(current);
            return err;
        };
        allocator.free(current);
        current = normalized;

        if (!isWithinBoundary(current, boundary)) {
            allocator.free(current);
            return PathSafetyError.EscapesBoundary;
        }

        if (visited.contains(current)) {
            allocator.free(current);
            return PathSafetyError.SymlinkLoop;
        }

        const visited_key = allocator.dupe(u8, current) catch {
            allocator.free(current);
            return PathSafetyError.OutOfMemory;
        };
        visited.put(visited_key, {}) catch {
            allocator.free(visited_key);
            allocator.free(current);
            return PathSafetyError.OutOfMemory;
        };

        const target = readSymlinkAlloc(allocator, current) catch |err| {
            return switch (err) {
                error.NotLink => {
                    return ResolveResult{
                        .path = current,
                        .is_symlink = false,
                        .depth = depth,
                    };
                },
                error.OutOfMemory => {
                    allocator.free(current);
                    return PathSafetyError.OutOfMemory;
                },
                else => {
                    return ResolveResult{
                        .path = current,
                        .is_symlink = false,
                        .depth = depth,
                    };
                },
            };
        };
        defer allocator.free(target);

        const next_path = resolveSymlinkTarget(allocator, current, target) catch |err| {
            allocator.free(current);
            return err;
        };
        allocator.free(current);
        current = next_path;

        depth += 1;
    }

    allocator.free(current);
    return PathSafetyError.ChainTooDeep;
}

pub fn isWithinBoundary(p: []const u8, boundary: []const u8) bool {
    if (!std.mem.startsWith(u8, p, boundary)) {
        return false;
    }
    if (p.len > boundary.len) {
        return p[boundary.len] == '/';
    }
    return true;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) PathSafetyError![]const u8 {
    const resolved = std.fs.path.resolve(allocator, &[_][]const u8{path}) catch {
        return PathSafetyError.OutOfMemory;
    };
    return resolved;
}

fn resolveSymlinkTarget(
    allocator: std.mem.Allocator,
    symlink_path: []const u8,
    target: []const u8,
) PathSafetyError![]const u8 {
    if (std.fs.path.isAbsolute(target)) {
        return normalizePath(allocator, target);
    }

    const parent = std.fs.path.dirname(symlink_path) orelse "/";

    const joined = std.fs.path.join(allocator, &[_][]const u8{ parent, target }) catch {
        return PathSafetyError.OutOfMemory;
    };
    defer allocator.free(joined);

    return normalizePath(allocator, joined);
}

fn readSymlinkAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.readLinkAbsolute(path, &buf);
    return try allocator.dupe(u8, target);
}

pub fn validateStorePayload(
    allocator: std.mem.Allocator,
    store_root: []const u8,
) PathSafetyError!void {
    var dir = std.fs.openDirAbsolute(store_root, .{ .iterate = true }) catch {
        return PathSafetyError.FileSystem;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch {
        return PathSafetyError.OutOfMemory;
    };
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch {
            return PathSafetyError.FileSystem;
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind == .sym_link) {
            const full_path = std.fs.path.join(allocator, &[_][]const u8{ store_root, e.path }) catch {
                return PathSafetyError.OutOfMemory;
            };
            defer allocator.free(full_path);

            const result = try resolveWithinBoundary(allocator, full_path, store_root);
            allocator.free(result.path);
        }
    }
}

pub fn validateProfileSymlink(
    symlink_dest: []const u8,
    symlink_target: []const u8,
    profile_root: []const u8,
    store_root: []const u8,
) PathSafetyError!void {
    const alloc = std.heap.page_allocator;

    const normalized_dest = std.fs.path.resolve(alloc, &[_][]const u8{symlink_dest}) catch {
        return PathSafetyError.OutOfMemory;
    };
    defer alloc.free(normalized_dest);

    const normalized_target = std.fs.path.resolve(alloc, &[_][]const u8{symlink_target}) catch {
        return PathSafetyError.OutOfMemory;
    };
    defer alloc.free(normalized_target);

    const normalized_profile_root = std.fs.path.resolve(alloc, &[_][]const u8{profile_root}) catch {
        return PathSafetyError.OutOfMemory;
    };
    defer alloc.free(normalized_profile_root);

    const normalized_store_root = std.fs.path.resolve(alloc, &[_][]const u8{store_root}) catch {
        return PathSafetyError.OutOfMemory;
    };
    defer alloc.free(normalized_store_root);

    if (!isWithinBoundary(normalized_dest, normalized_profile_root)) {
        return PathSafetyError.EscapesBoundary;
    }

    if (!isWithinBoundary(normalized_target, normalized_store_root)) {
        return PathSafetyError.EscapesBoundary;
    }
}

// Tests

test "isWithinBoundary basic cases" {
    // Exact match
    try std.testing.expect(isWithinBoundary("/mere/store", "/mere/store"));

    // Subdirectory
    try std.testing.expect(isWithinBoundary("/mere/store/pkg", "/mere/store"));
    try std.testing.expect(isWithinBoundary("/mere/store/a/b/c", "/mere/store"));

    // Not within
    try std.testing.expect(!isWithinBoundary("/mere/other", "/mere/store"));
    try std.testing.expect(!isWithinBoundary("/etc/passwd", "/mere/store"));

    // Partial prefix (not a valid subdirectory)
    try std.testing.expect(!isWithinBoundary("/mere/store2", "/mere/store"));
    try std.testing.expect(!isWithinBoundary("/mere/storefoo", "/mere/store"));
}

test "normalizePath collapses dots" {
    const allocator = std.testing.allocator;

    const p1 = try normalizePath(allocator, "/a/b/../c");
    defer allocator.free(p1);
    try std.testing.expectEqualStrings("/a/c", p1);

    const p2 = try normalizePath(allocator, "/a/./b/./c");
    defer allocator.free(p2);
    try std.testing.expectEqualStrings("/a/b/c", p2);

    const p3 = try normalizePath(allocator, "/a//b///c");
    defer allocator.free(p3);
    try std.testing.expectEqualStrings("/a/b/c", p3);
}

test "resolveSymlinkTarget absolute target" {
    const allocator = std.testing.allocator;

    const result = try resolveSymlinkTarget(allocator, "/foo/bar/link", "/absolute/target");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/absolute/target", result);
}

test "resolveSymlinkTarget relative target" {
    const allocator = std.testing.allocator;

    const result = try resolveSymlinkTarget(allocator, "/foo/bar/link", "../baz");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/foo/baz", result);
}

test "resolveWithinBoundary rejects escape via .." {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create directory structure
    const boundary = try std.fs.path.join(allocator, &.{ test_env.path, "boundary" });
    defer allocator.free(boundary);
    const subdir = try std.fs.path.join(allocator, &.{ boundary, "subdir" });
    defer allocator.free(subdir);
    try std.fs.cwd().makePath(subdir);

    // Create a symlink that escapes via ..
    const escape_link = try std.fs.path.join(allocator, &.{ subdir, "escape" });
    defer allocator.free(escape_link);

    // Create symlink pointing outside boundary
    var dir = try std.fs.openDirAbsolute(subdir, .{});
    defer dir.close();
    try dir.symLink("../../outside", "escape", .{});

    // Should fail with EscapesBoundary
    const result = resolveWithinBoundary(allocator, escape_link, boundary);
    try std.testing.expectError(PathSafetyError.EscapesBoundary, result);
}

test "resolveWithinBoundary succeeds for valid internal symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create directory structure
    const boundary = try std.fs.path.join(allocator, &.{ test_env.path, "boundary" });
    defer allocator.free(boundary);
    const subdir = try std.fs.path.join(allocator, &.{ boundary, "subdir" });
    defer allocator.free(subdir);
    try std.fs.cwd().makePath(subdir);

    // Create a target file
    const target_file = try std.fs.path.join(allocator, &.{ boundary, "target.txt" });
    defer allocator.free(target_file);
    {
        var f = try std.fs.createFileAbsolute(target_file, .{});
        f.close();
    }

    // Create symlink pointing to target within boundary
    const link_path = try std.fs.path.join(allocator, &.{ subdir, "link" });
    defer allocator.free(link_path);

    var dir = try std.fs.openDirAbsolute(subdir, .{});
    defer dir.close();
    try dir.symLink("../target.txt", "link", .{});

    // Should succeed
    const result = try resolveWithinBoundary(allocator, link_path, boundary);
    defer allocator.free(result.path);

    try std.testing.expectEqualStrings(target_file, result.path);
    try std.testing.expect(!result.is_symlink);
    try std.testing.expectEqual(@as(u32, 1), result.depth);
}

test "resolveWithinBoundary detects loops" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create directory
    const dir_path = try std.fs.path.join(allocator, &.{ test_env.path, "loopdir" });
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    // Create symlink loop: a -> b, b -> a
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    try dir.symLink("b", "a", .{});
    try dir.symLink("a", "b", .{});

    const link_a = try std.fs.path.join(allocator, &.{ dir_path, "a" });
    defer allocator.free(link_a);

    // Should fail with SymlinkLoop
    const result = resolveWithinBoundary(allocator, link_a, dir_path);
    try std.testing.expectError(PathSafetyError.SymlinkLoop, result);
}

test "validateProfileSymlink rejects destination outside profile" {
    const result = validateProfileSymlink(
        "/etc/passwd", // outside profile
        "/mere/store/pkg/file",
        "/mere/profiles/system/gen-1",
        "/mere/store",
    );
    try std.testing.expectError(PathSafetyError.EscapesBoundary, result);
}

test "validateProfileSymlink rejects target outside store" {
    const result = validateProfileSymlink(
        "/mere/profiles/system/gen-1/bin/foo",
        "/etc/evil", // outside store
        "/mere/profiles/system/gen-1",
        "/mere/store",
    );
    try std.testing.expectError(PathSafetyError.EscapesBoundary, result);
}

test "validateProfileSymlink accepts valid symlink" {
    try validateProfileSymlink(
        "/mere/profiles/system/gen-1/bin/foo",
        "/mere/store/abc123-pkg-1.0/bin/foo",
        "/mere/profiles/system/gen-1",
        "/mere/store",
    );
}

test "validateProfileSymlink rejects normalized destination escape" {
    const result = validateProfileSymlink(
        "/mere/profiles/system/gen-1/../outside/bin/foo",
        "/mere/store/abc123-pkg-1.0/bin/foo",
        "/mere/profiles/system/gen-1",
        "/mere/store",
    );
    try std.testing.expectError(PathSafetyError.EscapesBoundary, result);
}

test "validateProfileSymlink rejects normalized target escape" {
    const result = validateProfileSymlink(
        "/mere/profiles/system/gen-1/bin/foo",
        "/mere/store/../etc/evil",
        "/mere/profiles/system/gen-1",
        "/mere/store",
    );
    try std.testing.expectError(PathSafetyError.EscapesBoundary, result);
}

test "validateStorePayload with valid symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create a mock store root
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);
    const lib_dir = try std.fs.path.join(allocator, &.{ store_root, "lib" });
    defer allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    // Create a real file
    const real_file = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so.1.0" });
    defer allocator.free(real_file);
    {
        var f = try std.fs.createFileAbsolute(real_file, .{});
        f.close();
    }

    // Create internal symlinks (valid)
    var dir = try std.fs.openDirAbsolute(lib_dir, .{});
    defer dir.close();
    try dir.symLink("libfoo.so.1.0", "libfoo.so.1", .{});
    try dir.symLink("libfoo.so.1", "libfoo.so", .{});

    // Validation should pass
    try validateStorePayload(allocator, store_root);
}

test "validateStorePayload rejects escaping symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create a mock store root
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    // Create a symlink that escapes
    var dir = try std.fs.openDirAbsolute(store_root, .{});
    defer dir.close();
    try dir.symLink("/etc/passwd", "escape", .{});

    // Validation should fail
    const result = validateStorePayload(allocator, store_root);
    try std.testing.expectError(PathSafetyError.EscapesBoundary, result);
}
