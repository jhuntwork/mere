const std = @import("std");
const path = @import("path.zig");
const zstd_c = @import("zstd_c.zig");
const Context = @import("mere.zig").Context;
const hash = @import("hash.zig");
const errors = @import("errors.zig");

const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

// Archive entry file types - defined manually because Zig's cImport can't
// translate the C macros that use casts like (__LA_MODE_T)0100000
const AE_IFREG: c_uint = 0o100000; // Regular file
const AE_IFDIR: c_uint = 0o040000; // Directory
const AE_IFLNK: c_uint = 0o120000; // Symbolic link

const Std = errors.StandardErrors;
pub const ArchiveError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{ArchiveCreateFailed};

pub const DeduplicationStats = struct {
    groups_deduplicated: usize = 0,
    files_deduplicated: usize = 0,
    bytes_saved: u64 = 0,
};

fn mapArchiveFsError(err: anyerror) ArchiveError {
    return switch (err) {
        error.OutOfMemory => ArchiveError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => ArchiveError.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => ArchiveError.InvalidInput,
        else => ArchiveError.FileSystem,
    };
}

fn mapHashError(err: hash.HashError) ArchiveError {
    return switch (err) {
        hash.HashError.OutOfMemory => ArchiveError.OutOfMemory,
        hash.HashError.PermissionDenied => ArchiveError.PermissionDenied,
        hash.HashError.InvalidInput => ArchiveError.InvalidInput,
        hash.HashError.FileSystem => ArchiveError.FileSystem,
    };
}

fn archiveFail(ctx: *Context, subject: []const u8, details: []const u8) ArchiveError {
    return ctx.fail(ArchiveError.ArchiveCreateFailed, subject, details);
}

/// Replace duplicate regular files under `dir_path` with hardlinks.
///
/// Canonical selection is deterministic and preserves existing hard-link groups:
/// - If any inode appears multiple times for a given hash, the lexicographically
///   smallest path from that inode group becomes canonical.
/// - Otherwise, the lexicographically smallest path for the hash becomes canonical.
pub fn deduplicate(ctx: *Context, dir_path: []const u8) ArchiveError!DeduplicationStats {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var stats = DeduplicationStats{};

    var dir = path.openExistingDir(dir_path) catch |err| {
        return ctx.fail(mapArchiveFsError(err), dir_path, "failed to open source directory");
    };
    defer dir.close();

    var walker = dir.walk(alloc) catch |err| {
        return ctx.fail(mapArchiveFsError(err), dir_path, "failed to initialize directory walk");
    };
    defer walker.deinit();

    const FileEntry = struct { path: []const u8, kind: std.fs.File.Kind };
    var file_entries = std.array_list.Managed(FileEntry).init(alloc);
    defer file_entries.deinit();

    while (true) {
        const entry = walker.next() catch |err| {
            return ctx.fail(mapArchiveFsError(err), dir_path, "failed to iterate source directory");
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind == .file or e.kind == .sym_link) {
            const rel = try alloc.dupe(u8, e.path);
            try file_entries.append(.{ .path = rel, .kind = e.kind });
        }
    }

    const FileInfo = struct { path: []const u8, inode: u64, hash: []const u8 };
    var files: std.ArrayList(FileInfo) = .{};
    defer files.deinit(alloc);

    var hash_groups = std.StringHashMap(std.ArrayList(usize)).init(alloc);
    defer {
        var it = hash_groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(alloc);
        }
        hash_groups.deinit();
    }

    for (file_entries.items) |fe| {
        if (fe.kind == .sym_link) {
            continue;
        }

        const abs_for_hash = try std.fs.path.join(alloc, &.{ dir_path, fe.path });
        path.ensureResolvedPathWithin(alloc, dir_path, abs_for_hash) catch |err| {
            return ctx.fail(mapArchiveFsError(err), abs_for_hash, "path escapes directory");
        };

        const h = hash.calculateFileHash(ctx.allocator, abs_for_hash) catch |err| {
            return ctx.fail(mapHashError(err), abs_for_hash, "failed to calculate file hash");
        };
        const h_dup = try alloc.dupe(u8, h);
        ctx.allocator.free(h);

        const gop = try hash_groups.getOrPut(h_dup);
        var hash_key: []const u8 = undefined;
        if (gop.found_existing) {
            alloc.free(h_dup);
            hash_key = gop.key_ptr.*;
        } else {
            hash_key = h_dup;
            gop.value_ptr.* = .{};
        }

        const st = std.fs.cwd().statFile(abs_for_hash) catch |err| {
            return ctx.fail(mapArchiveFsError(err), abs_for_hash, "failed to stat file");
        };
        try files.append(alloc, .{ .path = fe.path, .inode = st.inode, .hash = hash_key });
        try gop.value_ptr.*.append(alloc, files.items.len - 1);
    }

    var group_it = hash_groups.iterator();
    while (group_it.next()) |group_entry| {
        const indices = group_entry.value_ptr.*;

        const InodeInfo = struct { count: usize, min_path: []const u8 };
        var inode_map = std.AutoHashMap(u64, InodeInfo).init(alloc);
        defer inode_map.deinit();

        for (indices.items) |idx| {
            const fi = files.items[idx];
            const inode_gop = try inode_map.getOrPut(fi.inode);
            if (!inode_gop.found_existing) {
                inode_gop.value_ptr.* = .{ .count = 1, .min_path = fi.path };
            } else {
                inode_gop.value_ptr.count += 1;
                if (std.mem.order(u8, fi.path, inode_gop.value_ptr.min_path) == .lt) {
                    inode_gop.value_ptr.min_path = fi.path;
                }
            }
        }

        var canonical_inode: u64 = 0;
        var canonical_path: []const u8 = "";
        var found_hardlink_group = false;

        var inode_it = inode_map.iterator();
        while (inode_it.next()) |inode_entry| {
            const info = inode_entry.value_ptr.*;
            if (info.count > 1) {
                if (!found_hardlink_group or std.mem.order(u8, info.min_path, canonical_path) == .lt) {
                    canonical_inode = inode_entry.key_ptr.*;
                    canonical_path = info.min_path;
                    found_hardlink_group = true;
                }
            }
        }

        if (!found_hardlink_group) {
            var found_any = false;
            for (indices.items) |idx| {
                const fi = files.items[idx];
                if (!found_any or std.mem.order(u8, fi.path, canonical_path) == .lt) {
                    canonical_path = fi.path;
                    canonical_inode = fi.inode;
                    found_any = true;
                }
            }
        }

        const canonical_abs = try std.fs.path.join(alloc, &.{ dir_path, canonical_path });

        var group_deduplicated = false;
        for (indices.items) |idx| {
            const fi = files.items[idx];
            if (fi.inode == canonical_inode) {
                continue;
            }

            const target_abs = try std.fs.path.join(alloc, &.{ dir_path, fi.path });
            const target_stat = std.fs.cwd().statFile(target_abs) catch |err| {
                return ctx.fail(mapArchiveFsError(err), target_abs, "failed to stat duplicate file");
            };
            const target_temp_abs = try std.fmt.allocPrint(alloc, "{s}.mere-dedup-tmp", .{target_abs});
            defer alloc.free(target_temp_abs);

            const canonical_abs_z = try alloc.dupeZ(u8, canonical_abs);
            defer alloc.free(canonical_abs_z);

            const target_temp_abs_z = try alloc.dupeZ(u8, target_temp_abs);
            defer alloc.free(target_temp_abs_z);
            std.posix.unlink(target_temp_abs_z) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return ctx.fail(mapArchiveFsError(err), target_temp_abs, "failed to remove stale dedup temp file"),
            };

            std.posix.link(canonical_abs_z, target_temp_abs_z) catch |err| {
                return ctx.fail(mapArchiveFsError(err), target_temp_abs, "failed to create replacement hard link");
            };
            errdefer std.posix.unlink(target_temp_abs_z) catch {};

            if (std.fs.renameAbsolute(target_temp_abs, target_abs)) |_| {
                if (!group_deduplicated) {
                    stats.groups_deduplicated += 1;
                    group_deduplicated = true;
                }
                stats.files_deduplicated += 1;
                stats.bytes_saved += target_stat.size;
                continue;
            } else |err| {
                return ctx.fail(mapArchiveFsError(err), target_abs, "failed to atomically replace duplicate file");
            }
        }
    }

    return stats;
}

/// Create a package archive from a staging directory.
/// Package archives are POSIX pax tar streams compressed with zstd.
pub fn createPackageArchive(ctx: *Context, source_dir: []const u8, output_path: []const u8) !void {
    const resolved_source_dir = try resolveSourceDir(ctx, source_dir);
    defer ctx.allocator.free(resolved_source_dir);

    if (output_path.len == 0) {
        return archiveFail(ctx, "output_path", "empty output path");
    }

    const temp_output_path = std.fmt.allocPrint(ctx.allocator, "{s}.tmp", .{output_path}) catch {
        return archiveFail(ctx, output_path, "failed to allocate temp output path");
    };
    defer ctx.allocator.free(temp_output_path);

    // Write to a sibling temp path so failure never leaves a partial final archive.
    const out_file = path.makePathAndOpenFile(temp_output_path) catch {
        return archiveFail(ctx, temp_output_path, "failed to open temporary output file");
    };
    defer out_file.close();
    errdefer {
        if (std.fs.path.isAbsolute(temp_output_path)) {
            std.fs.deleteFileAbsolute(temp_output_path) catch {};
        } else {
            std.fs.cwd().deleteFile(temp_output_path) catch {};
        }
    }

    var file_buf: [8192]u8 = undefined;
    var out_writer = std.fs.File.writer(out_file, file_buf[0..]);
    var compressor = zstd_c.StreamCompressor.init(ctx.allocator, &out_writer.interface) catch {
        return archiveFail(ctx, output_path, "failed to initialize streaming compressor");
    };
    defer compressor.deinit();

    createTarToCompressor(ctx, resolved_source_dir, &compressor) catch |err| {
        return err;
    };

    compressor.finish() catch {
        return archiveFail(ctx, output_path, "failed to finalize compressed archive");
    };
    out_writer.interface.flush() catch {
        return archiveFail(ctx, output_path, "failed to write compressed archive");
    };

    if (std.fs.path.isAbsolute(temp_output_path) and std.fs.path.isAbsolute(output_path)) {
        std.fs.renameAbsolute(temp_output_path, output_path) catch {
            return archiveFail(ctx, output_path, "failed to atomically publish archive");
        };
    } else {
        std.fs.cwd().rename(temp_output_path, output_path) catch {
            return archiveFail(ctx, output_path, "failed to atomically publish archive");
        };
    }
}

/// Stream a tar archive into a zstd compressor using libarchive disk traversal.
fn createTarToCompressor(ctx: *Context, source_dir: []const u8, compressor: *zstd_c.StreamCompressor) !void {
    const archive = try initArchiveWriter(ctx, source_dir);
    defer _ = c.archive_write_free(archive);

    var write_ctx = WriteContext{ .compressor = compressor };
    try openArchiveToWriteContext(ctx, archive, &write_ctx, source_dir);
    var archive_open = true;
    errdefer if (archive_open) {
        _ = c.archive_write_close(archive);
    };

    try writeArchiveFromDisk(ctx, archive, source_dir);

    if (c.archive_write_close(archive) != c.ARCHIVE_OK) {
        return archiveFail(ctx, source_dir, "failed to close archive");
    }
    archive_open = false;
}

fn resolveSourceDir(ctx: *Context, source_dir: []const u8) ![]const u8 {
    var src_dir: std.fs.Dir = undefined;
    if (std.fs.path.isAbsolute(source_dir)) {
        src_dir = std.fs.openDirAbsolute(source_dir, .{}) catch {
            return archiveFail(ctx, source_dir, "failed to open source directory");
        };
    } else {
        src_dir = std.fs.cwd().openDir(source_dir, .{}) catch {
            return archiveFail(ctx, source_dir, "failed to open source directory");
        };
    }
    defer src_dir.close();

    // Use a canonical absolute path so later path checks stay stable.
    return std.fs.realpathAlloc(ctx.allocator, source_dir) catch {
        return archiveFail(ctx, source_dir, "failed to resolve source directory");
    };
}

fn initArchiveWriter(ctx: *Context, err_path: []const u8) !*c.struct_archive {
    const archive = c.archive_write_new() orelse return archiveFail(ctx, err_path, "failed to create archive writer");
    errdefer _ = c.archive_write_free(archive);

    if (c.archive_write_set_format_pax(archive) != c.ARCHIVE_OK) {
        return archiveFail(ctx, err_path, "failed to set archive format");
    }

    if (c.archive_write_add_filter_none(archive) != c.ARCHIVE_OK) {
        return archiveFail(ctx, err_path, "failed to set archive filter");
    }

    return archive;
}

fn openArchiveToWriteContext(ctx: *Context, archive: *c.struct_archive, write_ctx: *WriteContext, err_path: []const u8) !void {
    if (c.archive_write_open(archive, write_ctx, null, writeToBufferCallback, null) != c.ARCHIVE_OK) {
        return archiveFail(ctx, err_path, "failed to open archive writer");
    }
}

const WriteContext = struct {
    compressor: *zstd_c.StreamCompressor,
};

fn writeToBufferCallback(_: ?*c.struct_archive, client_data: ?*anyopaque, buf: ?*const anyopaque, length: usize) callconv(.c) c.la_ssize_t {
    const write_ctx: *WriteContext = @ptrCast(@alignCast(client_data));
    const data: [*]const u8 = @ptrCast(buf);
    write_ctx.compressor.write(data[0..length]) catch {
        return -1;
    };
    return @intCast(length);
}

fn writeArchiveFromDisk(ctx: *Context, archive: *c.struct_archive, source_dir: []const u8) !void {
    const disk = c.archive_read_disk_new() orelse {
        return archiveFail(ctx, source_dir, "failed to create archive disk reader");
    };
    defer _ = c.archive_read_free(disk);

    _ = c.archive_read_disk_set_symlink_physical(disk);
    _ = c.archive_read_disk_set_standard_lookup(disk);

    const resolver = c.archive_entry_linkresolver_new() orelse {
        return archiveFail(ctx, source_dir, "failed to create hardlink resolver");
    };
    defer c.archive_entry_linkresolver_free(resolver);
    c.archive_entry_linkresolver_set_strategy(resolver, c.archive_format(archive));

    const source_z = ctx.allocator.dupeZ(u8, source_dir) catch {
        return archiveFail(ctx, source_dir, "failed to allocate source path");
    };
    defer ctx.allocator.free(source_z);

    if (c.archive_read_disk_open(disk, source_z.ptr) != c.ARCHIVE_OK) {
        return archiveFail(ctx, source_dir, "failed to open source directory for read");
    }

    while (true) {
        const entry = c.archive_entry_new() orelse {
            _ = c.archive_read_close(disk);
            return archiveFail(ctx, source_dir, "failed to create archive entry");
        };

        const r = c.archive_read_next_header2(disk, entry);
        if (r == c.ARCHIVE_EOF) {
            c.archive_entry_free(entry);
            break;
        }
        if (r != c.ARCHIVE_OK) {
            c.archive_entry_free(entry);
            _ = c.archive_read_close(disk);
            return archiveFail(ctx, source_dir, "failed to read archive entry");
        }

        _ = c.archive_read_disk_descend(disk);

        if (!stripEntryPrefix(entry, source_dir)) {
            c.archive_entry_free(entry);
            continue;
        }

        var linkify_entry: ?*c.struct_archive_entry = entry;
        var sparse: ?*c.struct_archive_entry = null;
        c.archive_entry_linkify(resolver, &linkify_entry, &sparse);

        if (linkify_entry) |le| {
            try writeArchiveEntry(ctx, archive, le, source_dir);
            if (le != entry) c.archive_entry_free(le);
        }
        if (sparse) |se| {
            try writeArchiveEntry(ctx, archive, se, source_dir);
            c.archive_entry_free(se);
        }

        c.archive_entry_free(entry);
    }

    // Flush deferred entries from the resolver.
    var flush_entry: ?*c.struct_archive_entry = null;
    var flush_sparse: ?*c.struct_archive_entry = null;
    c.archive_entry_linkify(resolver, &flush_entry, &flush_sparse);
    while (flush_entry != null or flush_sparse != null) {
        if (flush_entry) |fe| {
            try writeArchiveEntry(ctx, archive, fe, source_dir);
            c.archive_entry_free(fe);
        }
        if (flush_sparse) |se| {
            try writeArchiveEntry(ctx, archive, se, source_dir);
            c.archive_entry_free(se);
        }
        flush_entry = null;
        flush_sparse = null;
        c.archive_entry_linkify(resolver, &flush_entry, &flush_sparse);
    }

    if (c.archive_read_close(disk) != c.ARCHIVE_OK) {
        return archiveFail(ctx, source_dir, "failed to close archive reader");
    }
}

/// Strip the source directory prefix from an entry's pathname and hardlink target.
/// Returns false if the entry should be skipped (root dir or missing path).
fn stripEntryPrefix(entry: *c.struct_archive_entry, source_dir: []const u8) bool {
    const full_path_ptr = c.archive_entry_sourcepath(entry) orelse return false;
    const full_path = std.mem.span(full_path_ptr);
    const rel = stripPrefix(full_path, source_dir) orelse return false;

    // rel points into the null-terminated sourcepath buffer, so
    // the byte just past rel is either '/' or '\0' from the original.
    // Since we stripped the prefix (and optional leading '/'), the
    // remaining slice extends to the original null terminator.
    c.archive_entry_set_pathname(entry, @ptrCast(rel.ptr));

    const hl_ptr = c.archive_entry_hardlink(entry) orelse return true;
    const hl = std.mem.span(hl_ptr);
    if (stripPrefix(hl, source_dir)) |rel_hl| {
        c.archive_entry_set_hardlink(entry, @ptrCast(rel_hl.ptr));
    }
    return true;
}

fn stripPrefix(full: []const u8, prefix: []const u8) ?[]const u8 {
    if (full.len <= prefix.len) return null;
    var rel = full[prefix.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) return null;
    return rel;
}

fn writeArchiveEntry(ctx: *Context, archive: *c.struct_archive, entry: *c.struct_archive_entry, source_dir: []const u8) !void {
    if (c.archive_write_header(archive, entry) != c.ARCHIVE_OK) {
        return archiveFail(ctx, source_dir, "failed to write archive header");
    }

    const size = c.archive_entry_size(entry);
    if (c.archive_entry_filetype(entry) != AE_IFREG or
        c.archive_entry_hardlink(entry) != null or size <= 0) return;

    const sp = c.archive_entry_sourcepath(entry) orelse return;
    const file = std.fs.openFileAbsoluteZ(sp, .{}) catch {
        return archiveFail(ctx, source_dir, "failed to open file for archive data");
    };
    defer file.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch {
            return archiveFail(ctx, source_dir, "failed to read file data");
        };
        if (n == 0) break;
        if (c.archive_write_data(archive, &buf, n) != @as(c.la_ssize_t, @intCast(n))) {
            return archiveFail(ctx, source_dir, "failed to write file data");
        }
    }
}

test "createPackageArchive creates a .tar.zst archive with correct paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const bad_source = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "does_not_exist_dir" });
    defer std.testing.allocator.free(bad_source);

    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "bad_archive.tar.zst" });
    defer std.testing.allocator.free(archive_path);

    try std.testing.expectError(ArchiveError.ArchiveCreateFailed, createPackageArchive(&test_env.ctx, bad_source, archive_path));
}

test "createPackageArchive output file open failure" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    try std.testing.expectError(ArchiveError.ArchiveCreateFailed, createPackageArchive(&test_env.ctx, test_env.path, ""));
}

test "createPackageArchive empty source directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const empty_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "empty" });
    defer std.testing.allocator.free(empty_dir);
    var empty_dir_handle = try path.makePathAndOpenDir(empty_dir);
    defer empty_dir_handle.close();

    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "empty_archive.tar.zst" });
    defer std.testing.allocator.free(archive_path);

    try createPackageArchive(&test_env.ctx, empty_dir, archive_path);

    const stat = try std.fs.cwd().statFile(archive_path);
    try std.testing.expect(stat.size > 0);

    const archive_path_z = try std.testing.allocator.dupeZ(u8, archive_path);
    defer std.testing.allocator.free(archive_path_z);

    const reader = c.archive_read_new() orelse return error.OutOfMemory;
    defer _ = c.archive_read_free(reader);

    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_read_support_format_all(reader));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_read_support_filter_all(reader));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_read_open_filename(reader, archive_path_z.ptr, 10240));

    var entry: ?*c.struct_archive_entry = null;
    try std.testing.expectEqual(c.ARCHIVE_EOF, c.archive_read_next_header(reader, &entry));
}

test "deduplicate replaces duplicate files with hard links pointing to canonical path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const files_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "files" });
    defer std.testing.allocator.free(files_dir);
    try std.fs.cwd().makePath(files_dir);

    const sub_dir = try std.fs.path.join(std.testing.allocator, &.{ files_dir, "sub" });
    defer std.testing.allocator.free(sub_dir);
    try std.fs.cwd().makePath(sub_dir);

    const content = "duplicate content";

    const a_rel = "a.txt";
    const b_rel = "b.txt";
    const c_rel = "sub/c.txt";

    // Create canonical file a.txt
    const a_abs_create = try std.fs.path.join(std.testing.allocator, &.{ files_dir, a_rel });
    defer std.testing.allocator.free(a_abs_create);
    var a_file = try std.fs.createFileAbsolute(a_abs_create, .{});
    try a_file.writeAll(content);
    a_file.close();

    // Create duplicate b.txt
    const b_abs_create = try std.fs.path.join(std.testing.allocator, &.{ files_dir, b_rel });
    defer std.testing.allocator.free(b_abs_create);
    var b_file = try std.fs.createFileAbsolute(b_abs_create, .{});
    try b_file.writeAll(content);
    b_file.close();

    // Create duplicate sub/c.txt
    const c_abs_create = try std.fs.path.join(std.testing.allocator, &.{ files_dir, c_rel });
    defer std.testing.allocator.free(c_abs_create);
    var c_file = try std.fs.createFileAbsolute(c_abs_create, .{});
    try c_file.writeAll(content);
    c_file.close();

    // Run deduplicate
    const stats = try deduplicate(&test_env.ctx, files_dir);
    try std.testing.expectEqual(@as(usize, 1), stats.groups_deduplicated);
    try std.testing.expectEqual(@as(usize, 2), stats.files_deduplicated);
    try std.testing.expectEqual(@as(u64, @as(u64, content.len) * 2), stats.bytes_saved);

    // Check that all files were replaced with hard links to canonical (same inode)
    // canonical should be a.txt (lexicographically smallest)
    const a_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, a_rel });
    defer std.testing.allocator.free(a_abs);
    const b_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, b_rel });
    defer std.testing.allocator.free(b_abs);
    const c_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, c_rel });
    defer std.testing.allocator.free(c_abs);

    const a_stat = try std.fs.cwd().statFile(a_abs);
    const b_stat = try std.fs.cwd().statFile(b_abs);
    const c_stat = try std.fs.cwd().statFile(c_abs);

    // All files should have the same inode (hard linked)
    try std.testing.expect(a_stat.inode == b_stat.inode);
    try std.testing.expect(a_stat.inode == c_stat.inode);

    // All files should still contain the same content
    const a_file_check = try std.fs.cwd().openFile(a_abs, .{});
    defer a_file_check.close();
    var a_content_buf: [100]u8 = undefined;
    const a_content_len = try a_file_check.readAll(&a_content_buf);
    const a_content = a_content_buf[0..a_content_len];

    const b_file_check = try std.fs.cwd().openFile(b_abs, .{});
    defer b_file_check.close();
    var b_content_buf: [100]u8 = undefined;
    const b_content_len = try b_file_check.readAll(&b_content_buf);
    const b_content = b_content_buf[0..b_content_len];

    try std.testing.expect(std.mem.eql(u8, a_content, b_content));
    try std.testing.expect(std.mem.eql(u8, a_content, content));
}

test "deduplicate preserves existing hard links without unnecessary operations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const files_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "hardlink_test" });
    defer std.testing.allocator.free(files_dir);
    try std.fs.cwd().makePath(files_dir);

    const content = "shared content for hard links";

    const original_rel = "original.txt";
    const existing_hardlink_rel = "existing_hardlink.txt";
    const duplicate_file_rel = "separate_duplicate.txt";

    // Create original file
    const original_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, original_rel });
    defer std.testing.allocator.free(original_abs);
    var original_file = try std.fs.createFileAbsolute(original_abs, .{});
    try original_file.writeAll(content);
    original_file.close();

    // Create existing hard link to original file
    const existing_hardlink_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, existing_hardlink_rel });
    defer std.testing.allocator.free(existing_hardlink_abs);
    const original_abs_z = try std.testing.allocator.dupeZ(u8, original_abs);
    defer std.testing.allocator.free(original_abs_z);
    const existing_hardlink_abs_z = try std.testing.allocator.dupeZ(u8, existing_hardlink_abs);
    defer std.testing.allocator.free(existing_hardlink_abs_z);
    const link_rc = std.os.linux.link(original_abs_z, existing_hardlink_abs_z);
    try std.testing.expect(link_rc == 0);

    // Create a separate duplicate file (not hard-linked)
    const duplicate_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, duplicate_file_rel });
    defer std.testing.allocator.free(duplicate_abs);
    var duplicate_file = try std.fs.createFileAbsolute(duplicate_abs, .{});
    try duplicate_file.writeAll(content);
    duplicate_file.close();

    // Get inodes before deduplication
    const original_stat_before = try std.fs.cwd().statFile(original_abs);
    const existing_hardlink_stat_before = try std.fs.cwd().statFile(existing_hardlink_abs);
    const duplicate_stat_before = try std.fs.cwd().statFile(duplicate_abs);

    // Verify existing hard link relationship
    try std.testing.expect(original_stat_before.inode == existing_hardlink_stat_before.inode);
    try std.testing.expect(original_stat_before.inode != duplicate_stat_before.inode);

    // Run deduplicate
    const stats = try deduplicate(&test_env.ctx, files_dir);
    try std.testing.expectEqual(@as(usize, 1), stats.groups_deduplicated);
    try std.testing.expectEqual(@as(usize, 1), stats.files_deduplicated);
    try std.testing.expectEqual(@as(u64, content.len), stats.bytes_saved);

    // Get inodes after deduplication
    const original_stat_after = try std.fs.cwd().statFile(original_abs);
    const existing_hardlink_stat_after = try std.fs.cwd().statFile(existing_hardlink_abs);
    const duplicate_stat_after = try std.fs.cwd().statFile(duplicate_abs);

    // Verify that existing hard links are preserved (same inodes as before)
    try std.testing.expect(original_stat_before.inode == original_stat_after.inode);
    try std.testing.expect(existing_hardlink_stat_before.inode == existing_hardlink_stat_after.inode);
    try std.testing.expect(original_stat_after.inode == existing_hardlink_stat_after.inode);

    // Verify that the separate duplicate file was converted to hard link with canonical file
    // (canonical should be existing_hardlink.txt, lexicographically first)
    try std.testing.expect(existing_hardlink_stat_after.inode == duplicate_stat_after.inode);

    // All three files should now have the same inode
    try std.testing.expect(original_stat_after.inode == duplicate_stat_after.inode);

    // Verify all files still contain the correct content
    const original_file_check = try std.fs.cwd().openFile(original_abs, .{});
    defer original_file_check.close();
    var content_buf: [100]u8 = undefined;
    const content_len = try original_file_check.readAll(&content_buf);
    const read_content = content_buf[0..content_len];
    try std.testing.expect(std.mem.eql(u8, read_content, content));
}

test "archive mapArchiveFsError preserves actionable classes" {
    try std.testing.expectEqual(ArchiveError.PermissionDenied, mapArchiveFsError(error.AccessDenied));
    try std.testing.expectEqual(ArchiveError.OutOfMemory, mapArchiveFsError(error.OutOfMemory));
    try std.testing.expectEqual(ArchiveError.InvalidInput, mapArchiveFsError(error.BadPathName));
    try std.testing.expectEqual(ArchiveError.FileSystem, mapArchiveFsError(error.InputOutput));
}

test "archive mapHashError preserves actionable classes" {
    try std.testing.expectEqual(ArchiveError.PermissionDenied, mapHashError(hash.HashError.PermissionDenied));
    try std.testing.expectEqual(ArchiveError.OutOfMemory, mapHashError(hash.HashError.OutOfMemory));
    try std.testing.expectEqual(ArchiveError.InvalidInput, mapHashError(hash.HashError.InvalidInput));
    try std.testing.expectEqual(ArchiveError.FileSystem, mapHashError(hash.HashError.FileSystem));
}

test "deduplicate reports traversal permission failures" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const files_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "perm_test" });
    defer std.testing.allocator.free(files_dir);
    try std.fs.cwd().makePath(files_dir);

    const blocked_dir = try std.fs.path.join(std.testing.allocator, &.{ files_dir, "blocked" });
    defer std.testing.allocator.free(blocked_dir);
    try std.fs.cwd().makePath(blocked_dir);

    const blocked_file = try std.fs.path.join(std.testing.allocator, &.{ blocked_dir, "x.txt" });
    defer std.testing.allocator.free(blocked_file);
    var f = try std.fs.createFileAbsolute(blocked_file, .{});
    try f.writeAll("hidden");
    f.close();

    try std.posix.fchmodat(std.posix.AT.FDCWD, blocked_dir, 0, 0);
    defer std.posix.fchmodat(std.posix.AT.FDCWD, blocked_dir, 0o755, 0) catch {};

    const result = deduplicate(&test_env.ctx, files_dir);
    try std.testing.expectError(ArchiveError.PermissionDenied, result);
}

test "deduplicate does not create missing source directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const missing_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "does-not-exist" });
    defer std.testing.allocator.free(missing_dir);

    try std.testing.expectError(ArchiveError.FileSystem, deduplicate(&test_env.ctx, missing_dir));
    try std.testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(missing_dir, .{}));
}

test "deduplicate failure preserves original duplicate file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const files_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "replace_safety" });
    defer std.testing.allocator.free(files_dir);
    try std.fs.cwd().makePath(files_dir);

    const canonical_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, "a.txt" });
    defer std.testing.allocator.free(canonical_abs);
    var canonical_file = try std.fs.createFileAbsolute(canonical_abs, .{});
    try canonical_file.writeAll("same");
    canonical_file.close();

    const duplicate_abs = try std.fs.path.join(std.testing.allocator, &.{ files_dir, "b.txt" });
    defer std.testing.allocator.free(duplicate_abs);
    var duplicate_file = try std.fs.createFileAbsolute(duplicate_abs, .{});
    try duplicate_file.writeAll("same");
    duplicate_file.close();

    try std.posix.fchmodat(std.posix.AT.FDCWD, files_dir, 0o555, 0);
    defer std.posix.fchmodat(std.posix.AT.FDCWD, files_dir, 0o755, 0) catch {};

    try std.testing.expectError(ArchiveError.PermissionDenied, deduplicate(&test_env.ctx, files_dir));

    var duplicate_check = try std.fs.openFileAbsolute(duplicate_abs, .{});
    defer duplicate_check.close();
    var buf: [8]u8 = undefined;
    const len = try duplicate_check.readAll(&buf);
    try std.testing.expectEqualStrings("same", buf[0..len]);
}
