const std = @import("std");
const mere = @import("mere");
const types = @import("types.zig");
const MereError = mere.errors.MereError;
const Flag = types.Flag;
const FlagType = types.FlagType;
const FlagValue = types.FlagValue;
const ParsedArgs = types.ParsedArgs;

/// Unified argument parser that handles global and command flags
pub const ArgumentParser = struct {
    allocator: std.mem.Allocator,
    global_flags: []const Flag,

    pub fn init(allocator: std.mem.Allocator, global_flags: []const Flag) ArgumentParser {
        return ArgumentParser{
            .allocator = allocator,
            .global_flags = global_flags,
        };
    }

    /// Parse command-line arguments into structured form
    pub fn parse(
        self: *ArgumentParser,
        args: []const []const u8,
        command_flags: []const Flag,
    ) MereError!ParsedArgs {
        var parsed = ParsedArgs.init(self.allocator);
        errdefer parsed.deinit();

        var positional = std.ArrayList([]const u8).empty;
        defer positional.deinit(self.allocator);

        var i: usize = 1; // Skip program name

        while (i < args.len) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--")) {
                // End-of-flags separator: everything after this is positional,
                // even if it looks like a flag.
                i += 1;
                while (i < args.len) {
                    try positional.append(self.allocator, args[i]);
                    i += 1;
                }
                break;
            } else if (std.mem.startsWith(u8, arg, "--")) {
                // Long flag
                const flag_name = arg[2..];
                i = try self.parseLongFlag(&parsed, args, &i, flag_name, command_flags);
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                // Short flag(s)
                i = try self.parseShortFlags(&parsed, args, &i, arg[1..], command_flags);
            } else {
                // Positional argument
                try positional.append(self.allocator, arg);
                i += 1;
            }
        }

        // Store positional args
        if (positional.items.len > 0) {
            parsed.positional = try self.allocator.dupe([]const u8, positional.items);
        }

        return parsed;
    }

    /// Parse a long flag (--flag or --flag=value)
    fn parseLongFlag(
        self: *ArgumentParser,
        parsed: *ParsedArgs,
        args: []const []const u8,
        i: *usize,
        flag_name: []const u8,
        command_flags: []const Flag,
    ) MereError!usize {
        // Check for --flag=value format
        var name = flag_name;
        var value: ?[]const u8 = null;

        if (std.mem.indexOf(u8, flag_name, "=")) |eq_pos| {
            name = flag_name[0..eq_pos];
            value = flag_name[eq_pos + 1 ..];
        }

        // Find the flag definition
        const flag_def = self.findFlag(name, command_flags) orelse {
            return MereError.InvalidInput;
        };

        const is_global = self.isGlobalFlag(name);
        const target_map = if (is_global) &parsed.global_flags else &parsed.flags;

        switch (flag_def.flag_type) {
            .bool => {
                if (value != null) {
                    return MereError.InvalidInput; // Boolean flags don't take values
                }
                try target_map.put(flag_def.name, FlagValue{ .bool = true });
                return i.* + 1;
            },
            .string => {
                const string_value = blk: {
                    if (value) |v| {
                        break :blk v;
                    } else {
                        const next_i = i.* + 1;
                        if (next_i >= args.len) {
                            if (flag_def.value_optional) {
                                break :blk flag_def.default_value orelse "";
                            }
                            return MereError.MissingArgument;
                        }
                        if (flag_def.value_optional and std.mem.startsWith(u8, args[next_i], "-")) {
                            break :blk flag_def.default_value orelse "";
                        }
                        i.* = next_i;
                        break :blk args[i.*];
                    }
                };
                try target_map.put(flag_def.name, FlagValue{ .string = string_value });
                return i.* + 1;
            },
            .int => {
                const int_string = blk: {
                    if (value) |v| {
                        break :blk v;
                    } else {
                        i.* += 1;
                        if (i.* >= args.len) {
                            return MereError.MissingArgument;
                        }
                        break :blk args[i.*];
                    }
                };
                const int_value = std.fmt.parseInt(i64, int_string, 10) catch {
                    return MereError.InvalidInput;
                };
                try target_map.put(flag_def.name, FlagValue{ .int = int_value });
                return i.* + 1;
            },
        }
    }

    /// Parse short flag(s) (-f or -abc)
    fn parseShortFlags(
        self: *ArgumentParser,
        parsed: *ParsedArgs,
        args: []const []const u8,
        i: *usize,
        flags: []const u8,
        command_flags: []const Flag,
    ) MereError!usize {
        var current_i = i.*;

        for (flags, 0..) |flag_char, j| {
            const flag_def = self.findFlagByShort(flag_char, command_flags) orelse {
                return MereError.InvalidInput;
            };

            const is_global = self.isGlobalFlag(flag_def.name);
            const target_map = if (is_global) &parsed.global_flags else &parsed.flags;

            switch (flag_def.flag_type) {
                .bool => {
                    try target_map.put(flag_def.name, FlagValue{ .bool = true });
                },
                .string, .int => {
                    // For non-boolean flags, the value must come next
                    if (j < flags.len - 1) {
                        // More characters in this flag group, invalid
                        return MereError.InvalidInput;
                    }
                    const next_i = current_i + 1;
                    if (next_i >= args.len) {
                        if (flag_def.flag_type == .string and flag_def.value_optional) {
                            try target_map.put(flag_def.name, FlagValue{ .string = flag_def.default_value orelse "" });
                            continue;
                        }
                        return MereError.MissingArgument;
                    }
                    if (flag_def.flag_type == .string and flag_def.value_optional and std.mem.startsWith(u8, args[next_i], "-")) {
                        try target_map.put(flag_def.name, FlagValue{ .string = flag_def.default_value orelse "" });
                        continue;
                    }
                    current_i = next_i;

                    const value_string = args[current_i];
                    if (flag_def.flag_type == .string) {
                        try target_map.put(flag_def.name, FlagValue{ .string = value_string });
                    } else {
                        const int_value = std.fmt.parseInt(i64, value_string, 10) catch {
                            return MereError.InvalidInput;
                        };
                        try target_map.put(flag_def.name, FlagValue{ .int = int_value });
                    }
                },
            }
        }

        return current_i + 1;
    }

    /// Find a flag by name in either global or command flags
    fn findFlag(self: *ArgumentParser, name: []const u8, command_flags: []const Flag) ?*const Flag {
        // Check command flags first
        for (command_flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                return flag;
            }
        }

        // Check global flags
        for (self.global_flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                return flag;
            }
        }

        return null;
    }

    /// Find a flag by short name
    fn findFlagByShort(self: *ArgumentParser, short: u8, command_flags: []const Flag) ?*const Flag {
        // Check command flags first
        for (command_flags) |*flag| {
            if (flag.short != null and flag.short.? == short) {
                return flag;
            }
        }

        // Check global flags
        for (self.global_flags) |*flag| {
            if (flag.short != null and flag.short.? == short) {
                return flag;
            }
        }

        return null;
    }

    /// Check if a flag is a global flag
    fn isGlobalFlag(self: *ArgumentParser, name: []const u8) bool {
        for (self.global_flags) |flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                return true;
            }
        }
        return false;
    }
};

test "parse treats -- as end-of-flags, keeping flag-like tokens positional" {
    const testing = std.testing;
    const global_flags = [_]Flag{};
    var p = ArgumentParser.init(testing.allocator, &global_flags);

    const command_flags = [_]Flag{
        .{ .name = "verbose", .short = 'v', .description = "", .flag_type = .bool },
    };

    const args = [_][]const u8{ "mere", "-v", "--", "-v", "--not-a-flag", "pos" };
    var parsed = try p.parse(&args, &command_flags);
    defer parsed.deinit();

    // The flag before -- was parsed normally.
    try testing.expect(parsed.getFlag("verbose").?.bool);

    // Everything after -- is positional, including tokens that look like flags.
    try testing.expectEqual(@as(usize, 3), parsed.positional.len);
    try testing.expectEqualStrings("-v", parsed.positional[0]);
    try testing.expectEqualStrings("--not-a-flag", parsed.positional[1]);
    try testing.expectEqualStrings("pos", parsed.positional[2]);
}

test "parse handles a bare -- with nothing before or after it" {
    const testing = std.testing;
    const global_flags = [_]Flag{};
    var p = ArgumentParser.init(testing.allocator, &global_flags);
    const command_flags = [_]Flag{};

    const args = [_][]const u8{ "mere", "--" };
    var parsed = try p.parse(&args, &command_flags);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 0), parsed.positional.len);
}

test "parse still rejects an unknown long flag before --" {
    const testing = std.testing;
    const global_flags = [_]Flag{};
    var p = ArgumentParser.init(testing.allocator, &global_flags);
    const command_flags = [_]Flag{};

    const args = [_][]const u8{ "mere", "--bogus", "--", "pos" };
    try testing.expectError(MereError.InvalidInput, p.parse(&args, &command_flags));
}
