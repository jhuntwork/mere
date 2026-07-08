const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const namespace = mere.namespace;
const emit = mere.ui.emit;
const profile = mere.profile;
const path = mere.path;

const shell_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 50,
    .name = "shell",
    .description = "Enter an interactive shell or run a command with a selected profile",
    .args = &[_]types.Arg{},
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile name to enter",
            .flag_type = .string,
            .value_name = "name",
        },
        .{
            .name = "no-etc-overlay",
            .description = "Bind mount /etc read-only instead of using overlayfs",
            .flag_type = .bool,
        },
    },
};

fn handleShell(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const no_etc_overlay = args.getBool("no-etc-overlay");
    if (args.positional.len > 1) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(
                u8,
                "unexpected positional arguments; use `mere shell [profile.kdl] -- <command> [args...]`",
            ),
        };
    }

    // Profile resolution order:
    // 1. --profile/-p flag (existing named profile)
    // 2. positional arg (path to profile.kdl file)
    // 3. profile.kdl in current directory
    const profile_name = resolveProfileName(ctx, args) catch |err| {
        if (err == error.OutOfMemory) return MereError.OutOfMemory;
        if (err == error.NoProfileSelected) {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try ctx.allocator.dupe(
                    u8,
                    "No profile selected. Use `mere shell --profile <name>` or place a profile.kdl in the current directory.",
                ),
            };
        }
        return try command.errorResult(ctx, err, "Failed to resolve profile");
    };
    defer ctx.allocator.free(profile_name);

    const profile_root = resolveProfileRoot(ctx.allocator, ctx.root_path, profile_name) catch |err| {
        const diag_ctx = mere.errors.DiagnosticContext.init()
            .withSubject(profile_name)
            .withDetails("failed to resolve profile path");
        ctx.withDiagnosticContext(diag_ctx);

        return try command.errorResult(ctx, err, null);
    };
    defer ctx.allocator.free(profile_root);

    const invocation_cwd = std.process.currentPathAlloc(path.currentIo(), ctx.allocator) catch |err| {
        return try command.errorResult(ctx, err, "Failed to resolve current working directory");
    };
    defer ctx.allocator.free(invocation_cwd);

    const shell_env = namespace.cloneHostEnvWithVar(ctx.allocator, "MERE_PROFILE", profile_name) catch |err| {
        return try command.errorResult(ctx, err, "Failed to prepare shell environment");
    };
    defer namespace.freeOwnedEnv(ctx.allocator, shell_env);

    // Set diagnostic context - the subject is the profile being entered
    const diag_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(profile_root);
    ctx.withDiagnosticContext(diag_ctx);

    std.Io.Dir.accessAbsolute(path.currentIo(), profile_root, .{}) catch |err| {
        return try command.errorResult(ctx, err, "profile not found");
    };

    const opts = namespace.EnvOptions{
        .profile_root = profile_root,
        .command = if (args.passthrough.len > 0) args.passthrough else null,
        .cwd = invocation_cwd,
        .workspace = null,
        .no_etc_overlay = no_etc_overlay,
        .env = shell_env,
    };

    // Error boundary: catch all errors and map them to user-friendly messages at CLI boundary
    namespace.enterEnv(ctx.allocator, .shell, opts) catch |err| {
        var owned_details: ?[]u8 = null;
        defer if (owned_details) |details| ctx.allocator.free(details);

        // Get specific error details for namespace errors
        const details: []const u8 = switch (err) {
            namespace.EnvError.UserNamespacesDisabled => "enable with: sysctl -w kernel.unprivileged_userns_clone=1",
            namespace.EnvError.OverlayFsUnavailable => "try --no-etc-overlay flag",
            namespace.EnvError.SessionSetupError => "failed to create namespace session directories under XDG_RUNTIME_DIR or /tmp",
            namespace.EnvError.SyntheticRootSetupError => "failed to build synthetic root for the selected profile",
            namespace.EnvError.DeviceSetupError => "failed to set up /dev inside the namespace",
            namespace.EnvError.EtcSetupError => "failed to generate the namespace /etc overlay",
            namespace.EnvError.WorkingDirectoryUnavailable => blk: {
                owned_details = std.fmt.allocPrint(
                    ctx.allocator,
                    "requested working directory is not available inside the namespace: {s}",
                    .{invocation_cwd},
                ) catch null;
                break :blk owned_details orelse "requested working directory is not available inside the namespace";
            },
            namespace.EnvError.MountRestricted => "bind mounts are restricted in this environment; sandbox or kernel policy is blocking mount(2)",
            namespace.EnvError.MountSourceMissing => "bind mount source path is missing",
            namespace.EnvError.MountBindError => "bind mount syscall failed after validating the source path",
            namespace.EnvError.MountTmpfsError => "tmpfs mount failed",
            namespace.EnvError.MountOverlayError => "overlay mount failed - try --no-etc-overlay flag",
            namespace.EnvError.MountProcError => "proc mount failed",
            namespace.EnvError.MountPrivateError => "failed to make mounts private",
            namespace.EnvError.UnshareError => "unshare failed",
            namespace.EnvError.ChrootError => "chroot failed",
            namespace.EnvError.ExecError => "shell not found or not executable - check /bin/sh exists in profile",
            namespace.EnvError.UidMapError => "failed to write uid_map",
            namespace.EnvError.GidMapError => "failed to write gid_map",
            namespace.EnvError.FileSystem => "filesystem error",
            else => @errorName(err),
        };

        // Update diagnostic context with error details
        ctx.withDiagnosticContext(diag_ctx.withDetails(details));

        return try command.errorResult(ctx, err, null);
    };

    unreachable;
}

// Resolve profile name according to spec §15.12 precedence
fn resolveProfileName(ctx: *mere.Context, args: *const types.ParsedArgs) ![]const u8 {
    // 1. --profile/-p flag
    if (args.getString("profile")) |value| {
        return try ctx.allocator.dupe(u8, value);
    }

    // 2. Positional arg (path to profile.kdl) - independent of whether a
    // passthrough command follows the `--`.
    if (args.positional.len > 0) {
        return try buildProfileFromFile(ctx, args.positional[0]);
    }

    // 3. profile.kdl in current directory
    return buildProfileFromFile(ctx, "profile.kdl");
}

fn buildProfileFromFile(ctx: *mere.Context, file_path: []const u8) ![]const u8 {
    const io = path.currentIo();

    // Read file once — used for both parsing and hashing
    var file = path.openExistingFile(file_path) catch return error.NoProfileSelected;
    defer file.close(io);
    const stat = file.stat(io) catch return error.NoProfileSelected;
    const content = ctx.allocator.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    defer ctx.allocator.free(content);
    _ = file.readPositionalAll(io, content, 0) catch return error.NoProfileSelected;

    const specs = mere.generation.parseProfilePackageSpecs(ctx.allocator, content) catch return error.NoProfileSelected;
    defer {
        for (specs) |*s| @constCast(s).deinit(ctx.allocator);
        ctx.allocator.free(specs);
    }
    if (specs.len == 0) return error.NoProfileSelected;

    // Derive a deterministic profile name from file content hash
    const full_hash = mere.hash.calculateBytesHash(ctx.allocator, content) catch return error.OutOfMemory;
    defer ctx.allocator.free(full_hash);
    const profile_name = try std.fmt.allocPrint(ctx.allocator, "shell-{s}", .{full_hash[0..12]});
    errdefer ctx.allocator.free(profile_name);

    // Skip build if this profile is already realized
    const profiles_base = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" });
    defer ctx.allocator.free(profiles_base);
    const root_path = try std.fs.path.join(ctx.allocator, &.{ profiles_base, profile_name, "root" });
    defer ctx.allocator.free(root_path);

    std.Io.Dir.accessAbsolute(io, root_path, .{}) catch {
        const segments = [_]mere.ui.Segment{
            .{ .text = "building shell profile from ", .kind = .normal },
            .{ .text = file_path, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, .shell, .info, &segments);

        _ = try ctx.getConfig();
        var curl_client = try mere.download.CurlTransferClient.init(ctx, command.user_agent);
        defer mere.download.CurlTransferClient.cleanupFn(ctx, curl_client);
        const client = curl_client.client();
        _ = try mere.install.installPackageSpecsFromConfig(ctx, specs, client, false, false, false, profile_name);
    };

    return profile_name;
}

fn resolveProfileRoot(allocator: std.mem.Allocator, root_path: []const u8, profile_name: []const u8) ![]const u8 {
    const profiles_base = try std.fs.path.join(allocator, &.{ root_path, "mere", "profiles" });
    defer allocator.free(profiles_base);

    const profile_dir = try std.fs.path.join(allocator, &.{ profiles_base, profile_name });
    defer allocator.free(profile_dir);

    if (std.mem.eql(u8, profile_name, "system")) {
        return try std.fs.path.join(allocator, &.{ profile_dir, "current" });
    }

    return try profile.getRootPath(allocator, profile_dir);
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, shell_meta, handleShell);
    return cmd;
}
