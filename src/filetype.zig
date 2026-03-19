const std = @import("std");
const p = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const FileTypeError = Std.FileSystem || Std.Internal;

pub const Kind = enum {
    elf,
    zst,
    tar,
};

const Signature = struct {
    kind: Kind,
    magic: []const u8,
};

const known = [_]Signature{
    .{ .kind = .elf, .magic = "\x7FELF" },
    .{ .kind = .tar, .magic = "ustar" }, // POSIX tar format
    .{ .kind = .zst, .magic = "\x28\xB5\x2F\xFD" },
};

pub fn detect(file: *const std.Io.File) FileTypeError!Kind {
    const io = p.currentIo();
    var buffer: [512]u8 = undefined;
    const read_bytes = file.readPositionalAll(io, &buffer, 0) catch {
        return error.FileSystem;
    };

    if (read_bytes >= 262 and std.mem.eql(u8, buffer[257..262], "ustar")) {
        return .tar;
    }

    var header_buffer: [8]u8 = undefined;
    const header_bytes = file.readPositionalAll(io, &header_buffer, 0) catch {
        return error.FileSystem;
    };

    for (known) |sig| {
        if (header_bytes >= sig.magic.len and std.mem.eql(u8, header_buffer[0..sig.magic.len], sig.magic)) {
            return sig.kind;
        }
    }

    return FileTypeError.Internal;
}

test "detect ELF" {
    const elf_file = try std.Io.Dir.cwd().openFile(p.currentIo(), "test/testdata/libtest.so", .{});
    defer elf_file.close(p.currentIo());

    const kind = try detect(&elf_file);
    try std.testing.expectEqual(Kind.elf, kind);
}

test "detect tar" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const tar_file = "test.tar";
    const abs_target = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
    defer std.testing.allocator.free(abs_target);

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };
    try tar_writer.writeFileBytes("some/random/file", "test content", .{});

    const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
    defer std.testing.allocator.free(tar_contents);
    const out = try std.Io.Dir.createFileAbsolute(p.currentIo(), abs_target, .{});
    defer out.close(p.currentIo());
    try out.writeStreamingAll(p.currentIo(), tar_contents);

    const created_tar = try std.Io.Dir.openFileAbsolute(p.currentIo(), abs_target, .{});
    defer created_tar.close(p.currentIo());
    const kind = try detect(&created_tar);
    try std.testing.expectEqual(Kind.tar, kind);
}

test "detect zst" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const test_file_name = "test.txt";
    const test_file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, test_file_name });
    defer std.testing.allocator.free(test_file_path);

    {
        const test_file = try std.Io.Dir.createFileAbsolute(p.currentIo(), test_file_path, .{});
        defer test_file.close(p.currentIo());
        try test_file.writeStreamingAll(p.currentIo(), "test content");
    }

    const compressed_name = "test.txt.zst";
    const compressed_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, compressed_name });
    defer std.testing.allocator.free(compressed_path);

    const uncompressed = try std.Io.Dir.cwd().readFileAlloc(p.currentIo(), test_file_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(uncompressed);
    const compressed_buf = @import("zstd_c.zig").compressOneShot(std.testing.allocator, uncompressed) catch |err| {
        test_env.ctx.debug("zstd compression failed: {s}", .{@errorName(err)});
        return FileTypeError.FileSystem;
    };
    defer std.testing.allocator.free(compressed_buf);
    const out_file = try p.makePathAndOpenFile(compressed_path);
    defer out_file.close(p.currentIo());
    try out_file.writeStreamingAll(p.currentIo(), compressed_buf);

    const compressed_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), compressed_path, .{});
    defer compressed_file.close(p.currentIo());

    const kind = try detect(&compressed_file);
    try std.testing.expectEqual(Kind.zst, kind);
}
