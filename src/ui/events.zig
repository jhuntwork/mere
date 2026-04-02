const std = @import("std");

pub const Severity = enum {
    info,
    warn,
    err,
};

pub const SegmentKind = enum {
    normal,
    err,
    success,
    warn,
    label,
    detail,
};

pub const Segment = struct {
    text: []const u8,
    kind: SegmentKind = .normal,
};

pub const Phase = enum {
    prepare,
    build,
    install,
    verify,
    gc,
    import,
    init,
    convert,
    shell,
    dev,
    profile,
    store,
    generation,
    pin,
    key,
    etc,
    search,
    service,
};

pub const Subject = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const ProgressUnit = enum {
    bytes,
    items,
};

pub const ProgressData = struct {
    progress_id: u64,
    current: u64,
    total: ?u64 = null,
    unit: ProgressUnit = .bytes,
    rate_per_sec: ?u64 = null,
};

pub const DownloadQueuedData = struct {
    download_id: u64,
    expected_size: ?u64 = null,
    dest: ?[]const u8 = null,
};

pub const DownloadCompleteData = struct {
    download_id: u64,
    bytes_total: u64,
    checksum: ?[]const u8 = null,
};

pub const DownloadErrorData = struct {
    download_id: u64,
    retryable: bool = false,
};

pub const InstallStartData = struct {
    install_id: u64,
};

pub const InstallCompleteData = struct {
    install_id: u64,
};

pub const InstallErrorData = struct {
    install_id: u64,
};

pub const PhaseEndData = struct {
    status_ok: bool = true,
    duration_ms: ?u64 = null,
};

pub const StepEndData = struct {
    status_ok: bool = true,
    duration_ms: ?u64 = null,
};

pub const StepStartData = struct {
    is_last: ?bool = null,
};

pub const DiagnosticData = struct {
    code: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    cause: ?[]const u8 = null,
    details: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

pub const EventKind = enum {
    phase_start,
    phase_end,
    step_start,
    step_end,
    log_line,
    log_segments,
    diagnostic,
    download_queued,
    download_progress,
    download_complete,
    download_error,
    install_start,
    install_complete,
    install_error,
};

pub const EventData = union(EventKind) {
    phase_start: void,
    phase_end: PhaseEndData,
    step_start: StepStartData,
    step_end: StepEndData,
    log_line: void,
    log_segments: []const Segment,
    diagnostic: DiagnosticData,
    download_queued: DownloadQueuedData,
    download_progress: ProgressData,
    download_complete: DownloadCompleteData,
    download_error: DownloadErrorData,
    install_start: InstallStartData,
    install_complete: InstallCompleteData,
    install_error: InstallErrorData,
};

pub const Event = struct {
    id: u64,
    kind: EventKind,
    severity: Severity = .info,
    phase: ?Phase = null,
    subject: ?Subject = null,
    message: ?[]const u8 = null,
    timestamp_ms: ?i64 = null,
    data: EventData,

    /// message is free-form and not a stable contract. Stable data should be
    /// represented via structured fields (phase, subject, data payloads).
    pub const stable_fields = [_][]const u8{
        "id",
        "kind",
        "severity",
        "phase",
        "subject",
        "data",
    };

    pub fn init(id: u64, kind: EventKind) Event {
        return Event{
            .id = id,
            .kind = kind,
            .data = switch (kind) {
                .phase_start => .{ .phase_start = {} },
                .phase_end => .{ .phase_end = .{} },
                .step_start => .{ .step_start = .{} },
                .step_end => .{ .step_end = .{} },
                .log_line => .{ .log_line = {} },
                .log_segments => .{ .log_segments = &[_]Segment{} },
                .diagnostic => .{ .diagnostic = .{} },
                .download_queued => .{ .download_queued = .{ .download_id = 0 } },
                .download_progress => .{ .download_progress = .{ .progress_id = 0, .current = 0 } },
                .download_complete => .{ .download_complete = .{ .download_id = 0, .bytes_total = 0 } },
                .download_error => .{ .download_error = .{ .download_id = 0 } },
                .install_start => .{ .install_start = .{ .install_id = 0 } },
                .install_complete => .{ .install_complete = .{ .install_id = 0 } },
                .install_error => .{ .install_error = .{ .install_id = 0 } },
            },
        };
    }
};

test "Event init sets kind and id" {
    const event = Event.init(42, .phase_start);
    try std.testing.expectEqual(@as(u64, 42), event.id);
    try std.testing.expectEqual(EventKind.phase_start, event.kind);
}

test "Event stable fields list excludes message and timestamp" {
    const fields = Event.stable_fields;
    var has_message = false;
    var has_timestamp = false;
    for (fields) |field| {
        if (std.mem.eql(u8, field, "message")) has_message = true;
        if (std.mem.eql(u8, field, "timestamp_ms")) has_timestamp = true;
    }
    try std.testing.expect(!has_message);
    try std.testing.expect(!has_timestamp);
}

test "ProgressData supports bytes with optional total" {
    const data = ProgressData{
        .progress_id = 7,
        .current = 128,
        .total = 256,
        .unit = .bytes,
        .rate_per_sec = 64,
    };
    try std.testing.expectEqual(@as(u64, 7), data.progress_id);
    try std.testing.expectEqual(@as(u64, 128), data.current);
    try std.testing.expectEqual(@as(?u64, 256), data.total);
    try std.testing.expectEqual(ProgressUnit.bytes, data.unit);
}
