// Build profile lifecycle for the ephemeral workspace profile root.

const std = @import("std");
const Context = @import("../mere.zig").Context;
const errors = @import("../errors.zig");
const path_mod = @import("../path.zig");
const ui = @import("../ui/mod.zig");

const Std = errors.StandardErrors;
pub const BuildProfileError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    ProfileCreationFailed,
};

/// BuildProfile owns the ephemeral build profile root at `<workspace>/profile/`.
pub const BuildProfile = struct {
    profile_path: []const u8,
    allocator: std.mem.Allocator,
    ctx: *Context,

    pub fn create(ctx: *Context, workspace_profile_dir: []const u8) BuildProfileError!BuildProfile {
        const allocator = ctx.allocator;
        const profile_path = allocator.dupe(u8, workspace_profile_dir) catch {
            return ctx.fail(BuildProfileError.OutOfMemory, "build_profile", "failed to dupe profile_path");
        };
        errdefer allocator.free(profile_path);

        ctx.debug("creating build profile at: {s}", .{profile_path});

        var profile_dir = path_mod.makePathAndOpenDir(profile_path) catch |err| {
            ctx.setDiagnosticContext(profile_path, "failed to create build profile directory");
            return switch (err) {
                error.AccessDenied => BuildProfileError.PermissionDenied,
                else => BuildProfileError.ProfileCreationFailed,
            };
        };
        profile_dir.close(path_mod.currentIo());

        ctx.debug("created build profile at: {s}", .{profile_path});

        return BuildProfile{
            .profile_path = profile_path,
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn root(self: *const BuildProfile) []const u8 {
        return self.profile_path;
    }

    pub fn cleanup(self: *BuildProfile) void {
        self.ctx.debug("cleaning up build profile: {s}", .{self.profile_path});

        const parent_path = std.fs.path.dirname(self.profile_path) orelse "/";
        const basename = std.fs.path.basename(self.profile_path);
        if (path_mod.openExistingDir(parent_path)) |parent_dir| {
            var dir = parent_dir;
            defer dir.close(path_mod.currentIo());
            dir.deleteTree(path_mod.currentIo(), basename) catch |err| {
                self.ctx.setDiagnosticContext(self.profile_path, "failed to cleanup build profile");
                self.ctx.debug("failed to cleanup build profile {s}: {}", .{ self.profile_path, err });
            };
        } else |err| {
            self.ctx.setDiagnosticContext(self.profile_path, "failed to cleanup build profile");
            self.ctx.debug("failed to open build profile parent {s}: {}", .{ self.profile_path, err });
        }

        self.allocator.free(self.profile_path);
    }

    pub fn preserve(self: *BuildProfile) void {
        ui.emit.logFmtSeverity(self.ctx, .build, .warn, "build profile preserved: {s}", .{self.profile_path});

        self.allocator.free(self.profile_path);
    }
};

// Tests

test "BuildProfile.create creates profile root" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const profile_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "workspace", "profile" });
    defer std.testing.allocator.free(profile_dir);

    var build_profile = try BuildProfile.create(ctx, profile_dir);
    defer build_profile.cleanup();

    var profile_dir_handle = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), build_profile.profile_path, .{}) catch |err| {
        ctx.setDiagnosticContext(build_profile.profile_path, "failed to open profile directory in test");
        std.debug.print("failed to open profile directory: {}\n", .{err});
        return err;
    };
    profile_dir_handle.close(path_mod.currentIo());
}

test "BuildProfile.root returns correct path" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const profile_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "workspace", "profile" });
    defer std.testing.allocator.free(profile_dir);

    var build_profile = try BuildProfile.create(ctx, profile_dir);
    defer build_profile.cleanup();

    const profile_root = build_profile.root();
    try std.testing.expectEqualStrings(build_profile.profile_path, profile_root);
}

test "BuildProfile.cleanup removes profile directory" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const profile_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "workspace", "profile" });
    defer std.testing.allocator.free(profile_dir);

    var build_profile = try BuildProfile.create(ctx, profile_dir);

    // Save path before cleanup
    const profile_path = try std.testing.allocator.dupe(u8, build_profile.profile_path);
    defer std.testing.allocator.free(profile_path);

    // Cleanup should remove the directory
    build_profile.cleanup();

    // Verify directory no longer exists
    const result = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_path, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "BuildProfile.preserve keeps profile directory" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const profile_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "workspace", "profile" });
    defer std.testing.allocator.free(profile_dir);

    var build_profile = try BuildProfile.create(ctx, profile_dir);

    // Save path before preserve
    const profile_path = try std.testing.allocator.dupe(u8, build_profile.profile_path);
    defer std.testing.allocator.free(profile_path);

    // Preserve should keep the directory
    build_profile.preserve();

    // Verify directory still exists
    var dir = try std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_path, .{});
    dir.close(path_mod.currentIo());

    // Manual cleanup for test
    const parent_path = std.fs.path.dirname(profile_path) orelse "/";
    const basename = std.fs.path.basename(profile_path);
    if (path_mod.openExistingDir(parent_path)) |parent_dir| {
        var cleanup_dir = parent_dir;
        defer cleanup_dir.close(path_mod.currentIo());
        cleanup_dir.deleteTree(path_mod.currentIo(), basename) catch {};
    } else |_| {}
}

test "BuildProfile.create uses provided workspace path" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const profile_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "workspace", "profile" });
    defer std.testing.allocator.free(profile_dir);

    var build_profile = try BuildProfile.create(ctx, profile_dir);
    defer build_profile.cleanup();

    // Profile path should match the provided workspace profile directory
    try std.testing.expectEqualStrings(profile_dir, build_profile.profile_path);
}
