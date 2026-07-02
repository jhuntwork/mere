const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const emit = mere.ui.emit;
const path = mere.path;

// Import generation-related modules
const activation = @import("mere").activation;
const gcroots = @import("mere").gcroots;
const generation_mod = @import("mere").generation;

fn emitGenerationActivationStatus(
    ctx: *mere.Context,
    gen_num: u32,
    etc_copied: ?usize,
    etc_unchanged: ?usize,
    etc_differing: ?usize,
) void {
    var gen_buf: [32]u8 = undefined;
    const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num}) catch return;

    if (etc_copied != null and etc_unchanged != null and etc_differing != null) {
        var copied_buf: [32]u8 = undefined;
        var unchanged_buf: [32]u8 = undefined;
        var differing_buf: [32]u8 = undefined;
        const copied_text = std.fmt.bufPrint(&copied_buf, "{d}", .{etc_copied.?}) catch return;
        const unchanged_text = std.fmt.bufPrint(&unchanged_buf, "{d}", .{etc_unchanged.?}) catch return;
        const differing_text = std.fmt.bufPrint(&differing_buf, "{d}", .{etc_differing.?}) catch return;
        const segments = [_]mere.ui.Segment{
            .{ .text = "generation ", .kind = .normal },
            .{ .text = "activated", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = gen_text, .kind = .detail },
            .{ .text = " (", .kind = .normal },
            .{ .text = copied_text, .kind = .detail },
            .{ .text = " /etc files copied, ", .kind = .normal },
            .{ .text = unchanged_text, .kind = .detail },
            .{ .text = " unchanged, ", .kind = .normal },
            .{ .text = differing_text, .kind = .detail },
            .{ .text = " differing; run 'mere etc status')", .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, .generation, .info, &segments);
        return;
    }

    const segments = [_]mere.ui.Segment{
        .{ .text = "generation ", .kind = .normal },
        .{ .text = "activated", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = gen_text, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .generation, .info, &segments);
}

/// Generation command metadata
const generation_meta = command.CommandMeta{
    .name = "generation",
    .description = "Manage generations",
};

/// List subcommand metadata
const list_meta = command.CommandMeta{
    .name = "list",
    .description = "List all generations",
};

/// Keep subcommand metadata
const keep_meta = command.CommandMeta{
    .name = "keep",
    .description = "Mark a generation as explicitly kept (prevents GC)",
    .args = &[_]types.Arg{
        .{
            .name = "generation",
            .description = "Generation number to keep",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{.{
        .name = "note",
        .description = "Human-readable note explaining why this generation is kept",
        .flag_type = .string,
    }},
};

/// Unkeep subcommand metadata
const unkeep_meta = command.CommandMeta{
    .name = "unkeep",
    .description = "Remove explicit keep marker from a generation",
    .args = &[_]types.Arg{
        .{
            .name = "generation",
            .description = "Generation number to unkeep",
            .required = true,
        },
    },
};

/// Delete subcommand metadata
const delete_meta = command.CommandMeta{
    .name = "delete",
    .description = "Delete a generation (cannot delete active generation)",
    .args = &[_]types.Arg{
        .{
            .name = "generation",
            .description = "Generation number to delete",
            .required = true,
        },
    },
};

/// Activate subcommand metadata
const activate_meta = command.CommandMeta{
    .name = "activate",
    .description = "Activate a specific generation (rollback)",
    .args = &[_]types.Arg{
        .{
            .name = "generation",
            .description = "Generation number to activate",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "verify-store",
            .description = "Verify store content hashes during activation (slow)",
            .flag_type = .bool,
        },
    },
};

/// Main generation command handler
fn handleGeneration(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// List generations handler
pub fn handleList(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = args;

    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    const gc_roots_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gc_roots_dir);

    // Get current generation
    const current = generation_mod.getCurrentGeneration(profile_dir) catch null;

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root);

    // Get all generations
    const all_gens = generation_mod.listGenerations(ctx.allocator, store_root, profile_dir) catch |err| {
        const msg = switch (err) {
            generation_mod.GenerationError.FileSystem => "failed to read generations directory",
            else => "failed to list generations",
        };
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, msg),
        };
    };
    defer ctx.allocator.free(all_gens);

    if (all_gens.len == 0) {
        return types.CommandResult{
            .success = true,
            .message = try ctx.allocator.dupe(u8, "No generations found"),
        };
    }

    // Get rooted generations from the profile-specific gc roots directory
    const profile_gc_dir = std.fs.path.join(ctx.allocator, &.{ gc_roots_dir, "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_gc_dir);

    const rooted_gens = gcroots.listGenerationRoots(ctx.allocator, profile_gc_dir) catch &[_]u32{};
    defer if (rooted_gens.len > 0) ctx.allocator.free(rooted_gens);

    // Build output
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &output);
    const out = &out_buf.writer;
    out.writeAll("Generations for profile 'system':\n") catch return MereError.OutOfMemory;

    for (all_gens) |gen| {
        const is_current = current != null and current.? == gen;
        const is_rooted = blk: {
            for (rooted_gens) |r| {
                if (r == gen) break :blk true;
            }
            break :blk false;
        };
        const is_kept = gcroots.isExplicitlyKept(ctx.allocator, profile_dir, gen) catch false;

        var flags_buf: [32]u8 = undefined;
        var flags_len: usize = 0;

        if (is_current) {
            flags_buf[flags_len] = '*';
            flags_len += 1;
        }
        if (is_rooted) {
            flags_buf[flags_len] = 'R';
            flags_len += 1;
        }
        if (is_kept) {
            flags_buf[flags_len] = 'K';
            flags_len += 1;
        }

        const flags = if (flags_len > 0) flags_buf[0..flags_len] else "";

        if (flags.len > 0) {
            out.print("  gen-{d} [{s}]\n", .{ gen, flags }) catch return MereError.OutOfMemory;
        } else {
            out.print("  gen-{d}\n", .{gen}) catch return MereError.OutOfMemory;
        }
    }

    out.writeAll("\nLegend: * = current, R = rooted (GC protected), K = explicitly kept\n") catch return MereError.OutOfMemory;
    output = out_buf.toArrayList();

    return types.CommandResult{
        .success = true,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// Keep generation handler
pub fn handleKeep(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const gen_str = args.positional[0];
    const gen_num = std.fmt.parseInt(u32, gen_str, 10) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "invalid generation number: {s}", .{gen_str}),
        };
    };

    const note = args.getString("note");

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    gcroots.keepGeneration(ctx.allocator, profile_dir, gen_num, note) catch |err| {
        const msg = switch (err) {
            gcroots.GCRootsError.GenerationNotFound => "generation not found",
            gcroots.GCRootsError.PermissionDenied => "permission denied",
            else => "failed to keep generation",
        };
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, msg),
        };
    };

    var gen_buf: [32]u8 = undefined;
    const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num}) catch return MereError.OutOfMemory;
    const segments = [_]mere.ui.Segment{
        .{ .text = "generation ", .kind = .normal },
        .{ .text = "marked as kept", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = gen_text, .kind = .detail },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Unkeep generation handler
pub fn handleUnkeep(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const gen_str = args.positional[0];
    const gen_num = std.fmt.parseInt(u32, gen_str, 10) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "invalid generation number: {s}", .{gen_str}),
        };
    };

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    gcroots.unkeepGeneration(ctx.allocator, profile_dir, gen_num) catch |err| {
        const msg = switch (err) {
            gcroots.GCRootsError.PermissionDenied => "permission denied",
            else => "failed to unkeep generation",
        };
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, msg),
        };
    };

    var gen_buf: [32]u8 = undefined;
    const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num}) catch return MereError.OutOfMemory;
    const segments = [_]mere.ui.Segment{
        .{ .text = "generation ", .kind = .normal },
        .{ .text = "keep marker removed", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = gen_text, .kind = .detail },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Delete generation handler
pub fn handleDelete(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const gen_str = args.positional[0];
    const gen_num = std.fmt.parseInt(u32, gen_str, 10) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "invalid generation number: {s}", .{gen_str}),
        };
    };

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    const gc_roots_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gc_roots_dir);

    gcroots.deleteGeneration(ctx, gc_roots_dir, profile_dir, gen_num) catch |err| {
        const msg = switch (err) {
            gcroots.GCRootsError.CannotDeleteActive => "cannot delete the active generation",
            gcroots.GCRootsError.GenerationNotFound => "generation not found",
            gcroots.GCRootsError.PermissionDenied => "permission denied",
            else => "failed to delete generation",
        };
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, msg),
        };
    };

    var gen_buf: [32]u8 = undefined;
    const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num}) catch return MereError.OutOfMemory;
    const segments = [_]mere.ui.Segment{
        .{ .text = "generation ", .kind = .normal },
        .{ .text = "deleted", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = gen_text, .kind = .detail },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Activate generation handler (rollback)
pub fn handleActivate(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const gen_str = args.positional[0];
    const gen_num = std.fmt.parseInt(u32, gen_str, 10) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "invalid generation number: {s}", .{gen_str}),
        };
    };

    const verify_store = args.getBool("verify-store");

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", "system" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    // Verify generation exists
    var gen_name_buf: [64]u8 = undefined;
    const gen_name = std.fmt.bufPrint(&gen_name_buf, "gen-{d}", .{gen_num}) catch {
        return MereError.Internal;
    };

    const gen_path = std.fs.path.join(ctx.allocator, &.{ profile_dir, gen_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gen_path);

    std.Io.Dir.accessAbsolute(path.currentIo(), gen_path, .{}) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try std.fmt.allocPrint(ctx.allocator, "generation {d} not found", .{gen_num}),
        };
    };

    const result = activation.activateSystemGeneration(
        ctx,
        gen_num,
        if (verify_store) .full_store else .fast,
    ) catch |err| {
        const msg = switch (err) {
            activation.ActivationError.GenerationNotFound => "generation not found",
            activation.ActivationError.FileSystem => "file system error",
            else => "failed to activate generation",
        };
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, msg),
        };
    };

    emitGenerationActivationStatus(ctx, gen_num, result.etc_copied, result.etc_skipped, result.etc_differing);
    return types.CommandResult{ .success = true };
}

/// Create the generation command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const gen_cmd = try allocator.create(command.Command);
    gen_cmd.* = command.Command.init(allocator, generation_meta, handleGeneration);

    const list_cmd = try allocator.create(command.Command);
    list_cmd.* = command.Command.init(allocator, list_meta, handleList);

    const keep_cmd = try allocator.create(command.Command);
    keep_cmd.* = command.Command.init(allocator, keep_meta, handleKeep);

    const unkeep_cmd = try allocator.create(command.Command);
    unkeep_cmd.* = command.Command.init(allocator, unkeep_meta, handleUnkeep);

    const delete_cmd = try allocator.create(command.Command);
    delete_cmd.* = command.Command.init(allocator, delete_meta, handleDelete);

    const activate_cmd = try allocator.create(command.Command);
    activate_cmd.* = command.Command.init(allocator, activate_meta, handleActivate);

    try gen_cmd.addSubcommand(list_cmd);
    try gen_cmd.addSubcommand(keep_cmd);
    try gen_cmd.addSubcommand(unkeep_cmd);
    try gen_cmd.addSubcommand(delete_cmd);
    try gen_cmd.addSubcommand(activate_cmd);

    return gen_cmd;
}
