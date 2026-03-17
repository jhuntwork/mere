const std = @import("std");
const mere = @import("mere.zig");

pub const Selection = struct {
    sources: bool,
    cache: bool,
    workspaces: bool,
    outputs: bool,
};

pub const Result = struct {
    sources_removed: usize = 0,
    cache_removed: usize = 0,
    workspaces_removed: usize = 0,
    outputs_removed: usize = 0,
};

pub fn resolve(
    sources: bool,
    cache: bool,
    workspaces: bool,
    outputs: bool,
) Selection {
    const has_explicit_scope = sources or cache or workspaces or outputs;
    if (has_explicit_scope) {
        return .{
            .sources = sources,
            .cache = cache,
            .workspaces = workspaces,
            .outputs = outputs,
        };
    }

    return .{
        .sources = false,
        .cache = true,
        .workspaces = true,
        .outputs = false,
    };
}

pub fn clean(ctx: *mere.Context, selection: Selection) !Result {
    var result = Result{};

    if (selection.workspaces) {
        var wm = mere.workspace_manager.WorkspaceManager.init(ctx);
        result.workspaces_removed = try wm.cleanAllWorkspaces();
    }

    if (selection.cache) {
        result.cache_removed = try mere.build_cache.clear(ctx.allocator, ctx);
    }

    if (selection.sources) {
        result.sources_removed = try mere.source_manager.clearSharedCache(ctx);
    }

    if (selection.outputs) {
        result.outputs_removed = try mere.build.clearBuildOutputs(ctx);
    }

    return result;
}

test "resolve defaults to cache and workspaces" {
    const selection = resolve(false, false, false, false);
    try std.testing.expect(!selection.sources);
    try std.testing.expect(selection.cache);
    try std.testing.expect(selection.workspaces);
    try std.testing.expect(!selection.outputs);
}

test "resolve honors explicit scopes" {
    const selection = resolve(true, false, false, false);
    try std.testing.expect(selection.sources);
    try std.testing.expect(!selection.cache);
    try std.testing.expect(!selection.workspaces);
    try std.testing.expect(!selection.outputs);
}

test "resolve honors outputs scope" {
    const selection = resolve(false, false, false, true);
    try std.testing.expect(!selection.sources);
    try std.testing.expect(!selection.cache);
    try std.testing.expect(!selection.workspaces);
    try std.testing.expect(selection.outputs);
}
