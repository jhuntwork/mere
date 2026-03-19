const std = @import("std");
const mere = @import("mere.zig");
const path = @import("path.zig");
const recipe = @import("recipe.zig");
const test_helpers = @import("test_helpers.zig");
const errors = @import("errors.zig");

/// Workspace management error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during workspace operations
/// - FileSystem: File operations failed (creating directories, etc.)
/// - InvalidInput: Invalid workspace parameters or configuration
///
/// Workspace-Specific Errors:
/// - CreationFailed: Workspace creation failed
/// - DirectoryCreationFailed: Directory creation failed
const Std = errors.StandardErrors;
pub const WorkspaceError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput || error{
    CreationFailed,
    DirectoryCreationFailed,
};

// Workspace representation - immutable structure with all paths
//
// Ownership & allocator contract:
// - All path fields (recipe_root, sources_dir, src_dir, destdir) are duplicated using
//   the Workspace.allocator and are therefore owned by the Workspace instance.
// - Callers that receive a Workspace are responsible for calling `Workspace.deinit()`
//   to free those duplicated buffers when the workspace is no longer needed.
// - If a caller needs to retain any path beyond the workspace lifetime, it MUST duplicate
//   the required string(s) into its own allocator before calling `Workspace.deinit()`.
// - For safety, `Workspace.deinit()` does not remove on-disk directories; it only releases
//   heap-owned buffers. Filesystem cleanup (if desired) must be performed explicitly by the caller.
pub const Workspace = struct {
    recipe_root: []const u8,
    sources_dir: []const u8,
    src_dir: []const u8,
    destdir: []const u8,
    profile_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Workspace) void {
        self.allocator.free(self.recipe_root);
        self.allocator.free(self.sources_dir);
        self.allocator.free(self.src_dir);
        self.allocator.free(self.destdir);
        self.allocator.free(self.profile_dir);
    }
};

// WorkspaceManager handles creation and destruction of build workspaces
pub const WorkspaceManager = struct {
    ctx: *mere.Context,

    pub fn init(ctx: *mere.Context) WorkspaceManager {
        return WorkspaceManager{
            .ctx = ctx,
        };
    }

    pub fn createWorkspace(self: *WorkspaceManager, r: *const recipe.Recipe) !Workspace {
        const allocator = self.ctx.allocator;

        const build_root = try std.fs.path.join(allocator, &.{ self.ctx.root(), "mere", "dev", "build" });
        defer allocator.free(build_root);

        // Create a unique workspace name using uuid to ensure uniqueness
        var uuid_bytes: [16]u8 = undefined;
        path.currentIo().random(&uuid_bytes);
        const uuid_hex = std.fmt.bytesToHex(uuid_bytes[0..8], .lower);

        // Use recipe name with fallback, matching original BuildWorkspace logic
        const pkg_name = if (r.name.len > 0) r.name else "pkg";
        const pkg_version = r.version;
        const pkg_release = r.release;

        if (!isValidWorkspaceComponent(pkg_name) or !isValidWorkspaceComponent(pkg_version)) {
            return WorkspaceError.InvalidInput;
        }

        // Create workspace root path: {build_root}/{recipe_name}-{version}-{release}-{uuid}
        const recipe_root = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}-{d}-{s}", .{ build_root, pkg_name, pkg_version, pkg_release, uuid_hex });
        errdefer allocator.free(recipe_root);
        errdefer if (std.fs.path.dirname(recipe_root)) |parent_path| {
            if (path.openExistingDir(parent_path) catch null) |parent_dir| {
                var dir = parent_dir;
                defer dir.close(path.currentIo());
                dir.deleteTree(path.currentIo(), std.fs.path.basename(recipe_root)) catch {};
            }
        };

        // Create derived directories
        const sources_dir = try std.fs.path.join(allocator, &.{ recipe_root, "sources" });
        errdefer allocator.free(sources_dir);
        const src_dir = try std.fs.path.join(allocator, &.{ recipe_root, "build-src" });
        errdefer allocator.free(src_dir);
        const destdir = try std.fs.path.join(allocator, &.{ recipe_root, "dest" });
        errdefer allocator.free(destdir);
        const profile_dir = try std.fs.path.join(allocator, &.{ recipe_root, "profile" });
        errdefer allocator.free(profile_dir);

        const root_dirs = [_][]const u8{
            recipe_root,
            sources_dir,
            src_dir,
            destdir,
            profile_dir,
        };
        for (root_dirs) |dir_path| {
            path.ensureDirExists(dir_path) catch {
                return WorkspaceError.DirectoryCreationFailed;
            };
        }

        // Create package directories (matching BuildWorkspace functionality)
        const pkg_root = try std.fs.path.join(allocator, &.{ recipe_root, "pkg" });
        defer allocator.free(pkg_root);
        path.ensureDirExists(pkg_root) catch {
            return WorkspaceError.DirectoryCreationFailed;
        };

        // Create per-package directories
        for (r.packages.items) |pkg_entry| {
            if (!isValidWorkspaceComponent(pkg_entry.name)) {
                return WorkspaceError.InvalidInput;
            }
            const pkg_dir = try std.fs.path.join(allocator, &.{ pkg_root, pkg_entry.name });
            defer allocator.free(pkg_dir);
            path.ensureDirExists(pkg_dir) catch {
                return WorkspaceError.DirectoryCreationFailed;
            };
        }

        return Workspace{
            .recipe_root = recipe_root,
            .sources_dir = sources_dir,
            .src_dir = src_dir,
            .destdir = destdir,
            .profile_dir = profile_dir,
            .allocator = allocator,
        };
    }

    /// Clean up all build workspaces.
    ///
    /// Removes all workspace directories from /mere/dev/build/.
    /// Returns the number of workspaces deleted.
    pub fn cleanAllWorkspaces(self: *WorkspaceManager) WorkspaceError!usize {
        const allocator = self.ctx.allocator;

        const build_root = std.fs.path.join(allocator, &.{ self.ctx.root(), "mere", "dev", "build" }) catch {
            return WorkspaceError.OutOfMemory;
        };
        defer allocator.free(build_root);

        // Open the build root directory
        var dir = std.Io.Dir.openDirAbsolute(path.currentIo(), build_root, .{ .iterate = true }) catch |err| {
            return switch (err) {
                error.FileNotFound => 0, // No build directory = nothing to clean
                error.AccessDenied => WorkspaceError.FileSystem,
                else => WorkspaceError.FileSystem,
            };
        };
        defer dir.close(path.currentIo());

        // Iterate through workspaces and delete them
        var iter = dir.iterate();
        var deleted_count: usize = 0;

        while (iter.next(path.currentIo()) catch return WorkspaceError.FileSystem) |entry| {
            // Only process directories (skip files like .gitkeep)
            if (entry.kind != .directory) continue;
            if (!isManagedWorkspaceName(entry.name)) continue;

            const workspace_path = std.fs.path.join(
                allocator,
                &.{ build_root, entry.name },
            ) catch {
                return WorkspaceError.OutOfMemory;
            };
            defer allocator.free(workspace_path);

            self.ctx.debug("removing build workspace: {s}", .{entry.name});

            path.deleteTreeAbsolute(workspace_path) catch |err| {
                self.ctx.debug("failed to delete build workspace {s}: {}", .{ entry.name, err });
                continue; // Continue with other workspaces even if one fails
            };

            deleted_count += 1;
        }

        return deleted_count;
    }
};

fn isValidWorkspaceComponent(name: []const u8) bool {
    if (!path.isValidInputPath(name)) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

fn isManagedWorkspaceName(name: []const u8) bool {
    if (name.len < 16) return false;
    const last_dash = std.mem.lastIndexOfScalar(u8, name, '-') orelse return false;
    const suffix = name[last_dash + 1 ..];
    if (suffix.len != 16) return false;
    for (suffix) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }

    const prefix = name[0..last_dash];
    const second_dash_from_end = std.mem.lastIndexOfScalar(u8, prefix, '-') orelse return false;
    if (second_dash_from_end == 0 or second_dash_from_end + 1 >= prefix.len) return false;
    const release_text = prefix[second_dash_from_end + 1 ..];
    for (release_text) |c| {
        if (c < '0' or c > '9') return false;
    }

    const version_and_name = prefix[0..second_dash_from_end];
    const first_dash = std.mem.indexOfScalar(u8, version_and_name, '-') orelse return false;
    if (first_dash == 0 or first_dash + 1 >= version_and_name.len) return false;
    return true;
}

// Test helper to check if directory exists
fn expectDirExists(dir_path: []const u8) !void {
    std.Io.Dir.accessAbsolute(path.currentIo(), dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return std.testing.expect(false), // Directory doesn't exist
        else => return err,
    };
}

// Helper to create a minimal test recipe
fn createTestRecipe(allocator: std.mem.Allocator, name: []const u8, version: []const u8, release: u32) !recipe.Recipe {
    var r = try recipe.Recipe.init(allocator, null);
    r.name = try allocator.dupe(u8, name);
    r.version = try allocator.dupe(u8, version);
    r.release = release;
    // Add a test package
    var artifact = try recipe.BuildArtifact.init(allocator);
    artifact.name = try allocator.dupe(u8, "test-pkg");
    try r.packages.append(allocator, artifact);
    return r;
}

fn cleanupTestRecipe(r: *recipe.Recipe) void {
    r.deinit();
}

test "WorkspaceManager creates directories with Recipe integration" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var manager = WorkspaceManager.init(&test_env.ctx);

    // Create a proper Recipe for testing
    var test_recipe = try createTestRecipe(test_env.ctx.allocator, "test-package", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe);

    const workspace = try manager.createWorkspace(&test_recipe);
    defer workspace.deinit();

    try expectDirExists(workspace.recipe_root);
    try expectDirExists(workspace.sources_dir);
    try expectDirExists(workspace.src_dir);
    try expectDirExists(workspace.destdir);

    // Test that package directories were created
    const pkg_root = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace.recipe_root, "pkg" });
    defer test_env.ctx.allocator.free(pkg_root);
    try expectDirExists(pkg_root);

    const test_pkg_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace.recipe_root, "pkg", "test-pkg" });
    defer test_env.ctx.allocator.free(test_pkg_dir);
    try expectDirExists(test_pkg_dir);
}

test "WorkspaceManager handles empty recipe name with fallback" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var manager = WorkspaceManager.init(&test_env.ctx);

    // Create recipe with empty name to test fallback
    var test_recipe = try createTestRecipe(test_env.ctx.allocator, "", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe);

    const workspace = try manager.createWorkspace(&test_recipe);
    defer workspace.deinit();

    // Should use "pkg" as fallback name
    try std.testing.expect(std.mem.indexOf(u8, workspace.recipe_root, "pkg-1.0-1") != null);
}

test "WorkspaceManager creates unique workspace directories" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var manager = WorkspaceManager.init(&test_env.ctx);

    // Create identical recipes - should get unique paths due to UUID
    var test_recipe1 = try createTestRecipe(test_env.ctx.allocator, "test", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe1);
    var test_recipe2 = try createTestRecipe(test_env.ctx.allocator, "test", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe2);

    const workspace1 = try manager.createWorkspace(&test_recipe1);
    defer workspace1.deinit();

    const workspace2 = try manager.createWorkspace(&test_recipe2);
    defer workspace2.deinit();

    // Should have different paths due to UUID uniqueness
    try std.testing.expect(!std.mem.eql(u8, workspace1.recipe_root, workspace2.recipe_root));
}

test "WorkspaceManager rejects recipe name with path separators" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var manager = WorkspaceManager.init(&test_env.ctx);
    var test_recipe = try createTestRecipe(test_env.ctx.allocator, "../bad/name", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe);

    try std.testing.expectError(WorkspaceError.InvalidInput, manager.createWorkspace(&test_recipe));
}

test "WorkspaceManager rejects package name with path separators" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var manager = WorkspaceManager.init(&test_env.ctx);
    var test_recipe = try createTestRecipe(test_env.ctx.allocator, "demo", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe);
    test_env.ctx.allocator.free(test_recipe.packages.items[0].name);
    test_recipe.packages.items[0].name = try test_env.ctx.allocator.dupe(u8, "bad/pkg");

    try std.testing.expectError(WorkspaceError.InvalidInput, manager.createWorkspace(&test_recipe));
}

test "WorkspaceManager cleanup only removes managed workspace directories" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var manager = WorkspaceManager.init(&test_env.ctx);
    var test_recipe = try createTestRecipe(test_env.ctx.allocator, "demo", "1.0", 1);
    defer cleanupTestRecipe(&test_recipe);

    const workspace = try manager.createWorkspace(&test_recipe);
    defer workspace.deinit();

    const build_root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "mere", "dev", "build" });
    defer test_env.ctx.allocator.free(build_root);

    const foreign_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ build_root, "manual-scratch" });
    defer test_env.ctx.allocator.free(foreign_dir);
    try path.ensureDirExists(foreign_dir);

    const removed = try manager.cleanAllWorkspaces();
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path.currentIo(), workspace.recipe_root, .{}));
    try std.Io.Dir.accessAbsolute(path.currentIo(), foreign_dir, .{});
}
