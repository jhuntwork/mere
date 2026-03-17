// Profile builder - creates symlink tree projections from packages
//
// This module implements profile realization and generation construction.
// specs #15 and #19. A profile is a symlink tree projection of store contents.
//
// Key properties:
// - File-level symlinks (directories are created, not symlinked)
// - Path conflicts are hard errors (no implicit resolution)
// - All symlinks are validated for boundary compliance
// - Profiles use nested layout: /mere/profiles/<name>/gen-N/

const std = @import("std");
const package_manifest = @import("manifest.zig");
const path_safety = @import("path_safety.zig");
const generation = @import("generation.zig");
const projection_index = @import("projection_index.zig");
const path = @import("path.zig");
const Context = @import("mere.zig").Context;
const errors = @import("errors.zig");

/// Profile builder error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during profile operations
/// - FileSystem: File/directory operations failed (creating dirs, symlinks, reading store)
/// - PermissionDenied: Insufficient permissions for profile directory or store access
/// - InvalidInput: Invalid profile path, store path, or empty inputs
///
/// Profile-Specific Errors:
/// - PathConflict: Two packages provide the same path with different targets
/// - StorePathNotFound: Package store path doesn't exist
/// - InvalidStoreLayout: Store path doesn't have valid projection metadata
/// - SymlinkEscapesBoundary: Symlink target escapes allowed boundary
const Std = errors.StandardErrors;
pub const ProfileError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    PathConflict,
    StorePathNotFound,
    InvalidStoreLayout,
    SymlinkEscapesBoundary,
};

pub const PathConflict = struct {
    path: []const u8,
    package_a: []const u8,
    package_b: []const u8,
    target_a: []const u8,
    target_b: []const u8,

    pub fn format(self: PathConflict, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "path conflict: '{s}' claimed by both '{s}' (-> {s}) and '{s}' (-> {s})",
            .{ self.path, self.package_a, self.target_a, self.package_b, self.target_b },
        );
    }
};

pub const PathConflictDetector = struct {
    allocator: std.mem.Allocator,
    conflicts: std.array_list.Managed(PathConflict),
    path_owners: std.StringHashMap(PathOwner),

    pub const RecordResult = enum {
        added,
        already_present,
        conflict,
    };

    const PathOwner = struct {
        package: []const u8,
        store_path: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) PathConflictDetector {
        return .{
            .allocator = allocator,
            .conflicts = std.array_list.Managed(PathConflict).init(allocator),
            .path_owners = std.StringHashMap(PathOwner).init(allocator),
        };
    }

    pub fn deinit(self: *PathConflictDetector) void {
        for (self.conflicts.items) |conflict| {
            self.allocator.free(conflict.path);
            self.allocator.free(conflict.package_a);
            self.allocator.free(conflict.package_b);
            self.allocator.free(conflict.target_a);
            self.allocator.free(conflict.target_b);
        }
        self.conflicts.deinit();

        var path_it = self.path_owners.iterator();
        while (path_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.path_owners.deinit();
    }

    pub fn recordPath(
        self: *PathConflictDetector,
        profile_path: []const u8,
        store_path: []const u8,
        package_name: []const u8,
    ) Std.OutOfMemory!RecordResult {
        if (self.path_owners.get(profile_path)) |existing| {
            if (std.mem.eql(u8, existing.store_path, store_path)) {
                return .already_present;
            }

            const target_a = std.fs.path.join(self.allocator, &.{ existing.store_path, profile_path }) catch {
                return error.OutOfMemory;
            };
            errdefer self.allocator.free(target_a);
            const target_b = std.fs.path.join(self.allocator, &.{ store_path, profile_path }) catch {
                return error.OutOfMemory;
            };
            errdefer self.allocator.free(target_b);

            try self.addConflict(.{
                .path = try self.allocator.dupe(u8, profile_path),
                .package_a = try self.allocator.dupe(u8, existing.package),
                .package_b = try self.allocator.dupe(u8, package_name),
                .target_a = target_a,
                .target_b = target_b,
            });
            return .conflict;
        }

        const key = self.allocator.dupe(u8, profile_path) catch return error.OutOfMemory;
        errdefer self.allocator.free(key);

        self.path_owners.put(key, .{ .package = package_name, .store_path = store_path }) catch {
            self.allocator.free(key);
            return error.OutOfMemory;
        };

        return .added;
    }

    pub fn recordConflict(
        self: *PathConflictDetector,
        profile_path: []const u8,
        package_a: []const u8,
        store_path_a: []const u8,
        package_b: []const u8,
        store_path_b: []const u8,
    ) Std.OutOfMemory!void {
        const target_a = std.fs.path.join(self.allocator, &.{ store_path_a, profile_path }) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(target_a);
        const target_b = std.fs.path.join(self.allocator, &.{ store_path_b, profile_path }) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(target_b);

        try self.addConflict(.{
            .path = try self.allocator.dupe(u8, profile_path),
            .package_a = try self.allocator.dupe(u8, package_a),
            .package_b = try self.allocator.dupe(u8, package_b),
            .target_a = target_a,
            .target_b = target_b,
        });
    }

    fn addConflict(self: *PathConflictDetector, conflict: PathConflict) Std.OutOfMemory!void {
        self.conflicts.append(conflict) catch return error.OutOfMemory;
    }

    pub fn hasConflicts(self: *const PathConflictDetector) bool {
        return self.conflicts.items.len > 0;
    }

    pub fn conflictCount(self: *const PathConflictDetector) usize {
        return self.conflicts.items.len;
    }

    pub fn getConflicts(self: *const PathConflictDetector) []const PathConflict {
        return self.conflicts.items;
    }

    pub fn formatAllConflicts(self: *const PathConflictDetector, allocator: std.mem.Allocator) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer result.deinit(allocator);
        const writer = result.writer(allocator);

        try writer.print("{d} path conflict(s) detected:\n", .{self.conflicts.items.len});

        for (self.conflicts.items, 0..) |conflict, i| {
            if (i > 0) {
                try writer.writeAll("\n");
            }
            try writer.writeAll("  - ");
            try writer.print(
                "path conflict: '{s}' claimed by both '{s}' (-> {s}) and '{s}' (-> {s})",
                .{ conflict.path, conflict.package_a, conflict.target_a, conflict.package_b, conflict.target_b },
            );
        }

        return try result.toOwnedSlice(allocator);
    }
};

pub const ProjectionResult = struct {
    stats: ProjectionStats,
    conflicts: PathConflictDetector,
    realization: generation.RealizationData,

    pub fn deinit(self: *ProjectionResult) void {
        self.conflicts.deinit();
        self.realization.deinit();
    }
};

pub const ProjectionStats = struct {
    total_entries: usize,
    materialized_entries: usize,
    reused_entries: usize,
    duration_ns: u64,
};

const ParentGenerationState = struct {
    allocator: std.mem.Allocator,
    generation_dir: []const u8,
    manifest: generation.GenerationManifest,
    realization: generation.RealizationData,
    path_lookup: std.StringHashMap(u32),

    fn init(
        allocator: std.mem.Allocator,
        generation_dir: []const u8,
        manifest_data: generation.GenerationManifest,
        realization_data: generation.RealizationData,
    ) !ParentGenerationState {
        var lookup = std.StringHashMap(u32).init(allocator);
        errdefer lookup.deinit();
        try lookup.ensureTotalCapacity(@intCast(realization_data.entries.items.len));
        for (realization_data.entries.items) |entry| {
            lookup.putAssumeCapacity(entry.path, entry.owner_package_index);
        }

        return .{
            .allocator = allocator,
            .generation_dir = generation_dir,
            .manifest = manifest_data,
            .realization = realization_data,
            .path_lookup = lookup,
        };
    }

    fn deinit(self: *ParentGenerationState) void {
        self.path_lookup.deinit();
        self.realization.deinit();
        self.manifest.deinit();
        self.allocator.free(self.generation_dir);
    }
};

fn readPackageProjection(
    allocator: std.mem.Allocator,
    ctx: *Context,
    store_path: []const u8,
) ProfileError!projection_index.Data {
    var store_dir = std.fs.openDirAbsolute(store_path, .{}) catch |err| {
        return ctx.fail(switch (err) {
            error.FileNotFound => ProfileError.StorePathNotFound,
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, store_path, "failed to open store path");
    };
    store_dir.close();

    return projection_index.readFile(allocator, store_path) catch |err| {
        return ctx.fail(switch (err) {
            projection_index.ProjectionError.OutOfMemory => ProfileError.OutOfMemory,
            projection_index.ProjectionError.PermissionDenied => ProfileError.PermissionDenied,
            projection_index.ProjectionError.InvalidInput => ProfileError.InvalidStoreLayout,
            projection_index.ProjectionError.FileSystem => ProfileError.FileSystem,
        }, store_path, "failed to read projection.v1");
    };
}

fn isSystemProfile(profile_dir: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(profile_dir), "system");
}

fn assertRootOwnedPackages(ctx: *Context, packages: []const generation.PackageEntry) ProfileError!void {
    for (packages) |pkg| {
        const store_path = pkg.store_path;
        const stat_buf = std.posix.fstatat(std.posix.AT.FDCWD, store_path, 0) catch |err| {
            return ctx.fail(switch (err) {
                error.FileNotFound => ProfileError.StorePathNotFound,
                error.AccessDenied => ProfileError.PermissionDenied,
                else => ProfileError.FileSystem,
            }, store_path, "failed to stat store path for ownership");
        };

        if (stat_buf.uid != 0 or stat_buf.gid != 0) {
            return ctx.fail(ProfileError.PermissionDenied, store_path, "store path is not root-owned");
        }
    }
}

pub fn buildProfile(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
) ProfileError!ProjectionResult {
    if (profile_root.len == 0 or store_root.len == 0) {
        return ProfileError.InvalidInput;
    }
    const started_at = std.time.nanoTimestamp();

    var result = try planProfileRealization(allocator, ctx, profile_root, store_root, packages, null);
    errdefer result.deinit();

    if (result.conflicts.hasConflicts()) {
        return result;
    }

    const apply_stats = try applyRealization(
        allocator,
        ctx,
        profile_root,
        packages,
        &result.realization,
        null,
    );
    result.stats.materialized_entries = apply_stats.materialized_entries;
    result.stats.reused_entries = apply_stats.reused_entries;
    result.stats.duration_ns = @intCast(std.time.nanoTimestamp() - started_at);
    return result;
}

fn planProfileRealization(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
    parent_state: ?*const ParentGenerationState,
) ProfileError!ProjectionResult {
    var detector = PathConflictDetector.init(allocator);
    errdefer detector.deinit();
    var realization = generation.RealizationData.init(allocator);
    errdefer realization.deinit();

    if (parent_state) |parent| {
        try planProfileRealizationFromParent(
            allocator,
            ctx,
            profile_root,
            store_root,
            packages,
            parent,
            &detector,
            &realization,
        );
    } else {
        for (packages, 0..) |pkg, pkg_index| {
            try addPackageProjectionToRealization(
                allocator,
                ctx,
                profile_root,
                store_root,
                pkg.store_path,
                pkg.name,
                &detector,
                &realization,
                @intCast(pkg_index),
            );
        }
    }

    realization.canonicalize() catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.InvalidManifest => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, profile_root, "failed to finalize profile realization");
    };

    return .{
        .stats = .{
            .total_entries = realization.entries.items.len,
            .materialized_entries = 0,
            .reused_entries = 0,
            .duration_ns = 0,
        },
        .conflicts = detector,
        .realization = realization,
    };
}

fn planProfileRealizationFromParent(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
    parent_state: *const ParentGenerationState,
    detector: *PathConflictDetector,
    realization: *generation.RealizationData,
) ProfileError!void {
    var new_package_by_store_path = std.StringHashMap(u32).init(allocator);
    defer new_package_by_store_path.deinit();
    try new_package_by_store_path.ensureTotalCapacity(@intCast(packages.len));

    for (packages, 0..) |pkg, pkg_index| {
        new_package_by_store_path.putAssumeCapacity(pkg.store_path, @intCast(pkg_index));
    }

    var retained_parent_owners = std.AutoHashMap(u32, u32).init(allocator);
    defer retained_parent_owners.deinit();
    try retained_parent_owners.ensureTotalCapacity(@intCast(parent_state.manifest.packages.items.len));
    var retained_store_paths = std.StringHashMap(void).init(allocator);
    defer retained_store_paths.deinit();
    try retained_store_paths.ensureTotalCapacity(@intCast(parent_state.manifest.packages.items.len));

    for (parent_state.manifest.packages.items, 0..) |pkg, pkg_index| {
        if (new_package_by_store_path.get(pkg.store_path)) |new_owner_index| {
            retained_parent_owners.putAssumeCapacity(@intCast(pkg_index), new_owner_index);
            retained_store_paths.putAssumeCapacity(pkg.store_path, {});
        }
    }

    for (parent_state.realization.entries.items) |entry| {
        const new_owner_index = retained_parent_owners.get(entry.owner_package_index) orelse continue;
        try seedRetainedRealizationEntry(
            ctx,
            entry.path,
            realization,
            new_owner_index,
        );
    }

    for (packages, 0..) |pkg, pkg_index| {
        if (retained_store_paths.contains(pkg.store_path)) continue;

        try addDeltaPackageProjectionToRealization(
            allocator,
            ctx,
            profile_root,
            store_root,
            packages,
            parent_state,
            &retained_parent_owners,
            pkg.store_path,
            pkg.name,
            detector,
            realization,
            @intCast(pkg_index),
        );
    }
}

fn seedRetainedRealizationEntry(
    ctx: *Context,
    projected_path: []const u8,
    realization: *generation.RealizationData,
    owner_package_index: u32,
) ProfileError!void {
    realization.addEntry(projected_path, owner_package_index) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.InvalidManifest => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, projected_path, "failed to seed retained generation realization");
    };
}

fn addDeltaPackageProjectionToRealization(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
    parent_state: *const ParentGenerationState,
    retained_parent_owners: *const std.AutoHashMap(u32, u32),
    store_path: []const u8,
    pkg_name: []const u8,
    detector: *PathConflictDetector,
    realization: *generation.RealizationData,
    owner_package_index: u32,
) ProfileError!void {
    if (!path_safety.isWithinBoundary(store_path, store_root)) {
        return ctx.fail(ProfileError.InvalidInput, store_path, "store path outside store root");
    }

    var projection = try readPackageProjection(allocator, ctx, store_path);
    defer projection.deinit();

    for (projection.paths.items) |projected_path| {
        if (lookupRetainedPathOwner(parent_state, retained_parent_owners, projected_path)) |retained_owner_index| {
            const retained_pkg = packages[retained_owner_index];
            detector.recordConflict(projected_path, retained_pkg.name, retained_pkg.store_path, pkg_name, store_path) catch {
                return ctx.fail(ProfileError.OutOfMemory, projected_path, "failed to record retained path conflict");
            };
            continue;
        }

        try addRealizationEntry(
            allocator,
            ctx,
            profile_root,
            store_root,
            store_path,
            pkg_name,
            projected_path,
            detector,
            realization,
            owner_package_index,
        );
    }
}

fn lookupRetainedPathOwner(
    parent_state: *const ParentGenerationState,
    retained_parent_owners: *const std.AutoHashMap(u32, u32),
    projected_path: []const u8,
) ?u32 {
    const parent_owner_index = parent_state.path_lookup.get(projected_path) orelse return null;
    return retained_parent_owners.get(parent_owner_index);
}

/// Add a single package's projection to the in-memory realization plan.
fn addPackageProjectionToRealization(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    store_path: []const u8,
    pkg_name: []const u8,
    detector: *PathConflictDetector,
    realization: *generation.RealizationData,
    owner_package_index: u32,
) ProfileError!void {
    if (!path_safety.isWithinBoundary(store_path, store_root)) {
        return ctx.fail(ProfileError.InvalidInput, store_path, "store path outside store root");
    }

    var projection = try readPackageProjection(allocator, ctx, store_path);
    defer projection.deinit();

    for (projection.paths.items) |projected_path| {
        try addRealizationEntry(
            allocator,
            ctx,
            profile_root,
            store_root,
            store_path,
            pkg_name,
            projected_path,
            detector,
            realization,
            owner_package_index,
        );
    }
}

fn addRealizationEntry(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    store_path: []const u8,
    pkg_name: []const u8,
    projected_path: []const u8,
    detector: *PathConflictDetector,
    realization: *generation.RealizationData,
    owner_package_index: u32,
) ProfileError!void {
    const record_result = detector.recordPath(projected_path, store_path, pkg_name) catch {
        return ctx.fail(ProfileError.OutOfMemory, projected_path, "failed to record path for conflict detection");
    };
    switch (record_result) {
        .already_present => return,
        .conflict => return,
        .added => {},
    }

    const profile_path = std.fs.path.join(allocator, &.{ profile_root, projected_path }) catch {
        return ctx.fail(ProfileError.OutOfMemory, profile_root, "failed to construct profile path");
    };
    defer allocator.free(profile_path);

    const store_target = std.fs.path.join(allocator, &.{ store_path, projected_path }) catch {
        return ctx.fail(ProfileError.OutOfMemory, store_path, "failed to construct store target path");
    };
    defer allocator.free(store_target);

    path_safety.validateProfileSymlink(
        profile_path,
        store_target,
        profile_root,
        store_root,
    ) catch {
        return ctx.fail(ProfileError.SymlinkEscapesBoundary, profile_path, "symlink escapes boundary");
    };

    realization.addEntry(projected_path, owner_package_index) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.InvalidManifest => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, projected_path, "failed to record generation realization");
    };
}

fn applyRealization(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    packages: []const generation.PackageEntry,
    realization: *const generation.RealizationData,
    parent_state: ?*const ParentGenerationState,
) ProfileError!ProjectionStats {
    var materialized_entries: usize = 0;
    var reused_entries: usize = 0;
    var last_parent = std.ArrayList(u8){};
    defer last_parent.deinit(allocator);

    for (realization.entries.items) |entry| {
        if (entry.owner_package_index >= packages.len) {
            return ctx.fail(ProfileError.InvalidInput, profile_root, "realization owner index out of bounds");
        }
        const pkg = packages[entry.owner_package_index];

        const profile_path = std.fs.path.join(allocator, &.{ profile_root, entry.path }) catch {
            return ctx.fail(ProfileError.OutOfMemory, profile_root, "failed to construct profile path");
        };
        defer allocator.free(profile_path);

        const parent = std.fs.path.dirname(profile_path) orelse profile_root;
        try ensureProfileParent(ctx, parent, &last_parent);

        if (parent_state) |parent_gen| {
            if (parent_gen.path_lookup.get(entry.path)) |parent_owner_index| {
                if (parent_owner_index < parent_gen.manifest.packages.items.len) {
                    const parent_pkg = parent_gen.manifest.packages.items[parent_owner_index];
                    if (std.mem.eql(u8, parent_pkg.store_path, pkg.store_path)) {
                        const source_path = std.fs.path.join(allocator, &.{ parent_gen.generation_dir, entry.path }) catch {
                            return ctx.fail(ProfileError.OutOfMemory, parent_gen.generation_dir, "failed to construct parent generation path");
                        };
                        defer allocator.free(source_path);

                        try linkExistingEntry(ctx, source_path, profile_path);
                        reused_entries += 1;
                        continue;
                    }
                }
            }
        }

        const store_target = std.fs.path.join(allocator, &.{ pkg.store_path, entry.path }) catch {
            return ctx.fail(ProfileError.OutOfMemory, pkg.store_path, "failed to construct store target path");
        };
        defer allocator.free(store_target);

        try replaceSymlinkAtomically(allocator, ctx, profile_path, store_target);
        materialized_entries += 1;
    }

    return .{
        .total_entries = realization.entries.items.len,
        .materialized_entries = materialized_entries,
        .reused_entries = reused_entries,
        .duration_ns = 0,
    };
}

fn ensureProfileParent(
    ctx: *Context,
    parent: []const u8,
    last_parent: *std.ArrayList(u8),
) ProfileError!void {
    if (std.mem.eql(u8, last_parent.items, parent)) return;

    std.fs.cwd().makePath(parent) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, parent, "failed to create parent directory");
    };

    last_parent.clearRetainingCapacity();
    last_parent.appendSlice(ctx.allocator, parent) catch {
        return ctx.fail(ProfileError.OutOfMemory, parent, "failed to cache realized parent directory");
    };
}

fn linkExistingEntry(ctx: *Context, source_path: []const u8, dest_path: []const u8) ProfileError!void {
    std.fs.deleteFileAbsolute(dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.AccessDenied => return ctx.fail(ProfileError.PermissionDenied, dest_path, "failed to remove existing destination before reuse"),
        else => return ctx.fail(ProfileError.FileSystem, dest_path, "failed to remove existing destination before reuse"),
    };

    std.posix.link(source_path, dest_path) catch |err| {
        return ctx.fail(switch (err) {
            error.FileNotFound => ProfileError.FileSystem,
            error.AccessDenied, error.PermissionDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, dest_path, "failed to reuse parent generation entry");
    };
}

fn replaceSymlinkAtomically(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_path: []const u8,
    store_target: []const u8,
) ProfileError!void {
    const parent = std.fs.path.dirname(profile_path) orelse "/";
    const basename = std.fs.path.basename(profile_path);

    var parent_dir = std.fs.openDirAbsolute(parent, .{}) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, parent, "failed to open parent directory for symlink replacement");
    };
    defer parent_dir.close();

    var random_bytes: [6]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);

    const tmp_name = std.fmt.allocPrint(allocator, ".{s}.tmp-{s}", .{ basename, suffix }) catch {
        return ctx.fail(ProfileError.OutOfMemory, profile_path, "failed to allocate temp symlink name");
    };
    defer allocator.free(tmp_name);

    parent_dir.symLink(store_target, tmp_name, .{}) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, profile_path, "failed to create temporary symlink");
    };
    errdefer parent_dir.deleteFile(tmp_name) catch {};

    parent_dir.rename(tmp_name, basename) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, profile_path, "failed to atomically replace symlink");
    };
}

fn loadParentGenerationState(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_dir: []const u8,
    parent_generation: u32,
) ProfileError!ParentGenerationState {
    const parent_dir = generation.getGenerationPath(allocator, profile_dir, parent_generation) catch {
        return ctx.fail(ProfileError.OutOfMemory, profile_dir, "failed to construct parent generation path");
    };
    errdefer allocator.free(parent_dir);

    var manifest_data = generation.readManifest(allocator, parent_dir) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.GenerationNotFound => ProfileError.FileSystem,
            generation.GenerationError.InvalidManifest, generation.GenerationError.ParseError => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, parent_dir, "failed to read parent generation manifest");
    };
    errdefer manifest_data.deinit();

    var realization_data = generation.readRealization(allocator, parent_dir) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.InvalidManifest, generation.GenerationError.ParseError => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, parent_dir, "failed to read parent generation realization");
    };
    errdefer realization_data.deinit();

    return ParentGenerationState.init(allocator, parent_dir, manifest_data, realization_data) catch {
        return ctx.fail(ProfileError.OutOfMemory, parent_dir, "failed to build parent generation lookup");
    };
}

pub fn createGeneration(
    ctx: *Context,
    profile_dir: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
    parent_generation: ?u32,
) ProfileError!u32 {
    const started_at = std.time.nanoTimestamp();
    const gen_num = generation.getNextGenerationNumber(profile_dir) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.ProfilesNotFound => ProfileError.FileSystem,
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            else => ProfileError.FileSystem,
        }, profile_dir, "failed to scan profile directory for generations");
    };

    const gen_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch {
        return ProfileError.OutOfMemory;
    };
    defer ctx.allocator.free(gen_path);

    std.fs.cwd().makePath(gen_path) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, gen_path, "failed to create generation directory");
    };

    if (isSystemProfile(profile_dir)) {
        try assertRootOwnedPackages(ctx, packages);
    }

    var parent_state = if (parent_generation) |parent_num|
        try loadParentGenerationState(ctx.allocator, ctx, profile_dir, parent_num)
    else
        null;
    defer if (parent_state) |*state| state.deinit();

    var result = try planProfileRealization(
        ctx.allocator,
        ctx,
        gen_path,
        store_root,
        packages,
        if (parent_state) |*state| state else null,
    );
    defer result.deinit();

    if (result.conflicts.hasConflicts()) {
        return ProfileError.PathConflict;
    }

    const apply_stats = try applyRealization(
        ctx.allocator,
        ctx,
        gen_path,
        packages,
        &result.realization,
        if (parent_state) |*state| state else null,
    );
    result.stats.materialized_entries = apply_stats.materialized_entries;
    result.stats.reused_entries = apply_stats.reused_entries;
    result.stats.duration_ns = @intCast(std.time.nanoTimestamp() - started_at);

    var manifest = generation.GenerationManifest.init(ctx.allocator, gen_num);
    defer manifest.deinit();

    manifest.parent_generation = parent_generation;

    for (packages) |pkg| {
        manifest.addPackage(
            pkg.name,
            pkg.version,
            pkg.release,
            pkg.arch,
            pkg.store_path,
            pkg.content_hash,
        ) catch {
            return ProfileError.OutOfMemory;
        };
    }

    generation.writeRealization(ctx.allocator, gen_path, &result.realization) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.InvalidManifest => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, gen_path, "failed to write generation realization");
    };

    generation.writeManifest(ctx.allocator, gen_path, &manifest) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            else => ProfileError.FileSystem,
        }, gen_path, "failed to write generation manifest");
    };

    ctx.debug(
        "generation {d} built: entries={d} materialized={d} reused={d} duration_ms={d}",
        .{
            gen_num,
            result.stats.total_entries,
            result.stats.materialized_entries,
            result.stats.reused_entries,
            @divFloor(result.stats.duration_ns, std.time.ns_per_ms),
        },
    );

    return gen_num;
}

pub fn createProfile(
    ctx: *Context,
    profiles_dir: []const u8,
    profile_name: []const u8,
) ProfileError![]const u8 {
    const profile_dir = generation.getProfilePath(ctx.allocator, profiles_dir, profile_name) catch {
        return ProfileError.OutOfMemory;
    };
    errdefer ctx.allocator.free(profile_dir);

    std.fs.cwd().makePath(profile_dir) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, profile_dir, "failed to create profile directory");
    };

    return profile_dir;
}

fn testPackageEntry(name: []const u8, store_path: []const u8) generation.PackageEntry {
    return .{
        .name = name,
        .version = "1.0",
        .release = 1,
        .arch = "x86_64",
        .store_path = store_path,
        .content_hash = "test-hash",
    };
}

fn writeProjectionForTestPackage(allocator: std.mem.Allocator, store_path: []const u8) !void {
    var projection = try projection_index.deriveFromPayload(allocator, store_path);
    defer projection.deinit();
    try projection_index.writeFile(allocator, store_path, &projection);
}

// Tests

// Spec #19: Profile build creates symlink tree projection from store paths
test "buildProfile creates symlinks for package files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc-test-1.0" });
    defer allocator.free(pkg_path);

    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    // Create a file in the package
    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "hello" });
    defer allocator.free(file_path);
    {
        var f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("#!/bin/sh\necho hello\n");
        f.close();
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    // Build profile
    var result = try buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("hello", pkg_path)});
    defer result.deinit();

    try std.testing.expect(!result.conflicts.hasConflicts());
    try std.testing.expectEqual(@as(usize, 1), result.stats.total_entries);
    try std.testing.expectEqual(@as(usize, 1), result.stats.materialized_entries);
    try std.testing.expectEqual(@as(usize, 0), result.stats.reused_entries);

    // Verify symlink was created
    const expected_link = try std.fs.path.join(allocator, &.{ profile_root, "bin", "hello" });
    defer allocator.free(expected_link);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.readLinkAbsolute(expected_link, &buf);
    try std.testing.expectEqualStrings(file_path, target);
}

// Spec #19: Path conflicts during profile build are hard errors
test "buildProfile detects path conflicts" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store structure with two packages having conflicting paths
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg1_path = try std.fs.path.join(allocator, &.{ store_root, "pkg1-1.0" });
    defer allocator.free(pkg1_path);
    const pkg1_bin = try std.fs.path.join(allocator, &.{ pkg1_path, "bin" });
    defer allocator.free(pkg1_bin);
    try std.fs.cwd().makePath(pkg1_bin);

    const pkg2_path = try std.fs.path.join(allocator, &.{ store_root, "pkg2-1.0" });
    defer allocator.free(pkg2_path);
    const pkg2_bin = try std.fs.path.join(allocator, &.{ pkg2_path, "bin" });
    defer allocator.free(pkg2_bin);
    try std.fs.cwd().makePath(pkg2_bin);

    // Both packages provide bin/foo
    const file1 = try std.fs.path.join(allocator, &.{ pkg1_bin, "foo" });
    defer allocator.free(file1);
    {
        var f = try std.fs.createFileAbsolute(file1, .{});
        try f.writeAll("pkg1");
        f.close();
    }

    const file2 = try std.fs.path.join(allocator, &.{ pkg2_bin, "foo" });
    defer allocator.free(file2);
    {
        var f = try std.fs.createFileAbsolute(file2, .{});
        try f.writeAll("pkg2");
        f.close();
    }

    try writeProjectionForTestPackage(allocator, pkg1_path);
    try writeProjectionForTestPackage(allocator, pkg2_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    // Build profile - should succeed but report conflicts
    var result = try buildProfile(
        allocator,
        &test_env.ctx,
        profile_root,
        store_root,
        &.{ testPackageEntry("pkg1", pkg1_path), testPackageEntry("pkg2", pkg2_path) },
    );
    defer result.deinit();

    // Should have detected a conflict
    try std.testing.expect(result.conflicts.hasConflicts());
    try std.testing.expectEqual(@as(usize, 1), result.conflicts.conflictCount());

    // Verify conflict details
    const conflicts = result.conflicts.getConflicts();
    try std.testing.expect(std.mem.endsWith(u8, conflicts[0].path, "bin/foo"));
}

// Spec #19: package metadata files are excluded from profile projection
test "buildProfile skips package metadata files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc-test-1.0" });
    defer allocator.free(pkg_path);
    try std.fs.cwd().makePath(pkg_path);

    // Create manifest files under .mere/ (should be skipped)
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_path, package_manifest.MANIFEST_FILENAME });
    defer allocator.free(manifest_path);
    {
        try std.fs.cwd().makePath(std.fs.path.dirname(manifest_path).?);
        var f = try std.fs.createFileAbsolute(manifest_path, .{});
        try f.writeAll("manifest");
        f.close();
    }

    const sig_path = try std.fs.path.join(allocator, &.{ pkg_path, package_manifest.MANIFEST_SIG_FILENAME });
    defer allocator.free(sig_path);
    {
        var f = try std.fs.createFileAbsolute(sig_path, .{});
        try f.writeAll("sig");
        f.close();
    }

    const meta_path = try std.fs.path.join(allocator, &.{ pkg_path, package_manifest.META_KDL_FILENAME });
    defer allocator.free(meta_path);
    {
        try std.fs.cwd().makePath(std.fs.path.dirname(meta_path).?);
        var f = try std.fs.createFileAbsolute(meta_path, .{});
        try f.writeAll("metadata");
        f.close();
    }

    // Create a regular file that should be included
    const bin_path = try std.fs.path.join(allocator, &.{ pkg_path, "bin", "tool" });
    defer allocator.free(bin_path);
    {
        const parent = std.fs.path.dirname(bin_path) orelse pkg_path;
        try std.fs.cwd().makePath(parent);
        var f = try std.fs.createFileAbsolute(bin_path, .{});
        try f.writeAll("tool");
        f.close();
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    // Build profile
    var result = try buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("test", pkg_path)});
    defer result.deinit();

    // Only the regular file should be included
    try std.testing.expect(!result.conflicts.hasConflicts());
    try std.testing.expectEqual(@as(usize, 1), result.stats.total_entries);
    try std.testing.expectEqual(@as(usize, 1), result.stats.materialized_entries);
    try std.testing.expectEqual(@as(usize, 0), result.stats.reused_entries);

    // Verify .mere metadata was not linked
    const manifest_link = try std.fs.path.join(allocator, &.{ profile_root, package_manifest.MANIFEST_FILENAME });
    defer allocator.free(manifest_link);
    try std.testing.expect(!path.fileExists(manifest_link));

    // Verify .mere was not linked
    const mere_link = try std.fs.path.join(allocator, &.{ profile_root, ".mere" });
    defer allocator.free(mere_link);
    // Check directory doesn't exist
    const maybe_dir = std.fs.openDirAbsolute(mere_link, .{});
    if (maybe_dir) |dir| {
        @constCast(&dir).close();
        try std.testing.expect(false); // Should not exist
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
}

test "createGeneration creates full generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc123-test-1.0" });
    defer allocator.free(pkg_path);

    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "test" });
    defer allocator.free(file_path);
    {
        var f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("test");
        f.close();
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory (new layout: profiles/<name>/)
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create package entry
    const packages = [_]generation.PackageEntry{
        .{
            .name = "test",
            .version = "1.0",
            .release = 1,
            .arch = "x86_64",
            .store_path = pkg_path,
            .content_hash = "abc123def456789012345678901234567890123456789012345678901234",
        },
    };

    // Create generation (now takes profile_dir, not profiles_dir)
    const gen_num = try createGeneration(&test_env.ctx, profile_dir, store_root, &packages, null);

    try std.testing.expectEqual(@as(u32, 1), gen_num);

    // Verify generation directory exists (new layout: profile_dir/gen-N)
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ gen_path, "manifest.json" });
    defer allocator.free(manifest_path);
    try std.testing.expect(path.fileExists(manifest_path));
    const realization_path = try std.fs.path.join(allocator, &.{ gen_path, generation.REALIZATION_FILENAME });
    defer allocator.free(realization_path);
    try std.testing.expect(path.fileExists(realization_path));

    // Verify symlink was created
    const link_path = try std.fs.path.join(allocator, &.{ gen_path, "bin", "test" });
    defer allocator.free(link_path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.readLinkAbsolute(link_path, &buf);
    try std.testing.expectEqualStrings(file_path, target);

    // Verify manifest was written
    var manifest = try generation.readManifest(allocator, gen_path);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(u32, 1), manifest.generation);
    try std.testing.expectEqual(@as(usize, 1), manifest.packages.items.len);
    try std.testing.expectEqualStrings("test", manifest.packages.items[0].name);

    var realization = try generation.readRealization(allocator, gen_path);
    defer realization.deinit();
    try std.testing.expectEqual(@as(usize, 1), realization.entries.items.len);
    try std.testing.expectEqualStrings("bin/test", realization.entries.items[0].path);
    try std.testing.expectEqual(@as(u32, 0), realization.entries.items[0].owner_package_index);
}

test "createGeneration reuses unchanged entries from parent generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);
    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc123-test-1.0" });
    defer allocator.free(pkg_path);
    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "test" });
    defer allocator.free(file_path);
    {
        var f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("test");
    }
    try writeProjectionForTestPackage(allocator, pkg_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const packages = [_]generation.PackageEntry{testPackageEntry("test", pkg_path)};

    const gen1 = try createGeneration(&test_env.ctx, profile_dir, store_root, &packages, null);
    try std.testing.expectEqual(@as(u32, 1), gen1);
    const gen2 = try createGeneration(&test_env.ctx, profile_dir, store_root, &packages, 1);
    try std.testing.expectEqual(@as(u32, 2), gen2);

    const gen1_link = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1", "bin", "test" });
    defer allocator.free(gen1_link);
    const gen2_link = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2", "bin", "test" });
    defer allocator.free(gen2_link);

    const stat1 = try std.posix.fstatat(std.posix.AT.FDCWD, gen1_link, std.posix.AT.SYMLINK_NOFOLLOW);
    const stat2 = try std.posix.fstatat(std.posix.AT.FDCWD, gen2_link, std.posix.AT.SYMLINK_NOFOLLOW);
    try std.testing.expectEqual(stat1.ino, stat2.ino);
}

test "createGeneration does not reread projection.v1 for unchanged parent package" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_a_path = try std.fs.path.join(allocator, &.{ store_root, "pkg-a-1.0" });
    defer allocator.free(pkg_a_path);
    const pkg_a_bin = try std.fs.path.join(allocator, &.{ pkg_a_path, "bin" });
    defer allocator.free(pkg_a_bin);
    try std.fs.cwd().makePath(pkg_a_bin);
    const pkg_a_file = try std.fs.path.join(allocator, &.{ pkg_a_bin, "a" });
    defer allocator.free(pkg_a_file);
    {
        var f = try std.fs.createFileAbsolute(pkg_a_file, .{});
        defer f.close();
        try f.writeAll("a");
    }
    try writeProjectionForTestPackage(allocator, pkg_a_path);

    const pkg_b_path = try std.fs.path.join(allocator, &.{ store_root, "pkg-b-1.0" });
    defer allocator.free(pkg_b_path);
    const pkg_b_bin = try std.fs.path.join(allocator, &.{ pkg_b_path, "bin" });
    defer allocator.free(pkg_b_bin);
    try std.fs.cwd().makePath(pkg_b_bin);
    const pkg_b_file = try std.fs.path.join(allocator, &.{ pkg_b_bin, "b" });
    defer allocator.free(pkg_b_file);
    {
        var f = try std.fs.createFileAbsolute(pkg_b_file, .{});
        defer f.close();
        try f.writeAll("b");
    }
    try writeProjectionForTestPackage(allocator, pkg_b_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gen1_packages = [_]generation.PackageEntry{
        testPackageEntry("pkg-a", pkg_a_path),
    };
    const gen1 = try createGeneration(&test_env.ctx, profile_dir, store_root, &gen1_packages, null);
    try std.testing.expectEqual(@as(u32, 1), gen1);

    const projection_path = try std.fs.path.join(allocator, &.{ pkg_a_path, package_manifest.PROJECTION_FILENAME });
    defer allocator.free(projection_path);
    try std.fs.deleteFileAbsolute(projection_path);

    const gen2_packages = [_]generation.PackageEntry{
        testPackageEntry("pkg-a", pkg_a_path),
        testPackageEntry("pkg-b", pkg_b_path),
    };
    const gen2 = try createGeneration(&test_env.ctx, profile_dir, store_root, &gen2_packages, 1);
    try std.testing.expectEqual(@as(u32, 2), gen2);

    const gen2_a_link = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2", "bin", "a" });
    defer allocator.free(gen2_a_link);
    const gen2_b_link = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2", "bin", "b" });
    defer allocator.free(gen2_b_link);

    try std.testing.expect(path.fileExists(gen2_a_link));
    try std.testing.expect(path.fileExists(gen2_b_link));
}

test "createGeneration detects conflicts against retained parent paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_a_path = try std.fs.path.join(allocator, &.{ store_root, "pkg-a-1.0" });
    defer allocator.free(pkg_a_path);
    const pkg_a_bin = try std.fs.path.join(allocator, &.{ pkg_a_path, "bin" });
    defer allocator.free(pkg_a_bin);
    try std.fs.cwd().makePath(pkg_a_bin);
    const pkg_a_file = try std.fs.path.join(allocator, &.{ pkg_a_bin, "tool" });
    defer allocator.free(pkg_a_file);
    {
        var f = try std.fs.createFileAbsolute(pkg_a_file, .{});
        defer f.close();
        try f.writeAll("a");
    }
    try writeProjectionForTestPackage(allocator, pkg_a_path);

    const pkg_b_path = try std.fs.path.join(allocator, &.{ store_root, "pkg-b-1.0" });
    defer allocator.free(pkg_b_path);
    const pkg_b_bin = try std.fs.path.join(allocator, &.{ pkg_b_path, "bin" });
    defer allocator.free(pkg_b_bin);
    try std.fs.cwd().makePath(pkg_b_bin);
    const pkg_b_file = try std.fs.path.join(allocator, &.{ pkg_b_bin, "tool" });
    defer allocator.free(pkg_b_file);
    {
        var f = try std.fs.createFileAbsolute(pkg_b_file, .{});
        defer f.close();
        try f.writeAll("b");
    }
    try writeProjectionForTestPackage(allocator, pkg_b_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    const gen1_packages = [_]generation.PackageEntry{
        testPackageEntry("pkg-a", pkg_a_path),
    };
    const gen1 = try createGeneration(&test_env.ctx, profile_dir, store_root, &gen1_packages, null);
    try std.testing.expectEqual(@as(u32, 1), gen1);

    const gen2_packages = [_]generation.PackageEntry{
        testPackageEntry("pkg-a", pkg_a_path),
        testPackageEntry("pkg-b", pkg_b_path),
    };
    try std.testing.expectError(
        ProfileError.PathConflict,
        createGeneration(&test_env.ctx, profile_dir, store_root, &gen2_packages, 1),
    );
}

test "createProfile creates profile directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create base profiles directory
    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    // Create a profile
    const profile_dir = try createProfile(&test_env.ctx, profiles_dir, "dev");
    defer allocator.free(profile_dir);

    // Verify it was created by opening it
    var dir = try std.fs.openDirAbsolute(profile_dir, .{});
    dir.close();

    // Verify path is correct
    const expected = try std.fs.path.join(allocator, &.{ profiles_dir, "dev" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, profile_dir);
}

// Spec #19.2: etc/ paths excluded from profile realization
test "buildProfile skips etc/ paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc-test-1.0" });
    defer allocator.free(pkg_path);
    try std.fs.cwd().makePath(pkg_path);

    // Create etc/ directory with a config file (should be skipped)
    const etc_dir = try std.fs.path.join(allocator, &.{ pkg_path, "etc" });
    defer allocator.free(etc_dir);
    try std.fs.cwd().makePath(etc_dir);

    const etc_file = try std.fs.path.join(allocator, &.{ etc_dir, "config.conf" });
    defer allocator.free(etc_file);
    {
        var f = try std.fs.createFileAbsolute(etc_file, .{});
        try f.writeAll("config");
        f.close();
    }

    // Create etc-defaults/ directory with a template (should be included)
    const etc_defaults_dir = try std.fs.path.join(allocator, &.{ pkg_path, "etc-defaults" });
    defer allocator.free(etc_defaults_dir);
    try std.fs.cwd().makePath(etc_defaults_dir);

    const etc_defaults_file = try std.fs.path.join(allocator, &.{ etc_defaults_dir, "template.conf" });
    defer allocator.free(etc_defaults_file);
    {
        var f = try std.fs.createFileAbsolute(etc_defaults_file, .{});
        try f.writeAll("template");
        f.close();
    }

    // Create a regular file that should be included
    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const bin_file = try std.fs.path.join(allocator, &.{ bin_dir, "tool" });
    defer allocator.free(bin_file);
    {
        var f = try std.fs.createFileAbsolute(bin_file, .{});
        try f.writeAll("tool");
        f.close();
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    // Build profile
    var result = try buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("test", pkg_path)});
    defer result.deinit();

    // Should have 2 symlinks: bin/tool and etc-defaults/template.conf
    try std.testing.expect(!result.conflicts.hasConflicts());
    try std.testing.expectEqual(@as(usize, 2), result.stats.total_entries);
    try std.testing.expectEqual(@as(usize, 2), result.stats.materialized_entries);
    try std.testing.expectEqual(@as(usize, 0), result.stats.reused_entries);

    // Verify etc/config.conf was NOT linked
    const etc_link = try std.fs.path.join(allocator, &.{ profile_root, "etc", "config.conf" });
    defer allocator.free(etc_link);
    try std.testing.expect(!path.fileExists(etc_link));

    // Verify etc-defaults/template.conf WAS linked
    const etc_defaults_link = try std.fs.path.join(allocator, &.{ profile_root, "etc-defaults", "template.conf" });
    defer allocator.free(etc_defaults_link);
    try std.testing.expect(path.fileExists(etc_defaults_link));

    // Verify bin/tool WAS linked
    const bin_link = try std.fs.path.join(allocator, &.{ profile_root, "bin", "tool" });
    defer allocator.free(bin_link);
    try std.testing.expect(path.fileExists(bin_link));
}

test "buildProfile rejects packages missing projection.v1" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create store structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);

    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc-badpkg-1.0" });
    defer allocator.free(pkg_path);
    try std.fs.cwd().makePath(pkg_path);

    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const tool_path = try std.fs.path.join(allocator, &.{ bin_dir, "tool" });
    defer allocator.free(tool_path);
    {
        var f = try std.fs.createFileAbsolute(tool_path, .{});
        try f.writeAll("tool");
        f.close();
    }

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    const result = buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("badpkg", pkg_path)});
    try std.testing.expectError(ProfileError.InvalidStoreLayout, result);
}

test "buildProfile preserves existing symlink when atomic replacement cannot start" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_root);
    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc-test-1.0" });
    defer allocator.free(pkg_path);
    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "tool" });
    defer allocator.free(file_path);
    {
        var f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("tool");
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-atomic" });
    defer allocator.free(profile_root);
    const profile_bin = try std.fs.path.join(allocator, &.{ profile_root, "bin" });
    defer allocator.free(profile_bin);
    try std.fs.cwd().makePath(profile_bin);

    const link_path = try std.fs.path.join(allocator, &.{ profile_bin, "tool" });
    defer allocator.free(link_path);
    try std.posix.symlinkat("/existing/target", std.fs.cwd().fd, link_path);

    // Deny write in parent dir to force temp-symlink creation failure.
    var profile_bin_dir = try std.fs.openDirAbsolute(profile_bin, .{});
    defer profile_bin_dir.close();
    try profile_bin_dir.chmod(0o555);
    defer profile_bin_dir.chmod(0o755) catch {};

    const result = buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("test", pkg_path)});
    try std.testing.expectError(ProfileError.PermissionDenied, result);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.readLinkAbsolute(link_path, &buf);
    try std.testing.expectEqualStrings("/existing/target", target);
}

test "PathConflictDetector detects conflicts" {
    const allocator = std.testing.allocator;

    var detector = PathConflictDetector.init(allocator);
    defer detector.deinit();

    const result1 = try detector.recordPath("usr/bin/foo", "/store/pkg1", "pkg1");
    try std.testing.expectEqual(PathConflictDetector.RecordResult.added, result1);

    const result2 = try detector.recordPath("usr/bin/foo", "/store/pkg1", "pkg1");
    try std.testing.expectEqual(PathConflictDetector.RecordResult.already_present, result2);

    const result3 = try detector.recordPath("usr/bin/foo", "/store/pkg2", "pkg2");
    try std.testing.expectEqual(PathConflictDetector.RecordResult.conflict, result3);

    try std.testing.expect(detector.hasConflicts());
    try std.testing.expectEqual(@as(usize, 1), detector.conflictCount());

    const conflicts = detector.getConflicts();
    try std.testing.expectEqualStrings("usr/bin/foo", conflicts[0].path);
    try std.testing.expectEqualStrings("pkg1", conflicts[0].package_a);
    try std.testing.expectEqualStrings("pkg2", conflicts[0].package_b);
    try std.testing.expectEqualStrings("/store/pkg1/usr/bin/foo", conflicts[0].target_a);
    try std.testing.expectEqualStrings("/store/pkg2/usr/bin/foo", conflicts[0].target_b);
}

test "PathConflictDetector no conflict for different paths" {
    const allocator = std.testing.allocator;

    var detector = PathConflictDetector.init(allocator);
    defer detector.deinit();

    const result1 = try detector.recordPath("usr/bin/foo", "/store/pkg1", "pkg1");
    try std.testing.expectEqual(PathConflictDetector.RecordResult.added, result1);

    const result2 = try detector.recordPath("usr/bin/bar", "/store/pkg2", "pkg2");
    try std.testing.expectEqual(PathConflictDetector.RecordResult.added, result2);

    try std.testing.expect(!detector.hasConflicts());
}

test "PathConflictDetector multiple conflicts" {
    const allocator = std.testing.allocator;

    var detector = PathConflictDetector.init(allocator);
    defer detector.deinit();

    _ = try detector.recordPath("usr/bin/foo", "/store/pkg1", "pkg1");
    _ = try detector.recordPath("usr/bin/foo", "/store/pkg2", "pkg2");

    _ = try detector.recordPath("usr/lib/libbar.so", "/store/pkg1", "pkg1");
    _ = try detector.recordPath("usr/lib/libbar.so", "/store/pkg3", "pkg3");

    try std.testing.expectEqual(@as(usize, 2), detector.conflictCount());
}

test "PathConflictDetector formatAllConflicts" {
    const allocator = std.testing.allocator;

    var detector = PathConflictDetector.init(allocator);
    defer detector.deinit();

    _ = try detector.recordPath("usr/bin/foo", "/store/pkg1", "pkg1");
    _ = try detector.recordPath("usr/bin/foo", "/store/pkg2", "pkg2");

    const msg = try detector.formatAllConflicts(allocator);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "1 path conflict(s) detected") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "usr/bin/foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "pkg1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "pkg2") != null);
}

test "PathConflict format message" {
    const allocator = std.testing.allocator;

    const conflict = PathConflict{
        .path = "/usr/bin/foo",
        .package_a = "pkg1",
        .package_b = "pkg2",
        .target_a = "/store/pkg1/usr/bin/foo",
        .target_b = "/store/pkg2/usr/bin/foo",
    };

    const msg = try conflict.format(allocator);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "path conflict") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "/usr/bin/foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "pkg1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "pkg2") != null);
}
