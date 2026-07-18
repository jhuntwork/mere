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
    path_mod.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFs(err),
    };
}

fn stagingStatePath(allocator: std.mem.Allocator, repo_dir: []const u8) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, STAGING_STATE_DIR }) catch Error.OutOfMemory;
}

fn currentDbPath(allocator: std.mem.Allocator, repo_dir: []const u8) []const u8 {
    return std.fs.path.join(allocator, &.{ repo_dir, REPO_DB_FILENAME }) catch return &.{};
}

/// Publish `new_db`/`new_sig` (already fully written, e.g. staged files) into
/// `live_db_path`/`live_sig_path` as a coherent pair. A crash between the two
/// destination renames would otherwise leave a mismatched db/sig on disk;
/// this backs up whatever is currently live first and rolls back to it on
/// any partial failure, same pattern as repocache.zig's
/// replaceCachedDbAndSigWithRollback.
fn replaceLiveDbAndSigWithRollback(
    allocator: std.mem.Allocator,
    new_db: []const u8,
    new_sig: []const u8,
    live_db_path: []const u8,
    live_sig_path: []const u8,
) Error!void {
    const io = path_mod.currentIo();

    const db_backup = std.fmt.allocPrint(allocator, "{s}.bak", .{live_db_path}) catch return Error.OutOfMemory;
    defer allocator.free(db_backup);
    const sig_backup = std.fmt.allocPrint(allocator, "{s}.bak", .{live_sig_path}) catch return Error.OutOfMemory;
    defer allocator.free(sig_backup);

    std.Io.Dir.deleteFileAbsolute(io, db_backup) catch {};
    std.Io.Dir.deleteFileAbsolute(io, sig_backup) catch {};

    var moved_live_db = false;
    var moved_live_sig = false;

    std.Io.Dir.renameAbsolute(live_db_path, db_backup, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFs(err),
    };
    moved_live_db = path_mod.fileExists(db_backup);

    std.Io.Dir.renameAbsolute(live_sig_path, sig_backup, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, io) catch {};
            return mapFs(err);
        },
    };
    moved_live_sig = path_mod.fileExists(sig_backup);

    std.Io.Dir.renameAbsolute(new_db, live_db_path, io) catch |err| {
        if (moved_live_sig) std.Io.Dir.renameAbsolute(sig_backup, live_sig_path, io) catch {};
        if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, io) catch {};
        return mapFs(err);
    };

    std.Io.Dir.renameAbsolute(new_sig, live_sig_path, io) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, live_db_path) catch {};
        if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, io) catch {};
        if (moved_live_sig) std.Io.Dir.renameAbsolute(sig_backup, live_sig_path, io) catch {};
        return mapFs(err);
    };

    std.Io.Dir.deleteFileAbsolute(io, db_backup) catch {};
    std.Io.Dir.deleteFileAbsolute(io, sig_backup) catch {};
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

        // Flat layout: publish staged db and sig to repo root as a coherent
        // pair, with rollback on partial failure.
        const root_db = std.fs.path.join(self.ctx.allocator, &.{ self.repo_dir, REPO_DB_FILENAME }) catch {
            return Error.OutOfMemory;
        };
        defer self.ctx.allocator.free(root_db);
        const root_sig = std.fs.path.join(self.ctx.allocator, &.{ self.repo_dir, REPO_SIG_FILENAME }) catch {
            return Error.OutOfMemory;
        };
        defer self.ctx.allocator.free(root_sig);

        try replaceLiveDbAndSigWithRollback(self.ctx.allocator, self.db_path, self.sig_path, root_db, root_sig);

        self.committed = true;
    }

    /// Clean up. If not committed, removes the staging directory.
    /// Always releases the lock.
    pub fn deinit(self: *Staged) void {
        self.db.deinit();
        self.ctx.allocator.destroy(self.db);

        if (!self.committed) {
            path_mod.deleteTreeAbsolute(self.state_path) catch {};
        }

        _ = std.c.flock(self.lock_fd, std.c.LOCK.UN);
        _ = std.c.close(self.lock_fd);

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

    const lock_file = std.Io.Dir.createFileAbsolute(path_mod.currentIo(), lock_path, .{ .truncate = false }) catch |err| {
        return ctx.fail(mapFs(err), lock_path, "failed to open repo lock file");
    };
    const lock_fd = lock_file.handle;

    switch (std.posix.errno(std.c.flock(lock_fd, std.c.LOCK.EX))) {
        .SUCCESS => {},
        else => {
            _ = std.c.close(lock_fd);
            return ctx.fail(Error.FileSystem, lock_path, "failed to acquire repo lock");
        },
    }

    errdefer {
        _ = std.c.flock(lock_fd, std.c.LOCK.UN);
        _ = std.c.close(lock_fd);
    }

    const db_result = currentDbPath(allocator, repo_dir);
    const src_db_path = db_result;
    if (src_db_path.len == 0) {
        return ctx.fail(Error.OutOfMemory, repo_dir, "failed to construct current state db path");
    }
    defer allocator.free(src_db_path);

    std.Io.Dir.accessAbsolute(path_mod.currentIo(), src_db_path, .{}) catch |err| {
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

    path_mod.ensureDirExists(state_path) catch |err| {
        return ctx.fail(mapFs(err), state_path, "failed to create staging state directory");
    };
    errdefer path_mod.deleteTreeAbsolute(state_path) catch {};

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
    const ver = @import("version.zig");

    // Fetch all package IDs with their version+release for this (name, arch).
    const find_sql =
        \\SELECT id, version, release FROM packages
        \\WHERE name = ? AND arch = ?
    ;

    var find_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sqlite_db, find_sql.ptr, @intCast(find_sql.len), &find_stmt, null) != c.SQLITE_OK or find_stmt == null) {
        return Error.FileSystem;
    }
    defer _ = c.sqlite3_finalize(find_stmt.?);

    _ = c.sqlite3_bind_text(find_stmt.?, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(find_stmt.?, 2, arch.ptr, @intCast(arch.len), c.SQLITE_STATIC);

    const Candidate = struct {
        id: i64,
        version: []const u8,
        release: u32,
        keep: bool,
    };

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |cand| {
            db.ctx.allocator.free(cand.version);
        }
        candidates.deinit(db.ctx.allocator);
    }

    while (c.sqlite3_step(find_stmt.?) == c.SQLITE_ROW) {
        const pkg_id = c.sqlite3_column_int64(find_stmt.?, 0);
        const ver_text = c.sqlite3_column_text(find_stmt.?, 1);
        const rel: u32 = @intCast(c.sqlite3_column_int(find_stmt.?, 2));
        const version_str = if (ver_text != null) db.ctx.allocator.dupe(u8, std.mem.span(ver_text.?)) catch return Error.OutOfMemory else db.ctx.allocator.dupe(u8, "") catch return Error.OutOfMemory;
        candidates.append(db.ctx.allocator, .{
            .id = pkg_id,
            .version = version_str,
            .release = rel,
            .keep = false,
        }) catch return Error.OutOfMemory;
    }

    if (candidates.items.len <= keep_count) return 0;

    // Mark the top keep_count versions using selection (same algorithm as
    // getLatestPackagesByNameArch): find the highest version, mark it,
    // repeat keep_count times.
    var kept: u32 = 0;
    while (kept < keep_count) : (kept += 1) {
        var best_idx: ?usize = null;
        for (candidates.items, 0..) |cand, idx| {
            if (cand.keep) continue;
            if (best_idx == null) {
                best_idx = idx;
                continue;
            }
            const best = candidates.items[best_idx.?];
            const cmp = ver.comparePackageVersions(
                cand.version,
                cand.release,
                best.version,
                best.release,
            ) catch return Error.InvalidInput;
            if (cmp == .greater) best_idx = idx;
        }
        if (best_idx) |idx| {
            candidates.items[idx].keep = true;
        } else break;
    }

    // Collect IDs to delete (everything not marked keep).
    var ids_to_delete: std.ArrayList(i64) = .empty;
    defer ids_to_delete.deinit(db.ctx.allocator);

    for (candidates.items) |cand| {
        if (!cand.keep) {
            ids_to_delete.append(db.ctx.allocator, cand.id) catch return Error.OutOfMemory;
        }
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

    {
        var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
        repo.deinit();
    }

    var staged = try stageNext(&test_env.ctx, repo_dir);
    defer staged.deinit();

    const staged_db_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staged.state_path, REPO_DB_FILENAME });
    defer test_env.ctx.allocator.free(staged_db_path);
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), staged_db_path, .{});
}

test "Staged.commit writes db and sig to repo root" {
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

    {
        var repo = try repository.Repository.init(&test_env.ctx, repo_dir, false);
        repo.deinit();
    }

    const key_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(key_dir);
    try path_mod.ensureDirExists(key_dir);
    const kp = try sign_mod.generateKeyPair();
    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ key_dir, "test.key" });
    defer test_env.ctx.allocator.free(key_path);
    try kp.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    var staged = try stageNext(&test_env.ctx, repo_dir);
    try staged.commit();
    staged.deinit();

    const root_db = try std.fs.path.join(test_env.ctx.allocator, &.{ repo_dir, REPO_DB_FILENAME });
    defer test_env.ctx.allocator.free(root_db);
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), root_db, .{});

    const root_sig = try std.fs.path.join(test_env.ctx.allocator, &.{ repo_dir, REPO_SIG_FILENAME });
    defer test_env.ctx.allocator.free(root_sig);
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), root_sig, .{});
}

test "replaceLiveDbAndSigWithRollback restores the original db and sig pair if the second rename fails" {
    // Regression: Staged.commit used two independent, non-atomic copyFile
    // calls to publish the staged db and sig - a crash between them left a
    // mismatched pair on disk that every subsequent verify rejects (fails
    // closed, but the repo is unusable until manually re-signed). Simulates
    // the failure by pointing the new sig at a file that doesn't exist, so
    // the second rename in the swap fails, and confirms the live pair is
    // rolled back to its original content rather than left half-swapped.
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const live_db = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo.db" });
    defer test_env.ctx.allocator.free(live_db);
    const live_sig = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "repo.db.sig" });
    defer test_env.ctx.allocator.free(live_sig);
    const new_db = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "new.db" });
    defer test_env.ctx.allocator.free(new_db);
    const missing_new_sig = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "does-not-exist.sig" });
    defer test_env.ctx.allocator.free(missing_new_sig);

    {
        var f = try std.Io.Dir.createFileAbsolute(io, live_db, .{});
        try f.writeStreamingAll(io, "old-db");
        f.close(io);
    }
    {
        var f = try std.Io.Dir.createFileAbsolute(io, live_sig, .{});
        try f.writeStreamingAll(io, "old-sig");
        f.close(io);
    }
    {
        var f = try std.Io.Dir.createFileAbsolute(io, new_db, .{});
        try f.writeStreamingAll(io, "new-db");
        f.close(io);
    }
    // missing_new_sig is deliberately never created, so the second rename
    // inside replaceLiveDbAndSigWithRollback fails.

    try std.testing.expectError(
        error.FileSystem,
        replaceLiveDbAndSigWithRollback(test_env.ctx.allocator, new_db, missing_new_sig, live_db, live_sig),
    );

    var db_buf: [16]u8 = undefined;
    var db_file = try std.Io.Dir.openFileAbsolute(io, live_db, .{});
    defer db_file.close(io);
    const db_bytes = try db_file.readPositionalAll(io, &db_buf, 0);
    try std.testing.expectEqualStrings("old-db", db_buf[0..db_bytes]);

    var sig_buf: [16]u8 = undefined;
    var sig_file = try std.Io.Dir.openFileAbsolute(io, live_sig, .{});
    defer sig_file.close(io);
    const sig_bytes = try sig_file.readPositionalAll(io, &sig_buf, 0);
    try std.testing.expectEqualStrings("old-sig", sig_buf[0..sig_bytes]);
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

    std.Io.Dir.accessAbsolute(path_mod.currentIo(), staged_path, .{}) catch |err| {
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
