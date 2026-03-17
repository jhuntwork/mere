const std = @import("std");
const kdl = @import("kdl.zig");
const manifest = @import("manifest.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const MetaError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{ParseError};

pub const DependencyType = enum {
    elf_needed,
    elf_interpreter,
    script_interpreter,
    split_runtime,

    pub fn toNodeName(self: DependencyType) []const u8 {
        return switch (self) {
            .elf_needed => "elf-needed",
            .elf_interpreter => "elf-interpreter",
            .script_interpreter => "script-interpreter",
            .split_runtime => "split-runtime",
        };
    }

    pub fn fromNodeName(name: []const u8) ?DependencyType {
        if (std.mem.eql(u8, name, "elf-needed")) return .elf_needed;
        if (std.mem.eql(u8, name, "elf-interpreter")) return .elf_interpreter;
        if (std.mem.eql(u8, name, "script-interpreter")) return .script_interpreter;
        if (std.mem.eql(u8, name, "split-runtime")) return .split_runtime;
        return null;
    }
};

pub const ProvisionType = enum {
    elf_soname,
    bin,

    pub fn toNodeName(self: ProvisionType) []const u8 {
        return switch (self) {
            .elf_soname => "elf-soname",
            .bin => "bin",
        };
    }

    pub fn fromNodeName(name: []const u8) ?ProvisionType {
        if (std.mem.eql(u8, name, "elf-soname")) return .elf_soname;
        if (std.mem.eql(u8, name, "bin")) return .bin;
        return null;
    }
};

pub const Dependency = struct {
    dep_type: DependencyType,
    value: []const u8,
    version_constraint: ?[]const u8 = null,

    pub fn deinit(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        if (self.version_constraint) |expr| allocator.free(expr);
    }
};

pub const Provision = struct {
    prov_type: ProvisionType,
    value: []const u8,

    pub fn deinit(self: *Provision, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const Data = struct {
    dependencies: std.ArrayList(Dependency),
    provisions: std.ArrayList(Provision),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Data {
        return Data{
            .dependencies = std.ArrayList(Dependency){},
            .provisions = std.ArrayList(Provision){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Data) void {
        for (self.dependencies.items) |*dep| {
            dep.deinit(self.allocator);
        }
        self.dependencies.deinit(self.allocator);

        for (self.provisions.items) |*prov| {
            prov.deinit(self.allocator);
        }
        self.provisions.deinit(self.allocator);
    }

    pub fn addDependency(self: *Data, dep_type: DependencyType, value: []const u8) MetaError!void {
        return self.addDependencyWithConstraint(dep_type, value, null);
    }

    pub fn addDependencyWithConstraint(
        self: *Data,
        dep_type: DependencyType,
        value: []const u8,
        version_constraint: ?[]const u8,
    ) MetaError!void {
        const value_copy = self.allocator.dupe(u8, value) catch return MetaError.OutOfMemory;
        errdefer self.allocator.free(value_copy);
        const version_copy = if (version_constraint) |expr|
            self.allocator.dupe(u8, expr) catch return MetaError.OutOfMemory
        else
            null;
        errdefer if (version_copy) |expr| self.allocator.free(expr);

        self.dependencies.append(self.allocator, Dependency{
            .dep_type = dep_type,
            .value = value_copy,
            .version_constraint = version_copy,
        }) catch return MetaError.OutOfMemory;
    }

    pub fn addProvision(self: *Data, prov_type: ProvisionType, value: []const u8) MetaError!void {
        const value_copy = self.allocator.dupe(u8, value) catch return MetaError.OutOfMemory;
        errdefer self.allocator.free(value_copy);

        self.provisions.append(self.allocator, Provision{
            .prov_type = prov_type,
            .value = value_copy,
        }) catch return MetaError.OutOfMemory;
    }

    pub fn populateFromPackage(self: *Data, pkg: anytype) MetaError!void {
        for (pkg.dependencies.items) |dep| {
            const dep_type: DependencyType = switch (dep.dep_type) {
                .elf_needed => .elf_needed,
                .elf_interpreter => .elf_interpreter,
                .script_interpreter => .script_interpreter,
                .split_runtime => .split_runtime,
            };
            try self.addDependencyWithConstraint(dep_type, dep.resource, dep.version_constraint);
        }

        for (pkg.provisions.items) |prov| {
            const prov_type: ProvisionType = switch (prov.prov_type) {
                .elf_soname => .elf_soname,
                .bin => .bin,
            };
            try self.addProvision(prov_type, prov.resource);
        }
    }

    pub fn encode(self: *const Data, allocator: std.mem.Allocator) MetaError![]u8 {
        var buffer = std.ArrayList(u8){};
        errdefer buffer.deinit(allocator);

        if (self.dependencies.items.len > 0) {
            buffer.appendSlice(allocator, "dependencies {\n") catch return MetaError.OutOfMemory;

            for (self.dependencies.items) |dep| {
                buffer.appendSlice(allocator, "    ") catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, dep.dep_type.toNodeName()) catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, " \"") catch return MetaError.OutOfMemory;
                for (dep.value) |c| {
                    if (c == '"') {
                        buffer.appendSlice(allocator, "\\\"") catch return MetaError.OutOfMemory;
                    } else if (c == '\\') {
                        buffer.appendSlice(allocator, "\\\\") catch return MetaError.OutOfMemory;
                    } else {
                        buffer.append(allocator, c) catch return MetaError.OutOfMemory;
                    }
                }
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
                if (dep.version_constraint) |expr| {
                    _ = buffer.pop();
                    buffer.appendSlice(allocator, " version=\"") catch return MetaError.OutOfMemory;
                    for (expr) |c| {
                        if (c == '"') {
                            buffer.appendSlice(allocator, "\\\"") catch return MetaError.OutOfMemory;
                        } else if (c == '\\') {
                            buffer.appendSlice(allocator, "\\\\") catch return MetaError.OutOfMemory;
                        } else {
                            buffer.append(allocator, c) catch return MetaError.OutOfMemory;
                        }
                    }
                    buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
                }
            }

            buffer.appendSlice(allocator, "}\n") catch return MetaError.OutOfMemory;
        }

        if (self.provisions.items.len > 0) {
            if (self.dependencies.items.len > 0) {
                buffer.append(allocator, '\n') catch return MetaError.OutOfMemory;
            }

            buffer.appendSlice(allocator, "provisions {\n") catch return MetaError.OutOfMemory;

            for (self.provisions.items) |prov| {
                buffer.appendSlice(allocator, "    ") catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, prov.prov_type.toNodeName()) catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, " \"") catch return MetaError.OutOfMemory;
                for (prov.value) |c| {
                    if (c == '"') {
                        buffer.appendSlice(allocator, "\\\"") catch return MetaError.OutOfMemory;
                    } else if (c == '\\') {
                        buffer.appendSlice(allocator, "\\\\") catch return MetaError.OutOfMemory;
                    } else {
                        buffer.append(allocator, c) catch return MetaError.OutOfMemory;
                    }
                }
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
            }

            buffer.appendSlice(allocator, "}\n") catch return MetaError.OutOfMemory;
        }

        return buffer.toOwnedSlice(allocator) catch return MetaError.OutOfMemory;
    }

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) MetaError!Data {
        var meta = Data.init(allocator);
        errdefer meta.deinit();

        if (input.len == 0) {
            return meta;
        }

        var nodes = kdl.parseDocument(allocator, input) catch |err| {
            return switch (err) {
                kdl.KdlError.OutOfMemory => MetaError.OutOfMemory,
                kdl.KdlError.ParseError => MetaError.ParseError,
                else => MetaError.InvalidInput,
            };
        };
        defer {
            for (nodes.items) |*n| n.deinit();
            nodes.deinit(allocator);
        }

        for (nodes.items) |*node| {
            if (std.mem.eql(u8, node.name, "dependencies")) {
                for (node.children.items) |*child| {
                    if (DependencyType.fromNodeName(child.name)) |dep_type| {
                        if (child.getFirstArgString()) |value| {
                            const version_constraint = child.getStringProperty("version");
                            try meta.addDependencyWithConstraint(dep_type, value, version_constraint);
                        }
                    }
                }
            } else if (std.mem.eql(u8, node.name, "provisions")) {
                for (node.children.items) |*child| {
                    if (ProvisionType.fromNodeName(child.name)) |prov_type| {
                        if (child.getFirstArgString()) |value| {
                            try meta.addProvision(prov_type, value);
                        }
                    }
                }
            }
        }

        return meta;
    }
};

pub fn readFile(allocator: std.mem.Allocator, dir_path: []const u8) MetaError!Data {
    const meta_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_KDL_FILENAME }) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(meta_path);

    const file = std.fs.openFileAbsolute(meta_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => {
                return Data.init(allocator);
            },
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };

    if (stat.size > 1024 * 1024) {
        return MetaError.InvalidInput;
    }

    const buffer = allocator.alloc(u8, @intCast(stat.size)) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(buffer);

    const bytes_read = file.readAll(buffer) catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };

    if (bytes_read != stat.size) {
        return MetaError.FileSystem;
    }

    return Data.parse(allocator, buffer);
}

pub fn writeFile(allocator: std.mem.Allocator, dir_path: []const u8, pkg_meta: *const Data) MetaError!void {
    const content = try pkg_meta.encode(allocator);
    defer allocator.free(content);

    if (content.len == 0) {
        return;
    }

    const meta_dir_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_DIR }) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(meta_dir_path);
    std.fs.cwd().makePath(meta_dir_path) catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };

    const meta_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_KDL_FILENAME }) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(meta_path);

    const file = std.fs.createFileAbsolute(meta_path, .{}) catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };
}

// Tests

test "Data encode empty" {
    const allocator = std.testing.allocator;

    var meta = Data.init(allocator);
    defer meta.deinit();

    const encoded = try meta.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("", encoded);
}

test "Data encode with dependencies" {
    const allocator = std.testing.allocator;

    var meta = Data.init(allocator);
    defer meta.deinit();

    try meta.addDependency(.elf_needed, "libc.so");
    try meta.addDependency(.elf_needed, "libz.so.1");
    try meta.addDependency(.elf_interpreter, "/lib/ld-musl-x86_64.so.1");

    const encoded = try meta.encode(allocator);
    defer allocator.free(encoded);

    const expected =
        \\dependencies {
        \\    elf-needed "libc.so"
        \\    elf-needed "libz.so.1"
        \\    elf-interpreter "/lib/ld-musl-x86_64.so.1"
        \\}
        \\
    ;

    try std.testing.expectEqualStrings(expected, encoded);
}

test "Data encode with provisions" {
    const allocator = std.testing.allocator;

    var meta = Data.init(allocator);
    defer meta.deinit();

    try meta.addProvision(.elf_soname, "libfoo.so.1");
    try meta.addProvision(.bin, "myprogram");

    const encoded = try meta.encode(allocator);
    defer allocator.free(encoded);

    const expected =
        \\provisions {
        \\    elf-soname "libfoo.so.1"
        \\    bin "myprogram"
        \\}
        \\
    ;

    try std.testing.expectEqualStrings(expected, encoded);
}

test "Data encode with both" {
    const allocator = std.testing.allocator;

    var meta = Data.init(allocator);
    defer meta.deinit();

    try meta.addDependency(.elf_needed, "libc.so");
    try meta.addProvision(.bin, "test");

    const encoded = try meta.encode(allocator);
    defer allocator.free(encoded);

    const expected =
        \\dependencies {
        \\    elf-needed "libc.so"
        \\}
        \\
        \\provisions {
        \\    bin "test"
        \\}
        \\
    ;

    try std.testing.expectEqualStrings(expected, encoded);
}

test "Data parse roundtrip" {
    const allocator = std.testing.allocator;

    const input =
        \\dependencies {
        \\    elf-needed "libc.so"
        \\    elf-interpreter "/lib/ld-musl-x86_64.so.1"
        \\}
        \\
        \\provisions {
        \\    elf-soname "libfoo.so.1"
        \\    bin "myprogram"
        \\}
        \\
    ;

    var meta = try Data.parse(allocator, input);
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 2), meta.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 2), meta.provisions.items.len);

    try std.testing.expectEqual(DependencyType.elf_needed, meta.dependencies.items[0].dep_type);
    try std.testing.expectEqualStrings("libc.so", meta.dependencies.items[0].value);

    try std.testing.expectEqual(DependencyType.elf_interpreter, meta.dependencies.items[1].dep_type);
    try std.testing.expectEqualStrings("/lib/ld-musl-x86_64.so.1", meta.dependencies.items[1].value);

    try std.testing.expectEqual(ProvisionType.elf_soname, meta.provisions.items[0].prov_type);
    try std.testing.expectEqualStrings("libfoo.so.1", meta.provisions.items[0].value);

    try std.testing.expectEqual(ProvisionType.bin, meta.provisions.items[1].prov_type);
    try std.testing.expectEqualStrings("myprogram", meta.provisions.items[1].value);
}

test "Data parse empty input" {
    const allocator = std.testing.allocator;

    var meta = try Data.parse(allocator, "");
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 0), meta.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 0), meta.provisions.items.len);
}

test "Data encode escapes quotes" {
    const allocator = std.testing.allocator;

    var meta = Data.init(allocator);
    defer meta.deinit();

    try meta.addDependency(.elf_needed, "lib\"test\".so");

    const encoded = try meta.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "lib\\\"test\\\".so") != null);
}

test "Data dependency version constraint roundtrip" {
    const allocator = std.testing.allocator;

    var meta_obj = Data.init(allocator);
    defer meta_obj.deinit();

    try meta_obj.addDependencyWithConstraint(.elf_needed, "libfoo", ">=1.2,<2.0");
    try meta_obj.addDependency(.elf_interpreter, "/lib/ld-musl-x86_64.so.1");

    const encoded = try meta_obj.encode(allocator);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "version=\">=1.2,<2.0\"") != null);

    var parsed = try Data.parse(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.dependencies.items.len);
    try std.testing.expectEqualStrings("libfoo", parsed.dependencies.items[0].value);
    try std.testing.expect(parsed.dependencies.items[0].version_constraint != null);
    try std.testing.expectEqualStrings(">=1.2,<2.0", parsed.dependencies.items[0].version_constraint.?);
    try std.testing.expect(parsed.dependencies.items[1].version_constraint == null);
}

test "Data encode and parse split-runtime dependency" {
    const allocator = std.testing.allocator;

    var meta_obj = Data.init(allocator);
    defer meta_obj.deinit();

    try meta_obj.addDependencyWithConstraint(.split_runtime, "libssl-3", "=3.6.1-4");

    const encoded = try meta_obj.encode(allocator);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "split-runtime \"libssl-3\" version=\"=3.6.1-4\"") != null);

    var parsed = try Data.parse(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.dependencies.items.len);
    try std.testing.expectEqual(DependencyType.split_runtime, parsed.dependencies.items[0].dep_type);
    try std.testing.expectEqualStrings("libssl-3", parsed.dependencies.items[0].value);
    try std.testing.expect(parsed.dependencies.items[0].version_constraint != null);
    try std.testing.expectEqualStrings("=3.6.1-4", parsed.dependencies.items[0].version_constraint.?);
}
