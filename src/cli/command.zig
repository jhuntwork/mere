const std = @import("std");
const mere = @import("mere");
const types = @import("types.zig");
const MereError = mere.errors.MereError;
const help = @import("help.zig");

/// Command metadata - defines a command's interface
pub const CommandMeta = struct {
    name: []const u8,
    description: []const u8,
    args: []const types.Arg = &[_]types.Arg{},
    flags: []const types.Flag = &[_]types.Flag{},
    hidden: bool = false,
    group: ?[]const u8 = null,
    order: u8 = 50,
};

/// Command handler function type
pub const CommandHandler = *const fn (ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult;

/// Command definition
pub const Command = struct {
    meta: CommandMeta,
    handler: CommandHandler,
    subcommands: std.StringHashMap(*const Command),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, meta: CommandMeta, handler: CommandHandler) Command {
        return Command{
            .meta = meta,
            .handler = handler,
            .subcommands = std.StringHashMap(*const Command).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Command) void {
        self.subcommands.deinit();
    }

    /// Add a subcommand to this command
    pub fn addSubcommand(self: *Command, subcommand: *const Command) !void {
        try self.subcommands.put(subcommand.meta.name, subcommand);
    }

    /// Find a subcommand by name
    pub fn findSubcommand(self: *const Command, name: []const u8) ?*const Command {
        return self.subcommands.get(name);
    }

    /// Get all subcommand names and descriptions
    pub fn getSubcommands(self: *const Command, allocator: std.mem.Allocator) !struct {
        names: [][]const u8,
        descriptions: [][]const u8,
        groups: []?[]const u8,
    } {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        var descriptions = std.ArrayList([]const u8).empty;
        defer descriptions.deinit(allocator);
        var groups = std.ArrayList(?[]const u8).empty;
        defer groups.deinit(allocator);
        var orders = std.ArrayList(u8).empty;
        defer orders.deinit(allocator);

        var iterator = self.subcommands.iterator();
        while (iterator.next()) |entry| {
            const cmd = entry.value_ptr.*;
            if (!cmd.meta.hidden) {
                try names.append(allocator, cmd.meta.name);
                try descriptions.append(allocator, cmd.meta.description);
                try groups.append(allocator, cmd.meta.group);
                try orders.append(allocator, cmd.meta.order);
            }
        }

        const sort_context = struct {
            names_slice: [][]const u8,
            descriptions_slice: [][]const u8,
            groups_slice: []?[]const u8,
            orders_slice: []u8,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                if (ctx.orders_slice[a] != ctx.orders_slice[b])
                    return ctx.orders_slice[a] < ctx.orders_slice[b];
                return std.mem.lessThan(u8, ctx.names_slice[a], ctx.names_slice[b]);
            }

            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                std.mem.swap([]const u8, &ctx.names_slice[a], &ctx.names_slice[b]);
                std.mem.swap([]const u8, &ctx.descriptions_slice[a], &ctx.descriptions_slice[b]);
                std.mem.swap(?[]const u8, &ctx.groups_slice[a], &ctx.groups_slice[b]);
                std.mem.swap(u8, &ctx.orders_slice[a], &ctx.orders_slice[b]);
            }
        }{
            .names_slice = names.items,
            .descriptions_slice = descriptions.items,
            .groups_slice = groups.items,
            .orders_slice = orders.items,
        };
        std.mem.sortContext(0, names.items.len, sort_context);

        return .{
            .names = try allocator.dupe([]const u8, names.items),
            .descriptions = try allocator.dupe([]const u8, descriptions.items),
            .groups = try allocator.dupe(?[]const u8, groups.items),
        };
    }

    /// Validate that required arguments are present
    pub fn validateArgs(self: *const Command, args: *const types.ParsedArgs) MereError!void {
        var required_count: usize = 0;
        for (self.meta.args) |arg| {
            if (arg.required) {
                required_count += 1;
            }
        }

        if (args.positional.len < required_count) {
            return MereError.MissingArgument;
        }
    }

    /// Validate that required flags are present
    pub fn validateFlags(self: *const Command, args: *const types.ParsedArgs) MereError!void {
        for (self.meta.flags) |flag| {
            if (flag.required and args.getFlag(flag.name) == null) {
                return MereError.MissingArgument;
            }
        }
    }
};

/// Command registry for auto-discovery and routing
pub const CommandRegistry = struct {
    commands: std.StringHashMap(*const Command),
    allocator: std.mem.Allocator,
    root_command: ?*const Command,

    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return CommandRegistry{
            .commands = std.StringHashMap(*const Command).init(allocator),
            .allocator = allocator,
            .root_command = null,
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.commands.deinit();
    }

    /// Register a command
    pub fn register(self: *CommandRegistry, command: *const Command) !void {
        try self.commands.put(command.meta.name, command);
    }

    /// Set the root command
    pub fn setRoot(self: *CommandRegistry, command: *const Command) void {
        self.root_command = command;
    }

    /// Find a command by path (e.g., ["dev", "import"])
    pub fn findCommand(self: *CommandRegistry, command_path: []const []const u8) ?*const Command {
        if (command_path.len == 0) {
            return self.root_command;
        }

        var current = self.commands.get(command_path[0]);
        if (current == null) {
            return null;
        }

        // Navigate down the command tree
        for (command_path[1..]) |part| {
            current = current.?.findSubcommand(part);
            if (current == null) {
                return null;
            }
        }

        return current;
    }

    /// Get all top-level command names and descriptions
    pub fn getTopLevelCommands(self: *CommandRegistry, allocator: std.mem.Allocator) !struct {
        names: [][]const u8,
        descriptions: [][]const u8,
        groups: []?[]const u8,
    } {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        var descriptions = std.ArrayList([]const u8).empty;
        defer descriptions.deinit(allocator);
        var groups = std.ArrayList(?[]const u8).empty;
        defer groups.deinit(allocator);
        var orders = std.ArrayList(u8).empty;
        defer orders.deinit(allocator);

        var iterator = self.commands.iterator();
        while (iterator.next()) |entry| {
            const cmd = entry.value_ptr.*;
            if (!cmd.meta.hidden) {
                try names.append(allocator, cmd.meta.name);
                try descriptions.append(allocator, cmd.meta.description);
                try groups.append(allocator, cmd.meta.group);
                try orders.append(allocator, cmd.meta.order);
            }
        }

        const sort_context = struct {
            names_slice: [][]const u8,
            descriptions_slice: [][]const u8,
            groups_slice: []?[]const u8,
            orders_slice: []u8,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                if (ctx.orders_slice[a] != ctx.orders_slice[b])
                    return ctx.orders_slice[a] < ctx.orders_slice[b];
                return std.mem.lessThan(u8, ctx.names_slice[a], ctx.names_slice[b]);
            }

            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                std.mem.swap([]const u8, &ctx.names_slice[a], &ctx.names_slice[b]);
                std.mem.swap([]const u8, &ctx.descriptions_slice[a], &ctx.descriptions_slice[b]);
                std.mem.swap(?[]const u8, &ctx.groups_slice[a], &ctx.groups_slice[b]);
                std.mem.swap(u8, &ctx.orders_slice[a], &ctx.orders_slice[b]);
            }
        }{
            .names_slice = names.items,
            .descriptions_slice = descriptions.items,
            .groups_slice = groups.items,
            .orders_slice = orders.items,
        };
        std.mem.sortContext(0, names.items.len, sort_context);

        return .{
            .names = try allocator.dupe([]const u8, names.items),
            .descriptions = try allocator.dupe([]const u8, descriptions.items),
            .groups = try allocator.dupe(?[]const u8, groups.items),
        };
    }
};

pub fn exitCodeForError(err: MereError) u8 {
    return switch (err) {
        MereError.InvalidInput, MereError.MissingArgument => 2,
        MereError.PermissionDenied => 13,
        MereError.OutOfMemory, MereError.OutOfDisk, MereError.TooManyFiles => 12,
        else => 1,
    };
}
