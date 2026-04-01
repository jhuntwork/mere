const std = @import("std");
const sign_crypto = @import("sign_crypto.zig");
const path = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const SignIOError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    FileAlreadyExists,
    InvalidSize,
};

const key_magic = [8]u8{ 'M', 'E', 'R', 'E', 'K', 'E', 'Y', 0 };
const key_version: u8 = 1;
const key_algorithm_ed25519: u8 = 1;

const KeyKind = enum(u8) {
    public = 1,
    secret = 2,
};

const key_header_size = 16;

fn mapOpenOrCreateError(err: anyerror) SignIOError {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => SignIOError.PermissionDenied,
        error.OutOfMemory => SignIOError.OutOfMemory,
        error.NameTooLong, error.InvalidUtf8, error.BadPathName => SignIOError.InvalidInput,
        else => SignIOError.FileSystem,
    };
}

fn mapReadOrWriteError(err: anyerror) SignIOError {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => SignIOError.PermissionDenied,
        else => SignIOError.FileSystem,
    };
}

fn readFixedSizeFile(comptime N: usize, file_path: []const u8) SignIOError![N]u8 {
    const io = path.currentIo();
    const file = path.openExistingFile(file_path) catch |err| {
        return mapOpenOrCreateError(err);
    };
    defer file.close(io);
    var data: [N]u8 = undefined;
    const n = file.readPositionalAll(io, &data, 0) catch |err| return mapReadOrWriteError(err);
    if (n != N) return SignIOError.InvalidSize;
    var extra: [1]u8 = undefined;
    const extra_n = file.readPositionalAll(io, &extra, N) catch |err| return mapReadOrWriteError(err);
    if (extra_n != 0) return SignIOError.InvalidSize;
    return data;
}

fn readKeyFile(
    comptime kind: KeyKind,
    comptime N: usize,
    file_path: []const u8,
) SignIOError![N]u8 {
    const io = path.currentIo();
    const file = path.openExistingFile(file_path) catch |err| {
        return mapOpenOrCreateError(err);
    };
    defer file.close(io);

    var header: [key_header_size]u8 = undefined;
    const header_n = file.readPositionalAll(io, &header, 0) catch |err| return mapReadOrWriteError(err);
    if (header_n != header.len) return SignIOError.InvalidSize;
    if (!std.mem.eql(u8, header[0..key_magic.len], key_magic[0..])) return SignIOError.InvalidSize;
    if (header[8] != key_version) return SignIOError.InvalidSize;
    if (header[9] != @intFromEnum(kind)) return SignIOError.InvalidSize;
    if (header[10] != key_algorithm_ed25519) return SignIOError.InvalidSize;

    const payload_len = std.mem.readInt(u32, header[12..16], .little);
    if (payload_len != N) return SignIOError.InvalidSize;

    var data: [N]u8 = undefined;
    const n = file.readPositionalAll(io, &data, key_header_size) catch |err| return mapReadOrWriteError(err);
    if (n != N) return SignIOError.InvalidSize;

    var extra: [1]u8 = undefined;
    const extra_n = file.readPositionalAll(io, &extra, key_header_size + N) catch |err| return mapReadOrWriteError(err);
    if (extra_n != 0) return SignIOError.InvalidSize;
    return data;
}

fn writeKeyFile(
    comptime kind: KeyKind,
    file_path: []const u8,
    data: []const u8,
    create_flags: std.Io.File.CreateFlags,
) SignIOError!void {
    const io = path.currentIo();
    var header: [key_header_size]u8 = undefined;
    @memcpy(header[0..key_magic.len], key_magic[0..]);
    header[8] = key_version;
    header[9] = @intFromEnum(kind);
    header[10] = key_algorithm_ed25519;
    header[11] = 0;
    std.mem.writeInt(u32, header[12..16], @intCast(data.len), .little);

    const out = if (std.fs.path.isAbsolute(file_path))
        std.Io.Dir.createFileAbsolute(io, file_path, create_flags) catch |err| return mapOpenOrCreateError(err)
    else
        std.Io.Dir.cwd().createFile(io, file_path, create_flags) catch |err| return mapOpenOrCreateError(err);
    defer out.close(io);

    out.writeStreamingAll(io, &header) catch |err| return mapReadOrWriteError(err);
    out.writeStreamingAll(io, data) catch |err| return mapReadOrWriteError(err);
}

pub fn readPublicKeyFile(file_path: []const u8) SignIOError![sign_crypto.c.crypto_sign_PUBLICKEYBYTES]u8 {
    return readKeyFile(.public, sign_crypto.c.crypto_sign_PUBLICKEYBYTES, file_path);
}

pub fn readSecretKeyFile(file_path: []const u8) SignIOError![sign_crypto.c.crypto_sign_SECRETKEYBYTES]u8 {
    return readKeyFile(.secret, sign_crypto.c.crypto_sign_SECRETKEYBYTES, file_path);
}

pub fn readSignatureFile(file_path: []const u8) SignIOError![sign_crypto.c.crypto_sign_BYTES]u8 {
    return readFixedSizeFile(sign_crypto.c.crypto_sign_BYTES, file_path);
}

pub fn readRawFile(file_path: []const u8) SignIOError![]u8 {
    const io = path.currentIo();
    const file = path.openExistingFile(file_path) catch |err| {
        return mapOpenOrCreateError(err);
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| return mapReadOrWriteError(err);
    const size = stat.size;
    if (size > 1024 * 1024) return SignIOError.InvalidSize;

    const buffer = std.heap.page_allocator.alloc(u8, size) catch return SignIOError.OutOfMemory;
    errdefer std.heap.page_allocator.free(buffer);

    const n = file.readPositionalAll(io, buffer, 0) catch |err| return mapReadOrWriteError(err);
    if (n != size) return SignIOError.FileSystem;

    return buffer;
}

pub fn writeSignatureFileRaw(file_path: []const u8, data: []const u8) SignIOError!void {
    if (data.len != sign_crypto.c.crypto_sign_BYTES) return SignIOError.InvalidSize;
    const io = path.currentIo();
    path.ensureParent(file_path) catch |err| return mapOpenOrCreateError(err);
    const out = if (std.fs.path.isAbsolute(file_path))
        std.Io.Dir.createFileAbsolute(io, file_path, .{ .truncate = true }) catch |err| return mapOpenOrCreateError(err)
    else
        std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true }) catch |err| return mapOpenOrCreateError(err);
    defer out.close(io);
    out.writeStreamingAll(io, data) catch |err| return mapReadOrWriteError(err);
    return;
}

pub fn writePublicKeyFile(file_path: []const u8, data: []const u8) SignIOError!void {
    if (data.len != sign_crypto.c.crypto_sign_PUBLICKEYBYTES) return SignIOError.InvalidSize;
    if (path.fileExists(file_path)) return SignIOError.FileAlreadyExists;
    path.ensureParent(file_path) catch |err| return mapOpenOrCreateError(err);
    return writeKeyFile(.public, file_path, data, .{ .exclusive = true });
}

pub fn writeSecretKeyFile(file_path: []const u8, data: []const u8) SignIOError!void {
    if (data.len != sign_crypto.c.crypto_sign_SECRETKEYBYTES) return SignIOError.InvalidSize;
    if (path.fileExists(file_path)) return SignIOError.FileAlreadyExists;
    path.ensureParent(file_path) catch |err| return mapOpenOrCreateError(err);

    const dirname = std.fs.path.dirname(file_path) orelse ".";
    const basename = std.fs.path.basename(file_path);
    const tmp_name = std.fmt.allocPrint(std.heap.page_allocator, ".{s}.tmp", .{basename}) catch return SignIOError.OutOfMemory;
    defer std.heap.page_allocator.free(tmp_name);

    const tmp_path = std.fs.path.join(std.heap.page_allocator, &.{ dirname, tmp_name }) catch return SignIOError.OutOfMemory;
    defer std.heap.page_allocator.free(tmp_path);

    writeKeyFile(.secret, tmp_path, data, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| return err;
    errdefer {
        const io = path.currentIo();
        if (std.fs.path.isAbsolute(tmp_path)) {
            std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        }
    }

    const io = path.currentIo();
    if (std.fs.path.isAbsolute(file_path)) {
        std.Io.Dir.renameAbsolute(tmp_path, file_path, io) catch |err| return mapOpenOrCreateError(err);
    } else {
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), file_path, io) catch |err| return mapOpenOrCreateError(err);
    }
    return;
}

test "sign_io: writeSignatureFileRaw and readSignatureFile roundtrip" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const sig_path = try std.fs.path.join(testing.allocator, &.{ dir, "test.sig" });
    defer testing.allocator.free(sig_path);

    // Prepare signature-sized data
    var data: [sign_crypto.c.crypto_sign_BYTES]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        data[i] = 0xAA;
    }

    try writeSignatureFileRaw(sig_path, data[0..]);

    const read_sig = try readSignatureFile(sig_path);
    try testing.expectEqualSlices(u8, &data, &read_sig);

    // Writing again should overwrite the existing file
    var overwrite: [sign_crypto.c.crypto_sign_BYTES]u8 = undefined;
    @memset(overwrite[0..], 0xBB);
    try writeSignatureFileRaw(sig_path, overwrite[0..]);

    const read_overwrite = try readSignatureFile(sig_path);
    try testing.expectEqualSlices(u8, &overwrite, &read_overwrite);
}

test "sign_io: writePublicKeyFile and readPublicKeyFile roundtrip" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const pub_path = try std.fs.path.join(testing.allocator, &.{ dir, "test.pub" });
    defer testing.allocator.free(pub_path);

    // Prepare public key-sized data
    var pub_key: [sign_crypto.c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    var i: usize = 0;
    while (i < pub_key.len) : (i += 1) {
        pub_key[i] = 0x55;
    }

    try writePublicKeyFile(pub_path, pub_key[0..]);

    const read_pub = try readPublicKeyFile(pub_path);
    try testing.expectEqualSlices(u8, &pub_key, &read_pub);

    // Attempting to write again should return FileAlreadyExists
    try testing.expectError(SignIOError.FileAlreadyExists, writePublicKeyFile(pub_path, pub_key[0..]));
}

test "sign_io: readSecretKeyFile rejects invalid sizes" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const sec_path = try std.fs.path.join(testing.allocator, &.{ dir, "short.key" });
    defer testing.allocator.free(sec_path);

    // Create a too-short file
    const f = try tmp.dir.createFile(path.currentIo(), "short.key", .{});
    try f.writeStreamingAll(path.currentIo(), "short");
    f.close(path.currentIo());

    try testing.expectError(SignIOError.InvalidSize, readSecretKeyFile(sec_path));
}

test "sign_io: oversized fixed-size files are rejected" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const pub_path = try std.fs.path.join(testing.allocator, &.{ dir, "oversized.pub" });
    defer testing.allocator.free(pub_path);

    const pub_file = try std.Io.Dir.createFileAbsolute(path.currentIo(), pub_path, .{});
    defer pub_file.close(path.currentIo());

    var oversized: [sign_crypto.c.crypto_sign_PUBLICKEYBYTES + 1]u8 = undefined;
    @memset(&oversized, 0x33);
    try pub_file.writeStreamingAll(path.currentIo(), &oversized);

    try testing.expectError(SignIOError.InvalidSize, readPublicKeyFile(pub_path));
}

test "sign_io: missing files return FileNotFound" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const missing_pub = try std.fs.path.join(testing.allocator, &.{ dir, "does-not-exist.pub" });
    defer testing.allocator.free(missing_pub);

    try testing.expectError(SignIOError.FileSystem, readPublicKeyFile(missing_pub));
    try testing.expectError(SignIOError.FileSystem, readSecretKeyFile(missing_pub));
    try testing.expectError(SignIOError.FileSystem, readSignatureFile(missing_pub));
}

test "sign_io: readPublicKeyFile reports permission denied" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const pub_path = try std.fs.path.join(testing.allocator, &.{ dir, "restricted.pub" });
    defer testing.allocator.free(pub_path);

    var pub_key: [sign_crypto.c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    @memset(pub_key[0..], 0x11);

    const file = try std.Io.Dir.createFileAbsolute(path.currentIo(), pub_path, .{});
    defer file.close(path.currentIo());
    try file.writeStreamingAll(path.currentIo(), pub_key[0..]);
    try file.setPermissions(path.currentIo(), .fromMode(0o000));

    try testing.expectError(SignIOError.PermissionDenied, readPublicKeyFile(pub_path));
}

test "sign_io: writePublicKeyFile reports permission denied" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(path.currentIo(), "ro");
    var ro = try tmp.dir.openDir(path.currentIo(), "ro", .{ .iterate = true });
    defer ro.close(path.currentIo());
    try ro.setPermissions(path.currentIo(), .fromMode(0o555));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];
    const pub_path = try std.fs.path.join(testing.allocator, &.{ dir, "ro", "blocked.pub" });
    defer testing.allocator.free(pub_path);

    var pub_key: [sign_crypto.c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    @memset(pub_key[0..], 0x44);

    try testing.expectError(SignIOError.PermissionDenied, writePublicKeyFile(pub_path, pub_key[0..]));
}

test "sign_io: writeSecretKeyFile reports permission denied" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(path.currentIo(), "ro");
    var ro = try tmp.dir.openDir(path.currentIo(), "ro", .{ .iterate = true });
    defer ro.close(path.currentIo());
    try ro.setPermissions(path.currentIo(), .fromMode(0o555));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];
    const sec_path = try std.fs.path.join(testing.allocator, &.{ dir, "ro", "blocked.key" });
    defer testing.allocator.free(sec_path);

    var sec_key: [sign_crypto.c.crypto_sign_SECRETKEYBYTES]u8 = undefined;
    @memset(sec_key[0..], 0x77);

    try testing.expectError(SignIOError.PermissionDenied, writeSecretKeyFile(sec_path, sec_key[0..]));
}

test "sign_io: writeSecretKeyFile leaves no partial target on failure" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const testing = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(path.currentIo(), "ro");
    var ro = try tmp.dir.openDir(path.currentIo(), "ro", .{ .iterate = true });
    defer ro.close(path.currentIo());
    try ro.setPermissions(path.currentIo(), .fromMode(0o555));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];
    const sec_path = try std.fs.path.join(testing.allocator, &.{ dir, "ro", "blocked.key" });
    defer testing.allocator.free(sec_path);

    var sec_key: [sign_crypto.c.crypto_sign_SECRETKEYBYTES]u8 = undefined;
    @memset(sec_key[0..], 0x88);

    try testing.expectError(SignIOError.PermissionDenied, writeSecretKeyFile(sec_path, sec_key[0..]));
    try testing.expect(!path.fileExists(sec_path));
}

test "sign_io: writeSecretKeyFile creates file with owner-only permissions" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];
    const sec_path = try std.fs.path.join(testing.allocator, &.{ dir, "secure.key" });
    defer testing.allocator.free(sec_path);

    var sec_key: [sign_crypto.c.crypto_sign_SECRETKEYBYTES]u8 = undefined;
    @memset(sec_key[0..], 0x99);

    try writeSecretKeyFile(sec_path, sec_key[0..]);

    const file = try std.Io.Dir.openFileAbsolute(path.currentIo(), sec_path, .{});
    defer file.close(path.currentIo());
    const stat = try file.stat(path.currentIo());

    try testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "sign_io: wrapped key files reject raw payloads" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const dir = buf[0..dir_len];

    const pub_path = try std.fs.path.join(testing.allocator, &.{ dir, "raw.pub" });
    defer testing.allocator.free(pub_path);

    const file = try std.Io.Dir.createFileAbsolute(path.currentIo(), pub_path, .{});
    defer file.close(path.currentIo());

    var pub_key: [sign_crypto.c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    @memset(pub_key[0..], 0x12);
    try file.writeStreamingAll(path.currentIo(), pub_key[0..]);

    try testing.expectError(SignIOError.InvalidSize, readPublicKeyFile(pub_path));
}
