const std = @import("std");
const mere = @import("mere");
const types = @import("types.zig");
const MereError = mere.errors.MereError;
const Flag = types.Flag;
const Arg = types.Arg;

/// Help formatter for consistent command help output
pub const HelpFormatter = struct {
    allocator: std.mem.Allocator,
    program_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, program_name: []const u8) HelpFormatter {
        return HelpFormatter{
            .allocator = allocator,
            .program_name = program_name,
        };
    }

    /// Generate usage line for a command
    pub fn formatUsage(
        self: *HelpFormatter,
        command_path: []const []const u8,
        args: []const Arg,
        flags: []const Flag,
        global_flags: []const Flag,
        has_subcommands: bool,
    ) ![]u8 {
        var usage = std.ArrayList(u8).empty;
        defer usage.deinit(self.allocator);

        var writer = usage.writer(self.allocator);

        // Usage: mere command subcommand
        try writer.writeAll("Usage: ");
        try writer.writeAll(self.program_name);

        for (command_path) |part| {
            try writer.writeByte(' ');
            try writer.writeAll(part);
        }

        // Add subcommands placeholder
        if (has_subcommands) {
            try writer.writeAll(" <subcommand>");
        }

        // Add arguments
        for (args) |arg| {
            try writer.writeByte(' ');
            if (arg.required) {
                try writer.print("<{s}>", .{arg.name});
            } else {
                try writer.print("[{s}]", .{arg.name});
            }
        }

        // Add options placeholder if we have flags
        if (flags.len > 0 or global_flags.len > 0) {
            try writer.writeAll(" [options]");
        }

        return self.allocator.dupe(u8, usage.items);
    }

    /// Generate full help text for a command
    pub fn formatHelp(
        self: *HelpFormatter,
        command_path: []const []const u8,
        description: []const u8,
        args: []const Arg,
        flags: []const Flag,
        global_flags: []const Flag,
        subcommands: []const []const u8, // Just names and descriptions
        subcommand_descriptions: []const []const u8,
    ) ![]u8 {
        var help = std.ArrayList(u8).empty;
        defer help.deinit(self.allocator);

        var writer = help.writer(self.allocator);

        // Usage line
        const usage = try self.formatUsage(command_path, args, flags, global_flags, subcommands.len > 0);
        defer self.allocator.free(usage);
        try writer.writeAll(usage);
        try writer.writeAll("\n\n");

        // Description
        try writer.writeAll(description);
        try writer.writeAll("\n");

        // Arguments section
        if (args.len > 0) {
            try writer.writeAll("\nArguments:\n");
            for (args) |arg| {
                try writer.print("  {s:<12} {s}\n", .{ arg.name, arg.description });
            }
        }

        // Command flags section
        if (flags.len > 0) {
            try writer.writeAll("\nOptions:\n");
            const name_width = 6 + maxFlagNameLen(flags);
            for (flags) |flag| {
                const flag_text = try self.formatFlagName(flag);
                defer self.allocator.free(flag_text);
                try writeAlignedLine(&writer, flag_text, flag.description, name_width);
            }
        }

        // Global flags section
        if (global_flags.len > 0) {
            try writer.writeAll("\nGlobal Options:\n");
            const name_width = 6 + maxFlagNameLen(global_flags);
            for (global_flags) |flag| {
                const flag_text = try self.formatFlagName(flag);
                defer self.allocator.free(flag_text);
                try writeAlignedLine(&writer, flag_text, flag.description, name_width);
            }
        }

        // Subcommands section
        if (subcommands.len > 0) {
            try writer.writeAll("\nSubcommands:\n");
            for (subcommands, subcommand_descriptions) |subcmd, desc| {
                try writer.print("  {s:<12} {s}\n", .{ subcmd, desc });
            }

            // Help instruction
            try writer.writeAll("\nUse '");
            try writer.writeAll(self.program_name);
            for (command_path) |part| {
                try writer.writeByte(' ');
                try writer.writeAll(part);
            }
            try writer.writeAll(" <subcommand> --help' for more information about a subcommand.\n");
        }

        return self.allocator.dupe(u8, help.items);
    }

    /// Format flag name with short option if available
    fn formatFlagName(self: *HelpFormatter, flag: Flag) ![]u8 {
        const placeholder = switch (flag.flag_type) {
            .bool => "",
            .string, .int => blk: {
                const value_name = flag.value_name orelse "value";
                if (flag.value_optional) {
                    break :blk try std.fmt.allocPrint(self.allocator, " [{s}]", .{value_name});
                }
                break :blk try std.fmt.allocPrint(self.allocator, " <{s}>", .{value_name});
            },
        };
        defer if (placeholder.len > 0) self.allocator.free(placeholder);

        if (flag.short) |short| {
            return std.fmt.allocPrint(self.allocator, "-{c}, --{s}{s}", .{ short, flag.name, placeholder });
        } else {
            return std.fmt.allocPrint(self.allocator, "    --{s}{s}", .{ flag.name, placeholder });
        }
    }

    fn writeAlignedLine(writer: anytype, name: []const u8, desc: []const u8, width: usize) !void {
        try writer.writeAll("  ");
        try writer.writeAll(name);
        if (width > name.len) {
            var remaining = width - name.len;
            while (remaining > 0) : (remaining -= 1) {
                try writer.writeByte(' ');
            }
        }
        try writer.writeByte(' ');
        try writer.writeAll(desc);
        try writer.writeByte('\n');
    }

    fn maxFlagNameLen(flags: []const Flag) usize {
        var max_len: usize = 0;
        for (flags) |flag| {
            const short_len: usize = if (flag.short != null) 4 else 0; // "-x, "
            const base_len = short_len + 2 + flag.name.len; // "--name"
            const value_len = switch (flag.flag_type) {
                .bool => 0,
                .string, .int => blk: {
                    const value_name = flag.value_name orelse "value";
                    if (flag.value_optional) {
                        break :blk 3 + value_name.len; // " [x]"
                    }
                    break :blk 3 + value_name.len; // " <x>"
                },
            };
            const total_len = base_len + value_len;
            if (total_len > max_len) {
                max_len = total_len;
            }
        }
        return max_len;
    }
};

/// Standardized error formatter
pub const ErrorFormatter = struct {
    program_name: []const u8,

    pub fn init(program_name: []const u8) ErrorFormatter {
        return ErrorFormatter{
            .program_name = program_name,
        };
    }

    /// Format and print an error message to stderr
    pub fn printError(_: *ErrorFormatter, comptime fmt: []const u8, args: anytype) void {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        stderr.print("error: ", .{}) catch {};
        stderr.print(fmt, args) catch {};
        stderr.writeAll("\n") catch {};
        stderr.flush() catch {};
    }

    /// Print usage suggestion
    pub fn printUsageSuggestion(self: *ErrorFormatter, command_path: []const []const u8) void {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        stderr.print("Try '{s}", .{self.program_name}) catch {};
        for (command_path) |part| {
            stderr.print(" {s}", .{part}) catch {};
        }
        stderr.writeAll(" --help' for more information.\n") catch {};
        stderr.flush() catch {};
    }

    /// Format error for specific CLI errors
    pub fn formatCliError(self: *ErrorFormatter, err: MereError, context: ?[]const u8) void {
        switch (err) {
            MereError.InvalidInput => {
                if (context) |ctx| {
                    self.printError("invalid input: {s}", .{ctx});
                } else {
                    self.printError("invalid input", .{});
                }
            },
            MereError.MissingArgument => {
                if (context) |ctx| {
                    self.printError("missing argument for {s}", .{ctx});
                } else {
                    self.printError("missing required argument", .{});
                }
            },
            MereError.FileSystem => {
                if (context) |ctx| {
                    self.printError("file system error: {s}", .{ctx});
                } else {
                    self.printError("file system error", .{});
                }
            },
            MereError.Network => {
                if (context) |ctx| {
                    self.printError("network error: {s}", .{ctx});
                } else {
                    self.printError("network error", .{});
                }
            },
            MereError.PermissionDenied => {
                if (context) |ctx| {
                    self.printError("permission denied: {s}", .{ctx});
                } else {
                    self.printError("permission denied", .{});
                }
            },
            MereError.CorruptData => {
                if (context) |ctx| {
                    self.printError("data corruption: {s}", .{ctx});
                } else {
                    self.printError("data corruption detected", .{});
                }
            },
            MereError.SignatureInvalid => {
                if (context) |ctx| {
                    self.printError("invalid signature: {s}", .{ctx});
                } else {
                    self.printError("signature verification failed", .{});
                }
            },
            MereError.OutOfMemory => {
                self.printError("out of memory", .{});
            },
            MereError.OutOfDisk => {
                self.printError("insufficient disk space", .{});
            },
            MereError.TooManyFiles => {
                self.printError("too many open files", .{});
            },
            MereError.Internal => {
                if (context) |ctx| {
                    self.printError("internal error: {s}", .{ctx});
                } else {
                    self.printError("internal error", .{});
                }
            },
        }
    }
};
