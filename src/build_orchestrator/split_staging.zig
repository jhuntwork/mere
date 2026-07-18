const std = @import("std");
const mere = @import("../mere.zig");
const path_mod = @import("../path.zig");
const recipe = @import("../recipe.zig");
const package_staging = @import("../package_staging.zig");

const ui = mere.ui;
const emit = mere.ui.emit;

pub const SplitStagingError = error{
    OutOfMemory,
    FileSystem,
    PermissionDenied,
    InvalidInput,
    SplitStagingFailed,
};

pub const StagedPackage = struct {
    pkg_index: usize,
    staging_dir: []u8,
    copied_files: [][]const u8,

    pub fn deinit(self: *const StagedPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.staging_dir);
        for (self.copied_files) |file_path| {
            allocator.free(file_path);
        }
        allocator.free(self.copied_files);
    }
};

pub const StagePackageFilesFn = *const fn (*mere.Context, package_staging.PackageStagingConfig) anyerror!package_staging.PackageStagingResult;

pub fn clearStagedPackages(allocator: std.mem.Allocator, staged_packages: *std.ArrayList(StagedPackage)) void {
    if (staged_packages.items.len == 0) return;

    var i: usize = 0;
    while (i < staged_packages.items.len) : (i += 1) {
        staged_packages.items[i].deinit(allocator);
    }
    staged_packages.clearRetainingCapacity();
}

pub fn stageSplitPackages(
    allocator: std.mem.Allocator,
    ctx_opt: ?*mere.Context,
    stop_on_error: bool,
    stage_package_files_fn: StagePackageFilesFn,
    recipe_name: []const u8,
    packages: []const recipe.BuildArtifact,
    workspace_recipe_root: []const u8,
    workspace_destdir: []const u8,
    staged_packages: *std.ArrayList(StagedPackage),
    split_staging_errors_encountered: *bool,
) SplitStagingError!void {
    if (packages.len == 0) {
        split_staging_errors_encountered.* = false;
        clearStagedPackages(allocator, staged_packages);
        return;
    }

    const ctx = ctx_opt orelse return error.InvalidInput;
    ctx.setDiagnosticContext(recipe_name, null);

    clearStagedPackages(allocator, staged_packages);
    split_staging_errors_encountered.* = false;
    try resetPackageStagingDirs(allocator, ctx, packages, workspace_recipe_root);
    var total_files_copied: usize = 0;

    var pi: usize = 0;
    while (pi < packages.len) : (pi += 1) {
        const artifact = &packages[pi];
        const pkg_name = if (artifact.name.len > 0) artifact.name else "pkg";
        const maybe_staged = try stageOnePackage(
            allocator,
            ctx,
            stop_on_error,
            stage_package_files_fn,
            workspace_recipe_root,
            workspace_destdir,
            pi,
            pkg_name,
            artifact.pkgfiles.items[0..artifact.pkgfiles.items.len],
            split_staging_errors_encountered,
        );
        const staged = maybe_staged orelse continue;
        total_files_copied += staged.copied_files.len;

        staged_packages.append(allocator, staged) catch {
            var staged_to_free = staged;
            staged_to_free.deinit(allocator);
            return ctx.fail(error.OutOfMemory, pkg_name, "failed to record staged package");
        };
    }

    const summary_details = std.fmt.allocPrint(allocator, "{d} packages ({d} files)", .{ staged_packages.items.len, total_files_copied }) catch {
        return ctx.fail(error.OutOfMemory, recipe_name, "failed to format split staging summary");
    };
    defer allocator.free(summary_details);
    const summary_segments = [_]ui.Segment{
        .{ .text = "packages", .kind = .normal },
        .{ .text = " staged", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = summary_details, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, .info, &summary_segments);
}

pub fn resetPackageStagingDirs(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    packages: []const recipe.BuildArtifact,
    workspace_recipe_root: []const u8,
) SplitStagingError!void {
    if (packages.len == 0) return;

    const pkg_root = std.fs.path.join(allocator, &.{ workspace_recipe_root, "pkg" }) catch {
        return ctx.fail(error.OutOfMemory, workspace_recipe_root, "failed to allocate package root");
    };
    defer allocator.free(pkg_root);

    if (std.fs.path.dirname(pkg_root)) |parent_dir_path| {
        var parent_dir = path_mod.makePathAndOpenDir(parent_dir_path) catch {
            return ctx.fail(error.FileSystem, parent_dir_path, "failed to open package workspace parent");
        };
        defer parent_dir.close(path_mod.currentIo());
        if (std.Io.Dir.accessAbsolute(path_mod.currentIo(), pkg_root, .{})) |_| {
            parent_dir.deleteTree(path_mod.currentIo(), std.fs.path.basename(pkg_root)) catch {
                return ctx.fail(error.FileSystem, pkg_root, "failed to reset package workspace");
            };
        } else |err| {
            if (err != error.FileNotFound) {
                return ctx.fail(error.FileSystem, pkg_root, "failed to inspect package workspace");
            }
        }
    }
    var pkg_root_handle = path_mod.makePathAndOpenDir(pkg_root) catch {
        return ctx.fail(error.FileSystem, pkg_root, "failed to create package workspace");
    };
    pkg_root_handle.close(path_mod.currentIo());

    for (packages) |artifact| {
        const pkg_name = if (artifact.name.len > 0) artifact.name else "pkg";
        const staging_dir = std.fs.path.join(allocator, &.{ pkg_root, pkg_name }) catch {
            return ctx.fail(error.OutOfMemory, pkg_name, "failed to allocate staging directory");
        };
        defer allocator.free(staging_dir);

        var staging_dir_handle = path_mod.makePathAndOpenDir(staging_dir) catch {
            return ctx.fail(error.FileSystem, staging_dir, "failed to create staging directory");
        };
        staging_dir_handle.close(path_mod.currentIo());
    }
}

fn stageOnePackage(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    stop_on_error: bool,
    stage_package_files_fn: StagePackageFilesFn,
    workspace_recipe_root: []const u8,
    workspace_destdir: []const u8,
    pkg_index: usize,
    pkg_name: []const u8,
    patterns: []const []const u8,
    split_staging_errors_encountered: *bool,
) SplitStagingError!?StagedPackage {
    const staging_dir = std.fs.path.join(allocator, &.{ workspace_recipe_root, "pkg", pkg_name }) catch {
        return ctx.fail(error.OutOfMemory, pkg_name, "failed to allocate staging directory");
    };
    errdefer allocator.free(staging_dir);

    const cfg = package_staging.PackageStagingConfig{
        .source_dir = workspace_destdir,
        .patterns = patterns,
        .destination = staging_dir,
    };

    var result = stage_package_files_fn(ctx, cfg) catch |err| {
        split_staging_errors_encountered.* = true;
        const diag = ctx.getDiagnosticContext();
        if (diag.details == null) {
            ctx.setDiagnosticContextFmt(pkg_name, "split staging failed: {s}", .{@errorName(err)});
        }
        if (stop_on_error) {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.AccessDenied => error.PermissionDenied,
                else => error.SplitStagingFailed,
            };
        }
        allocator.free(staging_dir);
        return null;
    };

    const copied_files = result.copied_files;
    result.files_copied = 0;
    result.copied_files = &[_][]const u8{};

    return StagedPackage{
        .pkg_index = pkg_index,
        .staging_dir = staging_dir,
        .copied_files = copied_files,
    };
}

test "resetPackageStagingDirs removes stale package workspace contents before staging starts" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "pack-reset"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64" "aarch64"
        \\}
        \\build { script "true" }
        \\package "pack-reset" { files "usr/bin/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const workspace_root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "workspace-pack-reset" });
    defer test_env.ctx.allocator.free(workspace_root);
    var workspace_root_handle = try path_mod.makePathAndOpenDir(workspace_root);
    workspace_root_handle.close(path_mod.currentIo());

    const stale_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_root, "pkg", "pack-reset", "usr", "bin" });
    defer test_env.ctx.allocator.free(stale_dir);
    var stale_dir_handle = try path_mod.makePathAndOpenDir(stale_dir);
    stale_dir_handle.close(path_mod.currentIo());

    const stale_path = try std.fs.path.join(test_env.ctx.allocator, &.{ stale_dir, "old-tool" });
    defer test_env.ctx.allocator.free(stale_path);
    var stale_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), stale_path, .{});
    defer stale_file.close(path_mod.currentIo());
    try stale_file.writeStreamingAll(path_mod.currentIo(), "stale");

    const stale_archive = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_root, "pkg", "pack-reset-1.0-1-x86_64-old.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(stale_archive);
    var stale_archive_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), stale_archive, .{});
    defer stale_archive_file.close(path_mod.currentIo());
    try stale_archive_file.writeStreamingAll(path_mod.currentIo(), "stale archive");

    try resetPackageStagingDirs(
        test_env.ctx.allocator,
        &test_env.ctx,
        parsed.packages.items,
        workspace_root,
    );

    var stale_path_missing = false;
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), stale_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        stale_path_missing = true;
    };
    try std.testing.expect(stale_path_missing);

    var stale_archive_missing = false;
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), stale_archive, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        stale_archive_missing = true;
    };
    try std.testing.expect(stale_archive_missing);
}
