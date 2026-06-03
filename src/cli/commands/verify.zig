const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const ui = mere.ui;
const emit = ui.emit;

const verify_mod = mere.verify;

const verify_meta = command.CommandMeta{
    .name = "verify",
    .description = "Verify store, profiles, and GC roots",
    .flags = &[_]types.Flag{
        .{
            .name = "store",
            .description = "Verify store objects",
            .flag_type = .bool,
        },
        .{
            .name = "profiles",
            .description = "Verify profile generations",
            .flag_type = .bool,
        },
        .{
            .name = "gc-roots",
            .description = "Verify GC roots",
            .flag_type = .bool,
        },
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile to verify (default: all)",
            .flag_type = .string,
        },
        .{
            .name = "full",
            .description = "Recompute content hashes (slow)",
            .flag_type = .bool,
        },
    },
};

fn emitVerifySummaryRow(
    ctx: *mere.Context,
    subject: []const u8,
    checked: usize,
    checked_unit: []const u8,
    issues: usize,
) void {
    var checked_buf: [32]u8 = undefined;
    var issues_buf: [32]u8 = undefined;
    const checked_text = std.fmt.bufPrint(&checked_buf, "{d}", .{checked}) catch return;
    const issues_text = std.fmt.bufPrint(&issues_buf, "{d}", .{issues}) catch return;
    const issue_kind: ui.SegmentKind = if (issues > 0) .warn else .detail;
    const severity: ui.Severity = if (issues > 0) .warn else .info;
    const segments = [_]ui.Segment{
        .{ .text = "  ", .kind = .normal },
        .{ .text = subject, .kind = .label },
        .{ .text = ": checked ", .kind = .normal },
        .{ .text = checked_text, .kind = .detail },
        .{ .text = checked_unit, .kind = .normal },
        .{ .text = ", issues ", .kind = .normal },
        .{ .text = issues_text, .kind = issue_kind },
    };
    emit.logSegmentsSeverity(ctx, .verify, severity, &segments);
}

pub fn handleVerify(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const verify_store = args.getBool("store");
    const verify_profiles = args.getBool("profiles");
    const verify_gc_roots = args.getBool("gc-roots");

    var opts = verify_mod.VerifyOptions{
        .verify_store = verify_store,
        .verify_profiles = verify_profiles,
        .verify_gc_roots = verify_gc_roots,
        .full_hash = args.getBool("full"),
        .profile = args.getString("profile"),
    };

    if (!verify_store and !verify_profiles and !verify_gc_roots) {
        opts.verify_store = true;
        opts.verify_profiles = true;
        opts.verify_gc_roots = true;
    }

    emit.phaseStart(ctx, .verify, null);
    const step_count: u8 =
        @as(u8, @intFromBool(opts.verify_store)) +
        @as(u8, @intFromBool(opts.verify_profiles)) +
        @as(u8, @intFromBool(opts.verify_gc_roots));
    var step_index: u8 = 0;
    if (opts.verify_store) {
        step_index += 1;
        emit.stepStartLast(ctx, .verify, "store", step_index == step_count);
    }
    if (opts.verify_profiles) {
        step_index += 1;
        emit.stepStartLast(ctx, .verify, "profiles", step_index == step_count);
    }
    if (opts.verify_gc_roots) {
        step_index += 1;
        emit.stepStartLast(ctx, .verify, "gc-roots", step_index == step_count);
    }

    var result = verify_mod.verifyAll(ctx, opts) catch |err| {
        emit.diagnostic(ctx, .verify, switch (err) {
            verify_mod.VerifyError.PermissionDenied => "permission denied",
            verify_mod.VerifyError.FileSystem => "filesystem error",
            verify_mod.VerifyError.InvalidInput => "invalid input",
            verify_mod.VerifyError.OutOfMemory => "out of memory",
        }, null, null, null);
        emit.phaseEnd(ctx, .verify, false);
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
        };
    };
    defer result.deinit(ctx.allocator);

    emit.logLineSeverity(ctx, .verify, .info, "verify summary:");
    if (opts.verify_store) {
        emitVerifySummaryRow(ctx, "store", result.store_checked, "", result.store_issues);
    }
    if (opts.verify_profiles) {
        emitVerifySummaryRow(ctx, "profiles", result.profile_realizations_checked, " realizations", result.profile_issues);
    }
    if (opts.verify_gc_roots) {
        emitVerifySummaryRow(ctx, "gc-roots", result.gc_roots_checked, "", result.gc_roots_issues);
    }

    if (result.issues.items.len == 0) {
        emit.logLineSeverity(ctx, .verify, .info, "");
        emit.logLineSeverity(ctx, .verify, .info, "no issues found.");
    } else {
        emit.logLineSeverity(ctx, .verify, .info, "");
        emit.logLineSeverity(ctx, .verify, .warn, "issues:");
        for (result.issues.items) |issue| {
            const issue_segments = [_]ui.Segment{
                .{ .text = "  [", .kind = .normal },
                .{ .text = kindLabel(issue.kind), .kind = .label },
                .{ .text = "] ", .kind = .normal },
                .{ .text = issue.path, .kind = .detail },
                .{ .text = ": ", .kind = .normal },
                .{ .text = issue.message, .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .verify, .warn, &issue_segments);
        }
    }

    const success = result.issues.items.len == 0;
    const exit_code: u8 = if (success) 0 else 1;

    if (opts.verify_store) emit.stepEnd(ctx, .verify, "store", result.store_issues == 0);
    if (opts.verify_profiles) emit.stepEnd(ctx, .verify, "profiles", result.profile_issues == 0);
    if (opts.verify_gc_roots) emit.stepEnd(ctx, .verify, "gc-roots", result.gc_roots_issues == 0);
    emit.phaseEnd(ctx, .verify, success);

    return types.CommandResult{
        .success = success,
        .exit_code = exit_code,
    };
}

fn kindLabel(kind: verify_mod.IssueKind) []const u8 {
    return switch (kind) {
        .store => "store",
        .profile => "profile",
        .gc_roots => "gc-roots",
        .trust => "trust",
    };
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, verify_meta, handleVerify);
    return cmd;
}
