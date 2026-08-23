const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const path = mere.path;

// Import profile-related modules
const profile_mod = mere.profile;
const generation_mod = mere.generation;

/// Profile command metadata
const profile_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 60,
    .name = "profile",
    .description = "Manage profiles",
};

fn profileCreationSegments(
    ctx: *mere.Context,
    profile_name: []const u8,
    base_name: ?[]const u8,
) !types.CommandResult {
    if (base_name) |base| {
        const segments = [_]mere.ui.Segment{
            .{ .text = "profile ", .kind = .normal },
            .{ .text = "created", .kind = .success },
            .{ .text = ": '", .kind = .normal },
            .{ .text = profile_name, .kind = .detail },
            .{ .text = "' from '", .kind = .normal },
            .{ .text = base, .kind = .detail },
            .{ .text = "' (cloned)", .kind = .normal },
        };
        return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
    }

    const segments = [_]mere.ui.Segment{
        .{ .text = "profile ", .kind = .normal },
        .{ .text = "created", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = profile_name, .kind = .detail },
        .{ .text = "' (empty)", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// List subcommand metadata
const list_meta = command.CommandMeta{
    .name = "list",
    .description = "List all profiles",
};

/// Packages subcommand metadata
const packages_meta = command.CommandMeta{
    .name = "packages",
    .description = "List packages in a profile's active state",
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Profile to inspect (default: system)",
            .flag_type = .string,
            .value_name = "name",
        },
    },
};

/// Create subcommand metadata
const create_meta = command.CommandMeta{
    .name = "create",
    .description = "Create a new profile",
    .args = &[_]types.Arg{
        .{
            .name = "name",
            .description = "Name of the profile to create",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "from",
            .description = "Clone from an existing profile's active realized state",
            .flag_type = .string,
        },
    },
};

/// Delete subcommand metadata
const delete_meta = command.CommandMeta{
    .name = "delete",
    .description = "Delete a profile",
    .args = &[_]types.Arg{
        .{
            .name = "name",
            .description = "Name of the profile to delete",
            .required = true,
        },
    },
};

/// Apply subcommand metadata
const apply_meta = command.CommandMeta{
    .name = "apply",
    .description = "Apply a profile.kdl to a profile",
    .args = &[_]types.Arg{
        .{
            .name = "file",
            .description = "Path to profile.kdl file",
            .required = true,
        },
    },
    .flags = &[_]types.Flag{
        .{
            .name = "profile",
            .short = 'p',
            .description = "Target profile name (default: system)",
            .flag_type = .string,
            .value_name = "name",
        },
    },
};

/// Main profile command handler
fn handleProfile(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = ctx;
    _ = args;
    return types.CommandResult{ .success = true };
}

/// List profiles handler
pub fn handleList(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    _ = args;

    const profiles_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profiles_dir);

    // Open profiles directory
    var dir = path.openExistingDir(profiles_dir) catch |err| {
        return switch (err) {
            error.FileNotFound => types.CommandResult{
                .success = true,
                .message = try ctx.allocator.dupe(u8, "No profiles found (profiles directory does not exist)"),
            },
            else => {
                ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(profiles_dir));
                return try command.errorResult(ctx, err, "failed to open profiles directory");
            },
        };
    };
    defer dir.close(path.currentIo());

    // Build output
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &output);
    const out = &out_buf.writer;
    out.writeAll("Profiles:\n") catch return MereError.OutOfMemory;

    var profile_count: usize = 0;

    // Iterate over profiles directory entries
    var iter = dir.iterate();
    while (iter.next(path.currentIo()) catch |err| {
        ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(profiles_dir));
        return try command.errorResult(ctx, err, "failed to enumerate profiles");
    }) |entry| {
        if (entry.kind != .directory) continue;

        const profile_name = entry.name;
        profile_count += 1;

        // Get profile directory path
        const profile_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, profile_name }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(profile_path);

        // Format output
        const is_system = std.mem.eql(u8, profile_name, "system");
        const kind_str = if (is_system) " [system]" else "";

        if (is_system) {
            const current_gen = generation_mod.getCurrentGeneration(profile_path) catch |err| {
                ctx.setDiagnosticContextFmt(profile_path, "failed to read current generation: {s}", .{@errorName(err)});
                return try command.errorResult(ctx, err, "failed to read current generation");
            };
            const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
                return MereError.OutOfMemory;
            };
            defer ctx.allocator.free(store_root);
            const generations = generation_mod.listGenerations(ctx.allocator, store_root, profile_path) catch |err| {
                ctx.setDiagnosticContextFmt(profile_path, "failed to list generations: {s}", .{@errorName(err)});
                return try command.errorResult(ctx, err, "failed to list generations");
            };
            defer ctx.allocator.free(generations);
            const gen_count = generations.len;

            if (current_gen) |gen| {
                out.print("  {s}{s}: gen-{d} ({d} generations)\n", .{ profile_name, kind_str, gen, gen_count }) catch return MereError.OutOfMemory;
            } else {
                out.print("  {s}{s}: (no current generation, {d} generations)\n", .{ profile_name, kind_str, gen_count }) catch return MereError.OutOfMemory;
            }
        } else {
            const root_path = profile_mod.getRootPath(ctx.allocator, profile_path) catch return MereError.OutOfMemory;
            defer ctx.allocator.free(root_path);

            const has_root = blk: {
                std.Io.Dir.accessAbsolute(path.currentIo(), root_path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(root_path));
                        return try command.errorResult(ctx, err, "failed to inspect profile root");
                    },
                };
                break :blk true;
            };
            if (has_root) {
                out.print("  {s}{s}: root\n", .{ profile_name, kind_str }) catch return MereError.OutOfMemory;
            } else {
                out.print("  {s}{s}: (empty)\n", .{ profile_name, kind_str }) catch return MereError.OutOfMemory;
            }
        }
    }

    if (profile_count == 0) {
        out.writeAll("  (no profiles found)\n") catch return MereError.OutOfMemory;
    }
    output = out_buf.toArrayList();

    return types.CommandResult{
        .success = true,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// List package names and versions from a profile's active realized state.
pub fn handlePackages(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    const profile_name = args.getString("profile") orelse "system";
    const profile_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles", profile_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_dir);

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root);

    var active_generation: ?u32 = null;
    const active_path = if (std.mem.eql(u8, profile_name, "system")) blk: {
        active_generation = generation_mod.getCurrentGeneration(profile_dir) catch |err| {
            ctx.setDiagnosticContextFmt(profile_dir, "failed to read current generation: {s}", .{@errorName(err)});
            return try command.errorResult(ctx, err, "failed to read current generation");
        };
        const generation = active_generation orelse {
            return types.CommandResult{
                .success = true,
                .message = try std.fmt.allocPrint(ctx.allocator, "Profile '{s}' has no active generation", .{profile_name}),
            };
        };
        break :blk generation_mod.getGenerationPath(ctx.allocator, profile_dir, generation) catch return MereError.OutOfMemory;
    } else blk: {
        const root_path = profile_mod.getRootPath(ctx.allocator, profile_dir) catch return MereError.OutOfMemory;
        std.Io.Dir.accessAbsolute(path.currentIo(), root_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                ctx.allocator.free(root_path);
                return types.CommandResult{
                    .success = true,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Profile '{s}' has no active realized state", .{profile_name}),
                };
            },
            else => {
                ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(root_path));
                const failure = try command.errorResult(ctx, err, "failed to inspect profile state");
                ctx.allocator.free(root_path);
                return failure;
            },
        };
        break :blk root_path;
    };
    defer ctx.allocator.free(active_path);

    var manifest = generation_mod.readManifest(ctx.allocator, store_root, active_path) catch |err| {
        ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(active_path));
        return try command.errorResult(ctx, err, "failed to read active profile manifest");
    };
    defer manifest.deinit();

    const packages = ctx.allocator.dupe(generation_mod.PackageEntry, manifest.packages.items) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(packages);
    std.mem.sort(generation_mod.PackageEntry, packages, {}, struct {
        fn lessThan(_: void, left: generation_mod.PackageEntry, right: generation_mod.PackageEntry) bool {
            const name_order = std.mem.order(u8, left.name, right.name);
            if (name_order != .eq) return name_order == .lt;
            const version_order = std.mem.order(u8, left.version, right.version);
            if (version_order != .eq) return version_order == .lt;
            return left.release < right.release;
        }
    }.lessThan);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &output);
    const out = &out_buf.writer;

    if (active_generation) |generation| {
        out.print("Packages in profile '{s}' (gen-{d}):\n", .{ profile_name, generation }) catch return MereError.OutOfMemory;
    } else {
        out.print("Packages in profile '{s}':\n", .{profile_name}) catch return MereError.OutOfMemory;
    }

    if (packages.len == 0) {
        out.writeAll("  (none)\n") catch return MereError.OutOfMemory;
    } else {
        for (packages) |pkg| {
            out.print("  {s} {s}-{d}\n", .{ pkg.name, pkg.version, pkg.release }) catch return MereError.OutOfMemory;
        }
    }
    output = out_buf.toArrayList();

    return types.CommandResult{
        .success = true,
        .message = try ctx.allocator.dupe(u8, output.items),
    };
}

/// Create profile handler
pub fn handleCreate(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const profile_name = args.positional[0];

    // Validate profile name
    if (std.mem.eql(u8, profile_name, "system")) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(u8, "Cannot create profile named 'system' - it is reserved"),
        };
    }

    // Check for invalid characters
    for (profile_name) |c| {
        if (c == '/' or c == '\x00') {
            return types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try ctx.allocator.dupe(u8, "Invalid profile name: contains invalid characters"),
            };
        }
    }

    if (profile_name.len == 0 or profile_name.len > 64) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(u8, "Invalid profile name: must be 1-64 characters"),
        };
    }

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const profiles_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profiles_dir);

    const profile_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, profile_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_path);

    // Check if profile already exists
    if (path.openExistingDir(profile_path)) |d| {
        @constCast(&d).close(path.currentIo());
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try std.fmt.allocPrint(ctx.allocator, "Profile '{s}' already exists", .{profile_name}),
        };
    } else |_| {
        // Profile doesn't exist, continue
    }

    const from_profile = args.getString("from");

    if (from_profile) |base_name| {
        // Clone from existing profile
        const base_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, base_name }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(base_path);

        // Check base profile exists
        var base_dir = path.openExistingDir(base_path) catch |err| {
            return switch (err) {
                error.FileNotFound => types.CommandResult{
                    .success = false,
                    .exit_code = 2,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Base profile '{s}' does not exist", .{base_name}),
                },
                else => {
                    ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(base_path));
                    return try command.errorResult(ctx, err, "failed to open base profile");
                },
            };
        };
        base_dir.close(path.currentIo());

        const base_realization_path = if (std.mem.eql(u8, base_name, "system")) blk: {
            const current_gen = generation_mod.getCurrentGeneration(base_path) catch |err| {
                ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(base_path));
                return try command.errorResult(ctx, err, "failed to read base profile generation");
            } orelse {
                return types.CommandResult{
                    .success = false,
                    .exit_code = 2,
                    .message = try std.fmt.allocPrint(ctx.allocator, "Base profile '{s}' has no current generation", .{base_name}),
                };
            };

            break :blk generation_mod.getGenerationPath(ctx.allocator, base_path, current_gen) catch return MereError.OutOfMemory;
        } else blk: {
            const root_path = profile_mod.getRootPath(ctx.allocator, base_path) catch return MereError.OutOfMemory;
            std.Io.Dir.accessAbsolute(path.currentIo(), root_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    ctx.allocator.free(root_path);
                    return types.CommandResult{
                        .success = false,
                        .exit_code = 2,
                        .message = try std.fmt.allocPrint(ctx.allocator, "Base profile '{s}' has no realized state", .{base_name}),
                    };
                }
                ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(root_path));
                const failure = try command.errorResult(ctx, err, "failed to inspect base profile state");
                ctx.allocator.free(root_path);
                return failure;
            };
            break :blk root_path;
        };
        defer ctx.allocator.free(base_realization_path);

        const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
            return MereError.OutOfMemory;
        };
        defer ctx.allocator.free(store_root);

        var manifest = generation_mod.readManifest(ctx.allocator, store_root, base_realization_path) catch |err| {
            ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(base_realization_path));
            return try command.errorResult(ctx, err, "failed to read base profile manifest");
        };
        defer manifest.deinit();

        // Create new profile directory
        path.ensureDirExists(profile_path) catch |err| {
            ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(profile_path));
            return try command.errorResult(ctx, err, "failed to create profile directory");
        };

        // Build package entries for the new generation
        var packages: std.ArrayList(generation_mod.PackageEntry) = .empty;
        defer packages.deinit(ctx.allocator);

        for (manifest.packages.items) |pkg| {
            packages.append(ctx.allocator, .{
                .name = pkg.name,
                .version = pkg.version,
                .release = pkg.release,
                .arch = pkg.arch,
                .store_path = pkg.store_path,
                .content_hash = pkg.content_hash,
            }) catch {
                return MereError.OutOfMemory;
            };
        }

        _ = profile_mod.publishProfileRoot(
            ctx,
            profile_path,
            store_root,
            packages.items,
        ) catch |err| {
            return try command.errorResult(ctx, err, "failed to publish profile root");
        };

        return try profileCreationSegments(ctx, profile_name, base_name);
    } else {
        // Create empty profile
        path.ensureDirExists(profile_path) catch |err| {
            ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(profile_path));
            return try command.errorResult(ctx, err, "failed to create profile directory");
        };

        return try profileCreationSegments(ctx, profile_name, null);
    }
}

/// Delete profile handler
pub fn handleDelete(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const profile_name = args.positional[0];

    // Cannot delete system profile
    if (std.mem.eql(u8, profile_name, "system")) {
        return types.CommandResult{
            .success = false,
            .exit_code = 2,
            .message = try ctx.allocator.dupe(u8, "Cannot delete the system profile"),
        };
    }

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const profiles_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profiles_dir);

    const profile_path = std.fs.path.join(ctx.allocator, &.{ profiles_dir, profile_name }) catch {
        return MereError.OutOfMemory;
    };
    defer ctx.allocator.free(profile_path);

    // Check profile exists
    var dir = path.openExistingDir(profile_path) catch |err| {
        return switch (err) {
            error.FileNotFound => types.CommandResult{
                .success = false,
                .exit_code = 2,
                .message = try std.fmt.allocPrint(ctx.allocator, "Profile '{s}' does not exist", .{profile_name}),
            },
            else => {
                ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(profile_path));
                return try command.errorResult(ctx, err, "failed to open profile");
            },
        };
    };
    dir.close(path.currentIo());

    // Delete profile directory recursively
    path.deleteTreeAbsolute(profile_path) catch |err| {
        ctx.withDiagnosticContext(mere.errors.DiagnosticContext.init().withSubject(profile_path));
        return try command.errorResult(ctx, err, "failed to delete profile directory");
    };

    const delete_segments = [_]mere.ui.Segment{
        .{ .text = "profile ", .kind = .normal },
        .{ .text = "deleted", .kind = .success },
        .{ .text = ": '", .kind = .normal },
        .{ .text = profile_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &delete_segments);
}

/// Apply handler - reads a profile.kdl and installs its packages to a profile
pub fn handleApply(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const file_path = args.positional[0];
    const profile_name = args.getString("profile") orelse "system";

    if (try command.acquireStoreLockOrResult(ctx)) |result| return result;
    defer ctx.releaseStoreLock();

    const result = performApply(ctx, file_path, profile_name) catch |err| {
        return try command.errorResult(ctx, err, null);
    };

    return result;
}

fn performApply(ctx: *mere.Context, file_path: []const u8, profile_name: []const u8) !types.CommandResult {
    const specs = generation_mod.readProfilePackageSpecs(ctx.allocator, file_path) catch {
        return error.InvalidInput;
    };
    defer {
        for (specs) |*s| @constCast(s).deinit(ctx.allocator);
        ctx.allocator.free(specs);
    }
    if (specs.len == 0) return error.InvalidInput;

    _ = try ctx.getConfig();
    var curl_client = try mere.download.CurlTransferClient.init(ctx, command.user_agent);
    defer mere.download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    _ = try mere.install.installPackageSpecsFromConfig(ctx, specs, client, false, false, false, profile_name);

    const segments = [_]mere.ui.Segment{
        .{ .text = "profile ", .kind = .normal },
        .{ .text = "applied", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = file_path, .kind = .detail },
        .{ .text = " → '", .kind = .normal },
        .{ .text = profile_name, .kind = .detail },
        .{ .text = "'", .kind = .normal },
    };
    return types.CommandResult.createSuccessSegments(ctx.allocator, &segments);
}

/// Create the profile command with its subcommands
pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const profile_cmd = try allocator.create(command.Command);
    profile_cmd.* = command.Command.init(allocator, profile_meta, handleProfile);

    const list_cmd = try allocator.create(command.Command);
    list_cmd.* = command.Command.init(allocator, list_meta, handleList);

    const packages_cmd = try allocator.create(command.Command);
    packages_cmd.* = command.Command.init(allocator, packages_meta, handlePackages);

    const create_cmd = try allocator.create(command.Command);
    create_cmd.* = command.Command.init(allocator, create_meta, handleCreate);

    const delete_cmd = try allocator.create(command.Command);
    delete_cmd.* = command.Command.init(allocator, delete_meta, handleDelete);

    const apply_cmd = try allocator.create(command.Command);
    apply_cmd.* = command.Command.init(allocator, apply_meta, handleApply);

    try profile_cmd.addSubcommand(list_cmd);
    try profile_cmd.addSubcommand(packages_cmd);
    try profile_cmd.addSubcommand(create_cmd);
    try profile_cmd.addSubcommand(delete_cmd);
    try profile_cmd.addSubcommand(apply_cmd);

    return profile_cmd;
}
