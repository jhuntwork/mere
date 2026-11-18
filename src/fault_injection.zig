const std = @import("std");
const builtin = @import("builtin");

/// Named mutation boundaries used by crash-restart tests. The production
/// paths do nothing unless a test configures an action, so the checkpoints are
/// observable without changing normal behavior.
pub const Checkpoint = enum {
    current_before_replace,
    current_after_replace,
    etc_before_changes,
    etc_after_changes,
    boot_before_staging,
    boot_after_staging,
    gc_roots_before_update,
    gc_roots_after_update,
    repository_before_database_publish,
    repository_after_database_publish,
    repository_before_signature_publish,
    repository_after_signature_publish,
    store_before_admission,
    store_after_admission,
    store_harden_chown,
    store_harden_chmod,
    store_harden_immutable,
    gc_before_collection,
    gc_after_collection,
    install_before_activation,
    install_after_activation,
};

pub const Action = enum {
    none,
    fail,
    terminate,
};

pub const Error = error{InjectedFailure};

var configured_checkpoint: ?Checkpoint = null;
var configured_action: Action = .none;

/// Configure one checkpoint for an in-process fault-injection test.
pub fn setForTest(checkpoint: Checkpoint, action: Action) void {
    if (!builtin.is_test) return;
    configured_checkpoint = checkpoint;
    configured_action = action;
}

pub fn clearForTest() void {
    configured_checkpoint = null;
    configured_action = .none;
}

/// Configure a child-process test from MERE_FAULT_CHECKPOINT and
/// MERE_FAULT_ACTION. This is deliberately opt-in; ordinary processes never
/// inspect the variables unless a test calls this function.
pub fn configureFromEnvironment() void {
    const checkpoint_name = std.c.getenv("MERE_FAULT_CHECKPOINT") orelse return;
    const action_name = std.c.getenv("MERE_FAULT_ACTION") orelse return;
    const checkpoint = parseCheckpoint(std.mem.span(checkpoint_name)) orelse return;
    const action = parseAction(std.mem.span(action_name)) orelse return;
    setForTest(checkpoint, action);
}

/// Consume the action configured for a checkpoint. A termination action exits
/// the process immediately, which lets a parent test observe a real restart
/// boundary rather than an ordinary error return.
pub fn hit(checkpoint: Checkpoint) Error!void {
    if (configured_checkpoint != checkpoint) return;
    const action = configured_action;
    clearForTest();
    switch (action) {
        .none => {},
        .fail => return error.InjectedFailure,
        .terminate => std.process.exit(86),
    }
}

fn parseAction(name: []const u8) ?Action {
    if (std.mem.eql(u8, name, "fail")) return .fail;
    if (std.mem.eql(u8, name, "terminate")) return .terminate;
    return null;
}

fn parseCheckpoint(name: []const u8) ?Checkpoint {
    inline for (std.meta.fields(Checkpoint)) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(Checkpoint, field.name);
    }
    return null;
}

test "fault checkpoints parse stable names and consume once" {
    setForTest(.current_after_replace, .fail);
    try std.testing.expectError(error.InjectedFailure, hit(.current_after_replace));
    try hit(.current_after_replace);
}
