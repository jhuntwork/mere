const std = @import("std");
const errors = @import("errors.zig");

const c = @cImport({
    @cInclude("zstd.h");
});

/// Zstd compression operations error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during compression operations
/// - FileSystem: I/O operations failed (reading/writing compressed data)
/// - Internal: Zstd stream initialization or compression operation failed (was InitFailed, CompressFailed)
/// - CorruptData: Zstd decompression operation failed (was DecompressFailed)
const Std = errors.StandardErrors;
pub const ZstdError = Std.OutOfMemory || Std.FileSystem || Std.Internal || Std.CorruptData;

pub const ZstdReader = struct {
    reader: std.io.Reader,
    src: *std.io.Reader,
    allocator: std.mem.Allocator,
    zds: ?*c.ZSTD_DStream = null,
    in_buf: []u8 = undefined,
    in_pos: usize = 0,
    in_size: usize = 0,
    frame_complete: bool = false,
    vtable_storage: std.io.Reader.VTable = undefined,

    pub fn init(allocator: std.mem.Allocator, src: *std.io.Reader) !*ZstdReader {
        var zr = try allocator.create(ZstdReader);
        zr.allocator = allocator;
        zr.src = src;

        const in_size_c = c.ZSTD_DStreamInSize();
        const in_size = @as(usize, in_size_c);

        zr.in_buf = try allocator.alloc(u8, in_size);
        zr.in_pos = 0;
        zr.in_size = 0;
        zr.frame_complete = false;

        zr.zds = c.ZSTD_createDStream();
        if (zr.zds == null) {
            allocator.free(zr.in_buf);
            allocator.destroy(zr);
            return ZstdError.Internal;
        }
        const init_res = c.ZSTD_initDStream(zr.zds.?);
        if (c.ZSTD_isError(init_res) != 0) {
            _ = c.ZSTD_freeDStream(zr.zds.?);
            allocator.free(zr.in_buf);
            allocator.destroy(zr);
            return ZstdError.Internal;
        }

        zr.vtable_storage = .{
            .stream = ZstdReader.stream,
            .discard = std.io.Reader.defaultDiscard,
            .readVec = std.io.Reader.defaultReadVec,
            .rebase = std.io.Reader.defaultRebase,
        };
        zr.reader = std.io.Reader{ .vtable = &zr.vtable_storage, .buffer = &[_]u8{}, .seek = 0, .end = 0 };

        return zr;
    }

    pub fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
        const self: *ZstdReader = @alignCast(@fieldParentPtr("reader", r));
        var total: usize = 0;
        var remaining: usize = 0;
        var unlimited: bool = true;
        if (limit.toInt()) |n| {
            remaining = n;
            unlimited = false;
        }
        var tmp: [8192]u8 = undefined;
        while (unlimited or (remaining != 0)) {
            const to_read = if (unlimited) tmp.len else if (remaining < tmp.len) remaining else tmp.len;
            const n = self.read(tmp[0..to_read]) catch |err| switch (err) {
                ZstdError.FileSystem, ZstdError.CorruptData => return std.io.Reader.StreamError.ReadFailed,
                else => return std.io.Reader.StreamError.ReadFailed,
            };
            if (n == 0) {
                if (total == 0) return std.io.Reader.StreamError.EndOfStream;
                return total;
            }
            var written_total: usize = 0;
            while (written_total < n) {
                const wn = w.write(tmp[written_total..n]) catch return std.io.Reader.StreamError.WriteFailed;
                written_total += wn;
            }
            total += n;
            if (!unlimited) {
                if (n >= remaining) {
                    remaining = 0;
                } else {
                    remaining -= n;
                }
                if (remaining == 0) break;
            }
        }
        return total;
    }

    pub fn deinit(self: *ZstdReader) void {
        if (self.zds) |z| {
            _ = c.ZSTD_freeDStream(z);
            self.zds = null;
        }
        if (self.in_buf.len != 0) {
            self.allocator.free(self.in_buf);
            self.in_buf = &[_]u8{};
        }
        self.allocator.destroy(self);
    }

    pub fn read(self: *ZstdReader, out: []u8) !usize {
        // Loop until we produce some output or reach EOF / error
        while (true) {
            // If we need input, fill the input buffer
            if (self.in_pos == self.in_size) {
                const n = std.io.Reader.readSliceShort(self.src, self.in_buf) catch {
                    return ZstdError.FileSystem;
                };
                if (n == 0) {
                    if (self.frame_complete) {
                        // EOF from underlying file after a completed frame
                        return 0;
                    }
                    // EOF before the frame completed means truncated/corrupt compressed input.
                    if (self.in_size != 0) {
                        return ZstdError.CorruptData;
                    }
                    // Empty compressed stream: treat as EOF.
                    return 0;
                }
                self.in_pos = 0;
                self.in_size = n;
            }

            var in_buf_c = c.ZSTD_inBuffer{
                .src = self.in_buf.ptr,
                .size = @as(usize, self.in_size),
                .pos = @as(usize, self.in_pos),
            };
            var out_buf_c = c.ZSTD_outBuffer{
                .dst = out.ptr,
                .size = @as(usize, out.len),
                .pos = 0,
            };

            const rc = c.ZSTD_decompressStream(self.zds.?, &out_buf_c, &in_buf_c);
            if (c.ZSTD_isError(rc) != 0) {
                return ZstdError.CorruptData;
            }

            // Update our input position
            self.in_pos = @as(usize, in_buf_c.pos);
            self.frame_complete = rc == 0;

            // If decompressor produced output, return it
            if (out_buf_c.pos != 0) {
                return @as(usize, out_buf_c.pos);
            }

            // No output produced: loop to read more input (if any) and try again
        }
    }
};

pub const StreamCompressor = struct {
    allocator: std.mem.Allocator,
    out_w: *std.io.Writer,
    zcs: *c.ZSTD_CStream,
    out_buf: []u8,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, out_w: *std.io.Writer) !StreamCompressor {
        const zcs = c.ZSTD_createCStream() orelse return ZstdError.Internal;
        errdefer _ = c.ZSTD_freeCStream(zcs);

        const init_res = c.ZSTD_initCStream(zcs, 3);
        if (c.ZSTD_isError(init_res) != 0) {
            return ZstdError.Internal;
        }

        const out_size = @as(usize, c.ZSTD_CStreamOutSize());
        const out_buf = try allocator.alloc(u8, out_size);
        errdefer allocator.free(out_buf);

        return .{
            .allocator = allocator,
            .out_w = out_w,
            .zcs = zcs,
            .out_buf = out_buf,
        };
    }

    pub fn deinit(self: *StreamCompressor) void {
        self.allocator.free(self.out_buf);
        _ = c.ZSTD_freeCStream(self.zcs);
    }

    pub fn write(self: *StreamCompressor, input: []const u8) !void {
        var in_buf_c = c.ZSTD_inBuffer{
            .src = input.ptr,
            .size = input.len,
            .pos = 0,
        };

        while (in_buf_c.pos < in_buf_c.size) {
            var out_buf_c = c.ZSTD_outBuffer{
                .dst = self.out_buf.ptr,
                .size = self.out_buf.len,
                .pos = 0,
            };

            const rc = c.ZSTD_compressStream(self.zcs, &out_buf_c, &in_buf_c);
            if (c.ZSTD_isError(rc) != 0) {
                return ZstdError.Internal;
            }

            if (out_buf_c.pos != 0) {
                self.out_w.writeAll(self.out_buf[0..out_buf_c.pos]) catch |err| {
                    return mapWriterError(err);
                };
            }
        }
    }

    pub fn finish(self: *StreamCompressor) !void {
        if (self.finished) return;

        while (true) {
            var out_buf_c = c.ZSTD_outBuffer{
                .dst = self.out_buf.ptr,
                .size = self.out_buf.len,
                .pos = 0,
            };

            const rc = c.ZSTD_endStream(self.zcs, &out_buf_c);
            if (c.ZSTD_isError(rc) != 0) {
                return ZstdError.Internal;
            }

            if (out_buf_c.pos != 0) {
                self.out_w.writeAll(self.out_buf[0..out_buf_c.pos]) catch |err| {
                    return mapWriterError(err);
                };
            }

            if (rc == 0) break;
        }

        self.finished = true;
    }
};

fn mapWriterError(err: anyerror) ZstdError {
    return switch (err) {
        error.OutOfMemory => ZstdError.OutOfMemory,
        else => ZstdError.FileSystem,
    };
}

pub fn compressOneShot(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const bound = @as(usize, c.ZSTD_compressBound(@as(usize, input.len)));
    const dst = try allocator.alloc(u8, bound);
    const res = @as(usize, c.ZSTD_compress(dst.ptr, @as(usize, dst.len), input.ptr, @as(usize, input.len), 3));
    if (c.ZSTD_isError(res) != 0) {
        allocator.free(dst);
        return ZstdError.Internal;
    }
    // Resize the allocation to the actual compressed size so callers can free safely.
    const final_buf = try allocator.realloc(dst, res);
    return final_buf;
}

pub fn compressStream(allocator: std.mem.Allocator, reader: *std.io.Reader) ![]u8 {
    var buf_writer: std.Io.Writer.Allocating = .init(allocator);
    defer buf_writer.deinit();

    try compressStreamToWriterInternal(allocator, reader, &buf_writer.writer);
    return try allocator.dupe(u8, buf_writer.written());
}

fn compressStreamToWriterInternal(
    allocator: std.mem.Allocator,
    reader: *std.io.Reader,
    out_w: *std.io.Writer,
) !void {
    const zs = c.ZSTD_createCStream();
    if (zs == null) return ZstdError.Internal;
    errdefer _ = c.ZSTD_freeCStream(zs);
    const init_res = c.ZSTD_initCStream(zs, 3);
    if (c.ZSTD_isError(init_res) != 0) {
        return ZstdError.Internal;
    }

    const in_size = @as(usize, c.ZSTD_CStreamInSize());
    const out_size = @as(usize, c.ZSTD_CStreamOutSize());
    const in_buf = try allocator.alloc(u8, in_size);
    const out_buf = try allocator.alloc(u8, out_size);
    defer allocator.free(in_buf);
    defer allocator.free(out_buf);

    var in_buf_c = c.ZSTD_inBuffer{
        .src = in_buf.ptr,
        .size = 0,
        .pos = 0,
    };
    var out_buf_c = c.ZSTD_outBuffer{
        .dst = out_buf.ptr,
        .size = out_size,
        .pos = 0,
    };

    while (true) {
        const n = std.io.Reader.readSliceShort(reader, in_buf) catch {
            return ZstdError.FileSystem;
        };
        if (n == 0) break;
        in_buf_c.src = in_buf.ptr;
        in_buf_c.size = @as(usize, n);
        in_buf_c.pos = 0;
        while (in_buf_c.pos < in_buf_c.size) {
            out_buf_c.pos = 0;
            const rc = c.ZSTD_compressStream(zs, &out_buf_c, &in_buf_c);
            if (c.ZSTD_isError(rc) != 0) {
                return ZstdError.Internal;
            }
            if (out_buf_c.pos != 0) try out_w.writeAll(out_buf[0..out_buf_c.pos]);
        }
    }

    // Finish stream
    while (true) {
        out_buf_c.pos = 0;
        const rc = c.ZSTD_endStream(zs, &out_buf_c);
        if (c.ZSTD_isError(rc) != 0) {
            return ZstdError.Internal;
        }
        if (out_buf_c.pos != 0) try out_w.writeAll(out_buf[0..out_buf_c.pos]);
        if (rc == 0) break;
    }
    _ = c.ZSTD_freeCStream(zs);
    return;
}

pub fn compressStreamToWriter(allocator: std.mem.Allocator, reader: *std.io.Reader, out_w: *std.io.Writer) !void {
    return compressStreamToWriterInternal(allocator, reader, out_w);
}

test "zstd: roundtrip decompress with ZstdReader" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const original: []const u8 = "the quick brown fox jumps over the lazy dog";

    const compressed = try compressOneShot(allocator, original);
    defer allocator.free(compressed);

    var fixed = std.Io.Reader.fixed(compressed);
    var zst = try ZstdReader.init(allocator, &fixed);
    defer zst.deinit();

    var out_buf: [256]u8 = undefined;
    const got = try zst.read(out_buf[0..]);
    try std.testing.expect(std.mem.startsWith(u8, out_buf[0..got], original));
}

test "zstd: deinit frees native resources (smoke)" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    var buf: [4096]u8 = undefined;
    var fixed = std.Io.Reader.fixed(&buf);
    var zst = try ZstdReader.init(allocator, &fixed);
    // Just call deinit to exercise free paths; no assertion beyond no-panic.
    zst.deinit();
}

test "zstd: compressStream basic functionality" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    // Use a larger, repetitive string that will compress well
    const original: []const u8 = "Hello, world! " ** 20 ++ "This is a test string for streaming compression that should compress nicely due to repetition.";

    // Create a reader from the original data
    var fixed_reader = std.io.Reader.fixed(original);

    // Compress using streaming compression
    const compressed = try compressStream(allocator, &fixed_reader);
    defer allocator.free(compressed);

    // Verify we got some compressed data
    try std.testing.expect(compressed.len > 0);
    try std.testing.expect(compressed.len < original.len); // Should compress due to repetition

    // Round-trip: decompress with ZstdReader
    var compressed_reader = std.io.Reader.fixed(compressed);
    var zst = try ZstdReader.init(allocator, &compressed_reader);
    defer zst.deinit();

    var out_buf: [1024]u8 = undefined;
    const decompressed_len = try zst.read(out_buf[0..]);

    // Verify round-trip accuracy
    try std.testing.expectEqual(original.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, original, out_buf[0..decompressed_len]);
}

test "zstd: compressStream error handling" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;

    // Test Io error from reader
    const FailingReader = struct {
        reader: std.io.Reader,
        vtable: std.io.Reader.VTable,

        const Self = @This();

        fn init() Self {
            var self = Self{
                .reader = undefined,
                .vtable = undefined,
            };
            self.vtable = .{
                .stream = stream,
                .discard = std.io.Reader.defaultDiscard,
                .readVec = std.io.Reader.defaultReadVec,
                .rebase = std.io.Reader.defaultRebase,
            };
            self.reader = std.io.Reader{ .vtable = &self.vtable, .buffer = &[_]u8{}, .seek = 0, .end = 0 };
            return self;
        }

        fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            _ = r;
            _ = w;
            _ = limit;
            return std.io.Reader.StreamError.ReadFailed;
        }
    };

    var failing_reader = FailingReader.init();
    const result = compressStream(allocator, &failing_reader.reader);
    try std.testing.expectError(ZstdError.FileSystem, result);
}

test "zstd: ZstdReader.stream method" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const original: []const u8 = "Stream test data! " ** 10; // Make it larger for streaming

    // Compress the data first
    const compressed = try compressOneShot(allocator, original);
    defer allocator.free(compressed);

    // Test unlimited streaming using a fixed buffer writer
    {
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var output_buf: [1024]u8 = undefined;
        var fixed_writer = std.io.Writer.fixed(&output_buf);

        const bytes_streamed = try zst.reader.stream(&fixed_writer, std.io.Limit.unlimited);
        try std.testing.expectEqual(original.len, bytes_streamed);
        try std.testing.expectEqualSlices(u8, original, output_buf[0..bytes_streamed]);
    }

    // Test limited streaming
    {
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var output_buf: [1024]u8 = undefined;
        var fixed_writer = std.io.Writer.fixed(&output_buf);

        const limit = 50; // Less than full original length
        const bytes_streamed = try zst.reader.stream(&fixed_writer, std.io.Limit.limited(limit));
        try std.testing.expectEqual(limit, bytes_streamed);
        try std.testing.expectEqualSlices(u8, original[0..limit], output_buf[0..bytes_streamed]);
    }
}

test "zstd: ZstdReader initialization error paths" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    // Test with a failing allocator to simulate memory allocation failures
    const FailingAllocator = struct {
        allocator: std.mem.Allocator,
        vtable: std.mem.Allocator.VTable,

        const Self = @This();

        fn init() Self {
            var self = Self{
                .allocator = undefined,
                .vtable = undefined,
            };
            self.vtable = .{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            };
            self.allocator = std.mem.Allocator{ .ptr = undefined, .vtable = &self.vtable };
            return self;
        }

        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null; // Always fail allocation
        }

        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }

        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }

        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    };

    const failing_allocator = FailingAllocator.init();
    var empty_data: [0]u8 = undefined;
    var fixed_reader = std.io.Reader.fixed(&empty_data);

    // Test memory allocation failure during ZstdReader creation
    const result = ZstdReader.init(failing_allocator.allocator, &fixed_reader);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "zstd: ZstdReader read error handling" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;

    // Test Io error from underlying reader
    const FailingReader = struct {
        reader: std.io.Reader,
        vtable: std.io.Reader.VTable,

        const Self = @This();

        fn init() Self {
            var self = Self{
                .reader = undefined,
                .vtable = undefined,
            };
            self.vtable = .{
                .stream = stream,
                .discard = std.io.Reader.defaultDiscard,
                .readVec = std.io.Reader.defaultReadVec,
                .rebase = std.io.Reader.defaultRebase,
            };
            self.reader = std.io.Reader{ .vtable = &self.vtable, .buffer = &[_]u8{}, .seek = 0, .end = 0 };
            return self;
        }

        fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            _ = r;
            _ = w;
            _ = limit;
            return std.io.Reader.StreamError.ReadFailed;
        }
    };

    var failing_reader = FailingReader.init();
    var zst = try ZstdReader.init(allocator, &failing_reader.reader);
    defer zst.deinit();

    var buf: [256]u8 = undefined;
    const result = zst.read(buf[0..]);
    try std.testing.expectError(ZstdError.FileSystem, result);

    // Test DecompressFailed with invalid compressed data
    const invalid_data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }; // Invalid zstd data
    var invalid_reader = std.io.Reader.fixed(&invalid_data);
    var zst2 = try ZstdReader.init(allocator, &invalid_reader);
    defer zst2.deinit();

    const result2 = zst2.read(buf[0..]);
    try std.testing.expectError(ZstdError.CorruptData, result2);

    const truncated = try compressOneShot(allocator, "truncated stream payload");
    defer allocator.free(truncated);
    try std.testing.expect(truncated.len > 1);
    var truncated_reader = std.io.Reader.fixed(truncated[0 .. truncated.len - 1]);
    var zst3 = try ZstdReader.init(allocator, &truncated_reader);
    defer zst3.deinit();

    while (true) {
        const step = zst3.read(buf[0..]) catch |err| {
            try std.testing.expectEqual(ZstdError.CorruptData, err);
            break;
        };
        if (step == 0) {
            return error.TestUnexpectedResult;
        }
    }
}

test "zstd: ZstdReader read edge cases" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const original: []const u8 = "This is test data for edge case testing with multiple reads.";

    // Compress the data first
    const compressed = try compressOneShot(allocator, original);
    defer allocator.free(compressed);

    // Test very small output buffer requiring multiple reads
    {
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var result_buf = std.array_list.Managed(u8).init(allocator);
        defer result_buf.deinit();

        // Read in very small chunks
        var small_buf: [5]u8 = undefined;
        while (true) {
            const bytes_read = try zst.read(small_buf[0..]);
            if (bytes_read == 0) break;
            try result_buf.appendSlice(small_buf[0..bytes_read]);
        }

        try std.testing.expectEqualSlices(u8, original, result_buf.items);
    }

    // Test EOF handling with empty compressed stream
    {
        const empty_compressed = try compressOneShot(allocator, "");
        defer allocator.free(empty_compressed);

        var empty_reader = std.io.Reader.fixed(empty_compressed);
        var zst = try ZstdReader.init(allocator, &empty_reader);
        defer zst.deinit();

        var buf: [10]u8 = undefined;
        const bytes_read = try zst.read(buf[0..]);
        try std.testing.expectEqual(@as(usize, 0), bytes_read);
    }

    // Test multiple read calls on the same reader
    {
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var buf1: [20]u8 = undefined;
        var buf2: [50]u8 = undefined;

        const bytes1 = try zst.read(buf1[0..]);
        const bytes2 = try zst.read(buf2[0..]);

        // Should get all data in first or second read
        const total_bytes = bytes1 + bytes2;
        try std.testing.expectEqual(original.len, total_bytes);

        // Reconstruct and verify
        var full_result: [100]u8 = undefined;
        @memcpy(full_result[0..bytes1], buf1[0..bytes1]);
        @memcpy(full_result[bytes1..total_bytes], buf2[0..bytes2]);
        try std.testing.expectEqualSlices(u8, original, full_result[0..total_bytes]);
    }
}

test "zstd: compressOneShot error handling" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    // Test with failing allocator to simulate memory allocation failures
    const FailingAllocator = struct {
        allocator: std.mem.Allocator,
        vtable: std.mem.Allocator.VTable,

        const Self = @This();

        fn init() Self {
            var self = Self{
                .allocator = undefined,
                .vtable = undefined,
            };
            self.vtable = .{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            };
            self.allocator = std.mem.Allocator{ .ptr = undefined, .vtable = &self.vtable };
            return self;
        }

        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null; // Always fail allocation
        }

        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }

        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }

        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    };

    const failing_allocator = FailingAllocator.init();
    const test_data: []const u8 = "Test data for compression failure testing";

    // Test memory allocation failure during compression
    const result = compressOneShot(failing_allocator.allocator, test_data);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "zstd: round-trip with compressStream" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const original: []const u8 = "Round-trip test data for compressStream functionality! " ** 5;

    // Create a reader from the original data
    var input_reader = std.io.Reader.fixed(original);

    // Compress using streaming compression
    const compressed = try compressStream(allocator, &input_reader);
    defer allocator.free(compressed);

    // Verify compression occurred
    try std.testing.expect(compressed.len > 0);
    try std.testing.expect(compressed.len < original.len); // Should compress due to repetition

    // Round-trip: decompress with ZstdReader
    var compressed_reader = std.io.Reader.fixed(compressed);
    var zst = try ZstdReader.init(allocator, &compressed_reader);
    defer zst.deinit();

    // Read back the decompressed data
    var decompressed_buf: [1024]u8 = undefined;
    const decompressed_len = try zst.read(decompressed_buf[0..]);

    // Verify round-trip accuracy
    try std.testing.expectEqual(original.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, original, decompressed_buf[0..decompressed_len]);

    // Verify no more data to read (EOF)
    var extra_buf: [10]u8 = undefined;
    const extra_len = try zst.read(extra_buf[0..]);
    try std.testing.expectEqual(@as(usize, 0), extra_len);
}

test "zstd: large data round-trip" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;

    // Create large test data (8KB with patterns)
    const pattern: []const u8 = "Large data test pattern for compression! 0123456789ABCDEF";
    const repetitions = 150; // 8KB+ of data
    const large_data = try allocator.alloc(u8, pattern.len * repetitions);
    defer allocator.free(large_data);

    // Fill with repeated pattern
    for (0..repetitions) |i| {
        const start = i * pattern.len;
        const end = start + pattern.len;
        @memcpy(large_data[start..end], pattern);
    }

    // Compress the large data
    const compressed = try compressOneShot(allocator, large_data);
    defer allocator.free(compressed);

    // Verify significant compression due to repetition
    try std.testing.expect(compressed.len > 0);
    try std.testing.expect(compressed.len < large_data.len / 4); // Should compress well

    // Round-trip: decompress with ZstdReader using multiple reads
    var compressed_reader = std.io.Reader.fixed(compressed);
    var zst = try ZstdReader.init(allocator, &compressed_reader);
    defer zst.deinit();

    var result_buf = std.array_list.Managed(u8).init(allocator);
    defer result_buf.deinit();

    // Read in moderate chunks to test multiple read operations
    var chunk_buf: [1024]u8 = undefined;
    while (true) {
        const bytes_read = try zst.read(chunk_buf[0..]);
        if (bytes_read == 0) break;
        try result_buf.appendSlice(chunk_buf[0..bytes_read]);
    }

    // Verify round-trip accuracy
    try std.testing.expectEqual(large_data.len, result_buf.items.len);
    try std.testing.expectEqualSlices(u8, large_data, result_buf.items);
}

test "zstd: empty input handling" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const empty_data: []const u8 = "";

    // Test compressOneShot with empty data
    {
        const compressed = try compressOneShot(allocator, empty_data);
        defer allocator.free(compressed);

        // Empty data should still produce some compressed output (zstd header)
        try std.testing.expect(compressed.len > 0);

        // Round-trip: decompress with ZstdReader
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var buf: [10]u8 = undefined;
        const decompressed_len = try zst.read(buf[0..]);

        // Should get 0 bytes back (empty)
        try std.testing.expectEqual(@as(usize, 0), decompressed_len);
    }

    // Test compressStream with empty data
    {
        var empty_reader = std.io.Reader.fixed(empty_data);
        const compressed = try compressStream(allocator, &empty_reader);
        defer allocator.free(compressed);

        // Empty data should still produce some compressed output (zstd header)
        try std.testing.expect(compressed.len > 0);

        // Round-trip: decompress with ZstdReader
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var buf: [10]u8 = undefined;
        const decompressed_len = try zst.read(buf[0..]);

        // Should get 0 bytes back (empty)
        try std.testing.expectEqual(@as(usize, 0), decompressed_len);

        // Subsequent reads should also return 0 (EOF)
        const second_read = try zst.read(buf[0..]);
        try std.testing.expectEqual(@as(usize, 0), second_read);
    }

    // Test ZstdReader with empty compressed stream (edge case)
    {
        // This tests what happens if we somehow get an empty buffer as compressed data
        // We expect initialization or the first read to reject the stream (or return no bytes)
        var truly_empty: [0]u8 = undefined;
        var empty_reader = std.io.Reader.fixed(&truly_empty);

        // This might fail at init or at first read, depending on implementation
        var zst = ZstdReader.init(allocator, &empty_reader);
        if (zst) |*reader| {
            defer reader.*.deinit();
            var buf: [10]u8 = undefined;
            const result = reader.*.read(buf[0..]);
            // Should either get 0 bytes or an error
            if (result) |len| {
                try std.testing.expectEqual(@as(usize, 0), len);
            } else |_| {
                // Error is also acceptable for truly empty data
            }
        } else |_| {
            // Init failure is acceptable for truly empty data
        }
    }
}

test "zstd: binary data round-trip" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;

    // Create binary data with all possible byte values
    var binary_data: [512]u8 = undefined;
    for (0..binary_data.len) |i| {
        binary_data[i] = @as(u8, @truncate(i));
    }

    // Test compressOneShot with binary data
    {
        const compressed = try compressOneShot(allocator, &binary_data);
        defer allocator.free(compressed);

        // Should produce compressed output
        try std.testing.expect(compressed.len > 0);

        // Round-trip: decompress with ZstdReader
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var decompressed_buf: [1024]u8 = undefined;
        const decompressed_len = try zst.read(decompressed_buf[0..]);

        // Verify exact binary match
        try std.testing.expectEqual(binary_data.len, decompressed_len);
        try std.testing.expectEqualSlices(u8, &binary_data, decompressed_buf[0..decompressed_len]);
    }

    // Test with random-like binary data (less compressible)
    {
        var random_data: [256]u8 = undefined;
        // Create pseudo-random data using a simple pattern
        var seed: u8 = 0x5A;
        for (0..random_data.len) |i| {
            seed = seed *% 137 +% 113; // Simple PRNG
            random_data[i] = seed;
        }

        const compressed = try compressOneShot(allocator, &random_data);
        defer allocator.free(compressed);

        // Should produce compressed output (may not be smaller due to randomness)
        try std.testing.expect(compressed.len > 0);

        // Round-trip: decompress with ZstdReader
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var decompressed_buf: [512]u8 = undefined;
        const decompressed_len = try zst.read(decompressed_buf[0..]);

        // Verify exact binary match
        try std.testing.expectEqual(random_data.len, decompressed_len);
        try std.testing.expectEqualSlices(u8, &random_data, decompressed_buf[0..decompressed_len]);
    }

    // Test with binary data containing null bytes and high values
    {
        const null_heavy_data = [_]u8{ 0x00, 0xFF, 0x00, 0x80, 0x7F, 0x00, 0xFF, 0x00, 0x01, 0xFE } ** 20;

        const compressed = try compressOneShot(allocator, &null_heavy_data);
        defer allocator.free(compressed);

        // Should compress well due to repetition
        try std.testing.expect(compressed.len > 0);
        try std.testing.expect(compressed.len < null_heavy_data.len);

        // Round-trip: decompress with ZstdReader
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var decompressed_buf: [512]u8 = undefined;
        const decompressed_len = try zst.read(decompressed_buf[0..]);

        // Verify exact binary match
        try std.testing.expectEqual(null_heavy_data.len, decompressed_len);
        try std.testing.expectEqualSlices(u8, &null_heavy_data, decompressed_buf[0..decompressed_len]);
    }
}

test "zstd: boundary condition reads" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const original_data = "Boundary test: " ** 30; // ~450 bytes

    const compressed = try compressOneShot(allocator, original_data);
    defer allocator.free(compressed);

    // Test reading with prime-number sized buffers (likely to hit boundaries)
    const buffer_sizes = [_]usize{ 7, 13, 23, 37, 67 };

    for (buffer_sizes) |buf_size| {
        var compressed_reader = std.io.Reader.fixed(compressed);
        var zst = try ZstdReader.init(allocator, &compressed_reader);
        defer zst.deinit();

        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();

        var read_buf = try allocator.alloc(u8, buf_size);
        defer allocator.free(read_buf);

        while (true) {
            const bytes_read = try zst.read(read_buf);
            if (bytes_read == 0) break;
            try result.appendSlice(read_buf[0..bytes_read]);
        }

        try std.testing.expectEqualSlices(u8, original_data, result.items);
    }
}

test "zstd: compressStreamToWriter basic functionality" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;
    const original: []const u8 = "Streaming test data for compressStreamToWriter " ** 10;

    // Create reader
    var reader = std.io.Reader.fixed(original);

    // Create an allocating writer to capture output
    var buf_writer: std.Io.Writer.Allocating = .init(allocator);
    defer buf_writer.deinit();

    try compressStreamToWriter(allocator, &reader, &buf_writer.writer);

    const compressed = try allocator.dupe(u8, buf_writer.written());
    defer allocator.free(compressed);

    // Decompress and verify
    var compressed_reader = std.io.Reader.fixed(compressed);
    var zst = try ZstdReader.init(allocator, &compressed_reader);
    defer zst.deinit();

    var out_buf: [1024]u8 = undefined;
    const decompressed_len = try zst.read(out_buf[0..]);
    try std.testing.expectEqual(original.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, original, out_buf[0..decompressed_len]);
}

test "zstd: compressStreamToWriter io error from reader" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }

    const allocator = env.ctx.allocator;

    const FailingReader = struct {
        reader: std.io.Reader,
        vtable: std.io.Reader.VTable,

        const Self = @This();

        fn init() Self {
            var self = Self{
                .reader = undefined,
                .vtable = undefined,
            };
            self.vtable = .{
                .stream = stream,
                .discard = std.io.Reader.defaultDiscard,
                .readVec = std.io.Reader.defaultReadVec,
                .rebase = std.io.Reader.defaultRebase,
            };
            self.reader = std.io.Reader{ .vtable = &self.vtable, .buffer = &[_]u8{}, .seek = 0, .end = 0 };
            return self;
        }

        fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            _ = r;
            _ = w;
            _ = limit;
            return std.io.Reader.StreamError.ReadFailed;
        }
    };

    var failing = FailingReader.init();

    var buf_writer: std.Io.Writer.Allocating = .init(allocator);
    defer buf_writer.deinit();

    const res = compressStreamToWriter(allocator, &failing.reader, &buf_writer.writer);
    try std.testing.expectError(ZstdError.FileSystem, res);
}
