/// Service management CLI commands — top-level verbs that delegate to the active provider.
const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const getUserFriendlyMessage = mere.errors.getUserFriendlyMessage;
const ui = mere.ui;
const emit = ui.emit;
const services = mere.services;

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
    services.start(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to start service");
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "started" };
}

fn handleStop(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    services.stop(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to stop service");
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "stopped" };
}

fn handleRestart(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    services.restart(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to restart service");
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "restarted" };
}

fn handleEnable(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    services.enable(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to enable service");
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "enabled" };
}

fn handleDisable(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    services.disable(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to disable service");
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "disabled" };
}

fn handleReload(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    services.reload(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to reload service");
    emit.logLineSeverity(ctx, .service, .info, name);
    return .{ .success = true, .message = "reloaded" };
}

fn handleStatus(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len == 0) return handleList(ctx, args);
    const name = args.positional[0];
    var detail = services.status(ctx, name) catch |err|
        return serviceFailure(ctx, err, "failed to read service status");
    defer detail.deinit(ctx);

    const stderr = std.Io.File.stderr();
    const sio = mere.path.currentIo();
    var buf: [8192]u8 = undefined;
    var writer = stderr.writer(sio, &buf);

    writer.interface.print(
        "\n  Service: {s}\n     Type: {s}\n   OnBoot: {s}\n   Status: {s}\n",
        .{ detail.name, detail.kind.label(), detail.boot_state.label(), detail.state },
    ) catch {};

    for (detail.dependencies.items, 0..) |dep, i| {
        const label: []const u8 = if (i == 0) "  Depends" else "         ";
        writer.interface.print("{s}: {s}\n", .{ label, dep }) catch {};
    }

    if (detail.kind == .daemon) {
        if (detail.pipeline) |pipeline| writer.interface.print(" Pipeline: {s}\n", .{pipeline}) catch {};
        if (detail.log_dir) |log_dir| writer.interface.print("     Logs: {s}\n", .{log_dir}) catch {};
    }

    writer.interface.print("\n", .{}) catch {};
    writer.interface.flush() catch {};
    return .{ .success = true };
}

fn handleLogs(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const name = try requireName(args);
    const sio = mere.path.currentIo();

    const output = services.readLogs(ctx, name) catch |err| switch (err) {
        error.NoLogDirectory => return .{ .success = false, .exit_code = 1, .message = "no log directory for service" },
        error.NoLogFile => return .{ .success = false, .exit_code = 1, .message = "no log file for service" },
        error.OutOfMemory => return .{ .success = false, .exit_code = 1, .message = "out of memory" },
        else => return serviceFailure(ctx, err, "failed to read logs"),
    };
    defer ctx.allocator.free(output);

    if (output.len == 0)
        return .{ .success = true, .message = "log is empty" };

    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(sio, &buf);
    writer.interface.writeAll(output) catch {};
    writer.interface.flush() catch {};

    return .{ .success = true };
}

fn handleList(ctx: *mere.Context, _: *const types.ParsedArgs) MereError!types.CommandResult {
    const sio = mere.path.currentIo();

    const entries = services.list(ctx) catch |err|
        return serviceFailure(ctx, err, "failed to scan service sources");
    defer services.freeList(ctx, entries);

    const stdout = std.Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var writer = stdout.writer(sio, &buf);
    writer.interface.print("\n{s:<24}{s:<14}{s}\n", .{ "Service", "Status", "OnBoot" }) catch {};
    writer.interface.print("{s:<24}{s:<14}{s}\n", .{ "-------", "------", "------" }) catch {};
    for (entries) |entry| {
        writer.interface.print("{s:<24}{s:<14}{s}\n", .{ entry.name, entry.state, entry.boot_state.label() }) catch {};
    }
    writer.interface.print("\n", .{}) catch {};
    writer.interface.flush() catch {};

    return .{ .success = true };
}

fn serviceFailure(ctx: *mere.Context, err: services.ServiceError, fallback: []const u8) !types.CommandResult {
    const message = switch (err) {
        error.UnsupportedProvider => try ctx.allocator.dupe(u8, "configured init provider is not implemented for service management"),
        error.InvalidConfig => blk: {
            const user_message = getUserFriendlyMessage(err);
            const error_ctx = ctx.getDiagnosticContext().toErrorContext();
            const formatted = error_ctx.formatWithMessage(ctx.allocator, user_message) catch
                try ctx.allocator.dupe(u8, user_message);
            break :blk formatted;
        },
        error.OutOfMemory => try ctx.allocator.dupe(u8, "out of memory"),
        error.PermissionDenied => try ctx.allocator.dupe(u8, "permission denied"),
        else => try std.fmt.allocPrint(ctx.allocator, "{s}: {s}", .{ fallback, getUserFriendlyMessage(err) }),
    };
    return .{ .success = false, .exit_code = 1, .message = message };
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
