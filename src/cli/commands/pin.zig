const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const pin = mere.pin;
const MereError = mere.errors.MereError;

fn exitCodeForPinError(err: pin.PinError) u8 {
    return switch (err) {
        pin.PinError.InvalidInput, pin.PinError.InvalidStorePath => 2,
        pin.PinError.PermissionDenied => 13,
        else => 1,
    };
}

/// Pin command metadata
const pin_meta = command.CommandMeta{
    .name = "pin",
    .description = "Manage package pins (GC roots)",
};

/// Add subcommand metadata
const add_meta = command.CommandMeta{
    .name = "add",
    .description = "Create a pin to a store path",
    .args = &[_]types.Arg{
        .{
            .name = "store-path",
            .description = "Store path to pin (e.g., /mere/store/<hash>-<name>-<version>)",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "name",
            .short = 'n',
            .description = "Pin name (default: package name from store path)",
            .flag_type = .string,
        },
        .{
            .name = "note",
            .description = "Human-readable note explaining the pin",
            .flag_type = .string,
        },
    },
};

/// Remove subcommand metadata
const remove_meta = command.CommandMeta{
    .name = "remove",
    .description = "Remove a pin",
    .args = &[_]types.Arg{
        .{
            .name = "name",
            .description = "Pin name to remove",
            .required = true,
        },
    },
};

/// List subcommand metadata
const list_meta = command.CommandMeta{
    .name = "list",
    .description = "List all pins",
};

/// Main pin command handler - shows help when no subcommand is given
fn handlePin(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// Add pin handler
pub fn handleAdd(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const store_path = args.positional[0];

    // Create diagnostic context for this operation
    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(store_path);
    ctx.withDiagnosticContext(diagnostic_ctx);

    // Get pin name (default to package name from store path)
    const pin_name = if (args.getString("name")) |n|
        n
    else blk: {
        const default_name = pin.defaultName(store_path) catch {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try std.fmt.allocPrint(ctx.allocator, "invalid store path format: {s}", .{store_path}),
            };
        };
        break :blk default_name;
    };

    const note = args.getString("note");

    // Build gc-roots path
    const gc_roots_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gc_roots_dir);

    pin.create(ctx.allocator, gc_roots_dir, pin_name, store_path, note) catch |err| {
        const user_message = switch (err) {
            pin.PinError.PinExists => "pin already exists (use 'pin remove' first)",
            pin.PinError.InvalidStorePath => "invalid store path format",
            pin.PinError.StorePathNotFound => "store path does not exist",
            pin.PinError.InvalidInput => "invalid pin name",
            pin.PinError.PermissionDenied => "permission denied",
            else => "operation failed",
        };

        const error_ctx = diagnostic_ctx.toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) ctx.allocator.free(formatted_message);

        const exit_code = exitCodeForPinError(err);

        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    const segments = [_]mere.ui.Segment{
        .{ .text = "pin ", .kind = .normal },
        .{ .text = "created", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = pin_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Remove pin handler
pub fn handleRemove(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const pin_name = args.positional[0];

    // Create diagnostic context for this operation
    const diagnostic_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(pin_name);
    ctx.withDiagnosticContext(diagnostic_ctx);

    const gc_roots_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gc_roots_dir);

    pin.remove(ctx.allocator, gc_roots_dir, pin_name) catch |err| {
        const user_message = switch (err) {
            pin.PinError.PinNotFound => "pin not found",
            pin.PinError.PermissionDenied => "permission denied",
            else => "operation failed",
        };

        const error_ctx = diagnostic_ctx.toErrorContext();
        const formatted_message = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;
        defer if (formatted_message.ptr != user_message.ptr) ctx.allocator.free(formatted_message);

        const exit_code = exitCodeForPinError(err);

        return types.CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try ctx.allocator.dupe(u8, formatted_message),
        };
    };

    const segments = [_]mere.ui.Segment{
        .{ .text = "pin ", .kind = .normal },
        .{ .text = "removed", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = pin_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// List pins handler
pub fn handleList(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = args;

    // Create diagnostic context for this operation (no specific subject for listing)
    const diagnostic_ctx = mere.errors.DiagnosticContext.init();
    ctx.withDiagnosticContext(diagnostic_ctx);

    const gc_roots_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(gc_roots_dir);

    var pins = pin.list(ctx.allocator, gc_roots_dir) catch |err| {
        const user_message = switch (err) {
            pin.PinError.PermissionDenied => "permission denied listing pins",
            else => "failed to list pins",
        };

        return types.CommandResult{
            .success = false,
            .exit_code = exitCodeForPinError(err),
            .message = try ctx.allocator.dupe(u8, user_message),
        };
    };
    defer pins.deinit();

    if (pins.pins.items.len == 0) {
        return types.CommandResult{
            .success = true,
            .message = try ctx.allocator.dupe(u8, "No pins found"),
        };
    }

    // Build output string
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(ctx.allocator);

    const writer = output.writer(ctx.allocator);
    try writer.writeAll("Pins:\n");

    for (pins.pins.items) |p| {
        try writer.print("  {s} -> {s}-{s}\n", .{ p.name, p.package_name, p.package_version });
        try writer.print("    {s}\n", .{p.store_path});
        if (p.note) |n| {
            try writer.print("    Note: {s}\n", .{n});
        }
    }

    return types.CommandResult{
        .success = true,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// Create the pin command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const pin_cmd = try allocator.create(command.Command);
    pin_cmd.* = command.Command.init(allocator, pin_meta, handlePin);

    const add_cmd = try allocator.create(command.Command);
    add_cmd.* = command.Command.init(allocator, add_meta, handleAdd);

    const remove_cmd = try allocator.create(command.Command);
    remove_cmd.* = command.Command.init(allocator, remove_meta, handleRemove);

    const list_cmd = try allocator.create(command.Command);
    list_cmd.* = command.Command.init(allocator, list_meta, handleList);

    try pin_cmd.addSubcommand(add_cmd);
    try pin_cmd.addSubcommand(remove_cmd);
    try pin_cmd.addSubcommand(list_cmd);

    return pin_cmd;
}
