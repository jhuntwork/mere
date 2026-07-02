const std = @import("std");
const mere = @import("mere");
const download = mere.download;
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = types.MereError;

const uninstall_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 40,
    .name = "uninstall",
    .description = "Uninstall one or more packages from a profile",
    .args = &[_]types.Arg{
        .{
            .name = "package",
            .description = "Package name(s) to uninstall",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile to uninstall from (default: system)",
            .flag_type = .string,
        },
        .{
            .name = "cascade",
            .description = "Also remove packages that depend on the uninstalled package",
            .flag_type = .bool,
        },
        .{
            .name = "dry-run",
            .description = "Show what would be removed without making changes",
            .flag_type = .bool,
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
    },
};

fn handleUninstall(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len == 0) {
        return MereError.MissingArgument;
    }

    const package_names = args.positional;
    const profile_name = args.getString("profile") orelse "system";
    const verify_store = args.getBool("verify-store");
    const force_sync = args.getBool("sync");
    const cascade = args.getBool("cascade");
    const dry_run = args.getBool("dry-run");

    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(package_names[0]);
    ctx.withDiagnosticContext(diagnostic_ctx);

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const result = performUninstall(ctx, package_names, profile_name, verify_store, force_sync, cascade, dry_run) catch |err| {
        const mapped_error = mere.errors.ErrorMapping.mapZigError(err);
        const current_diag_ctx = ctx.getDiagnosticContext();
        const user_message = mere.errors.getUserFriendlyMessage(err);
        const error_ctx = current_diag_ctx.toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) {
            ctx.allocator.free(formatted_message);
        };
        const exit_code = command.exitCodeForError(mapped_error);
        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    if (result) |msg| {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = msg,
        };
    }

    return types.CommandResult{
        .success = true,
        .message = null,
    };
}

fn performUninstall(
    ctx: *mere.Context,
    package_names: []const []const u8,
    profile_name: []const u8,
    verify_store: bool,
    force_sync: bool,
    cascade: bool,
    dry_run: bool,
) !?[]const u8 {
    _ = try ctx.getConfig();

    var curl_client = try download.CurlTransferClient.init(ctx, command.user_agent);
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    return try mere.install.uninstallPackagesFromConfig(
        ctx,
        package_names,
        client,
        verify_store,
        force_sync,
        profile_name,
        cascade,
        dry_run,
    );
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, uninstall_meta, handleUninstall);
    return cmd;
}
