// Tests for src/cli/commands/*.zig handlers. This file lives directly under
// src/cli/ (not src/cli/commands/) so it can be a standalone test root: its
// relative imports of commands/*.zig, and their own relative imports of
// ../types.zig etc., all stay within src/cli/'s directory tree. A file
// under src/cli/commands/ can't be compiled as a standalone test root
// itself, since its own "../types.zig" import would escape its module root.

const std = @import("std");
const mere = @import("mere");
const types = @import("types.zig");
const pin_cmd = @import("commands/pin.zig");
const profile_cmd = @import("commands/profile.zig");

fn makeArgs(positional: []const []const u8) !types.ParsedArgs {
    var parsed = types.ParsedArgs.init(std.testing.allocator);
    parsed.positional = try std.testing.allocator.dupe([]const u8, positional);
    return parsed;
}

test "pin add fails without ever touching gc-roots when the store lock can't be acquired" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path_len = try tmp.dir.realPath(mere.path.currentIo(), &path_buf);
    const root_path = path_buf[0..root_path_len];

    var ctx = mere.Context.init(testing.allocator, root_path);
    defer ctx.deinit();

    // A real, valid store path: if pin.create() were ever reached, this
    // would successfully validate and get pinned. This is what makes the
    // test discriminate the lock failure from a legitimate one.
    const store_dir = try std.fs.path.join(testing.allocator, &.{ root_path, "mere", "store" });
    defer testing.allocator.free(store_dir);
    const store_path = try std.fs.path.join(testing.allocator, &.{ store_dir, ("a" ** 64) ++ "-demo-1.0.0" });
    defer testing.allocator.free(store_path);
    try std.Io.Dir.cwd().createDirPath(mere.path.currentIo(), store_path);

    // mere/.lock is pre-created as a directory, so the store-lock file
    // open must fail, before pin.create ever runs.
    const mere_dir = try std.fs.path.join(testing.allocator, &.{ root_path, "mere" });
    defer testing.allocator.free(mere_dir);
    const lock_path = try std.fs.path.join(testing.allocator, &.{ mere_dir, ".lock" });
    defer testing.allocator.free(lock_path);
    try std.Io.Dir.cwd().createDirPath(mere.path.currentIo(), lock_path);

    var args = try makeArgs(&.{store_path});
    defer args.deinit();

    const result = try pin_cmd.handleAdd(&ctx, &args);
    defer if (result.message) |m| testing.allocator.free(m);

    // Without the store-lock fix, pin.create() would run and this add
    // would legitimately succeed (the store path is real and unpinned).
    try testing.expect(!result.success);

    // Confirm gc-roots was never created: pin.create() never ran because
    // the store lock was never acquired.
    const gc_roots_dir = try std.fs.path.join(testing.allocator, &.{ mere_dir, "gc-roots" });
    defer testing.allocator.free(gc_roots_dir);
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(mere.path.currentIo(), gc_roots_dir, .{}));
}
