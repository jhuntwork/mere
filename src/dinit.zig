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
    const started = isStarted(allocator, name) catch return error.ProcessFailed;
    if (!started) try exec(allocator, &.{ "dinitctl", "reload", name });
    try exec(allocator, &.{ "dinitctl", "start", name });
}

/// Stop a service now via dinitctl.
pub fn stopService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "stop", name });
}

/// Restart a running service via dinitctl.
pub fn restartService(allocator: std.mem.Allocator, name: []const u8) !void {
    // Refresh first: native restart otherwise reuses the cached command.
    // Dinit validates compatible live changes without dropping dependents.
    try exec(allocator, &.{ "dinitctl", "reload", name });
    try exec(allocator, &.{ "dinitctl", "restart", name });
}

/// Signal the running process to reload its configuration without restarting.
pub fn reloadService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "signal", "HUP", name });
}

/// Add a service to the boot bundle without changing its live state.
pub fn enableService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "--offline", "-d", paths.admin_sources, "-d", paths.pkg_sources, "enable", "--from", paths.boot_bundle, name });
}

/// Remove a service from the boot bundle without changing its live state.
pub fn disableService(allocator: std.mem.Allocator, name: []const u8) !void {
    try exec(allocator, &.{ "dinitctl", "--offline", "-d", paths.admin_sources, "-d", paths.pkg_sources, "disable", "--from", paths.boot_bundle, name });
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

/// Read persistent boot intent, independently of dinit's loaded/live graph.
pub fn isBootEnabled(allocator: std.mem.Allocator, name: []const u8) !bool {
    const source = try findSourcePath(allocator, paths.boot_bundle);
    defer if (source) |value| allocator.free(value);
    return bootFileEnables(allocator, source orelse return false, name);
}

fn bootFileEnables(allocator: std.mem.Allocator, source: []const u8, name: []const u8) !bool {
    const content = try std.Io.Dir.cwd().readFileAlloc(io(), source, allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const uncommented = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        const separator = std.mem.indexOfAny(u8, uncommented, "=:") orelse continue;
        const key = std.mem.trim(u8, uncommented[0..separator], " \t");
        const value = std.mem.trim(u8, uncommented[separator + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "depends-on") or std.mem.eql(u8, key, "waits-for") or
            std.mem.eql(u8, key, "depends-ms"))
        {
            if (std.mem.eql(u8, value, name)) return true;
        } else if (std.mem.eql(u8, key, "waits-for.d") or std.mem.eql(u8, key, "depends-on.d") or
            std.mem.eql(u8, key, "depends-ms.d"))
        {
            const directory = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(source).?, value });
            defer allocator.free(directory);
            var dir = std.Io.Dir.openDirAbsolute(io(), directory, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer dir.close(io());
            var entries = dir.iterate();
            while (try entries.next(io())) |entry| {
                // Dinit uses the entry name, even when the symlink target is stale.
                if (std.mem.eql(u8, entry.name, name)) return true;
            }
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

/// A template is a service named with a trailing '@' (for example "getty@").
/// dinit loads an instance such as "getty@tty1" from the template file
/// "getty@". A plain service name never owns instances.
pub fn isTemplateName(name: []const u8) bool {
    return name.len > 1 and name[name.len - 1] == '@';
}

/// The definition file that backs a loaded service name: the name itself, or
/// for an instance "base@arg" the template "base@".
pub fn definitionName(name: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, name, '@') orelse return name;
    if (at == 0 or at + 1 >= name.len) return name;
    return name[0 .. at + 1];
}

/// True when a loaded service belongs to a package-owned definition: an exact
/// match, or an instance of that definition when it is a template.
pub fn ownsLoadedService(definition: []const u8, loaded: []const u8) bool {
    if (std.mem.eql(u8, definition, loaded)) return true;
    if (!isTemplateName(definition)) return false;
    return loaded.len > definition.len and std.mem.startsWith(u8, loaded, definition);
}

/// Essential intent belongs to package metadata, even with an admin override.
pub fn isEssential(allocator: std.mem.Allocator, name: []const u8) !bool {
    return isEssentialIn(allocator, paths.pkg_sources, name);
}

/// Look up the essential marker in `source_dir`. An instance such as "foo@x"
/// has no file of its own, so fall back to its template "foo@".
pub fn isEssentialIn(allocator: std.mem.Allocator, source_dir: []const u8, name: []const u8) !bool {
    if (try essentialMarker(allocator, source_dir, name)) return true;
    const definition = definitionName(name);
    if (std.mem.eql(u8, definition, name)) return false;
    return essentialMarker(allocator, source_dir, definition);
}

fn essentialMarker(allocator: std.mem.Allocator, source_dir: []const u8, name: []const u8) !bool {
    const source = try std.fs.path.join(allocator, &.{ source_dir, name });
    defer allocator.free(source);
    const content = std.Io.Dir.cwd().readFileAlloc(io(), source, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "# mere: essential = true")) return true;
    }
    return false;
}

pub fn listServices(allocator: std.mem.Allocator) ![]const u8 {
    return checkedOutput(allocator, &.{ "dinitctl", "list" });
}

pub fn listedServiceName(line: []const u8) !?[]const u8 {
    if (std.mem.trim(u8, line, " \t\r").len == 0) return null;
    // Dinit 0.22.1 emits a ten-column status field, including nested brackets
    // for an explicitly started service: [[+]     ] name (pid: ...).
    if (line.len < 11 or line[0] != '[' or line[9] != ']' or line[10] != ' ')
        return error.ProcessFailed;
    var fields = std.mem.tokenizeAny(u8, line[11..], " \t\r");
    return fields.next() orelse error.ProcessFailed;
}

pub fn statusIsActive(content: []const u8) !bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "State:")) continue;
        var fields = std.mem.tokenizeAny(u8, trimmed[6..], " \t");
        const state = fields.next() orelse return error.ProcessFailed;
        if (std.ascii.eqlIgnoreCase(state, "stopped")) return false;
        if (std.ascii.eqlIgnoreCase(state, "started") or std.ascii.eqlIgnoreCase(state, "starting") or
            std.ascii.eqlIgnoreCase(state, "stopping")) return true;
        return error.ProcessFailed;
    }
    return error.ProcessFailed;
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

test "boot intent reads native dependencies and directory entries" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const allocator = env.ctx.allocator;
    const boot = try std.fs.path.join(allocator, &.{ env.path, "boot" });
    defer allocator.free(boot);
    const dependencies = try std.fs.path.join(allocator, &.{ env.path, "boot.d" });
    defer allocator.free(dependencies);
    try path_mod.ensureDirExists(dependencies);
    var file = try std.Io.Dir.createFileAbsolute(io(), boot, .{});
    try file.writeStreamingAll(io(), "type = internal\ndepends-on = core\nwaits-for: optional\nwaits-for.d = boot.d\n# depends-on = ignored\n");
    file.close(io());
    try std.testing.expect(try bootFileEnables(allocator, boot, "core"));
    try std.testing.expect(try bootFileEnables(allocator, boot, "optional"));
    try std.testing.expect(!try bootFileEnables(allocator, boot, "ignored"));
    try std.testing.expect(!try bootFileEnables(allocator, boot, "daemon"));
    const link = try std.fs.path.join(allocator, &.{ dependencies, "daemon" });
    defer allocator.free(link);
    try std.Io.Dir.symLinkAbsolute(io(), "/nonexistent-service-source", link, .{});
    try std.testing.expect(try bootFileEnables(allocator, boot, "daemon"));
    try std.Io.Dir.deleteFileAbsolute(io(), link);
    try std.testing.expect(!try bootFileEnables(allocator, boot, "daemon"));
}

test "boot intent live-state parsing fails closed and matches complete names" {
    try std.testing.expectEqualStrings("worker", (try listedServiceName("[[+]     ] worker (pid: 7)")).?);
    try std.testing.expectEqualStrings("worker-old", (try listedServiceName("[{+}     ] worker-old")).?);
    try std.testing.expectError(error.ProcessFailed, listedServiceName("unknown list format"));
    try std.testing.expect(try statusIsActive("    State: started\n"));
    try std.testing.expect(try statusIsActive("    State: stopping\n"));
    try std.testing.expect(!try statusIsActive("    State: STOPPED (dependency failed/terminated)\n"));
    try std.testing.expectError(error.ProcessFailed, statusIsActive("socket error\n"));
}

// ── Template handling ──────────────────────────────
// Test names contain "boot intent" so the existing build.zig filter runs them.

test "boot intent template ownership matches instances only of a template" {
    try std.testing.expect(ownsLoadedService("getty@", "getty@tty1"));
    try std.testing.expect(ownsLoadedService("worker", "worker"));
    try std.testing.expect(!ownsLoadedService("foo", "foo@x"));
    try std.testing.expect(!ownsLoadedService("getty@", "getty"));
    try std.testing.expect(ownsLoadedService("getty@", "getty@"));
}

test "boot intent essential lookup falls back from an instance to its template" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const allocator = env.ctx.allocator;
    const template = try std.fs.path.join(allocator, &.{ env.path, "getty@" });
    defer allocator.free(template);
    var file = try std.Io.Dir.createFileAbsolute(io(), template, .{});
    try file.writeStreamingAll(io(), "type = process\n# mere: essential = true\n");
    file.close(io());
    try std.testing.expect(try isEssentialIn(allocator, env.path, "getty@"));
    try std.testing.expect(try isEssentialIn(allocator, env.path, "getty@tty1"));
    try std.testing.expect(!try isEssentialIn(allocator, env.path, "other@tty1"));
    try std.testing.expect(!try isEssentialIn(allocator, env.path, "getty"));
}
