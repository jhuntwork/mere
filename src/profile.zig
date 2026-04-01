// Profile builder - creates symlink tree projections from packages
//
// This module implements profile realization, system generation construction,
// and named-profile root publishing.
// specs #15 and #19. A profile is a symlink tree projection of store contents.
//
// Key properties:
// - File-level symlinks (directories are created, not symlinked)
// - Path conflicts are hard errors (no implicit resolution)
// - All symlinks are validated for boundary compliance
// - System profiles use nested layout: /mere/profiles/system/gen-N/
// - Named profiles publish a single live root at /mere/profiles/<name>/root/

const std = @import("std");
const package_manifest = @import("manifest.zig");
const path_safety = @import("path_safety.zig");
const generation = @import("generation.zig");
const projection_index = @import("projection_index.zig");
const path = @import("path.zig");
const Context = @import("mere.zig").Context;
const store = @import("store.zig");
const errors = @import("errors.zig");

pub const ROOT_DIRNAME = "root";

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
        var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &result);
        const out = &out_buf.writer;

        try out.print("{d} path conflict(s) detected:\n", .{self.conflicts.items.len});

        for (self.conflicts.items, 0..) |conflict, i| {
            if (i > 0) {
                try out.writeAll("\n");
            }
            try out.writeAll("  - ");
            try out.print(
                "path conflict: '{s}' claimed by both '{s}' (-> {s}) and '{s}' (-> {s})",
                .{ conflict.path, conflict.package_a, conflict.target_a, conflict.package_b, conflict.target_b },
            );
        }

        result = out_buf.toArrayList();
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

const ParentRealizationState = struct {
    allocator: std.mem.Allocator,
    realization_dir: []const u8,
    manifest: generation.GenerationManifest,
    realization: generation.RealizationData,
    path_lookup: std.StringHashMap(u32),

    fn init(
        allocator: std.mem.Allocator,
        realization_dir: []const u8,
        manifest_data: generation.GenerationManifest,
        realization_data: generation.RealizationData,
    ) !ParentRealizationState {
        var lookup = std.StringHashMap(u32).init(allocator);
        errdefer lookup.deinit();
        try lookup.ensureTotalCapacity(@intCast(realization_data.entries.items.len));
        for (realization_data.entries.items) |entry| {
            lookup.putAssumeCapacity(entry.path, entry.owner_package_index);
        }

        return .{
            .allocator = allocator,
            .realization_dir = realization_dir,
            .manifest = manifest_data,
            .realization = realization_data,
            .path_lookup = lookup,
        };
    }

    fn deinit(self: *ParentRealizationState) void {
        self.path_lookup.deinit();
        self.realization.deinit();
        self.manifest.deinit();
        self.allocator.free(self.realization_dir);
    }
};

fn readPackageProjection(
    allocator: std.mem.Allocator,
    ctx: *Context,
    store_path: []const u8,
) ProfileError!projection_index.Data {
    var store_dir = path.openExistingDir(store_path) catch |err| {
        return ctx.fail(switch (err) {
            error.FileNotFound => ProfileError.StorePathNotFound,
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, store_path, "failed to open store path");
    };
    store_dir.close(path.currentIo());

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

pub fn getRootPath(allocator: std.mem.Allocator, profile_dir: []const u8) ProfileError![]const u8 {
    return std.fs.path.join(allocator, &.{ profile_dir, ROOT_DIRNAME }) catch ProfileError.OutOfMemory;
}

fn ensureRootOwnedPackages(ctx: *Context, packages: []const generation.PackageEntry) ProfileError!void {
    for (packages) |pkg| {
        const store_path = pkg.store_path;
        const store_path_z = try ctx.allocator.dupeZ(u8, store_path);
        defer ctx.allocator.free(store_path_z);

        var statx = std.mem.zeroes(std.os.linux.Statx);
        switch (std.os.linux.errno(std.os.linux.statx(std.posix.AT.FDCWD, store_path_z, 0, .{
            .UID = true,
            .GID = true,
        }, &statx))) {
            .SUCCESS => {},
            .NOENT => return ctx.fail(ProfileError.StorePathNotFound, store_path, "failed to stat store path for ownership"),
            .ACCES, .PERM => return ctx.fail(ProfileError.PermissionDenied, store_path, "failed to stat store path for ownership"),
            else => return ctx.fail(ProfileError.FileSystem, store_path, "failed to stat store path for ownership"),
        }

        if (statx.uid != 0 or statx.gid != 0) {
            store.hardenStoreObject(ctx, store_path) catch {
                return ctx.fail(ProfileError.PermissionDenied, store_path, "failed to harden store path");
            };
        }
    }
}

/// Sort packages by name to ensure indices match the canonical manifest order.
/// The manifest encoder sorts packages alphabetically, so all index-bearing
/// structures (realization, conflict detector) must use the same ordering.
fn canonicalizePackages(allocator: std.mem.Allocator, packages: []const generation.PackageEntry) ProfileError![]const generation.PackageEntry {
    const sorted = allocator.dupe(generation.PackageEntry, packages) catch return ProfileError.OutOfMemory;
    std.mem.sort(generation.PackageEntry, sorted, {}, struct {
        fn lessThan(_: void, a: generation.PackageEntry, b: generation.PackageEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return sorted;
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

    const sorted_packages = try canonicalizePackages(allocator, packages);
    defer allocator.free(sorted_packages);

    const started_at = std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds();

    var result = try planProfileRealization(allocator, ctx, profile_root, store_root, sorted_packages, null);
    errdefer result.deinit();

    if (result.conflicts.hasConflicts()) {
        return result;
    }

    const apply_stats = try applyRealization(
        allocator,
        ctx,
        profile_root,
        sorted_packages,
        &result.realization,
        null,
    );
    result.stats.materialized_entries = apply_stats.materialized_entries;
    result.stats.reused_entries = apply_stats.reused_entries;
    result.stats.duration_ns = @intCast(std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds() - started_at);
    return result;
}

fn planProfileRealization(
    allocator: std.mem.Allocator,
    ctx: *Context,
    profile_root: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
    parent_state: ?*const ParentRealizationState,
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
    parent_state: *const ParentRealizationState,
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
    parent_state: *const ParentRealizationState,
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
    parent_state: *const ParentRealizationState,
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
    parent_state: ?*const ParentRealizationState,
) ProfileError!ProjectionStats {
    var materialized_entries: usize = 0;
    var reused_entries: usize = 0;
    var last_parent: std.ArrayList(u8) = .empty;
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
                        const source_path = std.fs.path.join(allocator, &.{ parent_gen.realization_dir, entry.path }) catch {
                            return ctx.fail(ProfileError.OutOfMemory, parent_gen.realization_dir, "failed to construct parent realization path");
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

    path.ensureDirExists(parent) catch |err| {
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
    std.Io.Dir.deleteFileAbsolute(path.currentIo(), dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.AccessDenied => return ctx.fail(ProfileError.PermissionDenied, dest_path, "failed to remove existing destination before reuse"),
        else => return ctx.fail(ProfileError.FileSystem, dest_path, "failed to remove existing destination before reuse"),
    };

    std.Io.Dir.cwd().hardLink(source_path, std.Io.Dir.cwd(), dest_path, path.currentIo(), .{}) catch |err| {
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

    const io = path.currentIo();
    var parent_dir = path.openExistingDir(parent) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, parent, "failed to open parent directory for symlink replacement");
    };
    defer parent_dir.close(io);

    var random_bytes: [6]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);

    const tmp_name = std.fmt.allocPrint(allocator, ".{s}.tmp-{s}", .{ basename, suffix }) catch {
        return ctx.fail(ProfileError.OutOfMemory, profile_path, "failed to allocate temp symlink name");
    };
    defer allocator.free(tmp_name);

    parent_dir.symLink(io, store_target, tmp_name, .{}) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, profile_path, "failed to create temporary symlink");
    };
    errdefer parent_dir.deleteFile(io, tmp_name) catch {};

    parent_dir.rename(tmp_name, parent_dir, basename, io) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, profile_path, "failed to atomically replace symlink");
    };
}

fn loadParentRealizationState(
    allocator: std.mem.Allocator,
    ctx: *Context,
    realization_dir: []const u8,
) ProfileError!ParentRealizationState {
    const owned_realization_dir = allocator.dupe(u8, realization_dir) catch {
        return ctx.fail(ProfileError.OutOfMemory, realization_dir, "failed to duplicate parent realization path");
    };
    errdefer allocator.free(owned_realization_dir);

    const store_root = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(ProfileError.OutOfMemory, realization_dir, "failed to construct store root path");
    };
    defer allocator.free(store_root);

    var manifest_data = generation.readManifest(allocator, store_root, realization_dir) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.GenerationNotFound => ProfileError.FileSystem,
            generation.GenerationError.InvalidManifest, generation.GenerationError.ParseError => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, realization_dir, "failed to read parent realization manifest");
    };
    errdefer manifest_data.deinit();

    var realization_data = generation.readRealization(allocator, realization_dir) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.InvalidManifest, generation.GenerationError.ParseError => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, realization_dir, "failed to read parent realization");
    };
    errdefer realization_data.deinit();

    return ParentRealizationState.init(allocator, owned_realization_dir, manifest_data, realization_data) catch {
        return ctx.fail(ProfileError.OutOfMemory, realization_dir, "failed to build parent realization lookup");
    };
}

fn exchangePaths(left_path: []const u8, right_path: []const u8) ProfileError!void {
    const rename_exchange = std.os.linux.RENAME{ .EXCHANGE = true };
    const left_z = std.heap.page_allocator.dupeZ(u8, left_path) catch return ProfileError.OutOfMemory;
    defer std.heap.page_allocator.free(left_z);
    const right_z = std.heap.page_allocator.dupeZ(u8, right_path) catch return ProfileError.OutOfMemory;
    defer std.heap.page_allocator.free(right_z);

    switch (std.posix.errno(std.os.linux.renameat2(
        std.os.linux.AT.FDCWD,
        left_z,
        std.os.linux.AT.FDCWD,
        right_z,
        rename_exchange,
    ))) {
        .SUCCESS => {},
        .ACCES => return ProfileError.PermissionDenied,
        .INVAL => return ProfileError.InvalidInput,
        else => return ProfileError.FileSystem,
    }
}

fn buildProfileManifest(
    allocator: std.mem.Allocator,
    packages: []const generation.PackageEntry,
    generation_num: ?u32,
    parent_generation: ?u32,
    selected_profile: []const u8,
) ProfileError!generation.GenerationManifest {
    var manifest = if (generation_num) |gen_num|
        generation.GenerationManifest.init(allocator, gen_num)
    else
        generation.GenerationManifest.initRoot(allocator);
    errdefer manifest.deinit();

    manifest.parent_generation = parent_generation;
    manifest.selected_profile = allocator.dupe(u8, selected_profile) catch return ProfileError.OutOfMemory;

    for (packages) |pkg| {
        manifest.addPackage(
            pkg.name,
            pkg.version,
            pkg.release,
            pkg.arch,
            pkg.store_path,
            pkg.content_hash,
        ) catch return ProfileError.OutOfMemory;
    }

    return manifest;
}

pub fn publishProfileRoot(
    ctx: *Context,
    profile_dir: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
) ProfileError!ProjectionStats {
    if (isSystemProfile(profile_dir)) {
        return ctx.fail(ProfileError.InvalidInput, profile_dir, "system profile uses generations");
    }

    const sorted_packages = try canonicalizePackages(ctx.allocator, packages);
    defer ctx.allocator.free(sorted_packages);

    var random_bytes: [6]u8 = undefined;
    path.currentIo().random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const stage_dir = std.fmt.allocPrint(ctx.allocator, "{s}/.root-new-{s}", .{ profile_dir, suffix }) catch {
        return ctx.fail(ProfileError.OutOfMemory, profile_dir, "failed to allocate staged root path");
    };
    defer ctx.allocator.free(stage_dir);

    path.ensureDirExists(stage_dir) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, stage_dir, "failed to create staged profile root");
    };
    errdefer path.deleteTreeAbsolute(stage_dir) catch {};

    const root_path = try getRootPath(ctx.allocator, profile_dir);
    defer ctx.allocator.free(root_path);

    var parent_state: ?ParentRealizationState = null;
    defer if (parent_state) |*state| state.deinit();

    const root_exists = blk: {
        std.Io.Dir.accessAbsolute(path.currentIo(), root_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return ctx.fail(switch (err) {
                error.AccessDenied => ProfileError.PermissionDenied,
                else => ProfileError.FileSystem,
            }, root_path, "failed to access existing profile root"),
        };
        break :blk true;
    };
    if (root_exists) {
        parent_state = try loadParentRealizationState(ctx.allocator, ctx, root_path);
    }

    const started_at = std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds();
    var result = try planProfileRealization(
        ctx.allocator,
        ctx,
        stage_dir,
        store_root,
        sorted_packages,
        if (parent_state) |*state| state else null,
    );
    defer result.deinit();

    if (result.conflicts.hasConflicts()) {
        const details = result.conflicts.formatAllConflicts(ctx.allocator) catch
            return ctx.fail(ProfileError.PathConflict, profile_dir, "path conflicts detected (details unavailable: out of memory)");
        defer ctx.allocator.free(details);
        return ctx.fail(ProfileError.PathConflict, profile_dir, details);
    }

    const apply_stats = try applyRealization(
        ctx.allocator,
        ctx,
        stage_dir,
        sorted_packages,
        &result.realization,
        if (parent_state) |*state| state else null,
    );
    result.stats.materialized_entries = apply_stats.materialized_entries;
    result.stats.reused_entries = apply_stats.reused_entries;
    result.stats.duration_ns = @intCast(std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds() - started_at);

    var manifest = try buildProfileManifest(
        ctx.allocator,
        sorted_packages,
        null,
        null,
        std.fs.path.basename(profile_dir),
    );
    defer manifest.deinit();

    generation.writeRealization(ctx.allocator, stage_dir, &result.realization) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.InvalidManifest => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, stage_dir, "failed to write profile realization");
    };

    generation.writeManifest(ctx.allocator, stage_dir, &manifest) catch |err| {
        return ctx.fail(switch (err) {
            generation.GenerationError.PermissionDenied => ProfileError.PermissionDenied,
            generation.GenerationError.OutOfMemory => ProfileError.OutOfMemory,
            generation.GenerationError.InvalidManifest => ProfileError.InvalidInput,
            else => ProfileError.FileSystem,
        }, stage_dir, "failed to write profile manifest");
    };

    if (root_exists) {
        exchangePaths(stage_dir, root_path) catch |err| {
            return ctx.fail(err, root_path, "failed to atomically publish profile root");
        };
        path.deleteTreeAbsolute(stage_dir) catch |err| {
            ctx.debug("failed to remove previous profile root after publish: {}", .{err});
        };
    } else {
        std.Io.Dir.renameAbsolute(stage_dir, root_path, path.currentIo()) catch |err| {
            return ctx.fail(switch (err) {
                error.AccessDenied => ProfileError.PermissionDenied,
                else => ProfileError.FileSystem,
            }, root_path, "failed to publish profile root");
        };
    }

    return result.stats;
}

pub fn createGeneration(
    ctx: *Context,
    profile_dir: []const u8,
    store_root: []const u8,
    packages: []const generation.PackageEntry,
    parent_generation: ?u32,
) ProfileError!u32 {
    const sorted_packages = try canonicalizePackages(ctx.allocator, packages);
    defer ctx.allocator.free(sorted_packages);

    const started_at = std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds();
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

    path.ensureDirExists(gen_path) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, gen_path, "failed to create generation directory");
    };

    if (isSystemProfile(profile_dir)) {
        try ensureRootOwnedPackages(ctx, sorted_packages);
    }

    var parent_state = if (parent_generation) |parent_num| blk: {
        const parent_dir = generation.getGenerationPath(ctx.allocator, profile_dir, parent_num) catch {
            return ctx.fail(ProfileError.OutOfMemory, profile_dir, "failed to construct parent generation path");
        };
        defer ctx.allocator.free(parent_dir);
        break :blk try loadParentRealizationState(ctx.allocator, ctx, parent_dir);
    } else null;
    defer if (parent_state) |*state| state.deinit();

    var result = try planProfileRealization(
        ctx.allocator,
        ctx,
        gen_path,
        store_root,
        sorted_packages,
        if (parent_state) |*state| state else null,
    );
    defer result.deinit();

    if (result.conflicts.hasConflicts()) {
        const details = result.conflicts.formatAllConflicts(ctx.allocator) catch
            return ctx.fail(ProfileError.PathConflict, profile_dir, "path conflicts detected (details unavailable: out of memory)");
        defer ctx.allocator.free(details);
        return ctx.fail(ProfileError.PathConflict, profile_dir, details);
    }

    const apply_stats = try applyRealization(
        ctx.allocator,
        ctx,
        gen_path,
        sorted_packages,
        &result.realization,
        if (parent_state) |*state| state else null,
    );
    result.stats.materialized_entries = apply_stats.materialized_entries;
    result.stats.reused_entries = apply_stats.reused_entries;
    result.stats.duration_ns = @intCast(std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds() - started_at);

    var manifest = try buildProfileManifest(
        ctx.allocator,
        sorted_packages,
        gen_num,
        parent_generation,
        std.fs.path.basename(profile_dir),
    );
    defer manifest.deinit();

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

    path.ensureDirExists(profile_dir) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ProfileError.PermissionDenied,
            else => ProfileError.FileSystem,
        }, profile_dir, "failed to create profile directory");
    };

    return profile_dir;
}

const test_content_hash = "abc1230000000000000000000000000000000000000000000000000000000000";
const test_content_hash_b = "def4560000000000000000000000000000000000000000000000000000000000";

fn testPackageEntry(name: []const u8, store_path: []const u8) generation.PackageEntry {
    return .{
        .name = name,
        .version = "1.0",
        .release = 1,
        .arch = "x86_64",
        .store_path = store_path,
        .content_hash = test_content_hash,
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
    try path.ensureDirExists(bin_dir);

    // Create a file in the package
    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "hello" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho hello\n");
        f.close(path.currentIo());
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try path.ensureDirExists(profile_root);

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
    const target_len = try std.Io.Dir.readLinkAbsolute(path.currentIo(), expected_link, &buf);
    try std.testing.expectEqualStrings(file_path, buf[0..target_len]);
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
    try path.ensureDirExists(pkg1_bin);

    const pkg2_path = try std.fs.path.join(allocator, &.{ store_root, "pkg2-1.0" });
    defer allocator.free(pkg2_path);
    const pkg2_bin = try std.fs.path.join(allocator, &.{ pkg2_path, "bin" });
    defer allocator.free(pkg2_bin);
    try path.ensureDirExists(pkg2_bin);

    // Both packages provide bin/foo
    const file1 = try std.fs.path.join(allocator, &.{ pkg1_bin, "foo" });
    defer allocator.free(file1);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file1, .{});
        try f.writeStreamingAll(path.currentIo(), "pkg1");
        f.close(path.currentIo());
    }

    const file2 = try std.fs.path.join(allocator, &.{ pkg2_bin, "foo" });
    defer allocator.free(file2);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file2, .{});
        try f.writeStreamingAll(path.currentIo(), "pkg2");
        f.close(path.currentIo());
    }

    try writeProjectionForTestPackage(allocator, pkg1_path);
    try writeProjectionForTestPackage(allocator, pkg2_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try path.ensureDirExists(profile_root);

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
    try path.ensureDirExists(pkg_path);

    // Create manifest files under .mere/ (should be skipped)
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_path, package_manifest.MANIFEST_FILENAME });
    defer allocator.free(manifest_path);
    {
        try path.ensureDirExists(std.fs.path.dirname(manifest_path).?);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), manifest_path, .{});
        try f.writeStreamingAll(path.currentIo(), "manifest");
        f.close(path.currentIo());
    }

    const sig_path = try std.fs.path.join(allocator, &.{ pkg_path, package_manifest.MANIFEST_SIG_FILENAME });
    defer allocator.free(sig_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), sig_path, .{});
        try f.writeStreamingAll(path.currentIo(), "sig");
        f.close(path.currentIo());
    }

    const meta_path = try std.fs.path.join(allocator, &.{ pkg_path, package_manifest.META_KDL_FILENAME });
    defer allocator.free(meta_path);
    {
        try path.ensureDirExists(std.fs.path.dirname(meta_path).?);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), meta_path, .{});
        try f.writeStreamingAll(path.currentIo(), "metadata");
        f.close(path.currentIo());
    }

    // Create a regular file that should be included
    const bin_path = try std.fs.path.join(allocator, &.{ pkg_path, "bin", "tool" });
    defer allocator.free(bin_path);
    {
        const parent = std.fs.path.dirname(bin_path) orelse pkg_path;
        try path.ensureDirExists(parent);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), bin_path, .{});
        try f.writeStreamingAll(path.currentIo(), "tool");
        f.close(path.currentIo());
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try path.ensureDirExists(profile_root);

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
    const maybe_dir = std.Io.Dir.openDirAbsolute(path.currentIo(), mere_link, .{});
    if (maybe_dir) |dir| {
        @constCast(&dir).close(path.currentIo());
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
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);
    try path.ensureDirExists(store_root);

    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, "abc123def456789012345678901234567890123456789012345678901234-test-1.0" });
    defer allocator.free(pkg_path);

    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try path.ensureDirExists(bin_dir);

    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "test" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        try f.writeStreamingAll(path.currentIo(), "test");
        f.close(path.currentIo());
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory (new layout: profiles/<name>/)
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try path.ensureDirExists(profile_dir);

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
    const manifest_path = try std.fs.path.join(allocator, &.{ gen_path, "profile.kdl" });
    defer allocator.free(manifest_path);
    try std.testing.expect(path.fileExists(manifest_path));
    const realization_path = try std.fs.path.join(allocator, &.{ gen_path, generation.REALIZATION_FILENAME });
    defer allocator.free(realization_path);
    try std.testing.expect(path.fileExists(realization_path));

    // Verify symlink was created
    const link_path = try std.fs.path.join(allocator, &.{ gen_path, "bin", "test" });
    defer allocator.free(link_path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try std.Io.Dir.readLinkAbsolute(path.currentIo(), link_path, &buf);
    try std.testing.expectEqualStrings(file_path, buf[0..target_len]);

    // Verify manifest was written
    var manifest = try generation.readManifest(allocator, store_root, gen_path);
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
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);
    try path.ensureDirExists(store_root);
    const pkg_path = try std.fs.path.join(allocator, &.{ store_root, test_content_hash ++ "-test-1.0" });
    defer allocator.free(pkg_path);
    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try path.ensureDirExists(bin_dir);

    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "test" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "test");
    }
    try writeProjectionForTestPackage(allocator, pkg_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try path.ensureDirExists(profile_dir);

    const packages = [_]generation.PackageEntry{testPackageEntry("test", pkg_path)};

    const gen1 = try createGeneration(&test_env.ctx, profile_dir, store_root, &packages, null);
    try std.testing.expectEqual(@as(u32, 1), gen1);
    const gen2 = try createGeneration(&test_env.ctx, profile_dir, store_root, &packages, 1);
    try std.testing.expectEqual(@as(u32, 2), gen2);

    const gen1_link = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1", "bin", "test" });
    defer allocator.free(gen1_link);
    const gen2_link = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2", "bin", "test" });
    defer allocator.free(gen2_link);

    const gen1_link_z = try allocator.dupeZ(u8, gen1_link);
    defer allocator.free(gen1_link_z);
    const gen2_link_z = try allocator.dupeZ(u8, gen2_link);
    defer allocator.free(gen2_link_z);

    var statx1 = std.mem.zeroes(std.os.linux.Statx);
    var statx2 = std.mem.zeroes(std.os.linux.Statx);
    switch (std.os.linux.errno(std.os.linux.statx(std.posix.AT.FDCWD, gen1_link_z, std.posix.AT.SYMLINK_NOFOLLOW, .{
        .INO = true,
    }, &statx1))) {
        .SUCCESS => {},
        else => return error.FileSystem,
    }
    switch (std.os.linux.errno(std.os.linux.statx(std.posix.AT.FDCWD, gen2_link_z, std.posix.AT.SYMLINK_NOFOLLOW, .{
        .INO = true,
    }, &statx2))) {
        .SUCCESS => {},
        else => return error.FileSystem,
    }
    try std.testing.expectEqual(statx1.ino, statx2.ino);
}

test "createGeneration does not reread projection.v1 for unchanged parent package" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);
    try path.ensureDirExists(store_root);

    const pkg_a_path = try std.fs.path.join(allocator, &.{ store_root, test_content_hash ++ "-pkg-a-1.0" });
    defer allocator.free(pkg_a_path);
    const pkg_a_bin = try std.fs.path.join(allocator, &.{ pkg_a_path, "bin" });
    defer allocator.free(pkg_a_bin);
    try path.ensureDirExists(pkg_a_bin);
    const pkg_a_file = try std.fs.path.join(allocator, &.{ pkg_a_bin, "a" });
    defer allocator.free(pkg_a_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), pkg_a_file, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "a");
    }
    try writeProjectionForTestPackage(allocator, pkg_a_path);

    const pkg_b_path = try std.fs.path.join(allocator, &.{ store_root, test_content_hash_b ++ "-pkg-b-1.0" });
    defer allocator.free(pkg_b_path);
    const pkg_b_bin = try std.fs.path.join(allocator, &.{ pkg_b_path, "bin" });
    defer allocator.free(pkg_b_bin);
    try path.ensureDirExists(pkg_b_bin);
    const pkg_b_file = try std.fs.path.join(allocator, &.{ pkg_b_bin, "b" });
    defer allocator.free(pkg_b_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), pkg_b_file, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "b");
    }
    try writeProjectionForTestPackage(allocator, pkg_b_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try path.ensureDirExists(profile_dir);

    const pkg_b_entry = generation.PackageEntry{
        .name = "pkg-b",
        .version = "1.0",
        .release = 1,
        .arch = "x86_64",
        .store_path = pkg_b_path,
        .content_hash = test_content_hash_b,
    };

    const gen1_packages = [_]generation.PackageEntry{
        testPackageEntry("pkg-a", pkg_a_path),
    };
    const gen1 = try createGeneration(&test_env.ctx, profile_dir, store_root, &gen1_packages, null);
    try std.testing.expectEqual(@as(u32, 1), gen1);

    const projection_path = try std.fs.path.join(allocator, &.{ pkg_a_path, package_manifest.PROJECTION_FILENAME });
    defer allocator.free(projection_path);
    try std.Io.Dir.deleteFileAbsolute(path.currentIo(), projection_path);

    const gen2_packages = [_]generation.PackageEntry{
        testPackageEntry("pkg-a", pkg_a_path),
        pkg_b_entry,
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
    try path.ensureDirExists(pkg_a_bin);
    const pkg_a_file = try std.fs.path.join(allocator, &.{ pkg_a_bin, "tool" });
    defer allocator.free(pkg_a_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), pkg_a_file, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "a");
    }
    try writeProjectionForTestPackage(allocator, pkg_a_path);

    const pkg_b_path = try std.fs.path.join(allocator, &.{ store_root, "pkg-b-1.0" });
    defer allocator.free(pkg_b_path);
    const pkg_b_bin = try std.fs.path.join(allocator, &.{ pkg_b_path, "bin" });
    defer allocator.free(pkg_b_bin);
    try path.ensureDirExists(pkg_b_bin);
    const pkg_b_file = try std.fs.path.join(allocator, &.{ pkg_b_bin, "tool" });
    defer allocator.free(pkg_b_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), pkg_b_file, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "b");
    }
    try writeProjectionForTestPackage(allocator, pkg_b_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try path.ensureDirExists(profile_dir);

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

test "createGeneration realization indices match manifest package order" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);
    try path.ensureDirExists(store_root);

    // Create two packages with names that sort differently than input order
    const pkg_z_hash = "aaaa000000000000000000000000000000000000000000000000000000000000";
    const pkg_a_hash = "bbbb000000000000000000000000000000000000000000000000000000000000";
    const pkg_z_path = try std.fs.path.join(allocator, &.{ store_root, pkg_z_hash ++ "-zzz-1.0" });
    defer allocator.free(pkg_z_path);
    const pkg_a_path = try std.fs.path.join(allocator, &.{ store_root, pkg_a_hash ++ "-aaa-1.0" });
    defer allocator.free(pkg_a_path);

    // pkg "zzz" has bin/ztool
    const z_bin = try std.fs.path.join(allocator, &.{ pkg_z_path, "bin" });
    defer allocator.free(z_bin);
    try path.ensureDirExists(z_bin);
    const z_file = try std.fs.path.join(allocator, &.{ z_bin, "ztool" });
    defer allocator.free(z_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), z_file, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "z");
    }
    try writeProjectionForTestPackage(allocator, pkg_z_path);

    // pkg "aaa" has bin/atool
    const a_bin = try std.fs.path.join(allocator, &.{ pkg_a_path, "bin" });
    defer allocator.free(a_bin);
    try path.ensureDirExists(a_bin);
    const a_file = try std.fs.path.join(allocator, &.{ a_bin, "atool" });
    defer allocator.free(a_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), a_file, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "a");
    }
    try writeProjectionForTestPackage(allocator, pkg_a_path);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "dev" });
    defer allocator.free(profile_dir);
    try path.ensureDirExists(profile_dir);

    // Pass packages in REVERSE alphabetical order (zzz first, aaa second)
    const packages = [_]generation.PackageEntry{
        .{ .name = "zzz", .version = "1.0", .release = 1, .arch = "x86_64", .store_path = pkg_z_path, .content_hash = pkg_z_hash },
        .{ .name = "aaa", .version = "1.0", .release = 1, .arch = "x86_64", .store_path = pkg_a_path, .content_hash = pkg_a_hash },
    };

    const gen_num = try createGeneration(&test_env.ctx, profile_dir, store_root, &packages, null);
    try std.testing.expectEqual(@as(u32, 1), gen_num);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);

    // Read manifest — packages should be sorted alphabetically
    var manifest = try generation.readManifest(allocator, store_root, gen_path);
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 2), manifest.packages.items.len);
    try std.testing.expectEqualStrings("aaa", manifest.packages.items[0].name);
    try std.testing.expectEqualStrings("zzz", manifest.packages.items[1].name);

    // Read realization — owner indices must match manifest order
    var realization = try generation.readRealization(allocator, gen_path);
    defer realization.deinit();

    for (realization.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, "bin/atool")) {
            // "aaa" is manifest index 0
            try std.testing.expectEqual(@as(u32, 0), entry.owner_package_index);
        } else if (std.mem.eql(u8, entry.path, "bin/ztool")) {
            // "zzz" is manifest index 1
            try std.testing.expectEqual(@as(u32, 1), entry.owner_package_index);
        }
    }
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
    try path.ensureDirExists(profiles_dir);

    // Create a profile
    const profile_dir = try createProfile(&test_env.ctx, profiles_dir, "dev");
    defer allocator.free(profile_dir);

    // Verify it was created by opening it
    var dir = try path.openExistingDir(profile_dir);
    dir.close(path.currentIo());

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
    try path.ensureDirExists(pkg_path);

    // Create etc/ directory with a config file (should be skipped)
    const etc_dir = try std.fs.path.join(allocator, &.{ pkg_path, "etc" });
    defer allocator.free(etc_dir);
    try path.ensureDirExists(etc_dir);

    const etc_file = try std.fs.path.join(allocator, &.{ etc_dir, "config.conf" });
    defer allocator.free(etc_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), etc_file, .{});
        try f.writeStreamingAll(path.currentIo(), "config");
        f.close(path.currentIo());
    }

    // Create etc-defaults/ directory with a template (should be included)
    const etc_defaults_dir = try std.fs.path.join(allocator, &.{ pkg_path, "etc-defaults" });
    defer allocator.free(etc_defaults_dir);
    try path.ensureDirExists(etc_defaults_dir);

    const etc_defaults_file = try std.fs.path.join(allocator, &.{ etc_defaults_dir, "template.conf" });
    defer allocator.free(etc_defaults_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), etc_defaults_file, .{});
        try f.writeStreamingAll(path.currentIo(), "template");
        f.close(path.currentIo());
    }

    // Create a regular file that should be included
    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try path.ensureDirExists(bin_dir);

    const bin_file = try std.fs.path.join(allocator, &.{ bin_dir, "tool" });
    defer allocator.free(bin_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), bin_file, .{});
        try f.writeStreamingAll(path.currentIo(), "tool");
        f.close(path.currentIo());
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try path.ensureDirExists(profile_root);

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
    try path.ensureDirExists(pkg_path);

    const bin_dir = try std.fs.path.join(allocator, &.{ pkg_path, "bin" });
    defer allocator.free(bin_dir);
    try path.ensureDirExists(bin_dir);

    const tool_path = try std.fs.path.join(allocator, &.{ bin_dir, "tool" });
    defer allocator.free(tool_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), tool_path, .{});
        try f.writeStreamingAll(path.currentIo(), "tool");
        f.close(path.currentIo());
    }

    // Create profile directory
    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-1" });
    defer allocator.free(profile_root);
    try path.ensureDirExists(profile_root);

    const result = buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("badpkg", pkg_path)});
    try std.testing.expectError(ProfileError.InvalidStoreLayout, result);
}

test "buildProfile preserves existing symlink when atomic replacement cannot start" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

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
    try path.ensureDirExists(bin_dir);

    const file_path = try std.fs.path.join(allocator, &.{ bin_dir, "tool" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), file_path, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "tool");
    }

    try writeProjectionForTestPackage(allocator, pkg_path);

    const profile_root = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system-atomic" });
    defer allocator.free(profile_root);
    const profile_bin = try std.fs.path.join(allocator, &.{ profile_root, "bin" });
    defer allocator.free(profile_bin);
    try path.ensureDirExists(profile_bin);

    const link_path = try std.fs.path.join(allocator, &.{ profile_bin, "tool" });
    defer allocator.free(link_path);
    {
        var dir = try path.openExistingDir(profile_bin);
        defer dir.close(path.currentIo());
        try dir.symLink(path.currentIo(), "/existing/target", "tool", .{});
    }

    // Deny write in parent dir to force temp-symlink creation failure.
    var profile_bin_dir = try path.openExistingDir(profile_bin);
    defer profile_bin_dir.close(path.currentIo());
    try profile_bin_dir.setPermissions(path.currentIo(), .fromMode(0o555));
    defer profile_bin_dir.setPermissions(path.currentIo(), .fromMode(0o755)) catch {};

    const result = buildProfile(allocator, &test_env.ctx, profile_root, store_root, &.{testPackageEntry("test", pkg_path)});
    if (result) |success| {
        var owned = success;
        defer owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(ProfileError.PermissionDenied, err);
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try std.Io.Dir.readLinkAbsolute(path.currentIo(), link_path, &buf);
    try std.testing.expectEqualStrings("/existing/target", buf[0..target_len]);
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
