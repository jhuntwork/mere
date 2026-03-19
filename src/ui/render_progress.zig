const std = @import("std");
const ui = @import("mod.zig");
const render_default = @import("render_default.zig");

pub const Options = struct {
    use_color: bool = false,
    tty: bool = false,
    bar_width: u8 = 20,
    indent: []const u8 = "  ",
};

pub const ProgressEmitter = struct {
    emitter: ui.Emitter,
    renderer: render_default.Renderer,
    allocator: std.mem.Allocator,
    options: Options,
    downloads: std.ArrayList(DownloadEntry),
    last_render_ms: i64 = 0,
    last_render_lines: usize = 0,
    active_line: bool = false,
    active_install_id: ?u64 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        out_writer: anytype,
        err_writer: anytype,
        options: Options,
    ) ProgressEmitter {
        var self = ProgressEmitter{
            .emitter = undefined,
            .renderer = render_default.Renderer.init(allocator, out_writer, err_writer, .{
                .use_color = options.use_color,
                .indent = options.indent,
            }),
            .allocator = allocator,
            .options = options,
            .downloads = .empty,
        };
        self.emitter = .{ .emitFn = emit };
        return self;
    }

    pub fn deinit(self: *ProgressEmitter) void {
        for (self.downloads.items) |*entry| {
            self.allocator.free(entry.label);
        }
        self.downloads.deinit(self.allocator);
    }

    fn emit(emitter: *ui.Emitter, event: ui.Event) void {
        const self: *ProgressEmitter = @fieldParentPtr("emitter", emitter);
        self.handle(event) catch {};
    }

    fn handle(self: *ProgressEmitter, event: ui.Event) !void {
        if (self.options.tty and !isInlineEvent(event.kind)) {
            if (self.last_render_lines > 0) {
                try self.clearBlock();
            }
            if (self.active_line) {
                try clearLine(&self.renderer.out);
                self.active_line = false;
                self.active_install_id = null;
            }
        }
        switch (event.kind) {
            .download_queued => {
                if (!self.options.tty) {
                    try self.renderer.render(event);
                } else {
                    _ = try self.ensureEntry(event);
                }
            },
            .download_progress => {
                if (self.options.tty) {
                    try self.onDownloadProgressLine(event);
                } else {
                    try self.onDownloadProgressText(event);
                }
            },
            .download_complete => {
                if (self.options.tty) {
                    try self.onDownloadCompleteLine(event);
                } else {
                    try self.renderer.render(event);
                }
            },
            .download_error => {
                if (self.options.tty) {
                    try self.onDownloadErrorLine(event);
                } else {
                    try self.renderer.render(event);
                }
            },
            .install_start => {
                if (self.options.tty) {
                    try self.onInstallStartLine(event);
                } else {
                    try self.renderer.render(event);
                }
            },
            .install_complete => {
                if (self.options.tty) {
                    try self.onInstallCompleteLine(event);
                } else {
                    try self.renderer.render(event);
                }
            },
            .install_error => {
                if (self.options.tty) {
                    try self.onInstallErrorLine(event);
                } else {
                    try self.renderer.render(event);
                }
            },
            .step_start => {
                try self.renderer.render(event);
            },
            .step_end => {
                try self.renderer.render(event);
            },
            .log_line => {
                try self.renderer.render(event);
            },
            else => try self.renderer.render(event),
        }
        try self.renderer.out.flush();
        try self.renderer.err.flush();
    }

    fn onDownloadProgressText(self: *ProgressEmitter, event: ui.Event) !void {
        const data = event.data.download_progress;
        if (data.total == null or data.total.? == 0) return;
        const entry = try self.ensureEntry(event);
        const percent = @as(u8, @intCast(@min((data.current * 100) / data.total.?, 100)));
        if (percent < entry.last_percent + 5 and percent != 100) return;
        entry.last_percent = percent;

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try appendTreeBranchToLine(self.allocator, &line, &self.renderer, self.options, false);
        try line.appendSlice(self.allocator, "downloading ");
        try line.appendSlice(self.allocator, entry.label);
        try line.appendSlice(self.allocator, " ");
        try appendBytesToLine(self.allocator, &line, data.current);
        try line.appendSlice(self.allocator, " / ");
        try appendBytesToLine(self.allocator, &line, data.total.?);
        try writeLine(&self.renderer.out, line.items);
    }

    fn onDownloadProgressLine(self: *ProgressEmitter, event: ui.Event) !void {
        const entry = try self.ensureEntry(event);
        const data = event.data.download_progress;
        entry.current = data.current;
        entry.total = data.total;
        if (data.total) |total| {
            if (total > 0) {
                const percent = @as(u8, @intCast(@min((data.current * 100) / total, 100)));
                entry.last_percent = percent;
            }
        }
        try self.renderBlockThrottled();
    }

    fn onDownloadCompleteLine(self: *ProgressEmitter, event: ui.Event) !void {
        if (self.last_render_lines > 0) {
            try self.clearBlock();
        }
        if (self.active_line) {
            try clearLine(&self.renderer.out);
            self.active_line = false;
            self.active_install_id = null;
        }
        if (self.findEntryIndex(event)) |idx| {
            const label = self.downloads.items[idx].label;
            try self.renderDownloadCompleteSegments(label, event.data.download_complete.bytes_total);
            self.allocator.free(self.downloads.items[idx].label);
            _ = self.downloads.orderedRemove(idx);
            if (self.downloads.items.len > 0) {
                try self.renderBlock();
            }
            return;
        }

        const label = try self.labelForEvent(event);
        defer self.allocator.free(label);
        try self.renderDownloadCompleteSegments(label, event.data.download_complete.bytes_total);
        if (self.downloads.items.len > 0) {
            try self.renderBlock();
        }
    }

    fn onDownloadErrorLine(self: *ProgressEmitter, event: ui.Event) !void {
        if (self.last_render_lines > 0) {
            try self.clearBlock();
        }
        if (self.active_line) {
            try clearLine(&self.renderer.out);
            self.active_line = false;
            self.active_install_id = null;
        }
        if (self.findEntryIndex(event)) |idx| {
            const label = self.downloads.items[idx].label;
            _ = self.downloads.orderedRemove(idx);
            if (self.downloads.items.len > 0) {
                try self.renderBlock();
            } else {
                self.last_render_lines = 0;
            }
            defer self.allocator.free(label);
            try self.printErrorLine(label);
            return;
        }

        const label = try self.labelForEvent(event);
        defer self.allocator.free(label);
        if (self.downloads.items.len > 0) {
            try self.renderBlock();
        } else {
            self.last_render_lines = 0;
        }
        try self.printErrorLine(label);
    }

    fn onInstallStartLine(self: *ProgressEmitter, event: ui.Event) !void {
        const label = event.message orelse return;
        if (self.active_line) {
            try clearLine(&self.renderer.out);
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try appendTreeBranchToLine(self.allocator, &line, &self.renderer, self.options, false);
        try line.appendSlice(self.allocator, "installing ");
        try line.appendSlice(self.allocator, label);
        try self.renderer.out.writeAll(line.items);
        self.active_line = true;
        self.active_install_id = event.data.install_start.install_id;
    }

    fn onInstallCompleteLine(self: *ProgressEmitter, event: ui.Event) !void {
        const label = event.message orelse return;
        if (self.active_line and self.active_install_id != null and self.active_install_id.? == event.data.install_complete.install_id) {
            try clearLine(&self.renderer.out);
            self.active_line = false;
            self.active_install_id = null;
        }
        const segments = [_]ui.Segment{
            .{ .text = label, .kind = .normal },
            .{ .text = " installed", .kind = .success },
            .{ .text = " to store", .kind = .detail },
        };
        var log_event = ui.Event.init(event.id, .log_segments);
        log_event.phase = event.phase;
        log_event.severity = .info;
        log_event.data = .{ .log_segments = &segments };
        try self.renderer.render(log_event);
    }

    fn onInstallErrorLine(self: *ProgressEmitter, event: ui.Event) !void {
        const label = event.message orelse "package";
        if (self.active_line and self.active_install_id != null and self.active_install_id.? == event.data.install_error.install_id) {
            try clearLine(&self.renderer.out);
            self.active_line = false;
            self.active_install_id = null;
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try appendTreeBranchToLine(self.allocator, &line, &self.renderer, self.options, false);
        try line.appendSlice(self.allocator, "error installing ");
        try line.appendSlice(self.allocator, label);
        try writeLine(&self.renderer.err, line.items);
    }

    fn renderDownloadCompleteSegments(self: *ProgressEmitter, label: []const u8, total: u64) !void {
        var size_buf: [32]u8 = undefined;
        const size = formatBytes(&size_buf, total);
        const segments = [_]ui.Segment{
            .{ .text = label, .kind = .normal },
            .{ .text = " downloaded", .kind = .success },
            .{ .text = " ", .kind = .detail },
            .{ .text = size, .kind = .detail },
        };
        var event = ui.Event.init(0, .log_segments);
        event.phase = null;
        event.data = .{ .log_segments = &segments };
        try self.renderer.render(event);
    }

    fn ensureEntry(self: *ProgressEmitter, event: ui.Event) !*DownloadEntry {
        if (self.findEntryIndex(event)) |idx| {
            return &self.downloads.items[idx];
        }
        const label = try self.labelForEvent(event);
        const id = downloadId(event);
        try self.downloads.append(self.allocator, DownloadEntry{
            .id = id,
            .label = label,
        });
        return &self.downloads.items[self.downloads.items.len - 1];
    }

    fn findEntryIndex(self: *ProgressEmitter, event: ui.Event) ?usize {
        const id = downloadId(event);
        for (self.downloads.items, 0..) |entry, idx| {
            if (entry.id == id) return idx;
        }
        return null;
    }

    fn labelForEvent(self: *ProgressEmitter, event: ui.Event) ![]const u8 {
        if (event.subject) |subject| {
            if (subject.path) |path| {
                const base = std.fs.path.basename(path);
                return self.allocator.dupe(u8, stripTmpSuffix(base));
            }
            if (subject.url) |url| {
                return self.allocator.dupe(u8, stripTmpSuffix(basenameFromUrl(url)));
            }
        }
        return self.allocator.dupe(u8, "download");
    }

    fn renderBlockThrottled(self: *ProgressEmitter) !void {
        const now = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
        if (now - self.last_render_ms < 150) return;
        self.last_render_ms = now;
        try self.renderBlock();
    }

    fn renderBlock(self: *ProgressEmitter) !void {
        if (self.downloads.items.len == 0) {
            self.last_render_lines = 0;
            return;
        }

        if (self.last_render_lines > 0) {
            try moveCursorUp(&self.renderer.out, self.last_render_lines);
        }

        var lines_written: usize = 0;
        for (self.downloads.items, 0..) |entry, idx| {
            const child_is_last = idx + 1 == self.downloads.items.len;
            try clearLine(&self.renderer.out);
            try writeTreeBranchIndent(&self.renderer.out, &self.renderer, self.options, child_is_last);
            try self.renderer.out.writeAll("downloading ");
            try self.renderer.out.writeAll(entry.label);
            try self.renderer.out.writeAll("\n");
            lines_written += 1;

            try clearLine(&self.renderer.out);
            try self.renderBarLine(entry);
            try self.renderer.out.writeAll("\n");
            lines_written += 1;
        }
        self.last_render_lines = lines_written;
        try self.renderer.out.flush();
    }

    fn clearBlock(self: *ProgressEmitter) !void {
        if (self.last_render_lines == 0) return;
        try moveCursorUp(&self.renderer.out, self.last_render_lines);
        var i: usize = 0;
        while (i < self.last_render_lines) : (i += 1) {
            try clearLine(&self.renderer.out);
            if (i + 1 < self.last_render_lines) {
                try self.renderer.out.writeAll("\n");
            }
        }
        if (self.last_render_lines > 1) {
            try moveCursorUp(&self.renderer.out, self.last_render_lines - 1);
        }
        self.last_render_lines = 0;
        try self.renderer.out.flush();
    }

    fn renderBarLine(self: *ProgressEmitter, entry: DownloadEntry) !void {
        const total = entry.total orelse 0;
        const width: u64 = self.options.bar_width;
        var filled: u64 = 0;
        if (total > 0) {
            filled = (entry.current * width) / total;
        }
        try writeTreeContinuationIndent(&self.renderer.out, &self.renderer, self.options);
        try self.renderer.out.writeAll("[");
        var i: u64 = 0;
        while (i < width) : (i += 1) {
            if (i < filled) {
                try self.renderer.out.writeAll("#");
            } else {
                try self.renderer.out.writeAll("-");
            }
        }
        try self.renderer.out.writeAll("] ");
        try appendBytesToWriter(&self.renderer.out, entry.current);
        try self.renderer.out.writeAll(" / ");
        try appendBytesToWriter(&self.renderer.out, total);
    }

    fn printErrorLine(self: *ProgressEmitter, label: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try appendTreeBranchToLine(self.allocator, &line, &self.renderer, self.options, false);
        try line.appendSlice(self.allocator, "error downloading ");
        try line.appendSlice(self.allocator, label);
        try writeLine(&self.renderer.err, line.items);
        try self.renderer.err.flush();
    }
};

const DownloadEntry = struct {
    id: u64,
    label: []const u8,
    current: u64 = 0,
    total: ?u64 = null,
    last_percent: u8 = 0,
};

fn downloadId(event: ui.Event) u64 {
    return switch (event.kind) {
        .download_queued => event.data.download_queued.download_id,
        .download_progress => event.data.download_progress.progress_id,
        .download_complete => event.data.download_complete.download_id,
        .download_error => event.data.download_error.download_id,
        else => 0,
    };
}

fn isInlineEvent(kind: ui.EventKind) bool {
    return switch (kind) {
        .download_queued,
        .download_progress,
        .download_complete,
        .download_error,
        .install_start,
        .install_complete,
        .install_error,
        => true,
        else => false,
    };
}

fn basenameFromUrl(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        return if (idx + 1 < url.len) url[idx + 1 ..] else url;
    }
    return url;
}

fn stripTmpSuffix(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".tmp"))
        name[0 .. name.len - ".tmp".len]
    else
        name;
}

fn moveCursorUp(writer: *render_default.Writer, lines: usize) !void {
    if (lines == 0) return;
    var buf: [16]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{lines}) catch return;
    try writer.writeAll(slice);
}

fn clearLine(writer: *render_default.Writer) !void {
    try writer.writeAll("\x1b[2K\r");
}

fn writeLine(writer: *render_default.Writer, line: []const u8) !void {
    try writer.writeAll(line);
    try writer.writeAll("\n");
}

fn appendBytesToLine(allocator: std.mem.Allocator, line: *std.ArrayList(u8), bytes: u64) !void {
    var buf: [32]u8 = undefined;
    const slice = formatBytes(&buf, bytes);
    try line.appendSlice(allocator, slice);
}

fn appendIndentToLine(allocator: std.mem.Allocator, line: *std.ArrayList(u8), level: usize, indent: []const u8) !void {
    if (level == 0) return;
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try line.appendSlice(allocator, indent);
    }
}

fn writeIndent(writer: *render_default.Writer, indent: []const u8, level: usize) !void {
    if (level == 0) return;
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll(indent);
    }
}

fn appendTreeBranchToLine(
    allocator: std.mem.Allocator,
    line: *std.ArrayList(u8),
    renderer: *const render_default.Renderer,
    options: Options,
    _: bool,
) !void {
    return appendIndentToLine(allocator, line, renderer.step_depth + 1, options.indent);
}

fn writeTreeBranchIndent(writer: *render_default.Writer, renderer: *const render_default.Renderer, options: Options, _: bool) !void {
    return writeIndent(writer, options.indent, renderer.step_depth + 1);
}

fn writeTreeContinuationIndent(writer: *render_default.Writer, renderer: *const render_default.Renderer, options: Options) !void {
    return writeIndent(writer, options.indent, renderer.step_depth + 1);
}

fn appendBytesToWriter(writer: *render_default.Writer, bytes: u64) !void {
    var buf: [32]u8 = undefined;
    const slice = formatBytes(&buf, bytes);
    try writer.writeAll(slice);
}

fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value = bytes;
    var unit_index: usize = 0;
    while (value >= 1024 and unit_index + 1 < units.len) {
        value /= 1024;
        unit_index += 1;
    }

    if (unit_index == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[unit_index] }) catch "0 B";
    }

    const unit_size = @as(u64, 1) << @intCast(10 * unit_index);
    const scaled = (bytes * 10) / unit_size;
    const whole = scaled / 10;
    const frac = scaled % 10;
    if (whole >= 10) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ whole, units[unit_index] }) catch "0 B";
    }
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, frac, units[unit_index] }) catch "0 B";
}

test "progress emitter formats completion line" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var emitter = ProgressEmitter.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{
        .tty = false,
    });
    defer emitter.deinit();

    var event = ui.Event.init(1, .download_complete);
    event.subject = .{ .url = "http://example.com/file.tar.gz" };
    event.data = .{ .download_complete = .{ .download_id = 1, .bytes_total = 1024 } };

    emitter.emitter.emit(event);
    try std.testing.expect(std.mem.containsAtLeast(u8, out_buf.written(), 1, "file.tar.gz"));
}

test "tty download error clears active stdout line and writes error to stderr" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var emitter = ProgressEmitter.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{
        .tty = true,
    });
    defer emitter.deinit();

    var progress = ui.Event.init(1, .download_progress);
    progress.subject = .{ .url = "http://example.com/file.tar.gz" };
    progress.data = .{ .download_progress = .{ .progress_id = 1, .current = 10, .total = 100 } };
    emitter.emitter.emit(progress);

    var err_event = ui.Event.init(2, .download_error);
    err_event.subject = .{ .url = "http://example.com/file.tar.gz" };
    err_event.data = .{ .download_error = .{ .download_id = 1 } };
    emitter.emitter.emit(err_event);

    const out = out_buf.written();
    const err = err_buf.written();
    try std.testing.expect(std.mem.count(u8, out, "\x1b[2K\r") >= 2);
    try std.testing.expect(std.mem.containsAtLeast(u8, err, 1, "error downloading file.tar.gz"));
}

test "tty install error clears active stdout line and writes error to stderr" {
    var out_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_buf.deinit();
    var err_buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_buf.deinit();

    var emitter = ProgressEmitter.init(std.testing.allocator, &out_buf.writer, &err_buf.writer, .{
        .tty = true,
    });
    defer emitter.deinit();

    var start = ui.Event.init(1, .install_start);
    start.message = "pkg-a";
    start.data = .{ .install_start = .{ .install_id = 7 } };
    emitter.emitter.emit(start);

    var err_event = ui.Event.init(2, .install_error);
    err_event.message = "pkg-a";
    err_event.data = .{ .install_error = .{ .install_id = 7 } };
    emitter.emitter.emit(err_event);

    const out = out_buf.written();
    const err = err_buf.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[2K\r"));
    try std.testing.expect(std.mem.containsAtLeast(u8, err, 1, "error installing pkg-a"));
}
