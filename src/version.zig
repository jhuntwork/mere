// Version comparison for package dependency resolution
//
// This module implements Arch/pacman-style vercmp with epoch and tilde extension
// using the package version ordering rules implemented in this module.
//
// Comparison order: (epoch, version, release) tuple
// - Epoch: optional N: prefix (default 0)
// - Version: vercmp algorithm (digit/non-digit runs)
// - Release: integer tie-breaker
//
// Tilde (~) sorts before everything for pre-releases: 1.0~rc1 < 1.0

const std = @import("std");

/// Result of version comparison
pub const Order = enum {
    less,
    equal,
    greater,

    /// Convert to std.math.Order for callers that use std ordering
    pub fn toStd(self: Order) std.math.Order {
        return switch (self) {
            .less => .lt,
            .equal => .eq,
            .greater => .gt,
        };
    }
};

/// Parsed epoch and version string
pub const ParsedVersion = struct {
    epoch: u32,
    version: []const u8,
};

pub const VersionError = error{InvalidInput};

/// Parse epoch prefix from version string.
///
/// Format: "N:version" where N is a non-negative integer.
/// If no epoch prefix, returns epoch=0 and the full string as version.
/// Malformed epoch syntax is invalid input.
///
/// Examples:
/// - "1:2.0.0" -> { epoch: 1, version: "2.0.0" }
/// - "2.0.0" -> { epoch: 0, version: "2.0.0" }
/// - "0:1.0" -> { epoch: 0, version: "1.0" }
pub fn parseEpoch(version: []const u8) VersionError!ParsedVersion {
    if (std.mem.indexOf(u8, version, ":")) |colon_idx| {
        if (colon_idx == 0 or colon_idx + 1 >= version.len) {
            return error.InvalidInput;
        }
        const epoch_str = version[0..colon_idx];
        const epoch = std.fmt.parseInt(u32, epoch_str, 10) catch return error.InvalidInput;
        return .{ .epoch = epoch, .version = version[colon_idx + 1 ..] };
    }
    return .{ .epoch = 0, .version = version };
}

/// Compare two version strings using the vercmp algorithm.
///
/// Algorithm:
/// 1. Split into runs of digits and non-digits
/// 2. Compare runs left-to-right:
///    - Digit runs: compare as integers (leading zeros ignored)
///    - Non-digit runs: compare lexicographically (ASCII)
///    - Tilde (~) sorts before everything, including empty string
/// 3. Longer version wins if all compared runs are equal
///
/// Examples:
/// - "1.0" < "1.1" < "1.2" < "1.10" (numeric comparison)
/// - "1.0~alpha" < "1.0~beta" < "1.0~rc1" < "1.0" (tilde pre-release)
pub fn vercmp(a: []const u8, b: []const u8) Order {
    var i: usize = 0;
    var j: usize = 0;

    while (i < a.len or j < b.len) {
        // Handle tilde specially - sorts before everything
        const a_tilde = i < a.len and a[i] == '~';
        const b_tilde = j < b.len and b[j] == '~';

        if (a_tilde and !b_tilde) {
            return .less;
        }
        if (!a_tilde and b_tilde) {
            return .greater;
        }
        if (a_tilde and b_tilde) {
            i += 1;
            j += 1;
            continue;
        }

        // Skip leading separators (non-alphanumeric except tilde)
        while (i < a.len and !isAlphanumeric(a[i]) and a[i] != '~') : (i += 1) {}
        while (j < b.len and !isAlphanumeric(b[j]) and b[j] != '~') : (j += 1) {}

        // If one ended, the other is greater (longer wins)
        if (i >= a.len and j >= b.len) {
            return .equal;
        }
        if (i >= a.len) {
            // a ended, b has more - check if b has tilde
            if (j < b.len and b[j] == '~') {
                return .greater; // b has pre-release suffix, a is newer
            }
            return .less;
        }
        if (j >= b.len) {
            // b ended, a has more - check if a has tilde
            if (i < a.len and a[i] == '~') {
                return .less; // a has pre-release suffix, b is newer
            }
            return .greater;
        }

        // Determine if we're comparing digit runs or non-digit runs
        const a_is_digit = isDigit(a[i]);
        const b_is_digit = isDigit(b[j]);

        // If one is digit and other is not, digits come after letters
        if (a_is_digit and !b_is_digit) {
            return .greater;
        }
        if (!a_is_digit and b_is_digit) {
            return .less;
        }

        if (a_is_digit) {
            // Compare digit runs as integers
            const a_run = getDigitRun(a[i..]);
            const b_run = getDigitRun(b[j..]);

            const cmp = compareDigitRuns(a_run, b_run);
            if (cmp != .equal) {
                return cmp;
            }

            i += a_run.len;
            j += b_run.len;
        } else {
            // Compare non-digit runs lexicographically
            const a_run = getNonDigitRun(a[i..]);
            const b_run = getNonDigitRun(b[j..]);

            const cmp = compareStrings(a_run, b_run);
            if (cmp != .equal) {
                return cmp;
            }

            i += a_run.len;
            j += b_run.len;
        }
    }

    return .equal;
}

/// Compare full package versions including epoch and release.
///
/// Comparison order: (epoch, version, release)
/// 1. Compare epochs (higher epoch wins)
/// 2. Compare versions using vercmp
/// 3. Compare releases (higher release wins)
///
/// Parameters:
/// - a_version: Version string (may include epoch prefix like "1:2.0.0")
/// - a_release: Release number
/// - b_version: Version string (may include epoch prefix)
/// - b_release: Release number
pub fn comparePackageVersions(
    a_version: []const u8,
    a_release: u32,
    b_version: []const u8,
    b_release: u32,
) VersionError!Order {
    const a_parsed = try parseEpoch(a_version);
    const b_parsed = try parseEpoch(b_version);

    // Compare epochs first
    if (a_parsed.epoch < b_parsed.epoch) {
        return .less;
    }
    if (a_parsed.epoch > b_parsed.epoch) {
        return .greater;
    }

    // Compare versions
    const ver_cmp = vercmp(a_parsed.version, b_parsed.version);
    if (ver_cmp != .equal) {
        return ver_cmp;
    }

    // Compare releases
    if (a_release < b_release) {
        return .less;
    }
    if (a_release > b_release) {
        return .greater;
    }

    return .equal;
}

/// Compare two package version strings including epoch, but excluding release.
///
/// Comparison order: (epoch, version)
/// 1. Compare epochs (higher epoch wins)
/// 2. Compare versions using vercmp
pub fn compareVersionStrings(
    a_version: []const u8,
    b_version: []const u8,
) VersionError!Order {
    const a_parsed = try parseEpoch(a_version);
    const b_parsed = try parseEpoch(b_version);

    if (a_parsed.epoch < b_parsed.epoch) {
        return .less;
    }
    if (a_parsed.epoch > b_parsed.epoch) {
        return .greater;
    }

    return vercmp(a_parsed.version, b_parsed.version);
}

// Helper functions

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlphanumeric(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn getDigitRun(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) {}
    return s[0..i];
}

fn getNonDigitRun(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isAlphanumeric(s[i]) and !isDigit(s[i])) : (i += 1) {}
    return s[0..i];
}

/// Compare digit runs as integers (leading zeros ignored)
fn compareDigitRuns(a: []const u8, b: []const u8) Order {
    // Skip leading zeros
    var a_start: usize = 0;
    while (a_start < a.len and a[a_start] == '0') : (a_start += 1) {}
    var b_start: usize = 0;
    while (b_start < b.len and b[b_start] == '0') : (b_start += 1) {}

    const a_trimmed = a[a_start..];
    const b_trimmed = b[b_start..];

    // Longer number (after removing leading zeros) is greater
    if (a_trimmed.len < b_trimmed.len) {
        return .less;
    }
    if (a_trimmed.len > b_trimmed.len) {
        return .greater;
    }

    // Same length, compare digit by digit
    for (a_trimmed, b_trimmed) |ac, bc| {
        if (ac < bc) {
            return .less;
        }
        if (ac > bc) {
            return .greater;
        }
    }

    return .equal;
}

/// Compare strings lexicographically (ASCII)
fn compareStrings(a: []const u8, b: []const u8) Order {
    const min_len = @min(a.len, b.len);
    for (a[0..min_len], b[0..min_len]) |ac, bc| {
        if (ac < bc) {
            return .less;
        }
        if (ac > bc) {
            return .greater;
        }
    }

    if (a.len < b.len) {
        return .less;
    }
    if (a.len > b.len) {
        return .greater;
    }

    return .equal;
}

// Tests

// Spec #3: Epoch prefix parsing
test "parseEpoch with epoch prefix" {
    const result = try parseEpoch("1:2.0.0");
    try std.testing.expectEqual(@as(u32, 1), result.epoch);
    try std.testing.expectEqualStrings("2.0.0", result.version);
}

// Spec #3: Epoch prefix parsing (default epoch 0)
test "parseEpoch without epoch prefix" {
    const result = try parseEpoch("2.0.0");
    try std.testing.expectEqual(@as(u32, 0), result.epoch);
    try std.testing.expectEqualStrings("2.0.0", result.version);
}

// Spec #3: Epoch prefix parsing (explicit zero)
test "parseEpoch with zero epoch" {
    const result = try parseEpoch("0:1.0");
    try std.testing.expectEqual(@as(u32, 0), result.epoch);
    try std.testing.expectEqualStrings("1.0", result.version);
}

// Spec #3: Malformed epoch syntax is invalid input
test "parseEpoch rejects invalid epoch" {
    try std.testing.expectError(error.InvalidInput, parseEpoch("abc:1.0"));
    try std.testing.expectError(error.InvalidInput, parseEpoch(":1.0"));
    try std.testing.expectError(error.InvalidInput, parseEpoch("1:"));
}

// Spec #3: Epoch prefix parsing (large epoch value)
test "parseEpoch with large epoch" {
    const result = try parseEpoch("99:1.0");
    try std.testing.expectEqual(@as(u32, 99), result.epoch);
    try std.testing.expectEqualStrings("1.0", result.version);
}

// Spec #3: Numeric segments compared as integers
test "vercmp numeric comparison" {
    try std.testing.expectEqual(Order.less, vercmp("1.0", "1.1"));
    try std.testing.expectEqual(Order.less, vercmp("1.1", "1.2"));
    try std.testing.expectEqual(Order.less, vercmp("1.2", "1.10"));
    try std.testing.expectEqual(Order.less, vercmp("1.9", "1.10"));
    try std.testing.expectEqual(Order.equal, vercmp("1.0", "1.0"));
    try std.testing.expectEqual(Order.greater, vercmp("2.0", "1.0"));
}

// Spec #3: Tilde sorts before everything
test "vercmp tilde pre-release" {
    try std.testing.expectEqual(Order.less, vercmp("1.0~alpha", "1.0~beta"));
    try std.testing.expectEqual(Order.less, vercmp("1.0~beta", "1.0~rc1"));
    try std.testing.expectEqual(Order.less, vercmp("1.0~rc1", "1.0"));
    try std.testing.expectEqual(Order.less, vercmp("1.0~rc1", "1.0~rc2"));
}

// Spec #3: Tilde sorts before empty string
test "vercmp tilde sorts before empty" {
    try std.testing.expectEqual(Order.less, vercmp("1.0~", "1.0"));
    try std.testing.expectEqual(Order.less, vercmp("1.0~a", "1.0"));
}

// Spec #3: Leading zeros ignored in digit runs
test "vercmp leading zeros ignored" {
    try std.testing.expectEqual(Order.equal, vercmp("1.01", "1.1"));
    try std.testing.expectEqual(Order.equal, vercmp("1.001", "1.1"));
    try std.testing.expectEqual(Order.less, vercmp("1.01", "1.2"));
}

// Spec #3: Mixed alphanumeric runs compared correctly
test "vercmp alpha vs numeric" {
    // Digits come after letters in comparison
    try std.testing.expectEqual(Order.greater, vercmp("1.0a1", "1.0a"));
    try std.testing.expectEqual(Order.less, vercmp("1.0", "1.0a"));
}

// Spec #3: Longer version wins when all compared runs are equal
test "vercmp longer version wins" {
    try std.testing.expectEqual(Order.greater, vercmp("1.0.1", "1.0"));
    try std.testing.expectEqual(Order.less, vercmp("1.0", "1.0.1"));
}

// Spec #3: Numeric segments compared as integers
test "vercmp complex versions" {
    try std.testing.expectEqual(Order.less, vercmp("2.6.32", "2.6.33"));
    try std.testing.expectEqual(Order.greater, vercmp("2.6.32.1", "2.6.32"));
    try std.testing.expectEqual(Order.equal, vercmp("1.0.0", "1.0.0"));
}

// Spec #3: Non-alphanumeric separators are equivalent
test "vercmp with separators" {
    try std.testing.expectEqual(Order.equal, vercmp("1.0.0", "1-0-0"));
    try std.testing.expectEqual(Order.equal, vercmp("1_0_0", "1.0.0"));
}

// Spec #3: Epoch prefix overrides version comparison
test "comparePackageVersions epoch wins" {
    try std.testing.expectEqual(Order.greater, try comparePackageVersions("1:1.0", 1, "2.0", 1));
    try std.testing.expectEqual(Order.less, try comparePackageVersions("2.0", 1, "1:1.0", 1));
}

// Spec #3: Vercmp numeric comparison via comparePackageVersions
test "comparePackageVersions version comparison" {
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0", 1, "1.1", 1));
    try std.testing.expectEqual(Order.greater, try comparePackageVersions("2.0", 1, "1.0", 1));
    try std.testing.expectEqual(Order.equal, try comparePackageVersions("1.0", 1, "1.0", 1));
}

// Spec #3: Release is integer tie-breaker
test "comparePackageVersions release tie-breaker" {
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0", 1, "1.0", 2));
    try std.testing.expectEqual(Order.greater, try comparePackageVersions("1.0", 2, "1.0", 1));
}

// Spec #3: Epoch, version, and release comparison order
test "comparePackageVersions full comparison" {
    // Same epoch, different version
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1:1.0", 1, "1:1.1", 1));

    // Different epoch, same version
    try std.testing.expectEqual(Order.greater, try comparePackageVersions("2:1.0", 1, "1:1.0", 1));

    // Same version and epoch, different release
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1:1.0", 1, "1:1.0", 2));
}

// Spec #3: Epoch, version, release, and tilde spec examples
test "comparePackageVersions spec examples" {
    // From spec: 1.0 < 1.1 < 1.2 < 1.10
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0", 1, "1.1", 1));
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.1", 1, "1.2", 1));
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.2", 1, "1.10", 1));

    // From spec: 1.0~alpha < 1.0~beta < 1.0~rc1 < 1.0
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0~alpha", 1, "1.0~beta", 1));
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0~beta", 1, "1.0~rc1", 1));
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0~rc1", 1, "1.0", 1));

    // From spec: 1:1.0 > 2.0 (epoch wins)
    try std.testing.expectEqual(Order.greater, try comparePackageVersions("1:1.0", 1, "2.0", 1));

    // From spec: 1.0-1 < 1.0-2 (release tie-breaker)
    try std.testing.expectEqual(Order.less, try comparePackageVersions("1.0", 1, "1.0", 2));
}

test "comparePackageVersions rejects invalid epoch syntax" {
    try std.testing.expectError(error.InvalidInput, comparePackageVersions("abc:1.0", 1, "1.0", 1));
    try std.testing.expectError(error.InvalidInput, compareVersionStrings("1.0", ":2.0"));
}

// Spec #3: Edge case - empty version strings
test "vercmp empty strings" {
    try std.testing.expectEqual(Order.equal, vercmp("", ""));
    try std.testing.expectEqual(Order.less, vercmp("", "1.0"));
    try std.testing.expectEqual(Order.greater, vercmp("1.0", ""));
}

// Spec #3: Edge case - separator-only strings
test "vercmp only separators" {
    try std.testing.expectEqual(Order.equal, vercmp("...", "---"));
    try std.testing.expectEqual(Order.less, vercmp("...", "1"));
}
