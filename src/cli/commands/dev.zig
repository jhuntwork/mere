const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const import_cmd = @import("import.zig");
const build_cmd = @import("build.zig");
const dev_cleanup = mere.dev_cleanup;
const hash = mere.hash;
const path = mere.path;
const repo_history = mere.repo_history;
const Repository = mere.repository.Repository;
const RepoError = mere.repository.Error;
const MereError = mere.errors.MereError;
const DiagnosticContext = mere.errors.DiagnosticContext;
const ErrorMapping = mere.errors.ErrorMapping;
const getUserFriendlyMessage = mere.errors.getUserFriendlyMessage;

/// Dev command metadata
const dev_meta = command.CommandMeta{
    .name = "dev",
    .description = "Developer utilities for Mere package management",
};

/// Hash subcommand metadata
const hash_meta = command.CommandMeta{
    .name = "hash",
    .description = "Compute BLAKE3 hash for a file",
    .args = &[_]types.Arg{
        .{
            .name = "file",
            .description = "Path to file to hash",
            .required = true,
        },
    },
};

/// Clean subcommand metadata
const clean_meta = command.CommandMeta{
    .name = "clean",
    .description = "Clean development workspaces and caches",
    .flags = &[_]types.Flag{
        .{
            .name = "sources",
            .short = 's',
            .description = "Remove cached sources under /mere/dev/cache/sources",
            .flag_type = .bool,
        },
        .{
            .name = "cache",
            .short = 'c',
            .description = "Remove build cache entries under /mere/dev/cache/build",
            .flag_type = .bool,
        },
        .{
            .name = "workspaces",
            .short = 'w',
            .description = "Remove build workspaces under /mere/dev/build",
            .flag_type = .bool,
        },
        .{
            .name = "outputs",
            .short = 'o',
            .description = "Remove built package outputs under /mere/dev/outputs",
            .flag_type = .bool,
        },
    },
};

/// Validate subcommand metadata
const validate_meta = command.CommandMeta{
    .name = "validate",
    .description = "Validate a recipe file without building it",
    .args = &[_]types.Arg{
        .{
            .name = "recipe",
            .description = "Path to recipe KDL file",
            .required = true,
        },
    },
};

/// Repo sign subcommand metadata
const repo_sign_meta = command.CommandMeta{
    .name = "sign",
    .description = "Sign a local repository database named <name>",
    .args = &[_]types.Arg{
        .{
            .name = "repo-name",
            .description = "Name of the repository (maps to /mere/dev/repo/<name>/)",
            .required = true,
        },
    },
};

/// Repo remove subcommand metadata
const repo_remove_meta = command.CommandMeta{
    .name = "remove",
    .description = "Remove a package from a local repository database and re-sign it",
    .args = &[_]types.Arg{
        .{
            .name = "repo-name",
            .description = "Name of the repository (maps to /mere/dev/repo/<name>/)",
            .required = true,
        },
        .{
            .name = "package-name",
            .description = "Name of the package to remove",
            .required = true,
        },
        .{
            .name = "version",
            .description = "Package version (e.g. 1.0.0)",
            .required = true,
        },
        .{
            .name = "release",
            .description = "Package release number (integer)",
            .required = true,
        },
        .{
            .name = "arch",
            .description = "Package architecture (e.g. x86_64)",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "key",
            .short = 'k',
            .description = "Path to the secret key file (default: ~/.mere/keys/mere.key)",
            .flag_type = .string,
        },
    },
};

/// Repo parent command metadata
const repo_meta = command.CommandMeta{
    .name = "repo",
    .description = "Repository utilities",
};

/// Hash command handler
fn handleHash(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const file_path = args.positional[0];

    // Validate user-supplied path at CLI boundary
    if (!path.isValidInputPath(file_path)) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid file path: '{s}'", .{file_path}),
        };
    }

    // Create diagnostic context for the hash operation
    const diag_ctx = DiagnosticContext.init()
        .withSubject(file_path);
    ctx.withDiagnosticContext(diag_ctx);

    // Perform hash calculation with error handling at CLI boundary
    const hash_str = hash.calculateFileHash(ctx.allocator, file_path) catch |err| {
        // Get user-friendly error message and format with context
        const user_message = getUserFriendlyMessage(err);
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) ctx.allocator.free(formatted_message);

        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    // Return the computed hash in "hash  filename" format (compatible with sha256sum)
    const formatted = try std.fmt.allocPrint(ctx.allocator, "{s}  {s}", .{ hash_str, file_path });
    // Free the temporary hash string returned by calculateFileHash
    ctx.allocator.free(hash_str);
    return types.CommandResult{
        .success = true,
        .message = formatted,
    };
}

fn handleValidate(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const recipe_path = args.positional[0];
    if (!path.isValidInputPath(recipe_path)) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid recipe path: '{s}'", .{recipe_path}),
        };
    }

    ctx.withDiagnosticContext(DiagnosticContext.init().withSubject(recipe_path));

    mere.recipe.validateFile(ctx, recipe_path) catch |err| {
        const base_message = switch (err) {
            error.ParseFailed => "failed to parse recipe",
            error.InvalidInput => "recipe validation failed",
            else => getUserFriendlyMessage(err),
        };
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, base_message) catch base_message;
        defer if (formatted_message.ptr != base_message.ptr) ctx.allocator.free(formatted_message);

        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    return types.CommandResult{
        .success = true,
        .message = try std.fmt.allocPrint(ctx.allocator, "Recipe valid: {s}", .{recipe_path}),
    };
}

const CleanSummaryPart = struct {
    count: usize,
    singular: []const u8,
    plural: []const u8,
};

fn appendOwnedSegment(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(mere.ui.Segment),
    text: []const u8,
    kind: mere.ui.SegmentKind,
) !void {
    try segments.append(allocator, .{
        .text = try allocator.dupe(u8, text),
        .kind = kind,
    });
}

fn emitCleanSummaryResult(ctx: *mere.Context, parts: []const CleanSummaryPart) !types.CommandResult {
    if (parts.len == 0) {
        return types.CommandResult.createSuccess("Nothing selected to clean");
    }

    var segments: std.ArrayList(mere.ui.Segment) = .empty;
    errdefer {
        for (segments.items) |segment| ctx.allocator.free(segment.text);
        segments.deinit(ctx.allocator);
    }

    for (parts, 0..) |part, idx| {
        if (idx > 0) {
            try appendOwnedSegment(ctx.allocator, &segments, ", ", .normal);
        }
        const count_text = try std.fmt.allocPrint(ctx.allocator, "{d}", .{part.count});
        defer ctx.allocator.free(count_text);

        try appendOwnedSegment(ctx.allocator, &segments, "removed", .success);
        try appendOwnedSegment(ctx.allocator, &segments, " ", .normal);
        try appendOwnedSegment(ctx.allocator, &segments, count_text, .detail);
        try appendOwnedSegment(ctx.allocator, &segments, " ", .normal);
        try appendOwnedSegment(
            ctx.allocator,
            &segments,
            if (part.count == 1) part.singular else part.plural,
            .normal,
        );
    }

    return types.CommandResult{
        .success = true,
        .segments = try segments.toOwnedSlice(ctx.allocator),
    };
}

/// Clean command handler - removes selected development workspaces and caches
fn handleClean(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const selection = dev_cleanup.resolve(
        args.getBool("sources"),
        args.getBool("cache"),
        args.getBool("workspaces"),
        args.getBool("outputs"),
    );

    var summary_parts: std.ArrayList(CleanSummaryPart) = .empty;
    defer summary_parts.deinit(ctx.allocator);

    const clean_result = dev_cleanup.clean(ctx, selection) catch |err| {
        const user_message = getUserFriendlyMessage(err);
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, user_message),
        };
    };

    if (selection.workspaces) {
        try summary_parts.append(ctx.allocator, .{
            .count = clean_result.workspaces_removed,
            .singular = "workspace",
            .plural = "workspaces",
        });
    }

    if (selection.cache) {
        try summary_parts.append(ctx.allocator, .{
            .count = clean_result.cache_removed,
            .singular = "build cache entry",
            .plural = "build cache entries",
        });
    }

    if (selection.sources) {
        try summary_parts.append(ctx.allocator, .{
            .count = clean_result.sources_removed,
            .singular = "source cache entry",
            .plural = "source cache entries",
        });
    }

    if (selection.outputs) {
        try summary_parts.append(ctx.allocator, .{
            .count = clean_result.outputs_removed,
            .singular = "build output",
            .plural = "build outputs",
        });
    }

    return emitCleanSummaryResult(ctx, summary_parts.items);
}

/// Main dev command handler - shows help when no subcommand is given
fn handleDev(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    // The CLI system will handle showing help for commands with subcommands
    return types.CommandResult{ .success = true };
}

/// Repo parent command handler
fn handleRepo(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// Repo-sign command handler
fn handleRepoSign(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const repo_name = args.positional[0];

    const diagnostic_ctx = DiagnosticContext.init().withSubject(repo_name);
    ctx.withDiagnosticContext(diagnostic_ctx);

    performRepoSign(ctx, repo_name) catch |err| {
        const mapped_error = ErrorMapping.mapModuleError(@TypeOf(err), err);

        const user_message = getUserFriendlyMessage(err);
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) ctx.allocator.free(formatted_message);

        const exit_code = command.exitCodeForError(mapped_error);

        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    const sign_segments = [_]mere.ui.Segment{
        .{ .text = "repository ", .kind = .normal },
        .{ .text = "signed", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = repo_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &sign_segments);
}

fn performRepoSign(ctx: *mere.Context, repo_name: []const u8) !void {
    // Build repo source path: ${root}/mere/dev/repo/<name>
    const repo_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo", repo_name }) catch {
        return RepoError.OutOfMemory;
    };

    // Initialize repository (will validate existence)
    var repo = try Repository.init(ctx, repo_dir, true);
    defer repo.deinit();
    defer ctx.allocator.free(repo_dir);

    // Sign the repository database
    try repo.signDb();
}

/// Repo-remove command handler
fn handleRepoRemove(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 5) {
        return MereError.MissingArgument;
    }

    const repo_name = args.positional[0];
    const pkg_name = args.positional[1];
    const version = args.positional[2];
    const release_str = args.positional[3];
    const arch = args.positional[4];

    const diagnostic_ctx = DiagnosticContext.init()
        .withSubject(pkg_name)
        .withDetails(repo_name);
    ctx.withDiagnosticContext(diagnostic_ctx);

    // Parse release as u32
    const release = std.fmt.parseInt(u32, release_str, 10) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid release number: '{s}'", .{release_str}),
        };
    };

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

    performRepoRemove(ctx, repo_name, pkg_name, version, release, arch) catch |err| {
        const mapped_error = ErrorMapping.mapModuleError(@TypeOf(err), err);

        const user_message = getUserFriendlyMessage(err);
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) ctx.allocator.free(formatted_message);

        const exit_code = command.exitCodeForError(mapped_error);

        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    var release_buf: [32]u8 = undefined;
    const release_text = std.fmt.bufPrint(&release_buf, "{d}", .{release}) catch return MereError.OutOfMemory;
    const remove_segments = [_]mere.ui.Segment{
        .{ .text = "package ", .kind = .normal },
        .{ .text = "removed", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = pkg_name, .kind = .detail },
        .{ .text = "' ", .kind = .normal },
        .{ .text = version, .kind = .detail },
        .{ .text = "-", .kind = .normal },
        .{ .text = release_text, .kind = .detail },
        .{ .text = " (", .kind = .normal },
        .{ .text = arch, .kind = .detail },
        .{ .text = ") from repository '", .kind = .normal },
        .{ .text = repo_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &remove_segments);
}

fn performRepoRemove(ctx: *mere.Context, repo_name: []const u8, pkg_name: []const u8, version: []const u8, release: u32, arch: []const u8) !void {
    // Build repo source path: ${root}/mere/dev/repo/<name>
    const repo_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo", repo_name }) catch {
        return RepoError.OutOfMemory;
    };
    defer ctx.allocator.free(repo_dir);

    // Stage next state, delete package, commit
    var staged = repo_history.stageNext(ctx, repo_dir) catch |err| {
        return switch (err) {
            error.OutOfMemory => RepoError.OutOfMemory,
            error.PermissionDenied => RepoError.PermissionDenied,
            else => RepoError.FileSystem,
        };
    };
    defer staged.deinit();

    // Delete the package from the staged database
    try staged.db.deletePackage(pkg_name, version, release, arch);

    // Commit: sign + activate new state
    staged.commit() catch |err| {
        return switch (err) {
            error.OutOfMemory => RepoError.OutOfMemory,
            error.PermissionDenied => RepoError.PermissionDenied,
            else => RepoError.SignatureInvalid,
        };
    };
}

/// Create the dev command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const dev_cmd = try allocator.create(command.Command);
    dev_cmd.* = command.Command.init(allocator, dev_meta, handleDev);

    // Create hash subcommand
    const hash_cmd = try allocator.create(command.Command);
    hash_cmd.* = command.Command.init(allocator, hash_meta, handleHash);

    // Create clean subcommand
    const clean_cmd = try allocator.create(command.Command);
    clean_cmd.* = command.Command.init(allocator, clean_meta, handleClean);

    // Create validate subcommand
    const validate_cmd = try allocator.create(command.Command);
    validate_cmd.* = command.Command.init(allocator, validate_meta, handleValidate);

    // Add subcommands to dev command
    try dev_cmd.addSubcommand(hash_cmd);
    try dev_cmd.addSubcommand(clean_cmd);
    try dev_cmd.addSubcommand(validate_cmd);

    // Create repo parent + subcommands
    const repo_cmd = try allocator.create(command.Command);
    repo_cmd.* = command.Command.init(allocator, repo_meta, handleRepo);

    const repo_sign_cmd = try allocator.create(command.Command);
    repo_sign_cmd.* = command.Command.init(allocator, repo_sign_meta, handleRepoSign);
    try repo_cmd.addSubcommand(repo_sign_cmd);

    const repo_remove_cmd = try allocator.create(command.Command);
    repo_remove_cmd.* = command.Command.init(allocator, repo_remove_meta, handleRepoRemove);
    try repo_cmd.addSubcommand(repo_remove_cmd);
    try dev_cmd.addSubcommand(repo_cmd);

    // Also add the import command as a subcommand of dev
    const import_command = try import_cmd.createCommand(allocator);
    try dev_cmd.addSubcommand(import_command);

    // Build (dev) subcommand
    const build_command = try build_cmd.createCommand(allocator);
    try dev_cmd.addSubcommand(build_command);

    return dev_cmd;
}
