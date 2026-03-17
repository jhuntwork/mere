const std = @import("std");
const manifest = @import("manifest.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const ProjectionError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

pub const MAGIC: *const [8]u8 = "MEREPRJ1";
pub const SCHEMA_VERSION: u32 = 1;
const MAX_FILE_SIZE: u64 = 64 * 1024 * 1024;
const HEADER_SIZE: usize = 8 + 4 + 4;

pub const Data = struct {
    paths: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Data {
        return .{
            .paths = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Data) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit(self.allocator);
    }

    pub fn addPath(self: *Data, path: []const u8) ProjectionError!void {
        try validateProjectionPath(path);
        const path_copy = self.allocator.dupe(u8, path) catch return ProjectionError.OutOfMemory;
        errdefer self.allocator.free(path_copy);
        self.paths.append(self.allocator, path_copy) catch return ProjectionError.OutOfMemory;
    }

    pub fn canonicalize(self: *Data) ProjectionError!void {
        std.mem.sort([]const u8, self.paths.items, {}, lessThan);
        try self.validateCanonical();
    }

    pub fn validateCanonical(self: *const Data) ProjectionError!void {
        var prev: ?[]const u8 = null;
        for (self.paths.items) |path| {
            try validateProjectionPath(path);
            if (prev) |previous| {
                if (!std.mem.lessThan(u8, previous, path)) return ProjectionError.InvalidInput;
            }
            prev = path;
        }
    }

    pub fn encode(self: *const Data, allocator: std.mem.Allocator) ProjectionError![]u8 {
        try self.validateCanonical();

        var total_size: usize = 8 + 4 + 4;
        for (self.paths.items) |path| {
            total_size = std.math.add(usize, total_size, 4) catch return ProjectionError.OutOfMemory;
            total_size = std.math.add(usize, total_size, path.len) catch return ProjectionError.OutOfMemory;
        }

        const buffer = allocator.alloc(u8, total_size) catch return ProjectionError.OutOfMemory;
        errdefer allocator.free(buffer);

        var offset: usize = 0;
        @memcpy(buffer[offset..][0..8], MAGIC);
        offset += 8;

        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(@as(u32, SCHEMA_VERSION)));
        offset += 4;

        const entry_count: u32 = @intCast(self.paths.items.len);
        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(entry_count));
        offset += 4;

        for (self.paths.items) |path| {
            const path_len: u32 = @intCast(path.len);
            @memcpy(buffer[offset..][0..4], &std.mem.toBytes(path_len));
            offset += 4;
            @memcpy(buffer[offset..][0..path.len], path);
            offset += path.len;
        }

        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, input: []const u8) ProjectionError!Data {
        if (input.len < HEADER_SIZE) return ProjectionError.InvalidInput;

        var offset: usize = 0;
        if (!std.mem.eql(u8, input[offset..][0..8], MAGIC)) return ProjectionError.InvalidInput;
        offset += 8;

        const schema_version = std.mem.readInt(u32, input[offset..][0..4], .little);
        if (schema_version != SCHEMA_VERSION) return ProjectionError.InvalidInput;
        offset += 4;

        const entry_count = std.mem.readInt(u32, input[offset..][0..4], .little);
        offset += 4;

        var data = Data.init(allocator);
        errdefer data.deinit();

        try data.paths.ensureTotalCapacity(allocator, entry_count);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (offset + 4 > input.len) return ProjectionError.InvalidInput;
            const path_len = std.mem.readInt(u32, input[offset..][0..4], .little);
            offset += 4;
            if (offset + path_len > input.len) return ProjectionError.InvalidInput;

            const path_copy = allocator.dupe(u8, input[offset .. offset + path_len]) catch return ProjectionError.OutOfMemory;
            data.paths.append(allocator, path_copy) catch {
                allocator.free(path_copy);
                return ProjectionError.OutOfMemory;
            };
            offset += path_len;
        }

        if (offset != input.len) return ProjectionError.InvalidInput;
        try data.validateCanonical();
        return data;
    }

    pub fn eql(self: *const Data, other: *const Data) bool {
        if (self.paths.items.len != other.paths.items.len) return false;
        for (self.paths.items, other.paths.items) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }
};

pub fn deriveFromPayload(allocator: std.mem.Allocator, dir_path: []const u8) ProjectionError!Data {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        return mapFsError(err);
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch |err| {
        return mapFsError(err);
    };
    defer walker.deinit();

    var data = Data.init(allocator);
    errdefer data.deinit();

    while (true) {
        const maybe_entry = walker.next() catch |err| {
            return mapFsError(err);
        };
        if (maybe_entry == null) break;
        const entry = maybe_entry.?;
        if (entry.kind == .directory) continue;
        if (isExcludedProjectionPath(entry.path)) continue;
        try validateProjectionPath(entry.path);
        try data.addPath(entry.path);
    }

    try data.canonicalize();
    return data;
}

pub fn validateAgainstPayload(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    expected: *const Data,
) ProjectionError!void {
    var derived = try deriveFromPayload(allocator, dir_path);
    defer derived.deinit();

    if (!expected.eql(&derived)) return ProjectionError.InvalidInput;
}

pub fn readFile(allocator: std.mem.Allocator, dir_path: []const u8) ProjectionError!Data {
    const projection_path = std.fs.path.join(allocator, &.{ dir_path, manifest.PROJECTION_FILENAME }) catch {
        return ProjectionError.OutOfMemory;
    };
    defer allocator.free(projection_path);

    var file = std.fs.openFileAbsolute(projection_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ProjectionError.InvalidInput,
            else => mapFsError(err),
        };
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        return mapFsError(err);
    };
    if (stat.size > MAX_FILE_SIZE) return ProjectionError.InvalidInput;

    const content = allocator.alloc(u8, @intCast(stat.size)) catch return ProjectionError.OutOfMemory;
    defer allocator.free(content);

    const bytes_read = file.readAll(content) catch |err| {
        return mapFsError(err);
    };
    if (bytes_read != @as(usize, @intCast(stat.size))) return ProjectionError.FileSystem;

    return Data.decode(allocator, content);
}

pub fn writeFile(allocator: std.mem.Allocator, dir_path: []const u8, data: *const Data) ProjectionError!void {
    const meta_dir_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_DIR }) catch {
        return ProjectionError.OutOfMemory;
    };
    defer allocator.free(meta_dir_path);
    std.fs.cwd().makePath(meta_dir_path) catch |err| {
        return mapFsError(err);
    };

    const projection_path = std.fs.path.join(allocator, &.{ dir_path, manifest.PROJECTION_FILENAME }) catch {
        return ProjectionError.OutOfMemory;
    };
    defer allocator.free(projection_path);

    const encoded = try data.encode(allocator);
    defer allocator.free(encoded);

    var file = std.fs.createFileAbsolute(projection_path, .{ .truncate = true }) catch |err| {
        return mapFsError(err);
    };
    defer file.close();
    file.writeAll(encoded) catch |err| {
        return mapFsError(err);
    };
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn isExcludedProjectionPath(path: []const u8) bool {
    return std.mem.eql(u8, path, manifest.META_DIR) or
        std.mem.startsWith(u8, path, manifest.META_DIR ++ "/") or
        std.mem.eql(u8, path, "etc") or
        std.mem.startsWith(u8, path, "etc/");
}

fn validateProjectionPath(path: []const u8) ProjectionError!void {
    if (path.len == 0) return ProjectionError.InvalidInput;
    if (path[0] == '/' or path[path.len - 1] == '/') return ProjectionError.InvalidInput;
    if (isExcludedProjectionPath(path)) return ProjectionError.InvalidInput;
    if (std.mem.eql(u8, path, "usr/local") or std.mem.startsWith(u8, path, "usr/local/")) {
        return ProjectionError.InvalidInput;
    }

    var components = std.mem.tokenizeScalar(u8, path, '/');
    var count: usize = 0;
    while (components.next()) |component| {
        count += 1;
        if (component.len == 0) return ProjectionError.InvalidInput;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return ProjectionError.InvalidInput;
        }
    }
    if (count == 0) return ProjectionError.InvalidInput;
}

fn mapFsError(err: anyerror) ProjectionError {
    return switch (err) {
        error.OutOfMemory => ProjectionError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => ProjectionError.PermissionDenied,
        error.BadPathName, error.NameTooLong, error.InvalidUtf8 => ProjectionError.InvalidInput,
        else => ProjectionError.FileSystem,
    };
}

test "deriveFromPayload collects canonical leaf paths and excludes profile-special paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "projection-root" });
    defer test_env.ctx.allocator.free(root);
    try std.fs.cwd().makePath(root);

    const bin_path = try std.fs.path.join(test_env.ctx.allocator, &.{ root, "usr", "bin", "tool" });
    defer test_env.ctx.allocator.free(bin_path);
    try std.fs.cwd().makePath(std.fs.path.dirname(bin_path).?);
    var bin_file = try std.fs.createFileAbsolute(bin_path, .{});
    defer bin_file.close();
    try bin_file.writeAll("tool");

    const etc_path = try std.fs.path.join(test_env.ctx.allocator, &.{ root, "etc", "config.conf" });
    defer test_env.ctx.allocator.free(etc_path);
    try std.fs.cwd().makePath(std.fs.path.dirname(etc_path).?);
    var etc_file = try std.fs.createFileAbsolute(etc_path, .{});
    defer etc_file.close();
    try etc_file.writeAll("config");

    const defaults_path = try std.fs.path.join(test_env.ctx.allocator, &.{ root, "etc-defaults", "myapp", "config.conf" });
    defer test_env.ctx.allocator.free(defaults_path);
    try std.fs.cwd().makePath(std.fs.path.dirname(defaults_path).?);
    var defaults_file = try std.fs.createFileAbsolute(defaults_path, .{});
    defer defaults_file.close();
    try defaults_file.writeAll("template");

    const meta_path = try std.fs.path.join(test_env.ctx.allocator, &.{ root, manifest.META_KDL_FILENAME });
    defer test_env.ctx.allocator.free(meta_path);
    try std.fs.cwd().makePath(std.fs.path.dirname(meta_path).?);
    var meta_file = try std.fs.createFileAbsolute(meta_path, .{});
    defer meta_file.close();
    try meta_file.writeAll("ignored");

    var data = try deriveFromPayload(test_env.ctx.allocator, root);
    defer data.deinit();

    try std.testing.expectEqual(@as(usize, 2), data.paths.items.len);
    try std.testing.expectEqualStrings("etc-defaults/myapp/config.conf", data.paths.items[0]);
    try std.testing.expectEqualStrings("usr/bin/tool", data.paths.items[1]);
}

test "deriveFromPayload rejects usr/local paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "projection-root-usr-local" });
    defer test_env.ctx.allocator.free(root);
    try std.fs.cwd().makePath(root);
    const local_path = try std.fs.path.join(test_env.ctx.allocator, &.{ root, "usr", "local", "bin", "tool" });
    defer test_env.ctx.allocator.free(local_path);

    try std.fs.cwd().makePath(std.fs.path.dirname(local_path).?);
    var local_file = try std.fs.createFileAbsolute(local_path, .{});
    defer local_file.close();
    try local_file.writeAll("tool");

    try std.testing.expectError(ProjectionError.InvalidInput, deriveFromPayload(test_env.ctx.allocator, root));
}

test "projection.v1 round-trips canonical path tables" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var data = Data.init(test_env.ctx.allocator);
    defer data.deinit();
    try data.addPath("usr/share/doc/readme.txt");
    try data.addPath("usr/bin/tool");
    try data.canonicalize();

    const root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "projection-roundtrip" });
    defer test_env.ctx.allocator.free(root);
    try std.fs.cwd().makePath(root);
    try writeFile(test_env.ctx.allocator, root, &data);

    var decoded = try readFile(test_env.ctx.allocator, root);
    defer decoded.deinit();

    try std.testing.expect(data.eql(&decoded));
    try std.testing.expectEqualStrings("usr/bin/tool", decoded.paths.items[0]);
    try std.testing.expectEqualStrings("usr/share/doc/readme.txt", decoded.paths.items[1]);
}
