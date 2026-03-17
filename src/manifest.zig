const std = @import("std");
const Context = @import("mere.zig").Context;
const sign = @import("sign.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const ManifestError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{SigningFailed};

pub const MAGIC: *const [8]u8 = "MEREMFST";
pub const SCHEMA_VERSION: u32 = 1;
pub const META_DIR = ".mere";
pub const MANIFEST_FILENAME = ".mere/manifest.v1";
pub const MANIFEST_SIG_FILENAME = ".mere/manifest.v1.sig";
pub const META_KDL_FILENAME = ".mere/meta.kdl";
pub const PROJECTION_FILENAME = ".mere/projection.v1";

pub const PackageManifestV1 = struct {
    schema_version: u32,
    created_at: u64,
    release: u32,
    arch: []const u8,
    name: []const u8,
    version: []const u8,
    content_hash: [32]u8,

    pub fn encode(self: *const PackageManifestV1, allocator: std.mem.Allocator) ManifestError![]u8 {
        const total_size = 8 + // magic
            4 + // schema_version
            8 + // created_at
            4 + // release
            4 + self.arch.len + // arch_len + arch
            4 + self.name.len + // name_len + name
            4 + self.version.len + // version_len + version
            32; // content_hash

        var buffer = allocator.alloc(u8, total_size) catch {
            return ManifestError.OutOfMemory;
        };
        errdefer allocator.free(buffer);

        var offset: usize = 0;

        @memcpy(buffer[offset..][0..8], MAGIC);
        offset += 8;

        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(self.schema_version));
        offset += 4;

        @memcpy(buffer[offset..][0..8], &std.mem.toBytes(self.created_at));
        offset += 8;

        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(self.release));
        offset += 4;

        const arch_len: u32 = @intCast(self.arch.len);
        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(arch_len));
        offset += 4;
        @memcpy(buffer[offset..][0..self.arch.len], self.arch);
        offset += self.arch.len;

        const name_len: u32 = @intCast(self.name.len);
        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(name_len));
        offset += 4;
        @memcpy(buffer[offset..][0..self.name.len], self.name);
        offset += self.name.len;

        const version_len: u32 = @intCast(self.version.len);
        @memcpy(buffer[offset..][0..4], &std.mem.toBytes(version_len));
        offset += 4;
        @memcpy(buffer[offset..][0..self.version.len], self.version);
        offset += self.version.len;

        @memcpy(buffer[offset..][0..32], &self.content_hash);

        return buffer;
    }

    pub fn decode(data: []const u8) ManifestError!PackageManifestV1 {
        if (data.len < 8 + 4 + 8 + 4 + 4 + 4 + 4 + 32) {
            return ManifestError.InvalidInput;
        }

        var offset: usize = 0;

        if (!std.mem.eql(u8, data[offset..][0..8], MAGIC)) {
            return ManifestError.InvalidInput;
        }
        offset += 8;

        const schema_version = std.mem.readInt(u32, data[offset..][0..4], .little);
        if (schema_version != SCHEMA_VERSION) {
            return ManifestError.InvalidInput;
        }
        offset += 4;

        const created_at = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const release = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (offset + 4 > data.len) return ManifestError.InvalidInput;
        const arch_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        if (arch_len > 1024 or offset + arch_len > data.len) return ManifestError.InvalidInput;
        const arch = data[offset..][0..arch_len];
        offset += arch_len;

        if (offset + 4 > data.len) return ManifestError.InvalidInput;
        const name_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        if (name_len > 1024 or offset + name_len > data.len) return ManifestError.InvalidInput;
        const name = data[offset..][0..name_len];
        offset += name_len;

        if (offset + 4 > data.len) return ManifestError.InvalidInput;
        const version_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        if (version_len > 1024 or offset + version_len > data.len) return ManifestError.InvalidInput;
        const version = data[offset..][0..version_len];
        offset += version_len;

        if (offset + 32 > data.len) return ManifestError.InvalidInput;
        var content_hash: [32]u8 = undefined;
        @memcpy(&content_hash, data[offset..][0..32]);

        return PackageManifestV1{
            .schema_version = schema_version,
            .created_at = created_at,
            .release = release,
            .arch = arch,
            .name = name,
            .version = version,
            .content_hash = content_hash,
        };
    }

    pub fn contentHashHex(self: *const PackageManifestV1, allocator: std.mem.Allocator) ManifestError![]u8 {
        return std.fmt.allocPrint(allocator, "{x}", .{self.content_hash}) catch {
            return ManifestError.OutOfMemory;
        };
    }
};

pub fn readManifestFile(ctx: *Context, dir_path: []const u8) ManifestError![]u8 {
    const manifest_path = std.fs.path.join(ctx.allocator, &.{ dir_path, MANIFEST_FILENAME }) catch {
        return ManifestError.OutOfMemory;
    };
    defer ctx.allocator.free(manifest_path);

    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ManifestError.InvalidInput,
            error.AccessDenied => ManifestError.PermissionDenied,
            else => ManifestError.FileSystem,
        };
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        return switch (err) {
            error.AccessDenied => ManifestError.PermissionDenied,
            else => ManifestError.FileSystem,
        };
    };

    if (stat.size > 1024 * 1024) {
        return ManifestError.InvalidInput;
    }

    const buffer = ctx.allocator.alloc(u8, @intCast(stat.size)) catch {
        return ManifestError.OutOfMemory;
    };
    errdefer ctx.allocator.free(buffer);

    const bytes_read = file.readAll(buffer) catch |err| {
        return switch (err) {
            error.AccessDenied => ManifestError.PermissionDenied,
            else => ManifestError.FileSystem,
        };
    };

    if (bytes_read != stat.size) {
        return ManifestError.FileSystem;
    }

    return buffer;
}

pub fn writeManifest(ctx: *Context, dir_path: []const u8, manifest: *const PackageManifestV1, secret_key: []const u8) ManifestError!void {
    const manifest_bytes = try manifest.encode(ctx.allocator);
    defer ctx.allocator.free(manifest_bytes);

    const signature = sign.signBytes(secret_key, manifest_bytes) catch {
        return ManifestError.SigningFailed;
    };

    const meta_dir_path = std.fs.path.join(ctx.allocator, &.{ dir_path, META_DIR }) catch {
        return ManifestError.OutOfMemory;
    };
    defer ctx.allocator.free(meta_dir_path);
    std.fs.cwd().makePath(meta_dir_path) catch |err| {
        return switch (err) {
            error.AccessDenied => ManifestError.PermissionDenied,
            else => ManifestError.FileSystem,
        };
    };

    const manifest_path = std.fs.path.join(ctx.allocator, &.{ dir_path, MANIFEST_FILENAME }) catch {
        return ManifestError.OutOfMemory;
    };
    defer ctx.allocator.free(manifest_path);

    {
        const file = std.fs.createFileAbsolute(manifest_path, .{}) catch |err| {
            return switch (err) {
                error.AccessDenied => ManifestError.PermissionDenied,
                else => ManifestError.FileSystem,
            };
        };
        defer file.close();
        file.writeAll(manifest_bytes) catch |err| {
            return switch (err) {
                error.AccessDenied => ManifestError.PermissionDenied,
                else => ManifestError.FileSystem,
            };
        };
    }

    const sig_path = std.fs.path.join(ctx.allocator, &.{ dir_path, MANIFEST_SIG_FILENAME }) catch {
        return ManifestError.OutOfMemory;
    };
    defer ctx.allocator.free(sig_path);

    {
        const file = std.fs.createFileAbsolute(sig_path, .{}) catch |err| {
            return switch (err) {
                error.AccessDenied => ManifestError.PermissionDenied,
                else => ManifestError.FileSystem,
            };
        };
        defer file.close();
        file.writeAll(&signature) catch |err| {
            return switch (err) {
                error.AccessDenied => ManifestError.PermissionDenied,
                else => ManifestError.FileSystem,
            };
        };
    }
}

// Tests

// Spec #17: Manifest encode/decode round-trip
test "PackageManifestV1 encode/decode roundtrip" {
    const allocator = std.testing.allocator;

    const original = PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 3,
        .arch = "x86_64",
        .name = "test-package",
        .version = "1.2.3",
        .content_hash = [_]u8{0xaa} ** 32,
    };

    const encoded = try original.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try PackageManifestV1.decode(encoded);

    try std.testing.expectEqual(@as(u32, 1), decoded.schema_version);
    try std.testing.expectEqual(@as(u64, 1706745600), decoded.created_at);
    try std.testing.expectEqual(@as(u32, 3), decoded.release);
    try std.testing.expectEqualStrings("x86_64", decoded.arch);
    try std.testing.expectEqualStrings("test-package", decoded.name);
    try std.testing.expectEqualStrings("1.2.3", decoded.version);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 32), &decoded.content_hash);
}

// Spec #17: Magic is "MEREMFST"
test "PackageManifestV1 decode rejects invalid magic" {
    var data: [100]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..8], "BADMAGIC");

    try std.testing.expectError(ManifestError.InvalidInput, PackageManifestV1.decode(&data));
}

// Spec #17: Unknown schema_version rejected
test "PackageManifestV1 decode rejects unknown schema version" {
    const allocator = std.testing.allocator;

    var manifest = PackageManifestV1{
        .schema_version = 99,
        .created_at = 1706745600,
        .release = 1,
        .arch = "x86_64",
        .name = "test",
        .version = "1.0",
        .content_hash = [_]u8{0} ** 32,
    };

    // Manually encode with wrong schema version
    const encoded = try manifest.encode(allocator);
    defer allocator.free(encoded);

    // The encoded data has schema_version=99, which should be rejected
    try std.testing.expectError(ManifestError.InvalidInput, PackageManifestV1.decode(encoded));
}

// Spec #17: Truncated data rejected
test "PackageManifestV1 decode rejects truncated data" {
    const data = "MEREMFST" ++ [_]u8{0} ** 10; // Too short
    try std.testing.expectError(ManifestError.InvalidInput, PackageManifestV1.decode(data));
}

// Spec #17: contentHashHex is 64 hex chars
test "PackageManifestV1 contentHashHex produces 64 hex chars" {
    const allocator = std.testing.allocator;

    const manifest = PackageManifestV1{
        .schema_version = 1,
        .created_at = 0,
        .release = 1,
        .arch = "any",
        .name = "test",
        .version = "1.0",
        .content_hash = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } ++ [_]u8{0} ** 24,
    };

    const hex = try manifest.contentHashHex(allocator);
    defer allocator.free(hex);

    try std.testing.expectEqual(@as(usize, 64), hex.len);
    try std.testing.expect(std.mem.startsWith(u8, hex, "0123456789abcdef"));
}

// Spec #17: Total size matches formula
test "PackageManifestV1 encoded size matches formula" {
    const allocator = std.testing.allocator;

    const manifest = PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 5,
        .arch = "x86_64",
        .name = "example-package",
        .version = "2.1.0",
        .content_hash = [_]u8{0xbb} ** 32,
    };

    const encoded = try manifest.encode(allocator);
    defer allocator.free(encoded);

    // Formula: 8 + 4 + 8 + 4 + 4 + arch.len + 4 + name.len + 4 + version.len + 32
    const expected_size = 8 + // magic
        4 + // schema_version
        8 + // created_at
        4 + // release
        4 + manifest.arch.len + // arch_len + arch
        4 + manifest.name.len + // name_len + name
        4 + manifest.version.len + // version_len + version
        32; // content_hash

    try std.testing.expectEqual(expected_size, encoded.len);
}

test "writeManifest maps makePath AccessDenied to PermissionDenied" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const key_pair = try sign.generateKeyPair();
    defer {
        var sk = key_pair.secret_key;
        sk.deinit();
    }

    const locked_parent = try std.fs.path.join(allocator, &.{ test_env.path, "locked-parent" });
    defer allocator.free(locked_parent);
    try std.fs.cwd().makePath(locked_parent);
    try std.posix.fchmodat(std.posix.AT.FDCWD, locked_parent, 0o555, 0);
    defer std.posix.fchmodat(std.posix.AT.FDCWD, locked_parent, 0o755, 0) catch {};

    const target_dir = try std.fs.path.join(allocator, &.{ locked_parent, "pkg-root" });
    defer allocator.free(target_dir);

    const manifest = PackageManifestV1{
        .schema_version = SCHEMA_VERSION,
        .created_at = 1700000000,
        .release = 1,
        .arch = "x86_64",
        .name = "pkg",
        .version = "1.0.0",
        .content_hash = [_]u8{0x42} ** 32,
    };

    try std.testing.expectError(
        ManifestError.PermissionDenied,
        writeManifest(&test_env.ctx, target_dir, &manifest, key_pair.secret_key.key[0..]),
    );
}

test "readManifestFile reports InvalidInput when manifest is missing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const package_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "pkg-missing-manifest" });
    defer test_env.ctx.allocator.free(package_dir);
    try std.fs.cwd().makePath(package_dir);

    try std.testing.expectError(ManifestError.InvalidInput, readManifestFile(&test_env.ctx, package_dir));
}
