const std = @import("std");
const mere = @import("mere.zig");
const kdl = @import("kdl.zig");

const Span = struct {
    start: usize,
    end: usize,
    line: ?u32 = null,
    column: ?u32 = null,
};

const ValueKind = enum {
    string,
    integer,
    boolean,
    float,
};

const ArgSpec = struct {
    kind: ValueKind,
    min: usize,
    max: ?usize = null,
    label: ?[]const u8 = null,
};

const PropertySpec = struct {
    name: []const u8,
    kind: ValueKind,
    required: bool = false,
};

const PropertyPolicy = union(enum) {
    none,
    fixed: []const PropertySpec,
    any: ValueKind,
};

const NodeSpec = struct {
    name: []const u8,
    required: bool = false,
    repeatable: bool = false,
    args: ?ArgSpec = null,
    properties: PropertyPolicy = .none,
    children: []const NodeSpec = &[_]NodeSpec{},
    any_child_args: ?ArgSpec = null,
};

pub fn validateConfig(ctx: *mere.Context, nodes: []const kdl.Node) !void {
    try validateNodes(ctx, nodes, &config_top_level, "config.kdl", error.InvalidConfig);
}

pub fn validateRecipe(ctx: *mere.Context, nodes: []const kdl.Node) !void {
    try validateNodes(ctx, nodes, &recipe_top_level, "recipe.kdl", error.InvalidInput);
}

fn validateNodes(
    ctx: *mere.Context,
    nodes: []const kdl.Node,
    allowed: []const NodeSpec,
    subject: []const u8,
    error_value: anytype,
) !void {
    var counts = std.StringHashMap(usize).init(ctx.allocator);
    defer counts.deinit();

    for (nodes) |node| {
        const entry = try counts.getOrPut(node.name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var seen = std.StringHashMap(usize).init(ctx.allocator);
    defer seen.deinit();

    for (nodes) |node| {
        const spec = findSpec(allowed, node.name) orelse {
            return failPath(ctx, subject, node.name, "unknown node", error_value);
        };

        const total = counts.get(node.name) orelse 1;
        if (!spec.repeatable and total > 1) {
            const dup_path = formatRootPath(ctx, node.name, @as(?usize, 0)) catch {
                return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
            };
            defer ctx.allocator.free(dup_path);
            return failPath(ctx, subject, dup_path, "duplicate node", error_value);
        }
        const entry = try seen.getOrPut(node.name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        const idx = entry.value_ptr.*;
        entry.value_ptr.* += 1;

        const path = formatRootPath(ctx, node.name, if (total > 1) idx else null) catch {
            return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
        };
        defer ctx.allocator.free(path);

        try validateNode(ctx, &node, spec.*, path, subject, error_value);
    }

    for (allowed) |spec| {
        if (!spec.required) continue;
        if (!counts.contains(spec.name)) {
            return failPath(ctx, subject, spec.name, "missing required node", error_value);
        }
    }
}

fn validateNode(
    ctx: *mere.Context,
    node: *const kdl.Node,
    spec: NodeSpec,
    path: []const u8,
    subject: []const u8,
    error_value: anytype,
) !void {
    if (spec.args) |arg_spec| {
        try validateArgs(ctx, node, arg_spec, path, subject, error_value);
    } else if (node.arguments.items.len > 0) {
        return failPath(ctx, subject, path, "unexpected arguments", error_value);
    }

    try validateProperties(ctx, node, spec.properties, path, subject, error_value);

    if (spec.any_child_args) |child_arg_spec| {
        // All children allowed, but must match the arg spec and have no properties or children.
        for (node.children.items) |child| {
            const child_path = formatChildPath(ctx, path, child.name, null) catch {
                return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
            };
            defer ctx.allocator.free(child_path);

            try validateArgs(ctx, &child, child_arg_spec, child_path, subject, error_value);
            if (child.properties.count() > 0) {
                return failPath(ctx, subject, child_path, "unexpected properties", error_value);
            }
            if (child.children.items.len > 0) {
                return failPath(ctx, subject, child_path, "unexpected child nodes", error_value);
            }
        }
        return;
    }

    if (spec.children.len == 0) {
        if (node.children.items.len > 0) {
            return failPath(ctx, subject, path, "unexpected child nodes", error_value);
        }
        return;
    }

    var counts = std.StringHashMap(usize).init(ctx.allocator);
    defer counts.deinit();

    for (node.children.items) |child| {
        const entry = try counts.getOrPut(child.name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var seen = std.StringHashMap(usize).init(ctx.allocator);
    defer seen.deinit();

    for (node.children.items) |child| {
        const child_spec = findSpec(spec.children, child.name) orelse {
            const child_path = formatChildPath(ctx, path, child.name, null) catch {
                return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
            };
            defer ctx.allocator.free(child_path);
            return failPath(ctx, subject, child_path, "unknown child node", error_value);
        };

        const total = counts.get(child.name) orelse 1;
        if (!child_spec.repeatable and total > 1) {
            const dup_path = formatChildPath(ctx, path, child.name, @as(?usize, 0)) catch {
                return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
            };
            defer ctx.allocator.free(dup_path);
            return failPath(ctx, subject, dup_path, "duplicate child node", error_value);
        }
        const entry = try seen.getOrPut(child.name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        const idx = entry.value_ptr.*;
        entry.value_ptr.* += 1;

        const child_path = formatChildPath(ctx, path, child.name, if (total > 1) idx else null) catch {
            return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
        };
        defer ctx.allocator.free(child_path);

        try validateNode(ctx, &child, child_spec.*, child_path, subject, error_value);
    }

    for (spec.children) |child_spec| {
        if (!child_spec.required) continue;
        if (!counts.contains(child_spec.name)) {
            const child_path = formatChildPath(ctx, path, child_spec.name, null) catch {
                return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
            };
            defer ctx.allocator.free(child_path);
            return failPath(ctx, subject, child_path, "missing required child node", error_value);
        }
    }
}

fn validateArgs(
    ctx: *mere.Context,
    node: *const kdl.Node,
    spec: ArgSpec,
    path: []const u8,
    subject: []const u8,
    error_value: anytype,
) !void {
    const count = node.arguments.items.len;
    if (count < spec.min) {
        return failArg(ctx, subject, path, spec, count, "missing required argument", error_value);
    }
    if (spec.max) |max| {
        if (count > max) {
            return failArg(ctx, subject, path, spec, count, "too many arguments", error_value);
        }
    }

    for (node.arguments.items, 0..) |arg, idx| {
        const kind = valueKind(&arg) orelse {
            return failArgAt(ctx, subject, path, spec, idx, "unsupported argument type", error_value);
        };
        if (kind != spec.kind) {
            return failArgAt(
                ctx,
                subject,
                path,
                spec,
                idx,
                expectedGot(spec.kind, kind),
                error_value,
            );
        }
    }
}

fn validateProperties(
    ctx: *mere.Context,
    node: *const kdl.Node,
    policy: PropertyPolicy,
    path: []const u8,
    subject: []const u8,
    error_value: anytype,
) !void {
    switch (policy) {
        .none => {
            if (node.properties.count() > 0) {
                return failPath(ctx, subject, path, "unexpected properties", error_value);
            }
        },
        .any => |kind| {
            var iter = node.properties.iterator();
            while (iter.next()) |entry| {
                const value_kind = valueKind(entry.value_ptr) orelse {
                    return failPath(ctx, subject, path, "unsupported property type", error_value);
                };
                if (value_kind != kind) {
                    const prop_path = formatChildPath(ctx, path, entry.key_ptr.*, null) catch {
                        return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
                    };
                    defer ctx.allocator.free(prop_path);
                    return failPath(ctx, subject, prop_path, expectedGot(kind, value_kind), error_value);
                }
            }
        },
        .fixed => |specs| {
            var iter = node.properties.iterator();
            while (iter.next()) |entry| {
                const spec = findProperty(specs, entry.key_ptr.*) orelse {
                    const prop_path = formatChildPath(ctx, path, entry.key_ptr.*, null) catch {
                        return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
                    };
                    defer ctx.allocator.free(prop_path);
                    return failPath(ctx, subject, prop_path, "unknown property", error_value);
                };
                const value_kind = valueKind(entry.value_ptr) orelse {
                    return failPath(ctx, subject, path, "unsupported property type", error_value);
                };
                if (value_kind != spec.kind) {
                    const prop_path = formatChildPath(ctx, path, entry.key_ptr.*, null) catch {
                        return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
                    };
                    defer ctx.allocator.free(prop_path);
                    return failPath(ctx, subject, prop_path, expectedGot(spec.kind, value_kind), error_value);
                }
            }

            for (specs) |spec| {
                if (!spec.required) continue;
                if (node.getProperty(spec.name) == null) {
                    const prop_path = formatChildPath(ctx, path, spec.name, null) catch {
                        return ctx.fail(error.OutOfMemory, subject, "out of memory building error path");
                    };
                    defer ctx.allocator.free(prop_path);
                    return failPath(ctx, subject, prop_path, "missing required property", error_value);
                }
            }
        },
    }
}

fn valueKind(val: *const kdl.Value) ?ValueKind {
    return switch (val.type) {
        .string => .string,
        .integer => .integer,
        .boolean => .boolean,
        .float => .float,
        else => null,
    };
}

fn findSpec(specs: []const NodeSpec, name: []const u8) ?*const NodeSpec {
    for (specs) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn findProperty(specs: []const PropertySpec, name: []const u8) ?PropertySpec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn failPath(
    ctx: *mere.Context,
    subject: []const u8,
    path: []const u8,
    message: []const u8,
    error_value: anytype,
) !void {
    const msg = std.fmt.allocPrint(ctx.allocator, "{s}: {s}", .{ path, message }) catch {
        return ctx.fail(error.OutOfMemory, subject, "out of memory building error message");
    };
    defer ctx.allocator.free(msg);
    return ctx.fail(error_value, subject, msg);
}

fn failArg(
    ctx: *mere.Context,
    subject: []const u8,
    path: []const u8,
    spec: ArgSpec,
    count: usize,
    message: []const u8,
    error_value: anytype,
) !void {
    const label = spec.label orelse "arg";
    const msg = std.fmt.allocPrint(ctx.allocator, "{s}.{s}: {s} (got {d})", .{ path, label, message, count }) catch {
        return ctx.fail(error.OutOfMemory, subject, "out of memory building error message");
    };
    defer ctx.allocator.free(msg);
    return ctx.fail(error_value, subject, msg);
}

fn failArgAt(
    ctx: *mere.Context,
    subject: []const u8,
    path: []const u8,
    spec: ArgSpec,
    index: usize,
    message: []const u8,
    error_value: anytype,
) !void {
    const label = spec.label orelse "arg";
    const msg = std.fmt.allocPrint(ctx.allocator, "{s}.{s}[{d}]: {s}", .{ path, label, index, message }) catch {
        return ctx.fail(error.OutOfMemory, subject, "out of memory building error message");
    };
    defer ctx.allocator.free(msg);
    return ctx.fail(error_value, subject, msg);
}

fn expectedGot(expected: ValueKind, got: ValueKind) []const u8 {
    return switch (expected) {
        .string => switch (got) {
            .string => "expected string, got string",
            .integer => "expected string, got integer",
            .boolean => "expected string, got boolean",
            .float => "expected string, got float",
        },
        .integer => switch (got) {
            .string => "expected integer, got string",
            .integer => "expected integer, got integer",
            .boolean => "expected integer, got boolean",
            .float => "expected integer, got float",
        },
        .boolean => switch (got) {
            .string => "expected boolean, got string",
            .integer => "expected boolean, got integer",
            .boolean => "expected boolean, got boolean",
            .float => "expected boolean, got float",
        },
        .float => switch (got) {
            .string => "expected float, got string",
            .integer => "expected float, got integer",
            .boolean => "expected float, got boolean",
            .float => "expected float, got float",
        },
    };
}

fn formatChildPath(
    ctx: *mere.Context,
    base: []const u8,
    name: []const u8,
    idx: ?usize,
) ![]const u8 {
    if (idx) |i| {
        return std.fmt.allocPrint(ctx.allocator, "{s}.{s}[{d}]", .{ base, name, i });
    }
    return std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ base, name });
}

fn formatRootPath(
    ctx: *mere.Context,
    name: []const u8,
    idx: ?usize,
) ![]const u8 {
    if (idx) |i| {
        return std.fmt.allocPrint(ctx.allocator, "{s}[{d}]", .{ name, i });
    }
    return std.fmt.allocPrint(ctx.allocator, "{s}", .{name});
}

const config_settings_children = [_]NodeSpec{
    .{ .name = "color", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "sync-ttl", .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "sync-timeout", .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
};

const config_repo_children = [_]NodeSpec{
    .{ .name = "url", .required = true, .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "trusted-fingerprints", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "priority", .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "enabled", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "sync-ttl", .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "sync-timeout", .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
};

const config_top_level = [_]NodeSpec{
    .{ .name = "settings", .children = &config_settings_children },
    .{
        .name = "repo",
        .repeatable = true,
        .args = .{ .kind = .string, .min = 1, .max = 1, .label = "name" },
        .children = &config_repo_children,
    },
};

const recipe_env_node = NodeSpec{
    .name = "env",
    .properties = .{ .any = .string },
};

const recipe_meta_children = [_]NodeSpec{
    .{ .name = "name", .required = true, .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "version", .required = true, .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "release", .required = true, .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "description", .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "url", .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "licenses", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "archs", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "depends", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "needs-root", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    recipe_env_node,
};

const recipe_phase_children = [_]NodeSpec{
    .{ .name = "script", .required = true, .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    recipe_env_node,
};

const recipe_source_children = [_]NodeSpec{
    .{ .name = "blake3", .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "save-as", .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
};

const recipe_service_children = [_]NodeSpec{
    .{ .name = "type", .required = true, .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "command", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "up", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "down", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "depends-on", .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "ready-notification", .args = .{ .kind = .integer, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "essential", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "log", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "env", .any_child_args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
};

const recipe_package_children = [_]NodeSpec{
    .{ .name = "files", .required = true, .args = .{ .kind = .string, .min = 1, .label = "value" } },
    .{ .name = "strip", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "compress-manpages", .args = .{ .kind = .boolean, .min = 1, .max = 1, .label = "value" } },
    .{ .name = "arch", .args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" } },
    .{
        .name = "service",
        .repeatable = true,
        .args = .{ .kind = .string, .min = 1, .max = 1, .label = "name" },
        .children = &recipe_service_children,
    },
};

const recipe_top_level = [_]NodeSpec{
    .{ .name = "recipe", .required = true, .children = &recipe_meta_children },
    .{
        .name = "vars",
        .any_child_args = .{ .kind = .string, .min = 1, .max = 1, .label = "value" },
    },
    .{
        .name = "source",
        .repeatable = true,
        .args = .{ .kind = .string, .min = 1, .max = 1, .label = "url" },
        .children = &recipe_source_children,
    },
    .{ .name = "prepare", .children = &recipe_phase_children },
    .{ .name = "build", .children = &recipe_phase_children },
    .{ .name = "check", .children = &recipe_phase_children },
    .{ .name = "install", .children = &recipe_phase_children },
    .{
        .name = "package",
        .required = true,
        .repeatable = true,
        .args = .{ .kind = .string, .min = 1, .max = 1, .label = "name" },
        .children = &recipe_package_children,
    },
};

fn parseNodes(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(kdl.Node) {
    return kdl.parseDocument(allocator, input);
}

fn deinitNodes(allocator: std.mem.Allocator, nodes: *std.ArrayList(kdl.Node)) void {
    for (nodes.items) |*node| {
        node.deinit();
    }
    nodes.deinit(allocator);
}

fn expectDiagContains(ctx: *mere.Context, needle: []const u8) !void {
    const diag = ctx.getDiagnosticContext();
    try std.testing.expect(diag.details != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, diag.details.?, 1, needle));
}

test "validateConfig accepts empty config" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    var nodes = try parseNodes(ctx.allocator, "");
    defer deinitNodes(ctx.allocator, &nodes);

    try validateConfig(ctx, nodes.items);
}

test "validateConfig rejects unknown node" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    var nodes = try parseNodes(ctx.allocator, "mystery \"value\"");
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidConfig, validateConfig(ctx, nodes.items));
    const diag = ctx.getDiagnosticContext();
    try std.testing.expectEqualStrings("config.kdl", diag.subject.?);
    try expectDiagContains(ctx, "unknown node");
}

test "validateConfig rejects duplicate settings" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    var nodes = try parseNodes(ctx.allocator, "settings {}\nsettings {}");
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidConfig, validateConfig(ctx, nodes.items));
    try expectDiagContains(ctx, "duplicate node");
}

test "validateConfig requires repo url" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    var nodes = try parseNodes(ctx.allocator, "repo \"main\" {}");
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidConfig, validateConfig(ctx, nodes.items));
    try expectDiagContains(ctx, "missing required child node");
}

test "validateRecipe accepts minimal recipe" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const input =
        \\recipe {
        \\  name "demo"
        \\  version "1.0.0"
        \\  release 1
        \\}
        \\package "demo" {
        \\  files "/usr/bin/demo"
        \\}
    ;
    var nodes = try parseNodes(ctx.allocator, input);
    defer deinitNodes(ctx.allocator, &nodes);

    try validateRecipe(ctx, nodes.items);
}

test "validateRecipe rejects unknown top-level node" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    var nodes = try parseNodes(ctx.allocator, "bogus \"value\"");
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidInput, validateRecipe(ctx, nodes.items));
    try expectDiagContains(ctx, "unknown node");
}

test "validateRecipe rejects env property type" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const input =
        \\recipe {
        \\  name "demo"
        \\  version "1.0.0"
        \\  release 1
        \\  env FOO=1
        \\}
        \\package "demo" {
        \\  files "/usr/bin/demo"
        \\}
    ;
    var nodes = try parseNodes(ctx.allocator, input);
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidInput, validateRecipe(ctx, nodes.items));
    try expectDiagContains(ctx, "expected string, got integer");
}

test "validateRecipe rejects vars child properties" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const input =
        \\recipe {
        \\  name "demo"
        \\  version "1.0.0"
        \\  release 1
        \\}
        \\vars {
        \\  foo "bar" extra=1
        \\}
        \\package "demo" {
        \\  files "/usr/bin/demo"
        \\}
    ;
    var nodes = try parseNodes(ctx.allocator, input);
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidInput, validateRecipe(ctx, nodes.items));
    try expectDiagContains(ctx, "unexpected properties");
}

test "validateRecipe rejects unknown source child" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const input =
        \\recipe {
        \\  name "demo"
        \\  version "1.0.0"
        \\  release 1
        \\}
        \\source "https://example.com/demo.tar.gz" {
        \\  sha256 "deadbeef"
        \\}
        \\package "demo" {
        \\  files "/usr/bin/demo"
        \\}
    ;
    var nodes = try parseNodes(ctx.allocator, input);
    defer deinitNodes(ctx.allocator, &nodes);

    try std.testing.expectError(error.InvalidInput, validateRecipe(ctx, nodes.items));
    try expectDiagContains(ctx, "unknown child node");
}
