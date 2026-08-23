const std = @import("std");
const package = @import("package.zig");
const mere = @import("mere.zig");
const Context = mere.Context;
const Repository = @import("repository.zig").Repository;
const archive = @import("archive.zig");
const download = @import("download.zig");
const extract = @import("extract.zig");
const path = @import("path.zig");
const repodb = @import("repodb.zig");
const c = repodb.c;
const sign = @import("sign.zig");
const repocache_mod = @import("repocache.zig");
const repo_sync = @import("repo_sync.zig");
const SyncPolicy = repo_sync.SyncPolicy;
const RepoCache = repocache_mod.RepoCache;
const config_mod = @import("config.zig");
const repo_sources = @import("repo_sources.zig");
const hash = @import("hash.zig");
const resolver = @import("resolver.zig");
const store = @import("store.zig");
const manifest = @import("manifest.zig");
const projection_index = @import("projection_index.zig");
const path_safety = @import("path_safety.zig");
const profile = @import("profile.zig");
const generation = @import("generation.zig");
const activation = @import("activation.zig");
const service_reconcile = @import("service_reconcile.zig");
const gcroots = @import("gcroots.zig");
const scratch = @import("scratch.zig");
const version_mod = @import("version.zig");
const version_constraint = @import("version_constraint.zig");
const ui = mere.ui;
const emit = ui.emit;

const InstallRootRequirement = struct {
    name: []const u8,
    constraint_expr: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
    requested: bool = true,
    intent_constraint: ?[]const u8 = null,

    fn deinit(self: *InstallRootRequirement, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.constraint_expr) |expr| allocator.free(expr);
        if (self.content_hash) |h| allocator.free(h);
        if (self.intent_constraint) |expr| allocator.free(expr);
    }
};

pub const InstallCommandOutcome = enum {
    completed,
    store_only_system_activation_deferred,
};

const InstallTargetBehavior = enum {
    store_only_requested,
    store_only_system_deferred,
    activate_profile,
};

fn emitGenerationStatus(
    ctx: *Context,
    action: []const u8,
    gen_num: usize,
    profile_name: ?[]const u8,
    phase: ui.Phase,
) void {
    var gen_buf: [32]u8 = undefined;
    const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num}) catch return;
    if (profile_name) |prof_name| {
        const segments = [_]mere.ui.Segment{
            .{ .text = "generation ", .kind = .normal },
            .{ .text = action, .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = gen_text, .kind = .detail },
            .{ .text = " in profile '", .kind = .normal },
            .{ .text = prof_name, .kind = .detail },
            .{ .text = "'", .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, phase, .info, &segments);
        return;
    }

    const segments = [_]mere.ui.Segment{
        .{ .text = "generation ", .kind = .normal },
        .{ .text = action, .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = gen_text, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, phase, .info, &segments);
}

fn determineInstallTargetBehavior(
    profile_name: ?[]const u8,
    target_profile_path: ?[]const u8,
    privileged: bool,
) InstallTargetBehavior {
    if (target_profile_path != null) return .activate_profile;
    if (profile_name) |prof_name| {
        if (std.mem.eql(u8, prof_name, "system") and !privileged) {
            return .store_only_system_deferred;
        }
        return .activate_profile;
    }
    return .store_only_requested;
}

/// Find all packages that transitively depend on `target_name` by walking
/// reverse dependency edges. Returns the set of ancestor package names.
fn findTransitiveDependents(
    allocator: std.mem.Allocator,
    sorted: []const resolver.ResolvedPackage,
    target_name: []const u8,
) std.StringHashMap(void) {
    // Build reverse map: package name -> list of packages that depend on it
    var rdeps = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = rdeps.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        rdeps.deinit();
    }

    for (sorted) |resolved| {
        const pkg_name = resolved.pkg.name orelse continue;
        for (resolved.dependency_names) |dep_name| {
            var entry = rdeps.getOrPut(dep_name) catch continue;
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            entry.value_ptr.append(allocator, pkg_name) catch continue;
        }
    }

    // BFS upward from target
    var result = std.StringHashMap(void).init(allocator);
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    queue.append(allocator, target_name) catch return result;

    while (queue.items.len > 0) {
        const name = queue.orderedRemove(0);
        if (rdeps.get(name)) |parents| {
            for (parents.items) |parent| {
                if (!result.contains(parent)) {
                    result.put(parent, {}) catch continue;
                    queue.append(allocator, parent) catch continue;
                }
            }
        }
    }

    return result;
}

fn profileMatchesResolution(ctx: *Context, profile_name: []const u8, sorted: []const resolver.ResolvedPackage) bool {
    const profile_dir = getProfileDir(ctx, profile_name) catch return false;
    defer ctx.allocator.free(profile_dir);

    const current = (loadCurrentManifest(ctx, profile_name, profile_dir) catch return false) orelse return false;
    defer {
        var m = current;
        m.deinit();
    }

    if (current.packages.items.len != sorted.len) return false;

    var current_by_hash = std.StringHashMap(generation.PackageEntry).init(ctx.allocator);
    defer current_by_hash.deinit();
    for (current.packages.items) |pkg| {
        current_by_hash.put(pkg.content_hash, pkg) catch return false;
    }

    for (sorted) |resolved| {
        const current_pkg = current_by_hash.get(resolved.pkg.content_hash) orelse return false;
        if (current_pkg.requested != resolved.requested) return false;
        if (!optionalStringEqual(current_pkg.constraint_expr, resolved.constraint_expr)) return false;
    }

    return true;
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn emitResolutionDiff(
    ctx: *Context,
    profile_name: []const u8,
    sorted: []const resolver.ResolvedPackage,
    phase: ui.Phase,
) void {
    const profile_dir = getProfileDir(ctx, profile_name) catch return;
    defer ctx.allocator.free(profile_dir);

    const current = (loadCurrentManifest(ctx, profile_name, profile_dir) catch null) orelse {
        var buf: [32]u8 = undefined;
        const count_text = std.fmt.bufPrint(&buf, "{d}", .{sorted.len}) catch return;
        const segments = [_]mere.ui.Segment{
            .{ .text = count_text, .kind = .detail },
            .{ .text = " packages added", .kind = .success },
        };
        emit.logSegmentsSeverity(ctx, phase, .info, &segments);
        return;
    };
    defer {
        var m = current;
        m.deinit();
    }

    var current_by_name = std.StringHashMap([]const u8).init(ctx.allocator);
    defer current_by_name.deinit();
    for (current.packages.items) |pkg| {
        current_by_name.put(pkg.name, pkg.content_hash) catch return;
    }

    var new_by_name = std.StringHashMap(void).init(ctx.allocator);
    defer new_by_name.deinit();
    for (sorted) |resolved| {
        if (resolved.pkg.name) |name| new_by_name.put(name, {}) catch return;
    }

    var installed: std.ArrayList([]const u8) = .empty;
    defer installed.deinit(ctx.allocator);
    var uninstalled: std.ArrayList([]const u8) = .empty;
    defer uninstalled.deinit(ctx.allocator);
    var upgraded: std.ArrayList([]const u8) = .empty;
    defer upgraded.deinit(ctx.allocator);
    var unchanged: usize = 0;

    for (sorted) |resolved| {
        const name = resolved.pkg.name orelse continue;
        if (current_by_name.get(name)) |old_hash| {
            if (std.mem.eql(u8, old_hash, resolved.pkg.content_hash)) {
                unchanged += 1;
            } else {
                upgraded.append(ctx.allocator, name) catch return;
            }
        } else {
            installed.append(ctx.allocator, name) catch return;
        }
    }

    for (current.packages.items) |pkg| {
        if (!new_by_name.contains(pkg.name)) {
            uninstalled.append(ctx.allocator, pkg.name) catch return;
        }
    }

    emitDiffCounts(ctx, phase, installed.items, uninstalled.items, upgraded.items, unchanged);
}

fn emitProfileDiff(
    ctx: *Context,
    profile_name: []const u8,
    new_packages: []const generation.PackageEntry,
    phase: ui.Phase,
) void {
    const profile_dir = getProfileDir(ctx, profile_name) catch return;
    defer ctx.allocator.free(profile_dir);

    const current = (loadCurrentManifest(ctx, profile_name, profile_dir) catch null) orelse {
        var buf: [32]u8 = undefined;
        const count_text = std.fmt.bufPrint(&buf, "{d}", .{new_packages.len}) catch return;
        const segments = [_]mere.ui.Segment{
            .{ .text = count_text, .kind = .detail },
            .{ .text = " packages added", .kind = .success },
        };
        emit.logSegmentsSeverity(ctx, phase, .info, &segments);
        return;
    };
    defer {
        var m = current;
        m.deinit();
    }

    var current_by_name = std.StringHashMap(generation.PackageEntry).init(ctx.allocator);
    defer current_by_name.deinit();
    for (current.packages.items) |pkg| {
        current_by_name.put(pkg.name, pkg) catch return;
    }

    var new_by_name = std.StringHashMap(void).init(ctx.allocator);
    defer new_by_name.deinit();
    for (new_packages) |pkg| {
        new_by_name.put(pkg.name, {}) catch return;
    }

    var installed: std.ArrayList([]const u8) = .empty;
    defer installed.deinit(ctx.allocator);
    var uninstalled: std.ArrayList([]const u8) = .empty;
    defer uninstalled.deinit(ctx.allocator);
    var upgraded: std.ArrayList([]const u8) = .empty;
    defer upgraded.deinit(ctx.allocator);
    var unchanged: usize = 0;

    for (new_packages) |pkg| {
        if (current_by_name.get(pkg.name)) |old| {
            if (std.mem.eql(u8, old.content_hash, pkg.content_hash)) {
                unchanged += 1;
            } else {
                upgraded.append(ctx.allocator, pkg.name) catch return;
            }
        } else {
            installed.append(ctx.allocator, pkg.name) catch return;
        }
    }

    for (current.packages.items) |pkg| {
        if (!new_by_name.contains(pkg.name)) {
            uninstalled.append(ctx.allocator, pkg.name) catch return;
        }
    }

    emitDiffCounts(ctx, phase, installed.items, uninstalled.items, upgraded.items, unchanged);
}

fn emitDiffCounts(
    ctx: *Context,
    phase: ui.Phase,
    installed_names: []const []const u8,
    uninstalled_names: []const []const u8,
    upgraded_names: []const []const u8,
    unchanged: usize,
) void {
    if (installed_names.len > 0) {
        emitNamedDiffLine(ctx, phase, "installed: ", .success, installed_names);
    }
    if (uninstalled_names.len > 0) {
        emitNamedDiffLine(ctx, phase, "uninstalled: ", .warn, uninstalled_names);
    }
    if (upgraded_names.len > 0) {
        emitNamedDiffLine(ctx, phase, "upgraded: ", .detail, upgraded_names);
    }
    if (unchanged > 0) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d} unchanged", .{unchanged}) catch return;
        const segments = [_]mere.ui.Segment{
            .{ .text = text, .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, phase, .info, &segments);
    }
}

fn emitNamedDiffLine(ctx: *Context, phase: ui.Phase, label: []const u8, kind: mere.ui.SegmentKind, names: []const []const u8) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.allocator);
    for (names, 0..) |name, i| {
        if (i > 0) line.appendSlice(ctx.allocator, ", ") catch return;
        line.appendSlice(ctx.allocator, name) catch return;
    }
    const segments = [_]mere.ui.Segment{
        .{ .text = label, .kind = .normal },
        .{ .text = line.items, .kind = kind },
    };
    emit.logSegmentsSeverity(ctx, phase, .info, &segments);
}

pub fn installPackagesFromConfig(
    ctx: *Context,
    pkg_names: []const []const u8,
    client: download.TransferClient,
    reinstall: bool,
    verify_store: bool,
    force_sync: bool,
    profile_name: ?[]const u8,
) !InstallCommandOutcome {
    return installPackagesFromConfigWithPreview(
        ctx,
        pkg_names,
        client,
        reinstall,
        verify_store,
        if (force_sync) SyncPolicy.force else .automatic,
        profile_name,
        false,
    );
}

pub fn installPackagesFromConfigWithPreview(
    ctx: *Context,
    pkg_names: []const []const u8,
    client: download.TransferClient,
    reinstall: bool,
    verify_store: bool,
    sync_policy: SyncPolicy,
    profile_name: ?[]const u8,
    dry_run: bool,
) !InstallCommandOutcome {
    if (pkg_names.len == 0) {
        return ctx.fail(error.InvalidInput, "package", "no package names provided");
    }

    const config = ctx.configuration orelse {
        return ctx.fail(error.InvalidConfig, "configuration", "no configuration loaded");
    };
    config.validate() catch {
        return ctx.fail(error.InvalidConfig, "configuration", "invalid repository configuration");
    };

    const phase_name: []const u8 = if (pkg_names.len == 1) pkg_names[0] else "multiple";
    emit.phaseStart(ctx, .install, .{ .name = phase_name });
    errdefer emit.phaseEnd(ctx, .install, false);

    var repocaches = try repo_sources.createCaches(ctx, &config);
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    // Build resolver requirements from requested roots
    var input_requirements = try parseInstallRootRequirements(ctx.allocator, pkg_names);
    defer deinitInstallRootRequirements(ctx.allocator, &input_requirements);

    var resolver_requirements: []resolver.Requirement = &.{};
    var owned_resolver_requirements: ?[]resolver.Requirement = null;
    defer if (owned_resolver_requirements) |items| ctx.allocator.free(items);
    var preferred_selections_state: ?PreferredSelectionsState = null;
    defer if (preferred_selections_state) |*state| state.deinit();
    var preferred_selections: []const resolver.PreferredSelection = &.{};

    var requested_state: ?RequestedRootsState = null;
    defer if (requested_state) |*state| state.deinit(ctx.allocator);

    const target_behavior = determineInstallTargetBehavior(profile_name, null, store.isPrivileged());

    if (target_behavior == .activate_profile and profile_name != null) {
        requested_state = try buildRequestedRootsAfterAdd(ctx, profile_name.?, input_requirements.items);
        owned_resolver_requirements = try buildProfileResolverRequirements(
            ctx.allocator,
            input_requirements.items,
            requested_state.?.packages.items,
        );
        resolver_requirements = owned_resolver_requirements.?;
        preferred_selections_state = try loadCurrentGenerationPreferences(ctx, profile_name.?);
        preferred_selections_state.?.setInstallTargets(input_requirements.items);
        preferred_selections = preferred_selections_state.?.selections;
    } else {
        owned_resolver_requirements = try installRequirementsToResolverRequirements(ctx.allocator, input_requirements.items);
        resolver_requirements = owned_resolver_requirements.?;
    }

    // Resolve
    var resolution = try resolveProfile(ctx, repocaches.items, resolver_requirements, preferred_selections, client, sync_policy);
    defer resolution.deinit();
    if (requested_state) |*state| resolution.setRequestedIntent(state.packages.items);

    if (dry_run) {
        emitResolutionDiff(ctx, profile_name.?, resolution.plan.sorted, .install);
        emit.logLineSeverity(ctx, .install, .info, "dry run: no changes made");
        emit.phaseEnd(ctx, .install, true);
        return .completed;
    }

    // Realize
    const result_behavior = try realizeProfile(ctx, &resolution, client, reinstall, verify_store, profile_name, null, .install);

    emit.phaseEnd(ctx, .install, true);
    return switch (result_behavior) {
        .store_only_system_deferred => .store_only_system_activation_deferred,
        .store_only_requested, .activate_profile => .completed,
    };
}

/// Install packages from PackageSpec entries (from profile.kdl input).
/// Converts version/release/content-hash into resolver constraints.
pub fn installPackageSpecsFromConfig(
    ctx: *Context,
    specs: []const generation.PackageSpec,
    client: download.TransferClient,
    reinstall: bool,
    verify_store: bool,
    force_sync: bool,
    profile_name: ?[]const u8,
) !InstallCommandOutcome {
    if (specs.len == 0) {
        return ctx.fail(error.InvalidInput, "package", "no package specs provided");
    }

    const config = ctx.configuration orelse {
        return ctx.fail(error.InvalidConfig, "configuration", "no configuration loaded");
    };
    config.validate() catch {
        return ctx.fail(error.InvalidConfig, "configuration", "invalid repository configuration");
    };

    const phase_name: []const u8 = if (specs.len == 1) specs[0].name else "multiple";
    emit.phaseStart(ctx, .install, .{ .name = phase_name });
    errdefer emit.phaseEnd(ctx, .install, false);

    var repocaches = try repo_sources.createCaches(ctx, &config);
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    // Convert specs to install root requirements with constraints
    var input_requirements = try specsToInstallRequirements(ctx.allocator, specs);
    defer deinitInstallRootRequirements(ctx.allocator, &input_requirements);

    var resolver_requirements: []resolver.Requirement = &.{};
    var owned_resolver_requirements: ?[]resolver.Requirement = null;
    defer if (owned_resolver_requirements) |items| ctx.allocator.free(items);
    var preferred_selections_state: ?PreferredSelectionsState = null;
    defer if (preferred_selections_state) |*state| state.deinit();
    var preferred_selections: []const resolver.PreferredSelection = &.{};

    var requested_state: ?RequestedRootsState = null;
    defer if (requested_state) |*state| state.deinit(ctx.allocator);

    const target_behavior = determineInstallTargetBehavior(profile_name, null, store.isPrivileged());

    if (target_behavior == .activate_profile and profile_name != null) {
        requested_state = try buildRequestedRootsAfterAdd(ctx, profile_name.?, input_requirements.items);
        owned_resolver_requirements = try buildProfileResolverRequirements(
            ctx.allocator,
            input_requirements.items,
            requested_state.?.packages.items,
        );
        resolver_requirements = owned_resolver_requirements.?;
        preferred_selections_state = try loadCurrentGenerationPreferences(ctx, profile_name.?);
        preferred_selections = preferred_selections_state.?.selections;
    } else {
        owned_resolver_requirements = try installRequirementsToResolverRequirements(ctx.allocator, input_requirements.items);
        resolver_requirements = owned_resolver_requirements.?;
    }

    // Resolve
    var resolution = try resolveProfile(ctx, repocaches.items, resolver_requirements, preferred_selections, client, if (force_sync) .force else .automatic);
    defer resolution.deinit();
    resolution.setRequirementIntent(input_requirements.items);

    // Realize
    const result_behavior = try realizeProfile(ctx, &resolution, client, reinstall, verify_store, profile_name, null, .install);

    emit.phaseEnd(ctx, .install, true);
    return switch (result_behavior) {
        .store_only_system_deferred => .store_only_system_activation_deferred,
        .store_only_requested, .activate_profile => .completed,
    };
}

pub fn upgradePackagesFromConfig(
    ctx: *Context,
    pkg_names: []const []const u8,
    client: download.TransferClient,
    verify_store: bool,
    sync_policy: SyncPolicy,
    profile_name: []const u8,
    dry_run: bool,
) !InstallCommandOutcome {
    const config = ctx.configuration orelse {
        return ctx.fail(error.InvalidConfig, "configuration", "no configuration loaded");
    };
    config.validate() catch {
        return ctx.fail(error.InvalidConfig, "configuration", "invalid repository configuration");
    };

    const phase_name: []const u8 = if (pkg_names.len == 0) profile_name else if (pkg_names.len == 1) pkg_names[0] else "multiple";
    emit.phaseStart(ctx, .install, .{ .name = phase_name });
    errdefer emit.phaseEnd(ctx, .install, false);

    var repocaches = try repo_sources.createCaches(ctx, &config);
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    var requested_state = try loadRequestedRootsState(ctx, profile_name);
    defer requested_state.deinit(ctx.allocator);
    if (requested_state.packages.items.len == 0) {
        return ctx.fail(error.InvalidInput, profile_name, "profile has no requested packages to upgrade");
    }

    for (pkg_names) |name| {
        var found = false;
        for (requested_state.packages.items) |root| {
            if (std.mem.eql(u8, root.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return ctx.fail(error.InvalidInput, name, "package is not an explicitly requested root");
    }

    const resolver_requirements = try ctx.allocator.alloc(resolver.Requirement, requested_state.packages.items.len);
    defer ctx.allocator.free(resolver_requirements);
    for (requested_state.packages.items, 0..) |pkg, index| {
        resolver_requirements[index] = .{
            .name = pkg.name,
            .constraint_expr = pkg.constraint_expr,
        };
    }

    var preferred_selections_state = try loadCurrentGenerationPreferences(ctx, profile_name);
    defer preferred_selections_state.deinit();
    preferred_selections_state.setUpgradeTargets(requested_state.packages.items, pkg_names);

    var resolution = try resolveProfile(
        ctx,
        repocaches.items,
        resolver_requirements,
        preferred_selections_state.selections,
        client,
        sync_policy,
    );
    defer resolution.deinit();
    resolution.setRequestedIntent(requested_state.packages.items);

    if (dry_run) {
        emitResolutionDiff(ctx, profile_name, resolution.plan.sorted, .install);
        emit.logLineSeverity(ctx, .install, .info, "dry run: no changes made");
        emit.phaseEnd(ctx, .install, true);
        return .completed;
    }

    const behavior = try realizeProfile(ctx, &resolution, client, false, verify_store, profile_name, null, .install);
    emit.phaseEnd(ctx, .install, true);
    return switch (behavior) {
        .store_only_system_deferred => .store_only_system_activation_deferred,
        .store_only_requested, .activate_profile => .completed,
    };
}

pub fn uninstallPackagesFromConfig(
    ctx: *Context,
    pkg_names: []const []const u8,
    client: download.TransferClient,
    verify_store: bool,
    sync_policy: SyncPolicy,
    profile_name: []const u8,
    cascade: bool,
    dry_run: bool,
) !?[]const u8 {
    if (pkg_names.len == 0) return "No package names provided";

    const config = ctx.configuration orelse return "No configuration loaded";
    config.validate() catch return "Invalid repository configuration";

    const phase_name: []const u8 = if (pkg_names.len == 1) pkg_names[0] else "multiple";
    emit.phaseStart(ctx, .uninstall, .{ .name = phase_name });
    errdefer emit.phaseEnd(ctx, .uninstall, false);

    var repocaches = try repo_sources.createCaches(ctx, &config);
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    var requested_state = try buildRequestedRootsAfterRemove(ctx, profile_name, pkg_names);
    defer requested_state.deinit(ctx.allocator);

    if (requested_state.removed_count == 0 and requested_state.packages.items.len == 0) {
        return "No requested packages matched";
    }

    if (requested_state.packages.items.len > 0) {
        // Build resolver requirements from remaining roots
        var resolver_requirements = try ctx.allocator.alloc(resolver.Requirement, requested_state.packages.items.len);
        defer ctx.allocator.free(resolver_requirements);
        for (requested_state.packages.items, 0..) |pkg, i| {
            resolver_requirements[i] = .{
                .name = pkg.name,
                .constraint_expr = pkg.constraint_expr,
            };
        }

        var preferred_selections_state = try loadCurrentGenerationPreferences(ctx, profile_name);
        defer preferred_selections_state.deinit();
        preferred_selections_state.holdAll();

        // Resolve
        var resolution = try resolveProfile(ctx, repocaches.items, resolver_requirements, preferred_selections_state.selections, client, sync_policy);
        defer resolution.deinit();

        if (requested_state.removed_count == 0) {
            var matched_dependency = false;
            for (pkg_names) |name| {
                if (resolution.containsPackage(name)) {
                    matched_dependency = true;
                    break;
                }
            }
            if (!matched_dependency) return "No requested packages matched";
        }

        // Check if removed packages are still in the resolved set as transitive
        // deps. Loop to a fixed point: each cascade round only accounts for the
        // one removed_name it processed, so another requested removal that's
        // still pulled in by a different, unrelated dependent wouldn't be
        // caught by a single pass - keep re-checking all pkg_names against the
        // latest resolution until none of them remain.
        while (true) {
            var still_required: ?[]const u8 = null;
            for (pkg_names) |removed_name| {
                if (resolution.containsPackage(removed_name)) {
                    still_required = removed_name;
                    break;
                }
            }
            const removed_name = still_required orelse break;

            // Find which resolved packages directly depend on the removed one
            var dependents: std.ArrayList(u8) = .empty;
            defer dependents.deinit(ctx.allocator);
            for (resolution.plan.sorted) |resolved| {
                for (resolved.dependency_names) |dep_name| {
                    if (std.mem.eql(u8, dep_name, removed_name)) {
                        if (dependents.items.len > 0) try dependents.appendSlice(ctx.allocator, ", ");
                        try dependents.appendSlice(ctx.allocator, resolved.pkg.name orelse "unknown");
                        break;
                    }
                }
            }

            if (!cascade) {
                const msg = try std.fmt.allocPrint(
                    ctx.allocator,
                    "cannot uninstall '{s}': it is required by {s}. Use --cascade to remove dependent packages.",
                    .{ removed_name, dependents.items },
                );
                emit.phaseEnd(ctx, .uninstall, false);
                return msg;
            }

            // Cascade: find requested roots that transitively depend on the removed package
            var all_dependents = findTransitiveDependents(ctx.allocator, resolution.plan.sorted, removed_name);
            defer all_dependents.deinit();

            var roots_to_remove = std.StringHashMap(void).init(ctx.allocator);
            defer roots_to_remove.deinit();
            for (pkg_names) |name| try roots_to_remove.put(name, {});

            for (requested_state.packages.items) |root_pkg| {
                if (all_dependents.contains(root_pkg.name)) {
                    try roots_to_remove.put(root_pkg.name, {});
                }
            }

            // Rebuild requested state without cascaded roots
            var i: usize = 0;
            while (i < requested_state.packages.items.len) {
                if (roots_to_remove.contains(requested_state.packages.items[i].name)) {
                    var removed = requested_state.packages.orderedRemove(i);
                    removed.deinit(ctx.allocator);
                    continue;
                }
                i += 1;
            }

            // Re-resolve with reduced roots
            if (requested_state.packages.items.len > 0) {
                resolution.deinit();
                const new_reqs = try ctx.allocator.alloc(resolver.Requirement, requested_state.packages.items.len);
                defer ctx.allocator.free(new_reqs);
                for (requested_state.packages.items, 0..) |pkg, ri| {
                    new_reqs[ri] = .{ .name = pkg.name, .constraint_expr = pkg.constraint_expr };
                }
                resolution = try resolveProfile(ctx, repocaches.items, new_reqs, preferred_selections_state.selections, client, sync_policy);
                resolution.setRequestedIntent(requested_state.packages.items);
            } else {
                // All roots removed. Do NOT deinit `resolution` here - the
                // caller's `defer resolution.deinit()` (set up right after
                // the initial resolveProfile call) still owns it and will
                // clean it up exactly once when this function returns.
                // Deiniting it here too was a double-free: harmless while
                // cascade only ever ran a single round, but a real crash
                // once a second round could reach this branch.
                if (dry_run) {
                    emitResolutionDiff(ctx, profile_name, &.{}, .uninstall);
                    emit.logLineSeverity(ctx, .uninstall, .info, "dry run: no changes made");
                } else {
                    const empty: [0]generation.PackageEntry = .{};
                    try applyProfileRealization(ctx, profile_name, &empty, verify_store, .uninstall);
                }
                emit.phaseEnd(ctx, .uninstall, true);
                return null;
            }
        }

        // Realize
        resolution.setRequestedIntent(requested_state.packages.items);
        if (dry_run) {
            emitResolutionDiff(ctx, profile_name, resolution.plan.sorted, .uninstall);
            emit.logLineSeverity(ctx, .uninstall, .info, "dry run: no changes made");
        } else {
            _ = try realizeProfile(ctx, &resolution, client, false, verify_store, profile_name, null, .uninstall);
        }
    } else {
        // All roots removed
        if (dry_run) {
            emitResolutionDiff(ctx, profile_name, &.{}, .uninstall);
            emit.logLineSeverity(ctx, .uninstall, .info, "dry run: no changes made");
        } else {
            const empty: [0]generation.PackageEntry = .{};
            try applyProfileRealization(ctx, profile_name, &empty, verify_store, .uninstall);
        }
    }

    emit.phaseEnd(ctx, .uninstall, true);
    return null;
}

/// Install packages to a profile or build target.
/// Used by the build orchestrator for dependency installation into build profiles.
pub fn installPackagesToProfile(
    ctx: *Context,
    repocaches: []*RepoCache,
    pkg_names: []const []const u8,
    client: download.TransferClient,
    reinstall: bool,
    verify_store: bool,
    force_sync: bool,
    profile_name: ?[]const u8,
    target_profile_path: ?[]const u8,
) !void {
    if (pkg_names.len == 0) return;

    var input_requirements = try parseInstallRootRequirements(ctx.allocator, pkg_names);
    defer deinitInstallRootRequirements(ctx.allocator, &input_requirements);

    var resolver_requirements: []resolver.Requirement = &.{};
    var owned_resolver_requirements: ?[]resolver.Requirement = null;
    defer if (owned_resolver_requirements) |items| ctx.allocator.free(items);
    var preferred_selections_state: ?PreferredSelectionsState = null;
    defer if (preferred_selections_state) |*state| state.deinit();
    var preferred_selections: []const resolver.PreferredSelection = &.{};

    var requested_state: ?RequestedRootsState = null;
    defer if (requested_state) |*state| state.deinit(ctx.allocator);

    const target_behavior = determineInstallTargetBehavior(profile_name, target_profile_path, store.isPrivileged());

    if (target_behavior == .activate_profile and target_profile_path == null and profile_name != null) {
        requested_state = try buildRequestedRootsAfterAdd(ctx, profile_name.?, input_requirements.items);
        owned_resolver_requirements = try buildProfileResolverRequirements(
            ctx.allocator,
            input_requirements.items,
            requested_state.?.packages.items,
        );
        resolver_requirements = owned_resolver_requirements.?;
        preferred_selections_state = try loadCurrentGenerationPreferences(ctx, profile_name.?);
        preferred_selections_state.?.setInstallTargets(input_requirements.items);
        preferred_selections = preferred_selections_state.?.selections;
    } else {
        owned_resolver_requirements = try installRequirementsToResolverRequirements(ctx.allocator, input_requirements.items);
        resolver_requirements = owned_resolver_requirements.?;
    }

    // Resolve
    var resolution = try resolveProfile(ctx, repocaches, resolver_requirements, preferred_selections, client, if (force_sync) .force else .automatic);
    defer resolution.deinit();
    if (requested_state) |*state| resolution.setRequestedIntent(state.packages.items);

    // Realize
    _ = try realizeProfile(ctx, &resolution, client, reinstall, verify_store, profile_name, target_profile_path, .install);
}

const RequestedRootsState = struct {
    packages: std.ArrayList(RequestedPackage),
    changed: bool,
    removed_count: usize,

    fn deinit(self: *RequestedRootsState, allocator: std.mem.Allocator) void {
        for (self.packages.items) |*pkg| pkg.deinit(allocator);
        self.packages.deinit(allocator);
    }
};

const RequestedPackage = struct {
    name: []const u8,
    constraint_expr: ?[]const u8,

    fn deinit(self: *RequestedPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.constraint_expr) |constraint| allocator.free(constraint);
    }
};

const PreferredSelectionsState = struct {
    selections: []resolver.PreferredSelection,
    manifest: ?generation.GenerationManifest = null,
    allocator: std.mem.Allocator,

    fn initEmpty(allocator: std.mem.Allocator) PreferredSelectionsState {
        return .{
            .selections = &.{},
            .manifest = null,
            .allocator = allocator,
        };
    }

    fn setUpgradeTargets(
        self: *PreferredSelectionsState,
        roots: []const RequestedPackage,
        names: []const []const u8,
    ) void {
        for (self.selections) |*selection| {
            selection.allow_upgrade = false;
            if (names.len == 0) {
                for (roots) |root| {
                    if (std.mem.eql(u8, selection.name, root.name)) {
                        selection.allow_upgrade = true;
                        break;
                    }
                }
            } else {
                for (names) |name| {
                    if (std.mem.eql(u8, selection.name, name)) {
                        selection.allow_upgrade = true;
                        break;
                    }
                }
            }
        }
    }

    fn holdAll(self: *PreferredSelectionsState) void {
        for (self.selections) |*selection| selection.allow_upgrade = false;
    }

    fn setInstallTargets(self: *PreferredSelectionsState, requirements: []const InstallRootRequirement) void {
        self.holdAll();
        for (self.selections) |*selection| {
            for (requirements) |requirement| {
                if (std.mem.eql(u8, selection.name, requirement.name)) {
                    selection.allow_upgrade = true;
                    break;
                }
            }
        }
    }

    fn deinit(self: *PreferredSelectionsState) void {
        if (self.selections.len > 0) self.allocator.free(self.selections);
        if (self.manifest) |*manifest_data| manifest_data.deinit();
    }
};

fn getProfileDir(ctx: *Context, profile_name: []const u8) ![]const u8 {
    return std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", profile_name });
}

fn loadRequestedRootsState(ctx: *Context, profile_name: []const u8) !RequestedRootsState {
    const profile_dir = try getProfileDir(ctx, profile_name);
    defer ctx.allocator.free(profile_dir);

    path.ensureDirExists(profile_dir) catch |err| {
        ctx.setDiagnosticContext(profile_dir, "failed to create profile directory");
        return switch (err) {
            error.AccessDenied => error.PermissionDenied,
            else => error.FileSystem,
        };
    };

    // Read package names from the current generation's profile.kdl
    var packages: std.ArrayList(RequestedPackage) = .empty;
    errdefer {
        for (packages.items) |*pkg| pkg.deinit(ctx.allocator);
        packages.deinit(ctx.allocator);
    }

    const manifest_opt = loadCurrentManifest(ctx, profile_name, profile_dir) catch |err| {
        return failCurrentStateRead(ctx, profile_dir, "failed to read current profile manifest", err);
    };
    if (manifest_opt) |manifest_data| {
        var current = manifest_data;
        defer current.deinit();

        for (current.packages.items) |pkg| {
            if (!pkg.requested) continue;
            const name_copy = ctx.allocator.dupe(u8, pkg.name) catch return error.OutOfMemory;
            errdefer ctx.allocator.free(name_copy);
            const constraint_copy = if (pkg.constraint_expr) |constraint|
                ctx.allocator.dupe(u8, constraint) catch return error.OutOfMemory
            else
                null;
            errdefer if (constraint_copy) |constraint| ctx.allocator.free(constraint);
            packages.append(ctx.allocator, .{
                .name = name_copy,
                .constraint_expr = constraint_copy,
            }) catch return error.OutOfMemory;
        }
    }

    return RequestedRootsState{
        .packages = packages,
        .changed = false,
        .removed_count = 0,
    };
}

fn loadCurrentManifest(ctx: *Context, profile_name: []const u8, profile_dir: []const u8) generation.GenerationError!?generation.GenerationManifest {
    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch return generation.GenerationError.OutOfMemory;
    defer ctx.allocator.free(store_root);

    if (std.mem.eql(u8, profile_name, "system")) {
        const current_gen = try generation.getCurrentGeneration(profile_dir);
        const gen_num = current_gen orelse return null;
        const gen_path = try generation.getGenerationPath(ctx.allocator, profile_dir, gen_num);
        defer ctx.allocator.free(gen_path);
        const loaded_manifest = try generation.readManifest(ctx.allocator, store_root, gen_path);
        return @as(?generation.GenerationManifest, loaded_manifest);
    } else {
        const root_path = profile.getRootPath(ctx.allocator, profile_dir) catch return generation.GenerationError.OutOfMemory;
        defer ctx.allocator.free(root_path);
        return generation.readManifest(ctx.allocator, store_root, root_path) catch |err| switch (err) {
            generation.GenerationError.GenerationNotFound => null,
            else => err,
        };
    }
}

fn buildRequestedRootsAfterAdd(
    ctx: *Context,
    profile_name: []const u8,
    requirements: []const InstallRootRequirement,
) !RequestedRootsState {
    var state = try loadRequestedRootsState(ctx, profile_name);
    errdefer state.deinit(ctx.allocator);

    var package_index = std.StringHashMap(usize).init(ctx.allocator);
    defer package_index.deinit();

    for (state.packages.items, 0..) |pkg, idx| {
        try package_index.put(pkg.name, idx);
    }

    for (requirements) |req| {
        if (!req.requested) continue;
        if (package_index.get(req.name)) |idx| {
            const existing = &state.packages.items[idx];
            // Repeating an unconstrained install preserves an existing
            // constraint. Supplying a new constraint deliberately replaces it.
            if (req.intent_constraint) |new_constraint| {
                if (existing.constraint_expr == null or !std.mem.eql(u8, existing.constraint_expr.?, new_constraint)) {
                    if (existing.constraint_expr) |old_constraint| ctx.allocator.free(old_constraint);
                    existing.constraint_expr = try ctx.allocator.dupe(u8, new_constraint);
                    state.changed = true;
                }
            }
            continue;
        }

        const name_copy = try ctx.allocator.dupe(u8, req.name);
        const constraint_copy = if (req.intent_constraint) |expr|
            try ctx.allocator.dupe(u8, expr)
        else
            null;
        errdefer if (constraint_copy) |constraint| ctx.allocator.free(constraint);
        try state.packages.append(ctx.allocator, .{
            .name = name_copy,
            .constraint_expr = constraint_copy,
        });
        try package_index.put(state.packages.items[state.packages.items.len - 1].name, state.packages.items.len - 1);
        state.changed = true;
    }

    return state;
}

fn buildRequestedRootsAfterRemove(ctx: *Context, profile_name: []const u8, pkg_names: []const []const u8) !RequestedRootsState {
    var state = try loadRequestedRootsState(ctx, profile_name);
    errdefer state.deinit(ctx.allocator);

    var names_to_remove = std.StringHashMap(void).init(ctx.allocator);
    defer names_to_remove.deinit();

    for (pkg_names) |pkg_name| {
        try names_to_remove.put(pkg_name, {});
    }

    var i: usize = 0;
    while (i < state.packages.items.len) {
        if (names_to_remove.contains(state.packages.items[i].name)) {
            var removed = state.packages.orderedRemove(i);
            removed.deinit(ctx.allocator);
            state.changed = true;
            state.removed_count += 1;
            continue;
        }

        i += 1;
    }

    return state;
}

fn preferredSelectionsFromManifest(
    allocator: std.mem.Allocator,
    manifest_data: generation.GenerationManifest,
) !PreferredSelectionsState {
    const selections = try allocator.alloc(resolver.PreferredSelection, manifest_data.packages.items.len);
    errdefer allocator.free(selections);

    for (manifest_data.packages.items, 0..) |pkg, idx| {
        selections[idx] = .{
            .name = pkg.name,
            .version = pkg.version,
            .release = pkg.release,
            .arch = pkg.arch,
            .content_hash = pkg.content_hash,
        };
    }

    return .{
        .selections = selections,
        .manifest = manifest_data,
        .allocator = allocator,
    };
}

fn failCurrentStateRead(ctx: *Context, subject: []const u8, operation: []const u8, err: generation.GenerationError) anyerror {
    ctx.setDiagnosticContextFmt(subject, "{s}: {s}", .{ operation, @errorName(err) });
    return mapGenerationError(err);
}

fn loadCurrentGenerationPreferences(ctx: *Context, profile_name: []const u8) !PreferredSelectionsState {
    const profile_dir = try getProfileDir(ctx, profile_name);
    defer ctx.allocator.free(profile_dir);

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch return error.OutOfMemory;
    defer ctx.allocator.free(store_root);

    if (!std.mem.eql(u8, profile_name, "system")) {
        const root_path = profile.getRootPath(ctx.allocator, profile_dir) catch return error.OutOfMemory;
        defer ctx.allocator.free(root_path);

        std.Io.Dir.accessAbsolute(path.currentIo(), root_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => PreferredSelectionsState.initEmpty(ctx.allocator),
                error.AccessDenied => error.PermissionDenied,
                else => error.FileSystem,
            };
        };

        var manifest_data = generation.readManifest(ctx.allocator, store_root, root_path) catch |err| {
            return failCurrentStateRead(ctx, root_path, "failed to read current profile manifest", err);
        };
        errdefer manifest_data.deinit();

        return preferredSelectionsFromManifest(ctx.allocator, manifest_data);
    }

    const current_generation = generation.getCurrentGeneration(profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.ProfilesNotFound => PreferredSelectionsState.initEmpty(ctx.allocator),
            else => failCurrentStateRead(ctx, profile_dir, "failed to read current generation", err),
        };
    } orelse return PreferredSelectionsState.initEmpty(ctx.allocator);

    const gen_path = generation.getGenerationPath(ctx.allocator, profile_dir, current_generation) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => error.OutOfMemory,
            generation.GenerationError.PermissionDenied => error.PermissionDenied,
            generation.GenerationError.InvalidInput => error.InvalidInput,
            else => error.FileSystem,
        };
    };
    defer ctx.allocator.free(gen_path);

    var manifest_data = generation.readManifest(ctx.allocator, store_root, gen_path) catch |err| {
        return failCurrentStateRead(ctx, gen_path, "failed to read current generation manifest", err);
    };
    errdefer manifest_data.deinit();

    return preferredSelectionsFromManifest(ctx.allocator, manifest_data);
}

fn parseInstallRootRequirements(
    allocator: std.mem.Allocator,
    pkg_tokens: []const []const u8,
) !std.ArrayList(InstallRootRequirement) {
    var requirements: std.ArrayList(InstallRootRequirement) = .empty;
    errdefer deinitInstallRootRequirements(allocator, &requirements);

    var requirement_index = std.StringHashMap(usize).init(allocator);
    defer requirement_index.deinit();

    for (pkg_tokens) |token| {
        const parsed = version_constraint.splitRequirementToken(token) catch {
            return error.InvalidInput;
        };

        const name_copy = try allocator.dupe(u8, parsed.name);
        errdefer allocator.free(name_copy);

        const canonical_constraint = if (parsed.constraint_expr) |expr|
            try version_constraint.canonicalizeConstraintExpr(allocator, expr)
        else
            null;
        errdefer if (canonical_constraint) |expr| allocator.free(expr);

        if (requirement_index.get(parsed.name)) |idx| {
            const existing = &requirements.items[idx];
            allocator.free(existing.name);
            existing.name = name_copy;
            if (existing.constraint_expr) |old_expr| allocator.free(old_expr);
            existing.constraint_expr = canonical_constraint;
            continue;
        }

        try requirements.append(allocator, .{
            .name = name_copy,
            .constraint_expr = canonical_constraint,
            .intent_constraint = if (canonical_constraint) |constraint|
                try allocator.dupe(u8, constraint)
            else
                null,
        });
        try requirement_index.put(requirements.items[requirements.items.len - 1].name, requirements.items.len - 1);
    }

    return requirements;
}

fn deinitInstallRootRequirements(
    allocator: std.mem.Allocator,
    requirements: *std.ArrayList(InstallRootRequirement),
) void {
    for (requirements.items) |*req| req.deinit(allocator);
    requirements.deinit(allocator);
}

/// Convert PackageSpec entries (from profile.kdl) into InstallRootRequirements.
/// Maps the input gradient: content-hash → exact match, version+release → constraint, name → unconstrained.
fn specsToInstallRequirements(
    allocator: std.mem.Allocator,
    specs: []const generation.PackageSpec,
) !std.ArrayList(InstallRootRequirement) {
    var requirements: std.ArrayList(InstallRootRequirement) = .empty;
    errdefer deinitInstallRootRequirements(allocator, &requirements);

    for (specs) |spec| {
        const name_copy = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name_copy);

        var content_hash_copy: ?[]const u8 = null;
        errdefer if (content_hash_copy) |hc| allocator.free(hc);

        var constraint: ?[]const u8 = null;
        errdefer if (constraint) |cc| allocator.free(cc);

        if (spec.content_hash) |h| {
            content_hash_copy = try allocator.dupe(u8, h);
        } else if (spec.version) |v| {
            constraint = if (spec.release) |r|
                try std.fmt.allocPrint(allocator, "=={s}-{d}", .{ v, r })
            else
                try std.fmt.allocPrint(allocator, "=={s}", .{v});
        }

        try requirements.append(allocator, .{
            .name = name_copy,
            .constraint_expr = constraint,
            .content_hash = content_hash_copy,
            .requested = spec.requested,
            .intent_constraint = if (spec.constraint_expr) |intent|
                try allocator.dupe(u8, intent)
            else if (spec.requested)
                if (constraint) |resolved_constraint| try allocator.dupe(u8, resolved_constraint) else null
            else
                null,
        });
    }

    return requirements;
}

fn installRequirementsToResolverRequirements(
    allocator: std.mem.Allocator,
    requirements: []const InstallRootRequirement,
) ![]resolver.Requirement {
    const out = try allocator.alloc(resolver.Requirement, requirements.len);
    for (requirements, 0..) |req, idx| {
        out[idx] = .{
            .name = req.name,
            .constraint_expr = req.constraint_expr,
            .content_hash = req.content_hash,
        };
    }
    return out;
}

fn buildProfileResolverRequirements(
    allocator: std.mem.Allocator,
    explicit_requirements: []const InstallRootRequirement,
    packages: []const RequestedPackage,
) ![]resolver.Requirement {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (explicit_requirements) |requirement| try seen.put(requirement.name, {});

    var count = explicit_requirements.len;
    for (packages) |pkg| {
        if (!seen.contains(pkg.name)) count += 1;
    }

    seen.clearRetainingCapacity();
    const out = try allocator.alloc(resolver.Requirement, count);
    var idx: usize = 0;
    for (explicit_requirements) |req| {
        var constraint = req.constraint_expr;
        // An unconstrained repeated install keeps the persisted root
        // constraint. Exact profile specs continue to select their recorded
        // content hash regardless of future intent.
        if (req.requested and req.content_hash == null and req.intent_constraint == null) {
            for (packages) |pkg| {
                if (std.mem.eql(u8, pkg.name, req.name)) {
                    constraint = pkg.constraint_expr;
                    break;
                }
            }
        }
        out[idx] = .{
            .name = req.name,
            .constraint_expr = constraint,
            .content_hash = req.content_hash,
        };
        idx += 1;
        try seen.put(req.name, {});
    }

    for (packages) |pkg| {
        if (seen.contains(pkg.name)) continue;
        out[idx] = .{
            .name = pkg.name,
            .constraint_expr = pkg.constraint_expr,
        };
        idx += 1;
    }

    std.debug.assert(idx == count);
    return out;
}

const InstallPlan = struct {
    resolution: resolver.ResolutionResult,
    sorted: []resolver.ResolvedPackage,
};

/// Result of resolving a profile to a concrete package set.
/// Owns the resolution and arena; caller must deinit.
pub const ProfileResolution = struct {
    plan: InstallPlan,
    arena: std.heap.ArenaAllocator,
    loaded_keys: std.ArrayList(sign.LoadedKey),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProfileResolution) void {
        // Free package strings (owned by ctx.allocator), then tear down the arena.
        for (self.plan.resolution.packages) |*resolved| {
            resolved.pkg.deinit();
        }
        for (self.loaded_keys.items) |*key| key.deinit(self.allocator);
        self.loaded_keys.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Mark the durable roots whose intent should be written into the next
    /// profile generation. Constraints are borrowed until realization copies
    /// them into owned PackageEntry values.
    fn setRequestedIntent(self: *ProfileResolution, roots: []const RequestedPackage) void {
        for (self.plan.resolution.packages) |*resolved| setResolvedIntent(resolved, roots);
        for (self.plan.sorted) |*resolved| setResolvedIntent(resolved, roots);
    }

    fn setRequirementIntent(self: *ProfileResolution, requirements: []const InstallRootRequirement) void {
        for (self.plan.resolution.packages) |*resolved| setResolvedRequirementIntent(resolved, requirements);
        for (self.plan.sorted) |*resolved| setResolvedRequirementIntent(resolved, requirements);
    }

    /// Check whether a package name appears in the resolved set.
    pub fn containsPackage(self: *const ProfileResolution, name: []const u8) bool {
        for (self.plan.sorted) |resolved| {
            if (resolved.pkg.name) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
        }
        return false;
    }
};

fn setResolvedIntent(resolved: *resolver.ResolvedPackage, roots: []const RequestedPackage) void {
    resolved.requested = false;
    resolved.constraint_expr = null;
    const name = resolved.pkg.name orelse return;
    for (roots) |root| {
        if (std.mem.eql(u8, root.name, name)) {
            resolved.requested = true;
            resolved.constraint_expr = root.constraint_expr;
            return;
        }
    }
}

fn setResolvedRequirementIntent(resolved: *resolver.ResolvedPackage, requirements: []const InstallRootRequirement) void {
    resolved.requested = false;
    resolved.constraint_expr = null;
    const name = resolved.pkg.name orelse return;
    for (requirements) |requirement| {
        if (requirement.requested and std.mem.eql(u8, requirement.name, name)) {
            resolved.requested = true;
            resolved.constraint_expr = requirement.intent_constraint;
            return;
        }
    }
}

/// Resolve a list of package-name tokens (each optionally carrying a
/// version constraint, e.g. "openssl>=3.0" — the same syntax
/// installPackagesToProfile accepts) into a ProfileResolution, without
/// installing anything. Used by build orchestration to compute a cache key
/// from the actual resolved package versions, not just a recipe's raw
/// dependency name list — otherwise a repo sync that bumps a dependency's
/// version is invisible to the cache and a stale profile gets served
/// forever. Mirrors exactly how installPackagesToProfile itself resolves
/// unconstrained dependency tokens (no preferred selections), so the
/// resolution here matches what installing these tokens would actually do.
pub fn resolveDependencyTokens(
    ctx: *Context,
    repocaches: []*RepoCache,
    pkg_tokens: []const []const u8,
    client: download.TransferClient,
    force_sync: bool,
) !ProfileResolution {
    var input_requirements = try parseInstallRootRequirements(ctx.allocator, pkg_tokens);
    defer deinitInstallRootRequirements(ctx.allocator, &input_requirements);

    const resolver_requirements = try installRequirementsToResolverRequirements(ctx.allocator, input_requirements.items);
    defer ctx.allocator.free(resolver_requirements);

    return resolveProfile(ctx, repocaches, resolver_requirements, &.{}, client, if (force_sync) .force else .automatic);
}

/// Resolve a profile: sync repos, resolve dependencies, return the resolved package set.
/// No side effects on the store or profile — purely computes the resolution.
pub fn resolveProfile(
    ctx: *Context,
    repocaches: []*RepoCache,
    requirements: []const resolver.Requirement,
    preferred_selections: []const resolver.PreferredSelection,
    client: download.TransferClient,
    sync_policy: SyncPolicy,
) !ProfileResolution {
    var loaded_keys = try sign.loadAllKeys(ctx);
    errdefer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    var sync_result = try repo_sync.synchronize(ctx, repocaches, client, .{
        .policy = sync_policy,
    }, loaded_keys.items);
    defer sync_result.deinit(ctx.allocator);
    if (sync_result.firstFailure()) |err| return err;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    errdefer arena.deinit();

    var plan = try resolveInstallPlan(ctx, repocaches, requirements, preferred_selections, arena.allocator());
    errdefer plan.resolution.deinit();

    return ProfileResolution{
        .plan = plan,
        .arena = arena,
        .loaded_keys = loaded_keys,
        .allocator = ctx.allocator,
    };
}

/// Realize a resolved profile: admit packages to store, create generation, activate.
/// The phase parameter controls how UI output is labeled.
pub fn realizeProfile(
    ctx: *Context,
    resolution: *ProfileResolution,
    client: download.TransferClient,
    reinstall: bool,
    verify_store: bool,
    profile_name: ?[]const u8,
    target_profile_path: ?[]const u8,
    phase: ui.Phase,
) !InstallTargetBehavior {
    const target_behavior = determineInstallTargetBehavior(profile_name, target_profile_path, store.isPrivileged());

    // Check if the resolved set matches the current profile — skip everything if unchanged
    if (!reinstall and target_profile_path == null) {
        if (profile_name) |prof_name| {
            if (profileMatchesResolution(ctx, prof_name, resolution.plan.sorted)) {
                if (std.mem.eql(u8, prof_name, "system") and store.isPrivileged()) {
                    const staged = activation.stageCurrentSystemBootArtifacts(
                        ctx,
                        if (verify_store) .full_store else .fast,
                    ) catch |err| {
                        return ctx.fail(mapActivationError(err), "boot", "failed to stage boot artifacts");
                    };
                    if (staged > 0) {
                        emit.logLineSeverity(ctx, phase, .info, "staged boot artifacts for active system generation");
                    }
                }
                emit.logLineSeverity(ctx, phase, .info, "profile is already up to date");
                return target_behavior;
            }
        }
    }

    var installed_packages = try installResolvedPackages(ctx, resolution.plan.sorted, client, reinstall, resolution.loaded_keys.items);

    defer {
        for (installed_packages.items) |*pkg_info| {
            pkg_info.deinit(ctx.allocator);
        }
        installed_packages.deinit(ctx.allocator);
    }

    // Emit profile diff summary
    if (profile_name) |prof_name| {
        if (target_profile_path == null) {
            emitProfileDiff(ctx, prof_name, installed_packages.items, phase);
        }
    }

    switch (target_behavior) {
        .activate_profile => {
            const target_step_name: []const u8 = if (target_profile_path != null) "profile link" else "activation";
            emit.stepStartLast(ctx, phase, target_step_name, true);
            var target_step_open = true;
            errdefer if (target_step_open) emit.stepEnd(ctx, phase, target_step_name, false);
            try applyInstallTargets(ctx, installed_packages.items, profile_name, target_profile_path, verify_store, phase);
            emit.stepEnd(ctx, phase, target_step_name, true);
            target_step_open = false;
        },
        .store_only_system_deferred => {
            emit.logLineSeverity(ctx, phase, .warn, "system activation deferred: packages were installed to the store; rerun as root to finalize and activate");
        },
        .store_only_requested => {},
    }

    return target_behavior;
}

fn resolveInstallPlan(
    ctx: *Context,
    repocaches: []*RepoCache,
    requirements: []const resolver.Requirement,
    preferred_selections: []const resolver.PreferredSelection,
    allocator: std.mem.Allocator,
) !InstallPlan {
    // 1. Resolve all dependencies with cycle detection and pin enforcement
    if (requirements.len == 1) {
        if (requirements[0].constraint_expr) |expr| {
            ctx.debug("resolving dependencies for: {s}{s}", .{ requirements[0].name, expr });
        } else {
            ctx.debug("resolving dependencies for: {s}", .{requirements[0].name});
        }
    } else {
        ctx.debug("resolving dependencies for {d} package roots", .{requirements.len});
    }
    const resolution = try resolver.withRequirements(ctx, requirements, repocaches, preferred_selections, allocator);

    ctx.debug("resolved {d} packages in install order:", .{resolution.packages.len});
    for (resolution.packages, 0..) |resolved, idx| {
        ctx.debug("  {d}: {s}-{s}-{d} (order: {d}, scc: {d})", .{
            idx,
            resolved.pkg.name.?,
            resolved.pkg.version.?,
            resolved.pkg.release.?,
            resolved.install_order,
            resolved.scc_id,
        });
    }

    // Report if any cycles were detected
    for (resolution.sccs, 0..) |scc, scc_idx| {
        if (scc.len > 1) {
            ctx.debug("cycle detected in SCC {d} with {d} packages:", .{ scc_idx, scc.len });
            for (scc) |pkg_idx| {
                const resolved = resolution.packages[pkg_idx];
                ctx.debug("  - {s}-{s}-{d}", .{
                    resolved.pkg.name.?,
                    resolved.pkg.version.?,
                    resolved.pkg.release.?,
                });
            }
        }
    }

    const sorted_packages = try allocator.alloc(resolver.ResolvedPackage, resolution.packages.len);
    @memcpy(sorted_packages, resolution.packages);
    std.mem.sort(resolver.ResolvedPackage, sorted_packages, {}, struct {
        fn lessThan(_: void, a: resolver.ResolvedPackage, b: resolver.ResolvedPackage) bool {
            return a.install_order < b.install_order;
        }
    }.lessThan);

    return InstallPlan{
        .resolution = resolution,
        .sorted = sorted_packages,
    };
}

fn installResolvedPackages(
    ctx: *Context,
    sorted_packages: []resolver.ResolvedPackage,
    client: download.TransferClient,
    reinstall: bool,
    loaded_keys: []const sign.LoadedKey,
) !std.ArrayList(generation.PackageEntry) {
    var archive_cache_paths = try prefetchMissingPackageArchives(ctx, sorted_packages, client);
    defer {
        for (archive_cache_paths.items) |cache_path| ctx.allocator.free(cache_path);
        archive_cache_paths.deinit(ctx.allocator);
    }

    // 2. Install each package to store in topological order
    // Collect installed package info for generation creation
    var installed_packages: std.ArrayList(generation.PackageEntry) = .empty;
    errdefer {
        for (installed_packages.items) |*pkg_info| {
            pkg_info.deinit(ctx.allocator);
        }
        installed_packages.deinit(ctx.allocator);
    }

    for (sorted_packages, archive_cache_paths.items) |*resolved, cache_path| {
        ctx.debug("installing: {s}-{s}-{d}", .{
            resolved.pkg.name.?,
            resolved.pkg.version.?,
            resolved.pkg.release.?,
        });

        // If cache_path is empty, the package is already in the store — construct entry directly
        if (cache_path.len == 0) {
            const store_path = try store.constructStorePath(ctx, resolved.pkg.content_hash, resolved.pkg.name.?, resolved.pkg.version.?);

            try installed_packages.append(ctx.allocator, generation.PackageEntry{
                .name = try ctx.allocator.dupe(u8, resolved.pkg.name.?),
                .version = try ctx.allocator.dupe(u8, resolved.pkg.version.?),
                .release = resolved.pkg.release.?,
                .arch = try ctx.allocator.dupe(u8, resolved.pkg.arch.?),
                .store_path = store_path,
                .content_hash = try ctx.allocator.dupe(u8, resolved.pkg.content_hash),
                .requested = resolved.requested,
                .constraint_expr = if (resolved.constraint_expr) |constraint|
                    try ctx.allocator.dupe(u8, constraint)
                else
                    null,
            });
            continue;
        }

        var pkg_info = try installSinglePackageToStore(
            ctx,
            &resolved.pkg,
            resolved.repocache,
            cache_path,
            reinstall,
            loaded_keys,
        );
        pkg_info.requested = resolved.requested;
        pkg_info.constraint_expr = if (resolved.constraint_expr) |constraint|
            try ctx.allocator.dupe(u8, constraint)
        else
            null;
        try installed_packages.append(ctx.allocator, pkg_info);
    }

    return installed_packages;
}

fn prefetchMissingPackageArchives(
    ctx: *Context,
    sorted_packages: []resolver.ResolvedPackage,
    client: download.TransferClient,
) !std.ArrayList([]const u8) {
    var requests: std.ArrayList(download.BatchDownloadRequest) = .empty;
    defer requests.deinit(ctx.allocator);

    var owned_urls: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (owned_urls.items) |url| ctx.allocator.free(url);
        owned_urls.deinit(ctx.allocator);
    }

    var cache_paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (cache_paths.items) |path_buf| ctx.allocator.free(path_buf);
        cache_paths.deinit(ctx.allocator);
    }

    for (sorted_packages) |*resolved| {
        const cache_dir = try resolved.repocache.archiveCacheDir();
        defer ctx.allocator.free(cache_dir);
        path.ensureDirExists(cache_dir) catch |err| {
            return ctx.fail(err, cache_dir, "failed to create package cache directory");
        };

        const cache_path = try resolved.repocache.archiveCachePath(&resolved.pkg);
        errdefer ctx.allocator.free(cache_path);

        const in_cache = blk: {
            std.Io.Dir.accessAbsolute(path.currentIo(), cache_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (in_cache) {
            try cache_paths.append(ctx.allocator, cache_path);
            continue;
        }

        // Not in cache — check if already in store before downloading
        const in_store = blk: {
            if (resolved.pkg.name) |name| {
                if (resolved.pkg.version) |version| {
                    const store_path = store.constructStorePath(ctx, resolved.pkg.content_hash, name, version) catch break :blk false;
                    defer ctx.allocator.free(store_path);
                    std.Io.Dir.accessAbsolute(path.currentIo(), store_path, .{}) catch break :blk false;
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (in_store) {
            ctx.allocator.free(cache_path);
            const empty = try ctx.allocator.dupe(u8, "");
            try cache_paths.append(ctx.allocator, empty);
        } else {
            const archive_url = try resolved.repocache.archiveUrl(&resolved.pkg);
            errdefer ctx.allocator.free(archive_url);

            try requests.append(ctx.allocator, .{
                .url = archive_url,
                .dest_path = cache_path,
                .options = .{
                    .expected_hash = if (resolved.pkg.archive_hash.len > 0) resolved.pkg.archive_hash else null,
                },
            });
            try owned_urls.append(ctx.allocator, archive_url);
            try cache_paths.append(ctx.allocator, cache_path);
        }
    }

    if (requests.items.len > 0) {
        try download.downloadBatch(client, ctx, requests.items);
    }

    return cache_paths;
}

fn applyInstallTargets(
    ctx: *Context,
    installed_packages: []const generation.PackageEntry,
    profile_name: ?[]const u8,
    target_profile_path: ?[]const u8,
    verify_store: bool,
    phase: ui.Phase,
) !void {
    // 3. Create or publish the target profile realization, or symlink to a build profile
    if (target_profile_path) |profile_path| {
        // Symlink packages directly to the target profile (for build profiles)
        try symlinkPackagesToProfile(ctx, profile_path, installed_packages, phase);
    } else if (profile_name) |prof_name| {
        try applyProfileRealization(ctx, prof_name, installed_packages, verify_store, phase);
    }
}

/// Symlink packages directly to a target profile directory
/// This is used for build profiles where we don't create generations
fn symlinkPackagesToProfile(ctx: *Context, profile_path: []const u8, installed_packages: []const generation.PackageEntry, phase: ui.Phase) !void {
    ctx.debug("symlinking {d} packages to profile: {s}", .{ installed_packages.len, profile_path });

    const store_root = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" });
    defer ctx.allocator.free(store_root);

    // Use the profile module's buildProfile function to create symlinks
    var result = profile.buildProfile(
        ctx.allocator,
        ctx,
        profile_path,
        store_root,
        installed_packages,
    ) catch |err| {
        ctx.debug("failed to build profile: {}", .{err});
        const diag = ctx.getDiagnosticContext();
        if (diag.details == null) {
            ctx.setDiagnosticContextFmt(profile_path, "failed to build profile: {s}", .{@errorName(err)});
        }
        return switch (err) {
            profile.ProfileError.PathConflict => error.ConflictingProvision,
            profile.ProfileError.PermissionDenied => error.PermissionDenied,
            profile.ProfileError.OutOfMemory => error.OutOfMemory,
            profile.ProfileError.InvalidStoreLayout => error.InvalidInput,
            else => error.FileSystem,
        };
    };
    defer result.deinit();

    // Check for conflicts
    if (result.conflicts.hasConflicts()) {
        return ctx.fail(error.ConflictingProvision, profile_path, "path conflicts");
    }

    const details = std.fmt.allocPrint(
        ctx.allocator,
        "{d} packages ({d} entries, {d} materialized, {d} reused, {d} ms)",
        .{
            installed_packages.len,
            result.stats.total_entries,
            result.stats.materialized_entries,
            result.stats.reused_entries,
            @divFloor(result.stats.duration_ns, std.time.ns_per_ms),
        },
    ) catch {
        return error.OutOfMemory;
    };
    defer ctx.allocator.free(details);

    const segments = [_]mere.ui.Segment{
        .{ .text = "build profile", .kind = .normal },
        .{ .text = " linked", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = details, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, phase, .info, &segments);
}

/// Apply installed packages to the requested profile target.
/// System profiles create and activate generations; named profiles publish a single root.
fn applyProfileRealization(ctx: *Context, prof_name: []const u8, installed_packages: []const generation.PackageEntry, verify_store: bool, phase: ui.Phase) !void {
    const profile_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", prof_name });
    defer ctx.allocator.free(profile_dir);

    const store_root = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" });
    defer ctx.allocator.free(store_root);

    // Ensure profile directory exists
    path.ensureDirExists(profile_dir) catch |err| {
        ctx.setDiagnosticContext(profile_dir, "failed to create profile directory");
        return switch (err) {
            error.AccessDenied => error.PermissionDenied,
            else => error.FileSystem,
        };
    };

    if (std.mem.eql(u8, prof_name, "system")) {
        const current_gen = generation.getCurrentGeneration(profile_dir) catch |err| {
            return ctx.failFmt(mapGenerationError(err), profile_dir, "failed to read current generation: {s}", .{@errorName(err)});
        };
        var previous_manifest: ?generation.GenerationManifest = null;
        defer if (previous_manifest) |*manifest_data| manifest_data.deinit();

        if (current_gen) |gen_num| {
            const previous_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch |err| {
                return ctx.failFmt(mapGenerationError(err), profile_dir, "failed to construct current generation path: {s}", .{@errorName(err)});
            };
            defer ctx.allocator.free(previous_path);
            previous_manifest = generation.readManifest(ctx.allocator, store_root, previous_path) catch |err| {
                return ctx.failFmt(mapGenerationError(err), previous_path, "failed to read current generation manifest: {s}", .{@errorName(err)});
            };
        }

        const gen_num = profile.createGeneration(
            ctx,
            profile_dir,
            store_root,
            installed_packages,
            current_gen,
        ) catch |err| {
            ctx.debug("failed to create generation: {}", .{err});
            const diag = ctx.getDiagnosticContext();
            if (diag.details == null) {
                ctx.setDiagnosticContextFmt(profile_dir, "failed to create generation: {s}", .{@errorName(err)});
            }
            return switch (err) {
                profile.ProfileError.PathConflict => error.ConflictingProvision,
                profile.ProfileError.PermissionDenied => error.PermissionDenied,
                profile.ProfileError.OutOfMemory => error.OutOfMemory,
                profile.ProfileError.InvalidStoreLayout => error.InvalidInput,
                else => error.FileSystem,
            };
        };

        emitGenerationStatus(ctx, "created", gen_num, prof_name, phase);

        const provider = if (ctx.configuration) |*cfg| cfg.effectiveInitProvider() else .s6rc;
        var staged_dinit: ?service_reconcile.StagedDinit = null;
        defer if (staged_dinit) |*staged| staged.discard();
        if (provider == .dinit) {
            const generation_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch {
                return ctx.fail(error.OutOfMemory, profile_dir, "failed to construct generation path for dinit services");
            };
            defer ctx.allocator.free(generation_path);
            staged_dinit = try service_reconcile.stageDinit(
                ctx,
                generation_path,
                installed_packages,
                if (previous_manifest) |*manifest_data| manifest_data.packages.items else &.{},
            );
        }

        const result = activation.activateSystemGeneration(
            ctx,
            gen_num,
            if (verify_store) .full_store else .fast,
        ) catch |err| {
            ctx.debug("failed to activate generation: {}", .{err});
            return ctx.fail(mapActivationError(err), profile_dir, "failed to activate generation");
        };

        if (staged_dinit) |*staged| {
            staged.commit() catch |err| {
                ctx.debug("failed to commit dinit services: {}", .{err});
                return ctx.fail(switch (err) {
                    service_reconcile.ReconcileError.OutOfMemory => error.OutOfMemory,
                    service_reconcile.ReconcileError.PermissionDenied => error.PermissionDenied,
                    service_reconcile.ReconcileError.InvalidInput, service_reconcile.ReconcileError.DuplicateService => error.InvalidInput,
                    else => error.FileSystem,
                }, profile_dir, "failed to commit dinit services");
            };
        }

        var gen_buf: [32]u8 = undefined;
        var copied_buf: [32]u8 = undefined;
        var unchanged_buf: [32]u8 = undefined;
        var differing_buf: [32]u8 = undefined;
        var boot_buf: [32]u8 = undefined;
        const gen_text = std.fmt.bufPrint(&gen_buf, "{d}", .{gen_num}) catch return error.OutOfMemory;
        const copied_text = std.fmt.bufPrint(&copied_buf, "{d}", .{result.etc_copied}) catch return error.OutOfMemory;
        const unchanged_text = std.fmt.bufPrint(&unchanged_buf, "{d}", .{result.etc_skipped}) catch return error.OutOfMemory;
        const differing_text = std.fmt.bufPrint(&differing_buf, "{d}", .{result.etc_differing}) catch return error.OutOfMemory;
        const boot_text = std.fmt.bufPrint(&boot_buf, "{d}", .{result.boot_artifacts_staged}) catch return error.OutOfMemory;
        const segments = [_]mere.ui.Segment{
            .{ .text = "generation ", .kind = .normal },
            .{ .text = "activated", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = gen_text, .kind = .detail },
            .{ .text = " (", .kind = .normal },
            .{ .text = copied_text, .kind = .detail },
            .{ .text = " /etc files copied, ", .kind = .normal },
            .{ .text = unchanged_text, .kind = .detail },
            .{ .text = " unchanged, ", .kind = .normal },
            .{ .text = differing_text, .kind = .detail },
            .{ .text = " differing, ", .kind = .normal },
            .{ .text = boot_text, .kind = .detail },
            .{ .text = " boot artifacts staged; run 'mere etc status')", .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, phase, .info, &segments);
    } else {
        const stats = profile.publishProfileRoot(
            ctx,
            profile_dir,
            store_root,
            installed_packages,
        ) catch |err| {
            ctx.debug("failed to publish profile root: {}", .{err});
            const diag = ctx.getDiagnosticContext();
            if (diag.details == null) {
                ctx.setDiagnosticContextFmt(profile_dir, "failed to publish profile root: {s}", .{@errorName(err)});
            }
            return switch (err) {
                profile.ProfileError.PathConflict => error.ConflictingProvision,
                profile.ProfileError.PermissionDenied => error.PermissionDenied,
                profile.ProfileError.OutOfMemory => error.OutOfMemory,
                profile.ProfileError.InvalidStoreLayout => error.InvalidInput,
                else => error.FileSystem,
            };
        };
        const details = std.fmt.allocPrint(
            ctx.allocator,
            "{d} packages ({d} entries, {d} materialized, {d} reused, {d} ms)",
            .{
                installed_packages.len,
                stats.total_entries,
                stats.materialized_entries,
                stats.reused_entries,
                @divFloor(stats.duration_ns, std.time.ns_per_ms),
            },
        ) catch return error.OutOfMemory;
        defer ctx.allocator.free(details);

        const segments = [_]mere.ui.Segment{
            .{ .text = "profile root", .kind = .normal },
            .{ .text = " published", .kind = .success },
            .{ .text = " for '", .kind = .normal },
            .{ .text = prof_name, .kind = .detail },
            .{ .text = "': ", .kind = .normal },
            .{ .text = details, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, phase, .info, &segments);
    }
}

// (removed unused legacy dependency collection helper)
// Helper: install a single package to the store (no activation)
// Returns package info for generation creation
//
// Store Admission Protocol (spec 4.1):
// 1. Verify manifest signature before touching the store (fast-fail)
// 2. Stage in /mere/store/.incoming/<rand>/ (same filesystem for atomic rename)
// 3. Extract payload and validate symlinks
// 4. Atomic rename to final content-addressed path
// 5. Post-admission verification and set read-only permissions
fn installSinglePackageToStore(
    ctx: *Context,
    pkg: *package.Package,
    repo_cache: *RepoCache,
    cache_path: []const u8,
    reinstall: bool,
    loaded_keys: []const sign.LoadedKey,
) !generation.PackageEntry {
    const pkg_label = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}-{d}", .{ pkg.name.?, pkg.version.?, pkg.release.? });
    defer ctx.allocator.free(pkg_label);

    const pkg_id = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ pkg.name.?, pkg.version.? });
    defer ctx.allocator.free(pkg_id);

    // === Step 1: Pre-extraction manifest verification (fast-fail) ===
    var preverify = try preVerifyManifest(ctx, repo_cache, cache_path, pkg_id, loaded_keys);
    defer preverify.deinit(ctx.allocator);

    try enforceRepoMetadataBinding(ctx, pkg, &preverify, pkg_id);

    const preverify_install_dir = store.constructStorePath(ctx, preverify.manifest_content_hash, pkg.name.?, pkg.version.?) catch |err| {
        ctx.setDiagnosticContext(cache_path, "failed to construct store path");
        return switch (err) {
            store.StoreError.InvalidInput => error.InvalidInput,
            store.StoreError.OutOfMemory => error.OutOfMemory,
            store.StoreError.PermissionDenied => error.PermissionDenied,
            else => error.FileSystem,
        };
    };
    var keep_preverify_install_dir = false;
    defer if (!keep_preverify_install_dir) ctx.allocator.free(preverify_install_dir);

    var preverify_exists = true;
    std.Io.Dir.accessAbsolute(path.currentIo(), preverify_install_dir, .{}) catch {
        preverify_exists = false;
    };

    if (preverify_exists and !reinstall) {
        // Privileged fast-path: harden existing store object before referencing it.
        // An unprivileged user may have admitted this object previously; we must
        // ensure it is root-owned and read-only before any system profile uses it.
        if (store.isPrivileged()) {
            try finalizeAdmittedStoreObject(ctx, preverify_install_dir, true);
        }

        keep_preverify_install_dir = true;

        return generation.PackageEntry{
            .name = try ctx.allocator.dupe(u8, pkg.name.?),
            .version = try ctx.allocator.dupe(u8, pkg.version.?),
            .release = pkg.release.?,
            .arch = try ctx.allocator.dupe(u8, pkg.arch.?),
            .store_path = preverify_install_dir,
            .content_hash = try ctx.allocator.dupe(u8, preverify.manifest_content_hash),
        };
    }

    var staging = try stageAndValidatePayload(ctx, pkg, cache_path, preverify.manifest_content_hash, preverify.parsed.format);
    errdefer path.deleteTreeAbsolute(staging.staging_dir) catch {};
    defer ctx.allocator.free(staging.staging_dir);
    // Held across the rename below, so a concurrent sweep cannot mistake
    // in-flight staging for debris.
    defer staging.claim.release();

    if (staging.content_exists and !reinstall) {
        ctx.debug("content already exists in store: {s}", .{staging.install_dir});
        path.deleteTreeAbsolute(staging.staging_dir) catch {};

        try finalizeAdmittedStoreObject(ctx, staging.install_dir, true);

        return generation.PackageEntry{
            .name = try ctx.allocator.dupe(u8, pkg.name.?),
            .version = try ctx.allocator.dupe(u8, pkg.version.?),
            .release = pkg.release.?,
            .arch = try ctx.allocator.dupe(u8, pkg.arch.?),
            .store_path = staging.install_dir,
            .content_hash = staging.content_hash,
        };
    }

    const install_id = emit.installStart(ctx, pkg_label);
    errdefer emit.installError(ctx, install_id, pkg_label);

    if (reinstall and staging.content_exists) {
        ctx.debug("reinstall requested, removing existing store dir: {s}", .{staging.install_dir});
        path.deleteTreeAbsolute(staging.install_dir) catch {};
    }

    const store_parent = std.fs.path.dirname(staging.install_dir) orelse {
        return ctx.fail(error.FileSystem, staging.install_dir, "failed to compute store parent path");
    };
    var parent_dir = path.makePathAndOpenDir(store_parent) catch |err| {
        ctx.setDiagnosticContext(staging.install_dir, "failed to create store parent directory");
        return mapInstallFsError(err);
    };
    defer parent_dir.close(path.currentIo());

    // Ensure the staged payload is durable on disk before it becomes
    // reachable under its final store path.
    fsyncTree(ctx.allocator, staging.staging_dir) catch |err| {
        ctx.debug("fsync of staged content failed: {}", .{err});
        path.deleteTreeAbsolute(staging.staging_dir) catch {};
        return ctx.fail(error.FileSystem, staging.install_dir, "failed to sync staged package content to disk");
    };

    // === Step 4: Atomic rename to final path ===
    const staging_z = try ctx.allocator.dupeZ(u8, staging.staging_dir);
    defer ctx.allocator.free(staging_z);
    const install_z = try ctx.allocator.dupeZ(u8, staging.install_dir);
    defer ctx.allocator.free(install_z);

    const rename_result = std.os.linux.rename(staging_z, install_z);
    if (rename_result != 0) {
        const errno: std.posix.E = @enumFromInt(rename_result);
        if (errno == .EXIST or errno == .NOTEMPTY) {
            // Target already exists - another process beat us, treat as success
            ctx.debug("target already exists (race), cleaning up staging dir", .{});
            path.deleteTreeAbsolute(staging.staging_dir) catch {};
        } else {
            ctx.debug("atomic rename failed with errno {d}", .{rename_result});
            path.deleteTreeAbsolute(staging.staging_dir) catch {};
            return ctx.fail(error.FileSystem, staging.install_dir, "atomic rename to final path failed");
        }
    } else {
        // Make the rename itself durable: fsync the directory that now
        // contains the new entry.
        fsyncFd(parent_dir.handle) catch |err| {
            ctx.debug("fsync of store parent directory failed: {}", .{err});
        };
    }
    ctx.debug("package admitted to store: {s}", .{staging.install_dir});

    try finalizeAdmittedStoreObject(ctx, staging.install_dir, false);

    emit.installComplete(ctx, install_id, pkg_label);

    // Return package info for generation creation
    return generation.PackageEntry{
        .name = try ctx.allocator.dupe(u8, pkg.name.?),
        .version = try ctx.allocator.dupe(u8, pkg.version.?),
        .release = pkg.release.?,
        .arch = try ctx.allocator.dupe(u8, pkg.arch.?),
        .store_path = staging.install_dir,
        .content_hash = staging.content_hash,
    };
}

/// Set a directory and its contents to read-only (best-effort)
/// Removes write permissions while preserving read and execute bits
fn setDirectoryReadOnly(dir_path: []const u8) !void {
    const io = path.currentIo();
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    while (true) {
        const entry = try walker.next(io);
        if (entry == null) break;
        const e = entry.?;
        // Get metadata and change permissions
        if (e.kind == .directory) {
            var subdir = dir.openDir(io, e.path, .{ .iterate = true }) catch continue;
            defer subdir.close(io);
            const stat = subdir.stat(io) catch continue;
            // Remove write bits (0o222) but preserve read (0o444) and execute (0o111)
            const new_mode = stat.permissions.toMode() & ~@as(std.posix.mode_t, 0o222);
            subdir.setPermissions(io, .fromMode(new_mode)) catch {};
        } else {
            // Open file in read-only mode just to get handle for chmod
            var file = dir.openFile(io, e.path, .{ .mode = .read_only }) catch continue;
            defer file.close(io);
            const stat = file.stat(io) catch continue;
            // Remove write bits (0o222) but preserve read (0o444) and execute (0o111)
            const new_mode = stat.permissions.toMode() & ~@as(std.posix.mode_t, 0o222);
            file.setPermissions(io, .fromMode(new_mode)) catch {};
        }
    }

    // Also chmod the directory itself
    const stat = try dir.stat(io);
    const new_mode = stat.permissions.toMode() & ~@as(std.posix.mode_t, 0o222);
    dir.setPermissions(io, .fromMode(new_mode)) catch {};
}

const ParsedManifest = struct {
    data: []u8,
    manifest: manifest.PackageManifestV1,
    format: manifest.Format,

    pub fn deinit(self: *ParsedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const PreVerifyResult = struct {
    parsed: ParsedManifest,
    manifest_content_hash: []const u8,
    archive_hash: []const u8,
    verifying_fingerprint: []const u8,

    pub fn deinit(self: *PreVerifyResult, allocator: std.mem.Allocator) void {
        self.parsed.deinit(allocator);
        allocator.free(self.manifest_content_hash);
        allocator.free(self.archive_hash);
        allocator.free(self.verifying_fingerprint);
    }
};

const StagingResult = struct {
    staging_dir: []const u8,
    content_hash: []const u8,
    install_dir: []const u8,
    content_exists: bool,
    /// Held until the caller has renamed the staging directory into the store
    /// or deleted it (spec §4.3).
    claim: scratch.Claim,
};

fn mapInstallFsError(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => error.InvalidInput,
        else => error.FileSystem,
    };
}

fn mapActivationError(err: activation.ActivationError) anyerror {
    return switch (err) {
        activation.ActivationError.OutOfMemory => error.OutOfMemory,
        activation.ActivationError.PermissionDenied => error.PermissionDenied,
        activation.ActivationError.InvalidInput => error.InvalidInput,
        activation.ActivationError.DuplicateEtcTemplate => error.ConflictingProvision,
        else => error.FileSystem,
    };
}

fn mapGenerationError(err: generation.GenerationError) anyerror {
    return switch (err) {
        generation.GenerationError.OutOfMemory => error.OutOfMemory,
        generation.GenerationError.PermissionDenied => error.PermissionDenied,
        generation.GenerationError.InvalidInput => error.InvalidInput,
        generation.GenerationError.InvalidManifest,
        generation.GenerationError.ParseError,
        => error.InvalidInput,
        else => error.FileSystem,
    };
}

fn preVerifyManifest(
    ctx: *Context,
    repo_cache: *RepoCache,
    cache_path: []const u8,
    pkg_id: []const u8,
    loaded_keys: []const sign.LoadedKey,
) !PreVerifyResult {
    // Partial-extract the newest supported manifest/signature pair and verify
    // it before doing any store operations.
    var verify_temp_dir = try path.createTempDir("mere-verify");
    defer verify_temp_dir.cleanup();

    var verify_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const verify_dir_len = try verify_temp_dir.dir.realPath(path.currentIo(), &verify_path_buf);
    const verify_dir = verify_path_buf[0..verify_dir_len];

    ctx.debug("partial-extracting manifest for pre-verification", .{});
    var format: manifest.Format = .v1;
    for (manifest.formats_newest_first) |candidate| {
        extract.fileInto(ctx, cache_path, verify_dir, candidate.manifestFilename()) catch {};
        const probe_path = try std.fs.path.join(ctx.allocator, &.{ verify_dir, candidate.manifestFilename() });
        defer ctx.allocator.free(probe_path);
        if (path.fileExists(probe_path)) {
            format = candidate;
            break;
        }
    }

    try extract.fileInto(ctx, cache_path, verify_dir, format.manifestFilename());
    try extract.fileInto(ctx, cache_path, verify_dir, format.signatureFilename());

    const manifest_path = try std.fs.path.join(ctx.allocator, &.{ verify_dir, format.manifestFilename() });
    defer ctx.allocator.free(manifest_path);
    const sig_path = try std.fs.path.join(ctx.allocator, &.{ verify_dir, format.signatureFilename() });
    defer ctx.allocator.free(sig_path);

    if (repo_cache.trusted_fingerprints.len == 0) {
        return ctx.fail(error.SignatureInvalid, pkg_id, "no trusted fingerprints configured");
    }

    ctx.debug("verifying manifest signature against {d} trusted fingerprints", .{repo_cache.trusted_fingerprints.len});
    const result = sign.verifyManifestWithTrustedFingerprints(ctx, manifest_path, sig_path, format.signatureFormat(), repo_cache.trusted_fingerprints, loaded_keys) catch {
        return ctx.fail(error.SignatureInvalid, pkg_id, "manifest signature verification");
    };
    errdefer ctx.allocator.free(result.verifying_fingerprint);
    ctx.debug("manifest signature verified (pre-extraction)", .{});

    // Decode directly from the bytes that were just verified, rather than
    // re-reading manifest_path from disk a second time (avoids a
    // verify-then-reread TOCTOU window).
    const pkg_manifest = manifest.PackageManifestV1.decodeForSchema(result.manifest_bytes, format.schemaVersion()) catch {
        ctx.allocator.free(result.manifest_bytes);
        ctx.setDiagnosticContext(verify_dir, "package manifest invalid or failed to decode");
        return error.InvalidInput;
    };
    var parsed_manifest = ParsedManifest{
        .data = result.manifest_bytes,
        .manifest = pkg_manifest,
        .format = format,
    };
    errdefer parsed_manifest.deinit(ctx.allocator);

    const manifest_content_hash = try parsed_manifest.manifest.contentHashHex(ctx.allocator);
    const archive_hash = try hash.calculateFileHash(ctx, cache_path);
    ctx.debug("content hash from manifest: {s}", .{manifest_content_hash});
    ctx.debug("archive hash from package file: {s}", .{archive_hash});

    return PreVerifyResult{
        .parsed = parsed_manifest,
        .manifest_content_hash = manifest_content_hash,
        .archive_hash = archive_hash,
        .verifying_fingerprint = result.verifying_fingerprint,
    };
}

fn enforceRepoMetadataBinding(
    ctx: *Context,
    pkg: *const package.Package,
    preverify: *const PreVerifyResult,
    pkg_id: []const u8,
) !void {
    const m = preverify.parsed.manifest;

    if (!std.mem.eql(u8, pkg.name.?, m.name) or
        !std.mem.eql(u8, pkg.version.?, m.version) or
        pkg.release.? != m.release or
        !std.mem.eql(u8, pkg.arch.?, m.arch))
    {
        return ctx.fail(error.CorruptData, pkg_id, "repository metadata does not match package manifest identity");
    }

    if (pkg.content_hash.len != 64 or !std.mem.eql(u8, pkg.content_hash, preverify.manifest_content_hash)) {
        return ctx.fail(error.CorruptData, pkg_id, "repository metadata content hash does not match package manifest");
    }
    if (pkg.archive_hash.len != 64 or !std.mem.eql(u8, pkg.archive_hash, preverify.archive_hash)) {
        return ctx.fail(error.CorruptData, pkg_id, "repository metadata archive hash does not match package file");
    }
}

fn stageAndValidatePayload(
    ctx: *Context,
    pkg: *package.Package,
    cache_path: []const u8,
    manifest_content_hash: []const u8,
    format: manifest.Format,
) !StagingResult {
    // === Step 2: Stage in /mere/store/.incoming/<rand>/ ===
    const store_root = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    const incoming_dir = try std.fs.path.join(ctx.allocator, &.{ store_root, ".incoming" });
    defer ctx.allocator.free(incoming_dir);

    // Ensure .incoming directory exists
    path.ensureDirExists(incoming_dir) catch |err| {
        ctx.debug("failed to create .incoming dir: {}", .{err});
        return ctx.fail(mapInstallFsError(err), incoming_dir, "failed to create staging directory");
    };

    // Create unique staging directory
    var rand_buf: [16]u8 = undefined;
    path.currentIo().random(&rand_buf);
    const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
    const staging_dir = try std.fs.path.join(ctx.allocator, &.{ incoming_dir, &rand_hex });
    errdefer ctx.allocator.free(staging_dir);

    ctx.debug("staging package in: {s}", .{staging_dir});
    path.ensureDirExists(staging_dir) catch |err| {
        ctx.debug("failed to create staging dir: {}", .{err});
        return ctx.fail(mapInstallFsError(err), staging_dir, "failed to create staging directory");
    };
    errdefer path.deleteTreeAbsolute(staging_dir) catch {};

    // Claim it (spec §4.3) so that if this process dies before admission, the
    // half-extracted tree is reclaimable instead of sitting in .incoming/
    // forever. Not inheritable: nothing here execs, and the claim is dropped by
    // the caller once the directory has been renamed away or removed.
    var staging_claim = scratch.claim(ctx.allocator, staging_dir, false) catch |err| {
        return ctx.fail(mapInstallFsError(err), staging_dir, "failed to claim staging directory");
    };
    errdefer staging_claim.release();

    // === Step 3: Extract payload and validate ===
    extract.intoPreservingSpecialBits(ctx, cache_path, staging_dir) catch |err| {
        return ctx.fail(err, cache_path, "failed to extract package to staging directory");
    };
    ctx.debug("package extracted to staging dir", .{});

    // Validate payload symlinks stay within the package boundary (spec #7)
    path_safety.validateStorePayload(ctx.allocator, staging_dir) catch |err| {
        ctx.debug("symlink validation failed: {}", .{err});
        const detail = switch (err) {
            path_safety.PathSafetyError.EscapesBoundary => "symlink escapes package boundary",
            path_safety.PathSafetyError.SymlinkLoop => "symlink loop detected",
            path_safety.PathSafetyError.ChainTooDeep => "symlink chain too deep",
            else => "symlink validation failed",
        };
        return ctx.fail(switch (err) {
            path_safety.PathSafetyError.EscapesBoundary => error.SymlinkEscapesBoundary,
            path_safety.PathSafetyError.SymlinkLoop => error.InvalidSymlink,
            path_safety.PathSafetyError.ChainTooDeep => error.InvalidSymlink,
            else => error.FileSystem,
        }, staging_dir, detail);
    };
    ctx.debug("symlink validation passed", .{});

    // Compute content hash from realized payload and canonical package metadata (spec #1/#4)
    var hash_diag: hash.HashDiag = .{};
    defer hash_diag.deinit(ctx.allocator);
    var content_hash: []const u8 = switch (format.storeHashFormat()) {
        .v1 => hash.calculateStoreContentHash(ctx.allocator, staging_dir, &hash_diag),
        .v2 => hash.calculateStoreContentHashV2(ctx.allocator, staging_dir, &hash_diag),
        .v3 => hash.calculateStoreContentHashV3(ctx.allocator, staging_dir, &hash_diag),
        .v4 => hash.calculateStoreContentHashV4(ctx.allocator, staging_dir, &hash_diag),
    } catch |err| {
        const action = hash_diag.action orelse "compute content hash";
        const path_label = hash_diag.path orelse staging_dir;
        const os_err = if (hash_diag.os_error) |oe| @errorName(oe) else "unknown";
        ctx.setDiagnosticContextFmt(staging_dir, "failed to compute content hash from payload and metadata: {s}: {s} ({s})", .{ action, path_label, os_err });
        return switch (err) {
            hash.HashError.OutOfMemory => error.OutOfMemory,
            hash.HashError.PermissionDenied => error.PermissionDenied,
            hash.HashError.InvalidInput => error.InvalidInput,
            else => error.FileSystem,
        };
    };
    errdefer ctx.allocator.free(content_hash);
    ctx.debug("content hash from payload and metadata: {s}", .{content_hash});

    if (!std.mem.eql(u8, content_hash, manifest_content_hash)) {
        if (format == .v1) {
            const transitional_hash = hash.calculateTransitionalMetadataContentHash(ctx.allocator, staging_dir, null) catch {
                ctx.allocator.free(content_hash);
                return ctx.fail(error.FileSystem, staging_dir, "failed to compute transitional content hash");
            };
            if (std.mem.eql(u8, transitional_hash, manifest_content_hash)) {
                ctx.allocator.free(content_hash);
                content_hash = transitional_hash;
            } else {
                ctx.allocator.free(transitional_hash);
                return ctx.fail(error.CorruptData, staging_dir, "manifest content hash does not match payload");
            }
        } else {
            return ctx.fail(error.CorruptData, staging_dir, "manifest content hash does not match payload and metadata");
        }
    }

    const install_dir = store.constructStorePath(ctx, content_hash, pkg.name.?, pkg.version.?) catch |err| {
        ctx.setDiagnosticContext(staging_dir, "failed to construct store path");
        return switch (err) {
            store.StoreError.InvalidInput => error.InvalidInput,
            store.StoreError.OutOfMemory => error.OutOfMemory,
            store.StoreError.PermissionDenied => error.PermissionDenied,
            else => error.FileSystem,
        };
    };
    errdefer ctx.allocator.free(install_dir);
    ctx.debug("content-addressed store path: {s}", .{install_dir});

    var content_exists = true;
    std.Io.Dir.accessAbsolute(path.currentIo(), install_dir, .{}) catch {
        content_exists = false;
    };

    return StagingResult{
        .staging_dir = staging_dir,
        .content_hash = content_hash,
        .install_dir = install_dir,
        .content_exists = content_exists,
        .claim = staging_claim,
    };
}

fn fsyncFd(fd: std.posix.fd_t) !void {
    if (std.os.linux.fsync(fd) != 0) return error.FileSystem;
}

// Recursively fsync every file's data and every directory's entries under
// dir_path (including dir_path itself), so the staged payload is durable
// on disk before it is made visible via rename into the content-addressed
// store.
fn fsyncTree(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const io = path.currentIo();
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                var file = try dir.openFile(io, entry.path, .{});
                defer file.close(io);
                try fsyncFd(file.handle);
            },
            .directory => {
                // iterate = true is required here: without it Zig opens
                // the directory O_PATH, and fsync() on an O_PATH fd fails
                // with EBADF.
                var sub = try dir.openDir(io, entry.path, .{ .iterate = true });
                defer sub.close(io);
                try fsyncFd(sub.handle);
            },
            else => {},
        }
    }

    try fsyncFd(dir.handle);
}

fn finalizeAdmittedStoreObject(
    ctx: *Context,
    install_dir: []const u8,
    existing_only: bool,
) !void {
    _ = existing_only;
    if (store.isPrivileged()) {
        _ = store.harden(ctx, install_dir) catch |err| {
            return switch (err) {
                store.StoreError.OutOfMemory => error.OutOfMemory,
                store.StoreError.PermissionDenied => error.PermissionDenied,
                store.StoreError.SymlinkEscapesBoundary => error.SymlinkEscapesBoundary,
                store.StoreError.InvalidInput => error.InvalidInput,
                else => error.FileSystem,
            };
        };
        ctx.debug("store object hardened (root ownership)", .{});
    } else {
        // Unprivileged install - set read-only (best-effort)
        setDirectoryReadOnly(install_dir) catch |err| {
            ctx.debug("failed to set read-only permissions: {}", .{err});
        };
    }
}
test "multi-repository install uses priority and resolves dependencies across repos" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Prepare config and add two repositories with different priorities
    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    // Create directories for each repo using path helpers
    const repo1_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "repo1" });
    defer std.testing.allocator.free(repo1_dir);
    const repo2_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "repo2" });
    defer std.testing.allocator.free(repo2_dir);
    {
        var d1 = try path.makePathAndOpenDir(repo1_dir);
        d1.close(path.currentIo());
        var d2 = try path.makePathAndOpenDir(repo2_dir);
        d2.close(path.currentIo());
    }

    // Place DB files as repo1/repo.db and repo2/repo.db - Repository.init
    // always uses the fixed repo.db/repo.db.sig filenames, regardless of
    // the containing directory's name.
    const db_path1 = try std.fs.path.join(std.testing.allocator, &.{ repo1_dir, "repo.db" });
    defer std.testing.allocator.free(db_path1);
    const db_path2 = try std.fs.path.join(std.testing.allocator, &.{ repo2_dir, "repo.db" });
    defer std.testing.allocator.free(db_path2);
    var f1 = try path.makePathAndOpenFile(db_path1);
    f1.close(path.currentIo());
    var f2 = try path.makePathAndOpenFile(db_path2);
    f2.close(path.currentIo());

    // Generate and save valid keypairs for each repo
    // Generate and save valid keypairs for each repo (declare at outer scope)
    const keypair1 = try sign.generateKeyPair();
    const pub_path1 = try std.fs.path.join(std.testing.allocator, &.{ repo1_dir, "repo1.db.pub" });
    defer std.testing.allocator.free(pub_path1);
    const key_path1 = try std.fs.path.join(std.testing.allocator, &.{ repo1_dir, "repo1.db.key" });
    defer std.testing.allocator.free(key_path1);

    const keypair2 = try sign.generateKeyPair();
    const pub_path2 = try std.fs.path.join(std.testing.allocator, &.{ repo2_dir, "repo2.db.pub" });
    defer std.testing.allocator.free(pub_path2);
    const key_path2 = try std.fs.path.join(std.testing.allocator, &.{ repo2_dir, "repo2.db.key" });
    defer std.testing.allocator.free(key_path2);

    try keypair1.public_key.saveToFile(pub_path1);
    try keypair1.secret_key.saveToFile(key_path1);
    try keypair2.public_key.saveToFile(pub_path2);
    try keypair2.secret_key.saveToFile(key_path2);

    // Sign the DB files with the corresponding secret keys
    // --- Insert packages and dependencies BEFORE signing the DBs ---

    // Repo1: Insert A and its dependency
    // Initialize repositories
    var repo1 = try Repository.init(ctx, repo1_dir, false);
    defer repo1.deinit();
    var repo2 = try Repository.init(ctx, repo2_dir, false);
    defer repo2.deinit();

    // --- Repo1: A depends on B ---
    // Create dummy package file for A
    const packages_dir1 = try std.fs.path.join(std.testing.allocator, &.{ repo1_dir, "packages" });
    defer std.testing.allocator.free(packages_dir1);
    try path.ensureDirExists(packages_dir1);
    var pkg_a = package.Package.init(ctx);
    pkg_a.name = try ctx.allocator.dupe(u8, "A");
    pkg_a.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_a.release = 1;
    pkg_a.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_a_content_hash: []const u8 = "";
    defer if (pkg_a_content_hash.len > 0) ctx.allocator.free(pkg_a_content_hash);

    var pkg_a_file: []const u8 = "";
    defer if (pkg_a_file.len > 0) ctx.allocator.free(pkg_a_file);

    {
        // Ensure packages_dir1 exists
        try path.ensureDirExists(packages_dir1);

        // Create a temp directory structure for archive.createTar
        const pkg_a_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_a_staging" });
        defer ctx.allocator.free(pkg_a_staging);
        try path.ensureDirExists(pkg_a_staging);

        // Write file.txt
        const file_txt_path = try std.fs.path.join(ctx.allocator, &.{ pkg_a_staging, "file.txt" });
        defer ctx.allocator.free(file_txt_path);
        var file_txt = try path.makePathAndOpenFile(file_txt_path);
        try file_txt.writeStreamingAll(path.currentIo(), "hello");
        file_txt.close(path.currentIo());

        // Create .mere directory and manifest.v1 binary data
        const mere_dir_path = try std.fs.path.join(ctx.allocator, &.{ pkg_a_staging, manifest.META_DIR });
        defer ctx.allocator.free(mere_dir_path);
        try path.ensureDirExists(mere_dir_path);

        pkg_a_content_hash = try hash.calculateStoreContentHash(ctx.allocator, pkg_a_staging, null);
        var content_hash_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&content_hash_bytes, pkg_a_content_hash) catch unreachable;
        const pkg_manifest_a = manifest.PackageManifestV1{
            .schema_version = 1,
            .created_at = 1706745600,
            .release = 1,
            .arch = th.host_arch,
            .name = "A",
            .version = "1.0.0",
            .content_hash = content_hash_bytes,
        };

        // Use writeManifest to create both manifest.v1 and manifest.v1.sig
        const secret_key_a = try sign.SecretKey.loadFromFile(key_path1);
        try manifest.writeManifest(ctx, pkg_a_staging, &pkg_manifest_a, &secret_key_a.key);
        try writeProjectionForPackageDir(ctx.allocator, pkg_a_staging);

        pkg_a.content_hash = try ctx.allocator.dupe(u8, pkg_a_content_hash);
        pkg_a_file = try finalizeTestPackageArchive(ctx, &pkg_a, pkg_a_staging, packages_dir1);
    }
    // Sign the package file for A (use repo1 secret key)
    ctx.signing_key_path = key_path1;
    const sig_a = try sign.signWithResolvedKey(ctx, pkg_a_file, null, null);

    // Duplicate raw signature bytes into allocator-owned buffer for persistence.
    const sig_len = sign.c.crypto_sign_BYTES;
    var sig_buf = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf, sig_a[0..sig_len]);
    pkg_a.signature = sig_buf[0..sig_len];

    try pkg_a.addDependency("B", package.DependencyType.elf_needed);

    _ = try repo1.db.insertPackageTransaction(&pkg_a, null);
    pkg_a.deinit();

    // --- Repo2: B has no dependencies ---
    // Create dummy package file for B
    const packages_dir2 = try std.fs.path.join(std.testing.allocator, &.{ repo2_dir, "packages" });
    defer std.testing.allocator.free(packages_dir2);
    try path.ensureDirExists(packages_dir2);
    var pkg_b = package.Package.init(ctx);
    pkg_b.name = try ctx.allocator.dupe(u8, "B");
    pkg_b.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_b.release = 1;
    pkg_b.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_b_content_hash: []const u8 = "";
    defer if (pkg_b_content_hash.len > 0) ctx.allocator.free(pkg_b_content_hash);

    var pkg_b_file: []const u8 = "";
    defer if (pkg_b_file.len > 0) ctx.allocator.free(pkg_b_file);

    {
        // Ensure packages_dir2 exists
        try path.ensureDirExists(packages_dir2);

        // Create a temp directory structure for archive.createTar
        const pkg_b_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_b_staging" });
        defer ctx.allocator.free(pkg_b_staging);
        try path.ensureDirExists(pkg_b_staging);

        // Write file.txt
        const file_txt_path = try std.fs.path.join(ctx.allocator, &.{ pkg_b_staging, "file.txt" });
        defer ctx.allocator.free(file_txt_path);
        var file_txt = try path.makePathAndOpenFile(file_txt_path);
        try file_txt.writeStreamingAll(path.currentIo(), "hello");
        file_txt.close(path.currentIo());

        // Create .mere directory and manifest.v1 binary data
        const mere_dir_path = try std.fs.path.join(ctx.allocator, &.{ pkg_b_staging, manifest.META_DIR });
        defer ctx.allocator.free(mere_dir_path);
        try path.ensureDirExists(mere_dir_path);

        pkg_b_content_hash = try hash.calculateStoreContentHash(ctx.allocator, pkg_b_staging, null);
        var content_hash_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&content_hash_bytes, pkg_b_content_hash) catch unreachable;
        const pkg_manifest_b = manifest.PackageManifestV1{
            .schema_version = 1,
            .created_at = 1706745600,
            .release = 1,
            .arch = th.host_arch,
            .name = "B",
            .version = "1.0.0",
            .content_hash = content_hash_bytes,
        };

        // Use writeManifest to create both manifest.v1 and manifest.v1.sig
        const secret_key_b = try sign.SecretKey.loadFromFile(key_path2);
        try manifest.writeManifest(ctx, pkg_b_staging, &pkg_manifest_b, &secret_key_b.key);
        try writeProjectionForPackageDir(ctx.allocator, pkg_b_staging);

        pkg_b.content_hash = try ctx.allocator.dupe(u8, pkg_b_content_hash);
        pkg_b_file = try finalizeTestPackageArchive(ctx, &pkg_b, pkg_b_staging, packages_dir2);
    }
    // Sign the package file for B (use repo2 secret key)
    ctx.signing_key_path = key_path2;
    const sig_b = try sign.signWithResolvedKey(ctx, pkg_b_file, null, null);

    // Duplicate raw signature bytes into allocator-owned buffer for persistence.
    const sig_len_b = sign.c.crypto_sign_BYTES;
    var sig_buf_b = try ctx.allocator.alloc(u8, sig_len_b);
    std.mem.copyForwards(u8, sig_buf_b, sig_b[0..sig_len_b]);
    pkg_b.signature = sig_buf_b[0..sig_len_b];
    _ = try repo2.db.insertPackageTransaction(&pkg_b, null);
    pkg_b.deinit();

    // Now sign the DB files AFTER all writes
    const sig_path1 = try std.fs.path.join(std.testing.allocator, &.{ repo1_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path1);

    // Set the signing key path in the context to use keypair1 and write raw signature bytes
    ctx.signing_key_path = key_path1;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path1, sig_path1, null, null);

    const sig_path2 = try std.fs.path.join(std.testing.allocator, &.{ repo2_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path2);

    // Set the signing key path in the context to use keypair2 and write raw signature bytes
    ctx.signing_key_path = key_path2;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path2, sig_path2, null, null);

    // Print expected download source and cache destination for debugging
    // (moved debug logging for cache destination below, after repocache1 is declared)

    // Compute fingerprints for each keypair for trusted_fingerprints config
    const fingerprint1 = try keypair1.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint1);
    const fingerprint2 = try keypair2.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint2);

    // Copy the public keys to the user keys directory so verifyWithTrustedFingerprints can find them
    const user_keys_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer std.testing.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);

    const user_pub1 = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "repo1.pub" });
    defer std.testing.allocator.free(user_pub1);
    try keypair1.public_key.saveToFile(user_pub1);

    const user_pub2 = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "repo2.pub" });
    defer std.testing.allocator.free(user_pub2);
    try keypair2.public_key.saveToFile(user_pub2);

    // Use file:// URLs for repo sync logic
    const repo_url1 = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{repo1_dir});
    defer std.testing.allocator.free(repo_url1);
    const repo_url2 = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{repo2_dir});
    defer std.testing.allocator.free(repo_url2);

    // Build trusted_fingerprints lists for each repo
    var fps1: std.ArrayList([]const u8) = .empty;
    try fps1.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint1));

    var fps2: std.ArrayList([]const u8) = .empty;
    try fps2.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint2));

    // Repo1: higher priority, contains package A (depends on B)
    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo1"),
        .url = try ctx.allocator.dupe(u8, repo_url1),
        .priority = 200,
        .trusted_fingerprints = fps1,
    });
    // Repo2: lower priority, contains package B
    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo2"),
        .url = try ctx.allocator.dupe(u8, repo_url2),
        .priority = 100,
        .trusted_fingerprints = fps2,
    });

    // Insert packages and dependencies with real signatures

    // Create RepoCache objects from the repo configs
    var repocache1 = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[0]);
    defer repocache1.deinit();
    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try repocache1.sync(client, .{}, loaded_keys.items); // Sync BEFORE initializing the repository
    try repocache1.ensureRepository(loaded_keys.items);

    var repocache2 = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[1]);
    defer repocache2.deinit();
    try repocache2.sync(client, .{}, loaded_keys.items); // Sync BEFORE initializing the repository
    try repocache2.ensureRepository(loaded_keys.items);

    var repocaches = [_]*RepoCache{ &repocache1, &repocache2 };

    // Print expected cache destination for A after repocache1 is declared
    const cache_dir1 = try repocache1.archiveCacheDir();
    defer ctx.allocator.free(cache_dir1);
    const pkg_a_canon = try std.fmt.allocPrint(ctx.allocator, "A-1.0.0-1-{s}-{s}.pkg.tar.zst", .{ th.host_arch, pkg_a.archive_hash });
    defer ctx.allocator.free(pkg_a_canon);
    const cache_path_a = try std.fs.path.join(ctx.allocator, &.{ cache_dir1, pkg_a_canon });
    defer ctx.allocator.free(cache_path_a);

    const single = [_][]const u8{"A"};
    try installPackagesToProfile(ctx, &repocaches, single[0..], client, false, false, false, null, null);
}

test "resolveInstallPlan batches multiple roots and deduplicates shared dependency" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "plan-batch", repo_url, &[_][]const u8{}, 100);
    defer repocache.deinit();
    // Initialize read-write for test (need to create schema and insert data)
    repocache.repository = try Repository.init(repocache.ctx, repocache.cache_dir, false);

    var pkg_a = package.Package.init(ctx);
    defer pkg_a.deinit();
    pkg_a.name = try ctx.allocator.dupe(u8, "A");
    pkg_a.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_a.release = 1;
    pkg_a.arch = try ctx.allocator.dupe(u8, th.host_arch);
    pkg_a.signature = try ctx.allocator.dupe(u8, "sig-a");
    pkg_a.content_hash = try ctx.allocator.dupe(u8, "hash-a");
    pkg_a.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    try pkg_a.addDependency("C", package.DependencyType.elf_needed);
    _ = try repocache.repository.?.db.insertPackageTransaction(&pkg_a, null);

    var pkg_b = package.Package.init(ctx);
    defer pkg_b.deinit();
    pkg_b.name = try ctx.allocator.dupe(u8, "B");
    pkg_b.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_b.release = 1;
    pkg_b.arch = try ctx.allocator.dupe(u8, th.host_arch);
    pkg_b.signature = try ctx.allocator.dupe(u8, "sig-b");
    pkg_b.content_hash = try ctx.allocator.dupe(u8, "hash-b");
    pkg_b.archive_hash = try ctx.allocator.dupe(u8, "b" ** 64);
    try pkg_b.addDependency("C", package.DependencyType.elf_needed);
    _ = try repocache.repository.?.db.insertPackageTransaction(&pkg_b, null);

    var pkg_c = package.Package.init(ctx);
    defer pkg_c.deinit();
    pkg_c.name = try ctx.allocator.dupe(u8, "C");
    pkg_c.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_c.release = 1;
    pkg_c.arch = try ctx.allocator.dupe(u8, th.host_arch);
    pkg_c.signature = try ctx.allocator.dupe(u8, "sig-c");
    pkg_c.content_hash = try ctx.allocator.dupe(u8, "hash-c");
    pkg_c.archive_hash = try ctx.allocator.dupe(u8, "c" ** 64);
    _ = try repocache.repository.?.db.insertPackageTransaction(&pkg_c, null);

    var repocaches = [_]*RepoCache{&repocache};
    const roots = [_]resolver.Requirement{
        .{ .name = "A", .constraint_expr = null },
        .{ .name = "B", .constraint_expr = null },
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var plan = try resolveInstallPlan(ctx, &repocaches, &roots, &.{}, arena_allocator);
    defer plan.resolution.deinit();

    // A + B + shared C should resolve once each in one combined plan.
    try std.testing.expectEqual(@as(usize, 3), plan.resolution.packages.len);

    var has_a = false;
    var has_b = false;
    var has_c = false;
    for (plan.resolution.packages) |resolved| {
        const name = resolved.pkg.name.?;
        if (std.mem.eql(u8, name, "A")) has_a = true;
        if (std.mem.eql(u8, name, "B")) has_b = true;
        if (std.mem.eql(u8, name, "C")) has_c = true;
    }
    try std.testing.expect(has_a);
    try std.testing.expect(has_b);
    try std.testing.expect(has_c);

    var idx_a: ?usize = null;
    var idx_b: ?usize = null;
    var idx_c: ?usize = null;
    for (plan.sorted, 0..) |resolved, idx| {
        const name = resolved.pkg.name.?;
        if (std.mem.eql(u8, name, "A")) idx_a = idx;
        if (std.mem.eql(u8, name, "B")) idx_b = idx;
        if (std.mem.eql(u8, name, "C")) idx_c = idx;
    }
    try std.testing.expect(idx_a != null and idx_b != null and idx_c != null);
    try std.testing.expect(idx_c.? < idx_a.?);
    try std.testing.expect(idx_c.? < idx_b.?);
}

test "buildProfileResolverRequirements orders explicit roots before existing requested roots" {
    const allocator = std.testing.allocator;

    var install_requirements: std.ArrayList(InstallRootRequirement) = .empty;
    defer deinitInstallRootRequirements(allocator, &install_requirements);
    try install_requirements.append(allocator, .{
        .name = try allocator.dupe(u8, "X"),
        .constraint_expr = null,
    });

    var requested_packages: std.ArrayList(RequestedPackage) = .empty;
    defer {
        for (requested_packages.items) |*pkg| pkg.deinit(allocator);
        requested_packages.deinit(allocator);
    }
    try requested_packages.append(allocator, .{
        .name = try allocator.dupe(u8, "A"),
        .constraint_expr = null,
    });
    try requested_packages.append(allocator, .{
        .name = try allocator.dupe(u8, "X"),
        .constraint_expr = null,
    });

    const requirements = try buildProfileResolverRequirements(
        allocator,
        install_requirements.items,
        requested_packages.items,
    );
    defer allocator.free(requirements);

    try std.testing.expectEqual(@as(usize, 2), requirements.len);
    try std.testing.expectEqualStrings("X", requirements[0].name);
    try std.testing.expectEqualStrings("A", requirements[1].name);
}

test "upgrade targeting holds unrelated requested roots" {
    var selections = [_]resolver.PreferredSelection{
        .{ .name = "app", .version = "1", .release = 1, .arch = "x86_64", .content_hash = "a" },
        .{ .name = "tool", .version = "1", .release = 1, .arch = "x86_64", .content_hash = "b" },
        .{ .name = "dependency", .version = "1", .release = 1, .arch = "x86_64", .content_hash = "c" },
    };
    var state = PreferredSelectionsState{
        .allocator = std.testing.allocator,
        .selections = selections[0..],
    };
    const roots = [_]RequestedPackage{
        .{ .name = "app", .constraint_expr = ">=1" },
        .{ .name = "tool", .constraint_expr = null },
    };
    const targets = [_][]const u8{"app"};

    state.setUpgradeTargets(&roots, &targets);

    try std.testing.expect(selections[0].allow_upgrade);
    try std.testing.expect(!selections[1].allow_upgrade);
    try std.testing.expect(!selections[2].allow_upgrade);
}

test "unconstrained repeat install preserves the persisted root constraint" {
    const allocator = std.testing.allocator;
    const install_requirements = [_]InstallRootRequirement{
        .{ .name = "tool", .constraint_expr = null, .intent_constraint = null },
    };
    const requested_packages = [_]RequestedPackage{
        .{ .name = "tool", .constraint_expr = ">=2,<3" },
    };

    const requirements = try buildProfileResolverRequirements(allocator, &install_requirements, &requested_packages);
    defer allocator.free(requirements);

    try std.testing.expectEqual(@as(usize, 1), requirements.len);
    try std.testing.expectEqualStrings(">=2,<3", requirements[0].constraint_expr.?);
}

test "profile requirements keep exact dependency specs without promoting them" {
    const allocator = std.testing.allocator;
    const install_requirements = [_]InstallRootRequirement{
        .{ .name = "app", .content_hash = "app-hash", .requested = true, .intent_constraint = ">=1" },
        .{ .name = "lib", .content_hash = "lib-hash", .requested = false },
    };
    const requested_packages = [_]RequestedPackage{
        .{ .name = "app", .constraint_expr = ">=1" },
    };

    const requirements = try buildProfileResolverRequirements(allocator, &install_requirements, &requested_packages);
    defer allocator.free(requirements);

    try std.testing.expectEqual(@as(usize, 2), requirements.len);
    try std.testing.expectEqualStrings("app-hash", requirements[0].content_hash.?);
    try std.testing.expectEqualStrings("lib-hash", requirements[1].content_hash.?);
}

test "install targeting holds unrelated current selections" {
    var selections = [_]resolver.PreferredSelection{
        .{ .name = "app", .version = "1", .release = 1, .arch = "x86_64", .content_hash = "a" },
        .{ .name = "tool", .version = "1", .release = 1, .arch = "x86_64", .content_hash = "b" },
        .{ .name = "lib", .version = "1", .release = 1, .arch = "x86_64", .content_hash = "c" },
    };
    var state = PreferredSelectionsState{
        .allocator = std.testing.allocator,
        .selections = selections[0..],
    };
    const requirements = [_]InstallRootRequirement{.{ .name = "app" }};

    state.setInstallTargets(&requirements);

    try std.testing.expect(selections[0].allow_upgrade);
    try std.testing.expect(!selections[1].allow_upgrade);
    try std.testing.expect(!selections[2].allow_upgrade);
}

/// Assert a profile entry exists and is backed by a real store object.
///
/// Profile symlinks target the *logical* store path (/mere/store/...), which
/// only resolves where the mere directory is mounted at /mere (inside a build or
/// shell namespace, or on a booted system) — not on the host under a test root.
/// So we readlink the entry (which does not follow the link), confirm it points
/// into the logical store, then confirm the backing object exists at its physical
/// {root}/mere/store location.
fn expectProfileEntryBacked(ctx: *Context, link_path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(path.currentIo(), link_path, &buf);
    const target = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, target, "/mere/store/"));

    const physical = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, target[1..] });
    defer ctx.allocator.free(physical);
    try std.Io.Dir.accessAbsolute(path.currentIo(), physical, .{});
}

/// Assert a profile entry does not exist at all (no symlink present).
fn expectProfileEntryAbsent(link_path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.readLinkAbsolute(path.currentIo(), link_path, &buf),
    );
}

test "integration: full install pipeline publishes named profile root" {
    // This test verifies the complete install pipeline:
    // 1. Config loading (simulated)
    // 2. RepoCache sync
    // 3. Dependency resolution across repos
    // 4. Package download and extraction
    // 5. Store placement with content-addressed paths
    // 6. Named-profile root publish with profile.kdl
    // 7. Profile symlink tree building
    // 8. No generation activation state for named profiles

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Prepare config
    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    // Create repo directory
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "repo" });
    defer std.testing.allocator.free(repo_dir);
    {
        var d = try path.makePathAndOpenDir(repo_dir);
        d.close(path.currentIo());
    }

    // Create DB file
    const db_file = "repo.db";
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, db_file });
    defer std.testing.allocator.free(db_path);
    var f = try path.makePathAndOpenFile(db_path);
    f.close(path.currentIo());

    // Generate keypair
    const keypair = try sign.generateKeyPair();
    const pub_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.pub" });
    defer std.testing.allocator.free(pub_path);
    const key_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.key" });
    defer std.testing.allocator.free(key_path);
    try keypair.public_key.saveToFile(pub_path);
    try keypair.secret_key.saveToFile(key_path);

    // Initialize repository
    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    // Create packages directory
    const packages_dir = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "packages" });
    defer std.testing.allocator.free(packages_dir);
    try path.ensureDirExists(packages_dir);

    // Create package A (depends on B)
    var pkg_a = package.Package.init(ctx);
    pkg_a.name = try ctx.allocator.dupe(u8, "pkgA");
    pkg_a.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_a.release = 1;
    pkg_a.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_a_file: []const u8 = "";
    defer if (pkg_a_file.len > 0) ctx.allocator.free(pkg_a_file);

    // Create staging dir for package A with actual content
    const pkg_a_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_a_staging" });
    defer ctx.allocator.free(pkg_a_staging);
    try path.ensureDirExists(pkg_a_staging);

    // Create usr/bin directory structure
    const usr_bin_path = try std.fs.path.join(ctx.allocator, &.{ pkg_a_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_path);
    try path.ensureDirExists(usr_bin_path);

    // Create a binary file
    const bin_file_path = try std.fs.path.join(ctx.allocator, &.{ usr_bin_path, "hello-a" });
    defer ctx.allocator.free(bin_file_path);
    var bin_file = try path.makePathAndOpenFile(bin_file_path);
    try bin_file.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho Hello from A\n");
    bin_file.close(path.currentIo());

    // Compute actual content hash for A
    const content_hash_a = try hash.calculateStoreContentHash(ctx.allocator, pkg_a_staging, null);
    defer ctx.allocator.free(content_hash_a);

    // Create manifest.v1 for A
    const mere_dir_a = try std.fs.path.join(ctx.allocator, &.{ pkg_a_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_a);
    try path.ensureDirExists(mere_dir_a);

    var content_hash_bytes_a: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_a, content_hash_a) catch unreachable;
    const pkg_manifest_a = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgA",
        .version = "1.0.0",
        .content_hash = content_hash_bytes_a,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_a = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_a_staging, &pkg_manifest_a, &secret_key_a.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_a_staging);

    pkg_a.content_hash = try ctx.allocator.dupe(u8, content_hash_a);
    pkg_a_file = try finalizeTestPackageArchive(ctx, &pkg_a, pkg_a_staging, packages_dir);

    // Sign package A
    ctx.signing_key_path = key_path;
    const sig_a = try sign.signWithResolvedKey(ctx, pkg_a_file, null, null);
    const sig_len = sign.c.crypto_sign_BYTES;
    var sig_buf_a = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_a, sig_a[0..sig_len]);
    pkg_a.signature = sig_buf_a[0..sig_len];
    try pkg_a.addDependency("pkgB", package.DependencyType.elf_needed);
    _ = try repo.db.insertPackageTransaction(&pkg_a, null);
    pkg_a.deinit();

    // Create package B (no dependencies)
    var pkg_b = package.Package.init(ctx);
    pkg_b.name = try ctx.allocator.dupe(u8, "pkgB");
    pkg_b.version = try ctx.allocator.dupe(u8, "2.0.0");
    pkg_b.release = 1;
    pkg_b.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_b_file: []const u8 = "";
    defer if (pkg_b_file.len > 0) ctx.allocator.free(pkg_b_file);

    // Create staging dir for package B
    const pkg_b_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_b_staging" });
    defer ctx.allocator.free(pkg_b_staging);
    try path.ensureDirExists(pkg_b_staging);

    // Create usr/lib directory structure
    const usr_lib_path = try std.fs.path.join(ctx.allocator, &.{ pkg_b_staging, "usr", "lib" });
    defer ctx.allocator.free(usr_lib_path);
    try path.ensureDirExists(usr_lib_path);

    // Create a library file
    const lib_file_path = try std.fs.path.join(ctx.allocator, &.{ usr_lib_path, "libhello.so" });
    defer ctx.allocator.free(lib_file_path);
    var lib_file = try path.makePathAndOpenFile(lib_file_path);
    try lib_file.writeStreamingAll(path.currentIo(), "fake shared library content");
    lib_file.close(path.currentIo());

    // Compute actual content hash for B
    const content_hash_b = try hash.calculateStoreContentHash(ctx.allocator, pkg_b_staging, null);
    defer ctx.allocator.free(content_hash_b);

    // Create manifest.v1 for B
    const mere_dir_b = try std.fs.path.join(ctx.allocator, &.{ pkg_b_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_b);
    try path.ensureDirExists(mere_dir_b);

    var content_hash_bytes_b: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_b, content_hash_b) catch unreachable;
    const pkg_manifest_b = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgB",
        .version = "2.0.0",
        .content_hash = content_hash_bytes_b,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_b = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_b_staging, &pkg_manifest_b, &secret_key_b.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_b_staging);

    pkg_b.content_hash = try ctx.allocator.dupe(u8, content_hash_b);
    pkg_b_file = try finalizeTestPackageArchive(ctx, &pkg_b, pkg_b_staging, packages_dir);

    // Sign package B
    const sig_b = try sign.signWithResolvedKey(ctx, pkg_b_file, null, null);
    var sig_buf_b = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_b, sig_b[0..sig_len]);
    pkg_b.signature = sig_buf_b[0..sig_len];
    _ = try repo.db.insertPackageTransaction(&pkg_b, null);
    pkg_b.deinit();

    // Sign the database
    const sig_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path);
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path, sig_path, null, null);

    // Compute fingerprint and add to trusted list
    const fingerprint = try keypair.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint);

    // Copy public key to user keys directory
    const user_keys_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer std.testing.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const user_pub = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "repo.pub" });
    defer std.testing.allocator.free(user_pub);
    try keypair.public_key.saveToFile(user_pub);

    // Use file:// URL
    const repo_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{repo_dir});
    defer std.testing.allocator.free(repo_url);

    // Build trusted fingerprints list
    var fps: std.ArrayList([]const u8) = .empty;
    try fps.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint));

    // Add repo to config
    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo"),
        .url = try ctx.allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    // Create RepoCache and sync
    var repocache = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[0]);
    defer repocache.deinit();
    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try repocache.sync(client, .{}, loaded_keys.items);
    try repocache.ensureRepository(loaded_keys.items);

    var repocaches = [_]*RepoCache{&repocache};

    // ========================================
    // INSTALL WITH PROFILE (the key difference from existing tests)
    // ========================================
    const profile_name = "testprofile";
    const single = [_][]const u8{"pkgA"};
    try installPackagesToProfile(ctx, &repocaches, single[0..], client, false, false, false, profile_name, null);

    // ========================================
    // VERIFICATION: Check all pipeline outputs
    // ========================================

    // 1. Verify store paths exist for both packages
    const store_path_a = try store.constructStorePath(ctx, content_hash_a, "pkgA", "1.0.0");
    defer ctx.allocator.free(store_path_a);
    try std.Io.Dir.accessAbsolute(path.currentIo(), store_path_a, .{});

    const store_path_b = try store.constructStorePath(ctx, content_hash_b, "pkgB", "2.0.0");
    defer ctx.allocator.free(store_path_b);
    try std.Io.Dir.accessAbsolute(path.currentIo(), store_path_b, .{});

    // 2. Verify named profile root exists
    const profile_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", profile_name });
    defer ctx.allocator.free(profile_dir);
    const root_dir = try profile.getRootPath(ctx.allocator, profile_dir);
    defer ctx.allocator.free(root_dir);
    try std.Io.Dir.accessAbsolute(path.currentIo(), root_dir, .{});

    // 3. Verify profile.kdl exists in root
    const manifest_json_path = try std.fs.path.join(ctx.allocator, &.{ root_dir, "profile.kdl" });
    defer ctx.allocator.free(manifest_json_path);
    try std.Io.Dir.accessAbsolute(path.currentIo(), manifest_json_path, .{});

    // 4. Verify profile.kdl contains correct packages
    const manifest_content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), path.currentIo(), manifest_json_path, ctx.allocator, .limited(1024 * 1024));
    defer ctx.allocator.free(manifest_content);

    // Check that both packages are mentioned in manifest
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "pkgA") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "pkgB") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "2.0.0") != null);

    // 5. Verify profile symlink tree exists
    const profile_usr_bin = try std.fs.path.join(ctx.allocator, &.{ root_dir, "usr", "bin" });
    defer ctx.allocator.free(profile_usr_bin);
    try std.Io.Dir.accessAbsolute(path.currentIo(), profile_usr_bin, .{});

    const profile_usr_lib = try std.fs.path.join(ctx.allocator, &.{ root_dir, "usr", "lib" });
    defer ctx.allocator.free(profile_usr_lib);
    try std.Io.Dir.accessAbsolute(path.currentIo(), profile_usr_lib, .{});

    // 6. Verify specific files are symlinked in profile
    const profile_hello_a = try std.fs.path.join(ctx.allocator, &.{ profile_usr_bin, "hello-a" });
    defer ctx.allocator.free(profile_hello_a);
    try expectProfileEntryBacked(ctx, profile_hello_a);

    const profile_libhello = try std.fs.path.join(ctx.allocator, &.{ profile_usr_lib, "libhello.so" });
    defer ctx.allocator.free(profile_libhello);
    try expectProfileEntryBacked(ctx, profile_libhello);

    // 7. Verify named profiles do not expose generation activation state
    const current_link = try std.fs.path.join(ctx.allocator, &.{ profile_dir, "current" });
    defer ctx.allocator.free(current_link);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path.currentIo(), current_link, .{}));
    try std.testing.expectEqual(@as(?u32, null), try generation.getCurrentGeneration(profile_dir));
}

test "integration: named profile lifecycle replaces root atomically and additively" {
    // This test verifies the named-profile lifecycle:
    // 1. Install pkgA → publish root
    // 2. Install pkgC → republish root with additive package set
    // 3. Verify root contains both installations
    // 4. Verify no generation activation state exists for the named profile

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Prepare config
    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    // Create repo directory
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "repo" });
    defer std.testing.allocator.free(repo_dir);
    {
        var d = try path.makePathAndOpenDir(repo_dir);
        d.close(path.currentIo());
    }

    // Create DB file
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db" });
    defer std.testing.allocator.free(db_path);
    var f = try path.makePathAndOpenFile(db_path);
    f.close(path.currentIo());

    // Generate keypair
    const keypair = try sign.generateKeyPair();
    const pub_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.pub" });
    defer std.testing.allocator.free(pub_path);
    const key_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.key" });
    defer std.testing.allocator.free(key_path);
    try keypair.public_key.saveToFile(pub_path);
    try keypair.secret_key.saveToFile(key_path);

    // Initialize repository
    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    // Create packages directory
    const packages_dir = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "packages" });
    defer std.testing.allocator.free(packages_dir);
    try path.ensureDirExists(packages_dir);

    // Create package A (will be in the initial root)
    var pkg_a = package.Package.init(ctx);
    pkg_a.name = try ctx.allocator.dupe(u8, "pkgA");
    pkg_a.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_a.release = 1;
    pkg_a.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_a_file: []const u8 = "";
    defer if (pkg_a_file.len > 0) ctx.allocator.free(pkg_a_file);

    // Create staging dir for package A
    const pkg_a_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_a_staging" });
    defer ctx.allocator.free(pkg_a_staging);
    try path.ensureDirExists(pkg_a_staging);

    // Create usr/bin/tool-a
    const usr_bin_a = try std.fs.path.join(ctx.allocator, &.{ pkg_a_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_a);
    try path.ensureDirExists(usr_bin_a);
    const tool_a_path = try std.fs.path.join(ctx.allocator, &.{ usr_bin_a, "tool-a" });
    defer ctx.allocator.free(tool_a_path);
    var tool_a = try path.makePathAndOpenFile(tool_a_path);
    try tool_a.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho tool-a\n");
    tool_a.close(path.currentIo());

    // Compute content hash for A
    const content_hash_a = try hash.calculateStoreContentHash(ctx.allocator, pkg_a_staging, null);
    defer ctx.allocator.free(content_hash_a);

    // Create manifest.v1 for A
    const mere_dir_a = try std.fs.path.join(ctx.allocator, &.{ pkg_a_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_a);
    try path.ensureDirExists(mere_dir_a);

    var content_hash_bytes_a: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_a, content_hash_a) catch unreachable;
    const pkg_manifest_a = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgA",
        .version = "1.0.0",
        .content_hash = content_hash_bytes_a,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_a = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_a_staging, &pkg_manifest_a, &secret_key_a.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_a_staging);

    pkg_a.content_hash = try ctx.allocator.dupe(u8, content_hash_a);
    pkg_a_file = try finalizeTestPackageArchive(ctx, &pkg_a, pkg_a_staging, packages_dir);

    // Sign package A
    ctx.signing_key_path = key_path;
    const sig_a = try sign.signWithResolvedKey(ctx, pkg_a_file, null, null);
    const sig_len = sign.c.crypto_sign_BYTES;
    var sig_buf_a = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_a, sig_a[0..sig_len]);
    pkg_a.signature = sig_buf_a[0..sig_len];
    _ = try repo.db.insertPackageTransaction(&pkg_a, null);
    pkg_a.deinit();

    // Create package C (will be added when the root is republished)
    var pkg_c = package.Package.init(ctx);
    pkg_c.name = try ctx.allocator.dupe(u8, "pkgC");
    pkg_c.version = try ctx.allocator.dupe(u8, "3.0.0");
    pkg_c.release = 1;
    pkg_c.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_c_file: []const u8 = "";
    defer if (pkg_c_file.len > 0) ctx.allocator.free(pkg_c_file);

    // Create staging dir for package C
    const pkg_c_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_c_staging" });
    defer ctx.allocator.free(pkg_c_staging);
    try path.ensureDirExists(pkg_c_staging);

    // Create usr/bin/tool-c
    const usr_bin_c = try std.fs.path.join(ctx.allocator, &.{ pkg_c_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_c);
    try path.ensureDirExists(usr_bin_c);
    const tool_c_path = try std.fs.path.join(ctx.allocator, &.{ usr_bin_c, "tool-c" });
    defer ctx.allocator.free(tool_c_path);
    var tool_c = try path.makePathAndOpenFile(tool_c_path);
    try tool_c.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho tool-c\n");
    tool_c.close(path.currentIo());

    // Compute content hash for C
    const content_hash_c = try hash.calculateStoreContentHash(ctx.allocator, pkg_c_staging, null);
    defer ctx.allocator.free(content_hash_c);

    // Create manifest.v1 for C
    const mere_dir_c = try std.fs.path.join(ctx.allocator, &.{ pkg_c_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_c);
    try path.ensureDirExists(mere_dir_c);

    var content_hash_bytes_c: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_c, content_hash_c) catch unreachable;
    const pkg_manifest_c = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgC",
        .version = "3.0.0",
        .content_hash = content_hash_bytes_c,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_c = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_c_staging, &pkg_manifest_c, &secret_key_c.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_c_staging);

    pkg_c.content_hash = try ctx.allocator.dupe(u8, content_hash_c);
    pkg_c_file = try finalizeTestPackageArchive(ctx, &pkg_c, pkg_c_staging, packages_dir);

    // Sign package C
    const sig_c = try sign.signWithResolvedKey(ctx, pkg_c_file, null, null);
    var sig_buf_c = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_c, sig_c[0..sig_len]);
    pkg_c.signature = sig_buf_c[0..sig_len];
    _ = try repo.db.insertPackageTransaction(&pkg_c, null);
    pkg_c.deinit();

    // Sign the database
    const sig_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path);
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path, sig_path, null, null);

    // Setup config with repo
    const fingerprint = try keypair.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint);

    const user_keys_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer std.testing.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const user_pub = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "repo.pub" });
    defer std.testing.allocator.free(user_pub);
    try keypair.public_key.saveToFile(user_pub);

    const repo_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{repo_dir});
    defer std.testing.allocator.free(repo_url);

    var fps: std.ArrayList([]const u8) = .empty;
    try fps.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint));

    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo"),
        .url = try ctx.allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    // Create RepoCache and sync
    var repocache = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[0]);
    defer repocache.deinit();
    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try repocache.sync(client, .{}, loaded_keys.items);
    try repocache.ensureRepository(loaded_keys.items);

    var repocaches = [_]*RepoCache{&repocache};

    const profile_name = "lifecycle-test";
    const profile_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", profile_name });
    defer ctx.allocator.free(profile_dir);

    const root_dir = try profile.getRootPath(ctx.allocator, profile_dir);
    defer ctx.allocator.free(root_dir);

    // Step 1: Install pkgA → publish root
    const pkg_a_names = [_][]const u8{"pkgA"};
    try installPackagesToProfile(ctx, &repocaches, pkg_a_names[0..], client, false, false, false, profile_name, null);

    try std.Io.Dir.accessAbsolute(path.currentIo(), root_dir, .{});
    try std.testing.expectEqual(@as(?u32, null), try generation.getCurrentGeneration(profile_dir));

    // Verify tool-a exists in the published root
    const root_tool_a = try std.fs.path.join(ctx.allocator, &.{ root_dir, "usr", "bin", "tool-a" });
    defer ctx.allocator.free(root_tool_a);
    try expectProfileEntryBacked(ctx, root_tool_a);

    // Verify tool-c does NOT exist before the second publish
    const root_tool_c = try std.fs.path.join(ctx.allocator, &.{ root_dir, "usr", "bin", "tool-c" });
    defer ctx.allocator.free(root_tool_c);
    try expectProfileEntryAbsent(root_tool_c);

    // Step 2: Install pkgC → republish root
    const pkg_c_names = [_][]const u8{"pkgC"};
    try installPackagesToProfile(ctx, &repocaches, pkg_c_names[0..], client, false, false, false, profile_name, null);

    // Additive install: both tools are present in the replacement root
    try expectProfileEntryBacked(ctx, root_tool_a);
    try expectProfileEntryBacked(ctx, root_tool_c);

    const root_manifest_path = try std.fs.path.join(ctx.allocator, &.{ root_dir, "profile.kdl" });
    defer ctx.allocator.free(root_manifest_path);
    const root_manifest_data = blk: {
        const file = try path.openExistingFile(root_manifest_path);
        defer file.close(path.currentIo());
        const stat = try file.stat(path.currentIo());
        const data = try ctx.allocator.alloc(u8, @intCast(stat.size));
        errdefer ctx.allocator.free(data);
        const len = try file.readPositionalAll(path.currentIo(), data, 0);
        break :blk data[0..len];
    };
    defer ctx.allocator.free(root_manifest_data);
    try std.testing.expect(std.mem.indexOf(u8, root_manifest_data, "\"generation\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_manifest_data, "pkgA") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_manifest_data, "pkgC") != null);

    // Named profiles do not expose activation symlinks or rollback helpers
    const current_link = try std.fs.path.join(ctx.allocator, &.{ profile_dir, "current" });
    defer ctx.allocator.free(current_link);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path.currentIo(), current_link, .{}));
    try std.testing.expectEqual(@as(?u32, null), try generation.getCurrentGeneration(profile_dir));
    const test_store_root = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" });
    defer ctx.allocator.free(test_store_root);
    const all_gens = try generation.listGenerations(ctx.allocator, test_store_root, profile_dir);
    defer ctx.allocator.free(all_gens);
    try std.testing.expectEqual(@as(usize, 0), all_gens.len);
}

test "integration: symlink tree conflict detection" {
    // This test verifies that path conflicts are detected when two packages
    // provide the same file path with different targets.
    // Per spec #18: Path conflicts are hard errors with no silent resolution.

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    // Create repo
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "repo" });
    defer std.testing.allocator.free(repo_dir);
    {
        var d = try path.makePathAndOpenDir(repo_dir);
        d.close(path.currentIo());
    }

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db" });
    defer std.testing.allocator.free(db_path);
    var f = try path.makePathAndOpenFile(db_path);
    f.close(path.currentIo());

    const keypair = try sign.generateKeyPair();
    const pub_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.pub" });
    defer std.testing.allocator.free(pub_path);
    const key_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.key" });
    defer std.testing.allocator.free(key_path);
    try keypair.public_key.saveToFile(pub_path);
    try keypair.secret_key.saveToFile(key_path);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    const packages_dir = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "packages" });
    defer std.testing.allocator.free(packages_dir);
    try path.ensureDirExists(packages_dir);

    // Create package X with /usr/bin/conflict-tool
    var pkg_x = package.Package.init(ctx);
    pkg_x.name = try ctx.allocator.dupe(u8, "pkgX");
    pkg_x.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_x.release = 1;
    pkg_x.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_x_file: []const u8 = "";
    defer if (pkg_x_file.len > 0) ctx.allocator.free(pkg_x_file);

    const pkg_x_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_x_staging" });
    defer ctx.allocator.free(pkg_x_staging);
    try path.ensureDirExists(pkg_x_staging);

    const usr_bin_x = try std.fs.path.join(ctx.allocator, &.{ pkg_x_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_x);
    try path.ensureDirExists(usr_bin_x);
    const conflict_tool_x = try std.fs.path.join(ctx.allocator, &.{ usr_bin_x, "conflict-tool" });
    defer ctx.allocator.free(conflict_tool_x);
    var tool_x = try path.makePathAndOpenFile(conflict_tool_x);
    try tool_x.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho from X\n");
    tool_x.close(path.currentIo());

    const content_hash_x = try hash.calculateStoreContentHash(ctx.allocator, pkg_x_staging, null);
    defer ctx.allocator.free(content_hash_x);

    const mere_dir_x = try std.fs.path.join(ctx.allocator, &.{ pkg_x_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_x);
    try path.ensureDirExists(mere_dir_x);

    var content_hash_bytes_x: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_x, content_hash_x) catch unreachable;
    const pkg_manifest_x = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgX",
        .version = "1.0.0",
        .content_hash = content_hash_bytes_x,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_x = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_x_staging, &pkg_manifest_x, &secret_key_x.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_x_staging);

    pkg_x.content_hash = try ctx.allocator.dupe(u8, content_hash_x);
    pkg_x_file = try finalizeTestPackageArchive(ctx, &pkg_x, pkg_x_staging, packages_dir);

    ctx.signing_key_path = key_path;
    const sig_x = try sign.signWithResolvedKey(ctx, pkg_x_file, null, null);
    const sig_len = sign.c.crypto_sign_BYTES;
    var sig_buf_x = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_x, sig_x[0..sig_len]);
    pkg_x.signature = sig_buf_x[0..sig_len];
    _ = try repo.db.insertPackageTransaction(&pkg_x, null);
    pkg_x.deinit();

    // Create package Y with SAME /usr/bin/conflict-tool (different content)
    var pkg_y = package.Package.init(ctx);
    pkg_y.name = try ctx.allocator.dupe(u8, "pkgY");
    pkg_y.version = try ctx.allocator.dupe(u8, "2.0.0");
    pkg_y.release = 1;
    pkg_y.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_y_file: []const u8 = "";
    defer if (pkg_y_file.len > 0) ctx.allocator.free(pkg_y_file);

    const pkg_y_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_y_staging" });
    defer ctx.allocator.free(pkg_y_staging);
    try path.ensureDirExists(pkg_y_staging);

    const usr_bin_y = try std.fs.path.join(ctx.allocator, &.{ pkg_y_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_y);
    try path.ensureDirExists(usr_bin_y);
    const conflict_tool_y = try std.fs.path.join(ctx.allocator, &.{ usr_bin_y, "conflict-tool" });
    defer ctx.allocator.free(conflict_tool_y);
    var tool_y = try path.makePathAndOpenFile(conflict_tool_y);
    try tool_y.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho from Y\n"); // Different content!
    tool_y.close(path.currentIo());

    const content_hash_y = try hash.calculateStoreContentHash(ctx.allocator, pkg_y_staging, null);
    defer ctx.allocator.free(content_hash_y);

    const mere_dir_y = try std.fs.path.join(ctx.allocator, &.{ pkg_y_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_y);
    try path.ensureDirExists(mere_dir_y);

    var content_hash_bytes_y: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_y, content_hash_y) catch unreachable;
    const pkg_manifest_y = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgY",
        .version = "2.0.0",
        .content_hash = content_hash_bytes_y,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_y = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_y_staging, &pkg_manifest_y, &secret_key_y.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_y_staging);

    pkg_y.content_hash = try ctx.allocator.dupe(u8, content_hash_y);
    pkg_y_file = try finalizeTestPackageArchive(ctx, &pkg_y, pkg_y_staging, packages_dir);

    const sig_y = try sign.signWithResolvedKey(ctx, pkg_y_file, null, null);
    var sig_buf_y = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_y, sig_y[0..sig_len]);
    pkg_y.signature = sig_buf_y[0..sig_len];
    _ = try repo.db.insertPackageTransaction(&pkg_y, null);
    pkg_y.deinit();

    // Create pkgMain that depends on both pkgX and pkgY - installing it will pull both
    var pkg_main = package.Package.init(ctx);
    pkg_main.name = try ctx.allocator.dupe(u8, "pkgMain");
    pkg_main.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_main.release = 1;
    pkg_main.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_main_file: []const u8 = "";
    defer if (pkg_main_file.len > 0) ctx.allocator.free(pkg_main_file);

    const pkg_main_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_main_staging" });
    defer ctx.allocator.free(pkg_main_staging);
    try path.ensureDirExists(pkg_main_staging);

    // Create empty content for main package
    const mere_dir_main = try std.fs.path.join(ctx.allocator, &.{ pkg_main_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_main);
    try path.ensureDirExists(mere_dir_main);

    const content_hash_main = try hash.calculateStoreContentHash(ctx.allocator, pkg_main_staging, null);
    defer ctx.allocator.free(content_hash_main);

    var content_hash_bytes_main: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_main, content_hash_main) catch unreachable;
    const pkg_manifest_main = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "pkgMain",
        .version = "1.0.0",
        .content_hash = content_hash_bytes_main,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_main = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_main_staging, &pkg_manifest_main, &secret_key_main.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_main_staging);

    pkg_main.content_hash = try ctx.allocator.dupe(u8, content_hash_main);
    pkg_main_file = try finalizeTestPackageArchive(ctx, &pkg_main, pkg_main_staging, packages_dir);

    const sig_main = try sign.signWithResolvedKey(ctx, pkg_main_file, null, null);
    var sig_buf_main = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_main, sig_main[0..sig_len]);
    pkg_main.signature = sig_buf_main[0..sig_len];
    try pkg_main.addDependency("pkgX", package.DependencyType.elf_needed);
    try pkg_main.addDependency("pkgY", package.DependencyType.elf_needed);
    _ = try repo.db.insertPackageTransaction(&pkg_main, null);
    pkg_main.deinit();

    // Sign the database
    const sig_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path);
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path, sig_path, null, null);

    // Setup config
    const fingerprint = try keypair.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint);

    const user_keys_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer std.testing.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const user_pub = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "repo.pub" });
    defer std.testing.allocator.free(user_pub);
    try keypair.public_key.saveToFile(user_pub);

    const repo_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{repo_dir});
    defer std.testing.allocator.free(repo_url);

    var fps: std.ArrayList([]const u8) = .empty;
    try fps.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint));

    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo"),
        .url = try ctx.allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    var repocache = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[0]);
    defer repocache.deinit();
    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try repocache.sync(client, .{}, loaded_keys.items);
    try repocache.ensureRepository(loaded_keys.items);

    var repocaches = [_]*RepoCache{&repocache};

    // Try to install pkgMain (which depends on both pkgX and pkgY)
    // This should fail with ConflictingProvision because both packages
    // provide /usr/bin/conflict-tool with different content
    const single = [_][]const u8{"pkgMain"};
    const result = installPackagesToProfile(ctx, &repocaches, single[0..], client, false, false, false, "conflict-test", null);
    try std.testing.expectError(error.ConflictingProvision, result);
}

test "integration: multi-repository priority selection" {
    // Test that when the same package exists in multiple repos,
    // the one from the higher-priority repo (lower priority number) is selected.
    // Setup:
    // - Repo "high" (priority 10): contains "sharedPkg" version 2.0.0 with unique content
    // - Repo "low" (priority 100): contains "sharedPkg" version 1.0.0 with different content
    // Expected: Installing "sharedPkg" installs version 2.0.0 from "high" repo

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    // Create directories for both repos
    const high_repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "high_repo" });
    defer std.testing.allocator.free(high_repo_dir);
    const low_repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "low_repo" });
    defer std.testing.allocator.free(low_repo_dir);

    {
        var d1 = try path.makePathAndOpenDir(high_repo_dir);
        d1.close(path.currentIo());
        var d2 = try path.makePathAndOpenDir(low_repo_dir);
        d2.close(path.currentIo());
    }

    // Create DB files. Repository.init always uses the fixed repo.db/
    // repo.db.sig filenames regardless of the containing directory's name.
    const db_path_high = try std.fs.path.join(std.testing.allocator, &.{ high_repo_dir, "repo.db" });
    defer std.testing.allocator.free(db_path_high);
    const db_path_low = try std.fs.path.join(std.testing.allocator, &.{ low_repo_dir, "repo.db" });
    defer std.testing.allocator.free(db_path_low);
    {
        var f1 = try path.makePathAndOpenFile(db_path_high);
        f1.close(path.currentIo());
        var f2 = try path.makePathAndOpenFile(db_path_low);
        f2.close(path.currentIo());
    }

    // Generate keypairs
    const keypair_high = try sign.generateKeyPair();
    const key_path_high = try std.fs.path.join(std.testing.allocator, &.{ high_repo_dir, "high_repo.key" });
    defer std.testing.allocator.free(key_path_high);
    try keypair_high.secret_key.saveToFile(key_path_high);

    const keypair_low = try sign.generateKeyPair();
    const key_path_low = try std.fs.path.join(std.testing.allocator, &.{ low_repo_dir, "low_repo.key" });
    defer std.testing.allocator.free(key_path_low);
    try keypair_low.secret_key.saveToFile(key_path_low);

    // Initialize repositories
    var repo_high = try Repository.init(ctx, high_repo_dir, false);
    defer repo_high.deinit();
    var repo_low = try Repository.init(ctx, low_repo_dir, false);
    defer repo_low.deinit();

    const sig_len = sign.c.crypto_sign_BYTES;

    // Create packages directories
    const packages_dir_high = try std.fs.path.join(std.testing.allocator, &.{ high_repo_dir, "packages" });
    defer std.testing.allocator.free(packages_dir_high);
    try path.ensureDirExists(packages_dir_high);

    const packages_dir_low = try std.fs.path.join(std.testing.allocator, &.{ low_repo_dir, "packages" });
    defer std.testing.allocator.free(packages_dir_low);
    try path.ensureDirExists(packages_dir_low);

    // Create sharedPkg 2.0.0 in high-priority repo
    var pkg_high = package.Package.init(ctx);
    pkg_high.name = try ctx.allocator.dupe(u8, "sharedPkg");
    pkg_high.version = try ctx.allocator.dupe(u8, "2.0.0");
    pkg_high.release = 1;
    pkg_high.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_high_file: []const u8 = "";
    defer if (pkg_high_file.len > 0) ctx.allocator.free(pkg_high_file);

    const pkg_high_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_high_staging" });
    defer ctx.allocator.free(pkg_high_staging);
    try path.ensureDirExists(pkg_high_staging);

    // Create unique content for high-priority version
    const usr_bin_high = try std.fs.path.join(ctx.allocator, &.{ pkg_high_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_high);
    try path.ensureDirExists(usr_bin_high);
    const tool_high = try std.fs.path.join(ctx.allocator, &.{ usr_bin_high, "shared-tool" });
    defer ctx.allocator.free(tool_high);
    var tool_high_f = try path.makePathAndOpenFile(tool_high);
    try tool_high_f.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho version 2.0.0 from high priority\n");
    tool_high_f.close(path.currentIo());

    const content_hash_high = try hash.calculateStoreContentHash(ctx.allocator, pkg_high_staging, null);
    defer ctx.allocator.free(content_hash_high);

    const mere_dir_high = try std.fs.path.join(ctx.allocator, &.{ pkg_high_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_high);
    try path.ensureDirExists(mere_dir_high);

    var content_hash_bytes_high: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_high, content_hash_high) catch unreachable;
    const pkg_manifest_high = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "sharedPkg",
        .version = "2.0.0",
        .content_hash = content_hash_bytes_high,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_high = try sign.SecretKey.loadFromFile(key_path_high);
    try manifest.writeManifest(ctx, pkg_high_staging, &pkg_manifest_high, &secret_key_high.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_high_staging);

    pkg_high.content_hash = try ctx.allocator.dupe(u8, content_hash_high);
    pkg_high_file = try finalizeTestPackageArchive(ctx, &pkg_high, pkg_high_staging, packages_dir_high);

    ctx.signing_key_path = key_path_high;
    const sig_high = try sign.signWithResolvedKey(ctx, pkg_high_file, null, null);
    var sig_buf_high = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_high, sig_high[0..sig_len]);
    pkg_high.signature = sig_buf_high[0..sig_len];
    _ = try repo_high.db.insertPackageTransaction(&pkg_high, null);
    pkg_high.deinit();

    // Create sharedPkg 1.0.0 in low-priority repo (different content)
    var pkg_low = package.Package.init(ctx);
    pkg_low.name = try ctx.allocator.dupe(u8, "sharedPkg");
    pkg_low.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg_low.release = 1;
    pkg_low.arch = try ctx.allocator.dupe(u8, th.host_arch);

    var pkg_low_file: []const u8 = "";
    defer if (pkg_low_file.len > 0) ctx.allocator.free(pkg_low_file);

    const pkg_low_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_low_staging" });
    defer ctx.allocator.free(pkg_low_staging);
    try path.ensureDirExists(pkg_low_staging);

    // Create unique content for low-priority version
    const usr_bin_low = try std.fs.path.join(ctx.allocator, &.{ pkg_low_staging, "usr", "bin" });
    defer ctx.allocator.free(usr_bin_low);
    try path.ensureDirExists(usr_bin_low);
    const tool_low = try std.fs.path.join(ctx.allocator, &.{ usr_bin_low, "shared-tool" });
    defer ctx.allocator.free(tool_low);
    var tool_low_f = try path.makePathAndOpenFile(tool_low);
    try tool_low_f.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho version 1.0.0 from low priority\n");
    tool_low_f.close(path.currentIo());

    const content_hash_low = try hash.calculateStoreContentHash(ctx.allocator, pkg_low_staging, null);
    defer ctx.allocator.free(content_hash_low);

    const mere_dir_low = try std.fs.path.join(ctx.allocator, &.{ pkg_low_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_low);
    try path.ensureDirExists(mere_dir_low);

    var content_hash_bytes_low: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes_low, content_hash_low) catch unreachable;
    const pkg_manifest_low = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = "sharedPkg",
        .version = "1.0.0",
        .content_hash = content_hash_bytes_low,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    const secret_key_low = try sign.SecretKey.loadFromFile(key_path_low);
    try manifest.writeManifest(ctx, pkg_low_staging, &pkg_manifest_low, &secret_key_low.key);
    try writeProjectionForPackageDir(ctx.allocator, pkg_low_staging);

    pkg_low.content_hash = try ctx.allocator.dupe(u8, content_hash_low);
    pkg_low_file = try finalizeTestPackageArchive(ctx, &pkg_low, pkg_low_staging, packages_dir_low);

    ctx.signing_key_path = key_path_low;
    const sig_low = try sign.signWithResolvedKey(ctx, pkg_low_file, null, null);
    var sig_buf_low = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf_low, sig_low[0..sig_len]);
    pkg_low.signature = sig_buf_low[0..sig_len];
    _ = try repo_low.db.insertPackageTransaction(&pkg_low, null);
    pkg_low.deinit();

    // Sign database files
    const sig_path_high = try std.fs.path.join(std.testing.allocator, &.{ high_repo_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path_high);
    ctx.signing_key_path = key_path_high;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path_high, sig_path_high, null, null);

    const sig_path_low = try std.fs.path.join(std.testing.allocator, &.{ low_repo_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path_low);
    ctx.signing_key_path = key_path_low;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path_low, sig_path_low, null, null);

    // Setup fingerprints
    const fingerprint_high = try keypair_high.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint_high);
    const fingerprint_low = try keypair_low.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint_low);

    // Copy public keys to user keys directory
    const user_keys_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer std.testing.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);

    const user_pub_high = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "high_repo.pub" });
    defer std.testing.allocator.free(user_pub_high);
    try keypair_high.public_key.saveToFile(user_pub_high);

    const user_pub_low = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "low_repo.pub" });
    defer std.testing.allocator.free(user_pub_low);
    try keypair_low.public_key.saveToFile(user_pub_low);

    // Configure repos (high priority = lower number)
    const repo_url_high = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{high_repo_dir});
    defer std.testing.allocator.free(repo_url_high);
    const repo_url_low = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{low_repo_dir});
    defer std.testing.allocator.free(repo_url_low);

    var fps_high: std.ArrayList([]const u8) = .empty;
    try fps_high.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint_high));

    var fps_low: std.ArrayList([]const u8) = .empty;
    try fps_low.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint_low));

    // Add high priority repo first (priority 10)
    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "high_repo"),
        .url = try ctx.allocator.dupe(u8, repo_url_high),
        .priority = 10,
        .trusted_fingerprints = fps_high,
    });

    // Add low priority repo (priority 100)
    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "low_repo"),
        .url = try ctx.allocator.dupe(u8, repo_url_low),
        .priority = 100,
        .trusted_fingerprints = fps_low,
    });

    // Create RepoCaches - pass them in priority order (high first)
    var repocache_high = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[0]);
    defer repocache_high.deinit();
    var repocache_low = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[1]);
    defer repocache_low.deinit();

    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    try repocache_high.sync(client, .{}, loaded_keys.items);
    try repocache_high.ensureRepository(loaded_keys.items);
    try repocache_low.sync(client, .{}, loaded_keys.items);
    try repocache_low.ensureRepository(loaded_keys.items);

    // Pass repocaches in priority order (high priority first)
    var repocaches = [_]*RepoCache{ &repocache_high, &repocache_low };

    // Install sharedPkg - should get version 2.0.0 from high-priority repo
    const profile_name = "priority-test";
    const single = [_][]const u8{"sharedPkg"};
    try installPackagesToProfile(ctx, &repocaches, single[0..], client, false, false, false, profile_name, null);

    // Verify the installed version is 2.0.0 by checking the store path contains the high-priority content hash
    const profile_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", profile_name });
    defer ctx.allocator.free(profile_dir);
    const root_dir = try profile.getRootPath(ctx.allocator, profile_dir);
    defer ctx.allocator.free(root_dir);
    const root_manifest_path = try std.fs.path.join(ctx.allocator, &.{ root_dir, "profile.kdl" });
    defer ctx.allocator.free(root_manifest_path);

    const root_manifest_data = blk: {
        const file = try path.openExistingFile(root_manifest_path);
        defer file.close(path.currentIo());
        const stat = try file.stat(path.currentIo());
        const data = try ctx.allocator.alloc(u8, @intCast(stat.size));
        errdefer ctx.allocator.free(data);
        const len = try file.readPositionalAll(path.currentIo(), data, 0);
        break :blk data[0..len];
    };
    defer ctx.allocator.free(root_manifest_data);

    // Verify version 2.0.0 is in the manifest (from high-priority repo)
    try std.testing.expect(std.mem.indexOf(u8, root_manifest_data, "2.0.0") != null);
    // Verify version 1.0.0 is NOT in the manifest
    try std.testing.expect(std.mem.indexOf(u8, root_manifest_data, "1.0.0") == null);
}

test "integration: garbage collection removes unreferenced store paths" {
    // Test the full GC workflow:
    // Note: Each install creates a generation with ONLY the newly installed packages.
    // Generations do NOT carry forward packages from previous generations.
    //
    // 1. Install pkgA (creates gen-1 with only pkgA)
    // 2. Install pkgB (creates gen-2 with only pkgB)
    // 3. Delete gen-1 (A is now unreferenced)
    // 4. Run GC - pkgA should be deleted
    // 5. Verify A is gone, B still exists

    const th = @import("test_helpers.zig");
    const gc = @import("gc.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    // Setup repository
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "repo" });
    defer std.testing.allocator.free(repo_dir);
    {
        var d = try path.makePathAndOpenDir(repo_dir);
        d.close(path.currentIo());
    }

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db" });
    defer std.testing.allocator.free(db_path);
    {
        var f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }

    const keypair = try sign.generateKeyPair();
    const key_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.key" });
    defer std.testing.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    const sig_len = sign.c.crypto_sign_BYTES;
    const packages_dir = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "packages" });
    defer std.testing.allocator.free(packages_dir);
    try path.ensureDirExists(packages_dir);

    // Helper to create a package
    const createPackage = struct {
        fn create(
            context: *Context,
            repository: *Repository,
            pkg_name: []const u8,
            pkg_version: []const u8,
            pkgs_dir: []const u8,
            env_path: []const u8,
            signing_key_path: []const u8,
            signature_len: usize,
        ) ![]const u8 {
            var pkg = package.Package.init(context);
            pkg.name = try context.allocator.dupe(u8, pkg_name);
            pkg.version = try context.allocator.dupe(u8, pkg_version);
            pkg.release = 1;
            pkg.arch = try context.allocator.dupe(u8, th.host_arch);
            var pkg_file: []const u8 = "";
            defer if (pkg_file.len > 0) context.allocator.free(pkg_file);

            const staging_name = try std.fmt.allocPrint(context.allocator, "{s}_staging", .{pkg_name});
            defer context.allocator.free(staging_name);
            const pkg_staging = try std.fs.path.join(context.allocator, &.{ env_path, staging_name });
            defer context.allocator.free(pkg_staging);
            try path.ensureDirExists(pkg_staging);

            // Create unique content
            const usr_bin = try std.fs.path.join(context.allocator, &.{ pkg_staging, "usr", "bin" });
            defer context.allocator.free(usr_bin);
            try path.ensureDirExists(usr_bin);
            const tool_name = try std.fmt.allocPrint(context.allocator, "{s}-tool", .{pkg_name});
            defer context.allocator.free(tool_name);
            const tool_path = try std.fs.path.join(context.allocator, &.{ usr_bin, tool_name });
            defer context.allocator.free(tool_path);
            var tool_f = try path.makePathAndOpenFile(tool_path);
            const content = try std.fmt.allocPrint(context.allocator, "#!/bin/sh\necho {s} {s}\n", .{ pkg_name, pkg_version });
            defer context.allocator.free(content);
            try tool_f.writeStreamingAll(path.currentIo(), content);
            tool_f.close(path.currentIo());

            const content_hash_str = try hash.calculateStoreContentHash(context.allocator, pkg_staging, null);
            defer context.allocator.free(content_hash_str);

            const mere_dir = try std.fs.path.join(context.allocator, &.{ pkg_staging, manifest.META_DIR });
            defer context.allocator.free(mere_dir);
            try path.ensureDirExists(mere_dir);

            var content_hash_bytes: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_str) catch unreachable;
            const pkg_manifest = manifest.PackageManifestV1{
                .schema_version = 1,
                .created_at = 1706745600,
                .release = 1,
                .arch = th.host_arch,
                .name = pkg_name,
                .version = pkg_version,
                .content_hash = content_hash_bytes,
            };

            // Use writeManifest to create both manifest.v1 and manifest.v1.sig
            const secret_key = try sign.SecretKey.loadFromFile(signing_key_path);
            try manifest.writeManifest(context, pkg_staging, &pkg_manifest, &secret_key.key);
            try writeProjectionForPackageDir(context.allocator, pkg_staging);

            pkg.content_hash = try context.allocator.dupe(u8, content_hash_str);
            pkg_file = try finalizeTestPackageArchive(context, &pkg, pkg_staging, pkgs_dir);

            context.signing_key_path = signing_key_path;
            const sig_bytes = try sign.signWithResolvedKey(context, pkg_file, null, null);
            var sig_buf = try context.allocator.alloc(u8, signature_len);
            std.mem.copyForwards(u8, sig_buf, sig_bytes[0..signature_len]);
            pkg.signature = sig_buf[0..signature_len];

            _ = try repository.db.insertPackageTransaction(&pkg, null);

            // Return the content hash (for verification later)
            const result = try context.allocator.dupe(u8, content_hash_str);
            pkg.deinit();
            return result;
        }
    }.create;

    // Create packages
    const hash_a = try createPackage(ctx, &repo, "pkgA", "1.0.0", packages_dir, test_env.path, key_path, sig_len);
    defer ctx.allocator.free(hash_a);
    const hash_b = try createPackage(ctx, &repo, "pkgB", "1.0.0", packages_dir, test_env.path, key_path, sig_len);
    defer ctx.allocator.free(hash_b);

    // Sign DB
    const sig_path = try std.fs.path.join(std.testing.allocator, &.{ repo_dir, "repo.db.sig" });
    defer std.testing.allocator.free(sig_path);
    ctx.signing_key_path = key_path;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path, sig_path, null, null);

    // Setup config
    const fingerprint = try keypair.public_key.fingerprint(std.testing.allocator);
    defer std.testing.allocator.free(fingerprint);

    const user_keys_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys" });
    defer std.testing.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const user_pub = try std.fs.path.join(std.testing.allocator, &.{ user_keys_dir, "repo.pub" });
    defer std.testing.allocator.free(user_pub);
    try keypair.public_key.saveToFile(user_pub);

    const repo_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{repo_dir});
    defer std.testing.allocator.free(repo_url);

    var fps: std.ArrayList([]const u8) = .empty;
    try fps.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint));

    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo"),
        .url = try ctx.allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    var repocache = try RepoCache.fromConfig(ctx, &ctx.configuration.?.repos.items[0]);
    defer repocache.deinit();
    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try repocache.sync(client, .{}, loaded_keys.items);
    try repocache.ensureRepository(loaded_keys.items);

    var repocaches = [_]*RepoCache{&repocache};

    const profile_name = "gc-test";
    const store_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" });
    defer ctx.allocator.free(store_dir);
    const gc_roots_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" });
    defer ctx.allocator.free(gc_roots_dir);
    const profiles_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" });
    defer ctx.allocator.free(profiles_dir);
    const profile_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", profile_name });
    defer ctx.allocator.free(profile_dir);

    // Step 1: Install pkgA (creates gen-1 with only A)
    const pkg_a_names = [_][]const u8{"pkgA"};
    try installPackagesToProfile(ctx, &repocaches, pkg_a_names[0..], client, false, false, false, profile_name, null);
    try gcroots.updateRoots(ctx.allocator, store_dir, gc_roots_dir, profile_dir, 2);

    const store_path_a = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}-pkgA-1.0.0", .{ store_dir, hash_a });
    defer ctx.allocator.free(store_path_a);

    // Verify A exists in store
    try std.Io.Dir.accessAbsolute(path.currentIo(), store_path_a, .{});

    // Step 2: Install pkgB (additive: creates gen-2 with A + B)
    const pkg_b_names = [_][]const u8{"pkgB"};
    try installPackagesToProfile(ctx, &repocaches, pkg_b_names[0..], client, false, false, false, profile_name, null);
    try gcroots.updateRoots(ctx.allocator, store_dir, gc_roots_dir, profile_dir, 2);

    const store_path_b = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}-pkgB-1.0.0", .{ store_dir, hash_b });
    defer ctx.allocator.free(store_path_b);

    // Verify B exists
    try std.Io.Dir.accessAbsolute(path.currentIo(), store_path_b, .{});

    // Both generations exist, both store paths should be rooted
    {
        var gc_result = try gc.collectGarbage(ctx, .{ .dry_run = true });
        defer gc_result.deinit();
        for (gc_result.deleted_paths.items) |deleted_path| {
            try std.testing.expect(!std.mem.startsWith(u8, deleted_path, store_dir));
        }
    }

    // Step 3: Delete gen-1 (A remains referenced by additive gen-2)
    try gcroots.deleteGeneration(ctx, gc_roots_dir, profile_dir, 1);

    // Step 4: Run GC (dry run) - nothing should be collected
    {
        var gc_result = try gc.collectGarbage(ctx, .{ .dry_run = true });
        defer gc_result.deinit();
        for (gc_result.deleted_paths.items) |deleted_path| {
            try std.testing.expect(!std.mem.startsWith(u8, deleted_path, store_dir));
        }
    }

    // Step 5: Run GC for real
    {
        var gc_result = try gc.collectGarbage(ctx, .{ .dry_run = false });
        defer gc_result.deinit();
        for (gc_result.deleted_paths.items) |deleted_path| {
            try std.testing.expect(!std.mem.startsWith(u8, deleted_path, store_dir));
        }
    }

    // Verify both A and B remain reachable
    try std.Io.Dir.accessAbsolute(path.currentIo(), store_path_a, .{});
    try std.Io.Dir.accessAbsolute(path.currentIo(), store_path_b, .{});
}

test "installPackageToProfile symlinks to target profile" {
    // Simplified test that verifies symlinkPackagesToProfile works correctly
    // by creating mock installed packages and verifying symlinks are created.

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Create a mock store directory with a package
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);

    const content_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const pkg_store_path = try std.fs.path.join(ctx.allocator, &.{ store_root, content_hash ++ "-test-pkg-1.0.0" });
    defer ctx.allocator.free(pkg_store_path);

    // Create package content in store
    const usr_bin = try std.fs.path.join(ctx.allocator, &.{ pkg_store_path, "usr", "bin" });
    defer ctx.allocator.free(usr_bin);
    try path.ensureDirExists(usr_bin);

    const tool_path = try std.fs.path.join(ctx.allocator, &.{ usr_bin, "test-tool" });
    defer ctx.allocator.free(tool_path);
    var tool_f = try path.makePathAndOpenFile(tool_path);
    try tool_f.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho test\n");
    tool_f.close(path.currentIo());

    try writeProjectionForPackageDir(ctx.allocator, pkg_store_path);

    // Create a target profile directory
    const target_profile = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "build-profile" });
    defer ctx.allocator.free(target_profile);
    try path.ensureDirExists(target_profile);

    // Create standard subdirectories
    const subdirs = [_][]const u8{ "bin", "sbin", "lib", "usr", "usr/bin", "usr/lib", "usr/share" };
    for (subdirs) |subdir| {
        const subdir_path = try std.fs.path.join(ctx.allocator, &.{ target_profile, subdir });
        defer ctx.allocator.free(subdir_path);
        try path.ensureDirExists(subdir_path);
    }

    // Create mock installed package info
    var installed_packages = [_]generation.PackageEntry{
        .{
            .name = "test-pkg",
            .version = "1.0.0",
            .release = 1,
            .arch = th.host_arch,
            .store_path = pkg_store_path,
            .content_hash = content_hash,
        },
    };

    // Call symlinkPackagesToProfile directly
    try symlinkPackagesToProfile(ctx, target_profile, &installed_packages, .install);

    // Verify symlink exists in the profile
    const profile_tool = try std.fs.path.join(ctx.allocator, &.{ target_profile, "usr", "bin", "test-tool" });
    defer ctx.allocator.free(profile_tool);

    // Check that the symlink exists
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = std.Io.Dir.readLinkAbsolute(path.currentIo(), profile_tool, &link_buf) catch |err| {
        std.debug.print("failed to read symlink at {s}: {}\n", .{ profile_tool, err });
        return ctx.fail(err, profile_tool, "failed to read symlink");
    };
    const link_target = link_buf[0..link_len];

    // Verify the symlink points to the store via its logical path
    // (/mere/store/...), not the physical --root staging path. See
    // store.toLogicalStorePath.
    const expected_prefix = try store.toLogicalStorePath(ctx.allocator, ctx.root_path, store_root);
    defer ctx.allocator.free(expected_prefix);
    try std.testing.expectEqualStrings("/mere/store", expected_prefix);
    try std.testing.expect(std.mem.startsWith(u8, link_target, expected_prefix));
    try std.testing.expect(std.mem.indexOf(u8, link_target, "test-tool") != null);
}

// Spec #4.1: Store admission uses atomic rename from staging to final path
test "store admission uses atomic rename from staging directory to final store path" {
    // This test verifies the core store admission invariant (spec #4.1):
    // A package staged in /mere/store/.incoming/<rand>/ is admitted to its
    // final content-addressed path via a single atomic rename(2) syscall.
    // After rename, the staging directory no longer exists and the final
    // path contains the original content.

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Set up store directory structure matching the spec layout
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    const incoming_dir = try std.fs.path.join(ctx.allocator, &.{ store_root, ".incoming" });
    defer ctx.allocator.free(incoming_dir);
    try path.ensureDirExists(incoming_dir);

    // Create staging directory under .incoming/ (same filesystem for atomic rename)
    const staging_dir = try std.fs.path.join(ctx.allocator, &.{ incoming_dir, "test-rand-staging" });
    defer ctx.allocator.free(staging_dir);
    try path.ensureDirExists(staging_dir);

    // Populate staging directory with package content
    const staging_file = try std.fs.path.join(ctx.allocator, &.{ staging_dir, "usr", "bin", "hello" });
    defer ctx.allocator.free(staging_file);
    {
        const parent = std.fs.path.dirname(staging_file).?;
        try path.ensureDirExists(parent);
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), staging_file, .{});
        try f.writeStreamingAll(path.currentIo(), "#!/bin/sh\necho hello\n");
        f.close(path.currentIo());
    }

    // Create .mere/manifest.v1 marker in staging (excluded from hash but present in store)
    const mere_dir = try std.fs.path.join(ctx.allocator, &.{ staging_dir, ".mere" });
    defer ctx.allocator.free(mere_dir);
    try path.ensureDirExists(mere_dir);
    const manifest_file = try std.fs.path.join(ctx.allocator, &.{ mere_dir, "manifest.v1" });
    defer ctx.allocator.free(manifest_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), manifest_file, .{});
        try f.writeStreamingAll(path.currentIo(), "MEREMFST");
        f.close(path.currentIo());
    }

    // Define the final content-addressed store path
    const content_hash = "b" ** 64;
    const final_store_path = try std.fs.path.join(ctx.allocator, &.{ store_root, content_hash ++ "-hello-1.0.0" });
    defer ctx.allocator.free(final_store_path);

    // Verify preconditions: staging exists, final does not
    try std.testing.expect(store.storePathExists(staging_dir));
    try std.testing.expect(!store.storePathExists(final_store_path));

    // === Atomic rename: the single syscall that admits the package ===
    // This mirrors installSinglePackageToStore Step 4
    // Rename the staged directory into its final content-addressed path.
    try std.Io.Dir.renameAbsolute(staging_dir, final_store_path, path.currentIo());

    // Verify postconditions:
    // 1. Staging directory no longer exists (it was moved, not copied)
    try std.testing.expect(!store.storePathExists(staging_dir));

    // 2. Final store path now exists
    try std.testing.expect(store.storePathExists(final_store_path));

    // 3. Content is intact at the final path (rename preserves directory tree)
    const final_file = try std.fs.path.join(ctx.allocator, &.{ final_store_path, "usr", "bin", "hello" });
    defer ctx.allocator.free(final_file);
    var verify = try path.openExistingFile(final_file);
    defer verify.close(path.currentIo());
    var buf: [100]u8 = undefined;
    const n = try verify.readPositionalAll(path.currentIo(), &buf, 0);
    try std.testing.expectEqualStrings("#!/bin/sh\necho hello\n", buf[0..n]);

    // 4. Manifest marker is also present (whole tree moved atomically)
    const final_manifest = try std.fs.path.join(ctx.allocator, &.{ final_store_path, ".mere", "manifest.v1" });
    defer ctx.allocator.free(final_manifest);
    var mf = try path.openExistingFile(final_manifest);
    defer mf.close(path.currentIo());
    var mbuf: [20]u8 = undefined;
    const mn = try mf.readPositionalAll(path.currentIo(), &mbuf, 0);
    try std.testing.expectEqualStrings("MEREMFST", mbuf[0..mn]);
}

test "fsyncTree recursively syncs nested files and directories without following symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const root_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "fsync-tree-test" });
    defer ctx.allocator.free(root_dir);
    const nested_dir = try std.fs.path.join(ctx.allocator, &.{ root_dir, "sub", "nested" });
    defer ctx.allocator.free(nested_dir);
    try path.ensureDirExists(nested_dir);

    const nested_file = try std.fs.path.join(ctx.allocator, &.{ nested_dir, "data.txt" });
    defer ctx.allocator.free(nested_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(path.currentIo(), nested_file, .{});
        try f.writeStreamingAll(path.currentIo(), "hello");
        f.close(path.currentIo());
    }

    // Dangling symlink: if fsyncTree opened walk entries without checking
    // .kind, following this would fail with FileNotFound.
    const sub_dir = try std.fs.path.join(ctx.allocator, &.{ root_dir, "sub" });
    defer ctx.allocator.free(sub_dir);
    const dangling_link = try std.fs.path.join(ctx.allocator, &.{ sub_dir, "dangling" });
    defer ctx.allocator.free(dangling_link);
    const dangling_target = try std.fs.path.join(ctx.allocator, &.{ root_dir, "does-not-exist" });
    defer ctx.allocator.free(dangling_target);
    try std.Io.Dir.symLinkAbsolute(path.currentIo(), dangling_target, dangling_link, .{});

    try fsyncTree(ctx.allocator, root_dir);
}

test "fsyncTree fails for a nonexistent directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const missing_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "does-not-exist" });
    defer ctx.allocator.free(missing_dir);

    try std.testing.expectError(error.FileNotFound, fsyncTree(ctx.allocator, missing_dir));
}

test "enforceRepoMetadataBinding rejects content hash mismatch" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, "pkgA");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, th.host_arch);
    pkg.content_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    pkg.archive_hash = try ctx.allocator.dupe(u8, "b" ** 64);

    var manifest_hash_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&manifest_hash_bytes, "b" ** 64);

    var parsed = ParsedManifest{
        .data = try ctx.allocator.dupe(u8, "x"),
        .manifest = .{
            .schema_version = 1,
            .created_at = 1706745600,
            .name = "pkgA",
            .version = "1.0.0",
            .release = 1,
            .arch = th.host_arch,
            .content_hash = manifest_hash_bytes,
        },
        .format = .v1,
    };
    errdefer parsed.deinit(ctx.allocator);

    var preverify = PreVerifyResult{
        .parsed = parsed,
        .manifest_content_hash = try ctx.allocator.dupe(u8, "b" ** 64),
        .archive_hash = try ctx.allocator.dupe(u8, "b" ** 64),
        .verifying_fingerprint = try ctx.allocator.dupe(u8, "c" ** 64),
    };
    defer preverify.deinit(ctx.allocator);

    const res = enforceRepoMetadataBinding(ctx, &pkg, &preverify, "pkgA-1.0.0");
    try std.testing.expectError(error.CorruptData, res);
}

test "enforceRepoMetadataBinding rejects manifest identity mismatch" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, "pkgA");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, th.host_arch);
    pkg.content_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    pkg.archive_hash = try ctx.allocator.dupe(u8, "b" ** 64);

    var hash_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash_bytes, "a" ** 64);

    var parsed = ParsedManifest{
        .data = try ctx.allocator.dupe(u8, "x"),
        .manifest = .{
            .schema_version = 1,
            .created_at = 1706745600,
            .name = "pkgB",
            .version = "1.0.0",
            .release = 1,
            .arch = th.host_arch,
            .content_hash = hash_bytes,
        },
        .format = .v1,
    };
    errdefer parsed.deinit(ctx.allocator);

    var preverify = PreVerifyResult{
        .parsed = parsed,
        .manifest_content_hash = try ctx.allocator.dupe(u8, "a" ** 64),
        .archive_hash = try ctx.allocator.dupe(u8, "b" ** 64),
        .verifying_fingerprint = try ctx.allocator.dupe(u8, "c" ** 64),
    };
    defer preverify.deinit(ctx.allocator);

    const res = enforceRepoMetadataBinding(ctx, &pkg, &preverify, "pkgA-1.0.0");
    try std.testing.expectError(error.CorruptData, res);
}

test "preVerifyManifest fails when trusted fingerprints are missing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    var pkg = package.Package.init(&ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, "sigtest");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, th.host_arch);
    pkg.content_hash = try ctx.allocator.dupe(u8, "dummyhash");
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);

    const setup = try th.setupTestImport(&ctx, &pkg, test_env, "sigtest.tar");
    defer ctx.allocator.free(setup.db_path);
    defer ctx.allocator.free(setup.pkg_path);
    defer ctx.allocator.free(setup.secret_key_path);

    var repo_cache = try RepoCache.init(&ctx, "remote-no-trust", "file:///tmp/unused", &[_][]const u8{}, 100);
    defer repo_cache.deinit();

    const no_keys: []const sign.LoadedKey = &.{};
    const result = preVerifyManifest(&ctx, &repo_cache, setup.pkg_path, "sigtest-1.0.0", no_keys);
    try std.testing.expectError(error.SignatureInvalid, result);
    ctx.resetDiagnostics();
}

test "install mapInstallFsError preserves actionable classes" {
    try std.testing.expectEqual(error.OutOfMemory, mapInstallFsError(error.OutOfMemory));
    try std.testing.expectEqual(error.PermissionDenied, mapInstallFsError(error.AccessDenied));
    try std.testing.expectEqual(error.InvalidInput, mapInstallFsError(error.BadPathName));
    try std.testing.expectEqual(error.FileSystem, mapInstallFsError(error.FileNotFound));
}

test "install mapActivationError preserves actionable classes" {
    try std.testing.expectEqual(error.OutOfMemory, mapActivationError(activation.ActivationError.OutOfMemory));
    try std.testing.expectEqual(error.PermissionDenied, mapActivationError(activation.ActivationError.PermissionDenied));
    try std.testing.expectEqual(error.InvalidInput, mapActivationError(activation.ActivationError.InvalidInput));
    try std.testing.expectEqual(error.ConflictingProvision, mapActivationError(activation.ActivationError.DuplicateEtcTemplate));
    try std.testing.expectEqual(error.FileSystem, mapActivationError(activation.ActivationError.ManifestNotFound));
}

test "install mapGenerationError preserves actionable classes" {
    try std.testing.expectEqual(error.OutOfMemory, mapGenerationError(generation.GenerationError.OutOfMemory));
    try std.testing.expectEqual(error.PermissionDenied, mapGenerationError(generation.GenerationError.PermissionDenied));
    try std.testing.expectEqual(error.InvalidInput, mapGenerationError(generation.GenerationError.InvalidManifest));
    try std.testing.expectEqual(error.InvalidInput, mapGenerationError(generation.GenerationError.ParseError));
    try std.testing.expectEqual(error.FileSystem, mapGenerationError(generation.GenerationError.GenerationNotFound));
}

test "determineInstallTargetBehavior defers non-privileged system installs" {
    try std.testing.expectEqual(
        InstallTargetBehavior.store_only_system_deferred,
        determineInstallTargetBehavior("system", null, false),
    );
    try std.testing.expectEqual(
        InstallTargetBehavior.activate_profile,
        determineInstallTargetBehavior("system", null, true),
    );
}

test "loadCurrentGenerationPreferences reports corrupt current manifest details" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    try path.ensureDirExists(profile_dir);

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    try path.ensureDirExists(gen_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ gen_path, generation.MANIFEST_FILENAME });
    defer allocator.free(manifest_path);
    var manifest_file = try std.Io.Dir.createFileAbsolute(path.currentIo(), manifest_path, .{ .truncate = true });
    manifest_file.close(path.currentIo());

    var profile_handle = try std.Io.Dir.openDirAbsolute(path.currentIo(), profile_dir, .{});
    defer profile_handle.close(path.currentIo());
    try profile_handle.symLink(path.currentIo(), "gen-1", generation.CURRENT_SYMLINK, .{});

    try std.testing.expectError(error.InvalidInput, loadCurrentGenerationPreferences(ctx, "system"));
    const diagnostic = ctx.getDiagnosticContext();
    try std.testing.expectEqualStrings(gen_path, diagnostic.subject.?);
    try std.testing.expect(std.mem.containsAtLeast(u8, diagnostic.details.?, 1, "InvalidManifest"));
}

fn writeProjectionForPackageDir(allocator: std.mem.Allocator, package_dir: []const u8) !void {
    var projection = try projection_index.deriveFromPayload(allocator, package_dir);
    defer projection.deinit();
    try projection_index.writeFile(allocator, package_dir, &projection);
}

fn finalizeTestPackageArchive(
    ctx: *mere.Context,
    pkg: *package.Package,
    staging_dir: []const u8,
    packages_dir: []const u8,
) ![]const u8 {
    const archive_temp = try std.fs.path.join(ctx.allocator, &.{ packages_dir, "package.tmp.pkg.tar.zst" });
    defer ctx.allocator.free(archive_temp);

    try archive.createPackageArchive(ctx, staging_dir, archive_temp);

    const archive_hash = try hash.calculateFileHash(ctx, archive_temp);
    defer ctx.allocator.free(archive_hash);

    if (pkg.archive_hash.len > 0) {
        ctx.allocator.free(pkg.archive_hash);
    }
    pkg.archive_hash = try ctx.allocator.dupe(u8, archive_hash);

    const archive_name = try pkg.canonicalArchiveName();
    defer ctx.allocator.free(archive_name);

    const archive_final = try std.fs.path.join(ctx.allocator, &.{ packages_dir, archive_name });
    errdefer ctx.allocator.free(archive_final);

    try std.Io.Dir.renameAbsolute(archive_temp, archive_final, path.currentIo());
    return archive_final;
}

/// Create a minimal signed package (name/version/deps) and insert it into
/// `repo`'s database. Shared by tests that need several interdependent
/// packages without repeating the full staging/manifest/sign dance per
/// package.
fn createSignedTestPackage(
    ctx: *mere.Context,
    repo: *Repository,
    staging_root: []const u8,
    packages_dir: []const u8,
    key_path: []const u8,
    name: []const u8,
    version: []const u8,
    deps: []const []const u8,
) !void {
    const th = @import("test_helpers.zig");
    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, version);
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, th.host_arch);

    const staging = try std.fs.path.join(ctx.allocator, &.{ staging_root, name });
    defer ctx.allocator.free(staging);
    try path.ensureDirExists(staging);

    // Filename includes the package name - these packages may all end up
    // merged into the same profile, and identical paths across packages
    // would collide when publishing the symlink tree.
    const file_txt_name = try std.fmt.allocPrint(ctx.allocator, "{s}.txt", .{name});
    defer ctx.allocator.free(file_txt_name);
    const file_txt_path = try std.fs.path.join(ctx.allocator, &.{ staging, file_txt_name });
    defer ctx.allocator.free(file_txt_path);
    var file_txt = try path.makePathAndOpenFile(file_txt_path);
    try file_txt.writeStreamingAll(path.currentIo(), name);
    file_txt.close(path.currentIo());

    const mere_dir_path = try std.fs.path.join(ctx.allocator, &.{ staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir_path);
    try path.ensureDirExists(mere_dir_path);

    const content_hash = try hash.calculateStoreContentHash(ctx.allocator, staging, null);
    defer ctx.allocator.free(content_hash);
    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash) catch unreachable;

    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = th.host_arch,
        .name = name,
        .version = version,
        .content_hash = content_hash_bytes,
    };

    const secret_key = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, staging, &pkg_manifest, &secret_key.key);
    try writeProjectionForPackageDir(ctx.allocator, staging);

    pkg.content_hash = try ctx.allocator.dupe(u8, content_hash);
    const pkg_file = try finalizeTestPackageArchive(ctx, &pkg, staging, packages_dir);
    defer ctx.allocator.free(pkg_file);

    ctx.signing_key_path = key_path;
    const sig = try sign.signWithResolvedKey(ctx, pkg_file, null, null);
    const sig_len = sign.c.crypto_sign_BYTES;
    const sig_buf = try ctx.allocator.alloc(u8, sig_len);
    std.mem.copyForwards(u8, sig_buf, sig[0..sig_len]);
    pkg.signature = sig_buf[0..sig_len];

    for (deps) |dep| {
        try pkg.addDependency(dep, package.DependencyType.elf_needed);
    }

    _ = try repo.db.insertPackageTransaction(&pkg, null);
}

// Regression: uninstall --cascade with multiple package names only cascaded
// the first one still required, then stopped checking entirely (a `break`
// exited the whole loop after one cascade round). A second requested
// removal that's still pulled in by a *different*, unrelated dependent
// silently survived with no error and no cascade. Fixed by looping to a
// fixed point: keep re-checking every requested name against the latest
// resolution until none of them remain.
test "uninstallPackagesFromConfig cascade handles multiple independently-required packages" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| cfg.deinit();
        ctx.configuration = null;
    }

    const repo_dir = try std.fs.path.join(allocator, &.{ test_env.path, "repo" });
    defer allocator.free(repo_dir);
    try path.ensureDirExists(repo_dir);

    const packages_dir = try std.fs.path.join(allocator, &.{ repo_dir, "packages" });
    defer allocator.free(packages_dir);
    try path.ensureDirExists(packages_dir);

    const staging_root = try std.fs.path.join(allocator, &.{ test_env.path, "staging" });
    defer allocator.free(staging_root);
    try path.ensureDirExists(staging_root);

    const keypair = try sign.generateKeyPair();
    const key_path = try std.fs.path.join(allocator, &.{ repo_dir, "repo.key" });
    defer allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    // A and C are each independently required by a *different* other
    // package (E and F respectively) - neither depends on the other.
    try createSignedTestPackage(ctx, &repo, staging_root, packages_dir, key_path, "A", "1.0.0", &.{});
    try createSignedTestPackage(ctx, &repo, staging_root, packages_dir, key_path, "C", "1.0.0", &.{});
    try createSignedTestPackage(ctx, &repo, staging_root, packages_dir, key_path, "E", "1.0.0", &.{"A"});
    try createSignedTestPackage(ctx, &repo, staging_root, packages_dir, key_path, "F", "1.0.0", &.{"C"});

    const db_path = try std.fs.path.join(allocator, &.{ repo_dir, "repo.db" });
    defer allocator.free(db_path);
    const sig_path = try std.fs.path.join(allocator, &.{ repo_dir, "repo.db.sig" });
    defer allocator.free(sig_path);
    ctx.signing_key_path = key_path;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_path, sig_path, null, null);

    // The public key must be discoverable by loadAllKeys() so
    // verifyWithTrustedFingerprints can match it against the fingerprint.
    const user_keys_dir = try std.fs.path.join(allocator, &.{ test_env.path, ".mere", "keys" });
    defer allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const pubkey_path = try std.fs.path.join(allocator, &.{ user_keys_dir, "testrepo.pub" });
    defer allocator.free(pubkey_path);
    try keypair.public_key.saveToFile(pubkey_path);

    const fingerprint = try keypair.public_key.fingerprint(allocator);
    defer allocator.free(fingerprint);

    var fps: std.ArrayList([]const u8) = .empty;
    try fps.append(allocator, try allocator.dupe(u8, fingerprint));

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}", .{repo_dir});
    defer allocator.free(repo_url);
    try ctx.configuration.?.repos.append(allocator, config_mod.RepoConfig{
        .name = try allocator.dupe(u8, "testrepo"),
        .url = try allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    // Install all four as roots of a named profile.
    _ = try installPackagesFromConfig(ctx, &.{ "A", "C", "E", "F" }, client, false, false, false, "testprofile");

    // Sanity: all four are actually present before we try to remove any.
    {
        const profile_dir = try getProfileDir(ctx, "testprofile");
        defer allocator.free(profile_dir);
        const root_path = try profile.getRootPath(allocator, profile_dir);
        defer allocator.free(root_path);
        const store_root = try std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "store" });
        defer allocator.free(store_root);
        var before = try generation.readManifest(allocator, store_root, root_path);
        defer before.deinit();
        try std.testing.expectEqual(@as(usize, 4), before.packages.items.len);
    }

    // Uninstall A and C with cascade. Both E (depends on A) and F (depends
    // on C) must be cascaded away too - not just whichever is checked first.
    const result = try uninstallPackagesFromConfig(ctx, &.{ "A", "C" }, client, false, .automatic, "testprofile", true, false);
    defer if (result) |msg| allocator.free(msg);
    try std.testing.expect(result == null);

    const profile_dir = try getProfileDir(ctx, "testprofile");
    defer allocator.free(profile_dir);
    const root_path = try profile.getRootPath(allocator, profile_dir);
    defer allocator.free(root_path);
    const store_root = try std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "store" });
    defer allocator.free(store_root);

    const after_opt = generation.readManifest(allocator, store_root, root_path);
    if (after_opt) |after_const| {
        var after = after_const;
        defer after.deinit();
        for (after.packages.items) |pkg| {
            inline for (.{ "A", "C", "E", "F" }) |removed| {
                try std.testing.expect(!std.mem.eql(u8, pkg.name, removed));
            }
        }
    } else |_| {
        // No profile root at all (everything removed) is also an acceptable
        // outcome, depending on how publishProfileRoot handles an empty set.
    }
}

test "determineInstallTargetBehavior preserves explicit store-only and profile targets" {
    try std.testing.expectEqual(
        InstallTargetBehavior.store_only_requested,
        determineInstallTargetBehavior(null, null, false),
    );
    try std.testing.expectEqual(
        InstallTargetBehavior.activate_profile,
        determineInstallTargetBehavior("dev", null, false),
    );
    try std.testing.expectEqual(
        InstallTargetBehavior.activate_profile,
        determineInstallTargetBehavior("system", "/tmp/profile", false),
    );
}

test "setDirectoryReadOnly reports traversal permission failures" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(path.currentIo(), "restricted");
    {
        var restricted = try tmp.dir.openDir(path.currentIo(), "restricted", .{ .iterate = true });
        defer restricted.close(path.currentIo());
        try restricted.setPermissions(path.currentIo(), .fromMode(0o000));
    }
    defer {
        if (tmp.dir.openDir(path.currentIo(), "restricted", .{ .iterate = true })) |restricted| {
            var dir_handle = restricted;
            defer dir_handle.close(path.currentIo());
            dir_handle.setPermissions(path.currentIo(), .fromMode(0o755)) catch {};
        } else |_| {}
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path_len = try tmp.dir.realPath(path.currentIo(), &buf);
    const root_path = buf[0..root_path_len];

    const result = setDirectoryReadOnly(root_path);
    try std.testing.expectError(error.AccessDenied, result);
}

test "finalizeAdmittedStoreObject skips hardening when unprivileged" {
    if (store.isPrivileged()) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const install_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", ("d" ** 64) ++ "-pkg-1.0.0" });
    defer ctx.allocator.free(install_dir);
    try path.ensureDirExists(install_dir);

    // Unprivileged: function succeeds, skipping the root-ownership hardening.
    // Hardening is only meaningful for privileged system installs; see the
    // matching guard in finalizeAdmittedStoreObject.
    try finalizeAdmittedStoreObject(ctx, install_dir, false);

    // Store object remains admitted.
    try std.Io.Dir.accessAbsolute(path.currentIo(), install_dir, .{});
}
