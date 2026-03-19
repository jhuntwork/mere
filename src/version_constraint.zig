const std = @import("std");
const version_mod = @import("version.zig");

pub const ConstraintError = error{
    InvalidConstraint,
};

pub const Operator = enum {
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,

    pub fn asString(self: Operator) []const u8 {
        return switch (self) {
            .eq => "=",
            .ne => "!=",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
        };
    }
};

pub const Requirement = struct {
    name: []const u8,
    constraint_expr: ?[]const u8 = null,
};

const ParsedClause = struct {
    op: Operator,
    version_text: []const u8,
    release: ?u32 = null,
};

pub fn splitRequirementToken(token: []const u8) ConstraintError!Requirement {
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidConstraint;

    const op_idx = firstOperatorIndex(trimmed);
    if (op_idx == null) {
        return .{ .name = trimmed, .constraint_expr = null };
    }

    const idx = op_idx.?;
    if (idx == 0) return error.InvalidConstraint;
    const name = std.mem.trim(u8, trimmed[0..idx], " \t\r\n");
    if (name.len == 0) return error.InvalidConstraint;

    const expr = std.mem.trim(u8, trimmed[idx..], " \t\r\n");
    if (expr.len == 0) return error.InvalidConstraint;
    try validateConstraintExpr(expr);

    return .{ .name = name, .constraint_expr = expr };
}

pub fn validateConstraintExpr(expr: []const u8) ConstraintError!void {
    var it = std.mem.splitScalar(u8, expr, ',');
    var count: usize = 0;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidConstraint;
        _ = try parseClause(trimmed);
        count += 1;
    }
    if (count == 0) return error.InvalidConstraint;
}

pub fn canonicalizeConstraintExpr(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    try validateConstraintExpr(expr);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, expr, ',');
    var first = true;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        const clause = try parseClause(trimmed);
        if (!first) try out.appendSlice(allocator, ",");
        first = false;
        try out.appendSlice(allocator, clause.op.asString());
        try out.appendSlice(allocator, clause.version_text);
    }

    return out.toOwnedSlice(allocator);
}

pub fn matchesConstraintExpr(expr: []const u8, pkg_version: []const u8, pkg_release: u32) ConstraintError!bool {
    try validateConstraintExpr(expr);
    var it = std.mem.splitScalar(u8, expr, ',');
    while (it.next()) |part| {
        const clause = try parseClause(std.mem.trim(u8, part, " \t\r\n"));
        if (!(try matchesClause(clause, pkg_version, pkg_release))) return false;
    }
    return true;
}

fn firstOperatorIndex(s: []const u8) ?usize {
    for (s, 0..) |ch, i| {
        if (ch == '!' or ch == '<' or ch == '>' or ch == '=') return i;
    }
    return null;
}

fn parseClause(clause: []const u8) ConstraintError!ParsedClause {
    if (clause.len == 0) return error.InvalidConstraint;

    var op: Operator = .eq;
    var rest = clause;

    if (std.mem.startsWith(u8, rest, ">=")) {
        op = .gte;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "<=")) {
        op = .lte;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "!=")) {
        op = .ne;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "=")) {
        op = .eq;
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, ">")) {
        op = .gt;
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, "<")) {
        op = .lt;
        rest = rest[1..];
    } else {
        op = .eq;
    }

    const version_text = std.mem.trim(u8, rest, " \t\r\n");
    if (version_text.len == 0) return error.InvalidConstraint;

    const rel = parseOptionalRelease(version_text);
    _ = version_mod.parseEpoch(stripReleaseSuffix(version_text, rel)) catch return error.InvalidConstraint;
    return .{
        .op = op,
        .version_text = version_text,
        .release = rel,
    };
}

fn parseOptionalRelease(version_text: []const u8) ?u32 {
    const dash_idx = std.mem.lastIndexOfScalar(u8, version_text, '-') orelse return null;
    if (dash_idx + 1 >= version_text.len) return null;
    const suffix = version_text[dash_idx + 1 ..];
    if (suffix.len == 0) return null;
    for (suffix) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(u32, suffix, 10) catch null;
}

fn matchesClause(clause: ParsedClause, pkg_version: []const u8, pkg_release: u32) ConstraintError!bool {
    const compare_version_text = stripReleaseSuffix(clause.version_text, clause.release);
    const cmp = if (clause.release) |rel|
        version_mod.comparePackageVersions(pkg_version, pkg_release, compare_version_text, rel) catch return error.InvalidConstraint
    else
        version_mod.compareVersionStrings(pkg_version, compare_version_text) catch return error.InvalidConstraint;

    return switch (clause.op) {
        .eq => cmp == .equal,
        .ne => cmp != .equal,
        .lt => cmp == .less,
        .lte => cmp == .less or cmp == .equal,
        .gt => cmp == .greater,
        .gte => cmp == .greater or cmp == .equal,
    };
}

fn stripReleaseSuffix(version_text: []const u8, release: ?u32) []const u8 {
    _ = release orelse return version_text;
    const dash_idx = std.mem.lastIndexOfScalar(u8, version_text, '-') orelse return version_text;
    if (dash_idx == 0) return version_text;
    return version_text[0..dash_idx];
}

test "splitRequirementToken supports name and expression" {
    const req = try splitRequirementToken("foo>=1.2,<2.0");
    try std.testing.expectEqualStrings("foo", req.name);
    try std.testing.expect(req.constraint_expr != null);
    try std.testing.expectEqualStrings(">=1.2,<2.0", req.constraint_expr.?);
}

test "canonicalize constraint strips whitespace and normalizes operators" {
    const expr = try canonicalizeConstraintExpr(std.testing.allocator, " >=1.2 , < 2.0 ");
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings(">=1.2,<2.0", expr);
}

test "matchesConstraintExpr supports release-aware and version-only clauses" {
    try std.testing.expect(try matchesConstraintExpr("=1.2.3", "1.2.3", 5));
    try std.testing.expect(!(try matchesConstraintExpr("=1.2.3-6", "1.2.3", 5)));
    try std.testing.expect(try matchesConstraintExpr("=1.2.3-5", "1.2.3", 5));
    try std.testing.expect(try matchesConstraintExpr(">=1.2,<2.0", "1.5.0", 1));
}

test "validateConstraintExpr rejects invalid epoch syntax in clause version" {
    try std.testing.expectError(error.InvalidConstraint, validateConstraintExpr(">=abc:1.0"));
    try std.testing.expectError(error.InvalidConstraint, validateConstraintExpr("=:1.0"));
}

test "matchesConstraintExpr rejects invalid package version syntax" {
    try std.testing.expectError(error.InvalidConstraint, matchesConstraintExpr(">=1.0", "abc:1.0", 1));
}
