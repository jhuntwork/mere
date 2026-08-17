//! Machine-readable description of mere's command surface.
//!
//! A consumer with no continuity of memory has to learn the interface at
//! runtime rather than rely on being told about it out of band, and being told
//! is exactly what goes stale (see "Current conformance" in the spec's
//! Consumers and the Interface Contract). Everything emitted here is already
//! declared in `CommandMeta` and `types.Flag`; this walks it and writes it out.
//!
//! JSON rather than KDL, even though KDL is what mere reads: mere has a KDL
//! parser and no KDL writer, and this output exists to be parsed by arbitrary
//! other tools rather than edited by hand.
//!
//! Output ordering is sorted, not hash order, so that two runs against the same
//! binary produce byte-identical output and a consumer diffing it sees only real
//! changes.

const std = @import("std");
const types = @import("types.zig");
const command = @import("command.zig");
const mere = @import("mere");
const pathmod = mere.path;

/// Bump when the shape of this document changes in a way that would break a
/// consumer parsing it. Additive fields do not require a bump.
pub const SCHEMA_VERSION: u32 = 1;

// This file writes fields one at a time, so a field added to Flag, Arg, or
// CommandMeta would be silently left out of the document - the one way describe
// can drift from the real interface, since commands and flags themselves are
// read straight from the registered tree.
//
// These lists close that gap: adding a field to any of the three breaks the
// build here until someone either emits it or records that it is internal.
const emitted_flag_fields = [_][]const u8{
    "name", "short", "description", "flag_type", "value_name", "value_optional", "required", "default_value",
};
const emitted_arg_fields = [_][]const u8{ "name", "description", "required" };
const emitted_command_fields = [_][]const u8{ "name", "description", "args", "flags", "group" };
// Read by describe but deliberately absent from the output: `hidden` selects
// what to emit, and `order` only affects how help lays commands out.
const internal_command_fields = [_][]const u8{ "hidden", "order" };

comptime {
    assertAllFieldsAccountedFor(types.Flag, &emitted_flag_fields, &.{});
    assertAllFieldsAccountedFor(types.Arg, &emitted_arg_fields, &.{});
    assertAllFieldsAccountedFor(command.CommandMeta, &emitted_command_fields, &internal_command_fields);
}

fn assertAllFieldsAccountedFor(
    comptime T: type,
    comptime emitted: []const []const u8,
    comptime internal: []const []const u8,
) void {
    outer: for (std.meta.fields(T)) |field| {
        for (emitted) |name| if (std.mem.eql(u8, field.name, name)) continue :outer;
        for (internal) |name| if (std.mem.eql(u8, field.name, name)) continue :outer;
        @compileError("`" ++ @typeName(T) ++ "." ++ field.name ++
            "` is neither emitted by `mere describe` nor listed as internal. Add it to the" ++
            " output and to `emitted_*_fields`, or to `internal_command_fields` if it should" ++
            " not be described.");
    }
}

/// Stated explicitly rather than inferred: writeCommand and writeSubcommands
/// are mutually recursive, and inferred error sets cannot resolve a cycle.
pub const DescribeError = std.Io.Writer.Error || error{ OutOfMemory, NoSpaceLeft };

/// The surface being described. Held module-level and set once during CLI
/// setup, following the same pattern as `path.setRuntimeIo`: a command handler
/// receives only a context and parsed arguments, so it has no other route to
/// the command tree it needs to walk. Registering `describe` as an ordinary
/// command rather than intercepting it earlier is what makes it appear in
/// `--help` and in its own output - a self-description command nobody can
/// discover is not much use.
const Surface = struct {
    program_name: []const u8,
    global_flags: []const types.Flag,
    root: *const command.Command,
};

var surface: ?Surface = null;

pub fn setSurface(program_name: []const u8, global_flags: []const types.Flag, root: *const command.Command) void {
    surface = .{ .program_name = program_name, .global_flags = global_flags, .root = root };
}

const describe_meta = command.CommandMeta{
    .group = "Introspection",
    .order = 200,
    .name = "describe",
    .description = "Print a machine-readable description of the command surface",
};

fn handleDescribe(ctx: *mere.Context, args: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    _ = args;
    const s = surface orelse return mere.errors.MereError.Internal;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(pathmod.currentIo(), &stdout_buffer);
    writeDocument(ctx.allocator, &stdout_writer.interface, s.program_name, s.global_flags, s.root) catch {
        return mere.errors.MereError.Internal;
    };
    stdout_writer.interface.flush() catch return mere.errors.MereError.Internal;
    return types.CommandResult{ .success = true };
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, describe_meta, handleDescribe);
    return cmd;
}

pub fn writeDocument(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    program_name: []const u8,
    global_flags: []const types.Flag,
    root: ?*const command.Command,
) DescribeError!void {
    try out.writeAll("{\n");
    try out.print("  \"schema_version\": {d},\n", .{SCHEMA_VERSION});
    try writeStringField(out, "  ", "program", program_name, true);
    try writeStringField(out, "  ", "version", command.build_zon.version, true);

    try out.writeAll("  \"global_flags\": ");
    try writeFlags(out, "  ", global_flags);
    try out.writeAll(",\n");

    try out.writeAll("  \"commands\": ");
    if (root) |r| {
        try writeSubcommands(allocator, out, "  ", r);
    } else {
        try out.writeAll("[]");
    }
    try out.writeAll("\n}\n");
}

fn writeCommand(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    indent: []const u8,
    cmd: *const command.Command,
) DescribeError!void {
    var child_indent_buf: [64]u8 = undefined;
    const inner = try std.fmt.bufPrint(&child_indent_buf, "{s}  ", .{indent});

    try out.print("{{\n", .{});
    try writeStringField(out, inner, "name", cmd.meta.name, true);
    try writeStringField(out, inner, "description", cmd.meta.description, true);
    if (cmd.meta.group) |g| {
        try writeStringField(out, inner, "group", g, true);
    }

    try out.print("{s}\"args\": ", .{inner});
    try writeArgs(out, inner, cmd.meta.args);
    try out.writeAll(",\n");

    try out.print("{s}\"flags\": ", .{inner});
    try writeFlags(out, inner, cmd.meta.flags);

    if (cmd.subcommands.count() > 0) {
        try out.writeAll(",\n");
        try out.print("{s}\"commands\": ", .{inner});
        try writeSubcommands(allocator, out, inner, cmd);
    }

    try out.print("\n{s}}}", .{indent});
}

/// Emit a command's subcommands as a JSON array, sorted by name. Hidden
/// commands are omitted, matching what `--help` shows.
fn writeSubcommands(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    indent: []const u8,
    parent: *const command.Command,
) DescribeError!void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);

    var it = parent.subcommands.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.meta.hidden) continue;
        try names.append(allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    if (names.items.len == 0) {
        try out.writeAll("[]");
        return;
    }

    var child_indent_buf: [64]u8 = undefined;
    const inner = try std.fmt.bufPrint(&child_indent_buf, "{s}  ", .{indent});

    try out.writeAll("[\n");
    for (names.items, 0..) |name, i| {
        const child = parent.subcommands.get(name).?;
        try out.writeAll(inner);
        try writeCommand(allocator, out, inner, child);
        if (i + 1 < names.items.len) try out.writeAll(",");
        try out.writeAll("\n");
    }
    try out.print("{s}]", .{indent});
}

fn writeArgs(out: *std.Io.Writer, indent: []const u8, args: []const types.Arg) DescribeError!void {
    if (args.len == 0) {
        try out.writeAll("[]");
        return;
    }

    var child_indent_buf: [64]u8 = undefined;
    const inner = try std.fmt.bufPrint(&child_indent_buf, "{s}  ", .{indent});
    var field_indent_buf: [64]u8 = undefined;
    const field = try std.fmt.bufPrint(&field_indent_buf, "{s}  ", .{inner});

    try out.writeAll("[\n");
    for (args, 0..) |arg, i| {
        try out.print("{s}{{\n", .{inner});
        try writeStringField(out, field, "name", arg.name, true);
        try writeStringField(out, field, "description", arg.description, true);
        try out.print("{s}\"required\": {s}\n", .{ field, boolText(arg.required) });
        try out.print("{s}}}", .{inner});
        if (i + 1 < args.len) try out.writeAll(",");
        try out.writeAll("\n");
    }
    try out.print("{s}]", .{indent});
}

fn writeFlags(out: *std.Io.Writer, indent: []const u8, flags: []const types.Flag) DescribeError!void {
    if (flags.len == 0) {
        try out.writeAll("[]");
        return;
    }

    var child_indent_buf: [64]u8 = undefined;
    const inner = try std.fmt.bufPrint(&child_indent_buf, "{s}  ", .{indent});
    var field_indent_buf: [64]u8 = undefined;
    const field = try std.fmt.bufPrint(&field_indent_buf, "{s}  ", .{inner});

    try out.writeAll("[\n");
    for (flags, 0..) |flag, i| {
        try out.print("{s}{{\n", .{inner});
        try writeStringField(out, field, "name", flag.name, true);
        if (flag.short) |s| {
            try out.print("{s}\"short\": \"", .{field});
            try writeEscaped(out, &[_]u8{s});
            try out.writeAll("\",\n");
        }
        try writeStringField(out, field, "description", flag.description, true);
        try writeStringField(out, field, "type", @tagName(flag.flag_type), true);
        if (flag.value_name) |v| {
            try writeStringField(out, field, "value_name", v, true);
        }
        if (flag.default_value) |d| {
            try writeStringField(out, field, "default", d, true);
        }
        try out.print("{s}\"value_optional\": {s},\n", .{ field, boolText(flag.value_optional) });
        try out.print("{s}\"required\": {s}\n", .{ field, boolText(flag.required) });
        try out.print("{s}}}", .{inner});
        if (i + 1 < flags.len) try out.writeAll(",");
        try out.writeAll("\n");
    }
    try out.print("{s}]", .{indent});
}

fn boolText(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn writeStringField(
    out: *std.Io.Writer,
    indent: []const u8,
    key: []const u8,
    value: []const u8,
    trailing_comma: bool,
) DescribeError!void {
    try out.print("{s}\"{s}\": \"", .{ indent, key });
    try writeEscaped(out, value);
    try out.writeAll(if (trailing_comma) "\",\n" else "\"\n");
}

/// Escape per RFC 8259. Descriptions are developer-authored rather than
/// untrusted, but emitting invalid JSON because a description gained a quote is
/// a silly way to break every consumer at once.
fn writeEscaped(out: *std.Io.Writer, s: []const u8) DescribeError!void {
    for (s) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x08 => try out.writeAll("\\b"),
            0x0c => try out.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try out.print("\\u{x:0>4}", .{c});
                } else {
                    try out.writeByte(c);
                }
            },
        }
    }
}

// Tests

const testing = std.testing;

fn renderToBuffer(
    allocator: std.mem.Allocator,
    global_flags: []const types.Flag,
    root: ?*const command.Command,
) ![]u8 {
    var out_buf: std.Io.Writer.Allocating = .init(allocator);
    defer out_buf.deinit();
    try writeDocument(allocator, &out_buf.writer, "mere", global_flags, root);
    return try allocator.dupe(u8, out_buf.written());
}

fn noopHandler(_: *mere.Context, _: *const types.ParsedArgs) mere.errors.MereError!types.CommandResult {
    return types.CommandResult{ .success = true };
}

test "describe emits parseable JSON carrying the declared surface" {
    const allocator = testing.allocator;

    var root = command.Command.init(allocator, .{
        .name = "mere",
        .description = "Mere package management tool",
    }, noopHandler);
    defer root.deinit();

    var child = command.Command.init(allocator, .{
        .name = "install",
        .description = "Install packages",
        .group = "Package Management",
        .args = &[_]types.Arg{.{ .name = "package", .description = "Package to install" }},
        .flags = &[_]types.Flag{.{
            .name = "reinstall",
            .short = 'r',
            .description = "Reinstall even if present",
            .flag_type = .bool,
        }},
    }, noopHandler);
    defer child.deinit();
    try root.addSubcommand(&child);

    const globals = [_]types.Flag{.{
        .name = "root",
        .short = 'r',
        .description = "Install prefix",
        .flag_type = .string,
        .value_name = "PATH",
    }};

    const out = try renderToBuffer(allocator, globals[0..], &root);
    defer allocator.free(out);

    // Must actually be JSON, not merely look like it.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, SCHEMA_VERSION), obj.get("schema_version").?.integer);
    try testing.expectEqualStrings("mere", obj.get("program").?.string);
    try testing.expectEqualStrings(command.build_zon.version, obj.get("version").?.string);

    const gf = obj.get("global_flags").?.array;
    try testing.expectEqual(@as(usize, 1), gf.items.len);
    try testing.expectEqualStrings("root", gf.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("string", gf.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("PATH", gf.items[0].object.get("value_name").?.string);

    const cmds = obj.get("commands").?.array;
    try testing.expectEqual(@as(usize, 1), cmds.items.len);
    const install = cmds.items[0].object;
    try testing.expectEqualStrings("install", install.get("name").?.string);
    try testing.expectEqualStrings("Package Management", install.get("group").?.string);
    try testing.expectEqualStrings("package", install.get("args").?.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("bool", install.get("flags").?.array.items[0].object.get("type").?.string);
}

// Subcommands live in a StringHashMap, whose iteration order is not defined. A
// consumer diffing describe output across runs must not see phantom changes.
test "describe output is byte-identical across runs" {
    const allocator = testing.allocator;

    var root = command.Command.init(allocator, .{ .name = "mere", .description = "root" }, noopHandler);
    defer root.deinit();

    var subs: [6]command.Command = undefined;
    const names = [_][]const u8{ "verify", "install", "gc", "shell", "build", "search" };
    for (names, 0..) |n, i| {
        subs[i] = command.Command.init(allocator, .{ .name = n, .description = "d" }, noopHandler);
        try root.addSubcommand(&subs[i]);
    }
    defer for (&subs) |*s| s.deinit();

    const first = try renderToBuffer(allocator, &.{}, &root);
    defer allocator.free(first);
    const second = try renderToBuffer(allocator, &.{}, &root);
    defer allocator.free(second);
    try testing.expectEqualStrings(first, second);

    // ...and sorted, so the order is predictable rather than merely stable.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, first, .{});
    defer parsed.deinit();
    const cmds = parsed.value.object.get("commands").?.array;
    var prev: []const u8 = "";
    for (cmds.items) |c| {
        const name = c.object.get("name").?.string;
        try testing.expect(std.mem.lessThan(u8, prev, name));
        prev = name;
    }
}

test "describe omits hidden commands" {
    const allocator = testing.allocator;

    var root = command.Command.init(allocator, .{ .name = "mere", .description = "root" }, noopHandler);
    defer root.deinit();
    var shown = command.Command.init(allocator, .{ .name = "shown", .description = "d" }, noopHandler);
    defer shown.deinit();
    var secret = command.Command.init(allocator, .{ .name = "secret", .description = "d", .hidden = true }, noopHandler);
    defer secret.deinit();
    try root.addSubcommand(&shown);
    try root.addSubcommand(&secret);

    const out = try renderToBuffer(allocator, &.{}, &root);
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"shown\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"secret\"") == null);
}

test "describe nests subcommands and still parses" {
    const allocator = testing.allocator;

    var root = command.Command.init(allocator, .{ .name = "mere", .description = "root" }, noopHandler);
    defer root.deinit();
    var dev = command.Command.init(allocator, .{ .name = "dev", .description = "Developer tooling" }, noopHandler);
    defer dev.deinit();
    var import_cmd = command.Command.init(allocator, .{ .name = "import", .description = "Import packages" }, noopHandler);
    defer import_cmd.deinit();
    try dev.addSubcommand(&import_cmd);
    try root.addSubcommand(&dev);

    const out = try renderToBuffer(allocator, &.{}, &root);
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const dev_obj = parsed.value.object.get("commands").?.array.items[0].object;
    try testing.expectEqualStrings("dev", dev_obj.get("name").?.string);
    const nested = dev_obj.get("commands").?.array;
    try testing.expectEqualStrings("import", nested.items[0].object.get("name").?.string);
}

// A description containing a quote or newline must not produce a document that
// every consumer then fails to parse.
test "describe escapes characters that would break the document" {
    const allocator = testing.allocator;

    var root = command.Command.init(allocator, .{ .name = "mere", .description = "root" }, noopHandler);
    defer root.deinit();
    var odd = command.Command.init(allocator, .{
        .name = "odd",
        .description = "has \"quotes\", a \\ backslash, and a\nnewline",
    }, noopHandler);
    defer odd.deinit();
    try root.addSubcommand(&odd);

    const out = try renderToBuffer(allocator, &.{}, &root);
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const desc = parsed.value.object.get("commands").?.array.items[0].object.get("description").?.string;
    try testing.expectEqualStrings("has \"quotes\", a \\ backslash, and a\nnewline", desc);
}

test "describe handles a root with no subcommands" {
    const allocator = testing.allocator;
    var root = command.Command.init(allocator, .{ .name = "mere", .description = "root" }, noopHandler);
    defer root.deinit();

    const out = try renderToBuffer(allocator, &.{}, &root);
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("commands").?.array.items.len);
}
