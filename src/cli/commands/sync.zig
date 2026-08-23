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

fn selected(names: []const []const u8, candidate: []const u8) bool {
    if (names.len == 0) return true;
    for (names) |name| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn repositorySyncPolicy(args: *const types.ParsedArgs) MereError!mere.repocache.SyncPolicy {
    return repositorySyncPolicyFromFlags(args.getBool("sync"), args.getBool("no-sync"));
}

fn repositorySyncPolicyFromFlags(force: bool, disabled: bool) MereError!mere.repocache.SyncPolicy {
    if (force and disabled) return MereError.InvalidInput;
    if (force) return .force;
    if (disabled) return .no_sync;
    return .automatic;
}

test "repository sync flags are explicit and mutually exclusive" {
    try std.testing.expectEqual(mere.repocache.SyncPolicy.automatic, try repositorySyncPolicyFromFlags(false, false));
    try std.testing.expectEqual(mere.repocache.SyncPolicy.force, try repositorySyncPolicyFromFlags(true, false));
    try std.testing.expectEqual(mere.repocache.SyncPolicy.no_sync, try repositorySyncPolicyFromFlags(false, true));
    try std.testing.expectError(MereError.InvalidInput, repositorySyncPolicyFromFlags(true, true));
}

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

    var matched = try ctx.allocator.alloc(bool, args.positional.len);
    defer ctx.allocator.free(matched);
    @memset(matched, false);

    var failures: usize = 0;
    var attempted: usize = 0;
    for (caches.items) |cache| {
        if (!selected(args.positional, cache.name)) continue;
        attempted += 1;
        for (args.positional, 0..) |name, index| {
            if (std.mem.eql(u8, name, cache.name)) matched[index] = true;
        }

        cache.sync(curl_client.client(), .{
            .force = true,
            .interval_seconds = cache.sync_interval_seconds,
            .timeout_seconds = cache.sync_timeout_seconds,
            .allow_stale_fallback = false,
        }, loaded_keys.items) catch |err| {
            failures += 1;
            mere.ui.emit.logFmtSeverity(ctx, null, .err, "failed to refresh repository {s}: {s}", .{ cache.name, @errorName(err) });
        };
    }

    for (args.positional, 0..) |name, index| {
        if (!matched[index]) {
            failures += 1;
            mere.ui.emit.logFmtSeverity(ctx, null, .err, "enabled repository not found: {s}", .{name});
        }
    }

    if (attempted == 0 and args.positional.len == 0) {
        return .{ .success = true, .message = "no enabled repositories configured" };
    }
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
