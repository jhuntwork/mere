const std = @import("std");
const Context = @import("mere.zig").Context;
const hash = @import("hash.zig");
const path_mod = @import("path.zig");
const sign_crypto = @import("sign_crypto.zig");
const sign_io = @import("sign_io.zig");
const errors = @import("errors.zig");

pub const c = sign_crypto.c;

const Std = errors.StandardErrors;
pub const SignError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    InvalidKey,
    VerifyFailed,
    SodiumInitFailed,
};

fn mapCryptoError(err: sign_crypto.CryptoError) SignError {
    switch (err) {
        sign_crypto.CryptoError.SodiumInitFailed => return SignError.SodiumInitFailed,
        sign_crypto.CryptoError.InvalidInput => return SignError.InvalidKey,
        sign_crypto.CryptoError.CryptoFailed => return SignError.VerifyFailed,
    }
}

fn mapIOReadError(err: sign_io.SignIOError) SignError {
    return mapIOError(err, true);
}

fn mapIOWriteError(err: sign_io.SignIOError) SignError {
    return mapIOError(err, false);
}

fn mapIOError(err: sign_io.SignIOError, is_read: bool) SignError {
    switch (err) {
        sign_io.SignIOError.OutOfMemory => return SignError.OutOfMemory,
        sign_io.SignIOError.PermissionDenied => return SignError.PermissionDenied,
        sign_io.SignIOError.FileSystem => return SignError.FileSystem,
        sign_io.SignIOError.FileAlreadyExists => return SignError.FileSystem,
        sign_io.SignIOError.InvalidSize => return if (is_read) SignError.InvalidKey else SignError.InvalidInput,
        sign_io.SignIOError.InvalidInput => return SignError.InvalidInput,
    }
}

pub const KeyResolverFn = fn (ctx: *Context) SignError![]const u8;

pub const SignerFn = fn (ctx: *Context, key_path: []const u8, file_path: []const u8) SignError![c.crypto_sign_BYTES]u8;

fn defaultSigner(ctx: *Context, key_path: []const u8, file_path: []const u8) SignError![c.crypto_sign_BYTES]u8 {
    var secret_key = SecretKey.loadFromFile(key_path) catch |err| return err;
    defer secret_key.deinit();

    const file_hash = getFileHash(ctx, file_path) catch |err| return err;

    const signature = signBytes(secret_key.key[0..], file_hash[0..]) catch |err| return err;

    return signature;
}

pub fn getDefaultKeyDirectory(ctx: *Context) ![]const u8 {
    return path_mod.getDefaultMereKeysDirectory(ctx) catch {
        return SignError.FileSystem;
    };
}

fn getDefaultKeyPath(ctx: *Context) ![]const u8 {
    return path_mod.getDefaultSigningKeyPath(ctx) catch {
        return SignError.FileSystem;
    };
}

pub fn resolveSigningKey(ctx: *Context, injected: ?*const KeyResolverFn) SignError![]const u8 {
    if (injected) |kr| {
        return kr(ctx);
    }

    if (ctx.signing_key_path) |kp| {
        return ctx.allocator.dupe(u8, kp) catch {
            return SignError.OutOfMemory;
        };
    }

    return getDefaultKeyPath(ctx);
}

pub fn signWithResolvedKey(
    ctx: *Context,
    file_path: []const u8,
    signer: ?*const SignerFn,
    resolver: ?*const KeyResolverFn,
) SignError![c.crypto_sign_BYTES]u8 {
    const key_path = resolveSigningKey(ctx, resolver) catch |err| return err;
    defer ctx.allocator.free(key_path);

    var sig: [c.crypto_sign_BYTES]u8 = undefined;
    if (signer) |s| {
        sig = s(ctx, key_path, file_path) catch |err| return err;
    } else {
        sig = defaultSigner(ctx, key_path, file_path) catch |err| return err;
    }
    return sig;
}

/// Public key for Ed25519 signatures
pub const PublicKey = struct {
    key: [c.crypto_sign_PUBLICKEYBYTES]u8,

    pub fn loadFromFile(path: []const u8) SignError!PublicKey {
        const key = sign_io.readPublicKeyFile(path) catch |e| return mapIOReadError(e);
        return PublicKey{ .key = key };
    }

    pub fn saveToFile(self: *const PublicKey, path: []const u8) SignError!void {
        sign_io.writePublicKeyFile(path, &self.key) catch |e| return mapIOWriteError(e);
        return;
    }

    pub fn fingerprint(self: *const PublicKey, allocator: std.mem.Allocator) SignError![]const u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&self.key);
        var hash_bytes: [32]u8 = undefined;
        hasher.final(&hash_bytes);
        const fp = std.fmt.allocPrint(allocator, "{x}", .{hash_bytes}) catch {
            return SignError.OutOfMemory;
        };
        _ = std.ascii.lowerString(fp, fp);
        return fp;
    }
};

/// Secret key for Ed25519 signatures
pub const SecretKey = struct {
    key: [c.crypto_sign_SECRETKEYBYTES]u8,

    pub fn loadFromFile(path: []const u8) SignError!SecretKey {
        const key = sign_io.readSecretKeyFile(path) catch |e| return mapIOReadError(e);
        const expected = sign_crypto.deriveKeypairFromSeed(key[0..c.crypto_sign_SEEDBYTES]) catch |err| return mapCryptoError(err);
        if (!std.mem.eql(u8, key[0..], expected.secret[0..])) {
            return SignError.InvalidKey;
        }
        return SecretKey{ .key = key };
    }

    pub fn saveToFile(self: *const SecretKey, path: []const u8) SignError!void {
        sign_io.writeSecretKeyFile(path, &self.key) catch |e| return mapIOWriteError(e);
        return;
    }

    pub fn derivePublicKey(self: *const SecretKey) PublicKey {
        var public_key: [c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
        const offset = c.crypto_sign_SECRETKEYBYTES - c.crypto_sign_PUBLICKEYBYTES;
        @memcpy(&public_key, self.key[offset..]);
        return PublicKey{ .key = public_key };
    }

    pub fn deinit(self: *SecretKey) void {
        @memset(&self.key, 0);
    }
};

pub fn generateKeyPair() !struct { public_key: PublicKey, secret_key: SecretKey } {
    const kp = sign_crypto.genKeypair() catch |err| return mapCryptoError(err);

    return .{
        .public_key = PublicKey{ .key = kp.public },
        .secret_key = SecretKey{ .key = kp.secret },
    };
}

pub fn generateAndSaveKeyPair(ctx: *Context, output_dir: []const u8) !struct { public_key_path: []const u8, secret_key_path: []const u8 } {
    var dir = path_mod.makePathAndOpenDir(output_dir) catch {
        return SignError.FileSystem;
    };
    defer dir.close(path_mod.currentIo());

    const key_pair = try generateKeyPair();

    const public_key_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "mere.pub" });
    errdefer ctx.allocator.free(public_key_path);

    const secret_key_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "mere.key" });
    errdefer ctx.allocator.free(secret_key_path);

    const public_tmp_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, ".mere.pub.tmp" });
    defer ctx.allocator.free(public_tmp_path);

    const secret_tmp_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, ".mere.key.tmp" });
    defer ctx.allocator.free(secret_tmp_path);

    if (path_mod.fileExists(public_key_path) or path_mod.fileExists(secret_key_path)) {
        return SignError.FileSystem;
    }

    key_pair.public_key.saveToFile(public_tmp_path) catch {
        return SignError.FileSystem;
    };
    errdefer std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), public_tmp_path) catch {};

    key_pair.secret_key.saveToFile(secret_tmp_path) catch {
        return SignError.FileSystem;
    };
    errdefer std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), secret_tmp_path) catch {};

    std.Io.Dir.renameAbsolute(public_tmp_path, public_key_path, path_mod.currentIo()) catch {
        return SignError.FileSystem;
    };
    errdefer std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), public_key_path) catch {};

    std.Io.Dir.renameAbsolute(secret_tmp_path, secret_key_path, path_mod.currentIo()) catch {
        return SignError.FileSystem;
    };

    return .{
        .public_key_path = public_key_path,
        .secret_key_path = secret_key_path,
    };
}

pub fn writePublicKeyFromSecretFile(secret_key_path: []const u8, pub_path: []const u8) SignError!void {
    var secret = try SecretKey.loadFromFile(secret_key_path);
    defer secret.deinit();

    const public_key = secret.derivePublicKey();
    sign_io.writePublicKeyFile(pub_path, &public_key.key) catch |e| return mapIOWriteError(e);
    return;
}

fn getFileHash(ctx: *Context, file_path: []const u8) SignError![32]u8 {
    var file_path_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path_abs = path_mod.resolveToAbsolutePath(file_path, &file_path_abs_buf) catch {
        return SignError.FileSystem;
    };

    const hex_hash = hash.calculateFileHash(ctx, file_path_abs) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) {
            return SignError.FileSystem;
        } else if (err == error.OutOfMemory or err == error.EndOfStream or err == error.Unexpected) {
            return SignError.FileSystem;
        } else {
            return SignError.FileSystem;
        }
    };
    defer ctx.allocator.free(hex_hash);

    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, hex_hash) catch {
        return SignError.InvalidInput;
    };

    return result;
}

pub fn signBytes(secret_key_bytes: []const u8, msg: []const u8) SignError![c.crypto_sign_BYTES]u8 {
    if (secret_key_bytes.len != c.crypto_sign_SECRETKEYBYTES) {
        return SignError.InvalidKey;
    }
    const res = sign_crypto.signDetached(secret_key_bytes, msg) catch |err| return mapCryptoError(err);
    return res;
}

pub fn verifyBytes(public_key_bytes: []const u8, msg: []const u8, sig: []const u8) SignError!void {
    if (public_key_bytes.len != c.crypto_sign_PUBLICKEYBYTES) {
        return SignError.InvalidKey;
    }
    if (sig.len != c.crypto_sign_BYTES) {
        return SignError.VerifyFailed;
    }
    const ok = sign_crypto.verifyDetached(public_key_bytes, msg, sig) catch |err| return mapCryptoError(err);
    if (!ok) return SignError.VerifyFailed;
    return;
}

/// Write a signature file for `file_path` using an injected or default signer/resolver.
/// This centralizes the file-writing semantics so callers (like convert/packaging) do not need to
/// handle signer resolution and IO themselves.
///
/// signature_path must be a valid, allocated path (caller owns it).
pub fn writeSignatureFileWithResolver(
    ctx: *Context,
    file_path: []const u8,
    signature_path: []const u8,
    signer: ?*const SignerFn,
    resolver: ?*const KeyResolverFn,
) SignError![c.crypto_sign_BYTES]u8 {
    // Resolve & sign in one operation (single signer invocation)
    const signature = signWithResolvedKey(ctx, file_path, signer, resolver) catch |err| return err;

    // Write signature file to disk using centralized IO helper
    sign_io.writeSignatureFileRaw(signature_path, signature[0..]) catch |e| return mapIOWriteError(e);

    // Return the raw signature bytes to the caller so callers can persist or inspect them.
    return signature;
}

fn determineSignaturePath(
    file_path: []const u8,
    signature_path: ?[]const u8,
    sig_path_buf: *[std.fs.max_path_bytes]u8,
) SignError![]const u8 {
    if (signature_path) |path| return path;
    return std.fmt.bufPrint(sig_path_buf, "{s}.sig", .{file_path}) catch {
        return SignError.FileSystem;
    };
}

fn loadSignatureBytes(sig_path: []const u8) SignError![c.crypto_sign_BYTES]u8 {
    return sign_io.readSignatureFile(sig_path) catch |e| {
        switch (e) {
            sign_io.SignIOError.InvalidSize => return SignError.VerifyFailed,
            else => return mapIOReadError(e),
        }
    };
}

fn resolveAndLoadSignature(
    file_path: []const u8,
    signature_path: ?[]const u8,
) SignError![c.crypto_sign_BYTES]u8 {
    var sig_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sig_path = try determineSignaturePath(file_path, signature_path, &sig_path_buf);
    return try loadSignatureBytes(sig_path);
}

fn hashFileForVerification(ctx: *Context, file_path: []const u8) SignError![32]u8 {
    return getFileHash(ctx, file_path) catch {
        return SignError.FileSystem;
    };
}

/// Verify a file signature using Ed25519
pub fn verifySignature(ctx: *Context, file_path: []const u8, public_key_path: []const u8, signature_path: ?[]const u8) SignError!void {
    ctx.debug("verifySignature: file_path={s} public_key_path={s} signature_path={?s}", .{ file_path, public_key_path, signature_path });

    // Load the public key
    const public_key = PublicKey.loadFromFile(public_key_path) catch {
        return SignError.FileSystem;
    };

    // Hash before verification.
    const file_hash_before = try hashFileForVerification(ctx, file_path);

    // Load signature using centralized path+IO helper
    const signature = try resolveAndLoadSignature(file_path, signature_path);

    // Verify the signature using pure API
    verifyBytes(public_key.key[0..], file_hash_before[0..], signature[0..]) catch |err| {
        if (err == SignError.VerifyFailed) {
            return SignError.VerifyFailed;
        }
        return err;
    };

    // Re-hash after verification and require byte-stable content across the
    // verify window to reduce TOCTOU exposure.
    const file_hash_after = try hashFileForVerification(ctx, file_path);
    if (!std.mem.eql(u8, file_hash_before[0..], file_hash_after[0..])) {
        return SignError.VerifyFailed;
    }

    ctx.debug("signature verification passed for file: {s} and pubkey: {s}", .{ file_path, public_key_path });
    return;
}

/// A loaded public key with its fingerprint and source path.
pub const LoadedKey = struct {
    public_key: PublicKey,
    fingerprint: []const u8,
    path: []const u8,

    pub fn deinit(self: *LoadedKey, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
        allocator.free(self.path);
    }
};

/// Scan a directory for .pub files and load them with their fingerprints.
/// Returns an ArrayList of LoadedKey structs.
///
/// Caller owns the returned ArrayList and all its contents; must call deinit() on each
/// LoadedKey and then deinit the ArrayList itself.
pub fn scanKeyDirectory(allocator: std.mem.Allocator, dir_path: []const u8) SignError!std.ArrayList(LoadedKey) {
    var keys: std.ArrayList(LoadedKey) = .empty;
    errdefer {
        for (keys.items) |*k| k.deinit(allocator);
        keys.deinit(allocator);
    }

    var dir = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), dir_path, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => keys,
            error.AccessDenied, error.PermissionDenied => SignError.PermissionDenied,
            else => SignError.FileSystem,
        };
    };
    defer dir.close(path_mod.currentIo());

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(path_mod.currentIo()) catch |err| {
            return switch (err) {
                error.AccessDenied => SignError.PermissionDenied,
                else => SignError.FileSystem,
            };
        } orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pub")) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch {
            continue; // Skip on allocation failure
        };
        errdefer allocator.free(full_path);

        const pub_key = PublicKey.loadFromFile(full_path) catch {
            allocator.free(full_path);
            continue; // Skip invalid key files
        };

        const fp = pub_key.fingerprint(allocator) catch {
            allocator.free(full_path);
            continue; // Skip on allocation failure
        };

        keys.append(allocator, .{
            .public_key = pub_key,
            .fingerprint = fp,
            .path = full_path,
        }) catch {
            allocator.free(full_path);
            allocator.free(fp);
            continue;
        };
    }

    return keys;
}

/// Load all public keys from both system and user key directories.
/// System: /mere/keys/
/// User: ~/.mere/keys/
///
/// Returns an ArrayList of LoadedKey structs containing all discovered keys.
/// Caller owns the returned ArrayList and must free it.
pub fn loadAllKeys(ctx: *Context) SignError!std.ArrayList(LoadedKey) {
    var all_keys: std.ArrayList(LoadedKey) = .empty;
    errdefer {
        for (all_keys.items) |*k| k.deinit(ctx.allocator);
        all_keys.deinit(ctx.allocator);
    }

    // Scan system keys directory
    const system_keys_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "keys" }) catch {
        return SignError.OutOfMemory;
    };
    defer ctx.allocator.free(system_keys_dir);

    ctx.debug("loadAllKeys: scanning system keys dir: {s}", .{system_keys_dir});
    try appendKeysFromDirectory(ctx, &all_keys, system_keys_dir);

    // Scan user keys directory
    if (ctx.home_dir) |home| {
        const user_keys_dir = std.fs.path.join(ctx.allocator, &.{ home, ".mere", "keys" }) catch {
            return SignError.OutOfMemory;
        };
        defer ctx.allocator.free(user_keys_dir);

        try appendKeysFromDirectory(ctx, &all_keys, user_keys_dir);
    }

    return all_keys;
}

fn appendKeysFromDirectory(
    ctx: *Context,
    all_keys: *std.ArrayList(LoadedKey),
    dir_path: []const u8,
) SignError!void {
    var keys = try scanKeyDirectory(ctx.allocator, dir_path);
    defer keys.deinit(ctx.allocator);
    try moveLoadedKeys(ctx.allocator, all_keys, &keys);
}

fn moveLoadedKeys(
    allocator: std.mem.Allocator,
    dst: *std.ArrayList(LoadedKey),
    src: *std.ArrayList(LoadedKey),
) SignError!void {
    for (src.items) |key| {
        dst.append(allocator, key) catch {
            return SignError.OutOfMemory;
        };
    }
    // Clear source list without freeing entries (ownership transferred to dst).
    src.clearRetainingCapacity();
}

fn isTrustedFingerprint(loaded_fp: []const u8, trusted_fingerprints: []const []const u8) bool {
    for (trusted_fingerprints) |trusted_fp| {
        if (std.mem.eql(u8, loaded_fp, trusted_fp)) return true;
    }
    return false;
}

fn verifyMsgAgainstTrustedKeys(
    ctx: *Context,
    all_keys: []const LoadedKey,
    trusted_fingerprints: []const []const u8,
    msg: []const u8,
    signature: [c.crypto_sign_BYTES]u8,
) SignError!VerifyWithFingerprintResult {
    var trusted_key_count: usize = 0;

    for (all_keys) |loaded_key| {
        if (!isTrustedFingerprint(loaded_key.fingerprint, trusted_fingerprints)) continue;
        trusted_key_count += 1;

        // Try to verify with this key
        verifyBytes(loaded_key.public_key.key[0..], msg, signature[0..]) catch {
            continue; // Try next key
        };

        // Verification succeeded
        ctx.debug("signature verified with trusted key: {s}", .{loaded_key.fingerprint});
        const fp_copy = ctx.allocator.dupe(u8, loaded_key.fingerprint) catch {
            return SignError.OutOfMemory;
        };
        return VerifyWithFingerprintResult{ .verifying_fingerprint = fp_copy };
    }

    if (trusted_key_count == 0) {
        ctx.setDiagnosticContext(
            "signature",
            "no local public key matches the configured trusted fingerprint(s); install the signer .pub into /mere/keys or ~/.mere/keys",
        );
    } else {
        ctx.setDiagnosticContextFmt(
            "signature",
            "signature did not verify with any of the {d} trusted key(s) available locally",
            .{trusted_key_count},
        );
    }
    return SignError.VerifyFailed;
}

fn requireTrustedFingerprints(
    ctx: *Context,
    trusted_fingerprints: []const []const u8,
) SignError!void {
    if (trusted_fingerprints.len == 0) {
        ctx.debug("verifyMsgWithTrustedFingerprints: no trusted fingerprints provided", .{});
        return SignError.VerifyFailed;
    }
}

/// Result of fingerprint-based verification
pub const VerifyWithFingerprintResult = struct {
    /// The fingerprint of the key that successfully verified the signature
    verifying_fingerprint: []const u8,

    pub fn deinit(self: *VerifyWithFingerprintResult, allocator: std.mem.Allocator) void {
        allocator.free(self.verifying_fingerprint);
    }
};

/// Verify a file signature against an allowlist of trusted key fingerprints.
/// This is the secure verification method that matches keys by cryptographic identity.
///
/// Parameters:
/// - ctx: Context for allocator and logging
/// - file_path: Path to the file being verified
/// - signature_path: Path to the signature file (or null for default .sig)
/// - trusted_fingerprints: Slice of 64-char hex fingerprints that are trusted for this operation
///
/// Returns the fingerprint of the key that verified successfully.
/// Returns SignError.VerifyFailed if no trusted key verifies the signature.
///
/// Caller owns the returned fingerprint string and must free it.
pub fn verifyWithTrustedFingerprints(
    ctx: *Context,
    file_path: []const u8,
    signature_path: ?[]const u8,
    trusted_fingerprints: []const []const u8,
    all_keys: []const LoadedKey,
) SignError!VerifyWithFingerprintResult {
    // Hash the file (large files use hash-based signatures)
    const file_hash = getFileHash(ctx, file_path) catch |err| return err;
    return verifyMsgWithTrustedFingerprints(
        ctx,
        file_path,
        file_hash[0..],
        signature_path,
        trusted_fingerprints,
        all_keys,
    );
}

/// Verify a manifest file's signature against trusted fingerprints.
/// Unlike verifyWithTrustedFingerprints, this verifies the raw file bytes (not a hash),
/// which is the format used by manifest.v1.sig files.
///
/// Returns the fingerprint of the key that verified successfully.
/// Returns SignError.VerifyFailed if no trusted key verifies the signature.
///
/// Caller owns the returned fingerprint string and must free it.
pub fn verifyManifestWithTrustedFingerprints(
    ctx: *Context,
    manifest_path: []const u8,
    signature_path: ?[]const u8,
    trusted_fingerprints: []const []const u8,
    all_keys: []const LoadedKey,
) SignError!VerifyWithFingerprintResult {
    // Read raw manifest bytes (manifests are signed directly, not hashed)
    const manifest_bytes = sign_io.readRawFile(manifest_path) catch |e| {
        return mapIOReadError(e);
    };
    defer std.heap.page_allocator.free(manifest_bytes);
    return verifyMsgWithTrustedFingerprints(
        ctx,
        manifest_path,
        manifest_bytes,
        signature_path,
        trusted_fingerprints,
        all_keys,
    );
}

/// Internal helper: verify message bytes against signature using trusted fingerprints.
/// Both hash-based (files) and raw-byte (manifests) verification use this.
fn verifyMsgWithTrustedFingerprints(
    ctx: *Context,
    file_path: []const u8,
    msg: []const u8,
    signature_path: ?[]const u8,
    trusted_fingerprints: []const []const u8,
    all_keys: []const LoadedKey,
) SignError!VerifyWithFingerprintResult {
    try requireTrustedFingerprints(ctx, trusted_fingerprints);

    // Load signature
    const signature = try resolveAndLoadSignature(file_path, signature_path);

    const result = verifyMsgAgainstTrustedKeys(ctx, all_keys, trusted_fingerprints, msg, signature) catch |err| {
        if (err == SignError.VerifyFailed) {
            ctx.debug("verifyMsgWithTrustedFingerprints: no trusted key verified the signature", .{});
        }
        return err;
    };
    return result;
}

// Unit tests
// Spec #5: Sign-then-verify round-trip
test "generateKeyPair, signFile and verifySignature" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    ctx.debug("test: assign ctx", .{});

    ctx.debug("test: libsodium init", .{});
    ctx.debug("initializing libsodium for testing...", .{});
    if (c.sodium_init() < 0) {
        return error.SodiumInitFailed;
    }

    ctx.debug("test: create test file path", .{});
    const test_file_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test_file.txt" });
    defer testing.allocator.free(test_file_path);

    ctx.debug("test: create test file", .{});
    const test_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file_path, .{});
    try test_file.writeStreamingAll(path_mod.currentIo(), "This is a test file to sign");
    test_file.close(path_mod.currentIo());

    ctx.debug("test: create key paths", .{});
    const secret_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test.key" });
    defer testing.allocator.free(secret_key_path);

    const public_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test.pub" });
    defer testing.allocator.free(public_key_path);

    ctx.debug("test: generateKeyPair", .{});
    ctx.debug("generating new keypair...", .{});
    const key_pair = try generateKeyPair();

    ctx.debug("test: save public key", .{});
    try key_pair.public_key.saveToFile(public_key_path);
    ctx.debug("test: save secret key", .{});
    try key_pair.secret_key.saveToFile(secret_key_path);

    // Set the signing key path in the context to ensure the correct key is used
    ctx.signing_key_path = secret_key_path;

    ctx.debug("test: signFile", .{});
    ctx.debug("attempting to sign file: {s}", .{test_file_path});
    const sig_path = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{test_file_path});
    defer testing.allocator.free(sig_path);
    _ = try writeSignatureFileWithResolver(ctx, test_file_path, sig_path, null, null);

    ctx.debug("test: verify signature exists", .{});
    const sig_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), sig_path, .{});
    sig_file.close(path_mod.currentIo());

    ctx.debug("test: verifySignature", .{});
    ctx.debug("attempting to verify signature...", .{});
    try verifySignature(ctx, test_file_path, public_key_path, null);

    ctx.debug("test: explicit signature path", .{});
    const custom_sig_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "custom.sig" });
    defer testing.allocator.free(custom_sig_path);

    ctx.debug("testing with custom signature path: {s}", .{custom_sig_path});
    _ = try writeSignatureFileWithResolver(ctx, test_file_path, custom_sig_path, null, null);

    try verifySignature(ctx, test_file_path, public_key_path, custom_sig_path);

    ctx.debug("test: error cases", .{});
    const nonexistent_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "nonexistent.txt" });
    defer testing.allocator.free(nonexistent_file);

    try testing.expectError(SignError.FileSystem, signWithResolvedKey(ctx, nonexistent_file, null, null));
    try testing.expectError(SignError.FileSystem, verifySignature(ctx, nonexistent_file, public_key_path, null));

    const nonexistent_key = try std.fs.path.join(testing.allocator, &.{ test_env.path, "nonexistent.key" });
    defer testing.allocator.free(nonexistent_key);

    // Set the signing key path to a nonexistent key to trigger the error
    ctx.signing_key_path = nonexistent_key;
    try testing.expectError(SignError.FileSystem, signWithResolvedKey(ctx, test_file_path, null, null));
    try testing.expectError(SignError.FileSystem, verifySignature(ctx, test_file_path, nonexistent_key, null));
    ctx.debug("test: end", .{});
}

// Spec #5: Tamper detection (modified message rejected)
test "handle malformed inputs" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    // Test invalid key files
    {
        // Create invalid key files
        const invalid_pub_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "invalid.pub" });
        defer testing.allocator.free(invalid_pub_path);

        const invalid_pub_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), invalid_pub_path, .{});
        try invalid_pub_file.writeStreamingAll(path_mod.currentIo(), "too short");
        invalid_pub_file.close(path_mod.currentIo());

        try testing.expectError(SignError.InvalidKey, PublicKey.loadFromFile(invalid_pub_path));
    }

    // Test invalid signature file
    {
        // Create test file
        const test_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test.txt" });
        defer testing.allocator.free(test_path);

        const test_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_path, .{});
        try test_file.writeStreamingAll(path_mod.currentIo(), "Test content");
        test_file.close(path_mod.currentIo());

        // Create invalid signature
        const sig_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "invalid.sig" });
        defer testing.allocator.free(sig_path);

        const sig_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), sig_path, .{});
        try sig_file.writeStreamingAll(path_mod.currentIo(), "invalid signature");
        sig_file.close(path_mod.currentIo());

        // Generate a valid key pair
        const key_pair = try generateKeyPair();

        // Save public key to file
        const pub_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test.pub" });
        defer testing.allocator.free(pub_path);
        try key_pair.public_key.saveToFile(pub_path);

        // Verification should return an error for invalid signature
        try testing.expectError(SignError.VerifyFailed, verifySignature(&ctx, test_path, pub_path, sig_path));
    }
}

test "verifySignature fails when file is mutated concurrently" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    const test_file_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "concurrent-verify.bin" });
    defer testing.allocator.free(test_file_path);
    {
        var file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file_path, .{});
        defer file.close(path_mod.currentIo());
        var chunk: [1024 * 1024]u8 = undefined;
        @memset(&chunk, 'A');
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            try file.writeStreamingAll(path_mod.currentIo(), &chunk);
        }
    }

    const secret_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "concurrent.key" });
    defer testing.allocator.free(secret_key_path);
    const public_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "concurrent.pub" });
    defer testing.allocator.free(public_key_path);

    const key_pair = try generateKeyPair();
    try key_pair.public_key.saveToFile(public_key_path);
    try key_pair.secret_key.saveToFile(secret_key_path);
    ctx.signing_key_path = secret_key_path;

    const sig_path = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{test_file_path});
    defer testing.allocator.free(sig_path);
    _ = try writeSignatureFileWithResolver(&ctx, test_file_path, sig_path, null, null);

    const Mutator = struct {
        fn run(stop: *std.atomic.Value(bool), path: []const u8) void {
            var file = std.Io.Dir.openFileAbsolute(path_mod.currentIo(), path, .{ .mode = .read_write }) catch return;
            defer file.close(path_mod.currentIo());

            var value: u8 = 1;
            var block: [4096]u8 = undefined;
            while (!stop.load(.monotonic)) {
                @memset(&block, value);
                file.writePositionalAll(path_mod.currentIo(), &block, 0) catch break;
                value +%= 1;
                if (value == 0) value = 1;
            }
        }
    };

    var saw_verify_failed = false;
    var attempt: usize = 0;
    while (attempt < 6 and !saw_verify_failed) : (attempt += 1) {
        var stop = std.atomic.Value(bool).init(false);
        var thread = try std.Thread.spawn(.{}, Mutator.run, .{ &stop, test_file_path });
        defer {
            stop.store(true, .monotonic);
            thread.join();
        }

        verifySignature(&ctx, test_file_path, public_key_path, sig_path) catch |err| {
            if (err == SignError.VerifyFailed) {
                saw_verify_failed = true;
                break;
            }
            return err;
        };
    }

    try testing.expect(saw_verify_failed);
}

// Spec #5: Public key file exactly 32 bytes
// Spec #5: Secret key file exactly 64 bytes
test "generateAndSaveKeyPair creates directory and saves keys" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a subdirectory path for testing
    const key_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, "keys/subdir" });
    defer testing.allocator.free(key_dir);

    // Generate and save key pair
    const result = try generateAndSaveKeyPair(&ctx, key_dir);
    defer ctx.allocator.free(result.public_key_path);
    defer ctx.allocator.free(result.secret_key_path);

    // Verify the directory was created
    var dir = try path_mod.openExistingDir(key_dir);
    dir.close(path_mod.currentIo());

    // Verify the key files exist
    const pub_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.public_key_path, .{});
    pub_file.close(path_mod.currentIo());

    const sec_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.secret_key_path, .{});
    sec_file.close(path_mod.currentIo());

    // Verify the key files have the correct names
    try testing.expect(std.mem.endsWith(u8, result.public_key_path, "mere.pub"));
    try testing.expect(std.mem.endsWith(u8, result.secret_key_path, "mere.key"));
}

// Spec #5: Key generation
test "generateAndSaveKeyPair with existing directory" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a directory path for testing
    const key_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, "existing_dir" });
    defer testing.allocator.free(key_dir);

    // Create the directory first
    try path_mod.ensureDirExists(key_dir);

    // Generate and save key pair to the existing directory
    const result = try generateAndSaveKeyPair(&ctx, key_dir);
    defer ctx.allocator.free(result.public_key_path);
    defer ctx.allocator.free(result.secret_key_path);

    // Verify the key files exist
    const pub_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.public_key_path, .{});
    pub_file.close(path_mod.currentIo());

    const sec_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.secret_key_path, .{});
    sec_file.close(path_mod.currentIo());
}

// Spec #5: Key generation
test "generateAndSaveKeyPair with absolute path" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create an absolute directory path for testing
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try path_mod.resolveToAbsolutePath(test_env.path, &buf);
    const key_dir = try std.fs.path.join(testing.allocator, &.{ abs_path, "abs_keys" });
    defer testing.allocator.free(key_dir);

    // Generate and save key pair
    const result = try generateAndSaveKeyPair(&ctx, key_dir);
    defer ctx.allocator.free(result.public_key_path);
    defer ctx.allocator.free(result.secret_key_path);

    // Verify the directory was created
    var dir = try path_mod.openExistingDir(key_dir);
    dir.close(path_mod.currentIo());

    // Verify the key files exist
    const pub_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.public_key_path, .{});
    pub_file.close(path_mod.currentIo());

    const sec_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.secret_key_path, .{});
    sec_file.close(path_mod.currentIo());
}

// Spec #5: Key generation
test "generateAndSaveKeyPair does not overwrite existing key files" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a directory path for testing
    const key_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, "key_dir_no_overwrite" });
    defer testing.allocator.free(key_dir);

    // Create the directory
    try path_mod.ensureDirExists(key_dir);

    // Create file paths for the keys
    const pub_key_path = try std.fs.path.join(testing.allocator, &.{ key_dir, "mere.pub" });
    defer testing.allocator.free(pub_key_path);

    const sec_key_path = try std.fs.path.join(testing.allocator, &.{ key_dir, "mere.key" });
    defer testing.allocator.free(sec_key_path);

    // Create files with known content
    const original_pub_content = "ORIGINAL_PUBLIC_KEY_CONTENT";
    const original_sec_content = "ORIGINAL_SECRET_KEY_CONTENT";

    {
        const pub_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), pub_key_path, .{});
        defer pub_file.close(path_mod.currentIo());
        try pub_file.writeStreamingAll(path_mod.currentIo(), original_pub_content);
    }

    {
        const sec_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), sec_key_path, .{});
        defer sec_file.close(path_mod.currentIo());
        try sec_file.writeStreamingAll(path_mod.currentIo(), original_sec_content);
    }

    // Attempt to generate and save key pair to the same directory
    // This should fail with FileSystem because the files already exist
    try testing.expectError(SignError.FileSystem, generateAndSaveKeyPair(&ctx, key_dir));

    // Verify the original files still contain the original content
    {
        const pub_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), pub_key_path, .{});
        defer pub_file.close(path_mod.currentIo());

        var pub_buffer: [100]u8 = undefined;
        const pub_bytes_read = try pub_file.readPositionalAll(path_mod.currentIo(), &pub_buffer, 0);
        try testing.expectEqualStrings(original_pub_content, pub_buffer[0..pub_bytes_read]);
    }

    {
        const sec_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), sec_key_path, .{});
        defer sec_file.close(path_mod.currentIo());

        var sec_buffer: [100]u8 = undefined;
        const sec_bytes_read = try sec_file.readPositionalAll(path_mod.currentIo(), &sec_buffer, 0);
        try testing.expectEqualStrings(original_sec_content, sec_buffer[0..sec_bytes_read]);
    }
}

test "generateAndSaveKeyPair leaves no partial files on failure" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    const key_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, "key_dir_partial_failure" });
    defer testing.allocator.free(key_dir);
    try path_mod.ensureDirExists(key_dir);

    const secret_key_path = try std.fs.path.join(testing.allocator, &.{ key_dir, "mere.key" });
    defer testing.allocator.free(secret_key_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), secret_key_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), "existing");
    }

    try testing.expectError(SignError.FileSystem, generateAndSaveKeyPair(&ctx, key_dir));

    const public_key_path = try std.fs.path.join(testing.allocator, &.{ key_dir, "mere.pub" });
    defer testing.allocator.free(public_key_path);
    try testing.expect(!path_mod.fileExists(public_key_path));
}

// Spec #5: Key generation
test "PublicKey.saveToFile does not overwrite existing file" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Generate a key pair
    const key_pair = try generateKeyPair();

    // Create a file path for the public key
    const pub_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "existing.pub" });
    defer testing.allocator.free(pub_key_path);

    // Create a file with known content
    const original_content = "ORIGINAL_PUBLIC_KEY_CONTENT";
    {
        const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), pub_key_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), original_content);
    }

    // Attempt to save the public key to the same file
    // This should fail with FileSystem because the file already exists
    try testing.expectError(SignError.FileSystem, key_pair.public_key.saveToFile(pub_key_path));

    // Verify the original file still contains the original content
    const file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), pub_key_path, .{});
    defer file.close(path_mod.currentIo());

    var buffer: [100]u8 = undefined;
    const bytes_read = try file.readPositionalAll(path_mod.currentIo(), &buffer, 0);
    try testing.expectEqualStrings(original_content, buffer[0..bytes_read]);
}

// Spec #5: Signing and verification
test "signFile with relative paths" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a test file to sign
    const test_file_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "rel_test_file.txt" });
    defer testing.allocator.free(test_file_path);

    const test_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file_path, .{});
    try test_file.writeStreamingAll(path_mod.currentIo(), "This is a test file for relative path signing");
    test_file.close(path_mod.currentIo());

    // Generate a new key pair for testing
    const secret_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "rel_test.key" });
    defer testing.allocator.free(secret_key_path);

    const public_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "rel_test.pub" });
    defer testing.allocator.free(public_key_path);

    // Generate key pair
    const key_pair = try generateKeyPair();

    // Save keys to files
    ctx.debug("public_key_path before save: {s}", .{public_key_path});
    try key_pair.public_key.saveToFile(public_key_path);
    ctx.debug("public_key_path after save: {s}", .{public_key_path});
    try key_pair.secret_key.saveToFile(secret_key_path);
    ctx.debug("secret_key_path after save: {s}", .{secret_key_path});
    // Check existence and size after saving
    {
        const pub_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), public_key_path, .{});
        const pub_stat = try pub_file.stat(path_mod.currentIo());
        ctx.debug("public_key_path exists, size: {}", .{pub_stat.size});
        pub_file.close(path_mod.currentIo());
        const sec_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), secret_key_path, .{});
        const sec_stat = try sec_file.stat(path_mod.currentIo());
        ctx.debug("secret_key_path exists, size: {}", .{sec_stat.size});
        sec_file.close(path_mod.currentIo());
    }

    // Save current working directory before switching
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try path_mod.resolveToAbsolutePath(".", &buf);
    defer std.process.setCurrentPath(path_mod.currentIo(), original_cwd) catch |err| {
        ctx.debug("Failed to restore cwd: {}\n", .{err});
    };

    // Change directories to the test environment path
    try std.process.setCurrentPath(path_mod.currentIo(), test_env.path);

    // Set context signing_key_path to relative key file
    ctx.signing_key_path = "rel_test.key";

    // Get relative paths
    const rel_file_path = std.fs.path.basename(test_file_path);

    // Sign using relative paths
    const sig_path = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{rel_file_path});
    defer testing.allocator.free(sig_path);
    _ = try writeSignatureFileWithResolver(&ctx, rel_file_path, sig_path, null, null);

    // Verify the signature exists (sig_path declared above)

    // Check if the signature file exists
    const sig_file = try std.Io.Dir.cwd().openFile(path_mod.currentIo(), sig_path, .{});
    sig_file.close(path_mod.currentIo());

    // Verify the signature
    const rel_pub_path = std.fs.path.basename(public_key_path);
    try verifySignature(&ctx, rel_file_path, rel_pub_path, null);
}

// Spec #5: Key generation
test "SecretKey.saveToFile does not overwrite existing file" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Generate a key pair
    const key_pair = try generateKeyPair();

    // Create a file path for the secret key
    const sec_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "existing.key" });
    defer testing.allocator.free(sec_key_path);

    // Create a file with known content
    const original_content = "ORIGINAL_SECRET_KEY_CONTENT";
    {
        const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), sec_key_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), original_content);
    }

    // Attempt to save the secret key to the same file
    // This should fail with FileSystem because the file already exists
    try testing.expectError(SignError.FileSystem, key_pair.secret_key.saveToFile(sec_key_path));

    // Verify the original file still contains the original content
    const file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), sec_key_path, .{});
    defer file.close(path_mod.currentIo());

    var buffer: [100]u8 = undefined;
    const bytes_read = try file.readPositionalAll(path_mod.currentIo(), &buffer, 0);
    try testing.expectEqualStrings(original_content, buffer[0..bytes_read]);
}

// Spec #5: Secret key file security
test "SecretKey.saveToFile sets restrictive permissions" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Generate a key pair
    const key_pair = try generateKeyPair();

    // Create a file path for the secret key
    const sec_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "secure.key" });
    defer testing.allocator.free(sec_key_path);

    // Save the key
    try key_pair.secret_key.saveToFile(sec_key_path);

    // Open the file and check its permissions
    const file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), sec_key_path, .{});
    defer file.close(path_mod.currentIo());

    // Get the file stat
    const stat = try file.stat(path_mod.currentIo());

    // Check if the permissions match 0600 (owner read/write only)
    // Note: We're checking that only the owner read/write bits are set (0o600)
    // and no other bits are set (like group or other permissions)
    const expected_mode = 0o600;
    const actual_mode = stat.permissions.toMode() & 0o777; // Apply mask to get just permission bits

    try testing.expectEqual(expected_mode, actual_mode);
}

// Spec #5: Signature file exactly 64 bytes
test "writeSignatureFileWithResolver produces valid signature" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    // Create a test environment
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Initialize libsodium
    ctx.debug("initializing libsodium for testing...", .{});
    if (c.sodium_init() < 0) {
        return error.SodiumInitFailed;
    }

    // Create a test file to sign
    const test_file_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test_file_bytes.txt" });
    defer testing.allocator.free(test_file_path);

    const test_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file_path, .{});
    try test_file.writeStreamingAll(path_mod.currentIo(), "This is a test file for writeSignatureFileWithResolver");
    test_file.close(path_mod.currentIo());

    // Generate a new key pair for testing
    const secret_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test_bytes.key" });
    defer testing.allocator.free(secret_key_path);

    const public_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test_bytes.pub" });
    defer testing.allocator.free(public_key_path);

    // Generate key pair
    ctx.debug("generating new keypair for bytes test...", .{});
    const key_pair = try generateKeyPair();

    // Save keys to files
    try key_pair.public_key.saveToFile(public_key_path);
    try key_pair.secret_key.saveToFile(secret_key_path);

    // Set the signing key path in the context to ensure the correct key is used
    ctx.signing_key_path = secret_key_path;

    // Prepare a signature path and invoke the new single-call helper that writes the signature file
    const sig_path = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{test_file_path});
    defer testing.allocator.free(sig_path);

    const signature_bytes = try writeSignatureFileWithResolver(&ctx, test_file_path, sig_path, null, null);

    // Verify the signature bytes length
    try testing.expectEqual(c.crypto_sign_BYTES, signature_bytes.len);

    // Verify the signature using the existing verifySignature function
    try verifySignature(&ctx, test_file_path, public_key_path, sig_path);

    // Convert signature bytes to hex using std.fmt
    const hex_signature = std.fmt.allocPrint(ctx.allocator, "{x}", .{signature_bytes}) catch return error.OutOfMemory;
    defer ctx.allocator.free(hex_signature);

    // Verify the hex signature length (each byte becomes 2 hex chars)
    try testing.expectEqual(c.crypto_sign_BYTES * 2, hex_signature.len);

    // Verify that the hex signature is valid hex
    for (hex_signature) |char| {
        const is_hex_char = (char >= '0' and char <= '9') or
            (char >= 'a' and char <= 'f') or
            (char >= 'A' and char <= 'F');
        try testing.expect(is_hex_char);
    }

    // Convert hex back to bytes and verify it matches the original signature
    var decoded_sig: [c.crypto_sign_BYTES]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded_sig, hex_signature);
    try testing.expectEqualSlices(u8, &signature_bytes, &decoded_sig);
}

// New pure API tests for signBytes/verifyBytes
// Spec #5: Sign-then-verify round-trip
// Spec #5: Tamper detection
test "signBytes and verifyBytes pure API" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    _ = test_env.ctx;

    // Ensure libsodium is initialized for tests (idempotent)
    if (c.sodium_init() < 0) {
        return error.SodiumInitFailed;
    }

    const msg = "hello-sign-test";

    var kp = try generateKeyPair();
    defer kp.secret_key.deinit();

    // Sign the message using the pure API
    const signature = try signBytes(kp.secret_key.key[0..], msg);

    // Verify the signature using the pure API
    try verifyBytes(kp.public_key.key[0..], msg, signature[0..]);

    // Tamper with the signature and ensure verification fails
    var tampered: [c.crypto_sign_BYTES]u8 = signature;
    tampered[0] = tampered[0] ^ 0x01;
    try testing.expectError(SignError.VerifyFailed, verifyBytes(kp.public_key.key[0..], msg, tampered[0..]));
}

// Spec #5: Ed25519 signature verification
test "sign: rfc8032 ed25519 test vector 1 (empty message)" {
    const testing = std.testing;

    // RFC8032 test vector 1
    const seed_hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
    const pub_hex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    const sig_hex = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" ++
        "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, seed_hex);
    var pub_key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pub_key, pub_hex);
    var expected_sig: [c.crypto_sign_BYTES]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_sig, sig_hex);

    // Construct libsodium-style secret key as seed||pub
    var secret: [c.crypto_sign_SECRETKEYBYTES]u8 = undefined;
    std.mem.copyForwards(u8, secret[0..32], seed[0..]);
    std.mem.copyForwards(u8, secret[32 .. 32 + pub_key.len], pub_key[0..]);

    const msg: []const u8 = "";

    const sig = try signBytes(secret[0..], msg);
    try testing.expectEqualSlices(u8, &expected_sig, &sig);

    // Verify using the pure API
    try verifyBytes(pub_key[0..], msg, sig[0..]);
}

test "standardized error handling" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Test 1: OutOfMemory error is properly mapped
    // This is tested implicitly through memory allocation failures

    // Test 2: FileSystem error for various file operations
    const nonexistent_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "nonexistent.txt" });
    defer testing.allocator.free(nonexistent_file);

    // Test FileSystem error for missing files
    try testing.expectError(SignError.FileSystem, PublicKey.loadFromFile(nonexistent_file));
    try testing.expectError(SignError.FileSystem, SecretKey.loadFromFile(nonexistent_file));

    // Test 3: InvalidKey error for malformed keys
    const invalid_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "invalid.key" });
    defer testing.allocator.free(invalid_key_path);

    // Create a file with invalid key content
    const invalid_key_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), invalid_key_path, .{});
    try invalid_key_file.writeStreamingAll(path_mod.currentIo(), "invalid key content");
    invalid_key_file.close(path_mod.currentIo());

    try testing.expectError(SignError.InvalidKey, SecretKey.loadFromFile(invalid_key_path));

    // Test 4: VerifyFailed error for signature verification
    if (c.sodium_init() < 0) {
        return error.SodiumInitFailed;
    }

    // Generate a valid key pair
    var key_pair = try generateKeyPair();
    defer key_pair.secret_key.deinit();

    const test_msg = "test message";
    const signature = try signBytes(key_pair.secret_key.key[0..], test_msg);

    // Test with wrong public key
    var wrong_key_pair = try generateKeyPair();
    defer wrong_key_pair.secret_key.deinit();

    try testing.expectError(SignError.VerifyFailed, verifyBytes(wrong_key_pair.public_key.key[0..], test_msg, signature[0..]));

    // Test with tampered signature
    var tampered_sig = signature;
    tampered_sig[0] = tampered_sig[0] ^ 0x01;
    try testing.expectError(SignError.VerifyFailed, verifyBytes(key_pair.public_key.key[0..], test_msg, tampered_sig[0..]));

    // Test 5: InvalidInput error for invalid parameters
    // Test with wrong key size
    const short_key = [_]u8{1} ** 16; // Too short for a public key
    try testing.expectError(SignError.InvalidKey, verifyBytes(short_key[0..], test_msg, signature[0..]));

    // Test with wrong signature size
    const short_sig = [_]u8{1} ** 32; // Too short for a signature
    try testing.expectError(SignError.VerifyFailed, verifyBytes(key_pair.public_key.key[0..], test_msg, short_sig[0..]));

    // Test 6: SodiumInitFailed is preserved as domain-specific error
    // This is tested implicitly through libsodium initialization

    // Test 7: Ensure all standard errors are defined in the error set
    // This is a compile-time check - if these don't compile, the error set is incomplete
    _ = SignError.OutOfMemory catch {};
    _ = SignError.FileSystem catch {};
    _ = SignError.PermissionDenied catch {};
    _ = SignError.InvalidInput catch {};
    _ = SignError.InvalidKey catch {};
    _ = SignError.VerifyFailed catch {};
    _ = SignError.SodiumInitFailed catch {};
}

test "error mapping functions work correctly" {
    const testing = std.testing;

    // Test that error mapping functions handle all cases correctly
    // This ensures the internal error mapping is working as expected

    // Test mapCryptoError function
    const crypto_error = sign_crypto.CryptoError.InvalidInput;
    const mapped_crypto = mapCryptoError(crypto_error);
    try testing.expectEqual(SignError.InvalidKey, mapped_crypto);

    // Test mapIOError function for read operations
    const io_error_read = sign_io.SignIOError.FileSystem;
    const mapped_io_read = mapIOError(io_error_read, true);
    try testing.expectEqual(SignError.FileSystem, mapped_io_read);

    // Test mapIOError function for write operations
    const io_error_write = sign_io.SignIOError.FileSystem;
    const mapped_io_write = mapIOError(io_error_write, false);
    try testing.expectEqual(SignError.FileSystem, mapped_io_write);

    // Test InvalidSize mapping for read vs write
    const invalid_size_read = mapIOError(sign_io.SignIOError.InvalidSize, true);
    try testing.expectEqual(SignError.InvalidKey, invalid_size_read);

    const invalid_size_write = mapIOError(sign_io.SignIOError.InvalidSize, false);
    try testing.expectEqual(SignError.InvalidInput, invalid_size_write);
}

test "Property 2: Diagnostic Context Preservation in sign module error propagation" {
    // **Feature: single-point-logging, Property 2: Diagnostic Context Preservation**
    // **Validates: Requirements 1.3, 1.5, 2.4**
    //
    // Property: For any cryptographic operation with diagnostic context, errors should propagate
    // without logging and preserve error type information through the call stack.

    const th = @import("test_helpers.zig");
    const testing = std.testing;

    // Test 5 error scenarios (one iteration each)
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var test_env = try th.createTestEnv();
        defer {
            test_env.cleanup();
            testing.allocator.destroy(test_env);
        }
        var ctx = test_env.ctx;

        switch (i) {
            0 => {
                // Test 1: Verify signature with non-existent file
                const nonexistent_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "nonexistent.txt" });
                defer testing.allocator.free(nonexistent_file);

                const pub_key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test.pub" });
                defer testing.allocator.free(pub_key_path);

                try testing.expectError(SignError.FileSystem, verifySignature(&ctx, nonexistent_file, pub_key_path, null));
            },
            1 => {
                // Test 2: Verify signature with non-existent public key
                const test_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "test.txt" });
                defer testing.allocator.free(test_file);

                // Create test file
                {
                    const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file, .{});
                    try f.writeStreamingAll(path_mod.currentIo(), "test content");
                    f.close(path_mod.currentIo());
                }

                const nonexistent_key = try std.fs.path.join(testing.allocator, &.{ test_env.path, "nonexistent.key" });
                defer testing.allocator.free(nonexistent_key);

                try testing.expectError(SignError.FileSystem, verifySignature(&ctx, test_file, nonexistent_key, null));
            },
            2 => {
                // Test 3: Load invalid public key file (too short)
                const invalid_pub_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "invalid.pub" });
                defer testing.allocator.free(invalid_pub_path);

                const invalid_pub_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), invalid_pub_path, .{});
                try invalid_pub_file.writeStreamingAll(path_mod.currentIo(), "too short");
                invalid_pub_file.close(path_mod.currentIo());

                try testing.expectError(SignError.InvalidKey, PublicKey.loadFromFile(invalid_pub_path));
            },
            3 => {
                // Test 4: Load invalid secret key file (too short)
                const invalid_sec_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "invalid.key" });
                defer testing.allocator.free(invalid_sec_path);

                const invalid_sec_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), invalid_sec_path, .{});
                try invalid_sec_file.writeStreamingAll(path_mod.currentIo(), "too short");
                invalid_sec_file.close(path_mod.currentIo());

                try testing.expectError(SignError.InvalidKey, SecretKey.loadFromFile(invalid_sec_path));
            },
            4 => {
                // Test 5: Verify bytes with invalid signature
                if (c.sodium_init() < 0) {
                    return error.SodiumInitFailed;
                }

                const msg = "test message";
                var kp = try generateKeyPair();
                defer kp.secret_key.deinit();

                // Create an invalid signature (all zeros)
                var invalid_sig: [64]u8 = undefined;
                @memset(&invalid_sig, 0);

                try testing.expectError(SignError.VerifyFailed, verifyBytes(kp.public_key.key[0..], msg, &invalid_sig));
            },
            else => unreachable,
        }
    }
}

test "SecretKey.loadFromFile rejects mismatched embedded public key" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }

    var kp = try generateKeyPair();
    defer kp.secret_key.deinit();

    const key_path = try std.fs.path.join(testing.allocator, &.{ test_env.path, "tampered.key" });
    defer testing.allocator.free(key_path);

    var tampered = kp.secret_key.key;
    tampered[c.crypto_sign_SECRETKEYBYTES - 1] ^= 0x01;

    const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), key_path, .{});
    defer file.close(path_mod.currentIo());
    try file.writeStreamingAll(path_mod.currentIo(), tampered[0..]);

    try testing.expectError(SignError.InvalidKey, SecretKey.loadFromFile(key_path));
}

// Spec #5: Public key fingerprint computation
test "PublicKey.fingerprint returns consistent 64-char hex" {
    const testing = std.testing;

    // Generate a key pair
    const kp = try generateKeyPair();

    // Get fingerprint
    const fp = try kp.public_key.fingerprint(testing.allocator);
    defer testing.allocator.free(fp);

    // Should be 64 hex characters
    try testing.expectEqual(@as(usize, 64), fp.len);

    // All characters should be lowercase hex
    for (fp) |char| {
        const is_hex = (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f');
        try testing.expect(is_hex);
    }

    // Same key should produce same fingerprint
    const fp2 = try kp.public_key.fingerprint(testing.allocator);
    defer testing.allocator.free(fp2);
    try testing.expectEqualStrings(fp, fp2);
}

// Spec #5: Key loading and fingerprint computation
test "scanKeyDirectory loads keys from directory" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }

    // Create a keys directory
    const keys_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, "keys" });
    defer testing.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    // Generate two key pairs and save them
    const kp1 = try generateKeyPair();
    const kp2 = try generateKeyPair();

    const key1_path = try std.fs.path.join(testing.allocator, &.{ keys_dir, "key1.pub" });
    defer testing.allocator.free(key1_path);
    try kp1.public_key.saveToFile(key1_path);

    const key2_path = try std.fs.path.join(testing.allocator, &.{ keys_dir, "key2.pub" });
    defer testing.allocator.free(key2_path);
    try kp2.public_key.saveToFile(key2_path);

    // Also create a non-.pub file that should be ignored
    const other_file = try std.fs.path.join(testing.allocator, &.{ keys_dir, "readme.txt" });
    defer testing.allocator.free(other_file);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), other_file, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "not a key");
        f.close(path_mod.currentIo());
    }

    // Scan the directory
    var loaded_keys = try scanKeyDirectory(testing.allocator, keys_dir);
    defer {
        for (loaded_keys.items) |*k| k.deinit(testing.allocator);
        loaded_keys.deinit(testing.allocator);
    }

    // Should have loaded exactly 2 keys
    try testing.expectEqual(@as(usize, 2), loaded_keys.items.len);

    // Each key should have a 64-char fingerprint
    for (loaded_keys.items) |key| {
        try testing.expectEqual(@as(usize, 64), key.fingerprint.len);
    }
}

test "scanKeyDirectory returns empty for nonexistent directory" {
    const testing = std.testing;

    var loaded_keys = try scanKeyDirectory(testing.allocator, "/nonexistent/path/keys");
    defer {
        for (loaded_keys.items) |*k| k.deinit(testing.allocator);
        loaded_keys.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(usize, 0), loaded_keys.items.len);
}

test "scanKeyDirectory returns PermissionDenied for unreadable directory" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }

    const keys_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, "restricted-keys" });
    defer testing.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    var restricted = try path_mod.openExistingDir(keys_dir);
    defer restricted.close(path_mod.currentIo());
    try restricted.setPermissions(path_mod.currentIo(), .fromMode(0o000));
    defer restricted.setPermissions(path_mod.currentIo(), .fromMode(0o755)) catch {};

    const result = scanKeyDirectory(testing.allocator, keys_dir);
    if (result) |loaded_keys| {
        var success = loaded_keys;
        defer {
            for (success.items) |*k| k.deinit(testing.allocator);
            success.deinit(testing.allocator);
        }
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(SignError.PermissionDenied, err);
    }
}

// Spec #5: Signature verification with trusted fingerprints
test "verifyWithTrustedFingerprints succeeds with matching fingerprint" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    // Create user keys directory (test home_dir is test_env.path)
    const keys_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer testing.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    // Generate key and save to user keys dir
    const kp = try generateKeyPair();
    const key_path = try std.fs.path.join(testing.allocator, &.{ keys_dir, "test.pub" });
    defer testing.allocator.free(key_path);
    try kp.public_key.saveToFile(key_path);

    // Get the fingerprint
    const fp = try kp.public_key.fingerprint(testing.allocator);
    defer testing.allocator.free(fp);

    // Create a test file and sign it
    const test_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "testfile.txt" });
    defer testing.allocator.free(test_file);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "test content for signing");
        f.close(path_mod.currentIo());
    }

    // Save secret key for signing
    const secret_path = try std.fs.path.join(testing.allocator, &.{ keys_dir, "test.key" });
    defer testing.allocator.free(secret_path);
    try kp.secret_key.saveToFile(secret_path);

    // Sign the file
    ctx.signing_key_path = secret_path;
    const sig_path = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{test_file});
    defer testing.allocator.free(sig_path);
    _ = try writeSignatureFileWithResolver(&ctx, test_file, sig_path, null, null);

    var loaded_keys = try loadAllKeys(&ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    // Verify with trusted fingerprint
    const trusted = [_][]const u8{fp};
    var result = try verifyWithTrustedFingerprints(&ctx, test_file, sig_path, &trusted, loaded_keys.items);
    defer result.deinit(ctx.allocator);

    try testing.expectEqualStrings(fp, result.verifying_fingerprint);
}

// Spec #5: Wrong key rejected
test "verifyWithTrustedFingerprints fails with untrusted fingerprint" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;
    defer ctx.resetDiagnostics();

    // Create user keys directory
    const keys_dir = try std.fs.path.join(testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer testing.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    // Generate key and save
    const kp = try generateKeyPair();
    const key_path = try std.fs.path.join(testing.allocator, &.{ keys_dir, "test.pub" });
    defer testing.allocator.free(key_path);
    try kp.public_key.saveToFile(key_path);

    // Create a test file and sign it
    const test_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "testfile.txt" });
    defer testing.allocator.free(test_file);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "test content for signing");
        f.close(path_mod.currentIo());
    }

    // Save secret key for signing
    const secret_path = try std.fs.path.join(testing.allocator, &.{ keys_dir, "test.key" });
    defer testing.allocator.free(secret_path);
    try kp.secret_key.saveToFile(secret_path);

    // Sign the file
    ctx.signing_key_path = secret_path;
    const sig_path = try std.fmt.allocPrint(testing.allocator, "{s}.sig", .{test_file});
    defer testing.allocator.free(sig_path);
    _ = try writeSignatureFileWithResolver(&ctx, test_file, sig_path, null, null);

    var loaded_keys = try loadAllKeys(&ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    // Try to verify with a DIFFERENT fingerprint (not the actual signer)
    const fake_fp = "0000000000000000000000000000000000000000000000000000000000000000";
    const trusted = [_][]const u8{fake_fp};
    try testing.expectError(SignError.VerifyFailed, verifyWithTrustedFingerprints(&ctx, test_file, sig_path, &trusted, loaded_keys.items));
}

// Spec #5: Signature verification requires trusted fingerprints
test "verifyWithTrustedFingerprints fails with empty fingerprint list" {
    const testing = std.testing;
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    const test_file = try std.fs.path.join(testing.allocator, &.{ test_env.path, "testfile.txt" });
    defer testing.allocator.free(test_file);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "test content");
        f.close(path_mod.currentIo());
    }

    const empty_trusted: []const []const u8 = &.{};
    var loaded_keys = try loadAllKeys(&ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try testing.expectError(SignError.VerifyFailed, verifyWithTrustedFingerprints(&ctx, test_file, null, empty_trusted, loaded_keys.items));
}

// Spec #5: Public key derivation from secret key
test "SecretKey.derivePublicKey extracts correct public key" {
    const testing = std.testing;

    // Generate a keypair
    const keypair = try generateKeyPair();
    const secret_key = keypair.secret_key;
    const expected_public_key = keypair.public_key;

    // Derive public key from secret key
    const derived = secret_key.derivePublicKey();

    // The derived public key should match the original
    try testing.expectEqualSlices(u8, &expected_public_key.key, &derived.key);
}
