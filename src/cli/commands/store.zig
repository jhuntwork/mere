/// Store maintenance commands — groups gc, verify, pin, and generation under 'mere store'.
const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;

const gc_cmd = @import("gc.zig");
const verify_cmd = @import("verify.zig");
const pin_cmd = @import("pin.zig");
const generation_cmd = @import("generation.zig");
const init_cmd = @import("init.zig");

const store_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 90,
    .name = "store",
    .description = "Store maintenance",
};

fn handleStore(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const store_cmd = try allocator.create(command.Command);
    store_cmd.* = command.Command.init(allocator, store_meta, handleStore);

    // Rename gc to clean
    const clean_command = try gc_cmd.createCommand(allocator);
    clean_command.meta.name = "clean";
    clean_command.meta.description = "Remove unreferenced store objects";
    try store_cmd.addSubcommand(clean_command);

    const verify_command = try verify_cmd.createCommand(allocator);
    try store_cmd.addSubcommand(verify_command);

    const pin_command = try pin_cmd.createCommand(allocator);
    try store_cmd.addSubcommand(pin_command);

    const generation_command = try generation_cmd.createCommand(allocator);
    try store_cmd.addSubcommand(generation_command);

    const init_command = try init_cmd.createCommand(allocator);
    try store_cmd.addSubcommand(init_command);

    return store_cmd;
}
