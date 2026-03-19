const std = @import("std");
const ui = @import("mod.zig");
const palette = @import("palette.zig");

pub const Options = struct {
    use_color: bool = false,
    indent: []const u8 = "  ",
};

pub const Writer = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
    flushFn: ?*const fn (ctx: *anyopaque) anyerror!void = null,

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        try self.writeFn(self.ctx, bytes);
    }

    pub fn flush(self: *Writer) !void {
        if (self.flushFn) |func| {
            try func(self.ctx);
        }
    }
};

pub const Renderer = struct {
    out: Writer,
    err: Writer,
    allocator: std.mem.Allocator,
    options: Options,
    indent_level: usize = 0,
    step_depth: usize = 0,
    pending_child: ?PendingChild = null,

    pub fn init(allocator: std.mem.Allocator, out_writer: anytype, err_writer: anytype, options: Options) Renderer {
        return Renderer{
            .out = makeWriter(out_writer),
            .err = makeWriter(err_writer),
            .allocator = allocator,
            .options = options,
            .indent_level = 0,
            .step_depth = 0,
        };
    }

    pub fn render(self: *Renderer, event: ui.Event) !void {
        switch (event.kind) {
            .phase_start => try self.renderPhaseStart(event),
            .phase_end => try self.renderPhaseEnd(event),
            .step_start => try self.renderStepStart(event),
            .step_end => try self.renderStepEnd(event),
            .log_line => try self.renderLogLine(event),
            .log_segments => try self.renderLogSegments(event),
            .diagnostic => try self.renderDiagnostic(event),
            .download_progress => {},
            .download_queued => try self.renderDownloadQueued(event),
            .download_complete => try self.renderDownloadComplete(event),
            .download_error => try self.renderDownloadError(event),
            .install_start => try self.renderInstallStart(event),
            .install_complete => try self.renderInstallComplete(event),
            .install_error => try self.renderInstallError(event),
        }
    }

    pub fn flushPendingAsLast(self: *Renderer) !void {
        try self.flushPendingChild(true);
    }

    pub fn flushPendingAsContinuing(self: *Renderer) !void {
        try self.flushPendingChild(false);
    }

    fn renderPhaseStart(self: *Renderer, event: ui.Event) !void {
        try self.flushPendingChild(true);
        const phase_label = phaseName(event.phase);
        if (phase_label == null) return;

        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);

        try appendLabelCode(allocator, &line, phase_label.?, self.options.use_color, palette.code(.phase));

        if (!appendSubject(allocator, &line, event.subject, true)) {
            if (event.message) |msg| {
                try line.append(allocator, ' ');
                try line.appendSlice(allocator, msg);
            }
        }

        try writeLine(&self.out, line.items);
        self.step_depth = 0;
        self.indent_level = 1;
    }

    fn renderPhaseEnd(self: *Renderer, event: ui.Event) !void {
        try self.flushPendingChild(true);
        const data = event.data.phase_end;
        self.step_depth = 0;
        self.indent_level = 0;
        if (data.status_ok) return;

        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);

        try appendLabelCode(allocator, &line, "error", self.options.use_color, palette.code(.err));
        if (event.message) |msg| {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, msg);
        } else if (phaseName(event.phase)) |phase_label| {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, phase_label);
            try line.appendSlice(allocator, " failed");
        }

        try writeLine(&self.err, line.items);
    }

    fn renderStepStart(self: *Renderer, event: ui.Event) !void {
        // A new step means any queued child line is followed by at least one sibling.
        try self.flushPendingChild(false);
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);

        try appendStepPrefix(allocator, &line, self.step_depth, self.options);
        if (event.message) |msg| {
            if (self.step_depth == 0) {
                try appendLabelCode(allocator, &line, msg, self.options.use_color, palette.code(.step_primary));
            } else {
                try appendLabelCode(allocator, &line, msg, self.options.use_color, palette.code(.step_secondary));
            }
        } else if (!appendSubject(allocator, &line, event.subject, false)) {
            try line.appendSlice(allocator, "step");
        }

        try writeLine(&self.out, line.items);
        self.step_depth += 1;
        self.indent_level = self.step_depth + 1;
    }

    fn renderStepEnd(self: *Renderer, event: ui.Event) !void {
        try self.flushPendingChild(true);
        _ = event.data.step_end;
        if (self.step_depth > 0) {
            self.step_depth -= 1;
        }
        self.indent_level = self.step_depth + 1;
    }

    fn renderLogLine(self: *Renderer, event: ui.Event) !void {
        const msg = event.message orelse return;
        if (msg.len == 0) return;
        try self.queueChildLine(if (event.severity == .info) .out else .err, msg);
    }

    fn renderLogSegments(self: *Renderer, event: ui.Event) !void {
        const segments = event.data.log_segments;
        if (segments.len == 0) return;
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        for (segments) |segment| {
            if (segment.text.len == 0) continue;
            try appendSegment(allocator, &line, segment, self.options.use_color);
        }
        try self.queueChildLine(if (event.severity == .info) .out else .err, line.items);
    }

    fn renderDownloadQueued(self: *Renderer, event: ui.Event) !void {
        const url = if (event.subject) |subject| subject.url else null;
        const label = url orelse event.message orelse return;
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "downloading ");
        try line.appendSlice(allocator, label);
        try self.queueChildLine(.out, line.items);
    }

    fn renderDownloadComplete(self: *Renderer, event: ui.Event) !void {
        const url = if (event.subject) |subject| subject.url else null;
        const label = url orelse event.message orelse return;
        const segments = [_]ui.Segment{
            .{ .text = label, .kind = .normal },
            .{ .text = " downloaded", .kind = .success },
        };
        var log_event = ui.Event.init(event.id, .log_segments);
        log_event.phase = event.phase;
        log_event.severity = .info;
        log_event.data = .{ .log_segments = &segments };
        try self.renderLogSegments(log_event);
    }

    fn renderDownloadError(self: *Renderer, event: ui.Event) !void {
        const url = if (event.subject) |subject| subject.url else null;
        const label = url orelse event.message orelse "download";
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try appendLabelCode(allocator, &line, "error", self.options.use_color, palette.code(.err));
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, label);
        try self.queueChildLine(.err, line.items);
    }

    fn renderInstallStart(self: *Renderer, event: ui.Event) !void {
        const label = event.message orelse return;
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "installing ");
        try line.appendSlice(allocator, label);
        try self.queueChildLine(.out, line.items);
    }

    fn renderInstallComplete(self: *Renderer, event: ui.Event) !void {
        const label = event.message orelse return;
        const segments = [_]ui.Segment{
            .{ .text = label, .kind = .normal },
            .{ .text = " installed", .kind = .success },
            .{ .text = " to store", .kind = .detail },
        };
        var log_event = ui.Event.init(event.id, .log_segments);
        log_event.phase = event.phase;
        log_event.severity = .info;
        log_event.data = .{ .log_segments = &segments };
        try self.renderLogSegments(log_event);
    }

    fn renderInstallError(self: *Renderer, event: ui.Event) !void {
        const label = event.message orelse "package";
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try appendLabelCode(allocator, &line, "error", self.options.use_color, palette.code(.err));
        try line.appendSlice(allocator, " installing ");
        try line.appendSlice(allocator, label);
        try self.queueChildLine(.err, line.items);
    }

    fn renderDiagnostic(self: *Renderer, event: ui.Event) !void {
        try self.flushPendingChild(true);
        const diag = event.data.diagnostic;
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);

        try appendLabelCode(allocator, &line, "error", self.options.use_color, palette.code(.err));
        if (diag.summary) |summary| {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, summary);
        } else if (event.message) |msg| {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, msg);
        }

        try writeLine(&self.err, line.items);

        if (event.subject) |subject| {
            if (subject.name != null or subject.path != null or subject.url != null) {
                var subject_buf: std.ArrayList(u8) = .empty;
                defer subject_buf.deinit(allocator);
                _ = appendSubject(allocator, &subject_buf, event.subject, false);
                try writeLabelLine(self.allocator, &self.err, self.options.indent, "subject", subject_buf.items, self.options.use_color);
            }
        }
        if (phaseName(event.phase)) |phase_label| {
            try writeLabelLine(self.allocator, &self.err, self.options.indent, "phase", phase_label, self.options.use_color);
        }
        if (diag.cause) |cause| {
            try writeLabelLine(self.allocator, &self.err, self.options.indent, "cause", cause, self.options.use_color);
        }
        if (diag.details) |details| {
            try writeDetailsLine(self.allocator, &self.err, self.options.indent, details, self.options.use_color);
        }
        if (diag.hint) |hint| {
            try writeLabelLine(self.allocator, &self.err, self.options.indent, "hint", hint, self.options.use_color);
        }
    }

    fn queueChildLine(self: *Renderer, writer_kind: WriterKind, msg: []const u8) !void {
        if (self.indent_level < 2) {
            try self.writeChildLine(writer_kind, msg, true);
            return;
        }
        try self.flushPendingChild(false);
        const allocator = self.allocator;
        self.pending_child = .{
            .writer_kind = writer_kind,
            .msg = try allocator.dupe(u8, msg),
        };
    }

    fn flushPendingChild(self: *Renderer, child_is_last: bool) !void {
        const pending = self.pending_child orelse return;
        defer {
            self.allocator.free(pending.msg);
            self.pending_child = null;
        }
        try self.writeChildLine(pending.writer_kind, pending.msg, child_is_last);
    }

    fn writeChildLine(self: *Renderer, writer_kind: WriterKind, msg: []const u8, child_is_last: bool) !void {
        const allocator = self.allocator;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try appendContentPrefix(allocator, &line, self.step_depth, self.options, child_is_last);
        try line.appendSlice(allocator, msg);
        const writer: *Writer = switch (writer_kind) {
            .out => &self.out,
            .err => &self.err,
        };
        try writeLine(writer, line.items);
    }
};

const WriterKind = enum {
    out,
    err,
};

const PendingChild = struct {
    writer_kind: WriterKind,
    msg: []u8,
};

pub const DefaultEmitter = struct {
    emitter: ui.Emitter,
    renderer: Renderer,

    pub fn init(allocator: std.mem.Allocator, out_writer: anytype, err_writer: anytype, options: Options) DefaultEmitter {
        var self = DefaultEmitter{
            .emitter = undefined,
            .renderer = Renderer.init(allocator, out_writer, err_writer, options),
        };
        self.emitter = .{ .emitFn = emit };
        return self;
    }

    fn emit(emitter: *ui.Emitter, event: ui.Event) void {
        const self: *DefaultEmitter = @fieldParentPtr("emitter", emitter);
        _ = self.renderer.render(event) catch |err| {
            var buf: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "render error: {s}\n", .{@errorName(err)}) catch "render error\n";
            self.renderer.err.writeAll(line) catch {};
            self.renderer.err.flush() catch {};
        };
    }
};

fn phaseName(phase: ?ui.Phase) ?[]const u8 {
    return if (phase) |p| switch (p) {
        .prepare => "prepare",
        .build => "build",
        .install => "install",
        .verify => "verify",
        .gc => "gc",
        .import => "import",
        .init => "init",
        .convert => "convert",
        .shell => "shell",
        .dev => "dev",
        .profile => "profile",
        .store => "store",
        .generation => "generation",
        .pin => "pin",
        .key => "key",
        .etc => "etc",
        .search => "search",
    } else null;
}

fn appendSubject(allocator: std.mem.Allocator, line: *std.ArrayList(u8), subject_opt: ?ui.Subject, prefix_space: bool) bool {
    const subject = subject_opt orelse return false;
    if (subject.name) |name| {
        if (prefix_space) line.append(allocator, ' ') catch return false;
        line.appendSlice(allocator, name) catch return false;
        if (subject.version) |ver| {
            line.append(allocator, '-') catch return false;
            line.appendSlice(allocator, ver) catch return false;
        }
        return true;
    }
    if (subject.path) |path| {
        if (prefix_space) line.append(allocator, ' ') catch return false;
        line.appendSlice(allocator, path) catch return false;
        return true;
    }
    if (subject.url) |url| {
        if (prefix_space) line.append(allocator, ' ') catch return false;
        line.appendSlice(allocator, url) catch return false;
        return true;
    }
    return false;
}

fn appendLabelCode(
    allocator: std.mem.Allocator,
    line: *std.ArrayList(u8),
    label: []const u8,
    use_color: bool,
    color_code: []const u8,
) !void {
    if (use_color) {
        try line.appendSlice(allocator, "\x1b[");
        try line.appendSlice(allocator, color_code);
        try line.appendSlice(allocator, "m");
    }
    try line.appendSlice(allocator, label);
    if (use_color) {
        try line.appendSlice(allocator, "\x1b[0m");
    }
}

fn appendSegment(allocator: std.mem.Allocator, line: *std.ArrayList(u8), segment: ui.Segment, use_color: bool) !void {
    const color_code = palette.segmentCode(segment.kind);
    if (color_code) |code| {
        try appendLabelCode(allocator, line, segment.text, use_color, code);
    } else {
        try line.appendSlice(allocator, segment.text);
    }
}

fn appendIndent(allocator: std.mem.Allocator, line: *std.ArrayList(u8), level: usize, indent: []const u8) !void {
    if (level == 0) return;
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try line.appendSlice(allocator, indent);
    }
}

fn appendStepPrefix(
    allocator: std.mem.Allocator,
    line: *std.ArrayList(u8),
    step_depth: usize,
    options: Options,
) !void {
    return appendIndent(allocator, line, step_depth + 1, options.indent);
}

fn appendContentPrefix(
    allocator: std.mem.Allocator,
    line: *std.ArrayList(u8),
    step_depth: usize,
    options: Options,
    _: bool,
) !void {
    return appendIndent(allocator, line, step_depth + 1, options.indent);
}

fn writeLabelLine(allocator: std.mem.Allocator, writer: *Writer, indent: []const u8, label: []const u8, value: []const u8, use_color: bool) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, indent);
    try appendLabelCode(allocator, &line, label, use_color, palette.code(.meta_label));
    try line.appendSlice(allocator, ": ");
    try line.appendSlice(allocator, value);
    try writeLine(writer, line.items);
}

fn writeDetailsLine(allocator: std.mem.Allocator, writer: *Writer, indent: []const u8, details: []const u8, use_color: bool) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, indent);
    try appendLabelCode(allocator, &line, "details", use_color, palette.code(.meta_label));
    try line.appendSlice(allocator, ": ");
    try appendHashHighlighted(allocator, &line, details, use_color);
    try writeLine(writer, line.items);
}

fn appendHashHighlighted(allocator: std.mem.Allocator, line: *std.ArrayList(u8), text: []const u8, use_color: bool) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (isLowerHexHashAt(text, i)) {
            try appendLabelCode(allocator, line, text[i .. i + 64], use_color, palette.code(.hash_muted));
            i += 64;
            continue;
        }
        try line.append(allocator, text[i]);
        i += 1;
    }
}

fn isLowerHexHashAt(text: []const u8, start: usize) bool {
    if (start + 64 > text.len) return false;
    const end = start + 64;
    if (start > 0 and isLowerHex(text[start - 1])) return false;
    if (end < text.len and isLowerHex(text[end])) return false;
    var i = start;
    while (i < end) : (i += 1) {
        if (!isLowerHex(text[i])) return false;
    }
    return true;
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

fn writeLine(writer: *Writer, line: []const u8) !void {
    try writer.writeAll(line);
    try writer.writeAll("\n");
}

fn makeWriter(writer_ptr: anytype) Writer {
    const info = @typeInfo(@TypeOf(writer_ptr));
    if (info != .pointer) {
        @compileError("writer must be a pointer");
    }
    return Writer{
        .ctx = @ptrCast(@alignCast(writer_ptr)),
        .writeFn = writeFnFor(@TypeOf(writer_ptr)),
        .flushFn = flushFnFor(@TypeOf(writer_ptr)),
    };
}

fn writeFnFor(comptime WriterPtr: type) *const fn (*anyopaque, []const u8) anyerror!void {
    const WriterType = @typeInfo(WriterPtr).pointer.child;
    return struct {
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const writer: *WriterType = @ptrCast(@alignCast(ctx));
            if (@hasField(WriterType, "interface")) {
                try writer.interface.writeAll(bytes);
            } else {
                try writer.writeAll(bytes);
            }
        }
    }.write;
}

fn flushFnFor(comptime WriterPtr: type) ?*const fn (*anyopaque) anyerror!void {
    const WriterType = @typeInfo(WriterPtr).pointer.child;
    return struct {
        fn flush(ctx: *anyopaque) anyerror!void {
            const writer: *WriterType = @ptrCast(@alignCast(ctx));
            if (@hasField(WriterType, "interface")) {
                try writer.interface.flush();
            } else if (@hasDecl(WriterType, "flush")) {
                try writer.flush();
            }
        }
    }.flush;
}

test "default renderer prints lowercase phase label" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var renderer = Renderer.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{ .use_color = false });
    var event = ui.Event.init(1, .phase_start);
    event.phase = .prepare;
    event.subject = .{ .name = "busybox", .version = "1.36.1" };

    try renderer.render(event);
    try std.testing.expectEqualStrings("prepare busybox-1.36.1\n", out_buf.written());
}

test "default renderer prints diagnostic details" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var renderer = Renderer.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{ .use_color = false });
    var event = ui.Event.init(2, .diagnostic);
    event.data = .{ .diagnostic = .{
        .summary = "build failed",
        .details = "cc exited 2",
        .hint = "run with --debug",
    } };
    event.phase = .build;
    event.subject = .{ .name = "demo", .version = "1.0.0" };

    try renderer.render(event);

    const expected =
        "error build failed\n" ++
        "  subject: demo-1.0.0\n" ++
        "  phase: build\n" ++
        "  details: cc exited 2\n" ++
        "  hint: run with --debug\n";
    try std.testing.expectEqualStrings(expected, err_buf.written());
}

test "default renderer prints fallback failed phase label without message" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var renderer = Renderer.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{ .use_color = false });
    var event = ui.Event.init(3, .phase_end);
    event.phase = .build;
    event.data = .{ .phase_end = .{ .status_ok = false } };

    try renderer.render(event);

    try std.testing.expectEqualStrings("error build failed\n", err_buf.written());
}

test "default renderer dims hash values in diagnostic details" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var renderer = Renderer.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{ .use_color = true });
    var event = ui.Event.init(3, .diagnostic);
    event.data = .{ .diagnostic = .{
        .summary = "build failed",
        .details = "blake3 mismatch; expected=2ad59909033cecd00ea1365dd3308d5a0dcaf40225b1a295f160fae58aeddb4c; actual=2ad59909033cecd00ea1365dd3308d5a0dcaf40225b1a295f160fae58aeddb4b",
    } };

    try renderer.render(event);

    try std.testing.expect(std.mem.indexOf(
        u8,
        err_buf.written(),
        "\x1b[90m2ad59909033cecd00ea1365dd3308d5a0dcaf40225b1a295f160fae58aeddb4c\x1b[0m",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        err_buf.written(),
        "\x1b[90m2ad59909033cecd00ea1365dd3308d5a0dcaf40225b1a295f160fae58aeddb4b\x1b[0m",
    ) != null);
}

test "default renderer keeps sibling branch when step follows queued log lines" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var renderer = Renderer.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{ .use_color = false });

    var phase_start = ui.Event.init(1, .phase_start);
    phase_start.phase = .build;
    phase_start.subject = .{ .name = "perl", .version = "5.42.0" };
    try renderer.render(phase_start);

    var step_start = ui.Event.init(2, .step_start);
    step_start.data = .{ .step_start = .{ .is_last = true } };
    step_start.message = "install dependencies";
    try renderer.render(step_start);

    var log1 = ui.Event.init(3, .log_line);
    log1.message = "local.db downloaded 96 KiB";
    try renderer.render(log1);

    var log2 = ui.Event.init(4, .log_line);
    log2.message = "local.db.sig downloaded 64 B";
    try renderer.render(log2);

    var child_step = ui.Event.init(5, .step_start);
    child_step.data = .{ .step_start = .{ .is_last = true } };
    child_step.message = "store admission";
    try renderer.render(child_step);

    const expected =
        "build perl-5.42.0\n" ++
        "  install dependencies\n" ++
        "    local.db downloaded 96 KiB\n" ++
        "    local.db.sig downloaded 64 B\n" ++
        "    store admission\n";
    try std.testing.expectEqualStrings(expected, out_buf.written());
}

test "default emitter reports render failures to stderr" {
    const FailingWriter = struct {
        fn writeAll(_: *@This(), _: []const u8) !void {
            return error.TestWriteFailed;
        }
    };

    var out = FailingWriter{};
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var emitter = DefaultEmitter.init(std.testing.allocator, &out, &err_buf.writer, .{ .use_color = false });
    var event = ui.Event.init(42, .phase_start);
    event.phase = .prepare;
    event.subject = .{ .name = "demo", .version = "1.0.0" };

    emitter.emitter.emit(event);
    try std.testing.expect(std.mem.containsAtLeast(u8, err_buf.written(), 1, "render error:"));
}

test "default renderer releases allocator-owned transient buffers" {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .{ .backing_allocator = std.testing.allocator };
    const alloc = debug_allocator.allocator();

    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var renderer = Renderer.init(alloc, &out_buf.writer, &err_buf.writer, .{ .use_color = false });

    var phase_start = ui.Event.init(100, .phase_start);
    phase_start.phase = .build;
    phase_start.subject = .{ .name = "demo", .version = "1.0.0" };
    try renderer.render(phase_start);

    var step_start = ui.Event.init(101, .step_start);
    step_start.data = .{ .step_start = .{ .is_last = true } };
    step_start.message = "compile";
    try renderer.render(step_start);

    var log_line = ui.Event.init(102, .log_line);
    log_line.message = "running cc";
    try renderer.render(log_line);

    var step_end = ui.Event.init(103, .step_end);
    step_end.data = .{ .step_end = .{ .status_ok = true } };
    try renderer.render(step_end);

    try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}
