const std = @import("std");
const mere = @import("mere.zig");
const path = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const HashError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

const TreeHashEntry = struct {
    entry_path: []const u8,
    kind: std.Io.File.Kind,
    mode: u32,
    size: u64,
    mtime: i128,
};

fn mapHashFsError(err: anyerror) HashError {
    return switch (err) {
        error.OutOfMemory => HashError.OutOfMemory,
        error.AccessDenied => HashError.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => HashError.InvalidInput,
        else => HashError.FileSystem,
    };
}

pub const HashDiag = struct {
    path: ?[]const u8 = null,
    action: ?[]const u8 = null,
    os_error: ?anyerror = null,

    pub fn deinit(self: *HashDiag, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        self.* = .{};
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn calculateBytesHash(allocator: std.mem.Allocator, bytes: []const u8) HashError![]const u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;

    hasher.update(bytes);
    hasher.final(&hash_buffer);

    return std.fmt.allocPrint(allocator, "{x}", .{hash_buffer}) catch {
        return HashError.OutOfMemory;
    };
}

pub fn calculateFileHash(ctx: *mere.Context, file_path: []const u8) HashError![]const u8 {
    if (!path.isValidInputPath(file_path)) {
        return HashError.InvalidInput;
    }
    const io = path.currentIo();
    var archive_file: std.Io.File = undefined;

    if (std.fs.path.isAbsolute(file_path)) {
        archive_file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
            ctx.setDiagnosticContext(file_path, @errorName(err));
            return switch (err) {
                error.FileNotFound => HashError.FileSystem,
                else => mapHashFsError(err),
            };
        };
    } else {
        archive_file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
            ctx.setDiagnosticContext(file_path, @errorName(err));
            return switch (err) {
                error.FileNotFound => HashError.FileSystem,
                else => mapHashFsError(err),
            };
        };
    }
    defer archive_file.close(io);

    var hasher = std.crypto.hash.Blake3.init(.{});
    var hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;

    {
        var buf: [8192]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const bytes_read = archive_file.readPositionalAll(io, &buf, offset) catch |err| {
                ctx.setDiagnosticContext(file_path, @errorName(err));
                return mapHashFsError(err);
            };
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
            offset += bytes_read;
        }
    }

    hasher.final(&hash_buffer);

    return std.fmt.allocPrint(ctx.allocator, "{x}", .{hash_buffer}) catch {
        return HashError.OutOfMemory;
    };
}

const EntryType = enum(u8) {
    file = 0x10,
    directory = 0x11,
    symlink = 0x12,
};

const ENTRY_TAG: u8 = 0x01;

/// The v1 store identity: realized payload only. This is retained for
/// compatibility with all packages published before metadata-aware identity.
pub fn calculateStoreContentHash(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
) HashError![]const u8 {
    return calculateTreeHashInternal(allocator, dir_path, diag, false, false, null);
}

/// The transitional v0.18.0 identity: payload plus meta.kdl, without a
/// domain marker. It is read-only compatibility for packages produced by the
/// released but unversioned metadata-aware implementation.
pub fn calculateTransitionalMetadataContentHash(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
) HashError![]const u8 {
    return calculateTreeHashInternal(allocator, dir_path, diag, false, true, null);
}

/// The versioned metadata-aware store identity used by new packages.
pub fn calculateStoreContentHashV2(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
) HashError![]const u8 {
    return calculateTreeHashInternal(allocator, dir_path, diag, false, true, "mere-store-content-v2\x00");
}

pub fn calculateBuildSnapshotHash(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
) HashError![]const u8 {
    return calculateTreeHashInternal(allocator, dir_path, diag, true, false, null);
}

fn calculateTreeHashInternal(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
    include_mtime: bool,
    include_metadata: bool,
    domain: ?[]const u8,
) HashError![]const u8 {
    if (!path.isValidInputPath(dir_path)) {
        setDiag(allocator, diag, dir_path, "invalid input path", null);
        return HashError.InvalidInput;
    }

    const io = path.currentIo();
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        setDiag(allocator, diag, dir_path, "open directory", err);
        return switch (err) {
            error.FileNotFound => HashError.FileSystem,
            else => mapHashFsError(err),
        };
    };
    defer dir.close(io);

    var entries: std.ArrayList(TreeHashEntry) = .empty;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.entry_path);
        }
        entries.deinit(allocator);
    }

    var walker = dir.walk(allocator) catch |err| {
        setDiag(allocator, diag, dir_path, "walk directory", err);
        return mapHashFsError(err);
    };
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io) catch |err| {
            setDiag(allocator, diag, dir_path, "iterate directory walk", err);
            return mapHashFsError(err);
        };
        if (entry == null) break;
        if (isExcludedStoreHashPath(entry.?.path, include_metadata)) continue;
        const e = entry.?;

        const path_copy = allocator.dupe(u8, e.path) catch {
            setDiag(allocator, diag, e.path, "copy entry path", error.OutOfMemory);
            return HashError.OutOfMemory;
        };
        switch (e.kind) {
            .file, .sym_link, .directory => {},
            else => {
                allocator.free(path_copy);
                continue;
            },
        }

        const stat = dir.statFile(io, e.path, .{ .follow_symlinks = false }) catch |err| {
            allocator.free(path_copy);
            setDiag(allocator, diag, e.path, "stat entry", err);
            return switch (err) {
                error.FileNotFound => HashError.FileSystem,
                else => mapHashFsError(err),
            };
        };

        entries.append(allocator, .{
            .entry_path = path_copy,
            .kind = e.kind,
            .mode = stat.permissions.toMode(),
            .size = if (e.kind == .file) @intCast(stat.size) else 0,
            .mtime = stat.mtime.nanoseconds,
        }) catch {
            allocator.free(path_copy);
            setDiag(allocator, diag, e.path, "record entry", error.OutOfMemory);
            return HashError.OutOfMemory;
        };
    }

    std.sort.heap(TreeHashEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: TreeHashEntry, b: TreeHashEntry) bool {
            return std.mem.lessThan(u8, a.entry_path, b.entry_path);
        }
    }.lessThan);

    var hasher = std.crypto.hash.Blake3.init(.{});
    if (domain) |prefix| hasher.update(prefix);
    if (include_mtime) hasher.update("build-snapshot-v1");

    for (entries.items) |entry| {
        hasher.update(&[_]u8{ENTRY_TAG});

        const path_len: u32 = @intCast(entry.entry_path.len);
        hasher.update(&std.mem.toBytes(path_len));

        hasher.update(entry.entry_path);

        const type_tag: u8 = switch (entry.kind) {
            .file => @intFromEnum(EntryType.file),
            .directory => @intFromEnum(EntryType.directory),
            .sym_link => @intFromEnum(EntryType.symlink),
            else => continue, // Skip other types (devices, sockets, etc.)
        };
        hasher.update(&[_]u8{type_tag});

        if (include_mtime) {
            const mode_le = std.mem.nativeToLittle(u32, entry.mode);
            hasher.update(&std.mem.toBytes(mode_le));
            if (entry.kind != .directory) {
                const mtime_le = std.mem.nativeToLittle(i128, entry.mtime);
                hasher.update(&std.mem.toBytes(mtime_le));
            }
        }

        if (entry.kind == .file) {
            const exec_bit: u8 = if (entry.mode & 0o111 != 0) 0x01 else 0x00;
            hasher.update(&[_]u8{exec_bit});

            hasher.update(&std.mem.toBytes(entry.size));

            const file = dir.openFile(io, entry.entry_path, .{}) catch |err| {
                setDiag(allocator, diag, entry.entry_path, "open file", err);
                return switch (err) {
                    error.FileNotFound => HashError.FileSystem,
                    else => mapHashFsError(err),
                };
            };
            defer file.close(io);

            var buf: [8192]u8 = undefined;
            var offset: u64 = 0;
            while (true) {
                const bytes_read = file.readPositionalAll(io, &buf, offset) catch |err| {
                    setDiag(allocator, diag, entry.entry_path, "read file", err);
                    return mapHashFsError(err);
                };
                if (bytes_read == 0) break;
                hasher.update(buf[0..bytes_read]);
                offset += bytes_read;
            }
        } else if (entry.kind == .sym_link) {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target_len = dir.readLink(io, entry.entry_path, &link_buf) catch |err| {
                setDiag(allocator, diag, entry.entry_path, "read symlink", err);
                return switch (err) {
                    error.FileNotFound => HashError.FileSystem,
                    else => mapHashFsError(err),
                };
            };
            const target = link_buf[0..target_len];

            const target_len_u32: u32 = @intCast(target.len);
            hasher.update(&std.mem.toBytes(target_len_u32));

            hasher.update(target);
        }
    }

    var hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(&hash_buffer);

    return std.fmt.allocPrint(allocator, "{x}", .{hash_buffer}) catch {
        return HashError.OutOfMemory;
    };
}

fn isExcludedStoreHashPath(entry_path: []const u8, include_metadata: bool) bool {
    if (!include_metadata) {
        return std.mem.eql(u8, entry_path, ".mere") or
            std.mem.startsWith(u8, entry_path, ".mere/");
    }

    // In metadata-aware identity, only self-referential and derived files
    // are excluded. Canonical meta.kdl participates in the hash.
    if (std.mem.eql(u8, entry_path, ".mere")) return true;
    return std.mem.eql(u8, entry_path, ".mere/manifest.v1") or
        std.mem.eql(u8, entry_path, ".mere/manifest.v1.sig") or
        std.mem.eql(u8, entry_path, ".mere/manifest.v2") or
        std.mem.eql(u8, entry_path, ".mere/manifest.v2.sig") or
        std.mem.eql(u8, entry_path, ".mere/projection.v1");
}

fn setDiag(
    allocator: std.mem.Allocator,
    diag: ?*HashDiag,
    path_value: []const u8,
    action_value: []const u8,
    os_error: ?anyerror,
) void {
    const d = diag orelse return;
    if (d.path) |p| allocator.free(p);
    const dup_path = allocator.dupe(u8, path_value) catch {
        d.* = .{ .path = null, .action = action_value, .os_error = os_error };
        return;
    };
    d.* = .{ .path = dup_path, .action = action_value, .os_error = os_error };
}

// Spec #1: Store content hash determinism
// Spec #1: Hash output is 64 lowercase hex characters
test "calculateStoreContentHash computes deterministic hash for directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create files with known content
    const file1_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "a.txt" });
    defer std.testing.allocator.free(file1_path);
    const file2_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "b.txt" });
    defer std.testing.allocator.free(file2_path);

    {
        var f1 = try std.Io.Dir.createFileAbsolute(path.currentIo(), file1_path, .{});
        try f1.writeStreamingAll(path.currentIo(), "hello");
        f1.close(path.currentIo());
        var f2 = try std.Io.Dir.createFileAbsolute(path.currentIo(), file2_path, .{});
        try f2.writeStreamingAll(path.currentIo(), "world");
        f2.close(path.currentIo());
    }

    // Compute directory hash
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Compute again to check determinism
    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    try std.testing.expectEqualStrings(hash1, hash2);

    // Verify hash is 64 hex characters
    try std.testing.expectEqual(@as(usize, 64), hash1.len);

    // Remove a file and check hash changes
    try std.Io.Dir.deleteFileAbsolute(path.currentIo(), file2_path);
    const hash3 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash3);

    try std.testing.expect(hash1.len > 0);
    try std.testing.expect(hash3.len > 0);
    try std.testing.expect(!std.mem.eql(u8, hash1, hash3));
}

// Spec #4: Manifest and derived projection files are excluded from v2;
// canonical package metadata participates in the versioned store identity.
test "calculateStoreContentHashV2 includes meta but excludes derived metadata" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const content_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "content.txt" });
    defer std.testing.allocator.free(content_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), content_path, .{});
        try f.writeStreamingAll(path.currentIo(), "package content");
        f.close(path.currentIo());
    }

    const mere_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere" });
    defer std.testing.allocator.free(mere_dir);
    try path.ensureDirExists(mere_dir);

    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "meta.kdl" });
    defer std.testing.allocator.free(meta_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), meta_path, .{});
        try f.writeStreamingAll(path.currentIo(), "dependencies { }\nprovisions { }\n");
        f.close(path.currentIo());
    }

    const hash1 = try calculateStoreContentHashV2(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "manifest.v1" });
    defer std.testing.allocator.free(manifest_path);
    const sig_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "manifest.v1.sig" });
    defer std.testing.allocator.free(sig_path);
    const projection_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "projection.v1" });
    defer std.testing.allocator.free(projection_path);
    for ([_][]const u8{ manifest_path, sig_path, projection_path }) |file_path| {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "derived data");
        f.close(path.currentIo());
    }

    const hash2 = try calculateStoreContentHashV2(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);
    try std.testing.expectEqualStrings(hash1, hash2);

    try std.Io.Dir.deleteFileAbsolute(path.currentIo(), meta_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), meta_path, .{});
        try f.writeStreamingAll(path.currentIo(), "dependencies {\n    elf-needed \"libc.so\"\n}\n");
        f.close(path.currentIo());
    }

    const hash3 = try calculateStoreContentHashV2(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash3);
    try std.testing.expect(!std.mem.eql(u8, hash1, hash3));
}


test "store hash formats preserve v1 and distinguish transitional and v2 identities" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const content_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "content.txt" });
    defer std.testing.allocator.free(content_path);
    var content = try std.Io.Dir.createFileAbsolute(path.currentIo(), content_path, .{});
    try content.writeStreamingAll(path.currentIo(), "package content");
    content.close(path.currentIo());

    const mere_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere" });
    defer std.testing.allocator.free(mere_dir);
    try path.ensureDirExists(mere_dir);
    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "meta.kdl" });
    defer std.testing.allocator.free(meta_path);
    var metadata = try std.Io.Dir.createFileAbsolute(path.currentIo(), meta_path, .{});
    try metadata.writeStreamingAll(path.currentIo(), "dependencies { }\n");
    metadata.close(path.currentIo());

    const v1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(v1);
    const transitional = try calculateTransitionalMetadataContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(transitional);
    const v2 = try calculateStoreContentHashV2(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(v2);

    try std.testing.expect(!std.mem.eql(u8, v1, transitional));
    try std.testing.expect(!std.mem.eql(u8, transitional, v2));

    try std.Io.Dir.deleteFileAbsolute(path.currentIo(), meta_path);
    metadata = try std.Io.Dir.createFileAbsolute(path.currentIo(), meta_path, .{});
    try metadata.writeStreamingAll(path.currentIo(), "dependencies { elf-needed \"libc.so\" }\n");
    metadata.close(path.currentIo());

    const v1_after_metadata_change = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(v1_after_metadata_change);
    const transitional_after_metadata_change = try calculateTransitionalMetadataContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(transitional_after_metadata_change);
    try std.testing.expectEqualStrings(v1, v1_after_metadata_change);
    try std.testing.expect(!std.mem.eql(u8, transitional, transitional_after_metadata_change));
}

// Spec #1.1: Executable bit incorporated into hash
test "calculateStoreContentHash includes executable bit" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "script.sh" });
    defer std.testing.allocator.free(file_path);

    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho hello");
        f.close(path.currentIo());
    }

    // Hash with non-executable file
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Make file executable
    {
        var f = try path.openExistingFile(file_path);
        defer f.close(path.currentIo());
        try f.setPermissions(path.currentIo(), .fromMode(0o755));
    }

    // Hash with executable file
    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    // Hashes should differ due to executable bit
    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}

// Spec #1: Symlink targets hashed
test "calculateStoreContentHash hashes symlink targets" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file and a symlink to it.
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "target.txt" });
    defer std.testing.allocator.free(target_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), target_path, .{});
        try f.writeStreamingAll(path.currentIo(), "data");
        f.close(path.currentIo());
    }

    const link_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "link.txt" });
    defer std.testing.allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(path.currentIo(), target_path, link_path, .{});

    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Change the symlink target and verify hash changes.
    try std.Io.Dir.deleteFileAbsolute(path.currentIo(), link_path);

    const alt_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "alt.txt" });
    defer std.testing.allocator.free(alt_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), alt_path, .{});
        try f.writeStreamingAll(path.currentIo(), "data");
        f.close(path.currentIo());
    }
    try std.Io.Dir.cwd().symLink(path.currentIo(), alt_path, link_path, .{});

    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "calculateFileHash" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    // Create a test file with known content
    const test_content = "test content for hash calculation";
    const test_file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "test-file" });
    defer std.testing.allocator.free(test_file_path);

    var test_file = try std.Io.Dir.createFileAbsolute(path.currentIo(), test_file_path, .{});
    try test_file.writeStreamingAll(path.currentIo(), test_content);
    test_file.close(path.currentIo());

    // Calculate hash
    const hash = try calculateFileHash(&test_env.ctx, test_file_path);
    defer test_env.ctx.allocator.free(hash);

    // Verify hash is not null and has expected length
    try std.testing.expect(hash.len > 0);

    // Calculate expected hash manually for comparison
    var expected_hasher = std.crypto.hash.Blake3.init(.{});
    var expected_hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    expected_hasher.update(test_content);
    expected_hasher.final(&expected_hash_buffer);
    const expected_hash = try std.fmt.allocPrint(std.testing.allocator, "{x}", .{expected_hash_buffer});
    defer std.testing.allocator.free(expected_hash);

    // Verify the hash matches the expected hash
    try std.testing.expectEqualStrings(expected_hash, hash);
}

test "calculateFileHash with relative path" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    // Create a test file with known content
    const test_content = "test content for relative path hash calculation";
    const test_file_name = "relative-test-file";

    // Create the file in the test environment directory
    const test_file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, test_file_name });
    defer std.testing.allocator.free(test_file_path);

    var test_file = try std.Io.Dir.createFileAbsolute(path.currentIo(), test_file_path, .{});
    try test_file.writeStreamingAll(path.currentIo(), test_content);
    test_file.close(path.currentIo());

    // Save current working directory before switching
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd_len = try std.process.currentPath(path.currentIo(), &buf);
    const original_cwd = buf[0..original_cwd_len];
    defer std.Io.Threaded.chdir(original_cwd) catch |err| {
        test_env.ctx.debug("Failed to restore cwd: {}\n", .{err});
    };

    // Change directories to the test environment path
    try std.Io.Threaded.chdir(test_env.path);

    // Calculate hash using relative path
    const hash_relative = try calculateFileHash(&test_env.ctx, test_file_name);
    defer test_env.ctx.allocator.free(hash_relative);

    // Calculate hash using absolute path for comparison
    const hash_absolute = try calculateFileHash(&test_env.ctx, test_file_path);
    defer test_env.ctx.allocator.free(hash_absolute);

    // Verify both hashes are the same
    try std.testing.expectEqualStrings(hash_absolute, hash_relative);

    // Calculate expected hash manually for additional verification
    var expected_hasher = std.crypto.hash.Blake3.init(.{});
    var expected_hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    expected_hasher.update(test_content);
    expected_hasher.final(&expected_hash_buffer);
    const expected_hash = try std.fmt.allocPrint(std.testing.allocator, "{x}", .{expected_hash_buffer});
    defer std.testing.allocator.free(expected_hash);

    // Verify the hash matches the expected hash
    try std.testing.expectEqualStrings(expected_hash, hash_relative);
}

// Spec #1: Empty directories included in hash
test "calculateStoreContentHash includes empty directories" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "a.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "content");
        f.close(path.currentIo());
    }

    // Hash without empty directory
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Create an empty subdirectory
    const empty_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "emptydir" });
    defer std.testing.allocator.free(empty_dir);
    try path.ensureDirExists(empty_dir);

    // Hash with empty directory present
    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    // Hashes should differ because empty directories are included in the hash
    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}

// Spec #1.1: Non-executable permission bits do not affect hash
test "calculateStoreContentHash ignores non-executable permission bits" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file with default permissions
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "data.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "some data");
        f.close(path.currentIo());
    }

    // Hash with default permissions (typically 0o644)
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Change to read-only (0o444) — only non-exec bits differ
    {
        var f = try path.openExistingFile(file_path);
        defer f.close(path.currentIo());
        try f.setPermissions(path.currentIo(), .fromMode(0o444));
    }

    // Hash after permission change
    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    // Hashes should be identical — only the exec bit matters
    try std.testing.expectEqualStrings(hash1, hash2);
}

// Spec #1.1: Ownership and timestamps do not affect hash
test "calculateStoreContentHash ignores ownership and timestamps" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file with known content
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "file.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "test content");
        f.close(path.currentIo());
    }

    // Compute initial hash
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Modify file timestamps by touching the file (update access and modification times)
    // We do this by opening and closing the file, which updates atime
    // Note: We cannot easily change ownership without root privileges, but the implementation
    // demonstrates that uid/gid are never read from stat - only mode is accessed for exec bit
    {
        var f = try std.Io.Dir.openFileAbsolute(path.currentIo(), file_path, .{ .mode = .read_write });
        defer f.close(path.currentIo());
        try f.setTimestampsNow(path.currentIo());
    }

    // Compute hash after timestamp modification
    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    // Hashes should be identical - timestamps and ownership do not affect the hash
    // The hash only incorporates: path, type, exec bit, and content
    try std.testing.expectEqualStrings(hash1, hash2);
}

// Spec #1: Lexicographic sort order produces same hash regardless of file creation order
test "calculateBuildSnapshotHash includes timestamps" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "file.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "test content");
        f.close(path.currentIo());
    }

    const store_hash_before = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(store_hash_before);
    const snapshot_hash_before = try calculateBuildSnapshotHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(snapshot_hash_before);

    {
        var f = try path.openExistingFile(file_path);
        defer f.close(path.currentIo());
        try f.setTimestamps(path.currentIo(), .{
            .access_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(1_700_000_000_000_000_000) },
            .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(1_700_000_123_000_000_000) },
        });
    }

    const store_hash_after = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(store_hash_after);
    const snapshot_hash_after = try calculateBuildSnapshotHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(snapshot_hash_after);

    try std.testing.expectEqualStrings(store_hash_before, store_hash_after);
    try std.testing.expect(!std.mem.eql(u8, snapshot_hash_before, snapshot_hash_after));
}

test "calculateStoreContentHash is order-independent" {
    const th = @import("test_helpers.zig");

    // Create two separate test environments with the same files created in different order
    var test_env1 = try th.createTestEnv();
    defer {
        test_env1.cleanup();
        std.testing.allocator.destroy(test_env1);
    }

    var test_env2 = try th.createTestEnv();
    defer {
        test_env2.cleanup();
        std.testing.allocator.destroy(test_env2);
    }

    // Environment 1: create files in order a, b, c
    {
        const a = try std.fs.path.join(std.testing.allocator, &.{ test_env1.path, "a.txt" });
        defer std.testing.allocator.free(a);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), a, .{});
        try f.writeStreamingAll(path.currentIo(), "alpha");
        f.close(path.currentIo());
    }
    {
        const b = try std.fs.path.join(std.testing.allocator, &.{ test_env1.path, "b.txt" });
        defer std.testing.allocator.free(b);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), b, .{});
        try f.writeStreamingAll(path.currentIo(), "bravo");
        f.close(path.currentIo());
    }
    {
        const c = try std.fs.path.join(std.testing.allocator, &.{ test_env1.path, "c.txt" });
        defer std.testing.allocator.free(c);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), c, .{});
        try f.writeStreamingAll(path.currentIo(), "charlie");
        f.close(path.currentIo());
    }

    // Environment 2: create same files in reverse order c, b, a
    {
        const c = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, "c.txt" });
        defer std.testing.allocator.free(c);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), c, .{});
        try f.writeStreamingAll(path.currentIo(), "charlie");
        f.close(path.currentIo());
    }
    {
        const b = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, "b.txt" });
        defer std.testing.allocator.free(b);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), b, .{});
        try f.writeStreamingAll(path.currentIo(), "bravo");
        f.close(path.currentIo());
    }
    {
        const a = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, "a.txt" });
        defer std.testing.allocator.free(a);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), a, .{});
        try f.writeStreamingAll(path.currentIo(), "alpha");
        f.close(path.currentIo());
    }

    // The test environment contains random signing keys under .mere/keys;
    // remove them so this fixture compares package trees, not test homes.
    const keys1 = try std.fs.path.join(std.testing.allocator, &.{ test_env1.path, ".mere", "keys" });
    defer std.testing.allocator.free(keys1);
    const keys2 = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, ".mere", "keys" });
    defer std.testing.allocator.free(keys2);
    try path.deleteTreeAbsolute(keys1);
    try path.deleteTreeAbsolute(keys2);

    const hash1 = try calculateStoreContentHash(test_env1.ctx.allocator, test_env1.path, null);
    defer test_env1.ctx.allocator.free(hash1);

    const hash2 = try calculateStoreContentHash(test_env2.ctx.allocator, test_env2.path, null);
    defer test_env2.ctx.allocator.free(hash2);

    // Same files, same content → same hash regardless of creation order
    try std.testing.expectEqualStrings(hash1, hash2);
}

// Spec #1: Hash output is 64 lowercase hex characters (all chars in [0-9a-f])
test "calculateStoreContentHash output is all lowercase hex" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file so the hash is non-trivial
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "data.bin" });
    defer std.testing.allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "some binary \x00\x01\x02 data");
        f.close(path.currentIo());
    }

    const hash_str = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash_str);

    // Must be exactly 64 characters
    try std.testing.expectEqual(@as(usize, 64), hash_str.len);

    // Every character must be lowercase hex [0-9a-f]
    for (hash_str) |c| {
        const is_valid = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_valid);
    }
}

test "hash mapHashFsError preserves actionable classes" {
    try std.testing.expectEqual(HashError.PermissionDenied, mapHashFsError(error.AccessDenied));
    try std.testing.expectEqual(HashError.OutOfMemory, mapHashFsError(error.OutOfMemory));
    try std.testing.expectEqual(HashError.InvalidInput, mapHashFsError(error.BadPathName));
    try std.testing.expectEqual(HashError.FileSystem, mapHashFsError(error.InputOutput));
}
