const std = @import("std");
const Context = @import("mere.zig").Context;
const generation = @import("generation.zig");
const errors = @import("errors.zig");
const version = @import("version.zig");

/// Template handling error set
const Std = errors.StandardErrors;
pub const EtcError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || error{DuplicateTemplate}; // Two packages provide same /etc path

pub const TemplateState = enum {
    missing,
    identical,
    different,
};

pub const TemplateEntry = struct {
    relative_path: []const u8,
    source_path: []const u8,
    etc_path: []const u8,
    package_name: []const u8,
    state: TemplateState,

    pub fn deinit(self: *TemplateEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        allocator.free(self.source_path);
        allocator.free(self.etc_path);
        allocator.free(self.package_name);
    }
};

pub const TemplateStatus = struct {
    missing: usize,
    identical: usize,
    differing: usize,
    entries: std.ArrayList(TemplateEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TemplateStatus {
        return .{
            .missing = 0,
            .identical = 0,
            .differing = 0,
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TemplateStatus) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn canonicalize(self: *TemplateStatus) void {
        std.mem.sort(TemplateEntry, self.entries.items, {}, lessThanTemplateEntry);
    }
};

/// Result of /etc template processing during activation.
pub const TemplateResult = struct {
    /// Number of templates copied (destination was missing)
    copied: usize,
    /// Number of templates skipped (destination identical)
    skipped: usize,
    /// Number of existing /etc files that differ from the active defaults
    differing: usize,
    /// Files created during this processing run (for rollback on failure)
    created_paths: std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TemplateResult {
        return TemplateResult{
            .copied = 0,
            .skipped = 0,
            .differing = 0,
            .created_paths = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TemplateResult) void {
        for (self.created_paths.items) |path| {
            self.allocator.free(path);
        }
        self.created_paths.deinit(self.allocator);
    }
};

const TemplateSource = struct {
    store_path: []const u8,
    package_name: []const u8,
};

/// Process all templates from a generation's packages.
///
/// Walks each package's store root looking for `etc-defaults/` subtrees and
/// processes templates according to the activation rules.
pub fn processTemplates(
    ctx: *Context,
    manifest: *const generation.GenerationManifest,
    etc_dir: []const u8,
) EtcError!TemplateResult {
    const allocator = ctx.allocator;
    var result = TemplateResult.init(allocator);
    errdefer {
        rollbackCreatedFiles(ctx, &result) catch {};
        result.deinit();
    }

    var status = try collectStatus(ctx, manifest, etc_dir);
    defer status.deinit();

    for (status.entries.items) |entry| {
        switch (entry.state) {
            .missing => {
                try copyTemplate(ctx, entry.source_path, entry.etc_path);
                const created_copy = allocator.dupe(u8, entry.etc_path) catch return EtcError.OutOfMemory;
                errdefer allocator.free(created_copy);
                result.created_paths.append(allocator, created_copy) catch return EtcError.OutOfMemory;
            },
            .identical, .different => {},
        }
    }

    result.copied = status.missing;
    result.skipped = status.identical;
    result.differing = status.differing;

    return result;
}

pub fn collectStatus(
    ctx: *Context,
    manifest: *const generation.GenerationManifest,
    etc_dir: []const u8,
) EtcError!TemplateStatus {
    const allocator = ctx.allocator;
    var status = TemplateStatus.init(allocator);
    errdefer status.deinit();

    var seen_paths = std.StringHashMap(TemplateSource).init(allocator);
    defer {
        var iter = seen_paths.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        seen_paths.deinit();
    }

    const package_order = try buildSortedPackageOrder(allocator, manifest);
    defer allocator.free(package_order);

    for (package_order) |pkg_index| {
        const pkg = manifest.packages.items[pkg_index];
        try collectPackageTemplates(ctx, pkg.store_path, pkg.name, etc_dir, &seen_paths, &status);
    }

    status.canonicalize();
    return status;
}

/// Remove files created during template processing, in reverse order.
pub fn rollbackCreatedFiles(ctx: *Context, result: *const TemplateResult) EtcError!void {
    var idx = result.created_paths.items.len;
    while (idx > 0) {
        idx -= 1;
        const path = result.created_paths.items[idx];
        std.fs.deleteFileAbsolute(path) catch |err| {
            switch (err) {
                error.FileNotFound => {},
                error.AccessDenied => return ctx.fail(EtcError.PermissionDenied, path, "permission denied cleaning up /etc activation file"),
                else => return ctx.fail(EtcError.FileSystem, path, "failed cleaning up /etc activation file"),
            }
        };
    }
}

/// Collect template status from a single package's store path.
fn collectPackageTemplates(
    ctx: *Context,
    store_path: []const u8,
    package_name: []const u8,
    etc_dir: []const u8,
    seen_paths: *std.StringHashMap(TemplateSource),
    status: *TemplateStatus,
) EtcError!void {
    const allocator = ctx.allocator;
    // Build path to etc-defaults in this package
    const template_root = std.fs.path.join(allocator, &.{ store_path, "etc-defaults" }) catch {
        return EtcError.OutOfMemory;
    };
    defer allocator.free(template_root);

    // Check if etc-defaults exists in this package
    var template_dir = std.fs.openDirAbsolute(template_root, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => {}, // No templates in this package, that's fine
            error.AccessDenied => {
                return ctx.fail(EtcError.PermissionDenied, template_root, "permission denied reading etc-defaults");
            },
            else => {
                return ctx.fail(EtcError.FileSystem, template_root, "failed to open etc-defaults");
            },
        };
    };
    defer template_dir.close();

    // Walk the template directory recursively
    try walkTemplates(ctx, template_dir, template_root, "", package_name, etc_dir, seen_paths, status);
}

/// Recursively walk a template directory and process files.
fn walkTemplates(
    ctx: *Context,
    dir: std.fs.Dir,
    template_root: []const u8,
    relative_path: []const u8,
    package_name: []const u8,
    etc_dir: []const u8,
    seen_paths: *std.StringHashMap(TemplateSource),
    status: *TemplateStatus,
) EtcError!void {
    const allocator = ctx.allocator;
    var iter = dir.iterate();
    while (true) {
        const entry = iter.next() catch {
            return EtcError.FileSystem;
        };
        if (entry == null) break;
        const e = entry.?;

        // Build relative path for this entry
        const entry_rel_path = if (relative_path.len == 0)
            allocator.dupe(u8, e.name) catch return EtcError.OutOfMemory
        else
            std.fs.path.join(allocator, &.{ relative_path, e.name }) catch return EtcError.OutOfMemory;
        defer allocator.free(entry_rel_path);

        if (e.kind == .directory) {
            // Recurse into subdirectory
            var subdir = dir.openDir(e.name, .{ .iterate = true }) catch |err| {
                return switch (err) {
                    error.AccessDenied => {
                        return ctx.fail(EtcError.PermissionDenied, e.name, "permission denied opening template directory");
                    },
                    else => {
                        return ctx.fail(EtcError.FileSystem, e.name, "failed to open template directory");
                    },
                };
            };
            defer subdir.close();
            try walkTemplates(ctx, subdir, template_root, entry_rel_path, package_name, etc_dir, seen_paths, status);
        } else if (e.kind == .file) {
            // Process this template file
            try processTemplateFile(ctx, template_root, entry_rel_path, package_name, etc_dir, seen_paths, status);
        }
        // Skip symlinks and other types in templates
    }
}

/// Process a single template file.
fn processTemplateFile(
    ctx: *Context,
    template_root: []const u8,
    relative_path: []const u8,
    package_name: []const u8,
    etc_dir: []const u8,
    seen_paths: *std.StringHashMap(TemplateSource),
    status: *TemplateStatus,
) EtcError!void {
    const allocator = ctx.allocator;
    if (seen_paths.get(relative_path)) |existing| {
        const detail = std.fmt.allocPrint(
            allocator,
            "duplicate /etc template path provided by packages '{s}' and '{s}'",
            .{ existing.package_name, package_name },
        ) catch return EtcError.OutOfMemory;
        defer allocator.free(detail);
        return ctx.fail(EtcError.DuplicateTemplate, relative_path, detail);
    }

    // Record this path
    const path_copy = allocator.dupe(u8, relative_path) catch return EtcError.OutOfMemory;
    seen_paths.put(path_copy, .{
        .store_path = template_root,
        .package_name = package_name,
    }) catch {
        allocator.free(path_copy);
        return EtcError.OutOfMemory;
    };

    // Build source and destination paths
    const src_path = std.fs.path.join(allocator, &.{ template_root, relative_path }) catch {
        return EtcError.OutOfMemory;
    };
    defer allocator.free(src_path);

    const dest_path = std.fs.path.join(allocator, &.{ etc_dir, relative_path }) catch {
        return EtcError.OutOfMemory;
    };
    defer allocator.free(dest_path);

    // Check if destination exists
    const dest_exists = blk: {
        std.fs.accessAbsolute(dest_path, .{}) catch |err| {
            if (err == error.FileNotFound) break :blk false;
            if (err == error.AccessDenied) return EtcError.PermissionDenied;
            return EtcError.FileSystem;
        };
        break :blk true;
    };

    const state: TemplateState = if (!dest_exists)
        .missing
    else if (try filesIdentical(ctx, src_path, dest_path))
        .identical
    else
        .different;

    switch (state) {
        .missing => status.missing += 1,
        .identical => status.identical += 1,
        .different => status.differing += 1,
    }

    status.entries.append(allocator, .{
        .relative_path = allocator.dupe(u8, relative_path) catch return EtcError.OutOfMemory,
        .source_path = allocator.dupe(u8, src_path) catch return EtcError.OutOfMemory,
        .etc_path = allocator.dupe(u8, dest_path) catch return EtcError.OutOfMemory,
        .package_name = allocator.dupe(u8, package_name) catch return EtcError.OutOfMemory,
        .state = state,
    }) catch return EtcError.OutOfMemory;
}

pub fn applyTemplate(ctx: *Context, source_path: []const u8, dest_path: []const u8) EtcError!void {
    const allocator = ctx.allocator;
    const old_path = std.fmt.allocPrint(allocator, "{s}.old", .{dest_path}) catch {
        return EtcError.OutOfMemory;
    };
    defer allocator.free(old_path);

    if (std.fs.accessAbsolute(dest_path, .{})) |_| {
        std.fs.renameAbsolute(dest_path, old_path) catch |err| {
            ctx.setDiagnosticContext(dest_path, "failed to back up existing /etc file");
            return switch (err) {
                error.AccessDenied => EtcError.PermissionDenied,
                else => EtcError.FileSystem,
            };
        };
    } else |_| {}

    try copyTemplate(ctx, source_path, dest_path);
}

fn buildSortedPackageOrder(
    allocator: std.mem.Allocator,
    manifest: *const generation.GenerationManifest,
) EtcError![]usize {
    const order = allocator.alloc(usize, manifest.packages.items.len) catch return EtcError.OutOfMemory;
    errdefer allocator.free(order);

    for (order, 0..) |*slot, idx| {
        slot.* = idx;
    }

    const Ctx = struct {
        manifest: *const generation.GenerationManifest,
    };

    std.mem.sort(usize, order, Ctx{ .manifest = manifest }, struct {
        fn lessThan(ctx: Ctx, a_idx: usize, b_idx: usize) bool {
            const a = ctx.manifest.packages.items[a_idx];
            const b = ctx.manifest.packages.items[b_idx];

            if (!std.mem.eql(u8, a.name, b.name)) {
                return std.mem.lessThan(u8, a.name, b.name);
            }

            const version_order = version.comparePackageVersions(a.version, a.release, b.version, b.release) catch unreachable;
            if (version_order != .equal) {
                return version_order == .less;
            }

            if (!std.mem.eql(u8, a.arch, b.arch)) {
                return std.mem.lessThan(u8, a.arch, b.arch);
            }

            return std.mem.lessThan(u8, a.store_path, b.store_path);
        }
    }.lessThan);

    return order;
}

fn lessThanTemplateEntry(_: void, a: TemplateEntry, b: TemplateEntry) bool {
    return std.mem.lessThan(u8, a.etc_path, b.etc_path);
}

/// Copy a template file to destination, creating parent directories as needed.
fn copyTemplate(ctx: *Context, src_path: []const u8, dest_path: []const u8) EtcError!void {
    // Ensure parent directory exists
    if (std.fs.path.dirnamePosix(dest_path)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| {
            ctx.setDiagnosticContext(parent, "failed to create /etc parent directory");
            return switch (err) {
                error.AccessDenied => EtcError.PermissionDenied,
                else => EtcError.FileSystem,
            };
        };
    }

    // Copy the file
    std.fs.copyFileAbsolute(src_path, dest_path, .{}) catch |err| {
        ctx.setDiagnosticContext(dest_path, "failed to copy /etc template");
        return switch (err) {
            error.FileNotFound => EtcError.FileSystem,
            error.AccessDenied => EtcError.PermissionDenied,
            else => EtcError.FileSystem,
        };
    };
}

/// Check if two files have identical contents.
fn filesIdentical(ctx: *Context, path_a: []const u8, path_b: []const u8) EtcError!bool {
    const allocator = ctx.allocator;
    // Read both files
    const content_a = std.fs.cwd().readFileAlloc(allocator, path_a, 10 * 1024 * 1024) catch |err| {
        ctx.setDiagnosticContext(path_a, "failed to read /etc template");
        return switch (err) {
            error.FileNotFound => EtcError.FileSystem,
            error.AccessDenied => EtcError.PermissionDenied,
            error.OutOfMemory => EtcError.OutOfMemory,
            else => EtcError.FileSystem,
        };
    };
    defer allocator.free(content_a);

    const content_b = std.fs.cwd().readFileAlloc(allocator, path_b, 10 * 1024 * 1024) catch |err| {
        ctx.setDiagnosticContext(path_b, "failed to read /etc template");
        return switch (err) {
            error.FileNotFound => EtcError.FileSystem,
            error.AccessDenied => EtcError.PermissionDenied,
            error.OutOfMemory => EtcError.OutOfMemory,
            else => EtcError.FileSystem,
        };
    };
    defer allocator.free(content_b);

    return std.mem.eql(u8, content_a, content_b);
}

// Tests

// Spec #13: Identical content detection
test "filesIdentical returns true for same content" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const file_a = try std.fs.path.join(allocator, &.{ test_env.path, "a.txt" });
    defer allocator.free(file_a);
    const file_b = try std.fs.path.join(allocator, &.{ test_env.path, "b.txt" });
    defer allocator.free(file_b);

    // Write same content to both
    var fa = try std.fs.createFileAbsolute(file_a, .{});
    try fa.writeAll("hello world");
    fa.close();

    var fb = try std.fs.createFileAbsolute(file_b, .{});
    try fb.writeAll("hello world");
    fb.close();

    try std.testing.expect(try filesIdentical(&test_env.ctx, file_a, file_b));
}

// Spec #13: Different content detection
test "filesIdentical returns false for different content" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const file_a = try std.fs.path.join(allocator, &.{ test_env.path, "a.txt" });
    defer allocator.free(file_a);
    const file_b = try std.fs.path.join(allocator, &.{ test_env.path, "b.txt" });
    defer allocator.free(file_b);

    var fa = try std.fs.createFileAbsolute(file_a, .{});
    try fa.writeAll("hello");
    fa.close();

    var fb = try std.fs.createFileAbsolute(file_b, .{});
    try fb.writeAll("world");
    fb.close();

    try std.testing.expect(!try filesIdentical(&test_env.ctx, file_a, file_b));
}

// Spec #13: Missing destination → copy template to /etc
test "processTemplates copies missing file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store path with template
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "store", "abc-pkg-1.0" });
    defer allocator.free(store_path);

    const template_dir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults", "myapp" });
    defer allocator.free(template_dir);
    try std.fs.cwd().makePath(template_dir);

    const template_file = try std.fs.path.join(allocator, &.{ template_dir, "config.conf" });
    defer allocator.free(template_file);
    var tf = try std.fs.createFileAbsolute(template_file, .{});
    try tf.writeAll("default config");
    tf.close();

    // Create etc directory
    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);

    // Create manifest with this package
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage("pkg", "1.0", 1, "x86_64", store_path, "abc123");

    // Process templates
    var result = try processTemplates(&test_env.ctx, &manifest, etc_dir);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.copied);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.differing);

    // Verify file was copied
    const dest_file = try std.fs.path.join(allocator, &.{ etc_dir, "myapp", "config.conf" });
    defer allocator.free(dest_file);

    const content = try std.fs.cwd().readFileAlloc(allocator, dest_file, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("default config", content);
}

// Spec #13: Identical destination → do nothing
test "processTemplates skips identical file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store path with template
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "store", "abc-pkg-1.0" });
    defer allocator.free(store_path);

    const template_dir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults" });
    defer allocator.free(template_dir);
    try std.fs.cwd().makePath(template_dir);

    const template_file = try std.fs.path.join(allocator, &.{ template_dir, "config.conf" });
    defer allocator.free(template_file);
    var tf = try std.fs.createFileAbsolute(template_file, .{});
    try tf.writeAll("same content");
    tf.close();

    // Create etc with identical file
    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);

    const etc_file = try std.fs.path.join(allocator, &.{ etc_dir, "config.conf" });
    defer allocator.free(etc_file);
    var ef = try std.fs.createFileAbsolute(etc_file, .{});
    try ef.writeAll("same content");
    ef.close();

    // Create manifest
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage("pkg", "1.0", 1, "x86_64", store_path, "abc123");

    // Process templates
    var result = try processTemplates(&test_env.ctx, &manifest, etc_dir);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.copied);
    try std.testing.expectEqual(@as(usize, 1), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.differing);
}

// Spec #13: Different destination → report drift without overwriting /etc
test "processTemplates reports differing file without writing .new" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store path with template
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "store", "abc-pkg-1.0" });
    defer allocator.free(store_path);

    const template_dir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults" });
    defer allocator.free(template_dir);
    try std.fs.cwd().makePath(template_dir);

    const template_file = try std.fs.path.join(allocator, &.{ template_dir, "config.conf" });
    defer allocator.free(template_file);
    var tf = try std.fs.createFileAbsolute(template_file, .{});
    try tf.writeAll("new default");
    tf.close();

    // Create etc with different file
    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);

    const etc_file = try std.fs.path.join(allocator, &.{ etc_dir, "config.conf" });
    defer allocator.free(etc_file);
    var ef = try std.fs.createFileAbsolute(etc_file, .{});
    try ef.writeAll("user customized");
    ef.close();

    // Create manifest
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage("pkg", "1.0", 1, "x86_64", store_path, "abc123");

    // Process templates
    var result = try processTemplates(&test_env.ctx, &manifest, etc_dir);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.copied);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), result.differing);

    // Verify original unchanged
    const orig_content = try std.fs.cwd().readFileAlloc(allocator, etc_file, 1024);
    defer allocator.free(orig_content);
    try std.testing.expectEqualStrings("user customized", orig_content);

    const new_file = try std.fs.path.join(allocator, &.{ etc_dir, "config.conf.new" });
    defer allocator.free(new_file);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(new_file, .{}));
}

// Spec #13: Duplicate template paths from two packages = hard error
test "processTemplates detects duplicate template paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create two packages with same template path
    const store_path1 = try std.fs.path.join(allocator, &.{ test_env.path, "store", "abc-pkg1-1.0" });
    defer allocator.free(store_path1);
    const template_dir1 = try std.fs.path.join(allocator, &.{ store_path1, "etc-defaults" });
    defer allocator.free(template_dir1);
    try std.fs.cwd().makePath(template_dir1);
    const template_file1 = try std.fs.path.join(allocator, &.{ template_dir1, "shared.conf" });
    defer allocator.free(template_file1);
    var tf1 = try std.fs.createFileAbsolute(template_file1, .{});
    try tf1.writeAll("from pkg1");
    tf1.close();

    const store_path2 = try std.fs.path.join(allocator, &.{ test_env.path, "store", "def-pkg2-1.0" });
    defer allocator.free(store_path2);
    const template_dir2 = try std.fs.path.join(allocator, &.{ store_path2, "etc-defaults" });
    defer allocator.free(template_dir2);
    try std.fs.cwd().makePath(template_dir2);
    const template_file2 = try std.fs.path.join(allocator, &.{ template_dir2, "shared.conf" });
    defer allocator.free(template_file2);
    var tf2 = try std.fs.createFileAbsolute(template_file2, .{});
    try tf2.writeAll("from pkg2");
    tf2.close();

    // Create etc directory
    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);

    // Create manifest with both packages
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage("pkg1", "1.0", 1, "x86_64", store_path1, "abc123");
    try manifest.addPackage("pkg2", "1.0", 1, "x86_64", store_path2, "def456");

    // Process templates should fail with DuplicateTemplate
    const result = processTemplates(&test_env.ctx, &manifest, etc_dir);
    try std.testing.expectError(EtcError.DuplicateTemplate, result);
}

test "applyTemplate backs up and replaces" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create original and template files
    const original = try std.fs.path.join(allocator, &.{ test_env.path, "config.conf" });
    defer allocator.free(original);
    var fo = try std.fs.createFileAbsolute(original, .{});
    try fo.writeAll("original content");
    fo.close();

    const new_file = try std.fs.path.join(allocator, &.{ test_env.path, "template.conf" });
    defer allocator.free(new_file);
    var fn_ = try std.fs.createFileAbsolute(new_file, .{});
    try fn_.writeAll("new content");
    fn_.close();

    // Apply
    try applyTemplate(&test_env.ctx, new_file, original);

    // Verify original now has new content
    const content = try std.fs.cwd().readFileAlloc(allocator, original, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new content", content);

    // Verify .old has original content
    const old_file = try std.fs.path.join(allocator, &.{ test_env.path, "config.conf.old" });
    defer allocator.free(old_file);
    const old_content = try std.fs.cwd().readFileAlloc(allocator, old_file, 1024);
    defer allocator.free(old_content);
    try std.testing.expectEqualStrings("original content", old_content);

    const template_content = try std.fs.cwd().readFileAlloc(allocator, new_file, 1024);
    defer allocator.free(template_content);
    try std.testing.expectEqualStrings("new content", template_content);
}

// Spec #13: etc-defaults never overwrites /etc
test "processTemplates never overwrites existing /etc files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create a package store path with etc-defaults containing a config file
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "store", "abc-myapp-2.0" });
    defer allocator.free(store_path);

    const template_dir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults", "myapp" });
    defer allocator.free(template_dir);
    try std.fs.cwd().makePath(template_dir);

    const template_file = try std.fs.path.join(allocator, &.{ template_dir, "app.conf" });
    defer allocator.free(template_file);
    {
        var tf = try std.fs.createFileAbsolute(template_file, .{});
        try tf.writeAll("# new upstream default\nport = 9090\n");
        tf.close();
    }

    // Create /etc with an existing user-customized file at the same relative path
    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);

    const etc_app_dir = try std.fs.path.join(allocator, &.{ etc_dir, "myapp" });
    defer allocator.free(etc_app_dir);
    try std.fs.cwd().makePath(etc_app_dir);

    const etc_file = try std.fs.path.join(allocator, &.{ etc_app_dir, "app.conf" });
    defer allocator.free(etc_file);
    {
        var ef = try std.fs.createFileAbsolute(etc_file, .{});
        try ef.writeAll("# user customized\nport = 8080\n");
        ef.close();
    }

    // Build a generation manifest referencing this package
    var gen_manifest = generation.GenerationManifest.init(allocator, 1);
    defer gen_manifest.deinit();
    try gen_manifest.addPackage("myapp", "2.0", 1, "x86_64", store_path, "abc123");

    // Process templates (this is what activateFull calls internally)
    var result = try processTemplates(&test_env.ctx, &gen_manifest, etc_dir);
    defer result.deinit();

    // Verify: existing /etc file was NOT overwritten
    const etc_content = try std.fs.cwd().readFileAlloc(allocator, etc_file, 4096);
    defer allocator.free(etc_content);
    try std.testing.expectEqualStrings("# user customized\nport = 8080\n", etc_content);

    // Verify no eager .new file was created
    const new_file = try std.fs.path.join(allocator, &.{ etc_app_dir, "app.conf.new" });
    defer allocator.free(new_file);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(new_file, .{}));

    // Verify counts: 0 copied, 0 skipped, 1 differing file
    try std.testing.expectEqual(@as(usize, 0), result.copied);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(usize, 1), result.differing);
}

test "collectStatus reports differing and missing files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "store", "abc-pkg-1.0" });
    defer allocator.free(store_path);
    const template_dir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults", "myapp" });
    defer allocator.free(template_dir);
    try std.fs.cwd().makePath(template_dir);

    const changed_file = try std.fs.path.join(allocator, &.{ template_dir, "changed.conf" });
    defer allocator.free(changed_file);
    {
        var f = try std.fs.createFileAbsolute(changed_file, .{});
        try f.writeAll("default changed");
        f.close();
    }

    const missing_file = try std.fs.path.join(allocator, &.{ template_dir, "missing.conf" });
    defer allocator.free(missing_file);
    {
        var f = try std.fs.createFileAbsolute(missing_file, .{});
        try f.writeAll("default missing");
        f.close();
    }

    const same_file = try std.fs.path.join(allocator, &.{ template_dir, "same.conf" });
    defer allocator.free(same_file);
    {
        var f = try std.fs.createFileAbsolute(same_file, .{});
        try f.writeAll("default same");
        f.close();
    }

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    const etc_app_dir = try std.fs.path.join(allocator, &.{ etc_dir, "myapp" });
    defer allocator.free(etc_app_dir);
    try std.fs.cwd().makePath(etc_app_dir);

    const etc_changed = try std.fs.path.join(allocator, &.{ etc_app_dir, "changed.conf" });
    defer allocator.free(etc_changed);
    {
        var f = try std.fs.createFileAbsolute(etc_changed, .{});
        try f.writeAll("user changed");
        f.close();
    }

    const etc_same = try std.fs.path.join(allocator, &.{ etc_app_dir, "same.conf" });
    defer allocator.free(etc_same);
    {
        var f = try std.fs.createFileAbsolute(etc_same, .{});
        try f.writeAll("default same");
        f.close();
    }

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage("pkg", "1.0", 1, "x86_64", store_path, "abc123");

    var status = try collectStatus(&test_env.ctx, &manifest, etc_dir);
    defer status.deinit();

    try std.testing.expectEqual(@as(usize, 1), status.differing);
    try std.testing.expectEqual(@as(usize, 1), status.missing);
    try std.testing.expectEqual(@as(usize, 1), status.identical);
    try std.testing.expectEqual(@as(usize, 3), status.entries.items.len);
    const expected_first = try std.fs.path.join(allocator, &.{ etc_app_dir, "changed.conf" });
    defer allocator.free(expected_first);
    try std.testing.expectEqualStrings(expected_first, status.entries.items[0].etc_path);
}
