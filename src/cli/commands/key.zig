const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const path = mere.path;
const sign = mere.sign;
const MereError = mere.errors.MereError;
const emit = mere.ui.emit;

/// Key command metadata
const key_meta = command.CommandMeta{
    .name = "key",
    .description = "Manage signing keys",
};

/// Generate subcommand metadata
const generate_meta = command.CommandMeta{
    .name = "generate",
    .description = "Generate a new Ed25519 key pair for package signing",
    .flags = &[_]types.Flag{
        .{
            .name = "output-dir",
            .short = 'o',
            .description = "Directory to store the key pair (default: ~/.mere/keys)",
            .flag_type = .string,
        },
    },
};

/// Fingerprint subcommand metadata
const fingerprint_meta = command.CommandMeta{
    .name = "fingerprint",
    .description = "Show the fingerprint of a key file",
    .args = &[_]types.Arg{
        .{
            .name = "path",
            .description = "Path to .pub or .key file",
            .required = true,
        },
    },
};

/// List subcommand metadata
const list_meta = command.CommandMeta{
    .name = "list",
    .description = "List keys in key directories with their fingerprints",
};

/// Main key command handler - shows help when no subcommand is given
fn handleKey(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// Generate command handler
fn handleGenerate(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const output_dir = args.getString("output-dir");

    // Validate user-supplied path if provided
    if (output_dir) |dir| {
        if (!path.isValidInputPath(dir)) {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try std.fmt.allocPrint(ctx.allocator, "Invalid output directory path: '{s}'", .{dir}),
            };
        }
    }

    // Determine output directory (use default if not specified)
    const key_dir = if (output_dir) |dir|
        try ctx.allocator.dupe(u8, dir)
    else
        sign.getDefaultKeyDirectory(ctx) catch |err| {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try std.fmt.allocPrint(ctx.allocator, "Could not determine home directory: {s}", .{@errorName(err)}),
            };
        };
    defer ctx.allocator.free(key_dir);

    // Generate and save key pair with specific error handling
    const result = sign.generateAndSaveKeyPair(ctx, key_dir) catch |err| {
        // Provide specific error messages based on error type
        switch (err) {
            sign.SignError.FileSystem => {
                // Check if keys already exist
                const pub_path = std.fs.path.join(ctx.allocator, &.{ key_dir, "mere.pub" }) catch {
                    return types.CommandResult{
                        .success = false,
                        .exit_code = 1,
                        .message = try std.fmt.allocPrint(ctx.allocator, "Failed to generate key pair in {s}: file system error", .{key_dir}),
                    };
                };
                defer ctx.allocator.free(pub_path);

                const key_path = std.fs.path.join(ctx.allocator, &.{ key_dir, "mere.key" }) catch {
                    return types.CommandResult{
                        .success = false,
                        .exit_code = 1,
                        .message = try std.fmt.allocPrint(ctx.allocator, "Failed to generate key pair in {s}: file system error", .{key_dir}),
                    };
                };
                defer ctx.allocator.free(key_path);

                if (path.fileExists(pub_path) or path.fileExists(key_path)) {
                    return types.CommandResult{
                        .success = false,
                        .exit_code = 1,
                        .message = try std.fmt.allocPrint(ctx.allocator, "Key pair already exists in {s}", .{key_dir}),
                    };
                }

                return types.CommandResult{
                    .success = false,
                    .exit_code = 1,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Failed to generate key pair in {s}: file system error", .{key_dir}),
                };
            },
            sign.SignError.PermissionDenied => {
                return types.CommandResult{
                    .success = false,
                    .exit_code = 1,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Failed to generate key pair in {s}: permission denied", .{key_dir}),
                };
            },
            sign.SignError.OutOfMemory => {
                return MereError.OutOfMemory;
            },
            else => {
                return types.CommandResult{
                    .success = false,
                    .exit_code = 1,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Failed to generate key pair in {s}: {s}", .{ key_dir, @errorName(err) }),
                };
            },
        }
    };
    defer ctx.allocator.free(result.public_key_path);
    defer ctx.allocator.free(result.secret_key_path);

    const heading_segments = [_]mere.ui.Segment{
        .{ .text = "key pair ", .kind = .normal },
        .{ .text = "generated", .kind = .success },
    };
    emit.logSegmentsSeverity(ctx, .key, .info, &heading_segments);

    const secret_segments = [_]mere.ui.Segment{
        .{ .text = "  secret", .kind = .label },
        .{ .text = ": ", .kind = .normal },
        .{ .text = result.secret_key_path, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .key, .info, &secret_segments);

    const public_segments = [_]mere.ui.Segment{
        .{ .text = "  public", .kind = .label },
        .{ .text = ": ", .kind = .normal },
        .{ .text = result.public_key_path, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .key, .info, &public_segments);

    // Load the generated public key to compute its fingerprint
    const pub_key = sign.PublicKey.loadFromFile(result.public_key_path) catch {
        return types.CommandResult{ .success = true };
    };

    const fingerprint = pub_key.fingerprint(ctx.allocator) catch {
        return types.CommandResult{ .success = true };
    };
    defer ctx.allocator.free(fingerprint);

    const fingerprint_segments = [_]mere.ui.Segment{
        .{ .text = "  fingerprint", .kind = .label },
        .{ .text = ": ", .kind = .normal },
        .{ .text = fingerprint, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .key, .info, &fingerprint_segments);

    return types.CommandResult{ .success = true };
}

/// Fingerprint command handler
fn handleFingerprint(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const key_path = args.positional[0];

    // Validate path
    if (!path.isValidInputPath(key_path)) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Invalid key path: '{s}'", .{key_path}),
        };
    }

    // Determine key type and load public key
    const is_secret_key = std.mem.endsWith(u8, key_path, ".key");
    const is_public_key = std.mem.endsWith(u8, key_path, ".pub");

    if (!is_secret_key and !is_public_key) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Key file must have .key or .pub extension: '{s}'", .{key_path}),
        };
    }

    const pub_key: sign.PublicKey = if (is_secret_key) blk: {
        var secret_key = sign.SecretKey.loadFromFile(key_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try std.fmt.allocPrint(ctx.allocator, "Failed to load secret key: '{s}'", .{key_path}),
            };
        };
        defer secret_key.deinit();
        break :blk secret_key.derivePublicKey();
    } else blk: {
        break :blk sign.PublicKey.loadFromFile(key_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try std.fmt.allocPrint(ctx.allocator, "Failed to load public key: '{s}'", .{key_path}),
            };
        };
    };

    const fingerprint = pub_key.fingerprint(ctx.allocator) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, "Failed to compute fingerprint"),
        };
    };

    const segments = [_]mere.ui.Segment{
        .{ .text = "fingerprint", .kind = .label },
        .{ .text = ": ", .kind = .normal },
        .{ .text = fingerprint, .kind = .detail },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// List command handler
fn handleList(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = args;

    var all_keys = sign.loadAllKeys(ctx) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, "Failed to scan key directories"),
        };
    };
    defer {
        for (all_keys.items) |*k| k.deinit(ctx.allocator);
        all_keys.deinit(ctx.allocator);
    }

    if (all_keys.items.len == 0) {
        return types.CommandResult{
            .success = true,
            .message = try ctx.allocator.dupe(u8, "No keys found"),
        };
    }

    // Build output
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(ctx.allocator);
    const writer = output.writer(ctx.allocator);

    for (all_keys.items) |key| {
        writer.print("{s}: {s}\n", .{ std.fs.path.basename(key.path), key.fingerprint }) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to format output"),
            };
        };
    }

    return types.CommandResult{
        .success = true,
        .message = try output.toOwnedSlice(ctx.allocator),
    };
}

/// Create the key command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const key_cmd = try allocator.create(command.Command);
    key_cmd.* = command.Command.init(allocator, key_meta, handleKey);

    const generate_cmd = try allocator.create(command.Command);
    generate_cmd.* = command.Command.init(allocator, generate_meta, handleGenerate);

    const fingerprint_cmd = try allocator.create(command.Command);
    fingerprint_cmd.* = command.Command.init(allocator, fingerprint_meta, handleFingerprint);

    const list_cmd = try allocator.create(command.Command);
    list_cmd.* = command.Command.init(allocator, list_meta, handleList);

    try key_cmd.addSubcommand(generate_cmd);
    try key_cmd.addSubcommand(fingerprint_cmd);
    try key_cmd.addSubcommand(list_cmd);

    return key_cmd;
}
