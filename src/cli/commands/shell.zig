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
    .name = "shell",
    .description = "Enter an interactive shell or run a command with a selected profile",
    .args = &[_]types.Arg{},
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile name (required unless MERE_SHELL_PROFILE is set)",
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
    if (args.positional.len > 0 and args.passthrough.len == 0) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(
                u8,
                "unexpected positional arguments; use `mere shell -- <command> [args...]` to run a command",
            ),
        };
    }

    // Profile resolution order:
    // 1. --profile/-p
    // 2. MERE_SHELL_PROFILE environment variable
    // 3. No implicit fallback
    const profile_name = resolveProfileName(ctx, args) catch |err| {
        if (err == error.OutOfMemory) return MereError.OutOfMemory;
        if (err == error.NoProfileSelected) {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try ctx.allocator.dupe(
                    u8,
                    "No profile selected. Use `mere shell --profile <name>` (or `-p <name>`) or set MERE_SHELL_PROFILE.",
                ),
            };
        }
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, "Failed to resolve profile name"),
        };
    };
    defer ctx.allocator.free(profile_name);

    const profile_root = resolveProfileRoot(ctx.allocator, ctx.root_path, profile_name) catch |err| {
        // Set diagnostic context for profile resolution failure
        const diag_ctx = mere.errors.DiagnosticContext.init()
            .withSubject(profile_name)
            .withDetails("failed to resolve profile path");
        ctx.withDiagnosticContext(diag_ctx);

        const user_message = mere.errors.getUserFriendlyMessage(err);
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted = error_ctx.formatWithMessage(ctx.allocator, user_message) catch user_message;

        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = if (formatted.ptr != user_message.ptr) formatted else try ctx.allocator.dupe(u8, formatted),
        };
    };
    defer ctx.allocator.free(profile_root);

    const invocation_cwd = std.process.currentPathAlloc(path.currentIo(), ctx.allocator) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, "Failed to resolve current working directory"),
        };
    };
    defer ctx.allocator.free(invocation_cwd);

    const shell_env = namespace.cloneHostEnvWithVar(ctx.allocator, "MERE_SHELL_PROFILE", profile_name) catch {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try ctx.allocator.dupe(u8, "Failed to prepare shell environment"),
        };
    };
    defer namespace.freeOwnedEnv(ctx.allocator, shell_env);

    // Set diagnostic context - the subject is the profile being entered
    const diag_ctx = mere.errors.DiagnosticContext.init()
        .withSubject(profile_root);
    ctx.withDiagnosticContext(diag_ctx);

    std.Io.Dir.accessAbsolute(path.currentIo(), profile_root, .{}) catch {
        const error_ctx = ctx.getDiagnosticContext().toErrorContext();
        const formatted = error_ctx.formatWithMessage(ctx.allocator, "profile not found") catch
            try ctx.allocator.dupe(u8, "profile not found");

        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = formatted,
        };
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
        const updated_diag_ctx = diag_ctx.withDetails(details);
        ctx.withDiagnosticContext(updated_diag_ctx);

        // Get user-friendly error message
        const user_message = mere.errors.getUserFriendlyMessage(err);

        // Format: "{error_message}: \"{subject}\" - {details}"
        const error_ctx = updated_diag_ctx.toErrorContext();
        const formatted = error_ctx.formatWithMessage(ctx.allocator, user_message) catch
            try ctx.allocator.dupe(u8, user_message);

        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = formatted,
        };
    };

    unreachable;
}

// Resolve profile name according to spec §15.9 precedence
fn resolveProfileName(ctx: *mere.Context, args: *const types.ParsedArgs) ![]const u8 {
    const env_profile = if (std.c.getenv("MERE_SHELL_PROFILE")) |value| std.mem.span(value) else null;
    const profile_name = resolveProfileNameFromSources(args.getString("profile"), env_profile) orelse {
        return error.NoProfileSelected;
    };

    if (args.getString("profile") == null) {
        const segments = [_]mere.ui.Segment{
            .{ .text = "using profile from ", .kind = .normal },
            .{ .text = "MERE_SHELL_PROFILE", .kind = .label },
            .{ .text = ": ", .kind = .normal },
            .{ .text = profile_name, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, .shell, .info, &segments);
    }

    return try ctx.allocator.dupe(u8, profile_name);
}

fn resolveProfileNameFromSources(profile_flag: ?[]const u8, env_profile: ?[]const u8) ?[]const u8 {
    // 1. --profile/-p flag
    if (profile_flag) |value| {
        return value;
    }

    // 2. Environment variable
    if (env_profile) |value| {
        return value;
    }

    return null;
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
