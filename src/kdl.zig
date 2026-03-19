const std = @import("std");
const errors = @import("errors.zig");

const kdl_str = extern struct {
    data: ?[*]const u8,
    len: usize,

    pub fn toSlice(self: kdl_str) ?[]const u8 {
        if (self.data) |ptr| {
            return ptr[0..self.len];
        }
        return null;
    }
};

const kdl_owned_string = extern struct {
    data: ?[*]u8,
    len: usize,
};

const kdl_type = enum(c_int) {
    KDL_TYPE_NULL = 0,
    KDL_TYPE_BOOLEAN = 1,
    KDL_TYPE_NUMBER = 2,
    KDL_TYPE_STRING = 3,
};

const kdl_number_type = enum(c_int) {
    KDL_NUMBER_TYPE_INTEGER = 0,
    KDL_NUMBER_TYPE_FLOATING_POINT = 1,
    KDL_NUMBER_TYPE_STRING_ENCODED = 2,
};

const kdl_number = extern struct {
    type: kdl_number_type,
    value: extern union {
        integer: c_longlong,
        floating_point: f64,
        string: kdl_str,
    },
};

const kdl_value = extern struct {
    type: kdl_type,
    type_annotation: kdl_str,
    value: extern union {
        boolean: bool,
        number: kdl_number,
        string: kdl_str,
    },

    /// Get string value if this is a string type
    pub fn getString(self: *const kdl_value) ?[]const u8 {
        if (self.type == .KDL_TYPE_STRING) {
            return self.value.string.toSlice();
        }
        return null;
    }

    /// Get integer value if this is an integer number
    pub fn getInteger(self: *const kdl_value) ?i64 {
        if (self.type == .KDL_TYPE_NUMBER and self.value.number.type == .KDL_NUMBER_TYPE_INTEGER) {
            return @intCast(self.value.number.value.integer);
        }
        return null;
    }

    /// Get float value if this is a floating point number
    pub fn getFloat(self: *const kdl_value) ?f64 {
        if (self.type == .KDL_TYPE_NUMBER and self.value.number.type == .KDL_NUMBER_TYPE_FLOATING_POINT) {
            return self.value.number.value.floating_point;
        }
        return null;
    }

    /// Get boolean value if this is a boolean type
    pub fn getBoolean(self: *const kdl_value) ?bool {
        if (self.type == .KDL_TYPE_BOOLEAN) {
            return self.value.boolean;
        }
        return null;
    }
};

const kdl_event = enum(c_int) {
    KDL_EVENT_EOF = 0,
    KDL_EVENT_PARSE_ERROR = 1,
    KDL_EVENT_START_NODE = 2,
    KDL_EVENT_END_NODE = 3,
    KDL_EVENT_ARGUMENT = 4,
    KDL_EVENT_PROPERTY = 5,
    KDL_EVENT_COMMENT = 0x10000,
};

const kdl_event_data = extern struct {
    event: kdl_event,
    name: kdl_str,
    value: kdl_value,
};

const kdl_parse_option = c_int;
const KDL_DETECT_VERSION: kdl_parse_option = 0x70000;

const kdl_parser = opaque {};

extern fn kdl_create_string_parser(doc: kdl_str, opt: kdl_parse_option) ?*kdl_parser;
extern fn kdl_destroy_parser(parser: *kdl_parser) void;
extern fn kdl_parser_next_event(parser: *kdl_parser) ?*kdl_event_data;

const Std = errors.StandardErrors;
pub const KdlError = Std.OutOfMemory || Std.InvalidInput || error{
    ParseError,
    UnexpectedEvent,
};

const Parser = struct {
    c_parser: *kdl_parser,
    input_buf: [:0]const u8,
    allocator: std.mem.Allocator,
    depth: usize,
    last_parse_error: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) KdlError!Parser {
        const buf = allocator.allocSentinel(u8, input.len, 0) catch return KdlError.OutOfMemory;
        @memcpy(buf, input);

        const doc = kdl_str{
            .data = buf.ptr,
            .len = input.len,
        };

        const parser = kdl_create_string_parser(doc, KDL_DETECT_VERSION) orelse {
            allocator.free(buf);
            return KdlError.OutOfMemory;
        };

        return Parser{
            .c_parser = parser,
            .input_buf = buf,
            .allocator = allocator,
            .depth = 0,
            .last_parse_error = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        kdl_destroy_parser(self.c_parser);
        self.allocator.free(self.input_buf);
    }

    pub fn nextEvent(self: *Parser) KdlError!?*kdl_event_data {
        const event = kdl_parser_next_event(self.c_parser) orelse return null;

        switch (event.event) {
            .KDL_EVENT_EOF => return null,
            .KDL_EVENT_PARSE_ERROR => {
                self.last_parse_error = event.value.getString() orelse "parse error";
                return KdlError.ParseError;
            },
            .KDL_EVENT_START_NODE => {
                self.depth += 1;
                return event;
            },
            .KDL_EVENT_END_NODE => {
                if (self.depth > 0) self.depth -= 1;
                return event;
            },
            else => return event,
        }
    }
};

/// Parsed KDL node with its arguments and properties collected
pub const Node = struct {
    name: []const u8,
    arguments: std.ArrayList(Value),
    properties: std.StringHashMapUnmanaged(Value),
    children: std.ArrayList(Node),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) KdlError!Node {
        const name_copy = allocator.dupe(u8, name) catch return KdlError.OutOfMemory;
        return Node{
            .name = name_copy,
            .arguments = .empty,
            .properties = std.StringHashMapUnmanaged(Value){},
            .children = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Node) void {
        self.allocator.free(self.name);

        for (self.arguments.items) |*arg| {
            arg.deinit(self.allocator);
        }
        self.arguments.deinit(self.allocator);

        var prop_iter = self.properties.iterator();
        while (prop_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.properties.deinit(self.allocator);

        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
    }

    pub fn getProperty(self: *const Node, name: []const u8) ?*const Value {
        return self.properties.getPtr(name);
    }

    pub fn getStringProperty(self: *const Node, name: []const u8) ?[]const u8 {
        if (self.properties.getPtr(name)) |val| {
            return val.getString();
        }
        return null;
    }

    pub fn getIntProperty(self: *const Node, name: []const u8) ?i64 {
        if (self.properties.getPtr(name)) |val| {
            return val.getInteger();
        }
        return null;
    }

    pub fn getFirstArgString(self: *const Node) ?[]const u8 {
        if (self.arguments.items.len > 0) {
            return self.arguments.items[0].getString();
        }
        return null;
    }

    pub fn getFirstArgInt(self: *const Node) ?i64 {
        if (self.arguments.items.len > 0) {
            return self.arguments.items[0].getInteger();
        }
        return null;
    }

    pub fn getFirstArgBool(self: *const Node) ?bool {
        if (self.arguments.items.len > 0) {
            return self.arguments.items[0].getBoolean();
        }
        return null;
    }

    pub fn findChild(self: *const Node, name: []const u8) ?*const Node {
        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }
        return null;
    }

    pub fn getChildString(self: *const Node, child_name: []const u8) ?[]const u8 {
        if (self.findChild(child_name)) |child| {
            return child.getFirstArgString();
        }
        return null;
    }

    pub fn getChildInt(self: *const Node, child_name: []const u8) ?i64 {
        if (self.findChild(child_name)) |child| {
            return child.getFirstArgInt();
        }
        return null;
    }

    pub fn getChildBool(self: *const Node, child_name: []const u8) ?bool {
        if (self.findChild(child_name)) |child| {
            return child.getFirstArgBool();
        }
        return null;
    }
};

pub const Value = struct {
    type: ValueType,
    data: union {
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
        none: void,
    },

    pub const ValueType = enum {
        string,
        integer,
        float,
        boolean,
        null_value,
    };

    pub fn fromKdlValue(allocator: std.mem.Allocator, kv: *const kdl_value) KdlError!Value {
        switch (kv.type) {
            .KDL_TYPE_NULL => return Value{ .type = .null_value, .data = .{ .none = {} } },
            .KDL_TYPE_BOOLEAN => return Value{ .type = .boolean, .data = .{ .boolean = kv.value.boolean } },
            .KDL_TYPE_STRING => {
                if (kv.value.string.toSlice()) |s| {
                    const copy = allocator.dupe(u8, s) catch return KdlError.OutOfMemory;
                    return Value{ .type = .string, .data = .{ .string = copy } };
                }
                return Value{ .type = .null_value, .data = .{ .none = {} } };
            },
            .KDL_TYPE_NUMBER => {
                switch (kv.value.number.type) {
                    .KDL_NUMBER_TYPE_INTEGER => return Value{
                        .type = .integer,
                        .data = .{ .integer = @intCast(kv.value.number.value.integer) },
                    },
                    .KDL_NUMBER_TYPE_FLOATING_POINT => return Value{
                        .type = .float,
                        .data = .{ .float = kv.value.number.value.floating_point },
                    },
                    .KDL_NUMBER_TYPE_STRING_ENCODED => {
                        // Parse string-encoded number as float
                        if (kv.value.number.value.string.toSlice()) |s| {
                            const f = std.fmt.parseFloat(f64, s) catch return Value{
                                .type = .null_value,
                                .data = .{ .none = {} },
                            };
                            return Value{ .type = .float, .data = .{ .float = f } };
                        }
                        return Value{ .type = .null_value, .data = .{ .none = {} } };
                    },
                }
            },
        }
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        if (self.type == .string) {
            allocator.free(self.data.string);
        }
    }

    pub fn getString(self: *const Value) ?[]const u8 {
        if (self.type == .string) return self.data.string;
        return null;
    }

    pub fn getInteger(self: *const Value) ?i64 {
        if (self.type == .integer) return self.data.integer;
        return null;
    }

    pub fn getFloat(self: *const Value) ?f64 {
        if (self.type == .float) return self.data.float;
        return null;
    }

    pub fn getBoolean(self: *const Value) ?bool {
        if (self.type == .boolean) return self.data.boolean;
        return null;
    }
};

fn parseDocumentInternal(
    allocator: std.mem.Allocator,
    input: []const u8,
    parse_error_message: ?*?[]const u8,
) KdlError!std.ArrayList(Node) {
    var parser = try Parser.init(allocator, input);
    defer parser.deinit();

    var nodes: std.ArrayList(Node) = .empty;
    errdefer {
        for (nodes.items) |*n| n.deinit();
        nodes.deinit(allocator);
    }

    var node_stack: std.ArrayList(*Node) = .empty;
    defer node_stack.deinit(allocator);

    while (parser.nextEvent() catch |err| {
        if (err == KdlError.ParseError and parse_error_message != null) {
            parse_error_message.?.* = parser.last_parse_error;
        }
        return err;
    }) |event| {
        switch (event.event) {
            .KDL_EVENT_START_NODE => {
                const name = event.name.toSlice() orelse "";
                var new_node = try Node.init(allocator, name);
                errdefer new_node.deinit();

                if (node_stack.items.len == 0) {
                    nodes.append(allocator, new_node) catch return KdlError.OutOfMemory;
                    const ptr = &nodes.items[nodes.items.len - 1];
                    node_stack.append(allocator, ptr) catch return KdlError.OutOfMemory;
                } else {
                    const parent = node_stack.items[node_stack.items.len - 1];
                    parent.children.append(allocator, new_node) catch return KdlError.OutOfMemory;
                    const ptr = &parent.children.items[parent.children.items.len - 1];
                    node_stack.append(allocator, ptr) catch return KdlError.OutOfMemory;
                }
            },
            .KDL_EVENT_END_NODE => {
                if (node_stack.items.len > 0) {
                    _ = node_stack.pop();
                }
            },
            .KDL_EVENT_ARGUMENT => {
                if (node_stack.items.len > 0) {
                    const current = node_stack.items[node_stack.items.len - 1];
                    const val = try Value.fromKdlValue(allocator, &event.value);
                    current.arguments.append(allocator, val) catch {
                        var tmp = val;
                        tmp.deinit(allocator);
                        return KdlError.OutOfMemory;
                    };
                }
            },
            .KDL_EVENT_PROPERTY => {
                if (node_stack.items.len > 0) {
                    const current = node_stack.items[node_stack.items.len - 1];
                    const prop_name = event.name.toSlice() orelse continue;
                    const prop_name_copy = allocator.dupe(u8, prop_name) catch return KdlError.OutOfMemory;
                    const val = try Value.fromKdlValue(allocator, &event.value);
                    current.properties.put(allocator, prop_name_copy, val) catch {
                        allocator.free(prop_name_copy);
                        var tmp = val;
                        tmp.deinit(allocator);
                        return KdlError.OutOfMemory;
                    };
                }
            },
            else => {},
        }
    }

    return nodes;
}

pub fn parseDocument(allocator: std.mem.Allocator, input: []const u8) KdlError!std.ArrayList(Node) {
    return parseDocumentInternal(allocator, input, null);
}

pub fn parseDocumentDetailed(
    allocator: std.mem.Allocator,
    input: []const u8,
    parse_error_message: *?[]const u8,
) KdlError!std.ArrayList(Node) {
    parse_error_message.* = null;
    return parseDocumentInternal(allocator, input, parse_error_message);
}

// Tests

test "parse simple KDL document" {
    const input =
        \\node "arg1" key="value"
        \\another-node 42
    ;

    var nodes = try parseDocument(std.testing.allocator, input);
    defer {
        for (nodes.items) |*n| n.deinit();
        nodes.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), nodes.items.len);
    try std.testing.expectEqualStrings("node", nodes.items[0].name);
    try std.testing.expectEqualStrings("another-node", nodes.items[1].name);

    // Check first node
    try std.testing.expectEqual(@as(usize, 1), nodes.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("arg1", nodes.items[0].arguments.items[0].getString().?);
    try std.testing.expectEqualStrings("value", nodes.items[0].getStringProperty("key").?);

    // Check second node
    try std.testing.expectEqual(@as(usize, 1), nodes.items[1].arguments.items.len);
    try std.testing.expectEqual(@as(i64, 42), nodes.items[1].arguments.items[0].getInteger().?);
}

test "parse nested KDL nodes" {
    const input =
        \\parent {
        \\    child "value"
        \\}
    ;

    var nodes = try parseDocument(std.testing.allocator, input);
    defer {
        for (nodes.items) |*n| n.deinit();
        nodes.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqualStrings("parent", nodes.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), nodes.items[0].children.items.len);

    const child = &nodes.items[0].children.items[0];
    try std.testing.expectEqualStrings("child", child.name);
    try std.testing.expectEqualStrings("value", child.getFirstArgString().?);
}

test "parse KDL with multiple properties" {
    const input =
        \\config name="test" priority=100 enabled=true
    ;

    var nodes = try parseDocument(std.testing.allocator, input);
    defer {
        for (nodes.items) |*n| n.deinit();
        nodes.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqualStrings("test", nodes.items[0].getStringProperty("name").?);
    try std.testing.expectEqual(@as(i64, 100), nodes.items[0].getIntProperty("priority").?);

    const enabled = nodes.items[0].getProperty("enabled").?;
    try std.testing.expectEqual(true, enabled.getBoolean().?);
}

test "parse error on invalid KDL" {
    const input = "invalid { { { }";

    const result = parseDocument(std.testing.allocator, input);
    try std.testing.expectError(KdlError.ParseError, result);
}
