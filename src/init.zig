const std = @import("std");
const Context = @import("mere.zig").Context;
const errors = @import("errors.zig");

/// Init module error set
const Std = errors.StandardErrors;
pub const InitError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

fn mapInitFsError(err: anyerror) InitError {
    return switch (err) {
        error.OutOfMemory => InitError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => InitError.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => InitError.InvalidInput,
        else => InitError.FileSystem,
    };
}

/// Directory specification for initialization
pub const DirSpec = struct {
    path: []const u8,
    mode: u32,
    description: []const u8,
};

/// Options for initialization
pub const InitOptions = struct {
    /// If true, show what would be done without doing it
    dry_run: bool = false,
    /// If true, show detailed information
    verbose: bool = false,
};

/// Result of initialization check
pub const CheckResult = struct {
    path: []const u8,
    status: Status,
    expected_mode: u32,
    actual_mode: ?u32,
    expected_owner: []const u8,
    actual_owner: ?[]const u8,

    pub const Status = enum {
        ok,
        missing,
        wrong_permissions,
        wrong_ownership,
        not_directory,
    };
};

/// Result of initialization operation
pub const InitResult = struct {
    allocator: std.mem.Allocator,
    checks: std.ArrayList(CheckResult),
    changes_applied: usize,
    issues_found: usize,

    pub fn init(allocator: std.mem.Allocator) InitResult {
        return InitResult{
            .allocator = allocator,
            .checks = .{},
            .changes_applied = 0,
            .issues_found = 0,
        };
    }

    pub fn deinit(self: *InitResult) void {
        for (self.checks.items) |check| {
            self.allocator.free(check.path);
            self.allocator.free(check.expected_owner);
            if (check.actual_owner) |owner| {
                self.allocator.free(owner);
            }
        }
        self.checks.deinit(self.allocator);
    }
};

/// Required directory layout with specifications
fn getRequiredDirectories(allocator: std.mem.Allocator, root: []const u8) ![]DirSpec {
    var list: std.ArrayList(DirSpec) = .{};
    errdefer list.deinit(allocator);

    const dirs = [_]struct { rel: []const u8, mode: u32, desc: []const u8 }{
        .{ .rel = "mere", .mode = 0o755, .desc = "Mere root directory" },
        .{ .rel = "mere/keys", .mode = 0o755, .desc = "System public keys directory" },
        .{ .rel = "mere/store", .mode = 0o1777, .desc = "Package store (world-writable with sticky bit)" },
        .{ .rel = "mere/store/.incoming", .mode = 0o1777, .desc = "Store incoming staging (world-writable with sticky bit)" },
        .{ .rel = "mere/dev", .mode = 0o755, .desc = "Development root directory" },
        .{ .rel = "mere/dev/build", .mode = 0o1777, .desc = "Build workspaces (world-writable with sticky bit)" },
        .{ .rel = "mere/dev/outputs", .mode = 0o1777, .desc = "Build outputs (world-writable with sticky bit)" },
        .{ .rel = "mere/dev/repo", .mode = 0o1777, .desc = "Repository sources (world-writable with sticky bit)" },
        .{ .rel = "mere/dev/cache", .mode = 0o1777, .desc = "Development cache root (world-writable with sticky bit)" },
        .{ .rel = "mere/dev/cache/sources", .mode = 0o1777, .desc = "Source cache for local builds (world-writable with sticky bit)" },
        .{ .rel = "mere/dev/cache/build", .mode = 0o1777, .desc = "Build cache for local builds (world-writable with sticky bit)" },
        .{ .rel = "mere/cache", .mode = 0o1777, .desc = "Download cache (world-writable with sticky bit)" },
        .{ .rel = "mere/cache/repos", .mode = 0o1777, .desc = "Repository cache (world-writable with sticky bit)" },
        .{ .rel = "mere/cache/packages", .mode = 0o1777, .desc = "Shared package archive cache (world-writable with sticky bit)" },
        .{ .rel = "mere/profiles", .mode = 0o1777, .desc = "Profile root directory (world-writable with sticky bit for user profiles)" },
        .{ .rel = "mere/profiles/system", .mode = 0o755, .desc = "System profile (privileged-only)" },
        .{ .rel = "mere/gc-roots", .mode = 0o755, .desc = "GC roots directory" },
        .{ .rel = "mere/gc-roots/profiles", .mode = 0o755, .desc = "Profile GC roots (system and named profiles)" },
    };

    for (dirs) |dir| {
        const full_path = try std.fs.path.join(allocator, &.{ root, dir.rel });
        try list.append(allocator, DirSpec{
            .path = full_path,
            .mode = dir.mode,
            .description = dir.desc,
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Check if running as root
fn isRoot() bool {
    if (@hasDecl(std.posix, "getuid")) {
        return std.posix.getuid() == 0;
    }
    return false;
}

fn requiresRoot(options: InitOptions) bool {
    return !options.dry_run;
}

/// Get ownership information for a path
fn getOwnership(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Use fstatat to get ownership information
    // Note: fstatat internally calls toPosixPath, so we pass the path slice directly
    const stat_buf = std.posix.fstatat(std.posix.AT.FDCWD, path, 0) catch |err| {
        return switch (err) {
            error.FileNotFound => try allocator.dupe(u8, "not found"),
            else => mapInitFsError(err),
        };
    };

    return std.fmt.allocPrint(allocator, "uid:{d} gid:{d}", .{ stat_buf.uid, stat_buf.gid });
}

/// Check a single directory
fn checkDirectory(
    allocator: std.mem.Allocator,
    spec: DirSpec,
) !CheckResult {
    var result = CheckResult{
        .path = try allocator.dupe(u8, spec.path),
        .status = .ok,
        .expected_mode = spec.mode,
        .actual_mode = null,
        .expected_owner = try allocator.dupe(u8, "uid:0 gid:0"),
        .actual_owner = null,
    };

    const stat = std.fs.cwd().statFile(spec.path) catch |err| {
        return switch (err) {
            error.FileNotFound => {
                result.status = .missing;
                return result;
            },
            else => mapInitFsError(err),
        };
    };

    // Check if it's a directory
    if (stat.kind != .directory) {
        result.status = .not_directory;
        return result;
    }

    // Get actual mode (only permission bits)
    result.actual_mode = @as(u32, @intCast(stat.mode & 0o7777));

    // Check permissions
    if (result.actual_mode.? != spec.mode) {
        result.status = .wrong_permissions;
    }

    // Get actual ownership
    result.actual_owner = try getOwnership(allocator, spec.path);

    // Check ownership (should be root:root, which is uid:0 gid:0)
    if (result.actual_owner) |owner| {
        if (!std.mem.eql(u8, owner, result.expected_owner)) {
            result.status = .wrong_ownership;
        }
    }

    return result;
}

/// Create a directory with specified permissions
fn createDirectory(path: []const u8, mode: u32) !void {
    std.fs.cwd().makePath(path) catch |err| {
        return switch (err) {
            error.PathAlreadyExists => {}, // Already exists is ok
            else => mapInitFsError(err),
        };
    };

    // Set permissions using fchmodat
    // Note: fchmodat internally calls toPosixPath, so we pass the path slice directly
    std.posix.fchmodat(std.posix.AT.FDCWD, path, mode, 0) catch |err| {
        return mapInitFsError(err);
    };
}

/// Set ownership of a directory to root:root
fn setOwnership(path: []const u8) !void {
    var dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        return mapInitFsError(err);
    };
    defer dir.close();

    dir.chown(0, 0) catch |err| {
        return mapInitFsError(err);
    };
}

/// Fix a single directory
fn fixDirectory(spec: DirSpec, check: CheckResult) !void {
    switch (check.status) {
        .ok => {}, // Nothing to fix
        .missing => {
            try createDirectory(spec.path, spec.mode);
            try setOwnership(spec.path);
        },
        .wrong_permissions => {
            // Fix permissions - also fix ownership since we're already fixing the directory
            std.posix.fchmodat(std.posix.AT.FDCWD, spec.path, spec.mode, 0) catch |err| {
                return mapInitFsError(err);
            };
            try setOwnership(spec.path);
        },
        .wrong_ownership => {
            // Fix ownership - also fix permissions since we're already fixing the directory
            try setOwnership(spec.path);
            std.posix.fchmodat(std.posix.AT.FDCWD, spec.path, spec.mode, 0) catch |err| {
                return mapInitFsError(err);
            };
        },
        .not_directory => {
            return InitError.InvalidInput; // Cannot fix - path exists but is not a directory
        },
    }
}

/// Initialize and validate Mere filesystem layout
pub fn initialize(ctx: *Context, options: InitOptions) !InitResult {
    // Check if running as root
    if (requiresRoot(options) and !isRoot()) {
        return InitError.PermissionDenied;
    }

    var result = InitResult.init(ctx.allocator);
    errdefer result.deinit();

    // Get required directories
    const specs = try getRequiredDirectories(ctx.allocator, ctx.root_path);
    defer {
        for (specs) |spec| {
            ctx.allocator.free(spec.path);
        }
        ctx.allocator.free(specs);
    }

    // Check all directories
    for (specs) |spec| {
        const check = try checkDirectory(ctx.allocator, spec);
        try result.checks.append(ctx.allocator, check);

        if (check.status != .ok) {
            result.issues_found += 1;
        }
    }

    // If dry-run, don't apply changes
    if (options.dry_run) {
        return result;
    }

    // Apply fixes (keep original check status for reporting)
    for (specs, 0..) |spec, idx| {
        const check = result.checks.items[idx];
        if (check.status != .ok) {
            fixDirectory(spec, check) catch |err| {
                return err;
            };
            result.changes_applied += 1;
        }
    }

    // After fixes, issues_found represents issues that existed and were fixed
    // (we don't re-check because we want to report what was changed)

    return result;
}

// Tests
test "getRequiredDirectories returns correct paths" {
    const testing = std.testing;

    const dirs = try getRequiredDirectories(testing.allocator, "/test");
    defer {
        for (dirs) |dir| {
            testing.allocator.free(dir.path);
        }
        testing.allocator.free(dirs);
    }

    try testing.expect(dirs.len == 18);

    try testing.expectEqualStrings("/test/mere", dirs[0].path);
    try testing.expectEqual(@as(u32, 0o755), dirs[0].mode);

    try testing.expectEqualStrings("/test/mere/keys", dirs[1].path);
    try testing.expectEqual(@as(u32, 0o755), dirs[1].mode);

    try testing.expectEqualStrings("/test/mere/store", dirs[2].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[2].mode);

    try testing.expectEqualStrings("/test/mere/store/.incoming", dirs[3].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[3].mode);

    try testing.expectEqualStrings("/test/mere/dev", dirs[4].path);
    try testing.expectEqual(@as(u32, 0o755), dirs[4].mode);

    try testing.expectEqualStrings("/test/mere/dev/build", dirs[5].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[5].mode);

    try testing.expectEqualStrings("/test/mere/dev/outputs", dirs[6].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[6].mode);

    try testing.expectEqualStrings("/test/mere/dev/repo", dirs[7].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[7].mode);

    try testing.expectEqualStrings("/test/mere/dev/cache", dirs[8].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[8].mode);

    try testing.expectEqualStrings("/test/mere/dev/cache/sources", dirs[9].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[9].mode);

    try testing.expectEqualStrings("/test/mere/dev/cache/build", dirs[10].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[10].mode);

    try testing.expectEqualStrings("/test/mere/cache", dirs[11].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[11].mode);

    try testing.expectEqualStrings("/test/mere/cache/repos", dirs[12].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[12].mode);

    try testing.expectEqualStrings("/test/mere/cache/packages", dirs[13].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[13].mode);

    try testing.expectEqualStrings("/test/mere/profiles", dirs[14].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[14].mode);

    try testing.expectEqualStrings("/test/mere/profiles/system", dirs[15].path);
    try testing.expectEqual(@as(u32, 0o755), dirs[15].mode);

    try testing.expectEqualStrings("/test/mere/gc-roots", dirs[16].path);
    try testing.expectEqual(@as(u32, 0o755), dirs[16].mode);

    try testing.expectEqualStrings("/test/mere/gc-roots/profiles", dirs[17].path);
    try testing.expectEqual(@as(u32, 0o1777), dirs[2].mode);
    try testing.expectEqual(@as(u32, 0o755), dirs[17].mode);
}

test "isRoot checks uid correctly" {
    // Just verify the function works without error
    _ = isRoot();
}

test "InitResult initialization and cleanup" {
    const testing = std.testing;

    var result = InitResult.init(testing.allocator);
    defer result.deinit();

    try testing.expect(result.checks.items.len == 0);
    try testing.expect(result.changes_applied == 0);
    try testing.expect(result.issues_found == 0);
}

test "init mapInitFsError preserves actionable classes" {
    try std.testing.expectEqual(InitError.PermissionDenied, mapInitFsError(error.AccessDenied));
    try std.testing.expectEqual(InitError.OutOfMemory, mapInitFsError(error.OutOfMemory));
    try std.testing.expectEqual(InitError.InvalidInput, mapInitFsError(error.BadPathName));
    try std.testing.expectEqual(InitError.FileSystem, mapInitFsError(error.InputOutput));
}

test "init requiresRoot allows dry run without root" {
    try std.testing.expect(!requiresRoot(.{ .dry_run = true }));
    try std.testing.expect(requiresRoot(.{ .dry_run = false }));
}
