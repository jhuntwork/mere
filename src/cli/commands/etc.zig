const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;

// Import etc module
const etc = @import("mere").etc;
const generation_mod = @import("mere").generation;

fn writeStdout(bytes: []const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    try stdout_writer.interface.writeAll(bytes);
    try stdout_writer.interface.flush();
}

fn stdoutIsTty() bool {
    return std.posix.isatty(std.fs.File.stdout().handle);
}

fn mapPagerError(err: anyerror) MereError {
    return switch (err) {
        error.OutOfMemory => MereError.OutOfMemory,
        else => MereError.FileSystem,
    };
}

fn tryPageWithArgv(allocator: std.mem.Allocator, argv: []const []const u8, input: []const u8) MereError!bool {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| {
        return switch (err) {
            error.FileNotFound => false,
            else => mapPagerError(err),
        };
    };

    if (child.stdin) |stdin_file| {
        stdin_file.writeAll(input) catch |err| switch (err) {
            error.BrokenPipe => {},
            else => return mapPagerError(err),
        };
        stdin_file.close();
        child.stdin = null;
    }

    const term = child.wait() catch |err| return mapPagerError(err);
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn tryPageOutput(ctx: *mere.Context, output: []const u8) MereError!void {
    if (!stdoutIsTty()) {
        writeStdout(output) catch |err| return mapPagerError(err);
        return;
    }

    const pager_env = std.process.getEnvVarOwned(ctx.allocator, "PAGER") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.OutOfMemory => return MereError.OutOfMemory,
        else => null,
    };
    defer if (pager_env) |pager| ctx.allocator.free(pager);

    if (pager_env) |pager| {
        if (pager.len > 0) {
            const pager_argv = [_][]const u8{ "sh", "-c", pager };
            if (try tryPageWithArgv(ctx.allocator, &pager_argv, output)) return;
        }
    }

    const less_argv = [_][]const u8{"less"};
    if (try tryPageWithArgv(ctx.allocator, &less_argv, output)) return;

    const more_argv = [_][]const u8{"more"};
    if (try tryPageWithArgv(ctx.allocator, &more_argv, output)) return;

    writeStdout(output) catch |err| return mapPagerError(err);
}

fn collectUnifiedDiff(ctx: *mere.Context, left_path: []const u8, right_path: []const u8) !struct {
    identical: bool,
    output: []u8,
    stderr: []u8,
} {
    const argv = [_][]const u8{ "diff", "-u", left_path, right_path };
    const result = try std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &argv,
    });
    errdefer {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
    }

    return switch (result.term) {
        .Exited => |code| switch (code) {
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

    const etc_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "etc" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(etc_dir);

    var manifest = loadActiveSystemManifest(ctx) catch |err| {
        return mapActiveManifestError(ctx, err);
    };
    defer manifest.deinit();

    var status = etc.collectStatus(ctx, &manifest, etc_dir) catch |err| {
        return mapEtcCommandError(ctx, err, "failed to inspect /etc state");
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

    const writer = output.writer(ctx.allocator);
    try writer.print(
        "Active system /etc status: {d} differing, {d} missing, {d} unchanged\n",
        .{ status.differing, status.missing, status.identical },
    );

    for (status.entries.items) |entry| {
        if (entry.state == .identical) continue;
        const state_text = switch (entry.state) {
            .missing => "missing",
            .different => "differing",
            .identical => unreachable,
        };
        try writer.print("  {s}: {s} <- {s}\n", .{ state_text, entry.etc_path, entry.package_name });
    }

    try writer.writeAll("\nUse 'mere etc diff <path>' to inspect the active default\n");
    try writer.writeAll("Use 'mere etc apply <path>' to install or replace with the active default\n");

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

    const etc_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "etc" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(etc_dir);

    const requested_path = try resolveEtcPath(ctx, etc_dir, args.positional[0]);
    defer ctx.allocator.free(requested_path);

    var manifest = loadActiveSystemManifest(ctx) catch |err| {
        return mapActiveManifestError(ctx, err);
    };
    defer manifest.deinit();

    var status = etc.collectStatus(ctx, &manifest, etc_dir) catch |err| {
        return mapEtcCommandError(ctx, err, "failed to inspect /etc state");
    };
    defer status.deinit();

    const entry = findTemplateEntry(&status, requested_path) orelse {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "no active system default found for {s}", .{requested_path}),
        };
    };

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

    try tryPageOutput(ctx, diff_result.output);
    return types.CommandResult{ .success = true };
}

/// Apply handler - replace current /etc content with the active default
pub fn handleApply(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const etc_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "etc" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(etc_dir);

    const requested_path = try resolveEtcPath(ctx, etc_dir, args.positional[0]);
    defer ctx.allocator.free(requested_path);

    var manifest = loadActiveSystemManifest(ctx) catch |err| {
        return mapActiveManifestError(ctx, err);
    };
    defer manifest.deinit();

    var status = etc.collectStatus(ctx, &manifest, etc_dir) catch |err| {
        return mapEtcCommandError(ctx, err, "failed to inspect /etc state");
    };
    defer status.deinit();

    const entry = findTemplateEntry(&status, requested_path) orelse {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "no active system default found for {s}", .{requested_path}),
        };
    };

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

fn loadActiveSystemManifest(ctx: *mere.Context) !generation_mod.GenerationManifest {
    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    const current = generation_mod.getCurrentGeneration(profile_dir) catch {
        return MereError.FileSystem;
    } orelse {
        return MereError.InvalidInput;
    };

    const gen_dir = generation_mod.getGenerationPath(ctx.allocator, profile_dir, current) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gen_dir);

    return generation_mod.readManifest(ctx.allocator, gen_dir) catch {
        return MereError.FileSystem;
    };
}

fn mapActiveManifestError(ctx: *mere.Context, err: MereError) types.CommandResult {
    return switch (err) {
        MereError.InvalidInput => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "system profile has no active generation") catch "system profile has no active generation",
        },
        MereError.OutOfMemory => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "out of memory while loading active system generation") catch "out of memory while loading active system generation",
        },
        else => .{
            .success = false,
            .exit_code = 1,
            .message = ctx.allocator.dupe(u8, "failed to read active system generation manifest") catch "failed to read active system generation manifest",
        },
    };
}

fn resolveEtcPath(ctx: *mere.Context, etc_dir: []const u8, raw_path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, raw_path, "/etc/")) {
        return std.fs.path.join(ctx.allocator, &.{ ctx.root_path, raw_path[1..] }) catch MereError.OutOfMemory;
    }
    if (std.mem.startsWith(u8, raw_path, "etc/")) {
        return std.fs.path.join(ctx.allocator, &.{ ctx.root_path, raw_path }) catch MereError.OutOfMemory;
    }
    return std.fs.path.join(ctx.allocator, &.{ etc_dir, raw_path }) catch MereError.OutOfMemory;
}

fn findTemplateEntry(status: *const etc.TemplateStatus, etc_path: []const u8) ?*const etc.TemplateEntry {
    for (status.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.etc_path, etc_path)) return entry;
    }
    return null;
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
