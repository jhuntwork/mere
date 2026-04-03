const std = @import("std");
const Context = @import("mere.zig").Context;
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
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
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), store_path, .{}) catch {
        return false;
    };
    return true;
}

/// Check if the current process is running with root privileges
pub fn isPrivileged() bool {
    return std.os.linux.geteuid() == 0;
}

/// Check if a store path has already been hardened (root-owned + immutable flag).
pub fn isHardened(store_path: []const u8) bool {
    const io = path_mod.currentIo();
    var dir = std.Io.Dir.openDirAbsolute(io, store_path, .{}) catch return false;
    defer dir.close(io);

    // Check root ownership
    const store_path_z = std.posix.toPosixPath(store_path) catch return false;
    var statx = std.mem.zeroes(std.os.linux.Statx);
    if (std.os.linux.errno(std.os.linux.statx(
        std.posix.AT.FDCWD,
        &store_path_z,
        0,
        .{ .UID = true },
        &statx,
    )) != .SUCCESS) return false;
    if (statx.uid != 0) return false;

    // Check immutable flag
    var flags: u64 = 0;
    if (std.os.linux.errno(std.os.linux.ioctl(dir.handle, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) {
        // Filesystem doesn't support flags — fall back to ownership + permissions check.
        // Root-owned + read-only is the hardened state on these filesystems.
        const stat = dir.stat(path_mod.currentIo()) catch return false;
        return (stat.permissions.toMode() & 0o222) == 0;
    }
    return (flags & FS_IMMUTABLE_FL) != 0;
}

// --- Store hardening ---

fn ior(typ: u8, nr: u8, comptime T: type) u32 {
    return (0x80 << 24) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, typ) << 8) | nr;
}
fn iow(typ: u8, nr: u8, comptime T: type) u32 {
    return (0x40 << 24) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, typ) << 8) | nr;
}

const FS_IOC_GETFLAGS = ior('f', 1, c_long);
const FS_IOC_SETFLAGS = iow('f', 2, c_long);
const FS_IMMUTABLE_FL: u64 = 0x00000010;

pub const HardenResult = struct {
    files_processed: usize = 0,
    immutable_supported: bool = true,
};

fn setImmutable(fd: std.posix.fd_t) bool {
    var flags: u64 = 0;
    if (std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) return false;
    flags |= FS_IMMUTABLE_FL;
    return std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_SETFLAGS, @intFromPtr(&flags))) == .SUCCESS;
}

fn clearImmutableFlag(fd: std.posix.fd_t) bool {
    var flags: u64 = 0;
    if (std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) return false;
    flags &= ~FS_IMMUTABLE_FL;
    return std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_SETFLAGS, @intFromPtr(&flags))) == .SUCCESS;
}

/// Harden a store object for system use.
///
/// 1. Validates the caller is root
/// 2. Validates the store path is within the store boundary
/// 3. Recursively: chown root:root, chmod read-only, set FS_IMMUTABLE_FL
/// 4. Validates all symlinks stay within the store path boundary
pub fn harden(ctx: *Context, store_path: []const u8) StoreError!HardenResult {
    if (std.c.getenv("MERE_NO_HARDEN")) |_| return .{};

    if (!isPrivileged()) {
        return ctx.fail(StoreError.PermissionDenied, store_path, "not running as root");
    }

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

    const io = path_mod.currentIo();
    var dir = path_mod.openExistingDir(store_path) catch {
        return ctx.fail(StoreError.FileSystem, store_path, "failed to open store directory");
    };
    defer dir.close(io);

    var result = HardenResult{};

    var walker = dir.walk(ctx.allocator) catch return StoreError.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch return StoreError.FileSystem) |entry| {
        switch (entry.kind) {
            .directory => {
                var subdir = dir.openDir(io, entry.path, .{ .iterate = true }) catch {
                    const p = std.fs.path.join(ctx.allocator, &.{ store_path, entry.path }) catch
                        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to allocate path");
                    defer ctx.allocator.free(p);
                    return ctx.fail(StoreError.FileSystem, p, "failed to open subdirectory");
                };
                defer subdir.close(io);
                hardenDir(io, subdir, &result);
            },
            .file => {
                var file = dir.openFile(io, entry.path, .{}) catch {
                    const p = std.fs.path.join(ctx.allocator, &.{ store_path, entry.path }) catch
                        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to allocate path");
                    defer ctx.allocator.free(p);
                    return ctx.fail(StoreError.FileSystem, p, "failed to open file");
                };
                defer file.close(io);
                hardenFile(io, file, &result);
            },
            .sym_link => {
                const entry_path = std.fs.path.join(ctx.allocator, &.{ store_path, entry.path }) catch {
                    return ctx.fail(StoreError.OutOfMemory, store_path, "failed to allocate symlink path");
                };
                defer ctx.allocator.free(entry_path);

                const symlink_result = path_safety.resolveWithinBoundary(ctx.allocator, entry_path, store_path) catch |err| {
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
                ctx.allocator.free(symlink_result.path);

                const path_z = std.posix.toPosixPath(entry.path) catch continue;
                _ = std.os.linux.fchownat(dir.handle, &path_z, 0, 0, std.os.linux.AT.SYMLINK_NOFOLLOW);
            },
            else => {},
        }
    }

    hardenDir(io, dir, &result);
    return result;
}

fn stripWriteBits(io: std.Io, handle: anytype) void {
    if (handle.stat(io)) |st| {
        const new_mode = st.permissions.toMode() & ~@as(std.posix.mode_t, 0o222);
        handle.setPermissions(io, .fromMode(new_mode)) catch {};
    } else |_| {}
}

fn hardenDir(io: std.Io, d: std.Io.Dir, result: *HardenResult) void {
    _ = std.os.linux.fchown(d.handle, 0, 0);
    stripWriteBits(io, d);
    if (!setImmutable(d.handle)) result.immutable_supported = false;
    result.files_processed += 1;
}

fn hardenFile(io: std.Io, f: std.Io.File, result: *HardenResult) void {
    _ = std.os.linux.fchown(f.handle, 0, 0);
    stripWriteBits(io, f);
    if (!setImmutable(f.handle)) result.immutable_supported = false;
    result.files_processed += 1;
}

/// Recursively clear filesystem immutable flags on a store path.
/// Must be called before deletion (GC).
pub fn clearImmutable(allocator: std.mem.Allocator, store_path: []const u8) HardenResult {
    const io = path_mod.currentIo();
    var result = HardenResult{};

    {
        var top = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return result;
        _ = clearImmutableFlag(top.handle);
        top.close(io);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return result;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return result;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                var subdir = dir.openDir(io, entry.path, .{ .iterate = true }) catch continue;
                defer subdir.close(io);
                if (!clearImmutableFlag(subdir.handle)) result.immutable_supported = false;
                result.files_processed += 1;
            },
            .file => {
                var file = dir.openFile(io, entry.path, .{}) catch continue;
                defer file.close(io);
                if (!clearImmutableFlag(file.handle)) result.immutable_supported = false;
                result.files_processed += 1;
            },
            else => {},
        }
    }

    return result;
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
    try path_mod.ensureDirExists(store_path);

    // 1) Escaping symlink
    const escape_link = try std.fs.path.join(allocator, &.{ store_path, "escape_link" });
    defer allocator.free(escape_link);
    try std.Io.Dir.symLinkAbsolute(path_mod.currentIo(), "/etc/passwd", escape_link, .{});
    try std.testing.expectError(
        path_safety.PathSafetyError.EscapesBoundary,
        path_safety.resolveWithinBoundary(allocator, escape_link, store_path),
    );

    // 2) Symlink loop
    const loop_a = try std.fs.path.join(allocator, &.{ store_path, "loop_a" });
    defer allocator.free(loop_a);
    const loop_b = try std.fs.path.join(allocator, &.{ store_path, "loop_b" });
    defer allocator.free(loop_b);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "loop_b", "loop_a", .{});
        try store_dir_handle.symLink(path_mod.currentIo(), "loop_a", "loop_b", .{});
    }
    try std.testing.expectError(
        path_safety.PathSafetyError.SymlinkLoop,
        path_safety.resolveWithinBoundary(allocator, loop_a, store_path),
    );

    // 3) Chain too deep
    const prev = try std.fmt.allocPrint(allocator, "{s}/chain_0", .{store_path});
    defer allocator.free(prev);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "chain_1", "chain_0", .{});
    }

    var idx: u32 = 1;
    while (idx <= path_safety.MAX_SYMLINK_DEPTH + 1) : (idx += 1) {
        const current = try std.fmt.allocPrint(allocator, "{s}/chain_{d}", .{ store_path, idx });
        defer allocator.free(current);
        const next = try std.fmt.allocPrint(allocator, "chain_{d}", .{idx + 1});
        defer allocator.free(next);
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        const current_name = try std.fmt.allocPrint(allocator, "chain_{d}", .{idx});
        defer allocator.free(current_name);
        try store_dir_handle.symLink(path_mod.currentIo(), next, current_name, .{});
    }
    try std.testing.expectError(
        path_safety.PathSafetyError.ChainTooDeep,
        path_safety.resolveWithinBoundary(allocator, prev, store_path),
    );

    // 4) Valid in-store link
    const data_file = try std.fs.path.join(allocator, &.{ store_path, "data.txt" });
    defer allocator.free(data_file);
    {
        var f = try path_mod.makePathAndOpenFile(data_file);
        try f.writeStreamingAll(path_mod.currentIo(), "ok");
        f.close(path_mod.currentIo());
    }
    const ok_link = try std.fs.path.join(allocator, &.{ store_path, "ok_link" });
    defer allocator.free(ok_link);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "data.txt", "ok_link", .{});
    }
    {
        const result = try path_safety.resolveWithinBoundary(allocator, ok_link, store_path);
        defer allocator.free(result.path);
    }

    // 5) Broken link is allowed
    const broken = try std.fs.path.join(allocator, &.{ store_path, "broken_link" });
    defer allocator.free(broken);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "missing.txt", "broken_link", .{});
    }
    {
        const result = try path_safety.resolveWithinBoundary(allocator, broken, store_path);
        defer allocator.free(result.path);
    }
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
    try path_mod.ensureDirExists(store_path);

    // Create a file in the existing store path to verify it's not empty
    const test_file = try std.fs.path.join(ctx.allocator, &.{ store_path, "test.txt" });
    defer ctx.allocator.free(test_file);
    var file = try path_mod.makePathAndOpenFile(test_file);
    try file.writeStreamingAll(path_mod.currentIo(), "existing content");
    file.close(path_mod.currentIo());

    // Verify the path exists
    try std.testing.expect(storePathExists(store_path));

    // Create a staging directory to simulate a second admission attempt
    const staging_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "staging" });
    defer ctx.allocator.free(staging_path);
    try path_mod.ensureDirExists(staging_path);

    const staging_file = try std.fs.path.join(ctx.allocator, &.{ staging_path, "test.txt" });
    defer ctx.allocator.free(staging_file);
    var staging_f = try path_mod.makePathAndOpenFile(staging_file);
    try staging_f.writeStreamingAll(path_mod.currentIo(), "new content");
    staging_f.close(path_mod.currentIo());

    // Under the 0.16 Io rename API, replacing an existing non-empty directory
    // surfaces as DirNotEmpty.
    try std.testing.expectError(error.DirNotEmpty, std.Io.Dir.renameAbsolute(staging_path, store_path, path_mod.currentIo()));

    // Original store path should still exist with original content
    try std.testing.expect(storePathExists(store_path));
    var verify_file = try path_mod.openExistingFile(test_file);
    defer verify_file.close(path_mod.currentIo());
    var buf: [100]u8 = undefined;
    const n = try verify_file.readPositionalAll(path_mod.currentIo(), &buf, 0);
    try std.testing.expectEqualStrings("existing content", buf[0..n]);

    // Clean up staging directory (simulating what install.zig does)
    path_mod.deleteTreeAbsolute(staging_path) catch {};
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
    try path_mod.ensureDirExists(store_path);

    // Create a subdirectory with a real file
    const lib_dir = try std.fs.path.join(allocator, &.{ store_path, "lib" });
    defer allocator.free(lib_dir);
    try path_mod.ensureDirExists(lib_dir);

    const real_file = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so.1.0" });
    defer allocator.free(real_file);
    {
        var f = try path_mod.makePathAndOpenFile(real_file);
        try f.writeStreamingAll(path_mod.currentIo(), "ELF...");
        f.close(path_mod.currentIo());
    }

    // Create a relative symlink: lib/libfoo.so -> libfoo.so.1.0
    const rel_link = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so" });
    defer allocator.free(rel_link);
    {
        var lib_dir_handle = try path_mod.openExistingDir(lib_dir);
        defer lib_dir_handle.close(path_mod.currentIo());
        try lib_dir_handle.symLink(path_mod.currentIo(), "libfoo.so.1.0", "libfoo.so", .{});
    }

    // resolveWithinBoundary should accept this relative symlink
    const result = try path_safety.resolveWithinBoundary(allocator, rel_link, store_path);
    defer allocator.free(result.path);

    // The resolved path should be within the store boundary
    try std.testing.expect(path_safety.isWithinBoundary(result.path, store_path));
}

test "harden validates store boundary" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const outside_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "not-store" });
    defer ctx.allocator.free(outside_path);
    try path_mod.ensureDirExists(outside_path);

    if (isPrivileged()) {
        try std.testing.expectError(StoreError.InvalidInput, harden(ctx, outside_path));
    } else {
        try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, outside_path));
    }
}

test "harden rejects sibling-prefix path" {
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
    try path_mod.ensureDirExists(sibling_path);

    if (isPrivileged()) {
        try std.testing.expectError(StoreError.InvalidInput, harden(ctx, sibling_path));
    } else {
        try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, sibling_path));
    }
}

test "harden requires privilege" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const hash_val = "a" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash_val ++ "-test-1.0" });
    defer ctx.allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    if (!isPrivileged()) {
        try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, store_path));
    }
}

test "harden detects escaping symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    if (!isPrivileged()) return error.SkipZigTest;

    const hash_val = "b" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash_val ++ "-escape-1.0" });
    defer ctx.allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    const link_path = try std.fs.path.join(ctx.allocator, &.{ store_path, "escape_link" });
    defer ctx.allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(path_mod.currentIo(), "/etc/passwd", link_path, .{});

    try std.testing.expectError(StoreError.SymlinkEscapesBoundary, harden(ctx, store_path));
}

test "clearImmutable allows modification after clearing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "def-pkg-2.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }

    const file_path = try std.fs.path.join(allocator, &.{ store_path, "file.txt" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "content\n");
    }

    _ = clearImmutable(allocator, store_path);

    {
        var f = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o644));
    }
}

test "clearImmutable handles empty directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "empty-pkg-1.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }

    const result = clearImmutable(allocator, store_path);
    try std.testing.expectEqual(@as(usize, 0), result.files_processed);
}

test "isHardened returns false for user-owned store path" {
    if (isPrivileged()) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const hash_val = "c" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash_val ++ "-pkg-1.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }

    try std.testing.expect(!isHardened(store_path));
}

test "isHardened returns false for nonexistent path" {
    try std.testing.expect(!isHardened("/mere/store/nonexistent-pkg-1.0"));
}
