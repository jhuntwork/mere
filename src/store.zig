const std = @import("std");
const Context = @import("mere.zig").Context;
const errors = @import("errors.zig");
const path_safety = @import("path_safety.zig");

/// Store operations error set
const Std = errors.StandardErrors;
pub const StoreError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{SymlinkEscapesBoundary};

/// Construct a content-addressed store path from components.
///
/// Format: `<root>/mere/store/<hash>-<name>-<version>/`
///
/// Where:
/// - hash is 64 lowercase hex characters (full BLAKE3 output)
/// - name is the package name
/// - version is the package version (no release number)
///
/// Returns an allocated path string (caller owns, must free with ctx.allocator).
pub fn constructStorePath(
    ctx: *Context,
    content_hash: []const u8,
    name: []const u8,
    version: []const u8,
) StoreError![]const u8 {
    // Validate hash length (must be 64 hex chars)
    if (content_hash.len != 64) {
        return StoreError.InvalidInput;
    }

    // Validate all characters are lowercase hex.
    for (content_hash) |c| {
        const is_lower_hex = (c >= 'a' and c <= 'f') or std.ascii.isDigit(c);
        if (!is_lower_hex) {
            return StoreError.InvalidInput;
        }
    }

    // Construct store directory name: <hash>-<name>-<version>
    const store_dir_name = std.fmt.allocPrint(ctx.allocator, "{s}-{s}-{s}", .{ content_hash, name, version }) catch {
        return StoreError.OutOfMemory;
    };
    defer ctx.allocator.free(store_dir_name);

    // Join with root path
    return std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store", store_dir_name }) catch {
        return StoreError.OutOfMemory;
    };
}

/// Parse a store path to extract the content hash, name, and version.
///
/// Input format: `<root>/mere/store/<hash>-<name>-<version>/`
///
/// Returns the parsed components. All returned strings are slices into the input
/// (no allocation needed).
pub const StorePathComponents = struct {
    content_hash: []const u8,
    name: []const u8,
    version: []const u8,
};

pub fn parseStorePath(store_path: []const u8) StoreError!StorePathComponents {
    if (!std.fs.path.isAbsolute(store_path)) {
        return StoreError.InvalidInput;
    }

    const parent = std.fs.path.dirname(store_path) orelse {
        return StoreError.InvalidInput;
    };
    if (!std.mem.endsWith(u8, parent, "/mere/store")) {
        return StoreError.InvalidInput;
    }

    // Extract the basename (last component)
    const basename = std.fs.path.basename(store_path);

    // Hash is exactly 64 characters followed by '-'
    if (basename.len < 66) { // 64 + '-' + at least 1 char for name
        return StoreError.InvalidInput;
    }

    const hash_part = basename[0..64];

    // Validate lowercase hash characters
    for (hash_part) |c| {
        const is_lower_hex = (c >= 'a' and c <= 'f') or std.ascii.isDigit(c);
        if (!is_lower_hex) {
            return StoreError.InvalidInput;
        }
    }

    // Must have separator after hash
    if (basename[64] != '-') {
        return StoreError.InvalidInput;
    }

    // Find the last '-' to separate name from version
    const rest = basename[65..];
    const last_dash = std.mem.lastIndexOf(u8, rest, "-") orelse {
        return StoreError.InvalidInput;
    };

    const name = rest[0..last_dash];
    const version = rest[last_dash + 1 ..];

    if (name.len == 0 or version.len == 0) {
        return StoreError.InvalidInput;
    }

    return .{
        .content_hash = hash_part,
        .name = name,
        .version = version,
    };
}

/// Check if a store path exists and is valid.
pub fn storePathExists(store_path: []const u8) bool {
    std.fs.accessAbsolute(store_path, .{}) catch {
        return false;
    };
    return true;
}

/// Check if the current process is running with root privileges
pub fn isPrivileged() bool {
    return std.posix.getuid() == 0 and std.posix.geteuid() == 0;
}

/// Harden a store object for system use by changing ownership and permissions
///
/// This function:
/// 1. Validates the store path is within the store boundary
/// 2. Recursively changes ownership to root:root (0:0)
/// 3. Sets read-only permissions
/// 4. Validates all symlinks stay within boundaries
///
/// Should only be called when isPrivileged() returns true.
pub fn hardenStoreObject(
    ctx: *Context,
    store_path: []const u8,
) StoreError!void {
    if (!isPrivileged()) {
        return ctx.fail(StoreError.PermissionDenied, store_path, "not running as root");
    }

    // Validate store_path is within /mere/store
    const store_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to construct store root path");
    };
    defer ctx.allocator.free(store_dir);

    if (!std.fs.path.isAbsolute(store_path)) {
        return ctx.fail(StoreError.InvalidInput, store_path, "store path must be absolute");
    }

    const normalized_store_dir = std.fs.path.resolve(ctx.allocator, &.{store_dir}) catch {
        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to normalize store root path");
    };
    defer ctx.allocator.free(normalized_store_dir);

    const normalized_store_path = std.fs.path.resolve(ctx.allocator, &.{store_path}) catch {
        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to normalize store path");
    };
    defer ctx.allocator.free(normalized_store_path);

    if (!path_safety.isWithinBoundary(normalized_store_path, normalized_store_dir)) {
        return ctx.fail(StoreError.InvalidInput, store_path, "not within store boundary");
    }

    // Open the store object directory
    var dir = std.fs.openDirAbsolute(store_path, .{ .iterate = true }) catch {
        return ctx.fail(StoreError.FileSystem, store_path, "failed to open store directory");
    };
    defer dir.close();

    // Walk the directory tree using lstat (don't follow symlinks)
    try hardenDirectory(ctx, dir, store_path, store_path);
}

/// Recursively harden a directory
fn hardenDirectory(
    ctx: *Context,
    dir: std.fs.Dir,
    dir_path: []const u8,
    store_root: []const u8,
) StoreError!void {
    const dir_stat = dir.stat() catch {
        return ctx.fail(StoreError.FileSystem, dir_path, "failed to stat directory");
    };
    const dir_mode = dir_stat.mode & ~@as(std.fs.File.Mode, 0o222);

    // Capture mode before chown. Linux clears setuid/setgid on ownership change,
    // so we must restore the packaged mode after changing owner.
    std.posix.fchown(dir.fd, 0, 0) catch {
        return ctx.fail(StoreError.PermissionDenied, dir_path, "failed to change ownership of directory");
    };
    dir.chmod(dir_mode) catch {
        return ctx.fail(StoreError.PermissionDenied, dir_path, "failed to chmod directory to read-only");
    };

    // Iterate through directory contents
    var iter = dir.iterate();
    while (iter.next() catch {
        return ctx.fail(StoreError.FileSystem, dir_path, "failed to iterate directory");
    }) |entry| {
        const entry_path = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.name }) catch {
            return ctx.fail(StoreError.OutOfMemory, dir_path, "failed to allocate path for directory entry");
        };
        defer ctx.allocator.free(entry_path);

        switch (entry.kind) {
            .directory => {
                // Recursively harden subdirectory
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch {
                    return ctx.fail(StoreError.FileSystem, entry_path, "failed to open subdirectory");
                };
                defer subdir.close();

                try hardenDirectory(ctx, subdir, entry_path, store_root);
            },
            .file => {
                // Open file to get handle for operations
                var file = dir.openFile(entry.name, .{ .mode = .read_only }) catch {
                    return ctx.fail(StoreError.FileSystem, entry_path, "failed to open file");
                };
                defer file.close();

                const stat = file.stat() catch {
                    return ctx.fail(StoreError.FileSystem, entry_path, "failed to stat file");
                };
                const new_mode = stat.mode & ~@as(std.fs.File.Mode, 0o222);

                // Capture mode before chown. Linux clears setuid/setgid on
                // ownership change, so restore the packaged mode afterward.
                std.posix.fchown(file.handle, 0, 0) catch {
                    return ctx.fail(StoreError.PermissionDenied, entry_path, "failed to change file ownership");
                };
                file.chmod(new_mode) catch {
                    return ctx.fail(StoreError.PermissionDenied, entry_path, "failed to chmod file");
                };
            },
            .sym_link => {
                const result = path_safety.resolveWithinBoundary(ctx.allocator, entry_path, store_root) catch |err| {
                    const detail = switch (err) {
                        path_safety.PathSafetyError.EscapesBoundary => "symlink escapes store boundary",
                        path_safety.PathSafetyError.SymlinkLoop => "symlink loop detected",
                        path_safety.PathSafetyError.ChainTooDeep => "symlink chain too deep",
                        path_safety.PathSafetyError.InvalidSymlink => "invalid symlink",
                        path_safety.PathSafetyError.InvalidInput => "invalid symlink path",
                        path_safety.PathSafetyError.FileSystem => "failed to read symlink",
                        path_safety.PathSafetyError.OutOfMemory => "out of memory",
                    };
                    return ctx.fail(switch (err) {
                        path_safety.PathSafetyError.EscapesBoundary,
                        path_safety.PathSafetyError.SymlinkLoop,
                        path_safety.PathSafetyError.ChainTooDeep,
                        path_safety.PathSafetyError.InvalidSymlink,
                        => StoreError.SymlinkEscapesBoundary,
                        path_safety.PathSafetyError.InvalidInput => StoreError.InvalidInput,
                        path_safety.PathSafetyError.FileSystem => StoreError.FileSystem,
                        path_safety.PathSafetyError.OutOfMemory => StoreError.OutOfMemory,
                    }, entry_path, detail);
                };
                ctx.allocator.free(result.path);

                // Note: We don't change symlink ownership itself because:
                // 1. The symlink target is validated to be within store_root
                // 2. The target files/dirs are already hardened above
                // 3. Symlink ownership doesn't affect security of the target
                // If needed in future, can use openat with O_PATH|O_NOFOLLOW and fchown
            },
            else => {
                // Ignore other types
            },
        }
    }
}

// Tests

// Spec #4.1: Store path format validation
test "constructStorePath creates correct format" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    const hash = "a" ** 64; // 64 'a' characters
    const store_path = try constructStorePath(&ctx, hash, "nginx", "1.24.0");
    defer ctx.allocator.free(store_path);

    // Check that path contains expected components
    try std.testing.expect(std.mem.indexOf(u8, store_path, "mere/store/") != null);
    try std.testing.expect(std.mem.indexOf(u8, store_path, hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, store_path, "-nginx-1.24.0") != null);
}

// Spec #4.1: Store path format validation
test "constructStorePath rejects invalid hash length" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    // Too short
    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, "abc", "test", "1.0"));

    // Too long
    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, "a" ** 65, "test", "1.0"));
}

// Spec #4.1: Store path format validation
test "constructStorePath rejects non-hex characters" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    // Contains 'g' which is not hex
    const bad_hash = "g" ** 64;
    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, bad_hash, "test", "1.0"));
}

test "constructStorePath rejects uppercase hash" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, "A" ** 64, "test", "1.0"));
}

test "parseStorePath extracts components correctly" {
    const path = "/mere/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nginx-1.24.0";
    const components = try parseStorePath(path);

    try std.testing.expectEqualStrings("a" ** 64, components.content_hash);
    try std.testing.expectEqualStrings("nginx", components.name);
    try std.testing.expectEqualStrings("1.24.0", components.version);
}

test "parseStorePath handles package names with hyphens" {
    const path = "/mere/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-my-package-name-2.0.0";
    const components = try parseStorePath(path);

    try std.testing.expectEqualStrings("b" ** 64, components.content_hash);
    try std.testing.expectEqualStrings("my-package-name", components.name);
    try std.testing.expectEqualStrings("2.0.0", components.version);
}

test "parseStorePath rejects invalid paths" {
    // Too short
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("short"));

    // No separator after hash
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    // Missing version (no second dash in rest)
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nameonly"));

    // Not under /mere/store
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("/tmp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-name-1.0"));

    // Uppercase hash is not canonical
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("/mere/store/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-name-1.0"));
}

test "storePathExists returns correct values" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Existing path
    try std.testing.expect(storePathExists(test_env.path));

    // Non-existing path
    try std.testing.expect(!storePathExists("/nonexistent/path/12345"));
}

test "isPrivileged detects root" {
    const is_root = isPrivileged();
    // Can't test both cases in single test, just verify it returns a bool
    _ = is_root;
}

// Spec #4.1: Store hardening validates store boundary
test "hardenStoreObject validates store boundary" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    // Create a path outside the store
    const outside_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "not-store" });
    defer ctx.allocator.free(outside_path);
    try std.fs.cwd().makePath(outside_path);

    // Should reject paths outside store
    if (isPrivileged()) {
        try std.testing.expectError(StoreError.InvalidInput, hardenStoreObject(ctx, outside_path));
    }
    // If not privileged, expect PermissionDenied
    else {
        try std.testing.expectError(StoreError.PermissionDenied, hardenStoreObject(ctx, outside_path));
    }
}

test "hardenStoreObject rejects sibling-prefix path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const sibling_path = try std.fs.path.join(ctx.allocator, &.{
        test_env.path,
        "mere",
        "store-evil",
        "a" ** 64 ++ "-pkg-1.0.0",
    });
    defer ctx.allocator.free(sibling_path);
    try std.fs.cwd().makePath(sibling_path);

    if (isPrivileged()) {
        try std.testing.expectError(StoreError.InvalidInput, hardenStoreObject(ctx, sibling_path));
    } else {
        try std.testing.expectError(StoreError.PermissionDenied, hardenStoreObject(ctx, sibling_path));
    }
}

// Spec #4.1: Store hardening requires root privileges
test "hardenStoreObject requires privilege" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    // Create a valid store path
    const hash = "a" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash ++ "-test-1.0" });
    defer ctx.allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    if (!isPrivileged()) {
        // Non-root should get PermissionDenied
        try std.testing.expectError(StoreError.PermissionDenied, hardenStoreObject(ctx, store_path));
    }
    // Can't fully test root behavior in unprivileged test
}

// Spec #7: Symlink validation (max depth, loop detection, boundary checking)
test "path safety rejects escapes, loops, and deep chains" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);

    const store_path = try std.fs.path.join(allocator, &.{ store_root, "a" ** 64 ++ "-test-1.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // 1) Escaping symlink
    const escape_link = try std.fs.path.join(allocator, &.{ store_path, "escape_link" });
    defer allocator.free(escape_link);
    try std.posix.symlinkat("/etc/passwd", std.fs.cwd().fd, escape_link);
    try std.testing.expectError(
        path_safety.PathSafetyError.EscapesBoundary,
        path_safety.resolveWithinBoundary(allocator, escape_link, store_path),
    );

    // 2) Symlink loop
    const loop_a = try std.fs.path.join(allocator, &.{ store_path, "loop_a" });
    defer allocator.free(loop_a);
    const loop_b = try std.fs.path.join(allocator, &.{ store_path, "loop_b" });
    defer allocator.free(loop_b);
    try std.posix.symlinkat("loop_b", std.fs.cwd().fd, loop_a);
    try std.posix.symlinkat("loop_a", std.fs.cwd().fd, loop_b);
    try std.testing.expectError(
        path_safety.PathSafetyError.SymlinkLoop,
        path_safety.resolveWithinBoundary(allocator, loop_a, store_path),
    );

    // 3) Chain too deep
    const prev = try std.fmt.allocPrint(allocator, "{s}/chain_0", .{store_path});
    defer allocator.free(prev);
    try std.posix.symlinkat("chain_1", std.fs.cwd().fd, prev);

    var idx: u32 = 1;
    while (idx <= path_safety.MAX_SYMLINK_DEPTH + 1) : (idx += 1) {
        const current = try std.fmt.allocPrint(allocator, "{s}/chain_{d}", .{ store_path, idx });
        defer allocator.free(current);
        const next = try std.fmt.allocPrint(allocator, "chain_{d}", .{idx + 1});
        defer allocator.free(next);
        try std.posix.symlinkat(next, std.fs.cwd().fd, current);
    }
    try std.testing.expectError(
        path_safety.PathSafetyError.ChainTooDeep,
        path_safety.resolveWithinBoundary(allocator, prev, store_path),
    );

    // 4) Valid in-store link
    const data_file = try std.fs.path.join(allocator, &.{ store_path, "data.txt" });
    defer allocator.free(data_file);
    {
        var f = try std.fs.createFileAbsolute(data_file, .{});
        try f.writeAll("ok");
        f.close();
    }
    const ok_link = try std.fs.path.join(allocator, &.{ store_path, "ok_link" });
    defer allocator.free(ok_link);
    try std.posix.symlinkat("data.txt", std.fs.cwd().fd, ok_link);
    {
        const result = try path_safety.resolveWithinBoundary(allocator, ok_link, store_path);
        defer allocator.free(result.path);
    }

    // 5) Broken link is allowed
    const broken = try std.fs.path.join(allocator, &.{ store_path, "broken_link" });
    defer allocator.free(broken);
    try std.posix.symlinkat("missing.txt", std.fs.cwd().fd, broken);
    {
        const result = try path_safety.resolveWithinBoundary(allocator, broken, store_path);
        defer allocator.free(result.path);
    }
}

// Spec #7: Symlink validation (escaping store root boundary)
// Spec #4.1: Store hardening validates symlinks
test "hardenStoreObject detects escaping symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    if (!isPrivileged()) {
        // Skip test if not root
        return error.SkipZigTest;
    }

    // Create store path with escaping symlink
    const hash = "b" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash ++ "-escape-1.0" });
    defer ctx.allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Create a symlink that escapes
    const link_path = try std.fs.path.join(ctx.allocator, &.{ store_path, "escape_link" });
    defer ctx.allocator.free(link_path);

    const outside_target = "/etc/passwd";
    try std.posix.symlinkat(outside_target, std.fs.cwd().fd, link_path);

    // Should detect escape
    try std.testing.expectError(StoreError.SymlinkEscapesBoundary, hardenStoreObject(ctx, store_path));
}

// Spec #4.1: Store admission idempotence (collision handling)
test "store admission handles existing path idempotently" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    // Create a store path that already exists
    const hash = "c" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash ++ "-existing-1.0" });
    defer ctx.allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Create a file in the existing store path to verify it's not empty
    const test_file = try std.fs.path.join(ctx.allocator, &.{ store_path, "test.txt" });
    defer ctx.allocator.free(test_file);
    var file = try std.fs.createFileAbsolute(test_file, .{});
    try file.writeAll("existing content");
    file.close();

    // Verify the path exists
    try std.testing.expect(storePathExists(store_path));

    // Create a staging directory to simulate a second admission attempt
    const staging_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "staging" });
    defer ctx.allocator.free(staging_path);
    try std.fs.cwd().makePath(staging_path);

    const staging_file = try std.fs.path.join(ctx.allocator, &.{ staging_path, "test.txt" });
    defer ctx.allocator.free(staging_file);
    var staging_f = try std.fs.createFileAbsolute(staging_file, .{});
    try staging_f.writeAll("new content");
    staging_f.close();

    // Attempt atomic rename (simulating store admission) using std.posix.renameZ
    // which properly converts raw syscall results to Zig errors
    const staging_z = try ctx.allocator.dupeZ(u8, staging_path);
    defer ctx.allocator.free(staging_z);
    const store_z = try ctx.allocator.dupeZ(u8, store_path);
    defer ctx.allocator.free(store_z);

    // Should fail with PathAlreadyExists (EEXIST/ENOTEMPTY mapped by std.posix)
    try std.testing.expectError(error.PathAlreadyExists, std.posix.renameZ(staging_z, store_z));

    // Original store path should still exist with original content
    try std.testing.expect(storePathExists(store_path));
    var verify_file = try std.fs.openFileAbsolute(test_file, .{});
    defer verify_file.close();
    var buf: [100]u8 = undefined;
    const n = try verify_file.readAll(&buf);
    try std.testing.expectEqualStrings("existing content", buf[0..n]);

    // Clean up staging directory (simulating what install.zig does)
    std.fs.deleteTreeAbsolute(staging_path) catch {};
}

// Spec #7: Relative symlink that stays within boundary is accepted
test "resolveWithinBoundary accepts relative symlink within store" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create a store-like directory structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);

    const store_path = try std.fs.path.join(allocator, &.{ store_root, "d" ** 64 ++ "-reltest-1.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Create a subdirectory with a real file
    const lib_dir = try std.fs.path.join(allocator, &.{ store_path, "lib" });
    defer allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    const real_file = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so.1.0" });
    defer allocator.free(real_file);
    {
        var f = try std.fs.createFileAbsolute(real_file, .{});
        try f.writeAll("ELF...");
        f.close();
    }

    // Create a relative symlink: lib/libfoo.so -> libfoo.so.1.0
    const rel_link = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so" });
    defer allocator.free(rel_link);
    try std.posix.symlinkat("libfoo.so.1.0", std.fs.cwd().fd, rel_link);

    // resolveWithinBoundary should accept this relative symlink
    const result = try path_safety.resolveWithinBoundary(allocator, rel_link, store_path);
    defer allocator.free(result.path);

    // The resolved path should be within the store boundary
    try std.testing.expect(path_safety.isWithinBoundary(result.path, store_path));
}
