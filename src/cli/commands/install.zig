const std = @import("std");
const mere = @import("mere");
const download = mere.download;
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = types.MereError;

/// Install command metadata
const install_meta = command.CommandMeta{
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
            .description = "Force repository sync even if cache is fresh",
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
    const force_sync = args.getBool("sync");

    // Set initial diagnostic context - the subject is the package being installed
    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(package_names[0]);
    ctx.withDiagnosticContext(diagnostic_ctx);

    // Error boundary: catch all errors and map them to user-friendly messages at CLI boundary
    const success_message = performInstallation(ctx, package_names, profile_name, verify_store, force_sync) catch |err| {
        // Map error to MereError vocabulary
        const mapped_error = mere.errors.ErrorMapping.mapZigError(err);

        // Get the current diagnostic context (may have been updated by module functions)
        const current_diag_ctx = ctx.getDiagnosticContext();

        // Get user-friendly error message
        const user_message = mere.errors.getUserFriendlyMessage(err);

        // Format: "{error_message}: \"{subject}\"" or "{error_message}: \"{subject}\" - {details}"
        const error_ctx = current_diag_ctx.toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) {
            ctx.allocator.free(formatted_message);
        };

        // Return error result with appropriate exit code
        // Note: CLI system will print the message, following single-point logging pattern
        const exit_code = command.exitCodeForError(mapped_error);

        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
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
    force_sync: bool,
) !?[]const u8 {
    // Ensure configuration is loaded (no logging - errors propagate)
    _ = try ctx.getConfig();

    // Create curl-backed TransferClient (no logging - errors propagate)
    var curl_client = try download.CurlTransferClient.init(ctx);
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    // Perform installation (no logging - errors propagate)
    const outcome = try mere.install.installPackagesFromConfig(ctx, package_names, client, false, verify_store, force_sync, profile_name);
    return switch (outcome) {
        .completed => "Package installed successfully",
        .store_only_system_activation_deferred => null,
    };
}

/// Create the install command
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, install_meta, handleInstall);
    return cmd;
}
