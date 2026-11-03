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
    const exists = blk: {
        const result = run(allocator, &.{ "s6-rc-repo-list", "-r", paths.repository }) catch break :blk false;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        break :blk result.term == .exited and result.term.exited == 0;
    };
    if (!exists) return try initRepo(allocator);
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
pub fn scanSourceNames(allocator: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    var names = std.StringHashMap(void).init(allocator);
    // The keys are returned to the caller; only the map's own storage is
    // released on success. On failure the keys go too.
    defer names.deinit();
    errdefer {
        var keys = names.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
    }

    try scanNamesFromPath(allocator, pkgSources(), &names);
    try scanNamesFromPath(allocator, adminSources(), &names);

    var list = try std.ArrayList([]const u8).initCapacity(allocator, names.count());
    errdefer list.deinit(allocator);
    var it = names.keyIterator();
    while (it.next()) |key| list.appendAssumeCapacity(key.*);
    return list.toOwnedSlice(allocator);
}

fn scanNamesFromPath(allocator: std.mem.Allocator, base: []const u8, names: *std.StringHashMap(void)) error{OutOfMemory}!void {
    var dir = std.Io.Dir.cwd().openDir(io(), base, .{ .iterate = true }) catch return;
    defer dir.close(io());
    var iter = dir.iterate();
    while (iter.next(io()) catch null) |entry| {
        if (entry.name[0] == '.') continue;
        if (entry.kind != .directory) continue;
        if (std.mem.endsWith(u8, entry.name, "-log")) continue;
        if (std.mem.startsWith(u8, entry.name, "s6rc-")) continue;
        // A name present in both directories (an administrator override) is
        // already recorded; recording it again would leak the second copy.
        if (names.contains(entry.name)) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.put(name, {});
    }
}

// ── Helpers ───────────────────────────────────────────────────────

fn exec(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = run(allocator, argv) catch return error.ProcessFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
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

/// Runs a command and returns its result. Replaced in tests so s6 commands can
/// be faked without an s6 installation.
pub const Runner = *const fn (std.mem.Allocator, []const []const u8) anyerror!std.process.RunResult;

var runner: Runner = defaultRunner;

fn defaultRunner(allocator: std.mem.Allocator, argv: []const []const u8) anyerror!std.process.RunResult {
    return std.process.run(allocator, io(), .{ .argv = argv });
}

/// Test hook: route every s6 command through `replacement`. Pass null to restore.
pub fn setRunnerForTest(replacement: ?Runner) void {
    runner = replacement orelse defaultRunner;
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return runner(allocator, argv);
}

var source_dirs_override: ?struct { pkg: []const u8, admin: []const u8 } = null;

fn pkgSources() []const u8 {
    return if (source_dirs_override) |dirs| dirs.pkg else paths.pkg_sources;
}

fn adminSources() []const u8 {
    return if (source_dirs_override) |dirs| dirs.admin else paths.admin_sources;
}

/// Test hook: scan `pkg` and `admin` instead of the system directories.
pub fn setSourceDirsForTest(pkg: ?[]const u8, admin: ?[]const u8) void {
    source_dirs_override = if (pkg != null and admin != null) .{ .pkg = pkg.?, .admin = admin.? } else null;
}
