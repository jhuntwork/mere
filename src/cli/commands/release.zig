const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const path = mere.path;
const MereError = mere.errors.MereError;

/// Release command metadata (parent for `publish`, and any future
/// release-related subcommands).
const release_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 135,
    .name = "release",
    .description = "Build and publish signed release output from a dev repository",
};

/// Publish subcommand metadata
const publish_meta = command.CommandMeta{
    .name = "publish",
    .description = "Build and sign a public release output (repo.db, repo.db.sig, packages/) from a dev repository",
    .flags = &[_]types.Flag{
        .{
            .name = "dev-repo",
            .description = "Path to the dev repository directory to publish from (sole source of truth)",
            .flag_type = .string,
            .required = true,
            .value_name = "PATH",
        },
        .{
            .name = "output",
            .description = "Path to the release output directory (write-only target: repo.db, repo.db.sig, packages/)",
            .flag_type = .string,
            .required = true,
            .value_name = "PATH",
        },
        .{
            .name = "key",
            .short = 'k',
            .description = "Path to the secret key file (default: ~/.mere/keys/mere.key)",
            .flag_type = .string,
        },
    },
};

/// Release parent command handler - shows help when no subcommand is given
fn handleRelease(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// Resolve a user-supplied (possibly relative) path to an absolute,
/// ctx.allocator-owned path. Returns null and sets a CommandResult-ready
/// error via the caller's fallback if resolution fails.
fn resolveOwnedAbsolutePath(ctx: *mere.Context, raw_path: []const u8) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = path.resolveToAbsolutePath(raw_path, &buf) catch return null;
    return try ctx.allocator.dupe(u8, resolved);
}

fn handlePublish(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const dev_repo = args.getString("dev-repo") orelse return MereError.MissingArgument;
    const output = args.getString("output") orelse return MereError.MissingArgument;

    if (!path.isValidInputPath(dev_repo)) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid dev repo path: '{s}'", .{dev_repo}),
        };
    }
    if (!path.isValidInputPath(output)) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid output path: '{s}'", .{output}),
        };
    }

    const key_path = args.getString("key");
    if (key_path) |kp| {
        if (!path.isValidInputPath(kp)) {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try std.fmt.allocPrint(ctx.allocator, "Invalid key file path: '{s}'", .{kp}),
            };
        }
    }
    ctx.signing_key_path = key_path;

    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(dev_repo)
        .withDetails(output);
    ctx.withDiagnosticContext(diagnostic_ctx);

    const abs_dev_repo = (try resolveOwnedAbsolutePath(ctx, dev_repo)) orelse {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Failed to resolve dev repo path: '{s}'", .{dev_repo}),
        };
    };
    defer ctx.allocator.free(abs_dev_repo);

    const abs_output = (try resolveOwnedAbsolutePath(ctx, output)) orelse {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Failed to resolve output path: '{s}'", .{output}),
        };
    };
    defer ctx.allocator.free(abs_output);

    mere.release.publish(ctx, abs_dev_repo, abs_output) catch |err| {
        return try command.errorResult(ctx, err, null);
    };

    const segments = [_]mere.ui.Segment{
        .{ .text = "release ", .kind = .normal },
        .{ .text = "published", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = output, .kind = .detail },
        .{ .text = "' from dev repo '", .kind = .normal },
        .{ .text = dev_repo, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Create the release command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const release_cmd = try allocator.create(command.Command);
    release_cmd.* = command.Command.init(allocator, release_meta, handleRelease);

    const publish_cmd = try allocator.create(command.Command);
    publish_cmd.* = command.Command.init(allocator, publish_meta, handlePublish);
    try release_cmd.addSubcommand(publish_cmd);

    return release_cmd;
}
