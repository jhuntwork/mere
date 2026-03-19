const std = @import("std");
const mere = @import("mere.zig");
const zstd_c = @import("zstd_c.zig");
const path = @import("path.zig");

pub const CompressError = error{
    OutOfMemory,
    FileSystem,
    Internal,
};

pub const CompressResult = struct {
    files_compressed: usize = 0,
    symlinks_rewritten: usize = 0,
};

pub fn compressDirectory(ctx: *mere.Context, staging_dir: []const u8) CompressError!CompressResult {
    const allocator = ctx.allocator;
    const io = path.currentIo();
    const man_root = std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "man" }) catch {
        return ctx.fail(CompressError.OutOfMemory, staging_dir, "failed to build man page path");
    };
    defer allocator.free(man_root);

    std.Io.Dir.accessAbsolute(io, man_root, .{}) catch |err| {
        if (err == error.FileNotFound) return .{};
        return ctx.fail(mapFsError(err), man_root, "failed to access man page directory");
    };

    var dir = std.Io.Dir.openDirAbsolute(io, man_root, .{ .iterate = true }) catch |err| {
        return ctx.fail(mapFsError(err), man_root, "failed to open man page directory");
    };
    defer dir.close(io);

    var walker = dir.walk(allocator) catch {
        return ctx.fail(CompressError.OutOfMemory, man_root, "failed to walk man page directory");
    };
    defer walker.deinit();

    var symlink_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (symlink_paths.items) |symlink_path| allocator.free(symlink_path);
        symlink_paths.deinit(allocator);
    }

    var result = CompressResult{};
    while (walker.next(io) catch |err| {
        return ctx.fail(CompressError.FileSystem, man_root, @errorName(err));
    }) |entry| {
        switch (entry.kind) {
            .file => {
                if (!isCompressibleManpage(entry.path)) continue;
                const abs_path = std.fs.path.join(allocator, &.{ man_root, entry.path }) catch {
                    return ctx.fail(CompressError.OutOfMemory, entry.path, "failed to allocate man page path");
                };
                defer allocator.free(abs_path);
                try compressFile(ctx, abs_path);
                result.files_compressed += 1;
            },
            .sym_link => {
                if (!isCompressibleManpage(entry.path)) continue;
                const dup = allocator.dupe(u8, entry.path) catch {
                    return ctx.fail(CompressError.OutOfMemory, entry.path, "failed to record man page symlink");
                };
                symlink_paths.append(allocator, dup) catch {
                    allocator.free(dup);
                    return ctx.fail(CompressError.OutOfMemory, entry.path, "failed to record man page symlink");
                };
            },
            else => {},
        }
    }

    for (symlink_paths.items) |rel_path| {
        const abs_path = std.fs.path.join(allocator, &.{ man_root, rel_path }) catch {
            return ctx.fail(CompressError.OutOfMemory, rel_path, "failed to allocate man page symlink path");
        };
        defer allocator.free(abs_path);
        if (try rewriteSymlinkTarget(ctx, abs_path)) {
            result.symlinks_rewritten += 1;
        }
    }

    return result;
}

fn isCompressibleManpage(rel_path: []const u8) bool {
    const base = std.fs.path.basename(rel_path);
    if (base.len == 0) return false;
    if (std.mem.endsWith(u8, base, ".zst")) return false;
    return true;
}

fn compressFile(ctx: *mere.Context, abs_path: []const u8) CompressError!void {
    const allocator = ctx.allocator;
    const io = path.currentIo();
    const out_path = std.fmt.allocPrint(allocator, "{s}.zst", .{abs_path}) catch {
        return ctx.fail(CompressError.OutOfMemory, abs_path, "failed to allocate compressed man page path");
    };
    defer allocator.free(out_path);

    var src = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to open man page for compression");
    };
    defer src.close(io);

    const stat = src.stat(io) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to stat man page for compression");
    };
    const src_bytes = allocator.alloc(u8, @intCast(stat.size)) catch {
        return ctx.fail(CompressError.OutOfMemory, abs_path, "failed to allocate man page input buffer");
    };
    defer allocator.free(src_bytes);
    const bytes_read = src.readPositionalAll(io, src_bytes, 0) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to read man page for compression");
    };
    if (bytes_read != stat.size) {
        return ctx.fail(CompressError.FileSystem, abs_path, "failed to read complete man page for compression");
    }

    const compressed = zstd_c.compressOneShot(allocator, src_bytes) catch |err| {
        return ctx.fail(mapZstdError(err), abs_path, "failed to compress man page");
    };
    defer allocator.free(compressed);

    var out = std.Io.Dir.createFileAbsolute(io, out_path, .{ .truncate = true }) catch |err| {
        return ctx.fail(mapFsError(err), out_path, "failed to create compressed man page");
    };
    defer out.close(io);
    out.writeStreamingAll(io, compressed) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, out_path) catch {};
        return ctx.fail(mapFsError(err), out_path, "failed to write compressed man page");
    };

    std.Io.Dir.deleteFileAbsolute(io, abs_path) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to remove uncompressed man page");
    };
}

fn rewriteSymlinkTarget(ctx: *mere.Context, abs_path: []const u8) CompressError!bool {
    const io = path.currentIo();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = std.Io.Dir.readLinkAbsolute(io, abs_path, &buf) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to read man page symlink");
    };
    const target = buf[0..target_len];
    if (std.mem.endsWith(u8, target, ".zst")) return false;

    const allocator = ctx.allocator;
    const new_target = std.fmt.allocPrint(allocator, "{s}.zst", .{target}) catch {
        return ctx.fail(CompressError.OutOfMemory, abs_path, "failed to allocate man page symlink target");
    };
    defer allocator.free(new_target);

    std.Io.Dir.deleteFileAbsolute(io, abs_path) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to replace man page symlink");
    };
    const parent = std.fs.path.dirname(abs_path) orelse "/";
    const basename = std.fs.path.basename(abs_path);
    var parent_dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| {
        return ctx.fail(mapFsError(err), parent, "failed to open man page symlink parent");
    };
    defer parent_dir.close(io);
    parent_dir.symLink(io, new_target, basename, .{}) catch |err| {
        return ctx.fail(mapFsError(err), abs_path, "failed to write compressed man page symlink");
    };
    return true;
}

fn mapFsError(err: anyerror) CompressError {
    return switch (err) {
        error.OutOfMemory => CompressError.OutOfMemory,
        else => CompressError.FileSystem,
    };
}

fn mapZstdError(err: anyerror) CompressError {
    return switch (err) {
        error.OutOfMemory => CompressError.OutOfMemory,
        error.FileSystem => CompressError.FileSystem,
        else => CompressError.Internal,
    };
}

test "compressDirectory compresses man pages and rewrites symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging" });
    defer test_env.ctx.allocator.free(staging_dir);
    const man_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "usr", "share", "man", "man1" });
    defer test_env.ctx.allocator.free(man_dir);
    try path.ensureDirExists(man_dir);

    const page_path = try std.fs.path.join(test_env.ctx.allocator, &.{ man_dir, "mere.1" });
    defer test_env.ctx.allocator.free(page_path);
    var page = try std.Io.Dir.createFileAbsolute(path.currentIo(), page_path, .{});
    try page.writeStreamingAll(path.currentIo(), "manual page contents");
    page.close(path.currentIo());

    const link_path = try std.fs.path.join(test_env.ctx.allocator, &.{ man_dir, "mere-link.1" });
    defer test_env.ctx.allocator.free(link_path);
    {
        var man_dir_handle = try path.openExistingDir(man_dir);
        defer man_dir_handle.close(path.currentIo());
        try man_dir_handle.symLink(path.currentIo(), "mere.1", "mere-link.1", .{});
    }

    const result = try compressDirectory(&test_env.ctx, staging_dir);

    try std.testing.expectEqual(@as(usize, 1), result.files_compressed);
    try std.testing.expectEqual(@as(usize, 1), result.symlinks_rewritten);

    std.Io.Dir.accessAbsolute(path.currentIo(), page_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };

    const compressed_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}.zst", .{page_path});
    defer test_env.ctx.allocator.free(compressed_path);
    try std.Io.Dir.accessAbsolute(path.currentIo(), compressed_path, .{});

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_target_len = try std.Io.Dir.readLinkAbsolute(path.currentIo(), link_path, &target_buf);
    const link_target = target_buf[0..link_target_len];
    try std.testing.expectEqualStrings("mere.1.zst", link_target);
}
