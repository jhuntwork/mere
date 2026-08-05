/// dinit integration for service management.
///
/// Delegates to dinitctl for lifecycle operations. Unlike s6-rc, dinit
/// has no separate compile / prescription / live-database step —
/// service files under `/etc/dinit.d/` and `/usr/share/dinit.d/` are
/// read directly by the running dinit instance.
///
/// If the init system changes, this module is replaced.
const std = @import("std");
const path_mod = @import("path.zig");

fn io() std.Io {
    return path_mod.currentIo();
}

pub const paths = struct {
    pub const pkg_sources = "/usr/share/dinit.d";
    pub const admin_sources = "/etc/dinit.d";
    pub const boot_bundle = "boot";
    pub const log_root = "/var/log";
};

// ── Lifecycle commands ────────────────────────────────────────────

/// Start a service now via dinitctl.
pub fn startService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "start", name });
}

/// Stop a service now via dinitctl.
pub fn stopService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "stop", name });
}

/// Restart a running service via dinitctl.
pub fn restartService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "restart", name });
}

/// Ask dinit to reload the running service's configuration.
pub fn reloadService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "reload", name });
}

/// Add a service to the boot bundle without changing its live state.
pub fn enableService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "enable", "--from", paths.boot_bundle, name });
}

/// Remove a service from the boot bundle without changing its live state.
pub fn disableService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "disable", "--from", paths.boot_bundle, name });
}

/// Scan source paths and return every available service name.
pub fn scanSourceNames(allocator: std.mem.Allocator) ![]const []const u8 {
    var names = std.StringHashMap(void).init(allocator);

    scanNamesFromPath(allocator, paths.pkg_sources, &names);
    scanNamesFromPath(allocator, paths.admin_sources, &names);

    var list: std.ArrayList([]const u8) = .empty;
    var it = names.keyIterator();
    while (it.next()) |key| {
        list.append(allocator, key.*) catch continue;
    }
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn scanNamesFromPath(allocator: std.mem.Allocator, base: []const u8, names: *std.StringHashMap(void)) void {
    var dir = std.Io.Dir.cwd().openDir(io(), base, .{ .iterate = true }) catch return;
    defer dir.close(io());
    var iter = dir.iterate();
    while (iter.next(io()) catch null) |entry| {
        if (entry.name[0] == '.') continue;
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, paths.boot_bundle)) continue;
        const name = allocator.dupe(u8, entry.name) catch continue;
        names.put(name, {}) catch continue;
    }
}

/// Read the configured service type from native dinit source files.
pub fn serviceKind(allocator: std.mem.Allocator, name: []const u8) !enum { daemon, oneshot } {
    const source = try findSourcePath(allocator, name);
    defer if (source) |path| allocator.free(path);
    const path_name = source orelse return error.ProcessFailed;
    const content = std.Io.Dir.cwd().readFileAlloc(io(), path_name, allocator, .limited(1024 * 1024)) catch return error.ProcessFailed;
    defer allocator.free(content);
    if (std.mem.indexOf(u8, content, "type = scripted") != null) return .oneshot;
    return .daemon;
}

/// Return whether the boot bundle declares a dependency on the service.
pub fn isBootEnabled(allocator: std.mem.Allocator, name: []const u8) !bool {
    const content = std.Io.Dir.cwd().readFileAlloc(io(), paths.admin_sources ++ "/" ++ paths.boot_bundle, allocator, .limited(1024 * 1024)) catch |err| {
        return switch (err) {
            error.FileNotFound => false,
            else => error.ProcessFailed,
        };
    };
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "depends-on:")) {
            const dependency = std.mem.trim(u8, trimmed["depends-on:".len..], " \t");
            if (std.mem.eql(u8, dependency, name)) return true;
        }
    }
    return false;
}

fn findSourcePath(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    for ([_][]const u8{ paths.admin_sources, paths.pkg_sources }) |base| {
        const candidate = try std.fs.path.join(allocator, &.{ base, name });
        if (std.Io.Dir.accessAbsolute(io(), candidate, .{})) |_| return candidate else |_| allocator.free(candidate);
    }
    return null;
}

// ── Introspection ─────────────────────────────────────────────────

/// Return dinit's human-readable status output for a service.
pub fn status(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return checkedOutput(allocator, &.{ "dinitctl", "status", name });
}

/// Return true when dinit reports the service as started.
pub fn isStarted(allocator: std.mem.Allocator, name: []const u8) !bool {
    return succeeds(allocator, &.{ "dinitctl", "is-started", name });
}

/// Return true when dinit reports the service as failed.
pub fn isFailed(allocator: std.mem.Allocator, name: []const u8) !bool {
    return succeeds(allocator, &.{ "dinitctl", "is-failed", name });
}

/// Return buffered dinit output. This is distinct from a configured logfile;
/// callers may fall back to the logfile when the service has no output buffer.
pub fn catlog(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return checkedOutput(allocator, &.{ "dinitctl", "catlog", name });
}

fn checkedOutput(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = try run(allocator, argv);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.ProcessFailed;
    }
    return result.stdout;
}

fn succeeds(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    const result = try run(allocator, argv);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited) return error.ProcessFailed;
    return result.term.exited == 0;
}

// ── Helpers ───────────────────────────────────────────────────────

fn exec(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = run(allocator, argv) catch return error.ProcessFailed;
    if (result.term != .exited or result.term.exited != 0) {
        if (result.stderr.len > 0) {
            const stderr = std.Io.File.stderr();
            var buf: [4096]u8 = undefined;
            var writer = stderr.writer(io(), &buf);
            writer.interface.writeAll(result.stderr) catch {};
            writer.interface.flush() catch {};
        }
        return error.ProcessFailed;
    }
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io(), .{ .argv = argv });
}
