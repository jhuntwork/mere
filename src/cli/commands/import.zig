const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const path = mere.path;
const MereError = mere.errors.MereError;

/// Import command metadata
const import_meta = command.CommandMeta{
    .name = "import",
    .description = "Import package archives into a repository (defaults to /mere/dev/outputs when no package-file is given)",
    .args = &[_]types.Arg{
        .{
            .name = "repo-name",
            .description = "Name of the repository (resolved from /mere/dev/repo/<name>/)",
            .required = true,
        },
        .{
            .name = "package-file",
            .description = "Path(s) to package archive(s) (e.g. .pkg.tar.zst). If omitted, import all archives from /mere/dev/outputs",
            .required = false,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "key",
            .short = 'k',
            .description = "Path to the secret key file (default: ~/.mere/keys/mere.key)",
            .flag_type = .string,
        },
        .{
            .name = "force",
            .short = 'f',
            .description = "Replace existing package if it already exists in the repository",
            .flag_type = .bool,
        },
    },
};

/// Import command handler
fn handleImport(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const repo_name = args.positional[0];
    const positional_package_paths = if (args.positional.len > 1) args.positional[1..] else &[_][]const u8{};

    // Create diagnostic context for this operation
    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(if (positional_package_paths.len > 0) positional_package_paths[0] else repo_name)
        .withDetails(repo_name);
    ctx.withDiagnosticContext(diagnostic_ctx);

    for (positional_package_paths) |package_path| {
        if (!path.isValidInputPath(package_path)) {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try std.fmt.allocPrint(ctx.allocator, "Invalid package file path: '{s}'", .{package_path}),
            };
        }
    }

    // Get key path from flags and validate if provided
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

    // Get force flag
    const force = args.getBool("force");

    var owned_package_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_package_paths.items) |pkg_path| ctx.allocator.free(pkg_path);
        owned_package_paths.deinit(ctx.allocator);
    }

    var package_paths: []const []const u8 = positional_package_paths;
    if (package_paths.len == 0) {
        mere.build.collectBuildOutputPackageArchives(ctx, &owned_package_paths) catch |err| {
            const mapped_error = mere.errors.ErrorMapping.mapModuleError(@TypeOf(err), err);
            const exit_code = command.exitCodeForError(mapped_error);
            const user_message = mere.errors.getUserFriendlyMessage(err);
            return types.CommandResult{
                .success = false,
                .exit_code = exit_code,
                .message = try std.fmt.allocPrint(ctx.allocator, "Failed to collect package archives from /mere/dev/outputs: {s}", .{user_message}),
            };
        };
        package_paths = owned_package_paths.items;
    }

    // Error boundary: catch all errors and map them to user-friendly messages at CLI boundary
    performImport(ctx, repo_name, package_paths, force) catch |err| {
        // Map error to MereError vocabulary
        const mapped_error = mere.errors.ErrorMapping.mapModuleError(@TypeOf(err), err);

        // Get user-friendly error message and format with context
        const user_message = mere.errors.getUserFriendlyMessage(err);
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) ctx.allocator.free(formatted_message);

        // Return error result with appropriate exit code
        // Note: Don't log here - the CLI layer handles error output via CommandResult.message
        const exit_code = command.exitCodeForError(mapped_error);

        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    // Success case - no error logging needed
    var count_buf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{package_paths.len}) catch return MereError.OutOfMemory;
    const segments = [_]mere.ui.Segment{
        .{ .text = "packages ", .kind = .normal },
        .{ .text = "imported", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = count_text, .kind = .detail },
        .{ .text = " to repository '", .kind = .normal },
        .{ .text = repo_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Perform the actual import logic without error logging
/// All errors are propagated to the CLI boundary for single-point logging
fn performImport(ctx: *mere.Context, repo_name: []const u8, package_paths: []const []const u8, force: bool) !void {
    try mere.import.packages(ctx, repo_name, package_paths, force);
}

/// Create the import command
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, import_meta, handleImport);
    return cmd;
}
