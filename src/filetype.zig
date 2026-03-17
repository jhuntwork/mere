const std = @import("std");
const p = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const FileTypeError = Std.FileSystem || Std.Internal;

pub const Kind = enum {
    elf,
    xz,
    zst,
    tar,
    shell_script,
    bash_script,
    python_script,
    gzip,
    zip,
    text,
};

const Signature = struct {
    kind: Kind,
    magic: []const u8,
};

const known = [_]Signature{
    .{ .kind = .elf, .magic = "\x7FELF" },
    .{ .kind = .tar, .magic = "ustar" }, // POSIX tar format
    .{ .kind = .xz, .magic = "\xFD\x37\x7A\x58\x5A\x00" },
    .{ .kind = .zst, .magic = "\x28\xB5\x2F\xFD" },
    .{ .kind = .gzip, .magic = "\x1F\x8B" },
    .{ .kind = .zip, .magic = "PK\x03\x04" },
};

pub fn detect(file: *const std.fs.File) FileTypeError!Kind {
    const original_pos = file.getPos() catch {
        return error.FileSystem;
    };
    defer {
        file.seekTo(original_pos) catch {};
    }

    file.seekTo(0) catch {
        return error.FileSystem;
    };
    var buffer: [512]u8 = undefined;
    const read_bytes = file.readAll(&buffer) catch {
        return error.FileSystem;
    };

    if (read_bytes >= 262 and std.mem.eql(u8, buffer[257..262], "ustar")) {
        return .tar;
    }

    if (read_bytes >= 2 and buffer[0] == '#' and buffer[1] == '!') {
        const line_end = std.mem.indexOf(u8, buffer[0..read_bytes], "\n") orelse read_bytes;
        const shebang_line = buffer[0..line_end];

        if (std.mem.indexOf(u8, shebang_line, "/sh") != null or
            std.mem.indexOf(u8, shebang_line, "/env sh") != null)
        {
            return .shell_script;
        } else if (std.mem.indexOf(u8, shebang_line, "/bash") != null or
            std.mem.indexOf(u8, shebang_line, "/env bash") != null)
        {
            return .bash_script;
        } else if (std.mem.indexOf(u8, shebang_line, "/python") != null or
            std.mem.indexOf(u8, shebang_line, "/env python") != null)
        {
            return .python_script;
        }

        return .shell_script;
    }

    file.seekTo(0) catch {
        return error.FileSystem;
    };
    var header_buffer: [8]u8 = undefined;
    const header_bytes = file.readAll(&header_buffer) catch {
        return error.FileSystem;
    };

    for (known) |sig| {
        if (header_bytes >= sig.magic.len and std.mem.eql(u8, header_buffer[0..sig.magic.len], sig.magic)) {
            return sig.kind;
        }
    }

    var is_text = true;
    const check_bytes = @min(read_bytes, 64);
    for (buffer[0..check_bytes]) |byte| {
        if (!((byte >= 32 and byte <= 126) or (byte >= 9 and byte <= 13))) {
            is_text = false;
            break;
        }
    }

    if (is_text) {
        return .text;
    }

    return FileTypeError.Internal;
}

test "detect ELF" {
    const elf_file = try std.fs.cwd().openFile("test/testdata/libtest.so", .{});
    defer elf_file.close();

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
    const out = try std.fs.createFileAbsolute(abs_target, .{});
    defer out.close();
    try out.writeAll(tar_contents);

    const created_tar = try std.fs.openFileAbsolute(abs_target, .{});
    defer created_tar.close();
    const kind = try detect(&created_tar);
    try std.testing.expectEqual(Kind.tar, kind);
}

test "detect xz" {
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
        const test_file = try std.fs.createFileAbsolute(test_file_path, .{});
        defer test_file.close();
        try test_file.writeAll("test content");
    }

    const compressed_name = "test.txt.xz";
    const compressed_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, compressed_name });
    defer std.testing.allocator.free(compressed_path);

    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "xz", "-z", "-f", "-k", test_file_path },
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        test_env.ctx.debug("xz compression failed: {s}", .{result.stderr});
        return FileTypeError.FileSystem;
    }

    const compressed_file = try std.fs.openFileAbsolute(compressed_path, .{});
    defer compressed_file.close();

    const kind = try detect(&compressed_file);
    try std.testing.expectEqual(Kind.xz, kind);
}

test "detect shell script" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const script_name = "test.sh";
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, script_name });
    defer std.testing.allocator.free(script_path);

    {
        const script_file = try std.fs.createFileAbsolute(script_path, .{});
        defer script_file.close();
        try script_file.writeAll("#!/bin/sh\necho 'Hello, world!'\n");
    }

    const file = try std.fs.openFileAbsolute(script_path, .{});
    defer file.close();

    const kind = try detect(&file);
    try std.testing.expectEqual(Kind.shell_script, kind);
}

test "detect bash script" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const script_name = "test.bash";
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, script_name });
    defer std.testing.allocator.free(script_path);

    {
        const script_file = try std.fs.createFileAbsolute(script_path, .{});
        defer script_file.close();
        try script_file.writeAll("#!/bin/bash\necho 'Hello, world!'\n");
    }

    const file = try std.fs.openFileAbsolute(script_path, .{});
    defer file.close();

    const kind = try detect(&file);
    try std.testing.expectEqual(Kind.bash_script, kind);
}

test "detect python script" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const script_name = "test.py";
    const script_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, script_name });
    defer std.testing.allocator.free(script_path);

    {
        const script_file = try std.fs.createFileAbsolute(script_path, .{});
        defer script_file.close();
        try script_file.writeAll("#!/usr/bin/env python\nprint('Hello, world!')\n");
    }

    const file = try std.fs.openFileAbsolute(script_path, .{});
    defer file.close();

    const kind = try detect(&file);
    try std.testing.expectEqual(Kind.python_script, kind);
}

test "detect text file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const text_name = "test.txt";
    const text_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, text_name });
    defer std.testing.allocator.free(text_path);

    {
        const text_file = try std.fs.createFileAbsolute(text_path, .{});
        defer text_file.close();
        try text_file.writeAll("This is a plain text file.\nIt contains only ASCII characters.\n");
    }

    const file = try std.fs.openFileAbsolute(text_path, .{});
    defer file.close();

    const kind = try detect(&file);
    try std.testing.expectEqual(Kind.text, kind);
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
        const test_file = try std.fs.createFileAbsolute(test_file_path, .{});
        defer test_file.close();
        try test_file.writeAll("test content");
    }

    const compressed_name = "test.txt.zst";
    const compressed_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, compressed_name });
    defer std.testing.allocator.free(compressed_path);

    const file = try std.fs.openFileAbsolute(test_file_path, .{});
    defer file.close();
    const uncompressed = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(uncompressed);
    const compressed_buf = @import("zstd_c.zig").compressOneShot(std.testing.allocator, uncompressed) catch |err| {
        test_env.ctx.debug("zstd compression failed: {s}", .{@errorName(err)});
        return FileTypeError.FileSystem;
    };
    defer std.testing.allocator.free(compressed_buf);
    const out_file = try p.makePathAndOpenFile(compressed_path);
    defer out_file.close();
    try out_file.writeAll(compressed_buf);

    const compressed_file = try std.fs.openFileAbsolute(compressed_path, .{});
    defer compressed_file.close();

    const kind = try detect(&compressed_file);
    try std.testing.expectEqual(Kind.zst, kind);
}
