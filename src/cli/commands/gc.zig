const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const ui = mere.ui;
const emit = ui.emit;

// Import GC module
const gc = @import("mere").gc;

/// GC command metadata
const gc_meta = command.CommandMeta{
    .name = "gc",
    .description = "Run garbage collection on the store",
    .flags = &[_]types.Flag{
        .{
            .name = "dry-run",
            .short = 'n',
            .description = "Show what would be deleted without deleting",
            .flag_type = .bool,
        },
    },
};

fn emitGCPathLine(ctx: *mere.Context, path: []const u8) void {
    const segments = [_]ui.Segment{
        .{ .text = "  ", .kind = .normal },
        .{ .text = path, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .gc, .info, &segments);
}

fn emitGCSummary(ctx: *mere.Context, action: []const u8, count: usize) void {
    var count_buf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch return;
    const segments = [_]ui.Segment{
        .{ .text = "summary: ", .kind = .normal },
        .{ .text = action, .kind = .label },
        .{ .text = " ", .kind = .normal },
        .{ .text = count_text, .kind = .detail },
        .{ .text = " path(s)", .kind = .normal },
    };
    emit.logSegmentsSeverity(ctx, .gc, .info, &segments);
}

/// GC command handler
pub fn handleGC(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const dry_run = args.getBool("dry-run");

    emit.phaseStart(ctx, .gc, null);
    emit.stepStartLast(ctx, .gc, "collect", true);

    var result = gc.collectGarbage(ctx, .{
        .dry_run = dry_run,
    }) catch |err| {
        const diag = ctx.getDiagnosticContext();
        const msg = switch (err) {
            gc.GCError.NoRoots => "no GC roots found - nothing is protected, refusing to run",
            gc.GCError.PermissionDenied => "permission denied",
            gc.GCError.LockFailed => "failed to acquire lock",
            else => "garbage collection failed",
        };
        emit.stepEnd(ctx, .gc, "collect", false);
        emit.diagnostic(ctx, .gc, msg, diag.subject, diag.details, null);
        emit.phaseEnd(ctx, .gc, false);
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
        };
    };
    defer result.deinit();

    if (result.deleted_paths.items.len == 0) {
        if (dry_run) {
            emit.logLineSeverity(ctx, .gc, .info, "nothing to delete.");
        } else {
            emit.logLineSeverity(ctx, .gc, .info, "no unreachable paths found.");
        }
    } else {
        if (dry_run) {
            emit.logLineSeverity(ctx, .gc, .info, "would delete:");
        } else {
            emit.logLineSeverity(ctx, .gc, .info, "deleted:");
        }

        for (result.deleted_paths.items) |path| {
            emitGCPathLine(ctx, path);
        }

        if (dry_run) {
            emit.logLineSeverity(ctx, .gc, .info, "");
            emitGCSummary(ctx, "would delete", result.deleted_paths.items.len);
        } else {
            emit.logLineSeverity(ctx, .gc, .info, "");
            emitGCSummary(ctx, "deleted", result.deleted_paths.items.len);
        }
    }

    emit.stepEnd(ctx, .gc, "collect", true);
    emit.phaseEnd(ctx, .gc, true);

    return types.CommandResult{
        .success = true,
    };
}

/// Create the GC command
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const gc_cmd = try allocator.create(command.Command);
    gc_cmd.* = command.Command.init(allocator, gc_meta, handleGC);

    return gc_cmd;
}
