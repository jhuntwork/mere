const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const path = mere.path;
const MereError = mere.errors.MereError;
const download = mere.download;
const build = mere.build;
const DiagnosticContext = mere.errors.DiagnosticContext;
const getUserFriendlyMessage = mere.errors.getUserFriendlyMessage;

/// Build (dev) subcommand metadata
const build_meta = command.CommandMeta{
    .name = "build",
    .description = "Developer build workflow (executes a recipe inside a namespace)",
    .args = &[_]types.Arg{.{ .name = "recipe", .description = "Path to recipe KDL file", .required = true }},
    .flags = &[_]types.Flag{
        .{
            .name = "no-cache",
            .short = null,
            .description = "Disable build cache reads for this run; fresh results still update cache",
            .flag_type = .bool,
        },
    },
};

/// Build command handler - delegate orchestration to src/recipe.zig
fn handleBuild(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }
    const recipe_path = args.positional[0];
    const cache = !args.getBool("no-cache");

    // Validate user-supplied path at CLI boundary
    if (!path.isValidInputPath(recipe_path)) {
        ctx.setDiagnosticContext(recipe_path, "invalid recipe path");
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid recipe path: '{s}'", .{recipe_path}),
        };
    }

    // Create diagnostic context for the entire build operation
    const diag_ctx = DiagnosticContext.init()
        .withSubject(recipe_path);
    ctx.withDiagnosticContext(diag_ctx);

    // Ensure configuration is loaded for dependency resolution
    _ = ctx.getConfig() catch |err| {
        ctx.setDiagnosticContext("configuration", "failed to load configuration");
        return try command.errorResult(ctx, err, "configuration error");
    };

    // Initialize real curl-backed transfer client for the build request.
    var curl_client = download.CurlTransferClient.init(ctx, command.user_agent) catch |err| {
        ctx.setDiagnosticContext(recipe_path, "failed to initialize download client");
        return try command.errorResult(ctx, err, null);
    };
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    // Load recipe file contents into memory (allocator-owned buffer)
    var buf_path: [std.fs.max_path_bytes]u8 = undefined;
    const abs_recipe_path = path.resolveToAbsolutePath(recipe_path, &buf_path) catch |err| {
        ctx.setDiagnosticContext(recipe_path, "failed to resolve recipe path");
        return try command.errorResult(ctx, err, null);
    };

    var recipe_file = path.openExistingFile(abs_recipe_path) catch |err| {
        ctx.setDiagnosticContext(abs_recipe_path, "failed to open recipe file");
        return try command.errorResult(ctx, err, null);
    };
    defer recipe_file.close(path.currentIo());

    // Prefer explicit size read to avoid readToEndAlloc FileTooBig errors and to validate size.
    const file_size = (recipe_file.stat(path.currentIo()) catch |err| {
        ctx.setDiagnosticContext(abs_recipe_path, "failed to stat recipe file");
        return try command.errorResult(ctx, err, null);
    }).size;

    if (file_size > 1024 * 1024 * 10) {
        ctx.setDiagnosticContext(abs_recipe_path, "recipe file too large");
        return try command.errorResult(ctx, MereError.InvalidInput, "recipe file too large");
    }

    const recipe_buf = try ctx.allocator.alloc(u8, file_size);
    defer ctx.allocator.free(recipe_buf);

    const bytes_read = recipe_file.readPositionalAll(path.currentIo(), recipe_buf, 0) catch |err| {
        ctx.setDiagnosticContext(abs_recipe_path, "failed to read recipe file");
        return try command.errorResult(ctx, err, null);
    };

    if (bytes_read != file_size) {
        ctx.setDiagnosticContext(abs_recipe_path, "short read while reading recipe file");
        return try command.errorResult(ctx, MereError.FileSystem, "short read while reading recipe file");
    }

    var request = build.BuildRequest.init();
    request.recipe_text = recipe_buf;
    const recipe_dir = std.fs.path.dirname(abs_recipe_path) orelse ".";
    request.recipe_dir = recipe_dir;
    request.download_client = client;
    request.cache = cache;

    var result = build.executeBuild(ctx, request) catch |err| {
        // Use existing diagnostic context; only add fallback if empty.
        const diag = ctx.getDiagnosticContext();
        var base_message: []const u8 = switch (err) {
            build.BuildError.OutOfMemory => "insufficient memory for build operation",
            build.BuildError.FileSystem => "file system error during build",
            build.BuildError.PermissionDenied => "permission denied during build",
            build.BuildError.InvalidInput => "invalid build configuration or recipe",
            build.BuildError.Network => "network error during build",
            build.BuildError.WorkspaceCreationFailed => "failed to create build workspace",
            build.BuildError.DependencyInstallFailed => "failed to install recipe dependencies",
            build.BuildError.SourceDownloadFailed => "failed to download recipe sources",
            build.BuildError.PhaseExecutionFailed => "build phase execution failed",
            build.BuildError.SplitStagingFailed => "failed to stage split packages",
            build.BuildError.PackageCreationFailed => "failed to create package archive",
            else => getUserFriendlyMessage(err),
        };
        var diagnostic_subject = diag.subject;
        var diagnostic_details = diag.details;
        if (err == build.BuildError.SourceDownloadFailed and diag.details != null) {
            const details = diag.details.?;
            if (std.mem.indexOf(u8, details, "invalid expected hash") != null) {
                base_message = "invalid source hash in recipe";
            } else if (std.mem.indexOf(u8, details, "hash mismatch") != null or
                std.mem.indexOf(u8, details, "integrity check failed") != null)
            {
                base_message = "source integrity check failed";
            }
        }
        if (err == build.BuildError.InvalidInput and diag.details != null and diag.subject != null) {
            const subject = diag.subject.?;
            if (std.mem.eql(u8, subject, "recipe KDL") or
                std.mem.eql(u8, subject, "recipe.kdl") or
                std.mem.eql(u8, subject, "recipe node") or
                std.mem.eql(u8, subject, "package node"))
            {
                diagnostic_subject = abs_recipe_path;
                base_message = diag.details.?;
                diagnostic_details = null;
            }
        }

        if (diagnostic_subject != null or diagnostic_details != null) {
            ctx.withDiagnosticContext(DiagnosticContext{
                .subject = diagnostic_subject,
                .details = diagnostic_details,
            });
        }
        return try command.errorResult(ctx, err, base_message);
    };
    defer result.deinit();

    return types.CommandResult{
        .success = true,
    };
}

/// Create the build command
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, build_meta, handleBuild);
    return cmd;
}
