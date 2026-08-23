const std = @import("std");
const mere = @import("mere");
const types = @import("types.zig");
const MereError = types.MereError;

pub fn repositorySyncPolicy(args: *const types.ParsedArgs) MereError!mere.repo_sync.SyncPolicy {
    return fromFlags(args.getBool("sync"), args.getBool("no-sync"));
}

fn fromFlags(force: bool, disabled: bool) MereError!mere.repo_sync.SyncPolicy {
    if (force and disabled) return MereError.InvalidInput;
    if (force) return .force;
    if (disabled) return .no_sync;
    return .automatic;
}

test "repository sync flags are explicit and mutually exclusive" {
    try std.testing.expectEqual(mere.repo_sync.SyncPolicy.automatic, try fromFlags(false, false));
    try std.testing.expectEqual(mere.repo_sync.SyncPolicy.force, try fromFlags(true, false));
    try std.testing.expectEqual(mere.repo_sync.SyncPolicy.no_sync, try fromFlags(false, true));
    try std.testing.expectError(MereError.InvalidInput, fromFlags(true, true));
}
