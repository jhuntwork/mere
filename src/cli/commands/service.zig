/// Service management CLI commands — top-level verbs that delegate to s6rc.
const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const ui = mere.ui;
const emit = ui.emit;
const s6rc = mere.s6rc;

// ── Command metadata ──────────────────────────────────────────────

const start_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 142,
    .name = "start",
    .description = "Bring a service up now",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

const stop_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 143,
    .name = "stop",
    .description = "Bring a service down now",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

const restart_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 144,
    .name = "restart",
    .description = "Stop and start a service",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

const enable_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 140,
    .name = "enable",
    .description = "Add a service to the boot set",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

const disable_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 141,
    .name = "disable",
    .description = "Remove a service from the boot set",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

const reload_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 145,
    .name = "reload",
    .description = "Signal a service to reload its configuration",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

const status_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 146,
    .name = "status",
    .description = "Show service status (all services, or detail for one)",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name (optional)", .required = false }},
};

const logs_meta = command.CommandMeta{
    .group = "Service Management",
    .order = 148,
    .name = "logs",
    .description = "Show service logs",
    .args = &[_]types.Arg{.{ .name = "name", .description = "Service name" }},
};

// ── Handlers ──────────────────────────────────────────────────────

fn requireName(args: *const types.ParsedArgs) MereError![]const u8 {
    if (args.positional.len > 0) return args.positional[0];
    return MereError.MissingArgument;
}

fn handleStart(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    s6rc.startService(ctx.allocator, name) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to start service" };
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "started" };
}

fn handleStop(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    s6rc.stopService(ctx.allocator, name) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to stop service" };
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "stopped" };
}

fn handleRestart(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    s6rc.stopService(ctx.allocator, name) catch {};
    s6rc.startService(ctx.allocator, name) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to restart service" };
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "restarted" };
}

fn handleEnable(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    const allocator = ctx.allocator;
    s6rc.ensureRepo(allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to initialize service repository" };
    s6rc.repoSync(allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to sync service repository" };
    s6rc.setChange(allocator, "active", name) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to enable service" };
    s6rc.setCommit(allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to commit service changes" };
    s6rc.setInstall(allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to install service changes" };
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "enabled" };
}

fn handleDisable(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    s6rc.setChange(ctx.allocator, "latent", name) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to disable service" };
    s6rc.setCommit(ctx.allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to commit service changes" };
    s6rc.setInstall(ctx.allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to install service changes" };
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "disabled" };
}

fn handleReload(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    s6rc.reloadService(ctx.allocator, name) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to reload service" };
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "reloaded" };
}

fn handleStatus(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len == 0) return handleList(ctx, args);
    const name = args.positional[0];
    const allocator = ctx.allocator;

    const stderr = std.Io.File.stderr();
    const sio = mere.path.currentIo();
    var buf: [8192]u8 = undefined;
    var writer = stderr.writer(sio, &buf);

    // Prescription
    var rx: []const u8 = "unknown";
    if (s6rc.run(allocator, &.{ "s6-rc-set-status", "-r", s6rc.paths.repository, "current", name })) |r| {
        if (r.stdout.len > 0) {
            const line = std.mem.trimEnd(u8, r.stdout, "\n");
            if (std.mem.indexOfScalar(u8, line, '/')) |sep| rx = line[sep + 1 ..];
        }
    } else |_| {}

    // Type
    var svc_type: []const u8 = "unknown";
    if (s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "type", name })) |r| {
        if (r.stdout.len > 0) svc_type = std.mem.trimEnd(u8, r.stdout, "\n");
    } else |_| {}

    const is_longrun = std.mem.eql(u8, svc_type, "longrun");

    // Check if service is in the up set (works without root)
    var is_up = false;
    if (s6rc.run(allocator, &.{ "s6-rc", "-l", s6rc.paths.live_dir, "-a", "list" })) |r| {
        var iter = std.mem.splitScalar(u8, r.stdout, '\n');
        while (iter.next()) |line| {
            if (std.mem.eql(u8, line, name)) {
                is_up = true;
                break;
            }
        }
    } else |_| {}

    writer.interface.print("\n  Service: {s}\n     Type: {s}\n   OnBoot: {s}\n", .{ name, svc_type, friendlyRx(rx) }) catch {};

    if (is_longrun) {
        const svc_path = std.fmt.allocPrint(allocator, "/run/service/{s}", .{name}) catch
            return .{ .success = true };
        defer allocator.free(svc_path);
        if (s6rc.run(allocator, &.{ "s6-svstat", svc_path })) |r| {
            if (r.term == .exited and r.term.exited == 0 and r.stdout.len > 0) {
                writer.interface.print("   Status: {s}\n", .{std.mem.trimEnd(u8, r.stdout, "\n")}) catch {};
            } else {
                writer.interface.print("   Status: {s}\n", .{if (is_up) "up" else "down"}) catch {};
            }
        } else |_| {
            writer.interface.print("   Status: {s}\n", .{if (is_up) "up" else "down"}) catch {};
        }
    } else {
        writer.interface.print("   Status: {s}\n", .{if (is_up) "done" else "not run"}) catch {};
    }

    // Dependencies
    if (s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "dependencies", name })) |r| {
        if (r.stdout.len > 0) {
            var first = true;
            var iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
            while (iter.next()) |dep| {
                if (dep.len == 0 or std.mem.startsWith(u8, dep, "s6rc-") or std.mem.endsWith(u8, dep, "-log")) continue;
                const label: []const u8 = if (first) "  Depends" else "         ";
                writer.interface.print("{s}: {s}\n", .{ label, dep }) catch {};
                first = false;
            }
        }
    } else |_| {}

    if (is_longrun) {
        if (s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "pipeline", name })) |r| {
            if (r.stdout.len > 0)
                writer.interface.print(" Pipeline: {s}\n", .{std.mem.trimEnd(u8, r.stdout, "\n")}) catch {};
        } else |_| {}

        const log_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ s6rc.paths.log_root, name }) catch "";
        _ = std.Io.Dir.cwd().openDir(sio, log_dir, .{}) catch {
            writer.interface.print("\n", .{}) catch {};
            writer.interface.flush() catch {};
            return .{ .success = true };
        };
        writer.interface.print("     Logs: {s}\n", .{log_dir}) catch {};
    }

    writer.interface.print("\n", .{}) catch {};
    writer.interface.flush() catch {};
    return .{ .success = true };
}

fn handleLogs(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    const allocator = ctx.allocator;
    const sio = mere.path.currentIo();

    const log_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ s6rc.paths.log_root, name }) catch
        return .{ .success = false, .exit_code = 1, .message = "out of memory" };
    defer allocator.free(log_dir);

    _ = std.Io.Dir.cwd().openDir(sio, log_dir, .{}) catch
        return .{ .success = false, .exit_code = 1, .message = "no log directory for service" };

    const current = std.fmt.allocPrint(allocator, "{s}/current", .{log_dir}) catch
        return .{ .success = false, .exit_code = 1, .message = "out of memory" };
    defer allocator.free(current);

    const stat = std.Io.Dir.cwd().statFile(sio, current, .{}) catch
        return .{ .success = false, .exit_code = 1, .message = "no log file for service" };

    if (stat.size == 0)
        return .{ .success = true, .message = "log is empty" };

    const cat_cmd = std.fmt.allocPrint(allocator, "cat {s} | s6-tai64nlocal", .{current}) catch
        return .{ .success = false, .exit_code = 1, .message = "out of memory" };
    defer allocator.free(cat_cmd);

    const result = s6rc.run(allocator, &.{ "sh", "-c", cat_cmd }) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to read logs" };

    if (result.stdout.len > 0) {
        const stdout = std.Io.File.stdout();
        var buf: [4096]u8 = undefined;
        var writer = stdout.writer(sio, &buf);
        writer.interface.writeAll(result.stdout) catch {};
        writer.interface.flush() catch {};
    }

    return .{ .success = true };
}

fn handleList(ctx: *mere.Context, _: *const types.ParsedArgs) MereError!types.CommandResult {
    const allocator = ctx.allocator;
    const sio = mere.path.currentIo();

    const all_names = s6rc.scanSourceNames(allocator) catch
        return .{ .success = false, .exit_code = 1, .message = "failed to scan service sources" };

    // Get prescriptions
    var rx_map = std.StringHashMap([]const u8).init(allocator);
    if (s6rc.run(allocator, &.{ "s6-rc-set-status", "-r", s6rc.paths.repository, "current" })) |rx_result| {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rx_result.stdout, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const sep = std.mem.indexOfScalar(u8, line, '/') orelse continue;
            rx_map.put(line[0..sep], line[sep + 1 ..]) catch {};
        }
    } else |_| {}

    // Get up services
    var up_set = std.StringHashMap(void).init(allocator);
    if (s6rc.run(allocator, &.{ "s6-rc", "-l", s6rc.paths.live_dir, "-a", "list" })) |up_result| {
        var up_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, up_result.stdout, "\n"), '\n');
        while (up_iter.next()) |line| {
            if (line.len > 0) up_set.put(line, {}) catch {};
        }
    } else |_| {}

    const ListEntry = struct { name: []const u8, rx: []const u8, state: []const u8 };
    var entries: std.ArrayList(ListEntry) = .empty;

    for (all_names) |name| {
        const rx = rx_map.get(name) orelse "available";

        // Skip essential oneshots
        if (std.mem.eql(u8, rx, "always")) {
            if (s6rc.run(allocator, &.{ "s6-rc-db", "-l", s6rc.paths.live_dir, "type", name })) |r| {
                if (std.mem.startsWith(u8, r.stdout, "oneshot")) continue;
            } else |_| {}
        }

        // Get live state for longruns
        var svc_state: []const u8 = if (up_set.contains(name)) "up" else "-";
        if (up_set.contains(name)) {
            const svc_path = std.fmt.allocPrint(allocator, "/run/service/{s}", .{name}) catch continue;
            if (s6rc.run(allocator, &.{ "s6-svstat", "-o", "up", svc_path })) |r| {
                if (std.mem.startsWith(u8, r.stdout, "false")) svc_state = "failing";
            } else |_| {}
        }

        entries.append(allocator, .{ .name = name, .rx = rx, .state = svc_state }) catch continue;
    }

    std.mem.sort(ListEntry, entries.items, {}, struct {
        fn f(_: void, a: ListEntry, b: ListEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.f);

    const stdout = std.Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var writer = stdout.writer(sio, &buf);
    writer.interface.print("\n{s:<24}{s:<14}{s}\n", .{ "Service", "Status", "OnBoot" }) catch {};
    writer.interface.print("{s:<24}{s:<14}{s}\n", .{ "-------", "------", "------" }) catch {};
    for (entries.items) |entry| {
        writer.interface.print("{s:<24}{s:<14}{s}\n", .{ entry.name, entry.state, friendlyRx(entry.rx) }) catch {};
    }
    writer.interface.print("\n", .{}) catch {};
    writer.interface.flush() catch {};

    return .{ .success = true };
}

// ── Helpers ───────────────────────────────────────────────────────

fn friendlyRx(rx: []const u8) []const u8 {
    if (std.mem.eql(u8, rx, "active")) return "enabled";
    if (std.mem.eql(u8, rx, "usable")) return "disabled";
    if (std.mem.eql(u8, rx, "always")) return "essential";
    if (std.mem.eql(u8, rx, "masked")) return "masked";
    if (std.mem.eql(u8, rx, "available")) return "available";
    return rx;
}

// ── Registration ──────────────────────────────────────────────────

pub fn createCommands(allocator: std.mem.Allocator) ![8]*command.Command {
    const specs = .{
        .{ start_meta, handleStart },
        .{ stop_meta, handleStop },
        .{ restart_meta, handleRestart },
        .{ enable_meta, handleEnable },
        .{ disable_meta, handleDisable },
        .{ reload_meta, handleReload },
        .{ status_meta, handleStatus },
        .{ logs_meta, handleLogs },
    };

    var cmds: [8]*command.Command = undefined;
    inline for (specs, 0..) |spec, i| {
        cmds[i] = try allocator.create(command.Command);
        cmds[i].* = command.Command.init(allocator, spec[0], spec[1]);
    }
    return cmds;
}
