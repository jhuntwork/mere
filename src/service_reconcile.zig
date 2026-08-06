/// Materialize provider-native service configuration from package metadata.
///
/// This is deliberately separate from profile projection: a profile is a
/// symlink view of package contents, while the init system consumes a
/// system-wide service tree. The package metadata is the boundary between the
/// two concerns.
const std = @import("std");
const generation = @import("generation.zig");
const meta = @import("meta.zig");
const mere = @import("mere.zig");
const path = @import("path.zig");

pub const ReconcileError = error{
    OutOfMemory,
    FileSystem,
    PermissionDenied,
    InvalidInput,
    DuplicateService,
};

/// A prepared replacement for the package-owned dinit service tree.
/// The replacement is not visible to dinit until `commit` is called.
pub const StagedDinit = struct {
    allocator: std.mem.Allocator,
    service_root: []const u8,
    stage_root: []const u8,
    committed: bool = false,

    pub fn commit(self: *StagedDinit) ReconcileError!void {
        const io = path.currentIo();
        const backup_root = std.fmt.allocPrint(self.allocator, "{s}.mere-old", .{self.service_root}) catch
            return error.OutOfMemory;
        defer self.allocator.free(backup_root);
        path.deleteTreeAbsolute(backup_root) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return mapFsError(err),
        };

        var old_exists = false;
        if (std.Io.Dir.accessAbsolute(io, self.service_root, .{})) |_| {
            old_exists = true;
        } else |_| {}
        if (old_exists) {
            std.Io.Dir.renameAbsolute(self.service_root, backup_root, io) catch |err| return mapFsError(err);
        }
        std.Io.Dir.renameAbsolute(self.stage_root, self.service_root, io) catch |err| {
            if (old_exists) std.Io.Dir.renameAbsolute(backup_root, self.service_root, io) catch {};
            return mapFsError(err);
        };
        if (old_exists) path.deleteTreeAbsolute(backup_root) catch {};
        self.committed = true;
    }

    pub fn discard(self: *StagedDinit) void {
        if (!self.committed) path.deleteTreeAbsolute(self.stage_root) catch {};
        self.allocator.free(self.service_root);
        self.allocator.free(self.stage_root);
        self.* = undefined;
    }
};

/// Prepare dinit's package-owned service tree for a system profile.
///
/// Package-owned files live below `<generation>/usr/share/dinit.d` so the
/// complete tree becomes visible with the generation switch. Administrator
/// overrides under `<root>/etc/dinit.d` remain untouched.
pub fn stageDinit(
    ctx: *mere.Context,
    generation_root: []const u8,
    packages: []const generation.PackageEntry,
    previous_packages: []const generation.PackageEntry,
) ReconcileError!StagedDinit {
    _ = previous_packages;
    const allocator = ctx.allocator;
    const service_root = std.fs.path.join(allocator, &.{ generation_root, "usr", "share", "dinit.d" }) catch
        return error.OutOfMemory;
    errdefer allocator.free(service_root);
    const stage_root = std.fmt.allocPrint(allocator, "{s}.mere-new", .{service_root}) catch return error.OutOfMemory;
    errdefer allocator.free(stage_root);

    path.deleteTreeAbsolute(stage_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFsError(err),
    };
    path.ensureDirExists(stage_root) catch |err| return mapFsError(err);

    var target_names = std.StringHashMap(void).init(allocator);
    defer freeNames(allocator, &target_names);
    try collectNames(ctx, packages, &target_names);

    // The complete package-owned tree is built off to the side. This avoids
    // exposing a partially updated service set to dinit.
    for (packages) |pkg| {
        var package_meta = meta.readFile(allocator, pkg.store_path) catch |err| return mapMetaError(err);
        defer package_meta.deinit();
        for (package_meta.services.items) |service| {
            try writeDinitService(ctx, stage_root, &service);
        }
    }

    return .{ .allocator = allocator, .service_root = service_root, .stage_root = stage_root };
}

/// Prepare and immediately commit a dinit service tree. Install/profile code
/// should prefer `stageDinit` so generation activation can happen first.
pub fn reconcileDinit(
    ctx: *mere.Context,
    packages: []const generation.PackageEntry,
    previous_packages: []const generation.PackageEntry,
) ReconcileError!void {
    var staged = try stageDinit(ctx, ctx.root_path, packages, previous_packages);
    staged.commit() catch |err| {
        staged.discard();
        return err;
    };
    staged.discard();
}

fn collectNames(
    ctx: *mere.Context,
    packages: []const generation.PackageEntry,
    names: *std.StringHashMap(void),
) ReconcileError!void {
    const allocator = ctx.allocator;
    for (packages) |pkg| {
        var package_meta = meta.readFile(allocator, pkg.store_path) catch |err| return mapMetaError(err);
        defer package_meta.deinit();
        for (package_meta.services.items) |service| {
            if (!validServiceName(service.name)) return error.InvalidInput;
            if (names.contains(service.name)) return error.DuplicateService;
            const owned_name = allocator.dupe(u8, service.name) catch return error.OutOfMemory;
            names.put(owned_name, {}) catch |err| {
                allocator.free(owned_name);
                return if (err == error.OutOfMemory) error.OutOfMemory else error.FileSystem;
            };
        }
    }
}

fn writeDinitService(ctx: *mere.Context, service_root: []const u8, service: *const meta.Service) ReconcileError!void {
    const allocator = ctx.allocator;
    const io = path.currentIo();
    const file_path = std.fs.path.join(allocator, &.{ service_root, service.name }) catch return error.OutOfMemory;
    defer allocator.free(file_path);
    const temp_path = std.fmt.allocPrint(allocator, "{s}.mere-new", .{file_path}) catch return error.OutOfMemory;
    defer allocator.free(temp_path);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);

    const type_line = switch (service.service_type) {
        .daemon => "type = process\n",
        .oneshot => "type = scripted\n",
    };
    content.appendSlice(allocator, type_line) catch return error.OutOfMemory;

    switch (service.service_type) {
        .daemon => {
            try appendCommand(&content, allocator, "command = ", service.command.items);
            if (service.ready_notification) |fd| {
                const line = std.fmt.allocPrint(allocator, "ready-notification = pipefd:{d}\n", .{fd}) catch return error.OutOfMemory;
                defer allocator.free(line);
                content.appendSlice(allocator, line) catch return error.OutOfMemory;
            }
            if (service.log) {
                const line = std.fmt.allocPrint(allocator, "logfile = /var/log/{s}.log\n", .{service.name}) catch return error.OutOfMemory;
                defer allocator.free(line);
                content.appendSlice(allocator, line) catch return error.OutOfMemory;
            }
        },
        .oneshot => {
            try appendCommand(&content, allocator, "command = ", service.up.items);
            try appendCommand(&content, allocator, "stop-command = ", service.down.items);
        },
    }

    for (service.depends_on.items) |dependency| {
        const line = std.fmt.allocPrint(allocator, "depends-on = {s}\n", .{dependency}) catch return error.OutOfMemory;
        defer allocator.free(line);
        content.appendSlice(allocator, line) catch return error.OutOfMemory;
    }

    if (service.essential) content.appendSlice(allocator, "# mere: essential = true\n") catch return error.OutOfMemory;

    var file = std.Io.Dir.createFileAbsolute(io, temp_path, .{}) catch |err| return mapFsError(err);
    file.writeStreamingAll(io, content.items) catch |err| {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return mapFsError(err);
    };
    file.close(io);

    std.Io.Dir.renameAbsolute(temp_path, file_path, io) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return mapFsError(err);
    };
}

fn appendCommand(
    content: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    args: []const []const u8,
) ReconcileError!void {
    if (args.len == 0) return;
    content.appendSlice(allocator, prefix) catch return error.OutOfMemory;
    for (args, 0..) |arg, index| {
        if (index > 0) content.append(allocator, ' ') catch return error.OutOfMemory;
        content.appendSlice(allocator, arg) catch return error.OutOfMemory;
    }
    content.append(allocator, '\n') catch return error.OutOfMemory;
}

fn validServiceName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (byte == '/' or byte == '\\' or byte == 0) return false;
    }
    return true;
}

fn freeNames(allocator: std.mem.Allocator, names: *std.StringHashMap(void)) void {
    var it = names.keyIterator();
    while (it.next()) |name| allocator.free(name.*);
    names.deinit();
}

fn mapFsError(err: anyerror) ReconcileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.PermissionDenied,
        else => error.FileSystem,
    };
}

fn mapMetaError(err: anyerror) ReconcileError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.PermissionDenied,
        error.InvalidInput, error.ParseError => error.InvalidInput,
        else => error.FileSystem,
    };
}

test "reconcileDinit materializes metadata and removes stale services" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);
    try path.ensureDirExists(store_root);

    const old_pkg = try std.fs.path.join(allocator, &.{ store_root, "old" });
    defer allocator.free(old_pkg);
    const new_pkg = try std.fs.path.join(allocator, &.{ store_root, "new" });
    defer allocator.free(new_pkg);
    try path.ensureDirExists(old_pkg);
    try path.ensureDirExists(new_pkg);

    var old_meta = meta.Data.init(allocator);
    defer old_meta.deinit();
    var old_service = meta.Service.init(allocator);
    old_service.name = try allocator.dupe(u8, "old-service");
    old_service.service_type = .daemon;
    try old_service.command.append(allocator, try allocator.dupe(u8, "/bin/old"));
    try old_meta.services.append(allocator, old_service);
    try meta.writeFile(allocator, old_pkg, &old_meta);

    var new_meta = meta.Data.init(allocator);
    defer new_meta.deinit();
    var new_service = meta.Service.init(allocator);
    new_service.name = try allocator.dupe(u8, "new-service");
    new_service.service_type = .oneshot;
    try new_service.up.append(allocator, try allocator.dupe(u8, "/bin/new"));
    try new_meta.services.append(allocator, new_service);
    try meta.writeFile(allocator, new_pkg, &new_meta);

    const old_hash = try allocator.dupe(u8, "old-hash");
    defer allocator.free(old_hash);
    const new_hash = try allocator.dupe(u8, "new-hash");
    defer allocator.free(new_hash);
    const old_entry = generation.PackageEntry{
        .name = "old",
        .version = "1",
        .release = 1,
        .arch = "any",
        .store_path = old_pkg,
        .content_hash = old_hash,
    };
    const new_entry = generation.PackageEntry{
        .name = "new",
        .version = "1",
        .release = 1,
        .arch = "any",
        .store_path = new_pkg,
        .content_hash = new_hash,
    };

    try reconcileDinit(&test_env.ctx, &.{new_entry}, &.{old_entry});

    const service_root = try std.fs.path.join(allocator, &.{ test_env.path, "usr", "share", "dinit.d" });
    defer allocator.free(service_root);
    const old_path = try std.fs.path.join(allocator, &.{ service_root, "old-service" });
    defer allocator.free(old_path);
    const new_path = try std.fs.path.join(allocator, &.{ service_root, "new-service" });
    defer allocator.free(new_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path.currentIo(), old_path, .{}));
    try std.Io.Dir.accessAbsolute(path.currentIo(), new_path, .{});

    const content = try std.Io.Dir.cwd().readFileAlloc(path.currentIo(), new_path, allocator, .limited(4096));
    defer allocator.free(content);
    try std.testing.expect(std.mem.startsWith(u8, content, "type = scripted\ncommand = /bin/new\n"));
}
