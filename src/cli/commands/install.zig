const std = @import("std");
const mere = @import("mere");
const download = mere.download;
const types = @import("../types.zig");
const command = @import("../command.zig");
const sync_command = @import("sync.zig");
const MereError = types.MereError;

/// Install command metadata
const install_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 30,
    .name = "install",
    .description = "Install one or more packages and all dependencies",
    .args = &[_]types.Arg{
        .{
            .name = "package",
            .description = "Package name(s) to install",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile to install to (default: system)",
            .flag_type = .string,
        },
        .{
            .name = "verify-store",
            .description = "Verify store content hashes during activation (slow)",
            .flag_type = .bool,
        },
        .{
            .name = "sync",
            .description = "Refresh repository metadata now, retaining verified-cache fallback",
            .flag_type = .bool,
        },
        .{
            .name = "no-sync",
            .description = "Use verified cached repository metadata without refreshing it",
            .flag_type = .bool,
        },
        .{
            .name = "dry-run",
            .description = "Show changes without creating or activating a generation",
            .flag_type = .bool,
        },
    },
};

/// Install command handler
fn handleInstall(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len == 0) {
        return MereError.MissingArgument;
    }

    const package_names = args.positional;
    const profile_name = args.getString("profile") orelse "system";
    const verify_store = args.getBool("verify-store");
    const sync_policy = sync_command.repositorySyncPolicy(args) catch return MereError.InvalidInput;
    const dry_run = args.getBool("dry-run");

    // Set initial diagnostic context - the subject is the package being installed
    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(package_names[0]);
    ctx.withDiagnosticContext(diagnostic_ctx);

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    // Error boundary: catch all errors and map them to user-friendly messages at CLI boundary
    const success_message = performInstallation(ctx, package_names, profile_name, verify_store, sync_policy, dry_run) catch |err| {
        return try command.errorResult(ctx, err, null);
    };

    // Success case - no error logging needed
    return types.CommandResult{
        .success = true,
        .message = success_message,
    };
}

/// Perform the actual installation logic without error logging
/// All errors are propagated to the CLI boundary for single-point logging
fn performInstallation(
    ctx: *mere.Context,
    package_names: []const []const u8,
    profile_name: []const u8,
    verify_store: bool,
    sync_policy: mere.repocache.SyncPolicy,
    dry_run: bool,
) !?[]const u8 {
    // Ensure configuration is loaded (no logging - errors propagate)
    _ = try ctx.getConfig();

    // Create curl-backed TransferClient (no logging - errors propagate)
    var curl_client = try download.CurlTransferClient.init(ctx, command.user_agent);
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    // Perform installation (no logging - errors propagate)
    const outcome = try mere.install.installPackagesFromConfigWithPreview(ctx, package_names, client, false, verify_store, sync_policy, profile_name, dry_run);
    return switch (outcome) {
        .completed => null,
        .store_only_system_activation_deferred => null,
    };
}

/// Create the install command
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, install_meta, handleInstall);
    return cmd;
}
