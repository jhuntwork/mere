const std = @import("std");
const mere = @import("mere.zig");
const download = @import("download.zig");
const repocache = @import("repocache.zig");
const sign = @import("sign.zig");

pub const SyncPolicy = enum {
    automatic,
    force,
    no_sync,
};

pub const Request = struct {
    policy: SyncPolicy = .automatic,
    repositories: []const []const u8 = &.{},
    strict: bool = false,
};

pub const OutcomeStatus = enum {
    ready,
    failed,
    not_found,
};

pub const Outcome = struct {
    name: []const u8,
    cache: ?*repocache.RepoCache,
    status: OutcomeStatus,
    failure: ?anyerror = null,
};

pub const Result = struct {
    outcomes: std.ArrayList(Outcome) = .empty,
    ready_count: usize = 0,
    selected_count: usize = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.outcomes.deinit(allocator);
    }

    pub fn failureCount(self: *const Result) usize {
        var count: usize = 0;
        for (self.outcomes.items) |outcome| {
            if (outcome.status != .ready) count += 1;
        }
        return count;
    }

    pub fn firstFailure(self: *const Result) ?anyerror {
        for (self.outcomes.items) |outcome| {
            switch (outcome.status) {
                .ready => {},
                .failed => return outcome.failure orelse error.RepositoryUnavailable,
                .not_found => return error.RepositoryNotFound,
            }
        }
        return null;
    }
};

fn isSelected(names: []const []const u8, candidate: []const u8) bool {
    if (names.len == 0) return true;
    for (names) |name| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn synchronizeOne(
    cache: *repocache.RepoCache,
    client: download.TransferClient,
    request: Request,
    loaded_keys: []const sign.LoadedKey,
) !void {
    if (request.strict) {
        try cache.sync(client, .{
            .force = true,
            .interval_seconds = cache.sync_interval_seconds,
            .timeout_seconds = cache.sync_timeout_seconds,
            .allow_stale_fallback = false,
        }, loaded_keys);
    } else switch (request.policy) {
        .automatic, .force => try cache.sync(client, .{
            .force = request.policy == .force,
            .interval_seconds = cache.sync_interval_seconds,
            .timeout_seconds = cache.sync_timeout_seconds,
        }, loaded_keys),
        .no_sync => {},
    }

    try cache.ensureRepository(loaded_keys);
}

/// Apply one repository synchronization contract to a set of initialized
/// caches. Operational repository failures are returned as per-repository
/// outcomes so strict sync can report all failures and search can retain
/// partial results. Resource exhaustion still aborts the operation.
pub fn synchronize(
    ctx: *mere.Context,
    caches: []*repocache.RepoCache,
    client: download.TransferClient,
    request: Request,
    loaded_keys: []const sign.LoadedKey,
) !Result {
    var result = Result{};
    errdefer result.deinit(ctx.allocator);

    const matched = try ctx.allocator.alloc(bool, request.repositories.len);
    defer ctx.allocator.free(matched);
    @memset(matched, false);

    for (caches) |cache| {
        if (!isSelected(request.repositories, cache.name)) continue;
        result.selected_count += 1;
        for (request.repositories, 0..) |name, index| {
            if (std.mem.eql(u8, name, cache.name)) matched[index] = true;
        }

        synchronizeOne(cache, client, request, loaded_keys) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try result.outcomes.append(ctx.allocator, .{
                .name = cache.name,
                .cache = cache,
                .status = .failed,
                .failure = err,
            });
            continue;
        };

        result.ready_count += 1;
        try result.outcomes.append(ctx.allocator, .{
            .name = cache.name,
            .cache = cache,
            .status = .ready,
        });
    }

    for (request.repositories, 0..) |name, index| {
        if (matched[index]) continue;
        try result.outcomes.append(ctx.allocator, .{
            .name = name,
            .cache = null,
            .status = .not_found,
            .failure = error.RepositoryNotFound,
        });
    }

    return result;
}

test "repository selection reports unknown names without hiding ready repositories" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    var cache = try repocache.RepoCache.init(ctx, "known", "https://repo.example.com/known", &.{}, 100);
    defer cache.deinit();
    var caches = [_]*repocache.RepoCache{&cache};

    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    var vtable = download.TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    const names = [_][]const u8{ "known", "missing" };
    var result = try synchronize(ctx, caches[0..], client, .{
        .policy = .no_sync,
        .repositories = &names,
    }, &.{});
    defer result.deinit(ctx.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.selected_count);
    try std.testing.expectEqual(@as(usize, 2), result.failureCount());
    try std.testing.expectEqual(OutcomeStatus.failed, result.outcomes.items[0].status);
    try std.testing.expectEqual(OutcomeStatus.not_found, result.outcomes.items[1].status);
}
