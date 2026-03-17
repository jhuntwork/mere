const std = @import("std");
const errors = @import("errors.zig");

pub const c = @cImport({
    @cInclude("sodium.h");
});

const Std = errors.StandardErrors;
pub const CryptoError = Std.InvalidInput || error{
    SodiumInitFailed,
    CryptoFailed,
};

pub fn genKeypair() CryptoError!struct { public: [c.crypto_sign_PUBLICKEYBYTES]u8, secret: [c.crypto_sign_SECRETKEYBYTES]u8 } {
    if (c.sodium_init() < 0) return CryptoError.SodiumInitFailed;
    var public_key: [c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    var secret_key: [c.crypto_sign_SECRETKEYBYTES]u8 = undefined;
    if (c.crypto_sign_keypair(@ptrCast(&public_key[0]), @ptrCast(&secret_key[0])) != 0) {
        return CryptoError.CryptoFailed;
    }
    return .{ .public = public_key, .secret = secret_key };
}

pub fn deriveKeypairFromSeed(seed: []const u8) CryptoError!struct { public: [c.crypto_sign_PUBLICKEYBYTES]u8, secret: [c.crypto_sign_SECRETKEYBYTES]u8 } {
    if (seed.len != c.crypto_sign_SEEDBYTES) return CryptoError.InvalidInput;
    if (c.sodium_init() < 0) return CryptoError.SodiumInitFailed;

    var public_key: [c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    var secret_key: [c.crypto_sign_SECRETKEYBYTES]u8 = undefined;
    if (c.crypto_sign_seed_keypair(@ptrCast(&public_key[0]), @ptrCast(&secret_key[0]), @ptrCast(&seed[0])) != 0) {
        return CryptoError.CryptoFailed;
    }
    return .{ .public = public_key, .secret = secret_key };
}

pub fn signDetached(secret_key: []const u8, msg: []const u8) CryptoError![c.crypto_sign_BYTES]u8 {
    if (secret_key.len != c.crypto_sign_SECRETKEYBYTES) return CryptoError.InvalidInput;
    if (c.sodium_init() < 0) return CryptoError.SodiumInitFailed;
    var signature: [c.crypto_sign_BYTES]u8 = undefined;

    if (msg.len == 0) {
        const res = c.crypto_sign_detached(@ptrCast(&signature[0]), null, null, 0, @ptrCast(&secret_key[0]));
        if (res != 0) return CryptoError.CryptoFailed;
    } else {
        const res = c.crypto_sign_detached(@ptrCast(&signature[0]), null, @ptrCast(&msg[0]), msg.len, @ptrCast(&secret_key[0]));
        if (res != 0) return CryptoError.CryptoFailed;
    }

    return signature;
}

pub fn verifyDetached(public_key: []const u8, msg: []const u8, sig: []const u8) CryptoError!bool {
    if (public_key.len != c.crypto_sign_PUBLICKEYBYTES) return CryptoError.InvalidInput;
    if (sig.len != c.crypto_sign_BYTES) return CryptoError.CryptoFailed;
    if (c.sodium_init() < 0) return CryptoError.SodiumInitFailed;

    var res: i32 = 0;
    if (msg.len == 0) {
        res = c.crypto_sign_verify_detached(@ptrCast(&sig[0]), null, 0, @ptrCast(&public_key[0]));
    } else {
        res = c.crypto_sign_verify_detached(@ptrCast(&sig[0]), @ptrCast(&msg[0]), msg.len, @ptrCast(&public_key[0]));
    }
    return res == 0;
}

test "sign_crypto: genKeypair, signDetached and verifyDetached" {
    const testing = std.testing;

    // Ensure libsodium initialized (wrapper is idempotent but test is explicit)
    if (c.sodium_init() < 0) {
        return error.SodiumInitFailed;
    }

    const kp = try genKeypair();
    const msg = "unit-test-message";

    const sig = try signDetached(kp.secret[0..], msg);
    const ok = try verifyDetached(kp.public[0..], msg, sig[0..]);
    try testing.expect(ok);
}

test "sign_crypto: signDetached rejects invalid secret key length" {
    const testing = std.testing;
    var short: [1]u8 = undefined;
    try testing.expectError(CryptoError.InvalidInput, signDetached(short[0..], "x"));
}

test "sign_crypto: deriveKeypairFromSeed matches generated secret seed" {
    const testing = std.testing;

    const kp = try genKeypair();
    const derived = try deriveKeypairFromSeed(kp.secret[0..c.crypto_sign_SEEDBYTES]);

    try testing.expectEqualSlices(u8, kp.public[0..], derived.public[0..]);
    try testing.expectEqualSlices(u8, kp.secret[0..], derived.secret[0..]);
}

test "sign_crypto: verifyDetached rejects invalid public key and signature lengths" {
    const testing = std.testing;

    // invalid public key length
    var pub_short: [1]u8 = undefined;
    try testing.expectError(CryptoError.InvalidInput, verifyDetached(pub_short[0..], "m", pub_short[0..]));

    // invalid signature length
    var sig_short: [1]u8 = undefined;
    // Generate a valid keypair to supply a valid public key for this subcase
    const kp = try genKeypair();
    try testing.expectError(CryptoError.CryptoFailed, verifyDetached(kp.public[0..], "m", sig_short[0..]));
}

test "sign_crypto: rfc8032 ed25519 test vector 1 (empty message)" {
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

    const sig = try signDetached(secret[0..], msg);
    try testing.expectEqualSlices(u8, &expected_sig, &sig);

    const ok = try verifyDetached(pub_key[0..], msg, sig[0..]);
    try testing.expect(ok);
}
