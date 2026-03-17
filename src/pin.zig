const std = @import("std");
const store = @import("store.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const PinError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    PinExists,
    PinNotFound,
    InvalidStorePath,
    StorePathNotFound,
};

pub const Info = struct {
    name: []const u8,
    store_path: []const u8,
    package_name: []const u8,
    package_version: []const u8,
    note: ?[]const u8,

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.store_path);
        if (self.note) |n| {
            allocator.free(n);
        }
    }
};

pub const List = struct {
    allocator: std.mem.Allocator,
    pins: std.ArrayList(Info),

    pub fn init(allocator: std.mem.Allocator) List {
        return .{
            .allocator = allocator,
            .pins = .{},
        };
    }

    pub fn deinit(self: *List) void {
        for (self.pins.items) |*pin| {
            pin.deinit(self.allocator);
        }
        self.pins.deinit(self.allocator);
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    pin_name: []const u8,
    store_path: []const u8,
    note: ?[]const u8,
) PinError!void {
    if (pin_name.len == 0 or pin_name.len > 255) {
        return PinError.InvalidInput;
    }
    for (pin_name) |c| {
        if (c == '/' or c == 0) {
            return PinError.InvalidInput;
        }
    }

    _ = store.parseStorePath(store_path) catch {
        return PinError.InvalidStorePath;
    };

    if (!store.storePathExists(store_path)) {
        return PinError.StorePathNotFound;
    }

    const pin_path = std.fs.path.join(allocator, &.{ gc_roots_dir, pin_name }) catch {
        return PinError.OutOfMemory;
    };
    defer allocator.free(pin_path);

    if (std.fs.accessAbsolute(pin_path, .{})) |_| {
        return PinError.PinExists;
    } else |err| {
        if (err != error.FileNotFound) {
            return switch (err) {
                error.AccessDenied => PinError.PermissionDenied,
                else => PinError.FileSystem,
            };
        }
    }

    std.fs.cwd().makePath(gc_roots_dir) catch |err| {
        return switch (err) {
            error.AccessDenied => PinError.PermissionDenied,
            else => PinError.FileSystem,
        };
    };

    std.posix.symlinkat(store_path, std.fs.cwd().fd, pin_path) catch |err| {
        return switch (err) {
            error.AccessDenied => PinError.PermissionDenied,
            else => PinError.FileSystem,
        };
    };
    errdefer std.fs.cwd().deleteFile(pin_path) catch {};

    if (note) |n| {
        const note_path = std.fmt.allocPrint(allocator, "{s}.note", .{pin_path}) catch {
            return PinError.OutOfMemory;
        };
        defer allocator.free(note_path);

        var note_created = false;
        errdefer if (note_created) std.fs.cwd().deleteFile(note_path) catch {};

        var file = std.fs.createFileAbsolute(note_path, .{}) catch |err| {
            return switch (err) {
                error.AccessDenied => PinError.PermissionDenied,
                else => PinError.FileSystem,
            };
        };
        note_created = true;
        defer file.close();

        file.writeAll(n) catch |err| {
            return switch (err) {
                error.AccessDenied => PinError.PermissionDenied,
                else => PinError.FileSystem,
            };
        };
    }
}

pub fn remove(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    pin_name: []const u8,
) PinError!void {
    const pin_path = std.fs.path.join(allocator, &.{ gc_roots_dir, pin_name }) catch {
        return PinError.OutOfMemory;
    };
    defer allocator.free(pin_path);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.readLinkAbsolute(pin_path, &link_buf) catch |err| {
        return switch (err) {
            error.FileNotFound => PinError.PinNotFound,
            error.NotLink => PinError.PinNotFound,
            else => PinError.FileSystem,
        };
    };

    std.fs.cwd().deleteFile(pin_path) catch |err| {
        return switch (err) {
            error.AccessDenied => PinError.PermissionDenied,
            else => PinError.FileSystem,
        };
    };

    const note_path = std.fmt.allocPrint(allocator, "{s}.note", .{pin_path}) catch {
        return;
    };
    defer allocator.free(note_path);

    std.fs.cwd().deleteFile(note_path) catch {
    };
}

pub fn get(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    pin_name: []const u8,
) PinError!Info {
    const pin_path = std.fs.path.join(allocator, &.{ gc_roots_dir, pin_name }) catch {
        return PinError.OutOfMemory;
    };
    defer allocator.free(pin_path);

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(pin_path, &target_buf) catch |err| {
        return switch (err) {
            error.FileNotFound => PinError.PinNotFound,
            error.NotLink => PinError.PinNotFound,
            error.AccessDenied => PinError.PermissionDenied,
            else => PinError.FileSystem,
        };
    };

    _ = store.parseStorePath(target) catch {
        return PinError.InvalidStorePath;
    };

    const name_copy = allocator.dupe(u8, pin_name) catch {
        return PinError.OutOfMemory;
    };
    errdefer allocator.free(name_copy);

    const target_copy = allocator.dupe(u8, target) catch {
        return PinError.OutOfMemory;
    };
    errdefer allocator.free(target_copy);

    const components_copy = store.parseStorePath(target_copy) catch unreachable;

    const note_path = std.fmt.allocPrint(allocator, "{s}.note", .{pin_path}) catch {
        return PinError.OutOfMemory;
    };
    defer allocator.free(note_path);

    const note: ?[]const u8 = blk: {
        var file = std.fs.openFileAbsolute(note_path, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk null;
            if (err == error.AccessDenied) break :blk null;
            return PinError.FileSystem;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            if (err == error.AccessDenied) break :blk null;
            return PinError.FileSystem;
        };

        if (stat.size > 1024 * 1024) {
            break :blk null;
        }

        const content = allocator.alloc(u8, @intCast(stat.size)) catch {
            break :blk null;
        };

        const bytes_read = file.readAll(content) catch |err| {
            allocator.free(content);
            if (err == error.AccessDenied) break :blk null;
            return PinError.FileSystem;
        };

        if (bytes_read < content.len) {
            break :blk allocator.realloc(content, bytes_read) catch content[0..bytes_read];
        }

        break :blk content;
    };

    return Info{
        .name = name_copy,
        .store_path = target_copy,
        .package_name = components_copy.name,
        .package_version = components_copy.version,
        .note = note,
    };
}

pub fn list(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
) PinError!List {
    var result = List.init(allocator);
    errdefer result.deinit();

    var dir = std.fs.openDirAbsolute(gc_roots_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => result,
            error.AccessDenied => PinError.PermissionDenied,
            else => PinError.FileSystem,
        };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch {
        return PinError.FileSystem;
    }) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".note")) {
            continue;
        }

        if (entry.kind != .sym_link) {
            continue;
        }

        if (std.mem.eql(u8, entry.name, "current") or
            std.mem.startsWith(u8, entry.name, "gen-"))
        {
            continue;
        }

        const pin_info = get(allocator, gc_roots_dir, entry.name) catch {
            continue;
        };

        result.pins.append(allocator, pin_info) catch {
            var mutable_pin = pin_info;
            mutable_pin.deinit(allocator);
            return PinError.OutOfMemory;
        };
    }

    return result;
}

pub fn forPackage(
    allocator: std.mem.Allocator,
    gc_roots_dir: []const u8,
    package_name: []const u8,
) PinError!?[]const u8 {
    var pins = try list(allocator, gc_roots_dir);
    defer pins.deinit();

    for (pins.pins.items) |pin| {
        if (std.mem.eql(u8, pin.package_name, package_name)) {
            return allocator.dupe(u8, pin.store_path) catch {
                return PinError.OutOfMemory;
            };
        }
    }

    return null;
}

pub fn defaultName(store_path: []const u8) PinError![]const u8 {
    const components = store.parseStorePath(store_path) catch {
        return PinError.InvalidStorePath;
    };
    return components.name;
}

// Tests

test "create and remove work correctly" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create gc-roots directory
    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);

    // Create a fake store path
    const hash = "a" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-test-pkg-1.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Create a pin
    try create(allocator, gc_roots, "my-pin", store_path, "Test pin note");

    // Verify pin exists
    const pin_info = try get(allocator, gc_roots, "my-pin");
    defer {
        var mutable = pin_info;
        mutable.deinit(allocator);
    }

    try std.testing.expectEqualStrings("my-pin", pin_info.name);
    try std.testing.expectEqualStrings(store_path, pin_info.store_path);
    try std.testing.expectEqualStrings("test-pkg", pin_info.package_name);
    try std.testing.expectEqualStrings("1.0", pin_info.package_version);
    try std.testing.expect(pin_info.note != null);
    try std.testing.expectEqualStrings("Test pin note", pin_info.note.?);

    // Remove the pin
    try remove(allocator, gc_roots, "my-pin");

    // Verify pin is gone
    try std.testing.expectError(PinError.PinNotFound, get(allocator, gc_roots, "my-pin"));
}

// Spec #22: Duplicate pin name is an error
test "create rejects duplicate pins" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);

    const hash = "b" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-foo-2.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Create first pin
    try create(allocator, gc_roots, "foo", store_path, null);

    // Try to create duplicate
    try std.testing.expectError(PinError.PinExists, create(allocator, gc_roots, "foo", store_path, null));
}

// Spec #22: Pin target must be a valid store path
test "createPin validates store path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);

    // Invalid store path format
    try std.testing.expectError(PinError.InvalidStorePath, create(allocator, gc_roots, "bad", "/some/random/path", null));

    // Valid format but doesn't exist
    const hash = "c" ** 64;
    const nonexistent = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-nonexistent-1.0" });
    defer allocator.free(nonexistent);
    try std.testing.expectError(PinError.StorePathNotFound, create(allocator, gc_roots, "bad", nonexistent, null));
}

// Spec #22: Pin name must be a valid filename
test "createPin validates pin name" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);

    const hash = "d" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-pkg-1.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Empty name
    try std.testing.expectError(PinError.InvalidInput, create(allocator, gc_roots, "", store_path, null));

    // Name with slash
    try std.testing.expectError(PinError.InvalidInput, create(allocator, gc_roots, "bad/name", store_path, null));
}

test "createPin rolls back symlink when note creation fails" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);
    try std.fs.cwd().makePath(gc_roots);

    const hash = "a" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-test-pkg-1.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Force note creation failure after symlink creation by pre-creating <pin>.note as a directory.
    const blocking_note_dir = try std.fs.path.join(allocator, &.{ gc_roots, "rollback-pin.note" });
    defer allocator.free(blocking_note_dir);
    try std.fs.cwd().makePath(blocking_note_dir);

    try std.testing.expectError(
        PinError.FileSystem,
        create(allocator, gc_roots, "rollback-pin", store_path, "note text"),
    );

    // Pin symlink must not remain after note failure.
    try std.testing.expectError(PinError.PinNotFound, get(allocator, gc_roots, "rollback-pin"));
}

// Spec #22: List all pins
test "listPins returns all user pins" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);

    // Create multiple store paths and pins
    const hash1 = "e" ** 64;
    const store1 = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash1 ++ "-pkg1-1.0" });
    defer allocator.free(store1);
    try std.fs.cwd().makePath(store1);

    const hash2 = "f" ** 64;
    const store2 = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash2 ++ "-pkg2-2.0" });
    defer allocator.free(store2);
    try std.fs.cwd().makePath(store2);

    try create(allocator, gc_roots, "pin1", store1, null);
    try create(allocator, gc_roots, "pin2", store2, "Note for pin2");

    // List pins
    var pins = try list(allocator, gc_roots);
    defer pins.deinit();

    try std.testing.expectEqual(@as(usize, 2), pins.pins.items.len);
}

test "listPins skips system roots" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);
    try std.fs.cwd().makePath(gc_roots);

    // Create system-managed roots (should be skipped)
    const current_path = try std.fs.path.join(allocator, &.{ gc_roots, "current" });
    defer allocator.free(current_path);
    std.posix.symlinkat("/mere/profiles/system/current", std.fs.cwd().fd, current_path) catch {};

    const gen1_path = try std.fs.path.join(allocator, &.{ gc_roots, "gen-1" });
    defer allocator.free(gen1_path);
    std.posix.symlinkat("/mere/profiles/system/gen-1", std.fs.cwd().fd, gen1_path) catch {};

    // Create a user pin
    const hash = "0" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-user-pkg-1.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    try create(allocator, gc_roots, "user-pin", store_path, null);

    // List pins - should only see the user pin
    var pins = try list(allocator, gc_roots);
    defer pins.deinit();

    try std.testing.expectEqual(@as(usize, 1), pins.pins.items.len);
    try std.testing.expectEqualStrings("user-pin", pins.pins.items[0].name);
}

// Spec #22: Pin matching by package name for resolver integration
test "getPinForPackage finds pin by package name" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots);

    const hash = "1" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash ++ "-my-app-3.0" });
    defer allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    // Pin with custom name
    try create(allocator, gc_roots, "stable-app", store_path, null);

    // Find by package name (not pin name)
    const pinned_path = try forPackage(allocator, gc_roots, "my-app");
    defer if (pinned_path) |p| allocator.free(p);

    try std.testing.expect(pinned_path != null);
    try std.testing.expectEqualStrings(store_path, pinned_path.?);

    // Non-existent package
    const no_pin = try forPackage(allocator, gc_roots, "other-pkg");
    try std.testing.expect(no_pin == null);
}

test "getDefaultPinName extracts package name" {
    const hash = "2" ** 64;
    const path = "/mere/store/" ++ hash ++ "-my-package-1.2.3";
    const name = try defaultName(path);
    try std.testing.expectEqualStrings("my-package", name);
}
