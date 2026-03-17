const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;

// Import profile-related modules
const profile_mod = mere.profile;
const generation_mod = mere.generation;
const gcroots = mere.gcroots;

/// Profile command metadata
const profile_meta = command.CommandMeta{
    .name = "profile",
    .description = "Manage profiles",
};

fn profileCreationSegments(
    ctx: *mere.Context,
    profile_name: []const u8,
    base_name: ?[]const u8,
    gen_num: ?u32,
) !types.CommandResult {
    if (base_name) |base| {
        var gen_buf: [32]u8 = undefined;
        const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num orelse 0}) catch return MereError.OutOfMemory;
        const segments = [_]mere.ui.Segment{
            .{ .text = "profile ", .kind = .normal },
            .{ .text = "created", .kind = .success },
            .{ .text = ": '", .kind = .normal },
            .{ .text = profile_name, .kind = .detail },
            .{ .text = "' from '", .kind = .normal },
            .{ .text = base, .kind = .detail },
            .{ .text = "' (gen-", .kind = .normal },
            .{ .text = gen_text, .kind = .detail },
            .{ .text = ")", .kind = .normal },
        };
        return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
    }

    const segments = [_]mere.ui.Segment{
        .{ .text = "profile ", .kind = .normal },
        .{ .text = "created", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = profile_name, .kind = .detail },
        .{ .text = "' (empty)", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// List subcommand metadata
const list_meta = command.CommandMeta{
    .name = "list",
    .description = "List all profiles",
};

/// Create subcommand metadata
const create_meta = command.CommandMeta{
    .name = "create",
    .description = "Create a new profile",
    .args = &[_]types.Arg{
        .{
            .name = "name",
            .description = "Name of the profile to create",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "from",
            .description = "Clone from an existing profile's current generation",
            .flag_type = .string,
        },
    },
};

/// Delete subcommand metadata
const delete_meta = command.CommandMeta{
    .name = "delete",
    .description = "Delete a profile",
    .args = &[_]types.Arg{
        .{
            .name = "name",
            .description = "Name of the profile to delete",
            .required = true,
        },
    },
};

/// Main profile command handler
fn handleProfile(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// List profiles handler
pub fn handleList(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = args;

    const profiles_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profiles_dir);

    // Open profiles directory
    var dir = std.fs.openDirAbsolute(profiles_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => types.CommandResult{
                .success = true,
                .message = try ctx.allocator.dupe(u8, "No profiles found (profiles directory does not exist)"),
            },
            else => types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to open profiles directory"),
            },
        };
    };
    defer dir.close();

    // Build output
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(ctx.allocator);

    const writer = output.writer(ctx.allocator);
    try writer.writeAll("Profiles:\n");

    var profile_count: usize = 0;

    // Iterate over profiles directory entries
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const profile_name = entry.name;
        profile_count += 1;

        // Get profile directory path
        const profile_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, profile_name }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(profile_path);

        // Get current generation
        const current_gen = generation_mod.getCurrentGeneration(profile_path) catch null;

        // Count generations
        const generations = generation_mod.listGenerations(ctx.allocator, profile_path) catch null;
        const gen_count = if (generations) |gens| blk: {
            defer ctx.allocator.free(gens);
            break :blk gens.len;
        } else 0;

        // Format output
        const is_system = std.mem.eql(u8, profile_name, "system");
        const kind_str = if (is_system) " [system]" else "";

        if (current_gen) |gen| {
            try writer.print("  {s}{s}: gen-{d} ({d} generations)\n", .{ profile_name, kind_str, gen, gen_count });
        } else {
            try writer.print("  {s}{s}: (no current generation, {d} generations)\n", .{ profile_name, kind_str, gen_count });
        }
    }

    if (profile_count == 0) {
        try writer.writeAll("  (no profiles found)\n");
    }

    return types.CommandResult{
        .success = true,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// Create profile handler
pub fn handleCreate(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const profile_name = args.positional[0];

    // Validate profile name
    if (std.mem.eql(u8, profile_name, "system")) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(u8, "Cannot create profile named 'system' - it is reserved"),
        };
    }

    // Check for invalid characters
    for (profile_name) |c| {
        if (c == '/' or c == '\x00') {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try ctx.allocator.dupe(u8, "Invalid profile name: contains invalid characters"),
            };
        }
    }

    if (profile_name.len == 0 or profile_name.len > 64) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(u8, "Invalid profile name: must be 1-64 characters"),
        };
    }

    const profiles_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profiles_dir);

    const profile_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, profile_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_path);

    // Check if profile already exists
    if (std.fs.openDirAbsolute(profile_path, .{})) |d| {
        @constCast(&d).close();
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try std.fmt.allocPrint(ctx.allocator, "Profile '{s}' already exists", .{profile_name}),
        };
    } else |_| {
        // Profile doesn't exist, continue
    }

    const from_profile = args.getString("from");

    if (from_profile) |base_name| {
        // Clone from existing profile
        const base_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, base_name }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(base_path);

        // Check base profile exists
        var base_dir = std.fs.openDirAbsolute(base_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => types.CommandResult{
                    .success = false,
                    .exit_code = 1,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Base profile '{s}' does not exist", .{base_name}),
                },
                else => types.CommandResult{
                    .success = false,
                    .exit_code = 1,
                    .message = try ctx.allocator.dupe(u8, "Failed to open base profile"),
                },
            };
        };
        base_dir.close();

        // Get base profile's current generation
        const current_gen = generation_mod.getCurrentGeneration(base_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try std.fmt.allocPrint(ctx.allocator, "Base profile '{s}' has no current generation", .{base_name}),
            };
        } orelse {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try std.fmt.allocPrint(ctx.allocator, "Base profile '{s}' has no current generation", .{base_name}),
            };
        };

        // Read base generation's manifest
        const base_gen_path = generation_mod.getGenerationPath(ctx.allocator, base_path, current_gen) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(base_gen_path);

        var manifest = generation_mod.readManifest(ctx.allocator, base_gen_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to read base profile manifest"),
            };
        };
        defer manifest.deinit();

        // Create new profile directory
        std.fs.cwd().makePath(profile_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to create profile directory"),
            };
        };

        // Build package entries for the new generation
        var packages: std.ArrayList(generation_mod.PackageEntry) = .{};
        defer packages.deinit(ctx.allocator);

        for (manifest.packages.items) |pkg| {
            packages.append(ctx.allocator, .{
                .name = pkg.name,
                .version = pkg.version,
                .release = pkg.release,
                .arch = pkg.arch,
                .store_path = pkg.store_path,
                .content_hash = pkg.content_hash,
            }) catch {
                return MereError.OutOfMemory;
            };
        }

        // Create generation in new profile
        const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(store_root);

        const gen_num = profile_mod.createGeneration(
            ctx,
            profile_path,
            store_root,
            packages.items,
            null,
        ) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to create generation in new profile"),
            };
        };

        _ = mere.activation.switchProfileGeneration(ctx, profile_name, gen_num, .fast) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to activate generation"),
            };
        };

        return try profileCreationSegments(ctx, profile_name, base_name, gen_num);
    } else {
        // Create empty profile
        std.fs.cwd().makePath(profile_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to create profile directory"),
            };
        };

        // Create empty requested.kdl
        const requested_path = std.fs.path.join(ctx.allocator, &.{ profile_path, "requested.kdl" }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(requested_path);

        var file = std.fs.createFileAbsolute(requested_path, .{}) catch {
            // Non-fatal, directory created is sufficient
            return try profileCreationSegments(ctx, profile_name, null, null);
        };
        file.writeAll("// Requested packages for profile\n") catch {};
        file.close();

        return try profileCreationSegments(ctx, profile_name, null, null);
    }
}

/// Delete profile handler
pub fn handleDelete(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const profile_name = args.positional[0];

    // Cannot delete system profile
    if (std.mem.eql(u8, profile_name, "system")) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(u8, "Cannot delete the system profile"),
        };
    }

    const profiles_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profiles_dir);

    const profile_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, profile_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_path);

    // Check profile exists
    var dir = std.fs.openDirAbsolute(profile_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try std.fmt.allocPrint(ctx.allocator, "Profile '{s}' does not exist", .{profile_name}),
            },
            else => types.CommandResult{
                .success = false,
                .exit_code = 1,
                .message = try ctx.allocator.dupe(u8, "Failed to open profile"),
            },
        };
    };
    dir.close();

    // Delete profile directory recursively
    std.fs.deleteTreeAbsolute(profile_path) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, "Failed to delete profile directory"),
        };
    };

    // Delete GC roots for this profile
    const gc_roots_path = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots", "profiles", profile_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gc_roots_path);

    std.fs.deleteTreeAbsolute(gc_roots_path) catch {
        // Non-fatal, GC roots may not exist
    };

    const delete_segments = [_]mere.ui.Segment{
        .{ .text = "profile ", .kind = .normal },
        .{ .text = "deleted", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = profile_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &delete_segments);
}

/// Create the profile command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const profile_cmd = try allocator.create(command.Command);
    profile_cmd.* = command.Command.init(allocator, profile_meta, handleProfile);

    const list_cmd = try allocator.create(command.Command);
    list_cmd.* = command.Command.init(allocator, list_meta, handleList);

    const create_cmd = try allocator.create(command.Command);
    create_cmd.* = command.Command.init(allocator, create_meta, handleCreate);

    const delete_cmd = try allocator.create(command.Command);
    delete_cmd.* = command.Command.init(allocator, delete_meta, handleDelete);

    try profile_cmd.addSubcommand(list_cmd);
    try profile_cmd.addSubcommand(create_cmd);
    try profile_cmd.addSubcommand(delete_cmd);

    return profile_cmd;
}
