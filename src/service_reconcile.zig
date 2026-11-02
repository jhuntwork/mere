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

    if (target_names.contains("mere-essential") or target_names.contains("mere-essential.d"))
        return ctx.fail(error.DuplicateService, "mere-essential", "service name reserved for the required boot bundle");

    // The complete package-owned tree is built off to the side. This avoids
    // exposing a partially updated service set to dinit.
    for (packages) |pkg| {
        var package_meta = meta.readFile(allocator, pkg.store_path) catch |err| return mapMetaError(err);
        defer package_meta.deinit();
        for (package_meta.services.items) |service| {
            try writeDinitService(ctx, stage_root, &service);
        }
    }

    try writeEssentialBundle(ctx, stage_root, packages);
    return .{ .allocator = allocator, .service_root = service_root, .stage_root = stage_root };
}

/// Prepare and immediately commit a dinit service tree. Install/profile code
/// should stage into the target generation and commit before activating it.
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

fn writeEssentialBundle(ctx: *mere.Context, root: []const u8, packages: []const generation.PackageEntry) ReconcileError!void {
    const allocator = ctx.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (packages) |pkg| {
        var data = meta.readFile(allocator, pkg.store_path) catch |err| return mapMetaError(err);
        defer data.deinit();
        for (data.services.items) |service| {
            if (service.essential) {
                const owned = try allocator.dupe(u8, service.name);
                names.append(allocator, owned) catch |err| {
                    allocator.free(owned);
                    return err;
                };
            }
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    try content.appendSlice(allocator, "type = internal\n# mere: essential = true\n");
    for (names.items) |name| {
        try content.appendSlice(allocator, "depends-on = ");
        try content.appendSlice(allocator, name);
        try content.append(allocator, '\n');
    }
    const file_path = try std.fs.path.join(allocator, &.{ root, "mere-essential" });
    defer allocator.free(file_path);
    var file = std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{}) catch |err| return mapFsError(err);
    defer file.close(path.currentIo());
    file.writeStreamingAll(path.currentIo(), content.items) catch |err| return mapFsError(err);
    const directory = try std.fs.path.join(allocator, &.{ root, "mere-essential.d" });
    defer allocator.free(directory);
    path.ensureDirExists(directory) catch |err| return mapFsError(err);
    var dir = std.Io.Dir.openDirAbsolute(path.currentIo(), directory, .{}) catch |err| return mapFsError(err);
    defer dir.close(path.currentIo());
    dir.symLink(path.currentIo(), "../mere-essential", "mere-essential", .{}) catch |err| return mapFsError(err);
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
    new_service.essential = true;
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
    const bundle = try std.fs.path.join(allocator, &.{ service_root, "mere-essential" });
    defer allocator.free(bundle);
    const required = try std.Io.Dir.cwd().readFileAlloc(path.currentIo(), bundle, allocator, .limited(4096));
    defer allocator.free(required);
    try std.testing.expect(std.mem.indexOf(u8, required, "depends-on = new-service\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, required, "old-service") == null);
    try reconcileDinit(&test_env.ctx, &.{}, &.{new_entry});
    const empty = try std.Io.Dir.cwd().readFileAlloc(path.currentIo(), bundle, allocator, .limited(4096));
    defer allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "depends-on") == null);
}

fn writeEssentialFixture(ctx: *mere.Context, arena: std.mem.Allocator, root: []const u8, name: []const u8, essential: bool) !generation.PackageEntry {
    const dir = try std.fs.path.join(arena, &.{ root, name });
    try path.ensureDirExists(dir);
    var data = meta.Data.init(ctx.allocator);
    defer data.deinit();
    var service = meta.Service.init(ctx.allocator);
    service.name = try ctx.allocator.dupe(u8, name);
    service.service_type = .daemon;
    service.essential = essential;
    try service.command.append(ctx.allocator, try ctx.allocator.dupe(u8, "/bin/true"));
    try data.services.append(ctx.allocator, service);
    try meta.writeFile(ctx.allocator, dir, &data);
    return .{ .name = name, .version = "1", .release = 1, .arch = "any", .store_path = dir, .content_hash = "0" ** 64 };
}

test "reconcileDinit exposes the essential bundle through mere-essential.d" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = try writeEssentialFixture(&env.ctx, a, env.path, "must-run", true);

    try reconcileDinit(&env.ctx, &.{entry}, &.{});

    const link = try std.fs.path.join(a, &.{ env.path, "usr", "share", "dinit.d", "mere-essential.d", "mere-essential" });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try std.Io.Dir.readLinkAbsolute(path.currentIo(), link, &target_buf);
    try std.testing.expectEqualStrings("../mere-essential", target_buf[0..target_len]);
    // The link must resolve to the generated bundle, since dinit follows it.
    const bundle = try std.Io.Dir.cwd().readFileAlloc(path.currentIo(), link, a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, bundle, "depends-on = must-run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundle, "# mere: essential = true\n") != null);
}

test "reconcileDinit rejects package services named like the essential bundle" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "mere-essential", "mere-essential.d" }) |reserved| {
        const entry = try writeEssentialFixture(&env.ctx, a, env.path, reserved, false);
        try std.testing.expectError(error.DuplicateService, reconcileDinit(&env.ctx, &.{entry}, &.{}));
    }
}

fn sweepStage(allocator: std.mem.Allocator, a_dir: []const u8, b_dir: []const u8, root: []const u8) !void {
    var base = mere.Context.init(std.testing.allocator, root);
    defer base.deinit();
    var ctx = base;
    ctx.allocator = allocator;
    const a: generation.PackageEntry = .{ .name = "a", .version = "1", .release = 1, .arch = "any", .store_path = a_dir, .content_hash = "0" ** 64 };
    const b: generation.PackageEntry = .{ .name = "b", .version = "1", .release = 1, .arch = "any", .store_path = b_dir, .content_hash = "0" ** 64 };
    reconcileDinit(&ctx, &.{ a, b }, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
}

test "reconcileDinit releases its allocations on every failure point" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const a = try writeEssentialFixture(&env.ctx, aa, env.path, "svc-a", true);
    const b = try writeEssentialFixture(&env.ctx, aa, env.path, "svc-b", false);
    // Each run replaces the tree from the previous one, so the sweep is repeatable.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sweepStage, .{ a.store_path, b.store_path, env.path });
}
