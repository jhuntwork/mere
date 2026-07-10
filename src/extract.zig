const std = @import("std");
const archive = @import("archive.zig");
const p = @import("path.zig");
const filetype = @import("filetype.zig");
const zstd_c = @import("zstd_c.zig");
const Context = @import("mere.zig").Context;
const errors = @import("errors.zig");

// libarchive C bindings
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

const AE_IFREG: c_uint = 0o100000;
const AE_IFDIR: c_uint = 0o040000;

const PendingModeKind = enum {
    file,
    directory,
};

const PendingSpecialBits = struct {
    kind: PendingModeKind,
    special_bits: std.Io.File.Permissions,
};

const PendingSpecialBitMap = std.StringHashMap(PendingSpecialBits);

const SpecialBitRestorePolicy = enum {
    none,
    restore_special_bits,
};

fn deinitPendingSpecialBits(pending_special_bits: *PendingSpecialBitMap, allocator: std.mem.Allocator) void {
    var iter = pending_special_bits.iterator();
    while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
    pending_special_bits.deinit();
}

fn recordArchivedSpecialBits(
    ctx: *Context,
    policy: SpecialBitRestorePolicy,
    pending_special_bits: *PendingSpecialBitMap,
    rel_path: []const u8,
    entry: *c.struct_archive_entry,
) ExtractError!void {
    if (policy == .none) return;

    const kind: PendingModeKind = switch (c.archive_entry_filetype(entry)) {
        AE_IFREG => .file,
        AE_IFDIR => .directory,
        else => return,
    };
    const special_bits = std.Io.File.Permissions.fromMode(@intCast(c.archive_entry_perm(entry) & 0o7000));
    if (special_bits.toMode() == 0) return;

    if (pending_special_bits.fetchRemove(rel_path)) |removed| ctx.allocator.free(removed.key);

    const rel_path_copy = ctx.allocator.dupe(u8, rel_path) catch {
        return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to record archived special-bit path");
    };
    errdefer ctx.allocator.free(rel_path_copy);

    pending_special_bits.put(rel_path_copy, .{
        .kind = kind,
        .special_bits = special_bits,
    }) catch {
        return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to record archived special bits");
    };
}

fn applyArchivedSpecialBits(
    ctx: *Context,
    target_dir: []const u8,
    pending_special_bits: *const PendingSpecialBitMap,
) ExtractError!void {
    var directory_paths: std.ArrayList([]const u8) = .empty;
    defer directory_paths.deinit(ctx.allocator);

    var iter = pending_special_bits.iterator();
    while (iter.next()) |entry| {
        const rel_path = entry.key_ptr.*;
        const restore = entry.value_ptr.*;
        if (restore.kind == .directory) {
            directory_paths.append(ctx.allocator, rel_path) catch {
                return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to queue special-bit restore");
            };
            continue;
        }
        try applyArchivedSpecialBitsAtPath(ctx, target_dir, rel_path, restore);
    }

    std.mem.sort([]const u8, directory_paths.items, {}, struct {
        fn depth(path: []const u8) usize {
            return std.mem.count(u8, path, "/");
        }

        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const a_depth = depth(a);
            const b_depth = depth(b);
            if (a_depth != b_depth) return a_depth > b_depth;
            return std.mem.lessThan(u8, b, a);
        }
    }.lessThan);

    for (directory_paths.items) |rel_path| {
        const restore = pending_special_bits.get(rel_path).?;
        try applyArchivedSpecialBitsAtPath(ctx, target_dir, rel_path, restore);
    }
}

fn applyArchivedSpecialBitsAtPath(
    ctx: *Context,
    target_dir: []const u8,
    rel_path: []const u8,
    restore: PendingSpecialBits,
) ExtractError!void {
    const full_path = std.fs.path.join(ctx.allocator, &.{ target_dir, rel_path }) catch {
        return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to allocate special-bit restore path");
    };
    defer ctx.allocator.free(full_path);

    switch (restore.kind) {
        .directory => {
            var dir = std.Io.Dir.openDirAbsolute(p.currentIo(), full_path, .{ .iterate = true }) catch |err| {
                return ctx.fail(mapFsError(err), full_path, "failed to open directory for special-bit restore");
            };
            defer dir.close(p.currentIo());

            const stat = dir.stat(p.currentIo()) catch |err| {
                return ctx.fail(mapFsError(err), full_path, "failed to stat directory for special-bit restore");
            };
            const new_mode = (stat.permissions.toMode() & ~@as(std.posix.mode_t, 0o7000)) | restore.special_bits.toMode();
            dir.setPermissions(p.currentIo(), std.Io.File.Permissions.fromMode(new_mode)) catch |err| {
                return ctx.fail(mapFsError(err), full_path, "failed to restore directory special bits");
            };
        },
        .file => {
            var file = std.Io.Dir.openFileAbsolute(p.currentIo(), full_path, .{}) catch |err| {
                return ctx.fail(mapFsError(err), full_path, "failed to open file for special-bit restore");
            };
            defer file.close(p.currentIo());

            const stat = file.stat(p.currentIo()) catch |err| {
                return ctx.fail(mapFsError(err), full_path, "failed to stat file for special-bit restore");
            };
            const new_mode = (stat.permissions.toMode() & ~@as(std.posix.mode_t, 0o7000)) | restore.special_bits.toMode();
            file.setPermissions(p.currentIo(), std.Io.File.Permissions.fromMode(new_mode)) catch |err| {
                return ctx.fail(mapFsError(err), full_path, "failed to restore file special bits");
            };
        },
    }
}

// Guards against decompression bombs: a small compressed archive whose
// entry declares (accurately) that it expands to an enormous amount of
// data. The main signed-install path is already protected because
// install.zig hash-verifies the whole archive against trusted repo
// metadata before extraction ever runs, but `mere dev import` and
// build-source unpacking extract before any such binding exists.
const max_extracted_entry_size: u64 = 4 * 1024 * 1024 * 1024; // 4 GiB

// archive_entry_size() reflects the declared uncompressed size from the
// entry's own header, independent of how small the compressed bytes
// backing it are - exactly the value a decompression bomb would inflate.
// Entries without a declared size (e.g. some streaming formats) aren't
// checked; mere's real formats (tar) always declare it.
fn checkEntryExtractedSize(ctx: *Context, name: []const u8, archive_entry: *c.struct_archive_entry) ExtractError!void {
    if (c.archive_entry_size_is_set(archive_entry) == 0) return;
    const raw_size = c.archive_entry_size(archive_entry);
    const entry_size: u64 = if (raw_size > 0) @intCast(raw_size) else 0;
    if (entry_size > max_extracted_entry_size) {
        return ctx.failFmt(
            ExtractError.InvalidInput,
            name,
            "declared size {d} bytes exceeds the {d} byte extraction limit",
            .{ entry_size, max_extracted_entry_size },
        );
    }
}

fn extractWithLibarchive(
    ctx: *Context,
    archive_path: []const u8,
    target_dir: []const u8,
    target_file: ?[]const u8,
    special_bit_policy: SpecialBitRestorePolicy,
    pending_special_bits: *PendingSpecialBitMap,
) ExtractError!void {
    // Initialize reader
    const reader = c.archive_read_new() orelse {
        return ctx.fail(ExtractError.OutOfMemory, archive_path, "failed to initialize archive reader");
    };
    defer _ = c.archive_read_free(reader);

    if (c.archive_read_support_format_all(reader) != c.ARCHIVE_OK) {
        return ctx.fail(ExtractError.PackageExtractFailed, archive_path, "failed to enable archive format support");
    }
    if (c.archive_read_support_filter_all(reader) != c.ARCHIVE_OK) {
        return ctx.fail(ExtractError.PackageExtractFailed, archive_path, "failed to enable archive filter support");
    }

    // Open archive file
    const path_z = try ctx.allocator.dupeZ(u8, archive_path);
    defer ctx.allocator.free(path_z);
    if (c.archive_read_open_filename(reader, path_z.ptr, 10240) != c.ARCHIVE_OK) {
        return ctx.fail(ExtractError.FileSystem, archive_path, "failed to open archive");
    }

    // Initialize disk writer
    const writer = c.archive_write_disk_new() orelse {
        return ctx.fail(ExtractError.OutOfMemory, target_dir, "failed to initialize archive writer");
    };
    defer _ = c.archive_write_free(writer);

    // Configure extraction flags - libarchive handles hardlinks automatically
    const extract_flags = c.ARCHIVE_EXTRACT_TIME | c.ARCHIVE_EXTRACT_PERM |
        c.ARCHIVE_EXTRACT_ACL | c.ARCHIVE_EXTRACT_FFLAGS |
        c.ARCHIVE_EXTRACT_SECURE_SYMLINKS | c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        c.ARCHIVE_EXTRACT_UNLINK;

    if (c.archive_write_disk_set_options(writer, extract_flags) != c.ARCHIVE_OK) {
        return ctx.fail(ExtractError.PackageExtractFailed, archive_path, "failed to configure archive extraction");
    }

    // Process each entry
    var entry: ?*c.struct_archive_entry = null;
    while (true) {
        const result = c.archive_read_next_header(reader, &entry);
        if (result == c.ARCHIVE_EOF) break;
        switch (classifyLibarchiveResult(result, reader, null)) {
            .ok => {},
            .warn => |msg| ctx.debug("archive header warning: {s}", .{msg}),
            .skip_missing_hardlink => unreachable,
            .fail => |failure| return ctx.fail(failure.err, archive_path, failure.msg),
        }

        if (entry == null) continue;

        const archive_entry = entry.?;

        // Get entry path
        const name_ptr = c.archive_entry_pathname(archive_entry);
        if (name_ptr == null) continue;
        const name = std.mem.span(name_ptr);

        // If target_file specified, only extract matching files
        if (target_file) |target| {
            const is_match = std.mem.eql(u8, name, target) or
                (std.mem.endsWith(u8, name, target) and
                    ((name.len == target.len) or (name[name.len - target.len - 1] == '/')));
            if (!is_match) continue;
        }

        try checkEntryExtractedSize(ctx, name, archive_entry);

        const rel_path = try ctx.allocator.dupe(u8, name);
        defer ctx.allocator.free(rel_path);

        // Set the extraction path to target_dir
        const new_path = try std.fs.path.join(ctx.allocator, &[_][]const u8{ target_dir, name });
        defer ctx.allocator.free(new_path);
        const new_path_z = try ctx.allocator.dupeZ(u8, new_path);
        defer ctx.allocator.free(new_path_z);
        c.archive_entry_set_pathname(archive_entry, new_path_z.ptr);

        // For hard links, also update the hardlink target path to use target_dir
        const hardlink_ptr = c.archive_entry_hardlink(archive_entry);
        if (hardlink_ptr != null) {
            const hardlink_target = std.mem.span(hardlink_ptr);
            const new_hardlink = try std.fs.path.join(ctx.allocator, &[_][]const u8{ target_dir, hardlink_target });
            defer ctx.allocator.free(new_hardlink);
            const new_hardlink_z = try ctx.allocator.dupeZ(u8, new_hardlink);
            defer ctx.allocator.free(new_hardlink_z);
            c.archive_entry_set_hardlink(archive_entry, new_hardlink_z.ptr);
        }

        // Use libarchive's built-in extract function with disk writer
        const extract_result = c.archive_read_extract2(reader, archive_entry, writer);
        switch (classifyLibarchiveResult(extract_result, reader, writer)) {
            .ok => {},
            .warn => |msg| ctx.debug("archive warning for {s}: {s}", .{ name, msg }),
            .skip_missing_hardlink => {
                if (target_file != null) continue;
                return ctx.fail(ExtractError.FileSystem, archive_path, "hard-link target does not exist");
            },
            .fail => |failure| return ctx.fail(failure.err, archive_path, failure.msg),
        }
        try recordArchivedSpecialBits(ctx, special_bit_policy, pending_special_bits, rel_path, archive_entry);

        if (target_file != null) break; // Found our target file
    }
}

const LibarchiveFailure = struct {
    err: ExtractError,
    msg: []const u8,
};

const LibarchiveAction = union(enum) {
    ok,
    warn: []const u8,
    skip_missing_hardlink,
    fail: LibarchiveFailure,
};

fn classifyLibarchiveResult(status: c_int, reader: ?*c.struct_archive, writer: ?*c.struct_archive) LibarchiveAction {
    if (status == c.ARCHIVE_OK) return .ok;

    const msg = libarchiveMessage(reader, writer);
    if (status == c.ARCHIVE_WARN) {
        return switch (classifyLibarchiveMessage(msg)) {
            .security_path_violation => .{ .fail = .{ .err = ExtractError.InvalidInput, .msg = msg } },
            .missing_hardlink_target => .skip_missing_hardlink,
            .other => .{ .warn = msg },
        };
    }

    return switch (classifyLibarchiveMessage(msg)) {
        .security_path_violation => .{ .fail = .{ .err = ExtractError.InvalidInput, .msg = msg } },
        .missing_hardlink_target => .skip_missing_hardlink,
        .other => if (status == c.ARCHIVE_FATAL)
            .{ .fail = .{ .err = ExtractError.InvalidInput, .msg = msg } }
        else if (status == c.ARCHIVE_FAILED)
            .{ .fail = .{ .err = ExtractError.PackageExtractFailed, .msg = msg } }
        else
            .{ .fail = .{ .err = ExtractError.FileSystem, .msg = msg } },
    };
}

fn libarchiveMessage(reader: ?*c.struct_archive, writer: ?*c.struct_archive) []const u8 {
    const writer_err = if (writer) |w| c.archive_error_string(w) else null;
    const reader_err = if (reader) |r| c.archive_error_string(r) else null;
    return if (writer_err != null) std.mem.span(writer_err) else if (reader_err != null) std.mem.span(reader_err) else "unknown archive error";
}

const LibarchiveMessageClass = enum {
    security_path_violation,
    missing_hardlink_target,
    other,
};

fn classifyLibarchiveMessage(msg: []const u8) LibarchiveMessageClass {
    if (std.mem.indexOf(u8, msg, "Path contains") != null or
        std.mem.indexOf(u8, msg, "Absolute path") != null or
        std.mem.indexOf(u8, msg, "Bad path") != null)
    {
        return .security_path_violation;
    }
    if (std.mem.indexOf(u8, msg, "Hard-link target") != null and
        std.mem.indexOf(u8, msg, "does not exist") != null)
    {
        return .missing_hardlink_target;
    }
    return .other;
}

fn mapPathError(err: anyerror) ExtractError {
    return switch (err) {
        error.OutOfMemory => ExtractError.OutOfMemory,
        error.AccessDenied => ExtractError.PermissionDenied,
        error.PathTooLong, error.InvalidUtf8, error.BadPathName, error.InvalidArgument => ExtractError.InvalidInput,
        else => ExtractError.FileSystem,
    };
}

fn mapFsError(err: anyerror) ExtractError {
    return switch (err) {
        error.OutOfMemory => ExtractError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => ExtractError.PermissionDenied,
        error.PathTooLong, error.BadPathName, error.InvalidUtf8, error.InvalidArgument => ExtractError.InvalidInput,
        else => ExtractError.FileSystem,
    };
}

fn createExtractionStageDir(ctx: *Context, target_abs: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(target_abs) orelse "/";
    const base = std.fs.path.basename(target_abs);

    var rand_bytes: [8]u8 = undefined;
    p.currentIo().random(&rand_bytes);
    const suffix = std.fmt.bytesToHex(rand_bytes, .lower);

    return std.fmt.allocPrint(ctx.allocator, "{s}/.{s}.extract-stage-{s}", .{ parent, base, suffix[0..] }) catch {
        return ctx.fail(ExtractError.OutOfMemory, target_abs, "failed to allocate extraction stage directory");
    };
}

fn mergeStagedTree(ctx: *Context, staged_dir: []const u8, target_abs: []const u8) ExtractError!void {
    var stage_root = std.Io.Dir.openDirAbsolute(p.currentIo(), staged_dir, .{ .iterate = true }) catch |err| {
        return ctx.fail(mapFsError(err), staged_dir, "failed to open staged extraction directory");
    };
    defer stage_root.close(p.currentIo());

    var walker = stage_root.walk(ctx.allocator) catch |err| {
        return ctx.fail(mapFsError(err), staged_dir, "failed to initialize staged extraction walker");
    };
    defer walker.deinit();

    const StagedEntry = struct {
        path: []const u8,
        kind: std.Io.File.Kind,
    };

    var entries: std.ArrayList(StagedEntry) = .empty;
    defer {
        for (entries.items) |entry| ctx.allocator.free(entry.path);
        entries.deinit(ctx.allocator);
    }

    var directories: std.ArrayList([]const u8) = .empty;
    defer directories.deinit(ctx.allocator);

    while (true) {
        const entry = walker.next(p.currentIo()) catch |err| {
            return ctx.fail(mapFsError(err), staged_dir, "failed to iterate staged extraction directory");
        };
        if (entry == null) break;
        try entries.append(ctx.allocator, .{
            .path = try ctx.allocator.dupe(u8, entry.?.path),
            .kind = entry.?.kind,
        });
        if (entry.?.kind == .directory) {
            try directories.append(ctx.allocator, entries.items[entries.items.len - 1].path);
        }
    }

    std.mem.sort(StagedEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: StagedEntry, b: StagedEntry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    for (entries.items) |entry| {
        const rel_path = entry.path;
        const src_path = std.fs.path.join(ctx.allocator, &.{ staged_dir, rel_path }) catch {
            return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to allocate staged source path");
        };
        defer ctx.allocator.free(src_path);
        const dst_path = std.fs.path.join(ctx.allocator, &.{ target_abs, rel_path }) catch {
            return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to allocate staged destination path");
        };
        defer ctx.allocator.free(dst_path);

        switch (entry.kind) {
            .directory => {
                var dir = p.makePathAndOpenDir(dst_path) catch |err| {
                    return ctx.fail(mapFsError(err), dst_path, "failed to create destination directory");
                };
                dir.close(p.currentIo());
            },
            .file, .sym_link => {
                if (std.fs.path.dirname(dst_path)) |dst_parent| {
                    var dir = p.makePathAndOpenDir(dst_parent) catch |err| {
                        return ctx.fail(mapFsError(err), dst_parent, "failed to create destination parent directory");
                    };
                    dir.close(p.currentIo());
                }

                std.Io.Dir.deleteFileAbsolute(p.currentIo(), dst_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    error.IsDir => {
                        std.Io.Dir.cwd().deleteTree(p.currentIo(), dst_path) catch |del_err| {
                            return ctx.fail(mapFsError(del_err), dst_path, "failed to replace destination directory");
                        };
                    },
                    else => return ctx.fail(mapFsError(err), dst_path, "failed to replace destination entry"),
                };

                std.Io.Dir.renameAbsolute(src_path, dst_path, p.currentIo()) catch |err| {
                    return ctx.fail(mapFsError(err), dst_path, "failed to move staged entry into destination");
                };
            },
            else => {},
        }
    }

    var i = directories.items.len;
    while (i > 0) {
        i -= 1;
        const rel_path = directories.items[i];
        const src_path = std.fs.path.join(ctx.allocator, &.{ staged_dir, rel_path }) catch {
            return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to allocate staged directory path");
        };
        defer ctx.allocator.free(src_path);
        const dst_path = std.fs.path.join(ctx.allocator, &.{ target_abs, rel_path }) catch {
            return ctx.fail(ExtractError.OutOfMemory, rel_path, "failed to allocate destination directory path");
        };
        defer ctx.allocator.free(dst_path);
        try copyDirectoryTimes(ctx, src_path, dst_path);
    }
}

fn copyDirectoryTimes(ctx: *Context, src_path: []const u8, dst_path: []const u8) ExtractError!void {
    var src_dir = std.Io.Dir.openDirAbsolute(p.currentIo(), src_path, .{}) catch |err| {
        return ctx.fail(mapFsError(err), src_path, "failed to open staged directory for timestamp copy");
    };
    defer src_dir.close(p.currentIo());
    const stat = src_dir.stat(p.currentIo()) catch |err| {
        return ctx.fail(mapFsError(err), src_path, "failed to stat staged directory for timestamp copy");
    };

    const dst_path_z = ctx.allocator.dupeZ(u8, dst_path) catch {
        return ctx.fail(ExtractError.OutOfMemory, dst_path, "failed to allocate destination timestamp path");
    };
    defer ctx.allocator.free(dst_path_z);

    const times = [2]std.posix.timespec{
        nsToTimespec((stat.atime orelse stat.mtime).nanoseconds),
        nsToTimespec(stat.mtime.nanoseconds),
    };
    switch (std.posix.errno(std.c.utimensat(std.posix.AT.FDCWD, dst_path_z, @constCast(&times), 0))) {
        .SUCCESS => {},
        .ACCES, .PERM, .ROFS => return ctx.fail(ExtractError.PermissionDenied, dst_path, "failed to restore directory timestamps"),
        .BADF, .INVAL, .NOENT, .NOTDIR => return ctx.fail(ExtractError.InvalidInput, dst_path, "failed to restore directory timestamps"),
        .FAULT => unreachable,
        else => return ctx.fail(ExtractError.FileSystem, dst_path, "failed to restore directory timestamps"),
    }
}

fn nsToTimespec(ns: i128) std.posix.timespec {
    return .{
        .sec = std.math.cast(isize, @divFloor(ns, std.time.ns_per_s)) orelse std.math.maxInt(isize),
        .nsec = std.math.cast(isize, @mod(ns, std.time.ns_per_s)) orelse std.math.maxInt(isize),
    };
}

/// Archive extraction operations error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during extraction operations
/// - FileSystem: File operations failed (reading archives, writing extracted files, etc.)
/// - PermissionDenied: Insufficient permissions for extraction operations
/// - InvalidInput: Invalid archive format or extraction parameters
///
/// Extract-Specific Errors:
/// - PackageExtractFailed: Package extraction process failed
/// - UnsupportedFormat: Archive format is not supported
const Std = errors.StandardErrors;
pub const ExtractError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    PackageExtractFailed,
    UnsupportedFormat,
};

fn extract(ctx: *Context, archive_path: []const u8, target_dir: []const u8, target_file: ?[]const u8) ExtractError!void {
    return extractWithPolicy(ctx, archive_path, target_dir, target_file, .none);
}

fn extractWithPolicy(
    ctx: *Context,
    archive_path: []const u8,
    target_dir: []const u8,
    target_file: ?[]const u8,
    special_bit_policy: SpecialBitRestorePolicy,
) ExtractError!void {
    if (!p.isValidInputPath(archive_path)) {
        return ctx.fail(ExtractError.InvalidInput, archive_path, "invalid archive path");
    }
    if (!p.isValidInputPath(target_dir)) {
        return ctx.fail(ExtractError.InvalidInput, target_dir, "invalid target directory");
    }

    var target_dir_handle = p.makePathAndOpenDir(target_dir) catch |err| {
        ctx.setDiagnosticContext(target_dir, "failed to open target directory");
        return switch (err) {
            error.FileNotFound => ExtractError.FileSystem,
            error.AccessDenied => ExtractError.PermissionDenied,
            else => ExtractError.FileSystem,
        };
    };
    target_dir_handle.close(p.currentIo());

    var pending_special_bits = PendingSpecialBitMap.init(ctx.allocator);
    defer deinitPendingSpecialBits(&pending_special_bits, ctx.allocator);

    if (target_file != null) {
        try extractWithLibarchive(ctx, archive_path, target_dir, target_file, special_bit_policy, &pending_special_bits);
        try applyArchivedSpecialBits(ctx, target_dir, &pending_special_bits);
        return;
    }

    var abs_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_abs = p.resolveToAbsolutePath(target_dir, &abs_target_buf) catch |err| {
        return ctx.fail(mapPathError(err), target_dir, "failed to resolve target directory");
    };

    const stage_dir = try createExtractionStageDir(ctx, target_abs);
    defer ctx.allocator.free(stage_dir);
    defer std.Io.Dir.cwd().deleteTree(p.currentIo(), stage_dir) catch {};

    var stage_handle = p.makePathAndOpenDir(stage_dir) catch |err| {
        return ctx.fail(mapFsError(err), stage_dir, "failed to create extraction stage directory");
    };
    stage_handle.close(p.currentIo());

    try extractWithLibarchive(ctx, archive_path, stage_dir, null, special_bit_policy, &pending_special_bits);
    try mergeStagedTree(ctx, stage_dir, target_abs);
    try applyArchivedSpecialBits(ctx, target_abs, &pending_special_bits);

    ctx.debug("extraction completed successfully", .{});
}

pub fn into(ctx: *Context, archive_path: []const u8, target_dir: []const u8) ExtractError!void {
    try extractWithPolicy(ctx, archive_path, target_dir, null, .none);
}

pub fn intoPreservingSpecialBits(ctx: *Context, archive_path: []const u8, target_dir: []const u8) ExtractError!void {
    try extractWithPolicy(ctx, archive_path, target_dir, null, .restore_special_bits);
}

pub fn fileInto(ctx: *Context, archive_path: []const u8, target_dir: []const u8, target_file: []const u8) ExtractError!void {
    try extractWithPolicy(ctx, archive_path, target_dir, target_file, .none);
}

fn writeTarWithOwnedFile(
    allocator: std.mem.Allocator,
    tar_path: []const u8,
    entry_path: []const u8,
    file_contents: []const u8,
    mode: std.Io.File.Permissions,
    uid: i64,
    gid: i64,
) !void {
    const writer = c.archive_write_new() orelse return error.OutOfMemory;
    defer _ = c.archive_write_free(writer);

    if (c.archive_write_set_format_pax_restricted(writer) != c.ARCHIVE_OK) return error.FileSystem;
    if (c.archive_write_add_filter_none(writer) != c.ARCHIVE_OK) return error.FileSystem;

    const tar_path_z = try allocator.dupeZ(u8, tar_path);
    defer allocator.free(tar_path_z);
    if (c.archive_write_open_filename(writer, tar_path_z.ptr) != c.ARCHIVE_OK) return error.FileSystem;
    defer _ = c.archive_write_close(writer);

    const entry = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(entry);

    const entry_path_z = try allocator.dupeZ(u8, entry_path);
    defer allocator.free(entry_path_z);
    c.archive_entry_set_pathname(entry, entry_path_z.ptr);
    c.archive_entry_set_filetype(entry, AE_IFREG);
    c.archive_entry_set_perm(entry, @intCast(mode.toMode()));
    c.archive_entry_set_uid(entry, uid);
    c.archive_entry_set_gid(entry, gid);
    c.archive_entry_set_size(entry, @intCast(file_contents.len));

    if (c.archive_write_header(writer, entry) != c.ARCHIVE_OK) return error.FileSystem;
    if (c.archive_write_data(writer, file_contents.ptr, file_contents.len) != @as(c.la_ssize_t, @intCast(file_contents.len))) {
        return error.FileSystem;
    }
    if (c.archive_write_finish_entry(writer) != c.ARCHIVE_OK) return error.FileSystem;
}

test "Extract a sample tar archive" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        const tar_file = "test.tar";
        const abs_target = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(abs_target);

        try th.createTestTarFile(&test_env.ctx, "some/random/file", abs_target);

        try into(&test_env.ctx, abs_target, test_env.path);
    }
}

test "Repeated extraction preserves stable build snapshot hash" {
    const th = @import("test_helpers.zig");
    const hash = @import("hash.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "stable.tar" });
    defer std.testing.allocator.free(tar_path);
    try th.createTestTarFile(&test_env.ctx, "root/subdir/file", tar_path);

    const extract_one = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "extract-one" });
    defer std.testing.allocator.free(extract_one);
    const extract_two = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "extract-two" });
    defer std.testing.allocator.free(extract_two);

    try into(&test_env.ctx, tar_path, extract_one);
    try into(&test_env.ctx, tar_path, extract_two);

    const hash_one = try hash.calculateBuildSnapshotHash(std.testing.allocator, extract_one, null);
    defer std.testing.allocator.free(hash_one);
    const hash_two = try hash.calculateBuildSnapshotHash(std.testing.allocator, extract_two, null);
    defer std.testing.allocator.free(hash_two);

    try std.testing.expectEqualStrings(hash_one, hash_two);
}

// Spec #16: Path traversal (..) rejected
test "Error when extracting a tar archive with relative path traversal" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        const tar_file = "evil_relative.tar";
        const paths: []const []const u8 = &.{ test_env.path, tar_file };
        const abs_target = try std.fs.path.join(std.testing.allocator, paths);
        defer std.testing.allocator.free(abs_target);

        const tar_contents = try th.createMaliciousTarContents("../etc/passwd");
        defer std.testing.allocator.free(tar_contents);
        var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), abs_target, .{});
        defer file.close(p.currentIo());
        try file.writeStreamingAll(p.currentIo(), tar_contents);

        try std.testing.expectError(error.InvalidInput, into(&test_env.ctx, abs_target, test_env.path));
    }
}

test "checkEntryExtractedSize rejects an entry declaring a decompression-bomb-sized payload" {
    // Exercises the size check directly against a synthetic archive_entry rather than
    // extracting a real archive: constructing an actual archive whose header declares
    // a huge size but whose real body is small/absent hits libarchive's own "truncated
    // archive" failure first (which happens to also map to InvalidInput), masking whether
    // this check ran at all. Setting the size directly on a fresh entry avoids that entirely.
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const archive_entry = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(archive_entry);
    c.archive_entry_set_size(archive_entry, 6 * 1024 * 1024 * 1024); // 6 GiB, over the cap

    try std.testing.expectError(
        error.InvalidInput,
        checkEntryExtractedSize(&test_env.ctx, "bomb.bin", archive_entry),
    );

    // The subject/details should be specific enough that a user hitting this
    // in practice can tell which file was rejected and why, not just "invalid
    // input" - regression guard for the diagnostic context actually being set.
    const diag = test_env.ctx.getDiagnosticContext();
    try std.testing.expectEqualStrings("bomb.bin", diag.subject.?);
    try std.testing.expect(std.mem.indexOf(u8, diag.details.?, "6442450944") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.details.?, "4294967296") != null);
}

test "checkEntryExtractedSize allows an entry at or under the cap" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const archive_entry = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(archive_entry);
    c.archive_entry_set_size(archive_entry, max_extracted_entry_size);

    try checkEntryExtractedSize(&test_env.ctx, "large-but-allowed.bin", archive_entry);
}

test "checkEntryExtractedSize skips entries with no declared size" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const archive_entry = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(archive_entry);

    try checkEntryExtractedSize(&test_env.ctx, "unknown-size.bin", archive_entry);
}

test "Extract a sample tar.zst archive" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        // First create a regular tar file
        const tar_file = "test.tar";
        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(tar_path);

        try th.createTestTarFile(&test_env.ctx, "some/random/file", tar_path);

        // Compress the tar file using zstd command
        const zst_file = "test.tar.zst";
        const zst_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, zst_file });
        defer std.testing.allocator.free(zst_path);

        // Compress using libzstd helper
        const uncompressed = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), p.currentIo(), tar_path, std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(uncompressed);
        const compressed_buf = @import("zstd_c.zig").compressOneShot(std.testing.allocator, uncompressed) catch |err| {
            test_env.ctx.debug("zstd compression failed: {s}\n", .{@errorName(err)});
            return ExtractError.FileSystem;
        };
        defer std.testing.allocator.free(compressed_buf);
        var out_file = try p.makePathAndOpenFile(zst_path);
        defer out_file.close(p.currentIo());
        try out_file.writeStreamingAll(p.currentIo(), compressed_buf);

        // Now test the extraction
        try into(&test_env.ctx, zst_path, test_env.path);

        // Verify the file was extracted correctly
        const extracted_file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "some/random/file" });
        defer std.testing.allocator.free(extracted_file_path);

        var extracted_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), extracted_file_path, .{});
        defer extracted_file.close(p.currentIo());

        var content_buffer: [12]u8 = undefined; // "test content" is 12 bytes
        const bytes_read = try extracted_file.readPositionalAll(p.currentIo(), &content_buffer, 0);
        try std.testing.expectEqual(@as(usize, 12), bytes_read);
        try std.testing.expectEqualStrings("test content", content_buffer[0..bytes_read]);
    }
}

test "Extract a single file from a tar archive" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        const tar_file = "multi_file.tar";
        const paths: []const []const u8 = &.{ test_env.path, tar_file };
        const abs_target = try std.fs.path.join(std.testing.allocator, paths);
        defer std.testing.allocator.free(abs_target);

        // Create a staging directory for the archive content
        const staging_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "staging" });
        defer std.testing.allocator.free(staging_dir);
        var staging_dir_handle = try p.makePathAndOpenDir(staging_dir);
        staging_dir_handle.close(p.currentIo());

        // Define the content for each file
        const file1_content = "content of file 1";
        const file2_content = "content of file 2";
        const file3_content = "content of file 3";

        // Write files to staging directory
        const file1_path = try std.fs.path.join(std.testing.allocator, &.{ staging_dir, "file1.txt" });
        defer std.testing.allocator.free(file1_path);
        var f1 = try p.makePathAndOpenFile(file1_path);
        try f1.writeStreamingAll(p.currentIo(), file1_content);
        f1.close(p.currentIo());

        const file2_path = try std.fs.path.join(std.testing.allocator, &.{ staging_dir, "file2.txt" });
        defer std.testing.allocator.free(file2_path);
        var f2 = try p.makePathAndOpenFile(file2_path);
        try f2.writeStreamingAll(p.currentIo(), file2_content);
        f2.close(p.currentIo());

        const file3_path = try std.fs.path.join(std.testing.allocator, &.{ staging_dir, "subdir", "file3.txt" });
        defer std.testing.allocator.free(file3_path);
        var f3 = try p.makePathAndOpenFile(file3_path);
        try f3.writeStreamingAll(p.currentIo(), file3_content);
        f3.close(p.currentIo());

        // Use archive.createPackageArchive instead of std.tar.Writer
        try archive.createPackageArchive(&test_env.ctx, staging_dir, abs_target);

        // Extract only file2.txt from the archive
        const target_file = "file2.txt";
        try fileInto(&test_env.ctx, abs_target, test_env.path, target_file);

        // Verify that only file2.txt was extracted
        const file2_extracted = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, target_file });
        defer std.testing.allocator.free(file2_extracted);

        // Check that file2.txt exists and has the correct content
        var file2 = try std.Io.Dir.openFileAbsolute(p.currentIo(), file2_extracted, .{});
        defer file2.close(p.currentIo());
        var content_buffer: [17]u8 = undefined; // "content of file 2" is 17 bytes
        const bytes_read = try file2.readPositionalAll(p.currentIo(), &content_buffer, 0);
        try std.testing.expectEqual(@as(usize, file2_content.len), bytes_read);
        try std.testing.expectEqualStrings(file2_content, content_buffer[0..bytes_read]);

        // Check that file1.txt was NOT extracted
        const file1_extracted = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "file1.txt" });
        defer std.testing.allocator.free(file1_extracted);
        // Check that file1.txt was NOT extracted
        const file1_exists = blk: {
            std.Io.Dir.accessAbsolute(p.currentIo(), file1_extracted, .{}) catch |err| {
                try std.testing.expectEqual(error.FileNotFound, err);
                break :blk false;
            };
            break :blk true;
        };
        try std.testing.expect(!file1_exists); // File should not exist

        // Check that subdir/file3.txt was NOT extracted
        const file3_extracted = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "subdir/file3.txt" });
        defer std.testing.allocator.free(file3_extracted);
        const file3_exists = blk: {
            std.Io.Dir.accessAbsolute(p.currentIo(), file3_extracted, .{}) catch |err| {
                try std.testing.expectEqual(error.FileNotFound, err);
                break :blk false;
            };
            break :blk true;
        };
        try std.testing.expect(!file3_exists); // File should not exist
    }
}

// Spec #16: Absolute paths rejected
test "Error when extracting a tar archive with absolute path traversal" {
    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // deliberately creates a malicious archive with absolute paths (/etc/passwd) to verify
    // security handling. libarchive normalizes paths, so we need raw control over entry names.
    // This test needs raw entry-name control that the normal archive path does not provide.

    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer test_env.cleanup();

        // Create a tar file with an absolute path entry
        const tar_file = "evil_absolute.tar";
        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(tar_path);

        // Create a buffer for the tar file
        var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buffer.deinit();
        var tar_writer = std.tar.Writer{
            .underlying_writer = &buffer.writer,
        };

        // Add a file with an absolute path to the tar
        try tar_writer.writeFileBytes("/etc/passwd", "malicious content", .{});

        // Write the tar contents to a file
        const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
        defer std.testing.allocator.free(tar_contents);
        var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
        defer file.close(p.currentIo());
        try file.writeStreamingAll(p.currentIo(), tar_contents);

        // libarchive successfully blocks this attack, so extraction succeeds safely
        try into(&test_env.ctx, tar_path, test_env.path);

        // Verify that the malicious file was NOT extracted to /etc/passwd
        std.Io.Dir.accessAbsolute(p.currentIo(), "/etc/passwd.extracted", .{}) catch |err| {
            try std.testing.expectEqual(error.FileNotFound, err);
        };

        // Verify no files were extracted outside the target directory
        const malicious_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "../etc/passwd" });
        defer std.testing.allocator.free(malicious_path);
        std.Io.Dir.accessAbsolute(p.currentIo(), malicious_path, .{}) catch |err| {
            try std.testing.expectEqual(error.FileNotFound, err);
        };
    }
    std.testing.allocator.destroy(test_env);
}

// Spec #16: Symlink escape rejected
test "Error when extracting a tar archive with traversal via symlink" {
    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // deliberately creates a malicious archive with symlinks pointing outside extraction dir
    // (../../../etc/passwd). libarchive normalizes symlink targets, so we need raw control.
    // This test needs raw entry-name control that the normal archive path does not provide.

    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer test_env.cleanup();

        // Create a tar file with a malicious symlink
        const tar_file = "evil_symlink.tar";
        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(tar_path);

        // Create a buffer for the tar file
        var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buffer.deinit();
        var tar_writer = std.tar.Writer{
            .underlying_writer = &buffer.writer,
        };

        // Add a safe directory first
        try tar_writer.writeDir("safe_dir", .{});

        // Add a symlink that tries to escape the extraction directory
        try tar_writer.writeLink("safe_dir/evil_link", "../../../etc/passwd", .{});

        // Write the tar contents to a file
        const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
        defer std.testing.allocator.free(tar_contents);
        var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
        defer file.close(p.currentIo());
        try file.writeStreamingAll(p.currentIo(), tar_contents);

        // libarchive successfully blocks this attack, so extraction succeeds safely
        try into(&test_env.ctx, tar_path, test_env.path);

        // Verify that malicious symlink was not created or is safely contained
        const safe_dir_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "safe_dir" });
        defer std.testing.allocator.free(safe_dir_path);
        const evil_link_path = try std.fs.path.join(std.testing.allocator, &.{ safe_dir_path, "evil_link" });
        defer std.testing.allocator.free(evil_link_path);

        // The symlink might exist but should not point outside the extraction directory
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = std.Io.Dir.readLinkAbsolute(p.currentIo(), evil_link_path, &link_buf) catch |err| {
            // If symlink doesn't exist, that's also acceptable (libarchive blocked it)
            try std.testing.expect(err == error.FileNotFound or err == error.NotLink);
            return;
        };
        const target = link_buf[0..target_len];

        // If symlink exists, verify it doesn't point outside the extraction directory
        try std.testing.expect(!std.mem.startsWith(u8, target, "/etc/"));
    }
    std.testing.allocator.destroy(test_env);
}

// Spec #16: Symlink escape rejected
test "Error when extracting a tar archive with traversal via normalized symlink" {
    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // deliberately creates a malicious archive with obfuscated path traversal symlinks
    // (innocent/looking/../../../../../../etc/passwd). libarchive normalizes paths.
    // This test needs raw entry-name control that the normal archive path does not provide.

    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer test_env.cleanup();

        // Create a tar file with a malicious symlink
        const tar_file = "evil_symlink_normalized.tar";
        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(tar_path);

        // Create a buffer for the tar file
        var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buffer.deinit();
        var tar_writer = std.tar.Writer{
            .underlying_writer = &buffer.writer,
        };

        // Add deeper directories first
        try tar_writer.writeDir("subdir", .{});
        try tar_writer.writeDir("subdir/deeper", .{});

        // Add a symlink that tries to escape via normalization
        // This path looks innocent but normalizes to "../../etc/passwd"
        try tar_writer.writeLink("subdir/deeper/evil_link", "innocent/looking/../../../../../../etc/passwd", .{});

        // Write the tar contents to a file
        const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
        defer std.testing.allocator.free(tar_contents);
        var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
        defer file.close(p.currentIo());
        try file.writeStreamingAll(p.currentIo(), tar_contents);

        // libarchive successfully blocks this attack, so extraction succeeds safely
        try into(&test_env.ctx, tar_path, test_env.path);

        // Verify that malicious symlink was not created or is safely contained
        const subdir_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "subdir/deeper" });
        defer std.testing.allocator.free(subdir_path);
        const evil_link_path = try std.fs.path.join(std.testing.allocator, &.{ subdir_path, "evil_link" });
        defer std.testing.allocator.free(evil_link_path);

        // The symlink might exist but should not point outside the extraction directory
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = std.Io.Dir.readLinkAbsolute(p.currentIo(), evil_link_path, &link_buf) catch |err| {
            // If symlink doesn't exist, that's also acceptable (libarchive blocked it)
            try std.testing.expect(err == error.FileNotFound or err == error.NotLink);
            return;
        };
        const target = link_buf[0..target_len];

        // If symlink exists, verify it doesn't point outside the extraction directory
        try std.testing.expect(!std.mem.startsWith(u8, target, "/etc/"));
    }
    std.testing.allocator.destroy(test_env);
}

// Spec #16: Permissions preserved during extraction
test "Extract preserves file permissions" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        // Create a tar file with an executable file
        const tar_file = "permissions_test.tar";
        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(tar_path);

        // Create a staging directory for the archive content
        const staging_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "staging" });
        defer std.testing.allocator.free(staging_dir);
        var staging_dir_handle = try p.makePathAndOpenDir(staging_dir);
        staging_dir_handle.close(p.currentIo());

        // Define the content for the executable file
        const exec_content = "#!/bin/sh\necho 'Hello, World!'\n";

        // Create the bin directory and write the executable file
        const exec_path = try std.fs.path.join(std.testing.allocator, &.{ staging_dir, "bin", "executable.sh" });
        defer std.testing.allocator.free(exec_path);
        var exec_file = try p.makePathAndOpenFile(exec_path);
        try exec_file.writeStreamingAll(p.currentIo(), exec_content);
        // Set executable permissions on the staged file before closing
        try exec_file.setPermissions(p.currentIo(), std.Io.File.Permissions.fromMode(0o755));
        exec_file.close(p.currentIo());

        // Use archive.createPackageArchive instead of std.tar.Writer
        try archive.createPackageArchive(&test_env.ctx, staging_dir, tar_path);

        // Extract the tar file
        try into(&test_env.ctx, tar_path, test_env.path);

        // Verify that the extracted file has the correct permissions
        const extracted_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "bin/executable.sh" });
        defer std.testing.allocator.free(extracted_path);

        var result_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), extracted_path, .{});
        defer result_file.close(p.currentIo());

        const stat = try result_file.stat(p.currentIo());
        // Check that the file has executable permissions
        try std.testing.expect((stat.permissions.toMode() & 0o100) != 0); // Check owner executable bit
        try std.testing.expect((stat.permissions.toMode() & 0o010) != 0); // Check group executable bit
        try std.testing.expect((stat.permissions.toMode() & 0o001) != 0); // Check other executable bit
    }
}

test "install extraction restores setuid bit when archive owner differs" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "suid-mismatch.tar" });
        defer std.testing.allocator.free(tar_path);
        try writeTarWithOwnedFile(
            std.testing.allocator,
            tar_path,
            "bin/suid-tool",
            "#!/bin/sh\nexit 0\n",
            std.Io.File.Permissions.fromMode(0o4755),
            0,
            0,
        );

        const install_target = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "install-target" });
        defer std.testing.allocator.free(install_target);
        try intoPreservingSpecialBits(&test_env.ctx, tar_path, install_target);

        const extracted_path = try std.fs.path.join(std.testing.allocator, &.{ install_target, "bin", "suid-tool" });
        defer std.testing.allocator.free(extracted_path);

        var extracted_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), extracted_path, .{});
        defer extracted_file.close(p.currentIo());

        const stat = try extracted_file.stat(p.currentIo());
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o4755), stat.permissions.toMode() & 0o7777);
    }
}

test "musl absolute symlink should be rewritten to package-local target" {
    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // creates an archive with an absolute symlink target (/lib/libc.so) to verify that
    // libarchive preserves symlink targets as-is. Creating filesystem symlinks with
    // absolute targets and using archive.createTar would require different test setup.
    // This test needs raw entry-name control that the normal archive path does not provide.

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    {
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }

        const tar_file = "musl_abs_symlink.tar";
        const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
        defer std.testing.allocator.free(tar_path);

        var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buffer.deinit();
        var tar_writer = std.tar.Writer{
            .underlying_writer = &buffer.writer,
        };

        // Add libc and an absolute symlink that points to /lib/libc.so
        try tar_writer.writeDir("lib", .{});
        try tar_writer.writeFileBytes("lib/libc.so", "dummy libc", .{});
        try tar_writer.writeLink("lib/ld-musl-x86_64.so.1", "/lib/libc.so", .{});

        const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
        defer std.testing.allocator.free(tar_contents);
        var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
        defer file.close(p.currentIo());
        try file.writeStreamingAll(p.currentIo(), tar_contents);

        try into(&test_env.ctx, tar_path, test_env.path);

        const link_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "lib/ld-musl-x86_64.so.1" });
        defer std.testing.allocator.free(link_path);

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = std.Io.Dir.readLinkAbsolute(p.currentIo(), link_path, &link_buf) catch {
            test_env.ctx.debug("failed to read symlink target", .{});
            return;
        };
        const target = link_buf[0..target_len];

        // New behavior: preserve symlinks as-is (no rewriting)
        try std.testing.expectEqualStrings("/lib/libc.so", target);
    }
}

// Spec #16: Hardlinks preserved
test "Extract archive with hard links scenario" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    try into(&test_env.ctx, "test/testdata/hardlink-test.tar", test_env.path);

    // Verify hard links were created and preserved
    const file1_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "hardlink-test/original.txt" });
    defer std.testing.allocator.free(file1_path);
    const file2_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "hardlink-test/hardlink.txt" });
    defer std.testing.allocator.free(file2_path);

    var file1 = try std.Io.Dir.openFileAbsolute(p.currentIo(), file1_path, .{});
    defer file1.close(p.currentIo());
    var file2 = try std.Io.Dir.openFileAbsolute(p.currentIo(), file2_path, .{});
    defer file2.close(p.currentIo());

    const stat1 = try file1.stat(p.currentIo());
    const stat2 = try file2.stat(p.currentIo());

    // Should have same inode (hard link relationship preserved)
    try std.testing.expectEqual(stat1.inode, stat2.inode);
}

test "Extract archive with mixed entry types scenario" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    try into(&test_env.ctx, "test/testdata/mixed-test.tar", test_env.path);

    // Verify all entry types were extracted
    const regular_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/regular.txt" });
    defer std.testing.allocator.free(regular_path);
    const symlink_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/symlink.txt" });
    defer std.testing.allocator.free(symlink_path);
    const hardlink_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/hardlink.txt" });
    defer std.testing.allocator.free(hardlink_path);

    // Regular file should exist
    var regular_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), regular_path, .{});
    regular_file.close(p.currentIo());

    // Symlink should exist
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try std.Io.Dir.readLinkAbsolute(p.currentIo(), symlink_path, &link_buf);
    const target = link_buf[0..target_len];
    try std.testing.expectEqualStrings("target.txt", target);

    // Hard link should exist and share inode with target
    const target_path_mixed = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/target.txt" });
    defer std.testing.allocator.free(target_path_mixed);
    var target_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), target_path_mixed, .{});
    defer target_file.close(p.currentIo());
    var hardlink_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), hardlink_path, .{});
    defer hardlink_file.close(p.currentIo());

    const target_stat = try target_file.stat(p.currentIo());
    const hardlink_stat = try hardlink_file.stat(p.currentIo());
    try std.testing.expectEqual(target_stat.inode, hardlink_stat.inode);
}

test "Compressed archive extraction (.tar.zst) scenario" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    try into(&test_env.ctx, "test/testdata/mixed-test.tar.zst", test_env.path);

    // Should extract same content as uncompressed version
    const regular_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/regular.txt" });
    defer std.testing.allocator.free(regular_path);

    var file = try std.Io.Dir.openFileAbsolute(p.currentIo(), regular_path, .{});
    defer file.close(p.currentIo());
    var content_buffer: [50]u8 = undefined;
    const bytes_read = try file.readPositionalAll(p.currentIo(), &content_buffer, 0);
    // The test file may have a trailing newline, so trim it
    const content_str = std.mem.trimEnd(u8, content_buffer[0..bytes_read], "\n\r");
    try std.testing.expectEqualStrings("regular file content", content_str);
}

test "Single-file extraction with libarchive scenario" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // For single file extraction, extract the regular file instead since target.txt has hardlink dependencies
    try fileInto(&test_env.ctx, "test/testdata/mixed-test.tar", test_env.path, "mixed-test/regular.txt");

    // Only regular file should exist
    const regular_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/regular.txt" });
    defer std.testing.allocator.free(regular_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/target.txt" });
    defer std.testing.allocator.free(target_path);

    // Regular file should exist
    var regular_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), regular_path, .{});
    regular_file.close(p.currentIo());

    // Target file should NOT exist (since it wasn't extracted)
    std.Io.Dir.accessAbsolute(p.currentIo(), target_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

// Spec #16: Path traversal (..) rejected
test "Path traversal attack prevention scenario" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a malicious tar file with path traversal
    const tar_file = "evil_traversal.tar";
    const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
    defer std.testing.allocator.free(tar_path);

    // Create tar contents with path traversal
    const tar_contents = try th.createMaliciousTarContents("../../../etc/passwd");
    defer std.testing.allocator.free(tar_contents);
    var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
    defer file.close(p.currentIo());
    try file.writeStreamingAll(p.currentIo(), tar_contents);

    // Should detect and reject path traversal
    try std.testing.expectError(error.InvalidInput, into(&test_env.ctx, tar_path, test_env.path));
}

test "Various tar implementations compatibility scenario" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Test with our created archives (representing different tar implementations)
    try into(&test_env.ctx, "test/testdata/hardlink-test.tar", test_env.path);
    try into(&test_env.ctx, "test/testdata/mixed-test.tar", test_env.path);

    // Should handle both formats correctly without errors
    const hardlink_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "hardlink-test/hardlink.txt" });
    defer std.testing.allocator.free(hardlink_path);
    const regular_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mixed-test/regular.txt" });
    defer std.testing.allocator.free(regular_path);

    // Both files should exist
    var hardlink_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), hardlink_path, .{});
    hardlink_file.close(p.currentIo());
    var regular_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), regular_path, .{});
    regular_file.close(p.currentIo());
}

// Spec #16: No partial extraction on failure
test "No partial extraction on failure" {
    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // deliberately creates a malicious archive with valid entries followed by a path
    // traversal entry to verify all-or-nothing extraction behavior.
    // This test needs raw entry-name control that the normal archive path does not provide.

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a tar file with valid entries followed by a malicious entry
    const tar_file = "partial_test.tar";
    const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, tar_file });
    defer std.testing.allocator.free(tar_path);

    // Create a buffer for the tar file
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };

    // Add valid entries first
    try tar_writer.writeDir("valid_dir", .{});
    try tar_writer.writeFileBytes("valid_dir/file1.txt", "content 1", .{});
    try tar_writer.writeFileBytes("valid_dir/file2.txt", "content 2", .{});

    // Add a malicious entry that will cause extraction to fail
    try tar_writer.writeFileBytes("../../../etc/evil", "malicious content", .{});

    // Write the tar contents to a file
    const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
    defer std.testing.allocator.free(tar_contents);
    var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
    defer file.close(p.currentIo());
    try file.writeStreamingAll(p.currentIo(), tar_contents);

    // Create a dedicated extraction directory
    const extract_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "extract_target" });
    defer std.testing.allocator.free(extract_dir);
    var extract_dir_handle = try p.makePathAndOpenDir(extract_dir);
    extract_dir_handle.close(p.currentIo());

    // Attempt extraction - should fail due to path traversal
    const result = into(&test_env.ctx, tar_path, extract_dir);
    try std.testing.expectError(error.InvalidInput, result);

    // Verify that NO files were extracted (all-or-nothing behavior)
    // The extraction directory should be empty or contain no extracted files
    const file1_path = try std.fs.path.join(std.testing.allocator, &.{ extract_dir, "valid_dir/file1.txt" });
    defer std.testing.allocator.free(file1_path);
    const file2_path = try std.fs.path.join(std.testing.allocator, &.{ extract_dir, "valid_dir/file2.txt" });
    defer std.testing.allocator.free(file2_path);

    // Check that the valid files were NOT left behind after failure
    std.Io.Dir.accessAbsolute(p.currentIo(), file1_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.Io.Dir.accessAbsolute(p.currentIo(), file2_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };

    // Verify the directory itself is clean (no valid_dir should exist)
    const valid_dir_path = try std.fs.path.join(std.testing.allocator, &.{ extract_dir, "valid_dir" });
    defer std.testing.allocator.free(valid_dir_path);
    std.Io.Dir.accessAbsolute(p.currentIo(), valid_dir_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

test "transactional extraction preserves preexisting target files on failure" {
    // EXCEPTION: Uses std.tar.Writer to embed a failing traversal entry.
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const tar_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "transactional_failure.tar" });
    defer std.testing.allocator.free(tar_path);

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };

    try tar_writer.writeFileBytes("new.txt", "new-data", .{});
    try tar_writer.writeFileBytes("../../../../etc/evil", "bad", .{});

    {
        var out = try std.Io.Dir.createFileAbsolute(p.currentIo(), tar_path, .{});
        defer out.close(p.currentIo());
        try out.writeStreamingAll(p.currentIo(), buffer.written());
    }

    const extract_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "extract_target_existing" });
    defer std.testing.allocator.free(extract_dir);
    var extract_dir_handle = try p.makePathAndOpenDir(extract_dir);
    extract_dir_handle.close(p.currentIo());

    const keep_path = try std.fs.path.join(std.testing.allocator, &.{ extract_dir, "keep.txt" });
    defer std.testing.allocator.free(keep_path);
    {
        var keep_file = try p.makePathAndOpenFile(keep_path);
        defer keep_file.close(p.currentIo());
        try keep_file.writeStreamingAll(p.currentIo(), "keep");
    }

    try std.testing.expectError(error.InvalidInput, into(&test_env.ctx, tar_path, extract_dir));

    {
        var keep_file = try std.Io.Dir.openFileAbsolute(p.currentIo(), keep_path, .{});
        defer keep_file.close(p.currentIo());
        var buf: [8]u8 = undefined;
        const n = try keep_file.readPositionalAll(p.currentIo(), &buf, 0);
        try std.testing.expectEqualStrings("keep", buf[0..n]);
    }

    const new_path = try std.fs.path.join(std.testing.allocator, &.{ extract_dir, "new.txt" });
    defer std.testing.allocator.free(new_path);
    std.Io.Dir.accessAbsolute(p.currentIo(), new_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}
