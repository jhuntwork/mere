//! Guard live service ownership before a system-generation switch.
const std = @import("std");
const mere = @import("mere.zig");
const generation = @import("generation.zig");
const meta = @import("meta.zig");
const dinit = @import("dinit.zig");
const path = @import("path.zig");

/// Everything `checkTransition` learns from the running host. Production uses
/// the defaults; tests substitute fixed answers so the policy can be exercised
/// without a live dinit or a host-root activation.
pub const Probe = struct {
    is_host_root: *const fn ([]const u8) anyerror!bool = probeIsHostRoot,
    is_live_dinit: *const fn (std.mem.Allocator) anyerror!bool = probeIsLiveDinit,
    list_services: *const fn (std.mem.Allocator) anyerror![]const u8 = probeListServices,
    service_status: *const fn (std.mem.Allocator, []const u8) anyerror![]const u8 = probeServiceStatus,
};

fn probeIsHostRoot(root: []const u8) anyerror!bool {
    return isHostRoot(root);
}
fn probeIsLiveDinit(allocator: std.mem.Allocator) anyerror!bool {
    return isLiveDinit(allocator);
}
fn probeListServices(allocator: std.mem.Allocator) anyerror![]const u8 {
    return dinit.listServices(allocator);
}
fn probeServiceStatus(allocator: std.mem.Allocator, name: []const u8) anyerror![]const u8 {
    return dinit.status(allocator, name);
}

pub fn checkTransition(ctx: *mere.Context, previous: []const generation.PackageEntry, target: []const generation.PackageEntry) !void {
    return checkTransitionWith(ctx, previous, target, .{});
}

pub fn checkTransitionWith(ctx: *mere.Context, previous: []const generation.PackageEntry, target: []const generation.PackageEntry, probe: Probe) !void {
    // An image/alternate root must never query the host service manager.
    ctx.debug("service policy root: '{s}'", .{ctx.root_path});
    if (!(probe.is_host_root(ctx.root_path) catch return ctx.fail(error.InvalidInput, ctx.root_path, "cannot resolve activation root; generation not activated"))) return;
    const provider = if (ctx.configuration) |*cfg| cfg.effectiveInitProvider() else .s6rc;
    if (provider != .dinit) return;
    const live = probe.is_live_dinit(ctx.allocator) catch
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
    const loaded = probe.list_services(ctx.allocator) catch
        return ctx.fail(error.InvalidInput, "dinit", "cannot inspect live services; generation not activated");
    defer ctx.allocator.free(loaded);
    var lines = std.mem.splitScalar(u8, loaded, '\n');
    while (lines.next()) |line| {
        const name = (dinit.listedServiceName(line) catch
            return ctx.fail(error.InvalidInput, "dinit", "unrecognized service list; generation not activated")) orelse continue;
        var owned = false;
        for (removed.items) |definition| {
            if (std.mem.eql(u8, definition, name) or (std.mem.startsWith(u8, name, definition) and name.len > definition.len and name[definition.len] == '@')) owned = true;
        }
        if (!owned) continue;
        const status = probe.service_status(ctx.allocator, name) catch
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

// ── Behavioral tests for checkTransition ──────────────────────────────────
// A fixed fake host stands in for dinit. Each test sets the canned answers
// first; tests run sequentially so file-level state is safe.

var fake_host_root: bool = true;
var fake_live_error: ?anyerror = null;
var fake_live: bool = true;
var fake_list_text: []const u8 = "";
var fake_status_text: []const u8 = "    State: started\n";
var fake_list_calls: usize = 0;

fn fakeIsHostRoot(_: []const u8) anyerror!bool {
    return fake_host_root;
}
fn fakeIsLiveDinit(_: std.mem.Allocator) anyerror!bool {
    if (fake_live_error) |err| return err;
    return fake_live;
}
fn fakeListServices(allocator: std.mem.Allocator) anyerror![]const u8 {
    fake_list_calls += 1;
    return allocator.dupe(u8, fake_list_text);
}
fn fakeServiceStatus(allocator: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return allocator.dupe(u8, fake_status_text);
}

const fake_probe: Probe = .{
    .is_host_root = fakeIsHostRoot,
    .is_live_dinit = fakeIsLiveDinit,
    .list_services = fakeListServices,
    .service_status = fakeServiceStatus,
};

fn resetFakes() void {
    fake_host_root = true;
    fake_live_error = null;
    fake_live = true;
    fake_list_text = "";
    fake_status_text = "    State: started\n";
    fake_list_calls = 0;
}

/// Write a package whose metadata declares `names` as services and return an
/// entry pointing at it. Strings live in `arena`.
fn fixturePackage(
    ctx: *mere.Context,
    arena: std.mem.Allocator,
    root: []const u8,
    package_name: []const u8,
    names: []const []const u8,
) !generation.PackageEntry {
    const dir = try std.fs.path.join(arena, &.{ root, package_name });
    try path.ensureDirExists(dir);
    var data = meta.Data.init(ctx.allocator);
    defer data.deinit();
    for (names) |service_name| {
        var service = meta.Service.init(ctx.allocator);
        service.name = try ctx.allocator.dupe(u8, service_name);
        service.service_type = .daemon;
        try service.command.append(ctx.allocator, try ctx.allocator.dupe(u8, "/bin/true"));
        try data.services.append(ctx.allocator, service);
    }
    try meta.writeFile(ctx.allocator, dir, &data);
    return .{
        .name = package_name,
        .version = "1",
        .release = 1,
        .arch = "any",
        .store_path = dir,
        .content_hash = "0" ** 64,
    };
}

const PolicyFixture = struct {
    env: *@import("test_helpers.zig").TestEnv,
    arena: std.heap.ArenaAllocator,

    fn init() !PolicyFixture {
        const th = @import("test_helpers.zig");
        const env = try th.createTestEnv();
        var cfg = mere.config.Config.init(&env.ctx, env.ctx.allocator);
        cfg.init_provider = .dinit;
        env.ctx.configuration = cfg;
        resetFakes();
        return .{ .env = env, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *PolicyFixture) void {
        self.arena.deinit();
        self.env.cleanup();
        std.testing.allocator.destroy(self.env);
    }

    fn package(self: *PolicyFixture, name: []const u8, services: []const []const u8) !generation.PackageEntry {
        return fixturePackage(&self.env.ctx, self.arena.allocator(), self.env.path, name, services);
    }
};

test "service policy refuses removing a service that is active" {
    var fx = try PolicyFixture.init();
    defer fx.deinit();
    const before = try fx.package("daemon-pkg", &.{"worker"});
    fake_list_text = "[[+]     ] worker (pid: 7)\n";
    fake_status_text = "    State: started\n";
    try std.testing.expectError(error.InvalidInput, checkTransitionWith(&fx.env.ctx, &.{before}, &.{}, fake_probe));
}

test "service policy allows removing a service that is stopped" {
    var fx = try PolicyFixture.init();
    defer fx.deinit();
    const before = try fx.package("daemon-pkg", &.{"worker"});
    fake_list_text = "[{ }     ] worker\n";
    fake_status_text = "    State: stopped\n";
    try checkTransitionWith(&fx.env.ctx, &.{before}, &.{}, fake_probe);
}

test "service policy never queries the service manager for an alternate root" {
    var fx = try PolicyFixture.init();
    defer fx.deinit();
    const before = try fx.package("daemon-pkg", &.{"worker"});
    fake_host_root = false;
    fake_list_text = "[[+]     ] worker (pid: 7)\n";
    try checkTransitionWith(&fx.env.ctx, &.{before}, &.{}, fake_probe);
    try std.testing.expectEqual(@as(usize, 0), fake_list_calls);
}

test "service policy fails closed when the service list is malformed" {
    var fx = try PolicyFixture.init();
    defer fx.deinit();
    const before = try fx.package("daemon-pkg", &.{"worker"});
    fake_list_text = "unrecognised output\n";
    try std.testing.expectError(error.InvalidInput, checkTransitionWith(&fx.env.ctx, &.{before}, &.{}, fake_probe));
}

test "service policy fails closed when the service state is unrecognised" {
    var fx = try PolicyFixture.init();
    defer fx.deinit();
    const before = try fx.package("daemon-pkg", &.{"worker"});
    fake_list_text = "[[+]     ] worker (pid: 7)\n";
    fake_status_text = "socket error\n";
    try std.testing.expectError(error.InvalidInput, checkTransitionWith(&fx.env.ctx, &.{before}, &.{}, fake_probe));
}

test "service policy still fails closed on an unreadable init identity when a service is removed" {
    var fx = try PolicyFixture.init();
    defer fx.deinit();
    const before = try fx.package("daemon-pkg", &.{"worker"});
    fake_live_error = error.FileNotFound;
    try std.testing.expectError(error.InvalidInput, checkTransitionWith(&fx.env.ctx, &.{before}, &.{}, fake_probe));
}
