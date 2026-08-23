const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = types.MereError;

const sync_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 21,
    .name = "sync",
    .description = "Refresh and verify repository metadata",
    .args = &[_]types.Arg{
        .{
            .name = "repository",
            .description = "Enabled repository name(s); omit to refresh all",
            .required = false,
        },
    },
};

fn handleSync(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const config = ctx.getConfig() catch |err| return try command.errorResult(ctx, err, null);
    var caches = mere.repo_sources.createCaches(ctx, config) catch |err| return try command.errorResult(ctx, err, null);
    defer {
        for (caches.items) |cache| {
            cache.deinit();
            ctx.allocator.destroy(cache);
        }
        caches.deinit(ctx.allocator);
    }

    var loaded_keys = mere.sign.loadAllKeys(ctx) catch |err| return try command.errorResult(ctx, err, null);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    var curl_client = mere.download.CurlTransferClient.init(ctx, command.user_agent) catch |err| {
        return try command.errorResult(ctx, err, null);
    };
    defer mere.download.CurlTransferClient.cleanupFn(ctx, curl_client);

    var sync_result = mere.repo_sync.synchronize(ctx, caches.items, curl_client.client(), .{
        .policy = .force,
        .repositories = args.positional,
        .strict = true,
    }, loaded_keys.items) catch |err| return try command.errorResult(ctx, err, null);
    defer sync_result.deinit(ctx.allocator);

    for (sync_result.outcomes.items) |outcome| {
        switch (outcome.status) {
            .ready => {},
            .failed => mere.ui.emit.logFmtSeverity(ctx, null, .err, "failed to refresh repository {s}: {s}", .{ outcome.name, @errorName(outcome.failure.?) }),
            .not_found => mere.ui.emit.logFmtSeverity(ctx, null, .err, "enabled repository not found: {s}", .{outcome.name}),
        }
    }

    if (sync_result.selected_count == 0 and args.positional.len == 0) {
        return .{ .success = true, .message = "no enabled repositories configured" };
    }
    const failures = sync_result.failureCount();
    if (failures > 0) {
        return .{
            .success = false,
            .exit_code = 1,
            .message = try std.fmt.allocPrint(ctx.allocator, "repository synchronization failed for {d} requested source(s)", .{failures}),
        };
    }
    return .{ .success = true };
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, sync_meta, handleSync);
    return cmd;
}
