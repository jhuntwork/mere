const std = @import("std");
const mere = @import("mere");
const types = @import("types.zig");
const parser = @import("parser.zig");
const help = @import("help.zig");
const command = @import("command.zig");
const MereError = mere.errors.MereError;
const path = mere.path;

/// Main CLI coordinator
pub const CLI = struct {
    allocator: std.mem.Allocator,
    program_name: []const u8,
    global_flags: []const types.Flag,
    registry: command.CommandRegistry,
    arg_parser: parser.ArgumentParser,
    help_formatter: help.HelpFormatter,

    pub fn init(allocator: std.mem.Allocator, program_name: []const u8, global_flags: []const types.Flag) CLI {
        return CLI{
            .allocator = allocator,
            .program_name = program_name,
            .global_flags = global_flags,
            .registry = command.CommandRegistry.init(allocator),
            .arg_parser = parser.ArgumentParser.init(allocator, global_flags),
            .help_formatter = help.HelpFormatter.init(allocator, program_name),
        };
    }

    pub fn deinit(self: *CLI) void {
        self.registry.deinit();
    }

    /// Register a command
    pub fn registerCommand(self: *CLI, cmd: *const command.Command) !void {
        try self.registry.register(cmd);
    }

    /// Set the root command
    pub fn setRootCommand(self: *CLI, cmd: *const command.Command) void {
        self.registry.setRoot(cmd);
    }

    /// Execute the CLI with given arguments
    pub fn execute(self: *CLI, args: []const []const u8, ctx: *mere.Context) u8 {
        // Handle the case where no arguments are provided - this is a usage error
        if (args.len < 2) {
            self.showRootHelp() catch {};
            return 2; // Usage error
        }

        // Check for version request before parsing
        if (self.isVersionRequest(args)) {
            return self.handleVersionRequest();
        }

        // First, check for help requests before parsing
        if (self.isHelpRequest(args)) {
            return self.handleHelpRequest(args);
        }

        // Pre-scan to extract global flags and handle -- sentinel
        var prescan_result = prescanGlobalFlags(self.allocator, args[1..], self.global_flags) catch |err| {
            if (findUnknownGlobalFlag(args[1..], self.global_flags)) |flag| {
                emitFormattedCliError(ctx, null, MereError.InvalidInput, flag);
                self.showRootHelp() catch {};
                return 2;
            }
            return self.handleParseError(ctx, err, &[_][]const u8{}, null);
        };
        defer prescan_result.deinit(self.allocator);

        // Apply global flags to context immediately
        if (prescan_result.verbose) {
            ctx.verbose = true;
        }

        // Parse arguments using filtered args (without global flags)
        var parse_args_with_program = std.ArrayList([]const u8).empty;
        defer parse_args_with_program.deinit(self.allocator);
        parse_args_with_program.append(self.allocator, args[0]) catch {
            return 1;
        };
        for (prescan_result.filtered_args) |arg| {
            parse_args_with_program.append(self.allocator, arg) catch {
                return 1;
            };
        }

        var inferred_command_path = self.inferCommandPath(parse_args_with_program.items) catch {
            return 1;
        };
        defer inferred_command_path.deinit(self.allocator);

        var parsed_args = self.parseArgs(parse_args_with_program.items) catch |err| {
            const missing_flag = self.detectMissingValueFlag(parse_args_with_program.items, inferred_command_path.items);
            return self.handleParseError(ctx, err, inferred_command_path.items, missing_flag);
        };
        defer parsed_args.deinit();

        // Store verbose flag in parsed_args for consistency
        if (prescan_result.verbose) {
            parsed_args.global_flags.put("verbose", types.FlagValue{ .bool = true }) catch {};
        }
        if (prescan_result.no_color) {
            parsed_args.global_flags.put("no-color", types.FlagValue{ .bool = true }) catch {};
        }

        // Handle case where no command was specified - this is a usage error
        if (parsed_args.command_path.len == 0) {
            self.showRootHelp() catch {};
            return 2; // Usage error
        }

        // Find and execute the command
        const cmd = self.registry.findCommand(parsed_args.command_path);
        if (cmd == null) {
            const nearest = self.findNearestKnownCommand(parsed_args.command_path);
            if (nearest.unknown_token) |unknown| {
                mere.ui.emit.logFmtSeverity(ctx, commandPhase(parsed_args.command_path), .err, "error: unknown command: {s}", .{unknown});
            } else {
                emitFormattedCliError(ctx, commandPhase(parsed_args.command_path), MereError.InvalidInput, null);
            }

            if (nearest.cmd) |nearest_cmd| {
                self.showCommandHelp(nearest_cmd, parsed_args.command_path[0..nearest.path_len]) catch {};
            } else {
                self.showRootHelp() catch {};
            }
            return 2; // Usage error - unknown command
        }

        return self.executeCommand(cmd.?, &parsed_args, ctx);
    }

    /// Result of global flag pre-scan
    pub const PrescanResult = struct {
        verbose: bool,
        no_color: bool,
        filtered_args: []const []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *PrescanResult, allocator: std.mem.Allocator) void {
            _ = self.allocator;
            allocator.free(self.filtered_args);
        }
    };

    /// Pre-scan arguments to extract global flags and handle -- sentinel.
    /// This allows global flags to appear anywhere before --.
    pub fn prescanGlobalFlags(
        allocator: std.mem.Allocator,
        args: []const []const u8,
        global_flags: []const types.Flag,
    ) MereError!PrescanResult {
        var verbose = false;
        var no_color = false;
        var filtered = std.ArrayList([]const u8).empty;
        defer filtered.deinit(allocator);

        var seen_command_token = false;
        var i: usize = 0;

        while (i < args.len) {
            const arg = args[i];

            // Handle -- sentinel: stop processing flags, keep rest as-is
            if (std.mem.eql(u8, arg, "--")) {
                try filtered.append(allocator, arg);
                i += 1;
                while (i < args.len) : (i += 1) {
                    try filtered.append(allocator, args[i]);
                }
                break;
            }

            if (findGlobalFlag(global_flags, arg)) |flag| {
                if (flag.flag_type != .bool) return MereError.InvalidInput;
                if (std.mem.eql(u8, flag.name, "verbose")) verbose = true;
                if (std.mem.eql(u8, flag.name, "no-color")) no_color = true;
                i += 1;
                continue;
            }

            // Check for unknown global flags (only before first command token)
            if (!seen_command_token and std.mem.startsWith(u8, arg, "-")) {
                return MereError.InvalidInput;
            }

            // Non-flag token: mark that we've seen command start
            if (!std.mem.startsWith(u8, arg, "-")) {
                seen_command_token = true;
            }

            // Keep this token for command parsing
            try filtered.append(allocator, arg);
            i += 1;
        }

        return PrescanResult{
            .verbose = verbose,
            .no_color = no_color,
            .filtered_args = try allocator.dupe([]const u8, filtered.items),
            .allocator = allocator,
        };
    }

    /// Parse command-line arguments
    fn parseArgs(self: *CLI, args: []const []const u8) MereError!types.ParsedArgs {
        // For parsing, we need to determine which flags belong to which command
        // First, let's identify the command path
        var command_path = std.ArrayList([]const u8).empty;
        defer command_path.deinit(self.allocator);

        var i: usize = 1; // Skip program name
        while (i < args.len) {
            const arg = args[i];
            if (std.mem.startsWith(u8, arg, "-")) {
                break; // Found a flag, stop looking for command parts
            }
            try command_path.append(self.allocator, arg);
            i += 1;

            // Check if this forms a valid command path
            const cmd = self.registry.findCommand(command_path.items);
            if (cmd != null and cmd.?.subcommands.count() == 0) {
                // This is a leaf command, stop here
                break;
            }
        }

        // Find the command to get its flags
        const cmd = self.registry.findCommand(command_path.items);
        const cmd_flags = if (cmd) |c| c.meta.flags else &[_]types.Flag{};

        // Parse arguments, but skip the command parts that were already identified
        const start_index = 1 + command_path.items.len;
        const remaining_args = if (start_index < args.len) args[start_index..] else &[_][]const u8{};
        const passthrough_index = for (remaining_args, 0..) |arg, idx| {
            if (std.mem.eql(u8, arg, "--")) break idx;
        } else null;
        const parser_args = if (passthrough_index) |idx| remaining_args[0..idx] else remaining_args;
        const passthrough_args = if (passthrough_index) |idx| remaining_args[idx + 1 ..] else &[_][]const u8{};

        // Create a new args array with program name + remaining args for the parser
        var parse_args = std.ArrayList([]const u8).empty;
        defer parse_args.deinit(self.allocator);
        try parse_args.append(self.allocator, args[0]); // Keep program name
        for (parser_args) |arg| {
            try parse_args.append(self.allocator, arg);
        }

        var parsed = try self.arg_parser.parse(parse_args.items, cmd_flags);

        // Set the command path on the parsed args
        if (command_path.items.len > 0) {
            parsed.command_path = try self.allocator.dupe([]const u8, command_path.items);
        }
        if (passthrough_args.len > 0) {
            parsed.passthrough = try self.allocator.dupe([]const u8, passthrough_args);
        }

        return parsed;
    }

    /// Execute a specific command
    fn executeCommand(self: *CLI, cmd: *const command.Command, args: *const types.ParsedArgs, ctx: *mere.Context) u8 {
        // Check if this command has subcommands but no positional arguments were provided
        if (cmd.subcommands.count() > 0 and args.positional.len == 0 and cmd.meta.args.len == 0) {
            // This command has subcommands but none was specified - show help and return usage error
            self.showCommandHelp(cmd, args.command_path) catch {};
            return 2; // Usage error
        }

        // Validate arguments and flags - just show help for validation errors (consistent with other usage errors)
        cmd.validateArgs(args) catch {
            self.showCommandHelp(cmd, args.command_path) catch {};
            return 2; // Usage error for missing arguments
        };

        cmd.validateFlags(args) catch {
            self.showCommandHelp(cmd, args.command_path) catch {};
            return 2; // Usage error for invalid flags
        };

        // Execute the command
        const result = cmd.handler(ctx, args) catch |err| {
            emitFormattedCliError(ctx, commandPhase(args.command_path), err, null);
            return 1; // Execution error
        };

        if (result.segments) |segments| {
            mere.ui.emit.logSegmentsSeverity(
                ctx,
                commandPhase(args.command_path),
                if (result.success) .info else .err,
                segments,
            );
        } else if (result.message) |msg| {
            if (result.success) {
                mere.ui.emit.logLineSeverity(ctx, commandPhase(args.command_path), .info, msg);
            } else {
                const error_segments = [_]mere.ui.Segment{
                    .{ .text = "error", .kind = .err },
                    .{ .text = ": ", .kind = .normal },
                    .{ .text = msg, .kind = .normal },
                };
                mere.ui.emit.logSegmentsSeverity(ctx, commandPhase(args.command_path), .err, &error_segments);
            }
        }

        return result.exit_code;
    }

    /// Handle parsing errors
    fn handleParseError(self: *CLI, ctx: *mere.Context, err: MereError, command_path: []const []const u8, missing_flag: ?[]const u8) u8 {
        switch (err) {
            MereError.Internal => { // Handle help requests as special case
                if (command_path.len > 0) {
                    const cmd = self.registry.findCommand(command_path);
                    if (cmd) |c| {
                        self.showCommandHelp(c, command_path) catch {};
                    } else {
                        self.showRootHelp() catch {};
                    }
                } else {
                    self.showRootHelp() catch {};
                }
                return 0; // Help explicitly requested
            },
            else => {
                if (err == MereError.MissingArgument and missing_flag != null) {
                    mere.ui.emit.logFmtSeverity(ctx, commandPhase(command_path), .err, "error: missing value for --{s}", .{missing_flag.?});
                } else {
                    emitFormattedCliError(ctx, commandPhase(command_path), err, null);
                }

                if (command_path.len > 0) {
                    const nearest = self.findNearestKnownCommand(command_path);
                    if (nearest.cmd) |cmd| {
                        self.showCommandHelp(cmd, command_path[0..nearest.path_len]) catch {};
                        return 2;
                    }
                }

                self.showRootHelp() catch {};
                return 2; // Usage error
            },
        }
    }

    /// Show help for the root command
    fn showRootHelp(self: *CLI) !void {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(path.currentIo(), &stdout_buffer);
        const stdout = &stdout_writer.interface;

        // Get top-level commands
        const commands = try self.registry.getTopLevelCommands(self.allocator);
        defer self.allocator.free(commands.names);
        defer self.allocator.free(commands.descriptions);
        defer self.allocator.free(commands.groups);

        const help_text = try self.help_formatter.formatHelp(
            &[_][]const u8{}, // Empty command path for root
            "Mere package management tool",
            &[_]types.Arg{}, // No args for root
            &[_]types.Flag{}, // No command flags for root
            self.global_flags,
            commands.names,
            commands.descriptions,
            commands.groups,
        );
        defer self.allocator.free(help_text);

        try stdout.writeAll(help_text);
        try stdout.flush();
    }

    /// Show help for a specific command
    fn showCommandHelp(self: *CLI, cmd: *const command.Command, command_path: []const []const u8) !void {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(path.currentIo(), &stdout_buffer);
        const stdout = &stdout_writer.interface;

        // Get subcommands
        const subcommands = try cmd.getSubcommands(self.allocator);
        defer self.allocator.free(subcommands.names);
        defer self.allocator.free(subcommands.descriptions);
        defer self.allocator.free(subcommands.groups);

        const help_text = try self.help_formatter.formatHelp(
            command_path,
            cmd.meta.description,
            cmd.meta.args,
            cmd.meta.flags,
            self.global_flags,
            subcommands.names,
            subcommands.descriptions,
            subcommands.groups,
        );
        defer self.allocator.free(help_text);

        try stdout.writeAll(help_text);
        try stdout.flush();
    }

    /// Check if the arguments contain a help request
    fn isHelpRequest(self: *CLI, args: []const []const u8) bool {
        _ = self;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            if (std.mem.eql(u8, arg, "help") or
                std.mem.eql(u8, arg, "--help") or
                std.mem.eql(u8, arg, "-h"))
            {
                return true;
            }
        }
        return false;
    }

    /// Check if the arguments contain a version request
    fn isVersionRequest(self: *CLI, args: []const []const u8) bool {
        _ = self;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            if (std.mem.eql(u8, arg, "--version")) {
                return true;
            }
        }
        return false;
    }

    /// Handle version requests
    fn handleVersionRequest(self: *CLI) u8 {
        _ = self;
        const build_zon: struct {
            name: enum { mere },
            version: []const u8,
            fingerprint: u64,
            minimum_zig_version: []const u8,
            paths: []const []const u8,
        } = @import("build_zon");

        var version_buffer: [256]u8 = undefined;
        const version_str = std.fmt.bufPrint(&version_buffer, "mere {s}\n", .{build_zon.version}) catch return 1;

        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(path.currentIo(), &stdout_buffer);
        stdout_writer.interface.writeAll(version_str) catch return 1;
        stdout_writer.interface.flush() catch return 1;
        return 0;
    }

    /// Handle help requests by determining the correct context
    fn handleHelpRequest(self: *CLI, args: []const []const u8) u8 {
        // Find the command path before the help flag
        var command_path = std.ArrayList([]const u8).empty;
        defer command_path.deinit(self.allocator);

        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "help") or
                std.mem.eql(u8, arg, "--help") or
                std.mem.eql(u8, arg, "-h"))
            {
                break;
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                break; // Stop at flags
            }
            command_path.append(self.allocator, arg) catch break;
        }

        if (command_path.items.len == 0) {
            // Root help
            self.showRootHelp() catch {};
            return 0;
        }

        // Find the command and show its help
        const cmd = self.registry.findCommand(command_path.items);
        if (cmd) |c| {
            self.showCommandHelp(c, command_path.items) catch {};
        } else {
            self.showRootHelp() catch {};
        }
        return 0;
    }

    const CommandPath = struct {
        items: []const []const u8,

        fn deinit(self: *CommandPath, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }
    };

    fn inferCommandPath(self: *CLI, args: []const []const u8) !CommandPath {
        var command_path = std.ArrayList([]const u8).empty;
        defer command_path.deinit(self.allocator);

        var i: usize = 1; // Skip program name
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.startsWith(u8, arg, "-")) break;
            try command_path.append(self.allocator, arg);

            const cmd = self.registry.findCommand(command_path.items);
            if (cmd != null and cmd.?.subcommands.count() == 0) break;
        }

        return CommandPath{ .items = try self.allocator.dupe([]const u8, command_path.items) };
    }

    const NearestCommand = struct {
        cmd: ?*const command.Command,
        path_len: usize,
        unknown_token: ?[]const u8,
    };

    fn findNearestKnownCommand(self: *CLI, command_path: []const []const u8) NearestCommand {
        var nearest = NearestCommand{
            .cmd = self.registry.root_command,
            .path_len = 0,
            .unknown_token = null,
        };

        var i: usize = 1;
        while (i <= command_path.len) : (i += 1) {
            const prefix = command_path[0..i];
            const cmd = self.registry.findCommand(prefix) orelse {
                nearest.unknown_token = command_path[i - 1];
                return nearest;
            };
            nearest.cmd = cmd;
            nearest.path_len = i;
        }

        return nearest;
    }

    fn findGlobalFlag(global_flags: []const types.Flag, arg: []const u8) ?types.Flag {
        if (std.mem.startsWith(u8, arg, "--")) {
            const flag_name = arg[2..];
            for (global_flags) |flag| {
                if (std.mem.eql(u8, flag.name, flag_name)) return flag;
            }
            return null;
        }

        if (arg.len == 2 and arg[0] == '-') {
            const short = arg[1];
            for (global_flags) |flag| {
                if (flag.short != null and flag.short.? == short) return flag;
            }
        }

        return null;
    }

    fn findUnknownGlobalFlag(args: []const []const u8, global_flags: []const types.Flag) ?[]const u8 {
        var seen_command_token = false;
        var i: usize = 0;

        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) break;
            if (!seen_command_token and std.mem.startsWith(u8, arg, "-")) {
                if (findGlobalFlag(global_flags, arg) != null) {
                    continue;
                }
                return arg;
            }
            if (!std.mem.startsWith(u8, arg, "-")) {
                seen_command_token = true;
            }
        }
        return null;
    }

    fn detectMissingValueFlag(self: *CLI, args: []const []const u8, command_path: []const []const u8) ?[]const u8 {
        const cmd = self.registry.findCommand(command_path);
        const cmd_flags = if (cmd) |c| c.meta.flags else &[_]types.Flag{};
        const start_index = 1 + command_path.len;
        if (start_index >= args.len) return null;

        var i: usize = start_index;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (!std.mem.startsWith(u8, arg, "-")) continue;

            if (std.mem.startsWith(u8, arg, "--")) {
                const flag_name_full = arg[2..];
                if (flag_name_full.len == 0) continue;
                if (std.mem.indexOfScalar(u8, flag_name_full, '=')) |_| continue;

                const flag_name = flag_name_full;
                const flag_def = self.findFlagDef(flag_name, cmd_flags) orelse continue;
                if (flag_def.flag_type == .bool) continue;
                if (flag_def.flag_type == .string and flag_def.value_optional) continue;

                if (i + 1 >= args.len) return flag_def.name;
                if (arg.len == 2 and i + 1 < args.len) continue;
                continue;
            }

            const short_group = arg[1..];
            if (short_group.len == 0) continue;
            for (short_group, 0..) |short_flag, j| {
                const flag_def = self.findFlagDefByShort(short_flag, cmd_flags) orelse return null;
                if (flag_def.flag_type == .bool) continue;

                if (j < short_group.len - 1) return flag_def.name;
                if (i + 1 >= args.len) return flag_def.name;
                if (flag_def.flag_type == .string and flag_def.value_optional and std.mem.startsWith(u8, args[i + 1], "-")) break;
                i += 1;
                break;
            }
        }
        return null;
    }

    fn findFlagDef(self: *CLI, name: []const u8, command_flags: []const types.Flag) ?*const types.Flag {
        for (command_flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) return flag;
        }
        for (self.global_flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) return flag;
        }
        return null;
    }

    fn findFlagDefByShort(self: *CLI, short: u8, command_flags: []const types.Flag) ?*const types.Flag {
        for (command_flags) |*flag| {
            if (flag.short != null and flag.short.? == short) return flag;
        }
        for (self.global_flags) |*flag| {
            if (flag.short != null and flag.short.? == short) return flag;
        }
        return null;
    }

    fn commandPhase(command_path: []const []const u8) ?mere.ui.Phase {
        if (command_path.len == 0) return null;
        return std.meta.stringToEnum(mere.ui.Phase, command_path[0]);
    }

    fn emitFormattedCliError(ctx: *mere.Context, phase: ?mere.ui.Phase, err: MereError, context: ?[]const u8) void {
        switch (err) {
            MereError.InvalidInput => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: invalid input: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: invalid input");
                }
            },
            MereError.MissingArgument => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: missing argument for {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: missing required argument");
                }
            },
            MereError.FileSystem => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: file system error: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: file system error");
                }
            },
            MereError.Network => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: network error: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: network error");
                }
            },
            MereError.PermissionDenied => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: permission denied: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: permission denied");
                }
            },
            MereError.CorruptData => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: data corruption: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: data corruption detected");
                }
            },
            MereError.SignatureInvalid => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: invalid signature: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: signature verification failed");
                }
            },
            MereError.OutOfMemory => {
                mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: out of memory");
            },
            MereError.OutOfDisk => {
                mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: insufficient disk space");
            },
            MereError.TooManyFiles => {
                mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: too many open files");
            },
            MereError.Internal => {
                if (context) |value| {
                    mere.ui.emit.logFmtSeverity(ctx, phase, .err, "error: internal error: {s}", .{value});
                } else {
                    mere.ui.emit.logLineSeverity(ctx, phase, .err, "error: internal error");
                }
            },
        }
    }
};
