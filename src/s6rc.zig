/// s6-rc integration for service management.
///
/// Delegates to s6-rc repo commands for prescription management,
/// compilation, and live database installation.
///
/// Stores (source definition directories) are registered with the
/// repository via s6-rc-repo-init; the repo commands handle merging,
/// compilation, and conflict detection internally.
///
/// If the init system changes, this module is replaced.
const std = @import("std");
const path_mod = @import("path.zig");

fn io() std.Io {
    return path_mod.currentIo();
}

pub const paths = struct {
    pub const pkg_sources = "/usr/share/s6-rc/sources";
    pub const admin_sources = "/etc/s6-rc/sources";
    pub const repository = "/var/lib/s6-rc/repository";
    pub const live_dir = "/run/s6-rc";
    pub const log_root = "/var/log";
};

// ── Repo commands ─────────────────────────────────────────────────

/// Ensure the repository exists and its store list is current.
/// Creates the repo if missing, updates stores if it already exists.
pub fn ensureRepo(allocator: std.mem.Allocator) !void {
    const result = run(allocator, &.{ "s6-rc-repo-list", "-r", paths.repository }) catch
        return try initRepo(allocator);
    if (result.term != .exited or result.term.exited != 0)
        return try initRepo(allocator);
    // Repo exists — ensure store list is up to date.
    try updateStores(allocator);
}

fn initRepo(allocator: std.mem.Allocator) !void {
    try exec(allocator, &.{ "s6-rc-repo-init", "-r", paths.repository, paths.pkg_sources, paths.admin_sources });
    try exec(allocator, &.{ "s6-rc-set-new", "-r", paths.repository, "current" });
}

fn updateStores(allocator: std.mem.Allocator) !void {
    try exec(allocator, &.{ "s6-rc-repo-init", "-U", "-r", paths.repository, paths.pkg_sources, paths.admin_sources });
}

pub fn repoSync(allocator: std.mem.Allocator) !void {
    try exec(allocator, &.{ "s6-rc-repo-sync", "-r", paths.repository });
}

pub fn setChange(allocator: std.mem.Allocator, rx: []const u8, service: []const u8) !void {
    try exec(allocator, &.{ "s6-rc-set-change", "-I", "pull", "-r", paths.repository, "current", rx, service });
}

pub fn setCommit(allocator: std.mem.Allocator) !void {
    try exec(allocator, &.{ "s6-rc-set-commit", "-r", paths.repository, "current" });
}

pub fn setInstall(allocator: std.mem.Allocator) !void {
    try exec(allocator, &.{ "s6-rc-set-install", "-r", paths.repository, "-l", paths.live_dir, "current" });
}

/// Ensure the live database is up to date. Called lazily by start/stop.
pub fn ensureInstalled(allocator: std.mem.Allocator) !void {
    ensureRepo(allocator) catch {};
    repoSync(allocator) catch {};
    try setCommit(allocator);
    try setInstall(allocator);
}

/// Start a service now. Ensures live db is current first.
pub fn startService(allocator: std.mem.Allocator, name: []const u8) !void {
    ensureInstalled(allocator) catch {};
    try exec(allocator, &.{ "s6-rc", "-l", paths.live_dir, "-u", "change", name });
}

/// Stop a service now. Ensures live db is current first.
pub fn stopService(allocator: std.mem.Allocator, name: []const u8) !void {
    ensureInstalled(allocator) catch {};
    try exec(allocator, &.{ "s6-rc", "-l", paths.live_dir, "-d", "change", name });
}

/// Send SIGHUP to a running longrun service.
pub fn reloadService(allocator: std.mem.Allocator, name: []const u8) !void {
    const svc_path = try std.fmt.allocPrint(allocator, "/run/service/{s}", .{name});
    defer allocator.free(svc_path);
    try exec(allocator, &.{ "s6-svc", "-h", svc_path });
}

/// Scan source paths and return all available service names (excludes log services and s6rc internals).
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
        if (entry.kind != .directory) continue;
        if (std.mem.endsWith(u8, entry.name, "-log")) continue;
        if (std.mem.startsWith(u8, entry.name, "s6rc-")) continue;
        const name = allocator.dupe(u8, entry.name) catch continue;
        names.put(name, {}) catch continue;
    }
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
