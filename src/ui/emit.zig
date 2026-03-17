const std = @import("std");
const mere = @import("../mere.zig");
const ui = @import("mod.zig");

pub fn phaseStart(ctx: *mere.Context, phase: ui.Phase, subject: ?ui.Subject) void {
    var event = ui.Event.init(ctx.nextEventId(), .phase_start);
    event.phase = phase;
    if (subject) |subj| {
        event.subject = subj;
    }
    ctx.emit(event);
}

pub fn phaseEnd(ctx: *mere.Context, phase: ui.Phase, ok: bool) void {
    var event = ui.Event.init(ctx.nextEventId(), .phase_end);
    event.phase = phase;
    event.data = .{ .phase_end = .{ .status_ok = ok } };
    if (!ok) event.severity = .err;
    ctx.emit(event);
}

pub fn stepStartLast(ctx: *mere.Context, phase: ui.Phase, name: []const u8, is_last: bool) void {
    var event = ui.Event.init(ctx.nextEventId(), .step_start);
    event.phase = phase;
    event.message = name;
    event.data = .{ .step_start = .{ .is_last = is_last } };
    ctx.emit(event);
}

pub fn stepEnd(ctx: *mere.Context, phase: ui.Phase, name: []const u8, ok: bool) void {
    var event = ui.Event.init(ctx.nextEventId(), .step_end);
    event.phase = phase;
    event.message = name;
    event.data = .{ .step_end = .{ .status_ok = ok } };
    if (!ok) event.severity = .err;
    ctx.emit(event);
}

pub fn logLine(ctx: *mere.Context, phase: ?ui.Phase, msg: []const u8) void {
    var event = ui.Event.init(ctx.nextEventId(), .log_line);
    if (phase) |p| {
        event.phase = p;
    }
    event.message = msg;
    ctx.emit(event);
}

pub fn logFmt(ctx: *mere.Context, phase: ?ui.Phase, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(ctx.allocator, fmt, args) catch return;
    defer ctx.allocator.free(msg);
    logLine(ctx, phase, msg);
}

pub fn logSegments(ctx: *mere.Context, phase: ?ui.Phase, segments: []const ui.Segment) void {
    logSegmentsSeverity(ctx, phase, .info, segments);
}

pub fn logSegmentsSeverity(ctx: *mere.Context, phase: ?ui.Phase, severity: ui.Severity, segments: []const ui.Segment) void {
    var event = ui.Event.init(ctx.nextEventId(), .log_segments);
    if (phase) |p| {
        event.phase = p;
    }
    event.severity = severity;
    event.data = .{ .log_segments = segments };
    ctx.emit(event);
}

pub fn logLineSeverity(ctx: *mere.Context, phase: ?ui.Phase, severity: ui.Severity, msg: []const u8) void {
    var event = ui.Event.init(ctx.nextEventId(), .log_line);
    if (phase) |p| {
        event.phase = p;
    }
    event.severity = severity;
    event.message = msg;
    ctx.emit(event);
}

pub fn logFmtSeverity(ctx: *mere.Context, phase: ?ui.Phase, severity: ui.Severity, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(ctx.allocator, fmt, args) catch return;
    defer ctx.allocator.free(msg);
    logLineSeverity(ctx, phase, severity, msg);
}

pub fn diagnostic(
    ctx: *mere.Context,
    phase: ui.Phase,
    summary: []const u8,
    subject: ?[]const u8,
    details: ?[]const u8,
    cause: ?[]const u8,
) void {
    var event = ui.Event.init(ctx.nextEventId(), .diagnostic);
    event.phase = phase;
    event.severity = .err;
    if (subject) |subj| {
        event.subject = .{ .path = subj };
    }
    event.data = .{ .diagnostic = .{
        .summary = summary,
        .cause = cause,
        .details = details,
    } };
    ctx.emit(event);
}

pub fn downloadQueued(ctx: *mere.Context, download_id: u64, subject: ui.Subject) void {
    var event = ui.Event.init(ctx.nextEventId(), .download_queued);
    event.subject = subject;
    event.data = .{ .download_queued = .{ .download_id = download_id, .dest = subject.path } };
    ctx.emit(event);
}

pub fn downloadProgress(ctx: *mere.Context, download_id: u64, subject: ui.Subject, current: u64, total: ?u64) void {
    var event = ui.Event.init(ctx.nextEventId(), .download_progress);
    event.subject = subject;
    event.data = .{ .download_progress = .{
        .progress_id = download_id,
        .current = current,
        .total = total,
        .unit = .bytes,
    } };
    ctx.emit(event);
}

pub fn downloadComplete(ctx: *mere.Context, download_id: u64, subject: ui.Subject, total: u64) void {
    var event = ui.Event.init(ctx.nextEventId(), .download_complete);
    event.subject = subject;
    event.data = .{ .download_complete = .{ .download_id = download_id, .bytes_total = total } };
    ctx.emit(event);
}

pub fn downloadError(ctx: *mere.Context, download_id: u64, subject: ui.Subject) void {
    var event = ui.Event.init(ctx.nextEventId(), .download_error);
    event.subject = subject;
    event.severity = .err;
    event.data = .{ .download_error = .{ .download_id = download_id, .retryable = false } };
    ctx.emit(event);
}

pub fn installStart(ctx: *mere.Context, label: []const u8) u64 {
    const install_id = ctx.nextEventId();
    var event = ui.Event.init(install_id, .install_start);
    event.phase = .install;
    event.message = label;
    event.data = .{ .install_start = .{ .install_id = install_id } };
    ctx.emit(event);
    return install_id;
}

pub fn installComplete(ctx: *mere.Context, install_id: u64, label: []const u8) void {
    var event = ui.Event.init(ctx.nextEventId(), .install_complete);
    event.phase = .install;
    event.message = label;
    event.data = .{ .install_complete = .{ .install_id = install_id } };
    ctx.emit(event);
}

pub fn installError(ctx: *mere.Context, install_id: u64, label: []const u8) void {
    var event = ui.Event.init(ctx.nextEventId(), .install_error);
    event.phase = .install;
    event.severity = .err;
    event.message = label;
    event.data = .{ .install_error = .{ .install_id = install_id } };
    ctx.emit(event);
}
