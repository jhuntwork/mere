const std = @import("std");
const artifact_model = @import("artifact_model.zig");
const build_cache = @import("../build_cache.zig");
const config = @import("../config.zig");
const hash = @import("../hash.zig");
const mere = @import("../mere.zig");
const packaging = @import("../packaging.zig");
const path_mod = @import("../path.zig");
const recipe = @import("../recipe.zig");
const split_staging = @import("split_staging.zig");

pub const SolvedNodeOutput = struct {
    allocator: std.mem.Allocator,
    key_hex: []const u8,
    digest_hex: []const u8,
    actual_subpath: ?[]const u8,
    restored_root: ?[]const u8,
    actual_path: ?[]const u8,

    pub fn deinit(self: *SolvedNodeOutput) void {
        self.allocator.free(self.key_hex);
        self.allocator.free(self.digest_hex);
        if (self.actual_subpath) |value| self.allocator.free(value);
        if (self.restored_root) |value| self.allocator.free(value);
        if (self.actual_path) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const SolvedPackageArchive = struct {
    allocator: std.mem.Allocator,
    key_hex: []const u8,
    archive_path: []const u8,
    content_hash: []const u8,
    archive_hash: []const u8,
    signature: []u8,

    pub fn deinit(self: *SolvedPackageArchive) void {
        self.allocator.free(self.key_hex);
        self.allocator.free(self.archive_path);
        self.allocator.free(self.content_hash);
        self.allocator.free(self.archive_hash);
        self.allocator.free(self.signature);
        self.* = undefined;
    }
};

pub const SolveRequest = struct {
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
};

pub const SolveResult = struct {
    execution: artifact_model.NodeExecutionKind,
    output: SolvedNodeOutput,

    pub fn deinit(self: *SolveResult) void {
        self.output.deinit();
    }
};

pub const MissExecutor = struct {
    ptr: *anyopaque,
    run_fn: *const fn (*anyopaque) anyerror!void,

    pub fn run(self: MissExecutor) anyerror!void {
        return self.run_fn(self.ptr);
    }
};

pub const SourceFetchSpec = struct {
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_sources_dir: []const u8,
};

pub const SourceUnpackSpec = struct {
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_sources_dir: []const u8,
    workspace_src_dir: []const u8,
    actual_src_dir: *const ?[]const u8,
};

pub const ExecutionTrace = struct {
    allocator: ?std.mem.Allocator = null,
    nodes: std.ArrayList(artifact_model.BuildNode) = .empty,
    fetched_sources: ?artifact_model.ArtifactRef = null,
    unpacked_source_tree: ?artifact_model.ArtifactRef = null,
    profile_tree: ?artifact_model.ArtifactRef = null,
    prepare_tree: ?artifact_model.ArtifactRef = null,
    build_tree: ?artifact_model.ArtifactRef = null,
    check_tree: ?artifact_model.ArtifactRef = null,
    destdir_tree: ?artifact_model.ArtifactRef = null,
    split_tree: ?artifact_model.ArtifactRef = null,

    pub fn deinit(self: *ExecutionTrace) void {
        for (self.nodes.items) |*node| node.deinit();
        self.nodes.deinit(self.allocator orelse std.heap.page_allocator);
        clearSlot(&self.fetched_sources);
        clearSlot(&self.unpacked_source_tree);
        clearSlot(&self.profile_tree);
        clearSlot(&self.prepare_tree);
        clearSlot(&self.build_tree);
        clearSlot(&self.check_tree);
        clearSlot(&self.destdir_tree);
        clearSlot(&self.split_tree);
    }

    pub fn recordNode(self: *ExecutionTrace, allocator: std.mem.Allocator, node: artifact_model.BuildNode) !void {
        if (self.allocator == null) self.allocator = allocator;
        try self.nodes.append(allocator, node);
        replaceSlotForOutput(self, self.nodes.items[self.nodes.items.len - 1].output);
    }

    pub fn formatSummaryAlloc(self: *const ExecutionTrace, allocator: std.mem.Allocator) ![]const u8 {
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(allocator);

        for (self.nodes.items, 0..) |node, i| {
            if (i > 0) try parts.appendSlice(allocator, " -> ");
            try parts.appendSlice(allocator, nodeKindLabel(node.kind));
            try parts.appendSlice(allocator, "(");
            try parts.appendSlice(allocator, executionKindLabel(node.execution));
            try parts.appendSlice(allocator, ")");
        }

        return parts.toOwnedSlice(allocator);
    }

    fn clearSlot(slot: *?artifact_model.ArtifactRef) void {
        if (slot.*) |*artifact| artifact.deinit();
        slot.* = null;
    }

    fn replaceSlot(slot: *?artifact_model.ArtifactRef, artifact: artifact_model.ArtifactRef) void {
        clearSlot(slot);
        slot.* = artifact;
    }

    fn replaceSlotForOutput(self: *ExecutionTrace, output: artifact_model.ArtifactRef) void {
        switch (output.kind) {
            .source_fetch => replaceSlot(&self.fetched_sources, cloneArtifact(output) catch unreachable),
            .source_unpack => replaceSlot(&self.unpacked_source_tree, cloneArtifact(output) catch unreachable),
            .profile_tree => replaceSlot(&self.profile_tree, cloneArtifact(output) catch unreachable),
            .prepare_tree => replaceSlot(&self.prepare_tree, cloneArtifact(output) catch unreachable),
            .build_tree => replaceSlot(&self.build_tree, cloneArtifact(output) catch unreachable),
            .check_tree => replaceSlot(&self.check_tree, cloneArtifact(output) catch unreachable),
            .destdir_tree => replaceSlot(&self.destdir_tree, cloneArtifact(output) catch unreachable),
            .split_tree => replaceSlot(&self.split_tree, cloneArtifact(output) catch unreachable),
            .package_archive => {},
        }
    }

    fn cloneArtifact(artifact: artifact_model.ArtifactRef) !artifact_model.ArtifactRef {
        return artifact_model.ArtifactRef.init(
            artifact.allocator,
            artifact.kind,
            artifact.key_hex,
            artifact.digest_hex,
            artifact.actual_subpath,
        );
    }
};

pub const RestoreRequest = union(enum) {
    source_fetch: struct {
        cache: bool,
        recipe_dir: []const u8,
        parsed_recipe: *const recipe.Recipe,
        workspace_sources_dir: []const u8,
    },
    source_unpack: struct {
        cache: bool,
        recipe_dir: []const u8,
        parsed_recipe: *const recipe.Recipe,
        workspace_src_dir: []const u8,
    },
    profile_tree: struct {
        cache: bool,
        parsed_recipe: *const recipe.Recipe,
        cfg: *const config.Config,
        profile_root: []const u8,
    },
    phase_output: struct {
        cache: bool,
        phase_name: []const u8,
        phase_script: []const u8,
        global_env: []const recipe.KV,
        phase_env: []const recipe.KV,
        source_tree_hash: []const u8,
        profile_tree_hash: []const u8,
        ns_working_dir: []const u8,
        phase_output_dir: []const u8,
    },
    split_stage: struct {
        cache: bool,
        parsed_recipe: *const recipe.Recipe,
        destdir: []const u8,
        recipe_root: []const u8,
        staged_packages: *std.ArrayList(split_staging.StagedPackage),
    },
    package_archive: struct {
        cache: bool,
        parsed_recipe: *const recipe.Recipe,
        artifact: *const recipe.BuildArtifact,
        staging_dir: []const u8,
        injected_dependencies: []const packaging.InjectedDependency,
        output_dir: []const u8,
    },
};

pub const RestoreResult = union(enum) {
    node: SolvedNodeOutput,
    package_archive: SolvedPackageArchive,

    pub fn deinit(self: *RestoreResult) void {
        switch (self.*) {
            .node => |*node| node.deinit(),
            .package_archive => |*archive| archive.deinit(),
        }
    }
};

pub const PersistRequest = union(enum) {
    source_fetch: struct {
        recipe_dir: []const u8,
        parsed_recipe: *const recipe.Recipe,
        workspace_sources_dir: []const u8,
    },
    source_unpack: struct {
        recipe_dir: []const u8,
        parsed_recipe: *const recipe.Recipe,
        workspace_src_dir: []const u8,
        actual_src_dir: ?[]const u8,
    },
    profile_tree: struct {
        parsed_recipe: *const recipe.Recipe,
        cfg: *const config.Config,
        profile_root: []const u8,
    },
    phase_output: struct {
        phase_name: []const u8,
        phase_script: []const u8,
        global_env: []const recipe.KV,
        phase_env: []const recipe.KV,
        source_tree_hash: []const u8,
        profile_tree_hash: []const u8,
        ns_working_dir: []const u8,
        phase_output_dir: []const u8,
    },
    split_stage: struct {
        parsed_recipe: *const recipe.Recipe,
        destdir: []const u8,
        recipe_root: []const u8,
        staged_packages: []const split_staging.StagedPackage,
    },
    package_archive: struct {
        parsed_recipe: *const recipe.Recipe,
        artifact: *const recipe.BuildArtifact,
        staging_dir: []const u8,
        injected_dependencies: []const packaging.InjectedDependency,
        result: *const packaging.PackageArtifactResult,
    },
};

pub fn restoreSourceFetchRequest(
    cache: bool,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_sources_dir: []const u8,
) RestoreRequest {
    return .{
        .source_fetch = .{
            .cache = cache,
            .recipe_dir = recipe_dir,
            .parsed_recipe = parsed_recipe,
            .workspace_sources_dir = workspace_sources_dir,
        },
    };
}

pub fn persistSourceFetchRequest(
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_sources_dir: []const u8,
) PersistRequest {
    return .{
        .source_fetch = .{
            .recipe_dir = recipe_dir,
            .parsed_recipe = parsed_recipe,
            .workspace_sources_dir = workspace_sources_dir,
        },
    };
}

pub fn restoreSourceUnpackRequest(
    cache: bool,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_src_dir: []const u8,
) RestoreRequest {
    return .{
        .source_unpack = .{
            .cache = cache,
            .recipe_dir = recipe_dir,
            .parsed_recipe = parsed_recipe,
            .workspace_src_dir = workspace_src_dir,
        },
    };
}

pub fn persistSourceUnpackRequest(
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_src_dir: []const u8,
    actual_src_dir: ?[]const u8,
) PersistRequest {
    return .{
        .source_unpack = .{
            .recipe_dir = recipe_dir,
            .parsed_recipe = parsed_recipe,
            .workspace_src_dir = workspace_src_dir,
            .actual_src_dir = actual_src_dir,
        },
    };
}

pub fn restoreProfileTreeRequest(
    cache: bool,
    parsed_recipe: *const recipe.Recipe,
    cfg: *const config.Config,
    profile_root: []const u8,
) RestoreRequest {
    return .{
        .profile_tree = .{
            .cache = cache,
            .parsed_recipe = parsed_recipe,
            .cfg = cfg,
            .profile_root = profile_root,
        },
    };
}

pub fn persistProfileTreeRequest(
    parsed_recipe: *const recipe.Recipe,
    cfg: *const config.Config,
    profile_root: []const u8,
) PersistRequest {
    return .{
        .profile_tree = .{
            .parsed_recipe = parsed_recipe,
            .cfg = cfg,
            .profile_root = profile_root,
        },
    };
}

pub fn restorePhaseOutputRequest(
    cache: bool,
    phase_name: []const u8,
    phase_script: []const u8,
    global_env: []const recipe.KV,
    phase_env: []const recipe.KV,
    source_tree_hash: []const u8,
    profile_tree_hash: []const u8,
    ns_working_dir: []const u8,
    phase_output_dir: []const u8,
) RestoreRequest {
    return .{
        .phase_output = .{
            .cache = cache,
            .phase_name = phase_name,
            .phase_script = phase_script,
            .global_env = global_env,
            .phase_env = phase_env,
            .source_tree_hash = source_tree_hash,
            .profile_tree_hash = profile_tree_hash,
            .ns_working_dir = ns_working_dir,
            .phase_output_dir = phase_output_dir,
        },
    };
}

pub fn persistPhaseOutputRequest(
    phase_name: []const u8,
    phase_script: []const u8,
    global_env: []const recipe.KV,
    phase_env: []const recipe.KV,
    source_tree_hash: []const u8,
    profile_tree_hash: []const u8,
    ns_working_dir: []const u8,
    phase_output_dir: []const u8,
) PersistRequest {
    return .{
        .phase_output = .{
            .phase_name = phase_name,
            .phase_script = phase_script,
            .global_env = global_env,
            .phase_env = phase_env,
            .source_tree_hash = source_tree_hash,
            .profile_tree_hash = profile_tree_hash,
            .ns_working_dir = ns_working_dir,
            .phase_output_dir = phase_output_dir,
        },
    };
}

pub fn restoreSplitStageRequest(
    cache: bool,
    parsed_recipe: *const recipe.Recipe,
    destdir: []const u8,
    recipe_root: []const u8,
    staged_packages: *std.ArrayList(split_staging.StagedPackage),
) RestoreRequest {
    return .{
        .split_stage = .{
            .cache = cache,
            .parsed_recipe = parsed_recipe,
            .destdir = destdir,
            .recipe_root = recipe_root,
            .staged_packages = staged_packages,
        },
    };
}

pub fn persistSplitStageRequest(
    parsed_recipe: *const recipe.Recipe,
    destdir: []const u8,
    recipe_root: []const u8,
    staged_packages: []const split_staging.StagedPackage,
) PersistRequest {
    return .{
        .split_stage = .{
            .parsed_recipe = parsed_recipe,
            .destdir = destdir,
            .recipe_root = recipe_root,
            .staged_packages = staged_packages,
        },
    };
}

pub fn restorePackageArchiveRequest(
    cache: bool,
    parsed_recipe: *const recipe.Recipe,
    artifact: *const recipe.BuildArtifact,
    staging_dir: []const u8,
    injected_dependencies: []const packaging.InjectedDependency,
    output_dir: []const u8,
) RestoreRequest {
    return .{
        .package_archive = .{
            .cache = cache,
            .parsed_recipe = parsed_recipe,
            .artifact = artifact,
            .staging_dir = staging_dir,
            .injected_dependencies = injected_dependencies,
            .output_dir = output_dir,
        },
    };
}

pub fn persistPackageArchiveRequest(
    parsed_recipe: *const recipe.Recipe,
    artifact: *const recipe.BuildArtifact,
    staging_dir: []const u8,
    injected_dependencies: []const packaging.InjectedDependency,
    result: *const packaging.PackageArtifactResult,
) PersistRequest {
    return .{
        .package_archive = .{
            .parsed_recipe = parsed_recipe,
            .artifact = artifact,
            .staging_dir = staging_dir,
            .injected_dependencies = injected_dependencies,
            .result = result,
        },
    };
}

pub fn solveSourceFetch(
    request: SolveRequest,
    spec: SourceFetchSpec,
    miss_executor: MissExecutor,
) !SolveResult {
    var restored = try restore(
        request.allocator,
        request.ctx,
        restoreSourceFetchRequest(
            request.cache,
            spec.recipe_dir,
            spec.parsed_recipe,
            spec.workspace_sources_dir,
        ),
    );
    if (restored) |*result| {
        const output = result.node;
        result.* = undefined;
        return SolveResult{
            .execution = .restored_from_cache,
            .output = output,
        };
    }

    try miss_executor.run();
    return SolveResult{
        .execution = .executed,
        .output = try persist(
            request.allocator,
            request.ctx,
            persistSourceFetchRequest(
                spec.recipe_dir,
                spec.parsed_recipe,
                spec.workspace_sources_dir,
            ),
        ),
    };
}

pub fn solveSourceUnpack(
    request: SolveRequest,
    spec: SourceUnpackSpec,
    miss_executor: MissExecutor,
) !SolveResult {
    var restored = try restore(
        request.allocator,
        request.ctx,
        restoreSourceUnpackRequest(
            request.cache,
            spec.recipe_dir,
            spec.parsed_recipe,
            spec.workspace_src_dir,
        ),
    );
    if (restored) |*result| {
        const output = result.node;
        result.* = undefined;
        return SolveResult{
            .execution = .restored_from_cache,
            .output = output,
        };
    }

    try miss_executor.run();
    return SolveResult{
        .execution = .executed,
        .output = try persist(
            request.allocator,
            request.ctx,
            persistSourceUnpackRequest(
                spec.recipe_dir,
                spec.parsed_recipe,
                spec.workspace_src_dir,
                spec.actual_src_dir.*,
            ),
        ),
    };
}

pub fn restore(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    request: RestoreRequest,
) build_cache.CacheError!?RestoreResult {
    return switch (request) {
        .source_fetch => |req| if (try restoreFetchedSources(allocator, ctx, req.cache, req.recipe_dir, req.parsed_recipe, req.workspace_sources_dir)) |node|
            RestoreResult{ .node = node }
        else
            null,
        .source_unpack => |req| if (try restoreUnpackedSources(allocator, ctx, req.cache, req.recipe_dir, req.parsed_recipe, req.workspace_src_dir)) |node|
            RestoreResult{ .node = node }
        else
            null,
        .profile_tree => |req| if (try restoreProfileTree(allocator, ctx, req.cache, req.parsed_recipe, req.cfg, req.profile_root)) |node|
            RestoreResult{ .node = node }
        else
            null,
        .phase_output => |req| if (try restorePhaseOutput(allocator, ctx, req.cache, req.phase_name, req.phase_script, req.global_env, req.phase_env, req.source_tree_hash, req.profile_tree_hash, req.ns_working_dir, req.phase_output_dir)) |node|
            RestoreResult{ .node = node }
        else
            null,
        .split_stage => |req| if (try restoreSplitStage(allocator, ctx, req.cache, req.parsed_recipe, req.destdir, req.recipe_root, req.staged_packages)) |node|
            RestoreResult{ .node = node }
        else
            null,
        .package_archive => |req| {
            const key_hex = try packageArchiveKey(allocator, ctx, req.parsed_recipe, req.artifact, req.staging_dir, req.injected_dependencies);
            defer allocator.free(key_hex);
            if (try restorePackageArchive(allocator, ctx, req.cache, key_hex, req.staging_dir, req.output_dir)) |archive| {
                return RestoreResult{ .package_archive = archive };
            }
            return null;
        },
    };
}

pub fn persist(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    request: PersistRequest,
) build_cache.CacheError!SolvedNodeOutput {
    return switch (request) {
        .source_fetch => |req| persistFetchedSources(allocator, ctx, req.recipe_dir, req.parsed_recipe, req.workspace_sources_dir),
        .source_unpack => |req| persistUnpackedSources(allocator, ctx, req.recipe_dir, req.parsed_recipe, req.workspace_src_dir, req.actual_src_dir),
        .profile_tree => |req| persistProfileTree(allocator, ctx, req.parsed_recipe, req.cfg, req.profile_root),
        .phase_output => |req| persistPhaseOutput(allocator, ctx, req.phase_name, req.phase_script, req.global_env, req.phase_env, req.source_tree_hash, req.profile_tree_hash, req.ns_working_dir, req.phase_output_dir),
        .split_stage => |req| persistSplitStage(allocator, ctx, req.parsed_recipe, req.destdir, req.recipe_root, req.staged_packages),
        .package_archive => |req| {
            const key_hex = try packageArchiveKey(allocator, ctx, req.parsed_recipe, req.artifact, req.staging_dir, req.injected_dependencies);
            errdefer allocator.free(key_hex);
            try persistPackageArchive(allocator, ctx, key_hex, req.staging_dir, req.result);
            return SolvedNodeOutput{
                .allocator = allocator,
                .key_hex = key_hex,
                .digest_hex = try allocator.dupe(u8, req.result.archive_hash),
                .actual_subpath = null,
                .restored_root = null,
                .actual_path = null,
            };
        },
    };
}

fn restoreFetchedSources(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_sources_dir: []const u8,
) build_cache.CacheError!?SolvedNodeOutput {
    if (!cache) return null;

    const key_hex = try sourceFetchKey(allocator, ctx, recipe_dir, parsed_recipe);
    errdefer allocator.free(key_hex);

    var restored = try build_cache.restoreDirectoryForKey(allocator, ctx, .source_fetch, key_hex, workspace_sources_dir);
    if (restored) |*hit| {
        defer hit.deinit();
        return SolvedNodeOutput{
            .allocator = allocator,
            .key_hex = key_hex,
            .digest_hex = try allocator.dupe(u8, hit.record.artifact_digest_hex),
            .actual_subpath = if (hit.record.actual_subpath) |value| try allocator.dupe(u8, value) else null,
            .restored_root = try allocator.dupe(u8, hit.restored_root),
            .actual_path = if (hit.actual_path) |value| try allocator.dupe(u8, value) else null,
        };
    }

    allocator.free(key_hex);
    return null;
}

fn persistFetchedSources(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_sources_dir: []const u8,
) build_cache.CacheError!SolvedNodeOutput {
    const key_hex = try sourceFetchKey(allocator, ctx, recipe_dir, parsed_recipe);
    errdefer allocator.free(key_hex);

    var stored = try build_cache.storeDirectoryForKey(allocator, ctx, .source_fetch, key_hex, workspace_sources_dir, null);
    defer stored.deinit();

    return SolvedNodeOutput{
        .allocator = allocator,
        .key_hex = key_hex,
        .digest_hex = try allocator.dupe(u8, stored.artifact_digest_hex),
        .actual_subpath = if (stored.actual_subpath) |value| try allocator.dupe(u8, value) else null,
        .restored_root = null,
        .actual_path = null,
    };
}

fn restoreUnpackedSources(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_src_dir: []const u8,
) build_cache.CacheError!?SolvedNodeOutput {
    if (!cache or parsed_recipe.sources.items.len == 0) return null;

    const fetch_key = try sourceFetchKey(allocator, ctx, recipe_dir, parsed_recipe);
    defer allocator.free(fetch_key);

    const unpack_key = try build_cache.computeSourceUnpackKey(allocator, fetch_key);
    errdefer allocator.free(unpack_key);

    var restored = try build_cache.restoreDirectoryForKey(allocator, ctx, .source_unpack, unpack_key, workspace_src_dir);
    if (restored) |*hit| {
        defer hit.deinit();
        return SolvedNodeOutput{
            .allocator = allocator,
            .key_hex = unpack_key,
            .digest_hex = try allocator.dupe(u8, hit.record.artifact_digest_hex),
            .actual_subpath = if (hit.record.actual_subpath) |value| try allocator.dupe(u8, value) else null,
            .restored_root = try allocator.dupe(u8, hit.restored_root),
            .actual_path = if (hit.actual_path) |value| try allocator.dupe(u8, value) else null,
        };
    }

    allocator.free(unpack_key);
    return null;
}

fn persistUnpackedSources(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
    workspace_src_dir: []const u8,
    actual_src_dir: ?[]const u8,
) build_cache.CacheError!SolvedNodeOutput {
    const fetch_key = try sourceFetchKey(allocator, ctx, recipe_dir, parsed_recipe);
    defer allocator.free(fetch_key);

    const unpack_key = try build_cache.computeSourceUnpackKey(allocator, fetch_key);
    errdefer allocator.free(unpack_key);

    var stored = try build_cache.storeDirectoryForKey(allocator, ctx, .source_unpack, unpack_key, workspace_src_dir, actual_src_dir);
    defer stored.deinit();

    return SolvedNodeOutput{
        .allocator = allocator,
        .key_hex = unpack_key,
        .digest_hex = try allocator.dupe(u8, stored.artifact_digest_hex),
        .actual_subpath = if (stored.actual_subpath) |value| try allocator.dupe(u8, value) else null,
        .restored_root = null,
        .actual_path = null,
    };
}

fn restoreProfileTree(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    parsed_recipe: *const recipe.Recipe,
    cfg: *const config.Config,
    profile_root: []const u8,
) build_cache.CacheError!?SolvedNodeOutput {
    if (!cache) return null;

    const key_hex = try profileTreeKey(allocator, ctx, parsed_recipe, cfg);
    errdefer allocator.free(key_hex);

    var restored = try build_cache.restoreDirectoryForKey(allocator, ctx, .profile_realize, key_hex, profile_root);
    if (restored) |*hit| {
        defer hit.deinit();
        return SolvedNodeOutput{
            .allocator = allocator,
            .key_hex = key_hex,
            .digest_hex = try allocator.dupe(u8, hit.record.artifact_digest_hex),
            .actual_subpath = if (hit.record.actual_subpath) |value| try allocator.dupe(u8, value) else null,
            .restored_root = try allocator.dupe(u8, hit.restored_root),
            .actual_path = if (hit.actual_path) |value| try allocator.dupe(u8, value) else null,
        };
    }

    allocator.free(key_hex);
    return null;
}

fn persistProfileTree(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    cfg: *const config.Config,
    profile_root: []const u8,
) build_cache.CacheError!SolvedNodeOutput {
    const key_hex = try profileTreeKey(allocator, ctx, parsed_recipe, cfg);
    errdefer allocator.free(key_hex);

    var stored = try build_cache.storeDirectoryForKey(allocator, ctx, .profile_realize, key_hex, profile_root, null);
    defer stored.deinit();

    return SolvedNodeOutput{
        .allocator = allocator,
        .key_hex = key_hex,
        .digest_hex = try allocator.dupe(u8, stored.artifact_digest_hex),
        .actual_subpath = if (stored.actual_subpath) |value| try allocator.dupe(u8, value) else null,
        .restored_root = null,
        .actual_path = null,
    };
}

fn restorePhaseOutput(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    phase_name: []const u8,
    phase_script: []const u8,
    global_env: []const recipe.KV,
    phase_env: []const recipe.KV,
    source_tree_hash: []const u8,
    profile_tree_hash: []const u8,
    ns_working_dir: []const u8,
    phase_output_dir: []const u8,
) build_cache.CacheError!?SolvedNodeOutput {
    if (!cache) return null;

    const key_hex = try phaseOutputKey(allocator, phase_name, phase_script, global_env, phase_env, source_tree_hash, profile_tree_hash, ns_working_dir);
    errdefer allocator.free(key_hex);

    var restored = try build_cache.restoreDirectoryForKey(allocator, ctx, .phase_run, key_hex, phase_output_dir);
    if (restored) |*hit| {
        defer hit.deinit();
        return SolvedNodeOutput{
            .allocator = allocator,
            .key_hex = key_hex,
            .digest_hex = try allocator.dupe(u8, hit.record.artifact_digest_hex),
            .actual_subpath = if (hit.record.actual_subpath) |value| try allocator.dupe(u8, value) else null,
            .restored_root = try allocator.dupe(u8, hit.restored_root),
            .actual_path = if (hit.actual_path) |value| try allocator.dupe(u8, value) else null,
        };
    }

    allocator.free(key_hex);
    return null;
}

fn persistPhaseOutput(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    phase_name: []const u8,
    phase_script: []const u8,
    global_env: []const recipe.KV,
    phase_env: []const recipe.KV,
    source_tree_hash: []const u8,
    profile_tree_hash: []const u8,
    ns_working_dir: []const u8,
    phase_output_dir: []const u8,
) build_cache.CacheError!SolvedNodeOutput {
    const key_hex = try phaseOutputKey(allocator, phase_name, phase_script, global_env, phase_env, source_tree_hash, profile_tree_hash, ns_working_dir);
    errdefer allocator.free(key_hex);

    var stored = try build_cache.storeDirectoryForKey(allocator, ctx, .phase_run, key_hex, phase_output_dir, null);
    defer stored.deinit();

    return SolvedNodeOutput{
        .allocator = allocator,
        .key_hex = key_hex,
        .digest_hex = try allocator.dupe(u8, stored.artifact_digest_hex),
        .actual_subpath = if (stored.actual_subpath) |value| try allocator.dupe(u8, value) else null,
        .restored_root = null,
        .actual_path = null,
    };
}

fn restoreSplitStage(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    parsed_recipe: *const recipe.Recipe,
    destdir: []const u8,
    recipe_root: []const u8,
    staged_packages: *std.ArrayList(split_staging.StagedPackage),
) build_cache.CacheError!?SolvedNodeOutput {
    if (!cache) return null;

    const destdir_hash = try hash.calculateStoreContentHash(allocator, destdir, null);
    defer allocator.free(destdir_hash);

    const key_hex = try splitStageKey(allocator, parsed_recipe, destdir_hash);
    errdefer allocator.free(key_hex);

    var restored = try build_cache.restoreSplitStagingForKey(
        allocator,
        ctx,
        key_hex,
        recipe_root,
        parsed_recipe.packages.items,
        staged_packages,
    );
    if (restored) |*hit| {
        defer hit.deinit();
        return SolvedNodeOutput{
            .allocator = allocator,
            .key_hex = key_hex,
            .digest_hex = try allocator.dupe(u8, hit.artifact_digest_hex),
            .actual_subpath = null,
            .restored_root = null,
            .actual_path = null,
        };
    }

    allocator.free(key_hex);
    return null;
}

fn persistSplitStage(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    destdir: []const u8,
    recipe_root: []const u8,
    staged_packages: []const split_staging.StagedPackage,
) build_cache.CacheError!SolvedNodeOutput {
    const destdir_hash = try hash.calculateStoreContentHash(allocator, destdir, null);
    defer allocator.free(destdir_hash);

    const key_hex = try splitStageKey(allocator, parsed_recipe, destdir_hash);
    errdefer allocator.free(key_hex);

    var stored = try build_cache.storeSplitStagingForKey(
        allocator,
        ctx,
        key_hex,
        recipe_root,
        staged_packages,
    );
    defer stored.deinit();

    return SolvedNodeOutput{
        .allocator = allocator,
        .key_hex = key_hex,
        .digest_hex = try allocator.dupe(u8, stored.artifact_digest_hex),
        .actual_subpath = null,
        .restored_root = null,
        .actual_path = null,
    };
}

pub fn packageArchiveKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    artifact: *const recipe.BuildArtifact,
    staging_dir: []const u8,
    injected_dependencies: []const packaging.InjectedDependency,
) build_cache.CacheError![]const u8 {
    const staging_tree_hash = try hash.calculateStoreContentHash(allocator, staging_dir, null);
    defer allocator.free(staging_tree_hash);

    return packageArchiveKeyForHash(
        allocator,
        ctx,
        parsed_recipe,
        artifact,
        staging_tree_hash,
        injected_dependencies,
    );
}

fn restorePackageArchive(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    package_key_hex: []const u8,
    staging_dir: []const u8,
    output_dir: []const u8,
) build_cache.CacheError!?SolvedPackageArchive {
    if (!cache) return null;

    var restored = try build_cache.restorePackageArchiveForKey(allocator, ctx, package_key_hex, staging_dir, output_dir);
    if (restored) |*hit| {
        defer hit.deinit();
        return SolvedPackageArchive{
            .allocator = allocator,
            .key_hex = try allocator.dupe(u8, package_key_hex),
            .archive_path = try allocator.dupe(u8, hit.archive_path),
            .content_hash = try allocator.dupe(u8, hit.content_hash),
            .archive_hash = try allocator.dupe(u8, hit.archive_hash),
            .signature = try allocator.dupe(u8, hit.signature),
        };
    }

    return null;
}

fn persistPackageArchive(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    package_key_hex: []const u8,
    staging_dir: []const u8,
    result: *const packaging.PackageArtifactResult,
) build_cache.CacheError!void {
    var stored = try build_cache.storePackageArchiveForKey(
        allocator,
        ctx,
        package_key_hex,
        staging_dir,
        result.archive_path,
        result.content_hash,
        result.archive_hash,
        result.signature,
    );
    stored.deinit();
}

fn sourceFetchKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
) build_cache.CacheError![]const u8 {
    return build_cache.computeSourceFetchKey(allocator, ctx, recipe_dir, parsed_recipe);
}

fn profileTreeKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    cfg: *const config.Config,
) build_cache.CacheError![]const u8 {
    return build_cache.computeProfileRealizeKey(allocator, ctx, parsed_recipe, cfg);
}

fn phaseOutputKey(
    allocator: std.mem.Allocator,
    phase_name: []const u8,
    phase_script: []const u8,
    global_env: []const recipe.KV,
    phase_env: []const recipe.KV,
    source_tree_hash: []const u8,
    profile_tree_hash: []const u8,
    ns_working_dir: []const u8,
) build_cache.CacheError![]const u8 {
    return build_cache.computePhaseStepKey(
        allocator,
        phase_name,
        phase_script,
        global_env,
        phase_env,
        source_tree_hash,
        profile_tree_hash,
        ns_working_dir,
    );
}

fn splitStageKey(
    allocator: std.mem.Allocator,
    parsed_recipe: *const recipe.Recipe,
    destdir_hash: []const u8,
) build_cache.CacheError![]const u8 {
    return build_cache.computeSplitStageKey(allocator, parsed_recipe, destdir_hash);
}

fn packageArchiveKeyForHash(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    artifact: *const recipe.BuildArtifact,
    staging_tree_hash: []const u8,
    injected_dependencies: []const packaging.InjectedDependency,
) build_cache.CacheError![]const u8 {
    return build_cache.computePackageArchiveKey(
        allocator,
        ctx,
        parsed_recipe,
        artifact,
        staging_tree_hash,
        injected_dependencies,
    );
}

fn nodeKindLabel(kind: artifact_model.NodeKind) []const u8 {
    return switch (kind) {
        .source_fetch => "source_fetch",
        .source_unpack => "source_unpack",
        .profile_realize => "profile_realize",
        .prepare_phase => "prepare",
        .build_phase => "build",
        .check_phase => "check",
        .install_phase => "install",
        .split_stage => "split",
        .package_archive => "package_archive",
    };
}

fn executionKindLabel(kind: artifact_model.NodeExecutionKind) []const u8 {
    return switch (kind) {
        .executed => "exec",
        .restored_from_cache => "cache",
    };
}

test "ExecutionTrace records nodes and updates latest artifact slots" {
    var trace = ExecutionTrace{};
    defer trace.deinit();

    const node = try artifact_model.BuildNode.init(
        std.testing.allocator,
        .prepare_phase,
        .executed,
        "k1",
        .prepare_tree,
        "d1",
        null,
    );

    try trace.recordNode(std.testing.allocator, node);
    try std.testing.expectEqual(@as(usize, 1), trace.nodes.items.len);
    try std.testing.expectEqual(artifact_model.NodeKind.prepare_phase, trace.nodes.items[0].kind);
    try std.testing.expect(trace.prepare_tree != null);
    try std.testing.expectEqualStrings("d1", trace.prepare_tree.?.digest_hex);
}

test "ExecutionTrace formats readable summary" {
    var trace = ExecutionTrace{};
    defer trace.deinit();

    try trace.recordNode(std.testing.allocator, try artifact_model.BuildNode.init(
        std.testing.allocator,
        .source_fetch,
        .restored_from_cache,
        "k1",
        .source_fetch,
        "d1",
        null,
    ));
    try trace.recordNode(std.testing.allocator, try artifact_model.BuildNode.init(
        std.testing.allocator,
        .build_phase,
        .executed,
        "k2",
        .build_tree,
        "d2",
        null,
    ));

    const summary = try trace.formatSummaryAlloc(std.testing.allocator);
    defer std.testing.allocator.free(summary);

    try std.testing.expectEqualStrings("source_fetch(cache) -> build(exec)", summary);
}

test "restoreUnpackedSources does not depend on fetch key record" {
    const test_helpers = @import("../test_helpers.zig");

    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const recipe_dir = try std.fs.path.join(allocator, &.{ test_env.path, "recipe" });
    defer allocator.free(recipe_dir);
    var recipe_dir_handle = try path_mod.makePathAndOpenDir(recipe_dir);
    recipe_dir_handle.close(path_mod.currentIo());

    const source_file = try std.fs.path.join(allocator, &.{ recipe_dir, "source.txt" });
    defer allocator.free(source_file);
    var source_handle = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), source_file, .{});
    defer source_handle.close(path_mod.currentIo());
    try source_handle.writeStreamingAll(path_mod.currentIo(), "source");

    const recipe_buf =
        \\recipe {
        \\  name "demo"
        \\  version "1.0.0"
        \\  release 1
        \\}
        \\source "source.txt" {}
        \\package "demo" {
        \\  files "usr/share/demo/*"
        \\}
    ;
    var parsed_recipe = try recipe.parse(&test_env.ctx, recipe_buf);
    defer parsed_recipe.deinit();

    const fetched_dir = try std.fs.path.join(allocator, &.{ test_env.path, "fetched" });
    defer allocator.free(fetched_dir);
    var fetched_dir_handle = try path_mod.makePathAndOpenDir(fetched_dir);
    fetched_dir_handle.close(path_mod.currentIo());

    const fetched_file = try std.fs.path.join(allocator, &.{ fetched_dir, "source.txt" });
    defer allocator.free(fetched_file);
    var fetched_handle = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), fetched_file, .{});
    defer fetched_handle.close(path_mod.currentIo());
    try fetched_handle.writeStreamingAll(path_mod.currentIo(), "fetched");

    const fetch_key = try build_cache.computeSourceFetchKey(allocator, &test_env.ctx, recipe_dir, &parsed_recipe);
    defer allocator.free(fetch_key);

    var fetch_record = try build_cache.storeDirectoryForKey(allocator, &test_env.ctx, .source_fetch, fetch_key, fetched_dir, null);
    defer fetch_record.deinit();

    const unpacked_dir = try std.fs.path.join(allocator, &.{ test_env.path, "unpacked" });
    defer allocator.free(unpacked_dir);
    const actual_dir = try std.fs.path.join(allocator, &.{ unpacked_dir, "demo-1.0.0" });
    defer allocator.free(actual_dir);
    var actual_dir_handle = try path_mod.makePathAndOpenDir(actual_dir);
    actual_dir_handle.close(path_mod.currentIo());

    const unpacked_file = try std.fs.path.join(allocator, &.{ actual_dir, "hello.txt" });
    defer allocator.free(unpacked_file);
    var unpacked_handle = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), unpacked_file, .{});
    defer unpacked_handle.close(path_mod.currentIo());
    try unpacked_handle.writeStreamingAll(path_mod.currentIo(), "unpacked");

    const unpack_key = try build_cache.computeSourceUnpackKey(allocator, fetch_key);
    defer allocator.free(unpack_key);
    var unpack_record = try build_cache.storeDirectoryForKey(allocator, &test_env.ctx, .source_unpack, unpack_key, unpacked_dir, actual_dir);
    defer unpack_record.deinit();

    const cache_root = try std.fs.path.join(allocator, &.{ test_env.ctx.root(), "mere", "dev", "cache", "build" });
    defer allocator.free(cache_root);
    const fetch_key_path = try std.fs.path.join(allocator, &.{ cache_root, "keys", build_cache.ArtifactKind.source_fetch.asString(), fetch_key });
    defer allocator.free(fetch_key_path);
    try std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), fetch_key_path);

    const restore_dir = try std.fs.path.join(allocator, &.{ test_env.path, "restore-unpacked" });
    defer allocator.free(restore_dir);

    var restored = (try restoreUnpackedSources(
        allocator,
        &test_env.ctx,
        true,
        recipe_dir,
        &parsed_recipe,
        restore_dir,
    )).?;
    defer restored.deinit();

    try std.testing.expect(restored.actual_path != null);
    const restored_file = try std.fs.path.join(allocator, &.{ restore_dir, "demo-1.0.0", "hello.txt" });
    defer allocator.free(restored_file);
    const content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), path_mod.currentIo(), restored_file, allocator, .limited(64));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("unpacked", content);
}
