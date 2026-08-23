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
const cli_mod = @import("cli.zig");
const command = @import("command.zig");

const CaptureEmitter = struct {
    emitter: mere.ui.Emitter,
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) CaptureEmitter {
        return .{ .emitter = .{ .emitFn = onEmit }, .allocator = allocator };
    }

    fn deinit(self: *CaptureEmitter) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }

    fn onEmit(emitter: *mere.ui.Emitter, event: mere.ui.Event) void {
        const self: *CaptureEmitter = @fieldParentPtr("emitter", emitter);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        switch (event.kind) {
            .log_line => line.appendSlice(self.allocator, event.message orelse return) catch return,
            .log_segments => for (event.data.log_segments) |segment| {
                line.appendSlice(self.allocator, segment.text) catch return;
            },
            else => return,
        }
        const owned = line.toOwnedSlice(self.allocator) catch return;
        self.lines.append(self.allocator, owned) catch self.allocator.free(owned);
    }

    fn contains(self: *const CaptureEmitter, needle: []const u8) bool {
        for (self.lines.items) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) return true;
        }
        return false;
    }
};

fn inputFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.InvalidInput, "recipe.kdl", "invalid package field");
}

fn permissionFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.PermissionDenied, "/etc/mere", "permission denied writing configuration");
}

fn filesystemFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.FileSystem, "/mere/store/object", "failed to open store object");
}

fn networkFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.Network, "https://repo.example/index", "connection timed out");
}

fn integrityFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.CorruptData, "/tmp/package.mere", "archive hash mismatch");
}

fn resourceFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.OutOfDisk, "/mere/store", "insufficient space for admission");
}

fn activationFailure(ctx: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return ctx.fail(mere.errors.MereError.CorruptData, "generation 7", "store content hash mismatch during activation");
}

fn expectCommandFailure(
    handler: command.CommandHandler,
    expected_exit: u8,
    expected_subject: []const u8,
    expected_details: []const u8,
) !void {
    var ctx = mere.Context.init(std.testing.allocator, "/test");
    defer ctx.deinit();
    var capture = CaptureEmitter.init(std.testing.allocator);
    defer capture.deinit();
    ctx.setEmitter(&capture.emitter);

    var cli = cli_mod.CLI.init(std.testing.allocator, "mere", &.{});
    defer cli.deinit();
    var probe = command.Command.init(std.testing.allocator, .{
        .name = "probe",
        .description = "exercise the final command boundary",
    }, handler);
    defer probe.deinit();
    try cli.registerCommand(&probe);

    const exit_code = cli.execute(&.{ "mere", "probe" }, &ctx);
    try std.testing.expectEqual(expected_exit, exit_code);
    try std.testing.expect(capture.contains(expected_subject));
    try std.testing.expect(capture.contains(expected_details));
}

fn makeArgs(positional: []const []const u8) !types.ParsedArgs {
    var parsed = types.ParsedArgs.init(std.testing.allocator);
    parsed.positional = try std.testing.allocator.dupe([]const u8, positional);
    return parsed;
}

test "final command boundary preserves category and diagnostics for representative failures" {
    try expectCommandFailure(inputFailure, 2, "recipe.kdl", "invalid package field");
    try expectCommandFailure(permissionFailure, 13, "/etc/mere", "permission denied writing configuration");
    try expectCommandFailure(filesystemFailure, 1, "/mere/store/object", "failed to open store object");
    try expectCommandFailure(networkFailure, 1, "https://repo.example/index", "connection timed out");
    try expectCommandFailure(integrityFailure, 1, "/tmp/package.mere", "archive hash mismatch");
    try expectCommandFailure(resourceFailure, 12, "/mere/store", "insufficient space for admission");
    try expectCommandFailure(activationFailure, 1, "generation 7", "store content hash mismatch during activation");
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
