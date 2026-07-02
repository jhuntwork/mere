/// Provider-neutral service management facade.
///
/// The public functions in this module are the interface used by `mere`
/// commands. The current provider is s6-rc; future providers should implement
/// this surface rather than leaking provider commands into the CLI.
const std = @import("std");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
const s6rc = @import("s6rc.zig");

const Std = errors.StandardErrors;
pub const ServiceError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || error{
    InvalidConfig,
    InvalidInput,
    ProcessFailed,
    NoLogDirectory,
    NoLogFile,
    UnsupportedProvider,
};

pub const ServiceKind = enum {
    daemon,
    oneshot,
    unknown,

    pub fn label(self: ServiceKind) []const u8 {
        return switch (self) {
            .daemon => "longrun",
            .oneshot => "oneshot",
            .unknown => "unknown",
        };
    }
};

pub const BootState = enum {
    enabled,
    disabled,
    essential,
    masked,
    available,
    unknown,

    pub fn label(self: BootState) []const u8 {
        return switch (self) {
            .enabled => "enabled",
            .disabled => "disabled",
            .essential => "essential",
            .masked => "masked",
            .available => "available",
            .unknown => "unknown",
        };
    }
};

pub const StatusDetail = struct {
    name: []const u8,
    kind: ServiceKind,
    boot_state: BootState,
    state: []const u8,
    dependencies: std.ArrayList([]const u8),
    pipeline: ?[]const u8 = null,
    log_dir: ?[]const u8 = null,

    pub fn deinit(self: *StatusDetail, ctx: *mere.Context) void {
        const allocator = ctx.allocator;
        allocator.free(self.state);
        for (self.dependencies.items) |dep| allocator.free(dep);
        self.dependencies.deinit(allocator);
        if (self.pipeline) |pipeline| allocator.free(pipeline);
        if (self.log_dir) |log_dir| allocator.free(log_dir);
    }
};

pub const ListEntry = struct {
    name: []const u8,
    boot_state: BootState,
    state: []const u8,
};

pub fn freeList(ctx: *mere.Context, entries: []ListEntry) void {
    const allocator = ctx.allocator;
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

pub fn start(ctx: *mere.Context, name: []const u8) ServiceError!void {
    try requireS6RcProvider(ctx);
    try s6rc.startService(ctx.allocator, name);
}

pub fn stop(ctx: *mere.Context, name: []const u8) ServiceError!void {
    try requireS6RcProvider(ctx);
    try s6rc.stopService(ctx.allocator, name);
}

pub fn restart(ctx: *mere.Context, name: []const u8) ServiceError!void {
    try requireS6RcProvider(ctx);
    s6rc.stopService(ctx.allocator, name) catch {};
    try s6rc.startService(ctx.allocator, name);
}

pub fn enable(ctx: *mere.Context, name: []const u8) ServiceError!void {
    try requireS6RcProvider(ctx);
    const allocator = ctx.allocator;
    try s6rc.ensureRepo(allocator);
    try s6rc.repoSync(allocator);
    try s6rc.setChange(allocator, "active", name);
    try s6rc.setCommit(allocator);
    try s6rc.setInstall(allocator);
}

pub fn disable(ctx: *mere.Context, name: []const u8) ServiceError!void {
    try requireS6RcProvider(ctx);
    const allocator = ctx.allocator;
    try s6rc.setChange(allocator, "latent", name);
    try s6rc.setCommit(allocator);
    try s6rc.setInstall(allocator);
}

pub fn reload(ctx: *mere.Context, name: []const u8) ServiceError!void {
    try requireS6RcProvider(ctx);
    try s6rc.reloadService(ctx.allocator, name);
}

pub fn status(ctx: *mere.Context, name: []const u8) ServiceError!StatusDetail {
    try requireS6RcProvider(ctx);
    const kind = queryKind(ctx, name);
    const is_up = isUp(ctx, name);

    var detail = StatusDetail{
        .name = name,
        .kind = kind,
        .boot_state = queryBootState(ctx, name),
        .state = try queryState(ctx, name, kind, is_up),
        .dependencies = .empty,
    };
    errdefer detail.deinit(ctx);

    try queryDependencies(ctx, name, &detail.dependencies);

    if (kind == .daemon) {
        detail.pipeline = try queryPipeline(ctx, name);
        detail.log_dir = try queryLogDir(ctx, name);
    }

    return detail;
}

/// Caller owns the returned slice and each entry name; free with `freeList`.
pub fn list(ctx: *mere.Context) ServiceError![]ListEntry {
    try requireS6RcProvider(ctx);
    const allocator = ctx.allocator;
    const all_names = try s6rc.scanSourceNames(allocator);
    defer allocator.free(all_names);

    var entries: std.ArrayList(ListEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    for (all_names) |name| {
        defer allocator.free(name);

        const boot_state = queryBootState(ctx, name);
        if (boot_state == .essential and queryKind(ctx, name) == .oneshot) continue;

        const owned_name = try allocator.dupe(u8, name);
        try entries.append(allocator, .{
            .name = owned_name,
            .boot_state = boot_state,
            .state = if (isFailingLongrun(ctx, name)) "failing" else if (isUp(ctx, name)) "up" else "-",
        });
    }

    std.mem.sort(ListEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ListEntry, b: ListEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    return try entries.toOwnedSlice(allocator);
}

/// Caller owns returned log output and must free it with `ctx.allocator`.
pub fn readLogs(ctx: *mere.Context, name: []const u8) ServiceError![]const u8 {
    try requireS6RcProvider(ctx);
    const allocator = ctx.allocator;
    const log_dir = try logDirPath(allocator, name);
    defer allocator.free(log_dir);

    var dir = std.Io.Dir.cwd().openDir(path_mod.currentIo(), log_dir, .{}) catch return error.NoLogDirectory;
    dir.close(path_mod.currentIo());

    const current = try std.fmt.allocPrint(allocator, "{s}/current", .{log_dir});
    defer allocator.free(current);

    const stat = std.Io.Dir.cwd().statFile(path_mod.currentIo(), current, .{}) catch return error.NoLogFile;
    if (stat.size == 0) return try allocator.dupe(u8, "");

    const cat_cmd = try std.fmt.allocPrint(allocator, "cat {s} | s6-tai64nlocal", .{current});
    defer allocator.free(cat_cmd);

    const result = s6rc.run(allocator, &.{ "sh", "-c", cat_cmd }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const mapped: ServiceError = if (err == error.AccessDenied) error.PermissionDenied else error.FileSystem;
        return ctx.failFmt(mapped, name, "failed to run log command ({s}): {s}", .{ cat_cmd, @errorName(err) });
    };
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.ProcessFailed;
    }
    return result.stdout;
}

fn requireS6RcProvider(ctx: *mere.Context) ServiceError!void {
    const cfg = ctx.getConfig() catch |err| switch (err) {
        error.InvalidConfig => return error.InvalidConfig,
        error.ResourceLimitReached => return error.OutOfMemory,
    };
    switch (cfg.effectiveInitProvider()) {
        .s6rc => {},
        .dinit => return error.UnsupportedProvider,
    }
}

fn queryBootState(ctx: *mere.Context, name: []const u8) BootState {
    const allocator = ctx.allocator;
    const result = s6rc.run(allocator, &.{ "s6-rc-set-status", "-r", s6rc.paths.repository, "current", name }) catch
        return .unknown;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) return .unknown;
    const line = std.mem.trimEnd(u8, result.stdout, "\n");
    const sep = std.mem.indexOfScalar(u8, line, '/') orelse return .unknown;
    return parseBootState(line[sep + 1 ..]);
}

fn parseBootState(rx: []const u8) BootState {
    if (std.mem.eql(u8, rx, "active")) return .enabled;
    if (std.mem.eql(u8, rx, "usable")) return .disabled;
    if (std.mem.eql(u8, rx, "latent")) return .disabled;
    if (std.mem.eql(u8, rx, "always")) return .essential;
    if (std.mem.eql(u8, rx, "masked")) return .masked;
    if (std.mem.eql(u8, rx, "available")) return .available;
    return .unknown;
}

fn queryKind(ctx: *mere.Context, name: []const u8) ServiceKind {
    const allocator = ctx.allocator;
    const result = s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "type", name }) catch
        return .unknown;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (std.mem.startsWith(u8, result.stdout, "longrun")) return .daemon;
    if (std.mem.startsWith(u8, result.stdout, "oneshot")) return .oneshot;
    return .unknown;
}

fn isUp(ctx: *mere.Context, name: []const u8) bool {
    const allocator = ctx.allocator;
    const result = s6rc.run(allocator, &.{ "s6-rc", "-l", s6rc.paths.live_dir, "-a", "list" }) catch
        return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (iter.next()) |line| {
        if (std.mem.eql(u8, line, name)) return true;
    }
    return false;
}

fn queryState(ctx: *mere.Context, name: []const u8, kind: ServiceKind, service_is_up: bool) ServiceError![]const u8 {
    const allocator = ctx.allocator;
    if (kind != .daemon) return try allocator.dupe(u8, if (service_is_up) "done" else "not run");

    const svc_path = try std.fmt.allocPrint(allocator, "/run/service/{s}", .{name});
    defer allocator.free(svc_path);

    const result = s6rc.run(allocator, &.{ "s6-svstat", svc_path }) catch
        return try allocator.dupe(u8, if (service_is_up) "up" else "down");
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0 and result.stdout.len > 0) {
        defer allocator.free(result.stdout);
        return try allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\n"));
    }

    allocator.free(result.stdout);
    return try allocator.dupe(u8, if (service_is_up) "up" else "down");
}

fn isFailingLongrun(ctx: *mere.Context, name: []const u8) bool {
    const allocator = ctx.allocator;
    if (queryKind(ctx, name) != .daemon) return false;

    const svc_path = std.fmt.allocPrint(allocator, "/run/service/{s}", .{name}) catch return false;
    defer allocator.free(svc_path);

    const result = s6rc.run(allocator, &.{ "s6-svstat", "-o", "up", svc_path }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return std.mem.startsWith(u8, result.stdout, "false");
}

fn queryDependencies(ctx: *mere.Context, name: []const u8, dependencies: *std.ArrayList([]const u8)) ServiceError!void {
    const allocator = ctx.allocator;
    const result = s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "dependencies", name }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, result.stdout, "\n"), '\n');
    while (iter.next()) |dep| {
        if (dep.len == 0 or std.mem.startsWith(u8, dep, "s6rc-") or std.mem.endsWith(u8, dep, "-log")) continue;
        try dependencies.append(allocator, try allocator.dupe(u8, dep));
    }
}

fn queryPipeline(ctx: *mere.Context, name: []const u8) ServiceError!?[]const u8 {
    const allocator = ctx.allocator;
    const result = s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "pipeline", name }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) return null;
    return try allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\n"));
}

fn queryLogDir(ctx: *mere.Context, name: []const u8) ServiceError!?[]const u8 {
    const allocator = ctx.allocator;
    const log_dir = try logDirPath(allocator, name);
    errdefer allocator.free(log_dir);

    var dir = std.Io.Dir.cwd().openDir(path_mod.currentIo(), log_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(log_dir);
            return null;
        },
        else => {
            allocator.free(log_dir);
            return null;
        },
    };
    dir.close(path_mod.currentIo());
    return log_dir;
}

fn logDirPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ s6rc.paths.log_root, name });
}

test "service operations reject unimplemented dinit provider" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var cfg = mere.config.Config.init(&test_env.ctx, test_env.ctx.allocator);
    cfg.init_provider = .dinit;
    test_env.ctx.configuration = cfg;

    try std.testing.expectError(error.UnsupportedProvider, start(&test_env.ctx, "ntpd"));
}

test "service operations preserve config load diagnostics" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const config_path = try mere.config.getSystemConfigPath(&test_env.ctx);
    defer test_env.ctx.allocator.free(config_path);

    var file = try mere.path.makePathAndOpenFile(config_path);
    defer file.close(mere.path.currentIo());
    try file.writeStreamingAll(mere.path.currentIo(),
        \\settings {
        \\    init-provider "systemd"
        \\}
    );

    try std.testing.expectError(error.InvalidConfig, start(&test_env.ctx, "ntpd"));
    const diag = test_env.ctx.getDiagnosticContext();
    try std.testing.expectEqualStrings("settings.init-provider", diag.subject.?);
    try std.testing.expect(std.mem.indexOf(u8, diag.details.?, "systemd") != null);
}
