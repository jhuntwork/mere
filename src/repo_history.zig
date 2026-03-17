const std = @import("std");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const RepoDB = @import("repodb.zig").RepoDB;
const sign = @import("sign.zig");
const path_mod = @import("path.zig");

const Std = errors.StandardErrors;
pub const Error = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    StateNotFound,
};

/// Default number of versions to keep per (name, arch) during auto-prune.
/// Keeps the newly imported version plus 2 previous versions.
pub const DEFAULT_KEEP_VERSIONS: u32 = 3;

pub const CURRENT_STATE_DIR = "current";
pub const PREVIOUS_STATE_DIR = "previous";
pub const STAGING_STATE_DIR = ".next";

/// Fixed database filename used by all repositories.
pub const REPO_DB_FILENAME = "repo.db";

/// Fixed signature filename for the repository database.
pub const REPO_SIG_FILENAME = "repo.db.sig";

fn mapFs(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.AccessDenied => Error.PermissionDenied,
        else => Error.FileSystem,
    };
}

fn deleteTreeIfExists(path: []const u8) Error!void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFs(err),
    };
}

pub fn currentStatePath(allocator: std.mem.Allocator, repo_dir: []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, CURRENT_STATE_DIR }) catch Error.OutOfMemory;
}

fn previousStatePath(allocator: std.mem.Allocator, repo_dir: []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, PREVIOUS_STATE_DIR }) catch Error.OutOfMemory;
}

fn stagingStatePath(allocator: std.mem.Allocator, repo_dir: []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, STAGING_STATE_DIR }) catch Error.OutOfMemory;
}

fn currentDbPath(allocator: std.mem.Allocator, repo_dir: []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, CURRENT_STATE_DIR, REPO_DB_FILENAME }) catch Error.OutOfMemory;
}

fn previousDbPath(allocator: std.mem.Allocator, repo_dir: []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, PREVIOUS_STATE_DIR, REPO_DB_FILENAME }) catch Error.OutOfMemory;
}

pub const Staged = struct {
    ctx: *mere.Context,
    repo_dir: []const u8,
    state_path: []const u8,
    db: *RepoDB,
    db_path: []const u8,
    sig_path: []const u8,
    lock_fd: std.posix.fd_t,
    committed: bool,

    pub fn commit(self: *Staged) !void {
        const key_path = sign.resolveSigningKey(self.ctx, null) catch |err| {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.PermissionDenied => Error.PermissionDenied,
                else => Error.FileSystem,
            };
        };
        defer self.ctx.allocator.free(key_path);

        _ = sign.writeSignatureFileWithResolver(self.ctx, self.db_path, self.sig_path, null, null) catch |err| {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.PermissionDenied => Error.PermissionDenied,
                else => Error.FileSystem,
            };
        };

        const current_path = try currentStatePath(self.ctx.allocator, self.repo_dir);
        defer self.ctx.allocator.free(current_path);
        const previous_path = try previousStatePath(self.ctx.allocator, self.repo_dir);
        defer self.ctx.allocator.free(previous_path);

        try deleteTreeIfExists(previous_path);

        std.fs.renameAbsolute(current_path, previous_path) catch |err| {
            return switch (err) {
                error.FileNotFound => Error.StateNotFound,
                else => mapFs(err),
            };
        };

        std.fs.renameAbsolute(self.state_path, current_path) catch |err| {
            // Best effort rollback of slot move if stage activation fails.
            std.fs.renameAbsolute(previous_path, current_path) catch {};
            return mapFs(err);
        };

        self.committed = true;
    }

    /// Clean up. If not committed, removes the staging directory.
    /// Always releases the lock.
    pub fn deinit(self: *Staged) void {
        self.db.deinit();
        self.ctx.allocator.destroy(self.db);

        if (!self.committed) {
            std.fs.deleteTreeAbsolute(self.state_path) catch {};
        }

        std.posix.flock(self.lock_fd, std.posix.LOCK.UN) catch {};
        std.posix.close(self.lock_fd);

        self.ctx.allocator.free(self.state_path);
        self.ctx.allocator.free(self.db_path);
        self.ctx.allocator.free(self.sig_path);
    }
};

/// Create a staged next-state directory with a copy of the current DB.
///
/// 1. Acquire exclusive lock on `<repo_dir>/repo.lock`
/// 2. Create/replace `<repo_dir>/.next`
/// 3. Copy `<repo_dir>/current/repo.db` to `.next/repo.db`
/// 4. Open staged DB read-write and return handle
pub fn stageNext(
    ctx: *mere.Context,
    repo_dir: []const u8,
) !Staged {
    const allocator = ctx.allocator;

    const lock_path = std.fs.path.join(allocator, &.{ repo_dir, "repo.lock" }) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct lock path");
    };
    defer allocator.free(lock_path);

    const lock_file = std.fs.createFileAbsolute(lock_path, .{ .truncate = false }) catch |err| {
        return ctx.fail(mapFs(err), lock_path, "failed to open repo lock file");
    };
    const lock_fd = lock_file.handle;

    std.posix.flock(lock_fd, std.posix.LOCK.EX) catch {
        std.posix.close(lock_fd);
        return ctx.fail(Error.FileSystem, lock_path, "failed to acquire repo lock");
    };

    errdefer {
        std.posix.flock(lock_fd, std.posix.LOCK.UN) catch {};
        std.posix.close(lock_fd);
    }

    const src_db_path = currentDbPath(allocator, repo_dir) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct current state db path");
    };
    defer allocator.free(src_db_path);

    std.fs.accessAbsolute(src_db_path, .{}) catch |err| {
        return ctx.fail(switch (err) {
            error.FileNotFound => Error.StateNotFound,
            else => mapFs(err),
        }, src_db_path, "current state database not accessible");
    };

    const state_path = stagingStatePath(allocator, repo_dir) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct staging state path");
    };
    errdefer allocator.free(state_path);

    deleteTreeIfExists(state_path) catch |err| {
        return ctx.fail(err, state_path, "failed to remove stale staging state");
    };

    std.fs.cwd().makePath(state_path) catch |err| {
        return ctx.fail(mapFs(err), state_path, "failed to create staging state directory");
    };
    errdefer std.fs.deleteTreeAbsolute(state_path) catch {};

    const dst_db_path = std.fs.path.join(allocator, &.{ state_path, REPO_DB_FILENAME }) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct destination db path");
    };
    errdefer allocator.free(dst_db_path);

    const dst_sig_path = std.fs.path.join(allocator, &.{ state_path, REPO_SIG_FILENAME }) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct destination sig path");
    };
    errdefer allocator.free(dst_sig_path);

    path_mod.copyFile(src_db_path, dst_db_path) catch {
        return ctx.fail(Error.FileSystem, src_db_path, "failed to copy database to staging state");
    };

    const db = RepoDB.init(ctx, dst_db_path, false) catch |err| {
        return switch (err) {
            error.OutOfMemory => ctx.fail(Error.OutOfMemory, dst_db_path, "failed to open staged database"),
            error.PermissionDenied => ctx.fail(Error.PermissionDenied, dst_db_path, "permission denied opening staged database"),
            error.InvalidInput => ctx.fail(Error.InvalidInput, dst_db_path, "repository database schema is outdated or invalid"),
            error.CorruptData => ctx.fail(Error.InvalidInput, dst_db_path, "repository database schema is outdated or invalid"),
            else => ctx.fail(Error.FileSystem, dst_db_path, "failed to open staged database"),
        };
    };

    return Staged{
        .ctx = ctx,
        .repo_dir = repo_dir,
        .state_path = state_path,
        .db = db,
        .db_path = dst_db_path,
        .sig_path = dst_sig_path,
        .lock_fd = lock_fd,
        .committed = false,
    };
}

/// Undo the most recent committed change by swapping `current` and `previous`.
pub fn undo(ctx: *mere.Context, repo_dir: []const u8) Error!void {
    const lock_path = std.fs.path.join(ctx.allocator, &.{ repo_dir, "repo.lock" }) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct lock path");
    };
    defer ctx.allocator.free(lock_path);

    const lock_file = std.fs.createFileAbsolute(lock_path, .{ .truncate = false }) catch |err| {
        return ctx.fail(mapFs(err), lock_path, "failed to open repo lock file");
    };
    const lock_fd = lock_file.handle;
    errdefer std.posix.close(lock_fd);

    std.posix.flock(lock_fd, std.posix.LOCK.EX) catch {
        return ctx.fail(Error.FileSystem, lock_path, "failed to acquire repo lock");
    };
    defer {
        std.posix.flock(lock_fd, std.posix.LOCK.UN) catch {};
        std.posix.close(lock_fd);
    }

    const previous_db = previousDbPath(ctx.allocator, repo_dir) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct previous state db path");
    };
    defer ctx.allocator.free(previous_db);

    std.fs.accessAbsolute(previous_db, .{}) catch |err| {
        return ctx.fail(switch (err) {
            error.FileNotFound => Error.StateNotFound,
            else => mapFs(err),
        }, previous_db, "no undo state available");
    };

    const current_path = try currentStatePath(ctx.allocator, repo_dir);
    defer ctx.allocator.free(current_path);
    const previous_path = try previousStatePath(ctx.allocator, repo_dir);
    defer ctx.allocator.free(previous_path);
    const swap_path = std.fs.path.join(ctx.allocator, &.{ repo_dir, ".swap" }) catch {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct swap path");
    };
    defer ctx.allocator.free(swap_path);

    deleteTreeIfExists(swap_path) catch {};

    std.fs.renameAbsolute(current_path, swap_path) catch |err| {
        return ctx.fail(switch (err) {
            error.FileNotFound => Error.StateNotFound,
            else => mapFs(err),
        }, current_path, "active state not accessible");
    };

    std.fs.renameAbsolute(previous_path, current_path) catch |err| {
        std.fs.renameAbsolute(swap_path, current_path) catch {};
        return ctx.fail(mapFs(err), previous_path, "failed to activate previous state");
    };

    std.fs.renameAbsolute(swap_path, previous_path) catch |err| {
        // Best effort rollback to preserve at least one active current slot.
        std.fs.renameAbsolute(current_path, previous_path) catch {};
        std.fs.renameAbsolute(swap_path, current_path) catch {};
        return ctx.fail(mapFs(err), swap_path, "failed to complete state swap");
    };
}

/// Auto-prune old versions of a package from a database.
///
/// Keeps the `keep_count` most recent versions per (name, arch), ordered by
/// rowid descending (most recently inserted = most recent). Deletes associated
/// dependencies and provisions for pruned rows.
///
/// Returns the number of package rows deleted.
pub fn pruneOldVersions(
    db: *RepoDB,
    name: []const u8,
    arch: []const u8,
    keep_count: u32,
) Error!u32 {
    const sqlite_db = db.db orelse return Error.FileSystem;
    const c = @import("repodb.zig").c;

    const find_sql =
        \\SELECT id FROM packages
        \\WHERE name = ? AND arch = ?
        \\ORDER BY id DESC
        \\LIMIT -1 OFFSET ?;
    ;

    var find_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sqlite_db, find_sql.ptr, @intCast(find_sql.len), &find_stmt, null) != c.SQLITE_OK or find_stmt == null) {
        return Error.FileSystem;
    }
    defer _ = c.sqlite3_finalize(find_stmt.?);

    _ = c.sqlite3_bind_text(find_stmt.?, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(find_stmt.?, 2, arch.ptr, @intCast(arch.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int(find_stmt.?, 3, @intCast(keep_count));

    var ids_to_delete: std.ArrayList(i64) = .{};
    defer ids_to_delete.deinit(db.ctx.allocator);

    while (c.sqlite3_step(find_stmt.?) == c.SQLITE_ROW) {
        const pkg_id = c.sqlite3_column_int64(find_stmt.?, 0);
        ids_to_delete.append(db.ctx.allocator, pkg_id) catch return Error.OutOfMemory;
    }

    if (ids_to_delete.items.len == 0) return 0;

    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(sqlite_db, "BEGIN TRANSACTION;", null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return Error.FileSystem;
    }

    for (ids_to_delete.items) |pkg_id| {
        const del_deps = "DELETE FROM dependencies WHERE source_package_id = ?";
        var del_deps_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(sqlite_db, del_deps.ptr, @intCast(del_deps.len), &del_deps_stmt, null) != c.SQLITE_OK or del_deps_stmt == null) {
            _ = c.sqlite3_exec(sqlite_db, "ROLLBACK;", null, null, null);
            return Error.FileSystem;
        }
        _ = c.sqlite3_bind_int64(del_deps_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(del_deps_stmt.?);
        _ = c.sqlite3_finalize(del_deps_stmt.?);

        const del_provs = "DELETE FROM provisions WHERE package_id = ?";
        var del_provs_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(sqlite_db, del_provs.ptr, @intCast(del_provs.len), &del_provs_stmt, null) != c.SQLITE_OK or del_provs_stmt == null) {
            _ = c.sqlite3_exec(sqlite_db, "ROLLBACK;", null, null, null);
            return Error.FileSystem;
        }
        _ = c.sqlite3_bind_int64(del_provs_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(del_provs_stmt.?);
        _ = c.sqlite3_finalize(del_provs_stmt.?);

        const del_pkg = "DELETE FROM packages WHERE id = ?";
        var del_pkg_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(sqlite_db, del_pkg.ptr, @intCast(del_pkg.len), &del_pkg_stmt, null) != c.SQLITE_OK or del_pkg_stmt == null) {
            _ = c.sqlite3_exec(sqlite_db, "ROLLBACK;", null, null, null);
            return Error.FileSystem;
        }
        _ = c.sqlite3_bind_int64(del_pkg_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(del_pkg_stmt.?);
        _ = c.sqlite3_finalize(del_pkg_stmt.?);
    }

    if (c.sqlite3_exec(sqlite_db, "COMMIT;", null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return Error.FileSystem;
    }

    return @intCast(ids_to_delete.items.len);
}

test "stageNextState uses .next and copies current db" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo" });
    defer test_env.ctx.allocator.free(repo_dir);

    try repository.setupStateLayout(test_env.ctx.allocator, repo_dir);
    {
        var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
        repo.deinit();
    }

    var staged = try stageNext(&test_env.ctx, repo_dir);
    defer staged.deinit();

    const staged_db_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staged.state_path, REPO_DB_FILENAME });
    defer test_env.ctx.allocator.free(staged_db_path);
    try std.fs.accessAbsolute(staged_db_path, .{});
}

test "Staged.commit rotates current to previous" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    const sign_mod = @import("sign.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo" });
    defer test_env.ctx.allocator.free(repo_dir);

    try repository.setupStateLayout(test_env.ctx.allocator, repo_dir);
    {
        var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
        repo.deinit();
    }

    const key_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(key_dir);
    try std.fs.cwd().makePath(key_dir);
    const kp = try sign_mod.generateKeyPair();
    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ key_dir, "test.key" });
    defer test_env.ctx.allocator.free(key_path);
    try kp.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    var staged = try stageNext(&test_env.ctx, repo_dir);
    try staged.commit();
    staged.deinit();

    const previous_db = try previousDbPath(test_env.ctx.allocator, repo_dir);
    defer test_env.ctx.allocator.free(previous_db);
    try std.fs.accessAbsolute(previous_db, .{});
}

test "undoLastChange swaps current and previous" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    const sign_mod = @import("sign.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo" });
    defer test_env.ctx.allocator.free(repo_dir);

    try repository.setupStateLayout(test_env.ctx.allocator, repo_dir);
    {
        var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
        repo.deinit();
    }

    const key_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(key_dir);
    try std.fs.cwd().makePath(key_dir);
    const kp = try sign_mod.generateKeyPair();
    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ key_dir, "test.key" });
    defer test_env.ctx.allocator.free(key_path);
    try kp.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    var staged = try stageNext(&test_env.ctx, repo_dir);
    try staged.commit();
    staged.deinit();

    try undo(&test_env.ctx, repo_dir);

    const current_db = try currentDbPath(test_env.ctx.allocator, repo_dir);
    defer test_env.ctx.allocator.free(current_db);
    const previous_db = try previousDbPath(test_env.ctx.allocator, repo_dir);
    defer test_env.ctx.allocator.free(previous_db);
    try std.fs.accessAbsolute(current_db, .{});
    try std.fs.accessAbsolute(previous_db, .{});
}

test "Staged.deinit without commit cleans up staging dir" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo" });
    defer test_env.ctx.allocator.free(repo_dir);

    try repository.setupStateLayout(test_env.ctx.allocator, repo_dir);
    {
        var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
        repo.deinit();
    }

    const staged_path = try stagingStatePath(test_env.ctx.allocator, repo_dir);
    defer test_env.ctx.allocator.free(staged_path);

    {
        var staged = try stageNext(&test_env.ctx, repo_dir);
        staged.deinit();
    }

    std.fs.accessAbsolute(staged_path, .{}) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult;
}

test "pruneOldVersions removes excess versions" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    const package = @import("package.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo" });
    defer test_env.ctx.allocator.free(repo_dir);

    try repository.setupStateLayout(test_env.ctx.allocator, repo_dir);

    var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
    defer repo.deinit();

    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        var pkg = package.Package.init(&test_env.ctx);
        defer pkg.deinit();
        pkg.name = try test_env.ctx.allocator.dupe(u8, "mypkg");
        const ver_str = try std.fmt.allocPrint(test_env.ctx.allocator, "1.0.{d}", .{i});
        pkg.version = ver_str;
        pkg.release = 1;
        pkg.arch = try test_env.ctx.allocator.dupe(u8, "x86_64");
        pkg.content_hash = try test_env.ctx.allocator.dupe(u8, "deadbeef");
        pkg.archive_hash = try test_env.ctx.allocator.dupe(u8, "a" ** 64);
        pkg.signature = try test_env.ctx.allocator.dupe(u8, "aabbccdd");
        _ = try repo.db.insertPackageTransaction(&pkg);
    }

    const deleted = try pruneOldVersions(repo.db, "mypkg", "x86_64", 3);
    try std.testing.expectEqual(@as(u32, 2), deleted);
}

test "pruneOldVersions does nothing when under keep count" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    const package = @import("package.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo" });
    defer test_env.ctx.allocator.free(repo_dir);

    try repository.setupStateLayout(test_env.ctx.allocator, repo_dir);

    var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
    defer repo.deinit();

    var pkg1 = package.Package.init(&test_env.ctx);
    defer pkg1.deinit();
    pkg1.name = try test_env.ctx.allocator.dupe(u8, "mypkg");
    pkg1.version = try test_env.ctx.allocator.dupe(u8, "1.0.0");
    pkg1.release = 1;
    pkg1.arch = try test_env.ctx.allocator.dupe(u8, "x86_64");
    pkg1.content_hash = try test_env.ctx.allocator.dupe(u8, "deadbeef");
    pkg1.archive_hash = try test_env.ctx.allocator.dupe(u8, "a" ** 64);
    pkg1.signature = try test_env.ctx.allocator.dupe(u8, "aabbccdd");
    _ = try repo.db.insertPackageTransaction(&pkg1);

    var pkg2 = package.Package.init(&test_env.ctx);
    defer pkg2.deinit();
    pkg2.name = try test_env.ctx.allocator.dupe(u8, "mypkg");
    pkg2.version = try test_env.ctx.allocator.dupe(u8, "1.0.1");
    pkg2.release = 1;
    pkg2.arch = try test_env.ctx.allocator.dupe(u8, "x86_64");
    pkg2.content_hash = try test_env.ctx.allocator.dupe(u8, "deadbeef");
    pkg2.archive_hash = try test_env.ctx.allocator.dupe(u8, "b" ** 64);
    pkg2.signature = try test_env.ctx.allocator.dupe(u8, "aabbccdd");
    _ = try repo.db.insertPackageTransaction(&pkg2);

    const deleted = try pruneOldVersions(repo.db, "mypkg", "x86_64", 3);
    try std.testing.expectEqual(@as(u32, 0), deleted);
}
