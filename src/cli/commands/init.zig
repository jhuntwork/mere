const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;

// Import init module
const init_mod = @import("mere").init;

/// Init command metadata
const init_meta = command.CommandMeta{
    .name = "init",
    .description = "Initialize and validate Mere filesystem layout",
    .flags = &[_]types.Flag{
        .{
            .name = "dry-run",
            .short = 'n',
            .description = "Show what would be done without doing it",
            .flag_type = .bool,
        },
    },
};

/// Init command handler
pub fn handleInit(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const dry_run = args.getBool("dry-run");
    const verbose = args.getBool("verbose");

    const options = init_mod.InitOptions{
        .dry_run = dry_run,
        .verbose = verbose,
    };

    // Run initialization
    var result = init_mod.initialize(ctx, options) catch |err| {
        const msg = switch (err) {
            init_mod.InitError.PermissionDenied => "must be run as root",
            init_mod.InitError.FileSystem => "filesystem operation failed",
            init_mod.InitError.InvalidInput => "invalid filesystem state detected",
            init_mod.InitError.OutOfMemory => "out of memory",
        };
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, msg),
        };
    };
    defer result.deinit();

    // Build output
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(ctx.allocator);

    const writer = output.writer(ctx.allocator);

    // Show what will be done or was done
    if (result.issues_found == 0 and result.changes_applied == 0) {
        try writer.writeAll("All directories are correctly configured");
    } else {
        // Always show the summary of changes
        for (result.checks.items) |check| {
            switch (check.status) {
                .ok => {},
                .missing => {
                    if (dry_run) {
                        try writer.print("Would create {s} (mode {o:0>4})\n", .{ check.path, check.expected_mode });
                    } else {
                        try writer.print("Created {s} (mode {o:0>4})\n", .{ check.path, check.expected_mode });
                    }
                },
                .wrong_permissions => {
                    if (dry_run) {
                        try writer.print("Would fix permissions on {s} ({o:0>4} -> {o:0>4})\n", .{
                            check.path,
                            check.actual_mode.?,
                            check.expected_mode,
                        });
                    } else {
                        try writer.print("Fixed permissions on {s} ({o:0>4} -> {o:0>4})\n", .{
                            check.path,
                            check.actual_mode.?,
                            check.expected_mode,
                        });
                    }
                },
                .wrong_ownership => {
                    if (dry_run) {
                        try writer.print("Would fix ownership on {s} ({s} -> {s})\n", .{
                            check.path,
                            check.actual_owner.?,
                            check.expected_owner,
                        });
                    } else {
                        try writer.print("Fixed ownership on {s} ({s} -> {s})\n", .{
                            check.path,
                            check.actual_owner.?,
                            check.expected_owner,
                        });
                    }
                },
                .not_directory => try writer.print("Error: {s} exists but is not a directory\n", .{check.path}),
            }
        }

        // Summary
        if (dry_run) {
            try writer.print("\n{d} change(s) would be applied", .{result.issues_found});
        } else {
            try writer.print("\n{d} change(s) applied", .{result.changes_applied});
        }
    }

    // Always succeed if we got here - any errors during fixes would have returned early
    const success = true;
    const exit_code: u8 = 0;

    return types.CommandResult{
        .success = success,
        .exit_code = exit_code,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// Create the init command
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const init_cmd = try allocator.create(command.Command);
    init_cmd.* = command.Command.init(allocator, init_meta, handleInit);

    return init_cmd;
}
