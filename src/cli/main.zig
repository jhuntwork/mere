const std = @import("std");
const mere = @import("mere");
const cli = @import("cli.zig");
const types = @import("types.zig");
const command = @import("command.zig");
const MereError = mere.errors.MereError;

// Import command implementations
const install = @import("commands/install.zig");
const uninstall = @import("commands/uninstall.zig");
const dev = @import("commands/dev.zig");
const release_cmd = @import("commands/release.zig");
const etc_cmd = @import("commands/etc.zig");
const shell_cmd = @import("commands/shell.zig");
const profile_cmd = @import("commands/profile.zig");
const search_cmd = @import("commands/search.zig");
const store_cmd = @import("commands/store.zig");
const service_cmd = @import("commands/service.zig");
const describe = @import("describe.zig");

/// Global flags available to all commands
const global_flags = [_]types.Flag{
    .{
        .name = "verbose",
        .short = 'v',
        .description = "Enable verbose output",
        .flag_type = .bool,
    },
    .{
        .name = "no-color",
        .short = null,
        .description = "Disable color output",
        .flag_type = .bool,
    },
    .{
        .name = "version",
        .short = null,
        .description = "Show version information",
        .flag_type = .bool,
    },
    .{
        .name = "root",
        .short = 'r',
        .description = "Install prefix (default: /, env: MERE_ROOT). Store and profiles are created at <prefix>/mere/",
        .flag_type = .string,
        .value_name = "PATH",
    },
};

/// Root command handler - shows help when no subcommand is given
fn handleRoot(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    // The CLI system will handle showing help for the root command
    return types.CommandResult{ .success = true };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    mere.path.setRuntimeIo(init.io);

    // Initialize CLI system
    var cli_system = cli.CLI.init(allocator, "mere", &global_flags);
    defer cli_system.deinit();

    // Determine root path: --root flag > MERE_ROOT env > default (/)
    // We initialize with null (default) here; the flag override happens after prescan.
    const env_root = init.environ_map.get("MERE_ROOT");
    var ctx = mere.Context.init(allocator, env_root);
    defer ctx.deinit();

    // Set home directory from environment
    ctx.home_dir = init.environ_map.get("HOME");

    // Get command-line arguments early so global presentation flags can affect emitter setup.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    const stdout_tty = stdout_file.isTty(init.io) catch false;
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);
    var stderr_writer = stderr_file.writer(init.io, &stderr_buf);
    const no_color = init.environ_map.contains("NO_COLOR");
    var global_options = cli.CLI.prescanGlobalFlags(allocator, args[1..], &global_flags) catch cli.CLI.PrescanResult{
        .verbose = false,
        .no_color = false,
        .root = null,
        .filtered_args = &[_][]const u8{},
        .allocator = allocator,
    };
    defer if (global_options.filtered_args.len > 0) global_options.deinit(allocator);

    // Apply --root flag override (takes precedence over MERE_ROOT env)
    if (global_options.root) |root_path| {
        ctx.setRoot(root_path) catch {
            std.process.exit(1);
        };
    }

    const config_color = mere.config.loadSystemColorSetting(&ctx) catch null;
    var ui_emitter = mere.ui.ProgressEmitter.init(allocator, &stdout_writer, &stderr_writer, .{
        .tty = stdout_tty,
        .use_color = stdout_tty and (config_color orelse true) and !no_color and !global_options.no_color,
    });
    defer ui_emitter.deinit();
    ctx.setEmitter(&ui_emitter.emitter);

    // Create the root command
    const root_meta = command.CommandMeta{
        .name = "mere",
        .description = "Mere package management tool",
    };
    var root_command = command.Command.init(allocator, root_meta, handleRoot);
    defer root_command.deinit();

    // Create and register all commands
    try registerCommands(allocator, &cli_system, &root_command);

    // Set the root command
    cli_system.setRootCommand(&root_command);

    // describe walks the finished tree, so it can only be handed the surface
    // once every command is registered.
    describe.setSurface("mere", &global_flags, &root_command);

    // Execute the CLI
    const exit_code = cli_system.execute(args, &ctx);
    _ = stdout_writer.interface.flush() catch {};
    _ = stderr_writer.interface.flush() catch {};
    std.process.exit(exit_code);
}

/// Register all commands with the CLI system
fn registerCommands(allocator: std.mem.Allocator, cli_system: *cli.CLI, root_command: *command.Command) !void {
    // Create install command
    const install_command = try install.createCommand(allocator);
    try cli_system.registerCommand(install_command);
    try root_command.addSubcommand(install_command);

    // Create uninstall command
    const uninstall_command = try uninstall.createCommand(allocator);
    try cli_system.registerCommand(uninstall_command);
    try root_command.addSubcommand(uninstall_command);

    // Create dev command with subcommands
    const dev_command = try dev.createCommand(allocator);
    try cli_system.registerCommand(dev_command);
    try root_command.addSubcommand(dev_command);

    // Create release command with subcommands
    const release_command = try release_cmd.createCommand(allocator);
    try cli_system.registerCommand(release_command);
    try root_command.addSubcommand(release_command);

    // Create store command (clean, verify, pin, generation)
    const store_command = try store_cmd.createCommand(allocator);
    try cli_system.registerCommand(store_command);
    try root_command.addSubcommand(store_command);

    // Create etc command with subcommands
    const etc_command = try etc_cmd.createCommand(allocator);
    try cli_system.registerCommand(etc_command);
    try root_command.addSubcommand(etc_command);

    // Create shell command
    const shell_command = try shell_cmd.createCommand(allocator);
    try cli_system.registerCommand(shell_command);
    try root_command.addSubcommand(shell_command);

    // Create profile command
    const profile_command = try profile_cmd.createCommand(allocator);
    try cli_system.registerCommand(profile_command);
    try root_command.addSubcommand(profile_command);

    // Create search command
    const search_command = try search_cmd.createCommand(allocator);
    try cli_system.registerCommand(search_command);
    try root_command.addSubcommand(search_command);

    // Create service management commands (top-level verbs)
    const service_commands = try service_cmd.createCommands(allocator);
    for (service_commands) |svc_command| {
        try cli_system.registerCommand(svc_command);
        try root_command.addSubcommand(svc_command);
    }

    const describe_command = try describe.createCommand(allocator);
    try cli_system.registerCommand(describe_command);
    try root_command.addSubcommand(describe_command);
}
