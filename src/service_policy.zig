//! Guard live service ownership before a system-generation switch.
const std = @import("std");
const mere = @import("mere.zig");
const generation = @import("generation.zig");
const meta = @import("meta.zig");
const dinit = @import("dinit.zig");
const path = @import("path.zig");

pub fn checkTransition(ctx: *mere.Context, previous: []const generation.PackageEntry, target: []const generation.PackageEntry) !void {
    // An image/alternate root must never query the host service manager.
    ctx.debug("service policy root: '{s}'", .{ctx.root_path});
    if (!(isHostRoot(ctx.root_path) catch return ctx.fail(error.InvalidInput, ctx.root_path, "cannot resolve activation root; generation not activated"))) return;
    const provider = if (ctx.configuration) |*cfg| cfg.effectiveInitProvider() else .s6rc;
    if (provider != .dinit) return;
    const live = isLiveDinit(ctx.allocator) catch
        return ctx.fail(error.InvalidInput, "dinit", "cannot determine the active init system; generation not activated");
    ctx.debug("service policy live={}", .{live});
    if (!live) return;
    var old_names = try serviceNames(ctx, previous);
    defer freeNames(ctx.allocator, &old_names);
    var new_names = try serviceNames(ctx, target);
    defer freeNames(ctx.allocator, &new_names);
    var removed: std.ArrayList([]const u8) = .empty;
    defer removed.deinit(ctx.allocator);
    var names = old_names.keyIterator();
    while (names.next()) |name| {
        if (!new_names.contains(name.*)) try removed.append(ctx.allocator, name.*);
    }
    if (removed.items.len == 0) return;
    // A successful list distinguishes an unloaded service from a lost socket.
    const loaded = dinit.listServices(ctx.allocator) catch
        return ctx.fail(error.InvalidInput, "dinit", "cannot inspect live services; generation not activated");
    defer ctx.allocator.free(loaded);
    var lines = std.mem.splitScalar(u8, loaded, '\n');
    while (lines.next()) |line| {
        const name = (dinit.listedServiceName(line) catch
            return ctx.fail(error.InvalidInput, "dinit", "unrecognized service list; generation not activated")) orelse continue;
        var owned = false;
        for (removed.items) |definition| {
            if (std.mem.eql(u8, definition, name) or
                (std.mem.startsWith(u8, name, definition) and name.len > definition.len and name[definition.len] == '@')) owned = true;
        }
        if (!owned) continue;
        const status = dinit.status(ctx.allocator, name) catch
            return ctx.fail(error.InvalidInput, name, "cannot inspect service state; generation not activated");
        defer ctx.allocator.free(status);
        const active = dinit.statusIsActive(status) catch
            return ctx.fail(error.InvalidInput, name, "unrecognized service state; generation not activated");
        if (active) return ctx.failFmt(error.InvalidInput, name, "service '{s}' is active; stop it before activating a generation that removes it", .{name});
    }
}

fn isHostRoot(root: []const u8) !bool {
    var resolved: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.realPathFileAbsolute(path.currentIo(), root, &resolved);
    return std.mem.eql(u8, resolved[0..len], "/");
}

fn isLiveDinit(allocator: std.mem.Allocator) !bool {
    if (std.Io.Dir.accessAbsolute(path.currentIo(), "/run/dinitctl", .{})) |_| return true else |_| {}
    const comm = try readInitComm(allocator);
    defer allocator.free(comm);
    return std.mem.eql(u8, std.mem.trim(u8, comm, " \r\n"), "dinit");
}

fn readInitComm(allocator: std.mem.Allocator) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(path.currentIo(), "/proc/1/comm", .{});
    defer file.close(path.currentIo());
    var buffer: [256]u8 = undefined;
    // procfs reports size zero; a positional reader can mistake it for empty.
    var reader = file.readerStreaming(path.currentIo(), &buffer);
    const comm = try reader.interface.allocRemaining(allocator, .limited(256));
    if (std.mem.trim(u8, comm, " \r\n").len == 0) {
        allocator.free(comm);
        return error.ProcessFailed;
    }
    return comm;
}

fn serviceNames(ctx: *mere.Context, packages: []const generation.PackageEntry) !std.StringHashMap(void) {
    var names = std.StringHashMap(void).init(ctx.allocator);
    errdefer freeNames(ctx.allocator, &names);
    for (packages) |pkg| {
        var data = try meta.readFile(ctx.allocator, pkg.store_path);
        defer data.deinit();
        for (data.services.items) |service| {
            const owned = try ctx.allocator.dupe(u8, service.name);
            const result = names.getOrPut(owned) catch |err| {
                ctx.allocator.free(owned);
                return err;
            };
            if (result.found_existing) ctx.allocator.free(owned);
        }
    }
    return names;
}

fn freeNames(allocator: std.mem.Allocator, names: *std.StringHashMap(void)) void {
    var entries = names.keyIterator();
    while (entries.next()) |name| allocator.free(name.*);
    names.deinit();
}

test "service policy reads procfs init with a streaming reader" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    try std.testing.expect(try isHostRoot("/"));
    try std.testing.expect(try isHostRoot("/."));
    try std.testing.expect(!try isHostRoot(env.path));
    const comm = readInitComm(env.ctx.allocator) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer env.ctx.allocator.free(comm);
    try std.testing.expect(std.mem.trim(u8, comm, " \r\n").len > 0);
}
