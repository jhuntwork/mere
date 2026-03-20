const std = @import("std");
const builtin = @import("builtin");
const mere = @import("mere.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const PathError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    HomeNotFound,
    PathTooLong,
};

var runtime_io: ?std.Io = null;

pub const TempDir = struct {
    dir: std.Io.Dir,
    parent_dir: std.Io.Dir,
    sub_path: []const u8,

    pub fn cleanup(self: *TempDir) void {
        const io = currentIo();
        self.dir.close(io);
        self.parent_dir.deleteTree(io, self.sub_path) catch {};
        self.parent_dir.close(io);
        std.heap.page_allocator.free(self.sub_path);
        self.* = undefined;
    }

    const random_bytes_count = 12;
    const encoded_size = random_bytes_count * 2;
};

pub fn currentIo() std.Io {
    if (builtin.is_test) return std.testing.io;
    return runtime_io orelse @panic("path runtime io not initialized");
}

pub fn setRuntimeIo(io: std.Io) void {
    runtime_io = io;
}

pub fn createTempDir(
    prefix: []const u8,
) !TempDir {
    const io = currentIo();
    var random_bytes: [TempDir.random_bytes_count]u8 = undefined;
    io.random(&random_bytes);

    var encoded_buf: [TempDir.encoded_size]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded_buf, "{s}", .{std.fmt.bytesToHex(random_bytes, .lower)}) catch unreachable;
    const encoded = encoded_buf[0..];

    var dir_name_buf: [TempDir.encoded_size + 32]u8 = undefined;
    const dir_name = try std.fmt.bufPrint(&dir_name_buf, "{s}_{s}", .{ prefix, encoded });

    var parent_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    errdefer parent_dir.close(io);

    var dir = try parent_dir.createDirPathOpen(io, dir_name, .{
        .open_options = .{ .iterate = true },
    });
    errdefer {
        parent_dir.deleteTree(io, dir_name) catch {};
        dir.close(io);
    }

    const sub_path_copy = try std.heap.page_allocator.dupe(u8, dir_name);

    return TempDir{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path_copy,
    };
}

pub fn makePathAndOpenDir(
    target_path: []const u8,
) !std.Io.Dir {
    const io = currentIo();
    if (std.fs.path.isAbsolute(target_path)) {
        var root_dir = try std.Io.Dir.openDirAbsolute(io, "/", .{});
        defer root_dir.close(io);
        return root_dir.createDirPathOpen(io, target_path, .{
            .open_options = .{
                .iterate = true,
            },
        });
    }

    return std.Io.Dir.cwd().createDirPathOpen(io, target_path, .{
        .open_options = .{
            .iterate = true,
        },
    });
}

pub fn ensureDirExists(target_path: []const u8) !void {
    var dir = try makePathAndOpenDir(target_path);
    dir.close(currentIo());
}

pub fn openExistingDir(target_path: []const u8) !std.Io.Dir {
    const io = currentIo();
    if (std.fs.path.isAbsolute(target_path)) {
        return std.Io.Dir.openDirAbsolute(io, target_path, .{ .iterate = true });
    }
    return std.Io.Dir.cwd().openDir(io, target_path, .{ .iterate = true });
}

pub fn makePathAndOpenFile(
    file_path: []const u8,
) !std.Io.File {
    const io = currentIo();
    const dirname = std.fs.path.dirname(file_path) orelse ".";
    var dir = try makePathAndOpenDir(dirname);
    defer dir.close(io);
    const basename = std.fs.path.basename(file_path);
    return dir.createFile(io, basename, .{});
}

pub fn ensureParent(file_path: []const u8) !void {
    const io = currentIo();
    const dirname = std.fs.path.dirname(file_path) orelse ".";
    var dir = try makePathAndOpenDir(dirname);
    defer dir.close(io);
    return;
}

pub fn fileExists(path: []const u8) bool {
    const io = currentIo();
    if (std.fs.path.isAbsolute(path)) {
        const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
        f.close(io);
        return true;
    } else {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
        f.close(io);
        return true;
    }
}
pub fn openExistingFile(file_path: []const u8) !std.Io.File {
    const io = currentIo();
    if (std.fs.path.isAbsolute(file_path)) {
        return std.Io.Dir.openFileAbsolute(io, file_path, .{});
    } else {
        return std.Io.Dir.cwd().openFile(io, file_path, .{});
    }
}

pub fn copyFile(src_path: []const u8, dst_path: []const u8) !void {
    try std.Io.Dir.copyFileAbsolute(src_path, dst_path, currentIo(), .{
        .make_path = true,
        .replace = true,
    });
}

pub fn deleteTreeAbsolute(target_path: []const u8) !void {
    const io = currentIo();
    const parent = std.fs.path.dirname(target_path) orelse "/";
    const basename = std.fs.path.basename(target_path);
    var parent_dir = try openExistingDir(parent);
    defer parent_dir.close(io);
    try parent_dir.deleteTree(io, basename);
}

pub fn isValidInputPath(destpath: []const u8) bool {
    if (destpath.len == 0) {
        return false;
    }
    if (std.mem.indexOfScalar(u8, destpath, 0) != null) {
        return false;
    }
    if (std.mem.trim(u8, destpath, " \t\r\n").len == 0) {
        return false;
    }
    if (std.mem.eql(u8, destpath, ".") or std.mem.eql(u8, destpath, "..")) {
        return false;
    }
    if (destpath.len > 1 and destpath[destpath.len - 1] == '/') {
        return false;
    }
    if (destpath.len > std.fs.max_path_bytes) {
        return false;
    }
    const NAME_MAX = std.os.linux.NAME_MAX;
    var start: usize = 0;
    while (start < destpath.len) {
        var end = start;
        while (end < destpath.len and destpath[end] != '/') : (end += 1) {}
        if (end - start > NAME_MAX) {
            return false;
        }
        start = end + 1;
    }
    return true;
}

fn getHomeDirectory(ctx: *const mere.Context) ![]const u8 {
    if (ctx.home_dir) |hd| {
        return try ctx.allocator.dupe(u8, hd);
    }
    const home_z = std.c.getenv("HOME") orelse return PathError.HomeNotFound;
    return try ctx.allocator.dupe(u8, std.mem.span(home_z));
}

pub fn getDefaultMereConfigDirectory(ctx: *const mere.Context) ![]const u8 {
    const home_dir = try getHomeDirectory(ctx);
    defer ctx.allocator.free(home_dir);

    return std.fs.path.join(ctx.allocator, &.{ home_dir, ".config", "mere" });
}

pub fn getDefaultMereKeysDirectory(ctx: *const mere.Context) ![]const u8 {
    const home_dir = try getHomeDirectory(ctx);
    defer ctx.allocator.free(home_dir);

    return std.fs.path.join(ctx.allocator, &.{ home_dir, ".mere", "keys" });
}

pub fn getDefaultSigningKeyPath(ctx: *const mere.Context) ![]const u8 {
    const home_dir = try getHomeDirectory(ctx);
    defer ctx.allocator.free(home_dir);
    return std.fs.path.join(ctx.allocator, &.{ home_dir, ".mere", "keys", "mere.key" });
}

pub fn resolveToAbsolutePath(path: []const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return path;
    } else {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(currentIo(), &cwd_buf);
        const cwd = cwd_buf[0..cwd_len];

        const parts = &[_][]const u8{ cwd, path };
        const resolved = try std.fs.path.resolvePosix(std.heap.page_allocator, parts);
        defer std.heap.page_allocator.free(resolved);

        if (resolved.len > buffer.len) {
            return PathError.PathTooLong;
        }
        std.mem.copyForwards(u8, buffer[0..resolved.len], resolved);
        return buffer[0..resolved.len];
    }
}

pub fn ensureResolvedPathWithin(allocator: std.mem.Allocator, base_dir: []const u8, combined_path: []const u8) !void {
    const resolved_combined = try std.fs.path.resolve(allocator, &[_][]const u8{combined_path});
    defer allocator.free(resolved_combined);

    const resolved_base = try std.fs.path.resolve(allocator, &[_][]const u8{base_dir});
    defer allocator.free(resolved_base);

    if (std.mem.eql(u8, resolved_base, "/")) {
        return;
    }

    if (!std.mem.startsWith(u8, resolved_combined, resolved_base)) {
        return error.InvalidArgument;
    }

    if (resolved_combined.len > resolved_base.len and resolved_combined[resolved_base.len] != '/') {
        return error.InvalidArgument;
    }
}

test "ensureResolvedPathWithin accepts descendant path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const base = try std.fs.path.resolve(alloc, &[_][]const u8{"/tmp/mere-base"});
    defer alloc.free(base);
    const combined = try std.fs.path.resolve(alloc, &[_][]const u8{"/tmp/mere-base/subdir/file.txt"});
    defer alloc.free(combined);

    try ensureResolvedPathWithin(alloc, base, combined);
}

test "ensureResolvedPathWithin rejects sibling-prefix escape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const base = try std.fs.path.resolve(alloc, &[_][]const u8{"/tmp/mere-base"});
    defer alloc.free(base);
    const combined = try std.fs.path.resolve(alloc, &[_][]const u8{"/tmp/mere-base-evil/file.txt"});
    defer alloc.free(combined);

    try testing.expectError(error.InvalidArgument, ensureResolvedPathWithin(alloc, base, combined));
}

test "createTempDir generates separator-safe sub_path" {
    var td = try createTempDir("mere-test");
    defer td.cleanup();

    try std.testing.expect(std.mem.startsWith(u8, td.sub_path, "mere-test_"));
    try std.testing.expect(std.mem.indexOfScalar(u8, td.sub_path, '/') == null);
}

test "Make an absolute path with leading dirs" {
    // Use createTestEnv to set up a test environment
    const testing = std.testing;
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Add some additional dirs which will require leading paths are created too
    const paths: []const []const u8 = &.{ test_env.path, "some/additional/dirs" };
    const abs_target = try std.fs.path.join(testing.allocator, paths);
    defer testing.allocator.free(abs_target);

    // Create the target dir using a full path
    var dir = try makePathAndOpenDir(abs_target);
    defer dir.close(currentIo());

    // Compare the created dir realpath matches the expected target
    const actual_path_len = try dir.realPath(currentIo(), &buf);
    const actual_path = buf[0..actual_path_len];
    try testing.expectEqualStrings(abs_target, actual_path);
}

test "Make a relative path with leading dirs" {
    // Use createTestEnv to set up a test environment
    const testing = std.testing;
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Save current working directory before switching
    const original_cwd_len = try std.process.currentPath(currentIo(), &original_cwd_buf);
    const original_cwd = original_cwd_buf[0..original_cwd_len];
    defer std.Io.Threaded.chdir(original_cwd) catch |err| {
        test_env.ctx.debug("Failed to restore cwd: {}\n", .{err});
    };

    // Change directories to the test environment path
    try std.Io.Threaded.chdir(test_env.path);

    // Set up some vars for testing
    const rel_path = "some/relative/path";
    const paths: []const []const u8 = &.{ test_env.path, rel_path };
    const abs_target = try std.fs.path.join(testing.allocator, paths);
    defer testing.allocator.free(abs_target);

    // Create the target dir using a relative path
    var dir = try makePathAndOpenDir(rel_path);
    defer dir.close(currentIo());

    // Compare the created dir realpath matches the expected target
    const actual_path_len = try dir.realPath(currentIo(), &buf);
    const actual_path = buf[0..actual_path_len];
    try testing.expectEqualStrings(abs_target, actual_path);
}

test "copyFile copies contents and creates parent dirs" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;

    const src_path = try std.fs.path.join(allocator, &.{ test_env.path, "src.txt" });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ test_env.path, "a", "b", "dst.txt" });
    defer allocator.free(dst_path);

    {
        var f = try makePathAndOpenFile(src_path);
        defer f.close(currentIo());
        try f.writeStreamingAll(currentIo(), "copy test");
    }

    try copyFile(src_path, dst_path);

    var f = try std.Io.Dir.openFileAbsolute(currentIo(), dst_path, .{});
    defer f.close(currentIo());
    var buf: [16]u8 = undefined;
    const n = try f.readPositionalAll(currentIo(), &buf, 0);
    try std.testing.expectEqualStrings("copy test", buf[0..n]);
}

test "isValidInputPath basic cases" {
    try std.testing.expect(isValidInputPath("foo.txt"));
    try std.testing.expect(isValidInputPath("/tmp/bar"));
    try std.testing.expect(!isValidInputPath(""));
    try std.testing.expect(!isValidInputPath("\x00"));
    try std.testing.expect(!isValidInputPath("abc\x00def"));
}

test "isValidInputPath rejects whitespace-only paths" {
    try std.testing.expect(!isValidInputPath("   "));
    try std.testing.expect(!isValidInputPath("\t\n\r"));
    try std.testing.expect(!isValidInputPath(" \t "));
    try std.testing.expect(isValidInputPath("foo.txt"));
}

test "isValidInputPath rejects directory-like paths" {
    try std.testing.expect(!isValidInputPath("."));
    try std.testing.expect(!isValidInputPath(".."));
    try std.testing.expect(!isValidInputPath("folder/"));
    try std.testing.expect(isValidInputPath("folder/file.txt"));
}

test "isValidInputPath rejects path longer than max_path_bytes" {
    const max_path = std.fs.max_path_bytes;
    var buf: [4096]u8 = undefined;
    @memset(&buf, 'b');
    if (max_path + 1 <= buf.len) {
        try std.testing.expect(!isValidInputPath(buf[0..(max_path + 1)]));
        try std.testing.expect(isValidInputPath(buf[0..max_path]));
    }
}

test "isValidInputPath rejects too-long paths" {
    const NAME_MAX = std.os.linux.NAME_MAX;
    var buf: [300]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expect(!isValidInputPath(buf[0..(NAME_MAX + 1)]));
    try std.testing.expect(isValidInputPath(buf[0..NAME_MAX]));
}

test "makePathAndOpenFile creates file for absolute path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Build an absolute path under the test environment
    const abs_file = try std.fs.path.join(allocator, &.{ test_env.path, "a", "b", "abs.txt" });
    defer allocator.free(abs_file);

    // Attempt to create the file using the helper which should create parent dirs
    var f = try makePathAndOpenFile(abs_file);
    defer f.close(currentIo());
    try f.writeStreamingAll(currentIo(), "regtest");

    // Verify the file exists and contains the expected content
    const st = try std.Io.Dir.cwd().statFile(currentIo(), abs_file, .{});
    try std.testing.expect(st.size == 7);

    var r = try std.Io.Dir.openFileAbsolute(currentIo(), abs_file, .{});
    defer r.close(currentIo());
    var buf: [16]u8 = undefined;
    const n = try r.readPositionalAll(currentIo(), &buf, 0);
    try std.testing.expectEqualStrings("regtest", buf[0..n]);
}
