const std = @import("std");
const mere = @import("mere");
const download = mere.download;
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = types.MereError;

const upgrade_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 31,
    .name = "upgrade",
    .description = "Upgrade requested packages in a profile",
    .args = &[_]types.Arg{
        .{
            .name = "package",
            .description = "Requested package name(s); omit to upgrade all roots",
            .required = false,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile to upgrade (default: system)",
            .flag_type = .string,
        },
        .{
            .name = "verify-store",
            .description = "Verify store content hashes during activation (slow)",
            .flag_type = .bool,
        },
        .{
            .name = "sync",
            .description = "Force repository sync even if cache is fresh",
            .flag_type = .bool,
        },
        .{
            .name = "dry-run",
            .description = "Show changes without creating or activating a generation",
            .flag_type = .bool,
        },
    },
};

fn handleUpgrade(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const package_names = args.positional;
    const profile_name = args.getString("profile") orelse "system";
    const verify_store = args.getBool("verify-store");
    const force_sync = args.getBool("sync");
    const dry_run = args.getBool("dry-run");

    ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(
        if (package_names.len > 0) package_names[0] else profile_name,
    ));

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    _ = ctx.getConfig() catch |err| return try command.errorResult(ctx, err, null);
    var curl_client = download.CurlTransferClient.init(ctx, command.user_agent) catch |err| {
        return try command.errorResult(ctx, err, null);
    };
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);

    _ = mere.install.upgradePackagesFromConfig(
        ctx,
        package_names,
        curl_client.client(),
        verify_store,
        force_sync,
        profile_name,
        dry_run,
    ) catch |err| return try command.errorResult(ctx, err, null);

    return .{ .success = true };
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, upgrade_meta, handleUpgrade);
    return cmd;
}
