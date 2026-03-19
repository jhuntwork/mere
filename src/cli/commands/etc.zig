const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const path = mere.path;

// Import etc module
const etc = @import("mere").etc;

fn writeStdout(bytes: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(path.currentIo(), &stdout_buf);
    try stdout_writer.interface.writeAll(bytes);
    try stdout_writer.interface.flush();
}

fn stdoutIsTty() bool {
    return std.Io.File.stdout().isTty(path.currentIo()) catch false;
}

fn mapPagerError(err: anyerror) MereError {
    return switch (err) {
        error.OutOfMemory => MereError.OutOfMemory,
        else => MereError.FileSystem,
    };
}

fn tryPageWithArgv(argv: []const []const u8, input: []const u8) MereError!bool {
    var child = std.process.spawn(path.currentIo(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        return switch (err) {
            error.FileNotFound => false,
            else => mapPagerError(err),
        };
    };
    defer child.kill(path.currentIo());

    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(path.currentIo(), input) catch |err| switch (err) {
            error.BrokenPipe => {},
            else => return mapPagerError(err),
        };
        stdin_file.close(path.currentIo());
        child.stdin = null;
    }

    const term = child.wait(path.currentIo()) catch |err| return mapPagerError(err);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn tryPageOutput(output: []const u8) MereError!void {
    if (!stdoutIsTty()) {
        writeStdout(output) catch |err| return mapPagerError(err);
        return;
    }

    const pager_env = if (std.c.getenv("PAGER")) |pager| std.mem.span(pager) else null;

    if (pager_env) |pager| {
        if (pager.len > 0) {
            const pager_argv = [_][]const u8{ "sh", "-c", pager };
            if (try tryPageWithArgv(&pager_argv, output)) return;
        }
    }

    const less_argv = [_][]const u8{"less"};
    if (try tryPageWithArgv(&less_argv, output)) return;

    const more_argv = [_][]const u8{"more"};
    if (try tryPageWithArgv(&more_argv, output)) return;

    writeStdout(output) catch |err| return mapPagerError(err);
}

fn collectUnifiedDiff(ctx: *mere.Context, left_path: []const u8, right_path: []const u8) !struct {
    identical: bool,
    output: []u8,
    stderr: []u8,
} {
    const argv = [_][]const u8{ "diff", "-u", left_path, right_path };
    const result = try std.process.run(ctx.allocator, path.currentIo(), .{
        .argv = &argv,
    });
    errdefer {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
    }

    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => .{ .identical = true, .output = result.stdout, .stderr = result.stderr },
            1 => .{ .identical = false, .output = result.stdout, .stderr = result.stderr },
            else => {
                ctx.allocator.free(result.stdout);
                ctx.allocator.free(result.stderr);
                return MereError.FileSystem;
            },
        },
        else => {
            ctx.allocator.free(result.stdout);
            ctx.allocator.free(result.stderr);
            return MereError.FileSystem;
        },
    };
}

/// Etc command metadata
const etc_meta = command.CommandMeta{
    .name = "etc",
    .description = "Manage /etc configuration files",
};

fn etcPathResult(
    ctx: *mere.Context,
    action: []const u8,
    path_text: []const u8,
    backup_path: ?[]const u8,
) !types.CommandResult {
    if (backup_path) |backup| {
        const segments = [_]mere.ui.Segment{
            .{ .text = "active default ", .kind = .normal },
            .{ .text = action, .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = path_text, .kind = .detail },
            .{ .text = " (backup at ", .kind = .normal },
            .{ .text = backup, .kind = .detail },
            .{ .text = ")", .kind = .normal },
        };
        return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
    }

    const segments = [_]mere.ui.Segment{
        .{ .text = "active default ", .kind = .normal },
        .{ .text = action, .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = path_text, .kind = .detail },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Status subcommand metadata
const status_meta = command.CommandMeta{
    .name = "status",
    .description = "Show /etc drift relative to the active system generation",
};

/// Diff subcommand metadata
const diff_meta = command.CommandMeta{
    .name = "diff",
    .description = "Show diff between /etc and the active system default",
    .args = &[_]types.Arg{
        .{
            .name = "path",
            .description = "Path under /etc managed by the active system generation",
            .required = true,
        },
    },
};

/// Apply subcommand metadata
const apply_meta = command.CommandMeta{
    .name = "apply",
    .description = "Replace /etc with the active system default (backs up to .old)",
    .args = &[_]types.Arg{
        .{
            .name = "path",
            .description = "Path under /etc managed by the active system generation",
            .required = true,
        },
    },
};

/// Main etc command handler
fn handleEtc(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// Status handler - inspect live /etc drift against active defaults
pub fn handleStatus(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = args;

    var status = etc.collectActiveStatus(ctx) catch |err| {
        return mapActiveStatusError(ctx, err);
    };
    defer status.deinit();

    if (status.missing == 0 and status.differing == 0) {
        return types.CommandResult{
            .success = true,
            .message = try ctx.allocator.dupe(u8, "No /etc drift relative to the active system generation"),
        };
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &output);
    const out = &out_buf.writer;
    out.print(
        "Active system /etc status: {d} differing, {d} missing, {d} unchanged\n",
        .{ status.differing, status.missing, status.identical },
    ) catch return MereError.OutOfMemory;

    for (status.entries.items) |entry| {
        if (entry.state == .identical) continue;
        const state_text = switch (entry.state) {
            .missing => "missing",
            .different => "differing",
            .identical => unreachable,
        };
        out.print("  {s}: {s} <- {s}\n", .{ state_text, entry.etc_path, entry.package_name }) catch return MereError.OutOfMemory;
    }

    out.writeAll("\nUse 'mere etc diff <path>' to inspect the active default\n") catch return MereError.OutOfMemory;
    out.writeAll("Use 'mere etc apply <path>' to install or replace with the active default\n") catch return MereError.OutOfMemory;
    output = out_buf.toArrayList();

    return types.CommandResult{
        .success = true,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// Diff handler - show diff between current /etc content and the active default
pub fn handleDiff(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    var lookup = etc.lookupActiveTemplate(ctx, args.positional[0]) catch |err| {
        return mapActiveLookupError(ctx, args.positional[0], err);
    };
    defer lookup.deinit();
    const entry = lookup.entry();

    const left_path = if (entry.state == .missing) "/dev/null" else entry.etc_path;
    const diff_result = collectUnifiedDiff(ctx, left_path, entry.source_path) catch |err| {
        return switch (err) {
            MereError.OutOfMemory => MereError.OutOfMemory,
            else => types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "failed to run diff -u"),
            },
        };
    };
    defer ctx.allocator.free(diff_result.output);
    defer ctx.allocator.free(diff_result.stderr);

    if (diff_result.identical) {
        return types.CommandResult{
            .success = true,
            .message = try ctx.allocator.dupe(u8, "Files are identical"),
        };
    }

    try tryPageOutput(diff_result.output);
    return types.CommandResult{ .success = true };
}

/// Apply handler - replace current /etc content with the active default
pub fn handleApply(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    var lookup = etc.lookupActiveTemplate(ctx, args.positional[0]) catch |err| {
        return mapActiveLookupError(ctx, args.positional[0], err);
    };
    defer lookup.deinit();
    const entry = lookup.entry();

    if (entry.state == .identical) {
        const segments = [_]mere.ui.Segment{
            .{ .text = "active default already matches: ", .kind = .normal },
            .{ .text = entry.etc_path, .kind = .detail },
        };
        return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
    }

    etc.applyTemplate(ctx, entry.source_path, entry.etc_path) catch |err| {
        return mapEtcCommandError(ctx, err, "failed to apply active system default");
    };

    if (entry.state == .missing) {
        return etcPathResult(ctx, "installed", entry.etc_path, null);
    }

    const backup_path = try std.fmt.allocPrint(ctx.allocator, "{s}.old", .{entry.etc_path});
    return etcPathResult(ctx, "applied", entry.etc_path, backup_path);
}

fn mapEtcCommandError(ctx: *mere.Context, err: etc.EtcError, default_msg: []const u8) !types.CommandResult {
    const msg = switch (err) {
        etc.EtcError.DuplicateTemplate => "duplicate /etc template in active system generation",
        etc.EtcError.PermissionDenied => "permission denied",
        else => default_msg,
    };
    return types.CommandResult{
        .success = false,
        .exit_code = 1,
        .message = try ctx.allocator.dupe(u8, msg),
    };
}

fn mapActiveStatusError(ctx: *mere.Context, err: etc.ActiveStatusError) types.CommandResult {
    return switch (err) {
        error.NoActiveGeneration => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "system profile has no active generation") catch "system profile has no active generation",
        },
        error.OutOfMemory => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "out of memory while loading active system generation") catch "out of memory while loading active system generation",
        },
        error.DuplicateTemplate => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "duplicate /etc template in active system generation") catch "duplicate /etc template in active system generation",
        },
        error.PermissionDenied => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "permission denied") catch "permission denied",
        },
        else => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "failed to inspect /etc state") catch "failed to inspect /etc state",
        },
    };
}

fn mapActiveLookupError(ctx: *mere.Context, raw_path: []const u8, err: etc.ActiveLookupError) !types.CommandResult {
    return switch (err) {
        error.TemplateNotFound => .{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "no active system default found for {s}", .{raw_path}),
        },
        else => mapActiveStatusError(ctx, switch (err) {
            error.NoActiveGeneration => error.NoActiveGeneration,
            error.OutOfMemory => error.OutOfMemory,
            error.PermissionDenied => error.PermissionDenied,
            error.DuplicateTemplate => error.DuplicateTemplate,
            else => error.FileSystem,
        }),
    };
}

/// Create the etc command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const etc_cmd = try allocator.create(command.Command);
    etc_cmd.* = command.Command.init(allocator, etc_meta, handleEtc);

    const status_cmd = try allocator.create(command.Command);
    status_cmd.* = command.Command.init(allocator, status_meta, handleStatus);

    const diff_cmd = try allocator.create(command.Command);
    diff_cmd.* = command.Command.init(allocator, diff_meta, handleDiff);

    const apply_cmd = try allocator.create(command.Command);
    apply_cmd.* = command.Command.init(allocator, apply_meta, handleApply);

    try etc_cmd.addSubcommand(status_cmd);
    try etc_cmd.addSubcommand(diff_cmd);
    try etc_cmd.addSubcommand(apply_cmd);

    return etc_cmd;
}
