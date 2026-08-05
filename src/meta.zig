const std = @import("std");
const kdl = @import("kdl.zig");
const manifest = @import("manifest.zig");
const errors = @import("errors.zig");
const path = @import("path.zig");

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

pub const ServiceType = enum {
    daemon,
    oneshot,

    pub fn label(self: ServiceType) []const u8 {
        return switch (self) {
            .daemon => "daemon",
            .oneshot => "oneshot",
        };
    }

    pub fn fromString(value: []const u8) ?ServiceType {
        if (std.mem.eql(u8, value, "daemon")) return .daemon;
        if (std.mem.eql(u8, value, "oneshot")) return .oneshot;
        return null;
    }
};

pub const Service = struct {
    name: []const u8,
    service_type: ServiceType,
    command: std.ArrayList([]const u8),
    up: std.ArrayList([]const u8),
    down: std.ArrayList([]const u8),
    depends_on: std.ArrayList([]const u8),
    ready_notification: ?i64 = null,
    essential: bool = false,
    log: bool = true,

    pub fn init(allocator: std.mem.Allocator) Service {
        _ = allocator;
        return .{
            .name = "",
            .service_type = .daemon,
            .command = .empty,
            .up = .empty,
            .down = .empty,
            .depends_on = .empty,
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        for (self.command.items) |value| allocator.free(value);
        self.command.deinit(allocator);
        for (self.up.items) |value| allocator.free(value);
        self.up.deinit(allocator);
        for (self.down.items) |value| allocator.free(value);
        self.down.deinit(allocator);
        for (self.depends_on.items) |value| allocator.free(value);
        self.depends_on.deinit(allocator);
    }
};

pub const Data = struct {
    dependencies: std.ArrayList(Dependency),
    provisions: std.ArrayList(Provision),
    allocator: std.mem.Allocator,

    // Recipe metadata (optional, carried through for display/tracking)
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    licenses: std.ArrayList([]const u8) = .empty,
    source_urls: std.ArrayList([]const u8) = .empty,
    services: std.ArrayList(Service) = .empty,

    pub fn init(allocator: std.mem.Allocator) Data {
        return Data{
            .dependencies = .empty,
            .provisions = .empty,
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

        if (self.description) |d| self.allocator.free(d);
        if (self.url) |u| self.allocator.free(u);
        for (self.licenses.items) |l| self.allocator.free(l);
        self.licenses.deinit(self.allocator);
        for (self.source_urls.items) |s| self.allocator.free(s);
        self.source_urls.deinit(self.allocator);
        for (self.services.items) |*service| service.deinit(self.allocator);
        self.services.deinit(self.allocator);
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

    pub fn addService(self: *Data, source: anytype) MetaError!void {
        var service = Service.init(self.allocator);
        errdefer service.deinit(self.allocator);

        service.name = self.allocator.dupe(u8, source.name) catch return MetaError.OutOfMemory;
        service.service_type = switch (source.service_type) {
            .daemon => .daemon,
            .oneshot => .oneshot,
        };
        service.ready_notification = source.ready_notification;
        service.essential = source.essential;
        service.log = source.log;

        for (source.command.items) |value| {
            try service.command.append(self.allocator, try self.allocator.dupe(u8, value));
        }
        for (source.up.items) |value| {
            try service.up.append(self.allocator, try self.allocator.dupe(u8, value));
        }
        for (source.down.items) |value| {
            try service.down.append(self.allocator, try self.allocator.dupe(u8, value));
        }
        for (source.depends_on.items) |value| {
            try service.depends_on.append(self.allocator, try self.allocator.dupe(u8, value));
        }

        try self.services.append(self.allocator, service);
    }

    /// Populate recipe-level metadata (description, homepage, licenses, source URLs).
    /// This data is carried through to repo.db for display and upstream tracking.
    pub fn populateRecipeMetadata(
        self: *Data,
        description: []const u8,
        url: ?[]const u8,
        licenses: []const []const u8,
        source_urls: []const []const u8,
    ) MetaError!void {
        if (description.len > 0) {
            self.description = self.allocator.dupe(u8, description) catch return MetaError.OutOfMemory;
        }
        if (url) |u| {
            self.url = self.allocator.dupe(u8, u) catch return MetaError.OutOfMemory;
        }
        for (licenses) |l| {
            const copy = self.allocator.dupe(u8, l) catch return MetaError.OutOfMemory;
            self.licenses.append(self.allocator, copy) catch return MetaError.OutOfMemory;
        }
        for (source_urls) |s| {
            const copy = self.allocator.dupe(u8, s) catch return MetaError.OutOfMemory;
            self.source_urls.append(self.allocator, copy) catch return MetaError.OutOfMemory;
        }
    }

    pub fn encode(self: *const Data, allocator: std.mem.Allocator) MetaError![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
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

        // Encode recipe metadata if any fields are populated.
        const has_metadata = self.description != null or self.url != null or
            self.licenses.items.len > 0 or self.source_urls.items.len > 0;
        if (has_metadata) {
            if (self.dependencies.items.len > 0 or self.provisions.items.len > 0) {
                buffer.append(allocator, '\n') catch return MetaError.OutOfMemory;
            }

            buffer.appendSlice(allocator, "metadata {\n") catch return MetaError.OutOfMemory;

            if (self.description) |desc| {
                buffer.appendSlice(allocator, "    description \"") catch return MetaError.OutOfMemory;
                try appendEscaped(&buffer, allocator, desc);
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
            }

            if (self.url) |u| {
                buffer.appendSlice(allocator, "    url \"") catch return MetaError.OutOfMemory;
                try appendEscaped(&buffer, allocator, u);
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
            }

            for (self.licenses.items) |l| {
                buffer.appendSlice(allocator, "    license \"") catch return MetaError.OutOfMemory;
                try appendEscaped(&buffer, allocator, l);
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
            }

            for (self.source_urls.items) |s| {
                buffer.appendSlice(allocator, "    source \"") catch return MetaError.OutOfMemory;
                try appendEscaped(&buffer, allocator, s);
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
            }

            buffer.appendSlice(allocator, "}\n") catch return MetaError.OutOfMemory;
        }

        if (self.services.items.len > 0) {
            if (self.dependencies.items.len > 0 or self.provisions.items.len > 0 or self.description != null or
                self.url != null or self.licenses.items.len > 0 or self.source_urls.items.len > 0)
            {
                buffer.append(allocator, '\n') catch return MetaError.OutOfMemory;
            }

            buffer.appendSlice(allocator, "services {\n") catch return MetaError.OutOfMemory;
            for (self.services.items) |service| {
                buffer.appendSlice(allocator, "    service \"") catch return MetaError.OutOfMemory;
                try appendEscaped(&buffer, allocator, service.name);
                buffer.appendSlice(allocator, "\" {\n        type \"") catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, service.service_type.label()) catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, "\"\n") catch return MetaError.OutOfMemory;
                try appendMetaArgs(&buffer, allocator, "command", service.command.items, 8);
                try appendMetaArgs(&buffer, allocator, "up", service.up.items, 8);
                try appendMetaArgs(&buffer, allocator, "down", service.down.items, 8);
                try appendMetaArgs(&buffer, allocator, "depends-on", service.depends_on.items, 8);
                if (service.ready_notification) |fd| {
                    var fd_buf: [64]u8 = undefined;
                    const fd_line = std.fmt.bufPrint(&fd_buf, "        ready-notification {d}\n", .{fd}) catch
                        return MetaError.OutOfMemory;
                    buffer.appendSlice(allocator, fd_line) catch return MetaError.OutOfMemory;
                }
                if (service.essential) buffer.appendSlice(allocator, "        essential true\n") catch return MetaError.OutOfMemory;
                if (!service.log) buffer.appendSlice(allocator, "        log false\n") catch return MetaError.OutOfMemory;
                buffer.appendSlice(allocator, "    }\n") catch return MetaError.OutOfMemory;
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
            } else if (std.mem.eql(u8, node.name, "services")) {
                for (node.children.items) |*child| {
                    if (!std.mem.eql(u8, child.name, "service")) continue;
                    var service = Service.init(allocator);
                    errdefer service.deinit(allocator);
                    service.name = allocator.dupe(u8, child.getFirstArgString() orelse return MetaError.InvalidInput) catch return MetaError.OutOfMemory;
                    const type_name = child.getChildString("type") orelse return MetaError.InvalidInput;
                    service.service_type = ServiceType.fromString(type_name) orelse return MetaError.InvalidInput;
                    service.ready_notification = child.getChildInt("ready-notification");
                    service.essential = child.getChildBool("essential") orelse false;
                    service.log = child.getChildBool("log") orelse true;
                    try parseServiceArgs(allocator, child, "command", &service.command);
                    try parseServiceArgs(allocator, child, "up", &service.up);
                    try parseServiceArgs(allocator, child, "down", &service.down);
                    try parseServiceArgs(allocator, child, "depends-on", &service.depends_on);
                    try meta.services.append(allocator, service);
                }
            } else if (std.mem.eql(u8, node.name, "metadata")) {
                for (node.children.items) |*child| {
                    if (std.mem.eql(u8, child.name, "description")) {
                        if (child.getFirstArgString()) |value| {
                            meta.description = allocator.dupe(u8, value) catch return MetaError.OutOfMemory;
                        }
                    } else if (std.mem.eql(u8, child.name, "url")) {
                        if (child.getFirstArgString()) |value| {
                            meta.url = allocator.dupe(u8, value) catch return MetaError.OutOfMemory;
                        }
                    } else if (std.mem.eql(u8, child.name, "license")) {
                        if (child.getFirstArgString()) |value| {
                            const copy = allocator.dupe(u8, value) catch return MetaError.OutOfMemory;
                            meta.licenses.append(allocator, copy) catch return MetaError.OutOfMemory;
                        }
                    } else if (std.mem.eql(u8, child.name, "source")) {
                        if (child.getFirstArgString()) |value| {
                            const copy = allocator.dupe(u8, value) catch return MetaError.OutOfMemory;
                            meta.source_urls.append(allocator, copy) catch return MetaError.OutOfMemory;
                        }
                    }
                }
            }
        }

        return meta;
    }
};

fn appendMetaArgs(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    values: []const []const u8,
    indent: usize,
) MetaError!void {
    if (values.len == 0) return;
    try appendIndent(buffer, allocator, indent);
    buffer.appendSlice(allocator, name) catch return MetaError.OutOfMemory;
    for (values) |value| {
        buffer.append(allocator, ' ') catch return MetaError.OutOfMemory;
        buffer.append(allocator, '"') catch return MetaError.OutOfMemory;
        try appendEscaped(buffer, allocator, value);
        buffer.append(allocator, '"') catch return MetaError.OutOfMemory;
    }
    buffer.append(allocator, '\n') catch return MetaError.OutOfMemory;
}

fn appendIndent(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, count: usize) MetaError!void {
    var i: usize = 0;
    while (i < count) : (i += 1) buffer.append(allocator, ' ') catch return MetaError.OutOfMemory;
}

fn parseServiceArgs(
    allocator: std.mem.Allocator,
    node: *const kdl.Node,
    name: []const u8,
    values: *std.ArrayList([]const u8),
) MetaError!void {
    if (node.findChild(name)) |child| {
        for (child.arguments.items) |arg| {
            const value = arg.getString() orelse return MetaError.InvalidInput;
            try values.append(allocator, try allocator.dupe(u8, value));
        }
    }
}

/// Append a string to a buffer, escaping KDL special characters.
fn appendEscaped(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) MetaError!void {
    for (value) |c| {
        if (c == '"') {
            buffer.appendSlice(allocator, "\\\"") catch return MetaError.OutOfMemory;
        } else if (c == '\\') {
            buffer.appendSlice(allocator, "\\\\") catch return MetaError.OutOfMemory;
        } else {
            buffer.append(allocator, c) catch return MetaError.OutOfMemory;
        }
    }
}

pub fn readFile(allocator: std.mem.Allocator, dir_path: []const u8) MetaError!Data {
    const meta_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_KDL_FILENAME }) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(meta_path);

    const io = path.currentIo();
    const file = path.openExistingFile(meta_path) catch |err| {
        return switch (err) {
            error.FileNotFound => {
                return Data.init(allocator);
            },
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
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

    const bytes_read = file.readPositionalAll(io, buffer, 0) catch |err| {
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
    const io = path.currentIo();
    const content = try pkg_meta.encode(allocator);
    defer allocator.free(content);

    if (content.len == 0) {
        return;
    }

    const meta_dir_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_DIR }) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(meta_dir_path);
    path.ensureDirExists(meta_dir_path) catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };

    const meta_path = std.fs.path.join(allocator, &.{ dir_path, manifest.META_KDL_FILENAME }) catch {
        return MetaError.OutOfMemory;
    };
    defer allocator.free(meta_path);

    const file = std.Io.Dir.createFileAbsolute(io, meta_path, .{}) catch |err| {
        return switch (err) {
            error.AccessDenied => MetaError.PermissionDenied,
            else => MetaError.FileSystem,
        };
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
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

test "Data service metadata roundtrip" {
    const allocator = std.testing.allocator;

    var meta = Data.init(allocator);
    defer meta.deinit();

    var service = Service.init(allocator);
    service.name = try allocator.dupe(u8, "ntpd");
    service.service_type = .daemon;
    service.ready_notification = 3;
    service.essential = true;
    service.log = false;
    try service.command.append(allocator, try allocator.dupe(u8, "/usr/bin/ntpd"));
    try service.command.append(allocator, try allocator.dupe(u8, "-n"));
    try service.depends_on.append(allocator, try allocator.dupe(u8, "network"));
    try meta.services.append(allocator, service);

    const encoded = try meta.encode(allocator);
    defer allocator.free(encoded);

    var parsed = try Data.parse(allocator, encoded);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.services.items.len);
    const parsed_service = parsed.services.items[0];
    try std.testing.expectEqualStrings("ntpd", parsed_service.name);
    try std.testing.expectEqual(ServiceType.daemon, parsed_service.service_type);
    try std.testing.expectEqual(@as(?i64, 3), parsed_service.ready_notification);
    try std.testing.expect(parsed_service.essential);
    try std.testing.expect(!parsed_service.log);
    try std.testing.expectEqual(@as(usize, 2), parsed_service.command.items.len);
    try std.testing.expectEqualStrings("/usr/bin/ntpd", parsed_service.command.items[0]);
    try std.testing.expectEqualStrings("-n", parsed_service.command.items[1]);
    try std.testing.expectEqualStrings("network", parsed_service.depends_on.items[0]);
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
