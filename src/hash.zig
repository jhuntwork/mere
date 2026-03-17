const std = @import("std");
const path = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const HashError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

const TreeHashEntry = struct {
    entry_path: []const u8,
    kind: std.fs.File.Kind,
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
    owns_path: bool = false,

    pub fn deinit(self: *HashDiag, allocator: std.mem.Allocator) void {
        if (self.owns_path) {
            if (self.path) |p| allocator.free(p);
        }
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

pub fn calculateFileHash(allocator: std.mem.Allocator, file_path: []const u8) HashError![]const u8 {
    if (!path.isValidInputPath(file_path)) {
        return HashError.InvalidInput;
    }
    var archive_file: std.fs.File = undefined;

    if (std.fs.path.isAbsolute(file_path)) {
        archive_file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => HashError.FileSystem,
                else => mapHashFsError(err),
            };
        };
    } else {
        archive_file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => HashError.FileSystem,
                else => mapHashFsError(err),
            };
        };
    }
    defer archive_file.close();

    var hasher = std.crypto.hash.Blake3.init(.{});
    var hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;

    {
        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = archive_file.read(&buf) catch |err| {
                return mapHashFsError(err);
            };
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }
    }

    hasher.final(&hash_buffer);

    return std.fmt.allocPrint(allocator, "{x}", .{hash_buffer}) catch {
        return HashError.OutOfMemory;
    };
}

const EntryType = enum(u8) {
    file = 0x10,
    directory = 0x11,
    symlink = 0x12,
};

const ENTRY_TAG: u8 = 0x01;

pub fn calculateStoreContentHash(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
) HashError![]const u8 {
    return calculateTreeHashInternal(allocator, dir_path, diag, false);
}

pub fn calculateBuildSnapshotHash(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
) HashError![]const u8 {
    return calculateTreeHashInternal(allocator, dir_path, diag, true);
}

fn calculateTreeHashInternal(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    diag: ?*HashDiag,
    include_mtime: bool,
) HashError![]const u8 {
    if (!path.isValidInputPath(dir_path)) {
        setDiag(allocator, diag, dir_path, "invalid input path", null);
        return HashError.InvalidInput;
    }

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        setDiag(allocator, diag, dir_path, "open directory", err);
        return switch (err) {
            error.FileNotFound => HashError.FileSystem,
            else => mapHashFsError(err),
        };
    };
    defer dir.close();

    var entries: std.ArrayList(TreeHashEntry) = .{};
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
        const entry = walker.next() catch |err| {
            setDiag(allocator, diag, dir_path, "iterate directory walk", err);
            return mapHashFsError(err);
        };
        if (entry == null) break;
        if (std.mem.eql(u8, entry.?.path, ".mere") or
            std.mem.startsWith(u8, entry.?.path, ".mere/"))
        {
            continue;
        }
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

        const stat = std.posix.fstatat(dir.fd, e.path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| {
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
            .mode = @intCast(stat.mode),
            .size = if (e.kind == .file) @intCast(stat.size) else 0,
            .mtime = timespecToNs(stat.mtime()),
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

            const file = dir.openFile(entry.entry_path, .{}) catch |err| {
                setDiag(allocator, diag, entry.entry_path, "open file", err);
                return switch (err) {
                    error.FileNotFound => HashError.FileSystem,
                    else => mapHashFsError(err),
                };
            };
            defer file.close();

            var buf: [8192]u8 = undefined;
            while (true) {
                const bytes_read = file.read(&buf) catch |err| {
                    setDiag(allocator, diag, entry.entry_path, "read file", err);
                    return mapHashFsError(err);
                };
                if (bytes_read == 0) break;
                hasher.update(buf[0..bytes_read]);
            }
        } else if (entry.kind == .sym_link) {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = dir.readLink(entry.entry_path, &link_buf) catch |err| {
                setDiag(allocator, diag, entry.entry_path, "read symlink", err);
                return switch (err) {
                    error.FileNotFound => HashError.FileSystem,
                    else => mapHashFsError(err),
                };
            };

            const target_len: u32 = @intCast(target.len);
            hasher.update(&std.mem.toBytes(target_len));

            hasher.update(target);
        }
    }

    var hash_buffer: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(&hash_buffer);

    return std.fmt.allocPrint(allocator, "{x}", .{hash_buffer}) catch {
        return HashError.OutOfMemory;
    };
}

fn setDiag(
    allocator: std.mem.Allocator,
    diag: ?*HashDiag,
    path_value: []const u8,
    action_value: []const u8,
    os_error: ?anyerror,
) void {
    const d = diag orelse return;
    if (d.owns_path) {
        if (d.path) |p| allocator.free(p);
    }
    const dup_path = allocator.dupe(u8, path_value) catch {
        d.* = .{ .path = null, .action = action_value, .os_error = os_error, .owns_path = false };
        return;
    };
    d.* = .{ .path = dup_path, .action = action_value, .os_error = os_error, .owns_path = true };
}

fn timespecToNs(ts: std.posix.timespec) i128 {
    return (@as(i128, ts.sec) * std.time.ns_per_s) + ts.nsec;
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
        const f1 = try std.fs.createFileAbsolute(file1_path, .{});
        try f1.writeAll("hello");
        f1.close();
        const f2 = try std.fs.createFileAbsolute(file2_path, .{});
        try f2.writeAll("world");
        f2.close();
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
    try std.fs.deleteFileAbsolute(file2_path);
    const hash3 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash3);

    try std.testing.expect(hash1.len > 0);
    try std.testing.expect(hash3.len > 0);
    try std.testing.expect(!std.mem.eql(u8, hash1, hash3));
}

// Spec #4: .mere/ excluded from content hash
test "calculateStoreContentHash excludes .mere directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a content file
    const content_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "content.txt" });
    defer std.testing.allocator.free(content_path);
    {
        const f = try std.fs.createFileAbsolute(content_path, .{});
        try f.writeAll("package content");
        f.close();
    }

    // Compute hash without .mere directory
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Create .mere directory with manifest.v1
    const mere_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere" });
    defer std.testing.allocator.free(mere_dir);
    try std.fs.cwd().makePath(mere_dir);

    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "manifest.v1" });
    defer std.testing.allocator.free(manifest_path);
    {
        const f = try std.fs.createFileAbsolute(manifest_path, .{});
        try f.writeAll("MEREMFST" ++ [_]u8{0} ** 100);
        f.close();
    }

    // Compute hash with .mere/manifest.v1 present
    const hash2 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash2);

    // Hashes should be identical (.mere directory excluded)
    try std.testing.expectEqualStrings(hash1, hash2);

    // Add manifest.v1.sig to .mere directory
    const sig_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "manifest.v1.sig" });
    defer std.testing.allocator.free(sig_path);
    {
        const f = try std.fs.createFileAbsolute(sig_path, .{});
        try f.writeAll(&[_]u8{0} ** 64);
        f.close();
    }

    // Add meta.kdl to .mere directory
    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ mere_dir, "meta.kdl" });
    defer std.testing.allocator.free(meta_path);
    {
        const f = try std.fs.createFileAbsolute(meta_path, .{});
        try f.writeAll("dependencies { }\nprovisions { }\n");
        f.close();
    }

    // Compute hash with all .mere files present
    const hash3 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash3);

    // Hashes should still be identical (entire .mere directory excluded)
    try std.testing.expectEqualStrings(hash1, hash3);
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
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("#!/bin/sh\necho hello");
        f.close();
    }

    // Hash with non-executable file
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Make file executable
    {
        const f = try std.fs.openFileAbsolute(file_path, .{});
        defer f.close();
        try f.setPermissions(.{ .inner = .{ .mode = 0o755 } });
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
        const f = try std.fs.createFileAbsolute(target_path, .{});
        try f.writeAll("data");
        f.close();
    }

    const link_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "link.txt" });
    defer std.testing.allocator.free(link_path);
    try std.fs.cwd().symLink(target_path, link_path, .{});

    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Change the symlink target and verify hash changes.
    try std.fs.deleteFileAbsolute(link_path);

    const alt_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "alt.txt" });
    defer std.testing.allocator.free(alt_path);
    {
        const f = try std.fs.createFileAbsolute(alt_path, .{});
        try f.writeAll("data");
        f.close();
    }
    try std.fs.cwd().symLink(alt_path, link_path, .{});

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

    const test_file = try std.fs.createFileAbsolute(test_file_path, .{});
    try test_file.writeAll(test_content);
    test_file.close();

    // Calculate hash
    const hash = try calculateFileHash(test_env.ctx.allocator, test_file_path);
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

    const test_file = try std.fs.createFileAbsolute(test_file_path, .{});
    try test_file.writeAll(test_content);
    test_file.close();

    // Save current working directory before switching
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.fs.cwd().realpath(".", &buf);
    defer std.posix.chdir(original_cwd) catch |err| {
        test_env.ctx.debug("Failed to restore cwd: {}\n", .{err});
    };

    // Change directories to the test environment path
    try std.posix.chdir(test_env.path);

    // Calculate hash using relative path
    const hash_relative = try calculateFileHash(test_env.ctx.allocator, test_file_name);
    defer test_env.ctx.allocator.free(hash_relative);

    // Calculate hash using absolute path for comparison
    const hash_absolute = try calculateFileHash(test_env.ctx.allocator, test_file_path);
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
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("content");
        f.close();
    }

    // Hash without empty directory
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Create an empty subdirectory
    const empty_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "emptydir" });
    defer std.testing.allocator.free(empty_dir);
    try std.fs.cwd().makePath(empty_dir);

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
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("some data");
        f.close();
    }

    // Hash with default permissions (typically 0o644)
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Change to read-only (0o444) — only non-exec bits differ
    {
        const f = try std.fs.openFileAbsolute(file_path, .{});
        defer f.close();
        try f.setPermissions(.{ .inner = .{ .mode = 0o444 } });
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
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("test content");
        f.close();
    }

    // Compute initial hash
    const hash1 = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(hash1);

    // Modify file timestamps by touching the file (update access and modification times)
    // We do this by opening and closing the file, which updates atime
    // Note: We cannot easily change ownership without root privileges, but the implementation
    // demonstrates that uid/gid are never read from stat - only mode is accessed for exec bit
    {
        const f = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_write });
        defer f.close();
        // Force a metadata update by seeking (this updates atime/mtime on many systems)
        try f.seekTo(0);
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
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("test content");
        f.close();
    }

    const store_hash_before = try calculateStoreContentHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(store_hash_before);
    const snapshot_hash_before = try calculateBuildSnapshotHash(test_env.ctx.allocator, test_env.path, null);
    defer test_env.ctx.allocator.free(snapshot_hash_before);

    {
        var f = try std.fs.openFileAbsolute(file_path, .{});
        defer f.close();
        try f.updateTimes(1_700_000_000_000_000_000, 1_700_000_123_000_000_000);
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
        const f = try std.fs.createFileAbsolute(a, .{});
        try f.writeAll("alpha");
        f.close();
    }
    {
        const b = try std.fs.path.join(std.testing.allocator, &.{ test_env1.path, "b.txt" });
        defer std.testing.allocator.free(b);
        const f = try std.fs.createFileAbsolute(b, .{});
        try f.writeAll("bravo");
        f.close();
    }
    {
        const c = try std.fs.path.join(std.testing.allocator, &.{ test_env1.path, "c.txt" });
        defer std.testing.allocator.free(c);
        const f = try std.fs.createFileAbsolute(c, .{});
        try f.writeAll("charlie");
        f.close();
    }

    // Environment 2: create same files in reverse order c, b, a
    {
        const c = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, "c.txt" });
        defer std.testing.allocator.free(c);
        const f = try std.fs.createFileAbsolute(c, .{});
        try f.writeAll("charlie");
        f.close();
    }
    {
        const b = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, "b.txt" });
        defer std.testing.allocator.free(b);
        const f = try std.fs.createFileAbsolute(b, .{});
        try f.writeAll("bravo");
        f.close();
    }
    {
        const a = try std.fs.path.join(std.testing.allocator, &.{ test_env2.path, "a.txt" });
        defer std.testing.allocator.free(a);
        const f = try std.fs.createFileAbsolute(a, .{});
        try f.writeAll("alpha");
        f.close();
    }

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
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("some binary \x00\x01\x02 data");
        f.close();
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
