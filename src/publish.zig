const std = @import("std");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const RepoDB = @import("repodb.zig").RepoDB;
const repodb_c = @import("repodb.zig").c;
const repodb = @import("repodb.zig");
const package_mod = @import("package.zig");
const repo_history = @import("repo_history.zig");
const path_mod = @import("path.zig");
const sign = @import("sign.zig");

const Std = errors.StandardErrors;
pub const PublishError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    SigningFailed,
};

fn mapFsError(err: anyerror) PublishError {
    return switch (err) {
        error.OutOfMemory => PublishError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => PublishError.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => PublishError.InvalidInput,
        else => PublishError.FileSystem,
    };
}

pub const StagedUpdate = struct {
    ctx: *mere.Context,
    stage_dir: []const u8,
    staged_db_path: []const u8,
    db: *RepoDB,
    committed: bool,

    pub fn commit(self: *StagedUpdate, output_repo_dir: []const u8) !void {
        path_mod.ensureDirExists(output_repo_dir) catch |err| {
            return self.ctx.fail(mapFsError(err), output_repo_dir, "failed to create output repo directory");
        };

        // Phase 5 coherence gate: DB rows must be materializable from the shared
        // package pool, and output packages set must match DB exactly.
        try materializePublishedPackages(self.ctx, self.db, output_repo_dir);

        const out_db_path = std.fs.path.join(self.ctx.allocator, &.{ output_repo_dir, repo_history.REPO_DB_FILENAME }) catch {
            return self.ctx.fail(PublishError.OutOfMemory, output_repo_dir, "failed to allocate output db path");
        };
        defer self.ctx.allocator.free(out_db_path);

        const out_db_tmp = std.fmt.allocPrint(self.ctx.allocator, "{s}.tmp", .{out_db_path}) catch {
            return self.ctx.fail(PublishError.OutOfMemory, out_db_path, "failed to allocate output db temp path");
        };
        defer self.ctx.allocator.free(out_db_tmp);

        path_mod.copyFile(self.staged_db_path, out_db_tmp) catch |err| {
            return self.ctx.fail(mapFsError(err), self.staged_db_path, "failed to copy staged db to output");
        };

        const out_sig_path = std.fs.path.join(self.ctx.allocator, &.{ output_repo_dir, repo_history.REPO_SIG_FILENAME }) catch {
            return self.ctx.fail(PublishError.OutOfMemory, output_repo_dir, "failed to allocate output signature path");
        };
        defer self.ctx.allocator.free(out_sig_path);

        const out_sig_tmp = std.fmt.allocPrint(self.ctx.allocator, "{s}.tmp", .{out_sig_path}) catch {
            return self.ctx.fail(PublishError.OutOfMemory, out_sig_path, "failed to allocate output signature temp path");
        };
        defer self.ctx.allocator.free(out_sig_tmp);

        _ = sign.writeSignatureFileWithResolver(self.ctx, out_db_tmp, out_sig_tmp, null, null) catch |err| {
            std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), out_db_tmp) catch {};
            std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), out_sig_tmp) catch {};
            return switch (err) {
                error.OutOfMemory => self.ctx.fail(PublishError.OutOfMemory, out_sig_path, "out of memory signing published db"),
                error.PermissionDenied => self.ctx.fail(PublishError.PermissionDenied, out_sig_path, "permission denied signing published db"),
                error.InvalidInput => self.ctx.fail(PublishError.InvalidInput, out_sig_path, "failed to sign published db"),
                error.FileSystem => self.ctx.fail(PublishError.FileSystem, out_sig_path, "failed to sign published db"),
                else => self.ctx.fail(PublishError.SigningFailed, out_sig_path, "failed to sign published db"),
            };
        };

        replaceDbAndSigWithRollback(self.ctx, out_db_tmp, out_sig_tmp, out_db_path, out_sig_path) catch |err| {
            return self.ctx.fail(err, out_db_path, "failed to atomically publish db/signature pair");
        };

        self.committed = true;
    }

    pub fn deinit(self: *StagedUpdate) void {
        self.db.deinit();
        self.ctx.allocator.destroy(self.db);
        if (!self.committed) {
            path_mod.deleteTreeAbsolute(self.stage_dir) catch {};
        }
        self.ctx.allocator.free(self.stage_dir);
        self.ctx.allocator.free(self.staged_db_path);
    }

    pub fn applyPackageWithRetention(
        self: *StagedUpdate,
        pkg: *package_mod.Package,
        keep_count: u32,
        force: bool,
    ) !u32 {
        try self.reconcileArchLineage(pkg);

        _ = self.db.insertPackageTransaction(pkg) catch |err| {
            if (err == repodb.RepoDBError.PackageAlreadyExists and force) {
                self.db.deletePackage(
                    pkg.name.?,
                    pkg.version.?,
                    pkg.release.?,
                    pkg.arch.?,
                ) catch {
                    return self.ctx.fail(PublishError.FileSystem, pkg.name.?, "failed to replace existing package in staged publish db");
                };
                _ = self.db.insertPackageTransaction(pkg) catch {
                    return self.ctx.fail(PublishError.FileSystem, pkg.name.?, "failed to insert replacement package in staged publish db");
                };
            } else {
                return self.ctx.fail(PublishError.FileSystem, pkg.name.?, "failed to insert package in staged publish db");
            }
        };

        return repo_history.pruneOldVersions(self.db, pkg.name.?, pkg.arch.?, keep_count) catch {
            return self.ctx.fail(PublishError.FileSystem, pkg.name.?, "failed to prune staged publish lineage");
        };
    }

    fn reconcileArchLineage(self: *StagedUpdate, pkg: *package_mod.Package) !void {
        var existing = self.db.getPackagesByName(self.ctx.allocator, pkg.name.?) catch |err| switch (err) {
            repodb.RepoDBError.PackageNotFound => return,
            else => return self.ctx.fail(PublishError.FileSystem, pkg.name.?, "failed to inspect staged publish lineage"),
        };
        defer {
            for (existing.items) |*candidate| candidate.deinit();
            existing.deinit(self.ctx.allocator);
        }

        const incoming_arch = pkg.arch.?;
        for (existing.items) |candidate| {
            const candidate_arch = candidate.arch orelse continue;
            const should_delete =
                if (std.mem.eql(u8, incoming_arch, "any"))
                    !std.mem.eql(u8, candidate_arch, "any")
                else
                    std.mem.eql(u8, candidate_arch, "any");

            if (!should_delete) continue;

            self.db.deletePackage(
                candidate.name.?,
                candidate.version.?,
                candidate.release.?,
                candidate_arch,
            ) catch |err| switch (err) {
                repodb.RepoDBError.PackageNotFound => {},
                else => return self.ctx.fail(PublishError.FileSystem, pkg.name.?, "failed to reconcile staged publish arch lineage"),
            };
        }
    }
};

fn replaceDbAndSigWithRollback(
    ctx: *mere.Context,
    new_db_tmp: []const u8,
    new_sig_tmp: []const u8,
    live_db_path: []const u8,
    live_sig_path: []const u8,
) PublishError!void {
    const db_backup = std.fmt.allocPrint(ctx.allocator, "{s}.bak", .{live_db_path}) catch {
        return PublishError.OutOfMemory;
    };
    defer ctx.allocator.free(db_backup);
    const sig_backup = std.fmt.allocPrint(ctx.allocator, "{s}.bak", .{live_sig_path}) catch {
        return PublishError.OutOfMemory;
    };
    defer ctx.allocator.free(sig_backup);

    std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), db_backup) catch {};
    std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), sig_backup) catch {};

    var moved_live_db = false;
    var moved_live_sig = false;

    std.Io.Dir.renameAbsolute(live_db_path, db_backup, path_mod.currentIo()) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFsError(err),
    };
    moved_live_db = path_mod.fileExists(db_backup);

    std.Io.Dir.renameAbsolute(live_sig_path, sig_backup, path_mod.currentIo()) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, path_mod.currentIo()) catch {};
            return mapFsError(err);
        },
    };
    moved_live_sig = path_mod.fileExists(sig_backup);

    std.Io.Dir.renameAbsolute(new_db_tmp, live_db_path, path_mod.currentIo()) catch |err| {
        if (moved_live_sig) std.Io.Dir.renameAbsolute(sig_backup, live_sig_path, path_mod.currentIo()) catch {};
        if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, path_mod.currentIo()) catch {};
        return mapFsError(err);
    };

    std.Io.Dir.renameAbsolute(new_sig_tmp, live_sig_path, path_mod.currentIo()) catch |err| {
        std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), live_db_path) catch {};
        if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, path_mod.currentIo()) catch {};
        if (moved_live_sig) std.Io.Dir.renameAbsolute(sig_backup, live_sig_path, path_mod.currentIo()) catch {};
        return mapFsError(err);
    };

    std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), db_backup) catch {};
    std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), sig_backup) catch {};
}

fn packagePoolDir(ctx: *mere.Context) ![]const u8 {
    return std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "cache", "packages" }) catch {
        return ctx.fail(PublishError.OutOfMemory, ctx.root_path, "failed to allocate package pool path");
    };
}

fn collectRequiredArchiveNames(ctx: *mere.Context, db: *RepoDB) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| ctx.allocator.free(n);
        names.deinit(ctx.allocator);
    }

    const sqlite_db = db.db orelse return ctx.fail(PublishError.FileSystem, "staged db", "staged publish db is not open");
    const sql =
        \\SELECT name, version, release, arch, archive_hash
        \\FROM packages
        \\ORDER BY name, version, release, arch;
    ;
    var stmt: ?*repodb_c.sqlite3_stmt = null;
    if (repodb_c.sqlite3_prepare_v2(sqlite_db, sql.ptr, @intCast(sql.len), &stmt, null) != repodb_c.SQLITE_OK or stmt == null) {
        return ctx.fail(PublishError.FileSystem, "staged db", "failed to prepare package listing query");
    }
    defer _ = repodb_c.sqlite3_finalize(stmt.?);

    while (true) {
        const step = repodb_c.sqlite3_step(stmt.?);
        if (step == repodb_c.SQLITE_DONE) break;
        if (step != repodb_c.SQLITE_ROW) {
            return ctx.fail(PublishError.FileSystem, "staged db", "failed to query package rows");
        }

        const name_c = repodb_c.sqlite3_column_text(stmt.?, 0) orelse {
            return ctx.fail(PublishError.InvalidInput, "staged db", "package row missing name");
        };
        const version_c = repodb_c.sqlite3_column_text(stmt.?, 1) orelse {
            return ctx.fail(PublishError.InvalidInput, "staged db", "package row missing version");
        };
        const release = repodb_c.sqlite3_column_int(stmt.?, 2);
        const arch_c = repodb_c.sqlite3_column_text(stmt.?, 3) orelse {
            return ctx.fail(PublishError.InvalidInput, "staged db", "package row missing arch");
        };
        const hash_c = repodb_c.sqlite3_column_text(stmt.?, 4) orelse {
            return ctx.fail(PublishError.InvalidInput, "staged db", "package row missing archive_hash");
        };

        const name = std.mem.span(name_c);
        const version = std.mem.span(version_c);
        const arch = std.mem.span(arch_c);
        const archive_hash = std.mem.span(hash_c);
        if (archive_hash.len != 64) {
            return ctx.fail(PublishError.InvalidInput, archive_hash, "package row has invalid archive_hash length");
        }
        const filename = std.fmt.allocPrint(
            ctx.allocator,
            "{s}-{s}-{d}-{s}-{s}.pkg.tar.zst",
            .{ name, version, release, arch, archive_hash },
        ) catch {
            return ctx.fail(PublishError.OutOfMemory, name, "failed to allocate archive filename");
        };
        try names.append(ctx.allocator, filename);
    }

    return names;
}

fn materializePublishedPackages(
    ctx: *mere.Context,
    db: *RepoDB,
    output_repo_dir: []const u8,
) !void {
    const pool_dir = try packagePoolDir(ctx);
    defer ctx.allocator.free(pool_dir);
    path_mod.ensureDirExists(pool_dir) catch |err| {
        return ctx.fail(mapFsError(err), pool_dir, "failed to create package pool directory");
    };

    var required = try collectRequiredArchiveNames(ctx, db);
    defer {
        for (required.items) |name| ctx.allocator.free(name);
        required.deinit(ctx.allocator);
    }

    const tmp_packages_dir = std.fs.path.join(ctx.allocator, &.{ output_repo_dir, ".packages-tmp" }) catch {
        return ctx.fail(PublishError.OutOfMemory, output_repo_dir, "failed to allocate temp packages dir");
    };
    defer ctx.allocator.free(tmp_packages_dir);
    path_mod.deleteTreeAbsolute(tmp_packages_dir) catch {};
    path_mod.ensureDirExists(tmp_packages_dir) catch |err| {
        return ctx.fail(mapFsError(err), tmp_packages_dir, "failed to create temp packages dir");
    };

    for (required.items) |archive_name| {
        const src_path = std.fs.path.join(ctx.allocator, &.{ pool_dir, archive_name }) catch {
            return ctx.fail(PublishError.OutOfMemory, archive_name, "failed to allocate source archive path");
        };
        defer ctx.allocator.free(src_path);
        std.Io.Dir.accessAbsolute(path_mod.currentIo(), src_path, .{}) catch {
            return ctx.fail(PublishError.InvalidInput, src_path, "publish blocked: package archive missing from shared pool");
        };

        const dst_path = std.fs.path.join(ctx.allocator, &.{ tmp_packages_dir, archive_name }) catch {
            return ctx.fail(PublishError.OutOfMemory, archive_name, "failed to allocate destination archive path");
        };
        defer ctx.allocator.free(dst_path);

        path_mod.copyFile(src_path, dst_path) catch |err| {
            return ctx.fail(mapFsError(err), src_path, "failed to copy archive into published package set");
        };
    }

    const out_packages_dir = std.fs.path.join(ctx.allocator, &.{ output_repo_dir, "packages" }) catch {
        return ctx.fail(PublishError.OutOfMemory, output_repo_dir, "failed to allocate output packages path");
    };
    defer ctx.allocator.free(out_packages_dir);

    path_mod.deleteTreeAbsolute(out_packages_dir) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return ctx.fail(mapFsError(err), out_packages_dir, "failed to replace output packages directory"),
        }
    };

    std.Io.Dir.renameAbsolute(tmp_packages_dir, out_packages_dir, path_mod.currentIo()) catch |err| {
        return ctx.fail(mapFsError(err), out_packages_dir, "failed to atomically publish packages directory");
    };
}

pub fn stageEmpty(
    ctx: *mere.Context,
    stage_dir: []const u8,
) !StagedUpdate {
    path_mod.ensureDirExists(stage_dir) catch |err| {
        return ctx.fail(mapFsError(err), stage_dir, "failed to create publish stage directory");
    };

    const staged_db_path = std.fs.path.join(ctx.allocator, &.{ stage_dir, repo_history.REPO_DB_FILENAME }) catch {
        return ctx.fail(PublishError.OutOfMemory, stage_dir, "failed to allocate staged db path");
    };
    errdefer ctx.allocator.free(staged_db_path);

    const db = RepoDB.init(ctx, staged_db_path, false) catch |err| {
        return switch (err) {
            error.OutOfMemory => PublishError.OutOfMemory,
            error.PermissionDenied => PublishError.PermissionDenied,
            error.InvalidInput => PublishError.InvalidInput,
            else => ctx.fail(PublishError.FileSystem, staged_db_path, "failed to open staged published db"),
        };
    };

    return StagedUpdate{
        .ctx = ctx,
        .stage_dir = try ctx.allocator.dupe(u8, stage_dir),
        .staged_db_path = staged_db_path,
        .db = db,
        .committed = false,
    };
}

pub fn stageFromPublishedBaseline(
    ctx: *mere.Context,
    stage_dir: []const u8,
    output_repo_dir: []const u8,
) !StagedUpdate {
    path_mod.ensureDirExists(stage_dir) catch |err| {
        return ctx.fail(mapFsError(err), stage_dir, "failed to create publish stage directory");
    };

    const staged_db_path = std.fs.path.join(ctx.allocator, &.{ stage_dir, repo_history.REPO_DB_FILENAME }) catch {
        return ctx.fail(PublishError.OutOfMemory, stage_dir, "failed to allocate staged db path");
    };
    errdefer ctx.allocator.free(staged_db_path);

    const baseline_db_path = std.fs.path.join(ctx.allocator, &.{ output_repo_dir, repo_history.REPO_DB_FILENAME }) catch {
        return ctx.fail(PublishError.OutOfMemory, output_repo_dir, "failed to allocate published baseline db path");
    };
    defer ctx.allocator.free(baseline_db_path);

    if (path_mod.fileExists(baseline_db_path)) {
        path_mod.copyFile(baseline_db_path, staged_db_path) catch |err| {
            return ctx.fail(mapFsError(err), baseline_db_path, "failed to copy published baseline db into stage");
        };
    }

    const db = RepoDB.init(ctx, staged_db_path, false) catch |err| {
        return switch (err) {
            error.OutOfMemory => PublishError.OutOfMemory,
            error.PermissionDenied => PublishError.PermissionDenied,
            error.InvalidInput => ctx.fail(PublishError.InvalidInput, baseline_db_path, "published baseline repository database schema is outdated or invalid"),
            error.CorruptData => ctx.fail(PublishError.InvalidInput, baseline_db_path, "published baseline repository database schema is outdated or invalid"),
            else => ctx.fail(PublishError.FileSystem, staged_db_path, "failed to open staged published baseline db"),
        };
    };
    errdefer {
        db.deinit();
        ctx.allocator.destroy(db);
    }

    return StagedUpdate{
        .ctx = ctx,
        .stage_dir = try ctx.allocator.dupe(u8, stage_dir),
        .staged_db_path = staged_db_path,
        .db = db,
        .committed = false,
    };
}

fn countPackages(db: *RepoDB) !u32 {
    const sqlite_db = db.db orelse return PublishError.FileSystem;
    const sql = "SELECT COUNT(*) FROM packages;";
    var stmt: ?*repodb_c.sqlite3_stmt = null;
    if (repodb_c.sqlite3_prepare_v2(sqlite_db, sql.ptr, @intCast(sql.len), &stmt, null) != repodb_c.SQLITE_OK or stmt == null) {
        return PublishError.FileSystem;
    }
    defer _ = repodb_c.sqlite3_finalize(stmt.?);
    const step = repodb_c.sqlite3_step(stmt.?);
    if (step != repodb_c.SQLITE_ROW) return PublishError.FileSystem;
    return @intCast(repodb_c.sqlite3_column_int(stmt.?, 0));
}

fn makeTestPkg(ctx: *mere.Context, name: []const u8, version: []const u8, arch: []const u8, hash: []const u8) !package_mod.Package {
    var pkg = package_mod.Package.init(ctx);
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, version);
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, arch);
    pkg.content_hash = try ctx.allocator.dupe(u8, hash);
    pkg.archive_hash = try ctx.allocator.dupe(u8, hash);
    pkg.signature = try ctx.allocator.dupe(u8, "deadbeef");
    return pkg;
}

fn packageVersionExists(db: *RepoDB, name: []const u8, version: []const u8) !bool {
    const sqlite_db = db.db orelse return PublishError.FileSystem;
    const sql = "SELECT 1 FROM packages WHERE name = ? AND version = ? LIMIT 1;";
    var stmt: ?*repodb_c.sqlite3_stmt = null;
    if (repodb_c.sqlite3_prepare_v2(sqlite_db, sql.ptr, @intCast(sql.len), &stmt, null) != repodb_c.SQLITE_OK or stmt == null) {
        return PublishError.FileSystem;
    }
    defer _ = repodb_c.sqlite3_finalize(stmt.?);
    _ = repodb_c.sqlite3_bind_text(stmt.?, 1, name.ptr, @intCast(name.len), repodb_c.SQLITE_STATIC);
    _ = repodb_c.sqlite3_bind_text(stmt.?, 2, version.ptr, @intCast(version.len), repodb_c.SQLITE_STATIC);
    return repodb_c.sqlite3_step(stmt.?) == repodb_c.SQLITE_ROW;
}

test "stageEmpty creates fresh empty db" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    const count = try countPackages(staged.db);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "stageFromPublishedBaseline copies existing output db" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-baseline" });
    defer ctx.allocator.free(output_dir);
    try path_mod.ensureDirExists(output_dir);

    const output_db = try std.fs.path.join(ctx.allocator, &.{ output_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(output_db);
    var baseline_db = try RepoDB.init(ctx, output_db, false);
    defer {
        baseline_db.deinit();
        ctx.allocator.destroy(baseline_db);
    }

    var baseline_pkg = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "a" ** 64);
    defer baseline_pkg.deinit();
    _ = try baseline_db.insertPackageTransaction(&baseline_pkg);

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-baseline" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageFromPublishedBaseline(ctx, stage_dir, output_dir);
    defer staged.deinit();

    try std.testing.expectEqual(@as(u32, 1), try countPackages(staged.db));
    try std.testing.expect(try packageVersionExists(staged.db, "pkg-a", "1.0.0"));
}

test "staged publish commit writes db, signature, and packages to output" {
    const th = @import("test_helpers.zig");
    const sign_mod = @import("sign.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const keypair = try sign_mod.generateKeyPair();
    const key_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "keys" });
    defer ctx.allocator.free(key_dir);
    try path_mod.ensureDirExists(key_dir);
    const key_path = try std.fs.path.join(ctx.allocator, &.{ key_dir, "publish.key" });
    defer ctx.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);
    ctx.signing_key_path = key_path;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-commit" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "a" ** 64);
    defer p1.deinit();
    _ = try staged.db.insertPackageTransaction(&p1);
    var p2 = try makeTestPkg(ctx, "pkg-b", "2.0.0", "x86_64", "b" ** 64);
    defer p2.deinit();
    _ = try staged.db.insertPackageTransaction(&p2);

    const pool_dir = try packagePoolDir(ctx);
    defer ctx.allocator.free(pool_dir);
    try path_mod.ensureDirExists(pool_dir);
    const p1_name = try std.fmt.allocPrint(ctx.allocator, "pkg-a-1.0.0-1-x86_64-{s}.pkg.tar.zst", .{"a" ** 64});
    defer ctx.allocator.free(p1_name);
    const p2_name = try std.fmt.allocPrint(ctx.allocator, "pkg-b-2.0.0-1-x86_64-{s}.pkg.tar.zst", .{"b" ** 64});
    defer ctx.allocator.free(p2_name);
    const p1_pool = try std.fs.path.join(ctx.allocator, &.{ pool_dir, p1_name });
    defer ctx.allocator.free(p1_pool);
    const p2_pool = try std.fs.path.join(ctx.allocator, &.{ pool_dir, p2_name });
    defer ctx.allocator.free(p2_pool);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), p1_pool, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "archive-a");
        f.close(path_mod.currentIo());
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), p2_pool, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "archive-b");
        f.close(path_mod.currentIo());
    }

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out" });
    defer ctx.allocator.free(output_dir);
    try staged.commit(output_dir);

    const out_db = try std.fs.path.join(ctx.allocator, &.{ output_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(out_db);
    var out = try RepoDB.init(ctx, out_db, true);
    defer {
        out.deinit();
        ctx.allocator.destroy(out);
    }
    try std.testing.expectEqual(@as(u32, 2), try countPackages(out));

    const out_sig = try std.fs.path.join(ctx.allocator, &.{ output_dir, repo_history.REPO_SIG_FILENAME });
    defer ctx.allocator.free(out_sig);
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), out_sig, .{}) catch return error.TestUnexpectedResult;

    const out_packages = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages" });
    defer ctx.allocator.free(out_packages);
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), out_packages, .{}) catch return error.TestUnexpectedResult;
}

test "applyPackageWithRetention prunes oldest versions beyond keep count" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-retention" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "1" ** 64);
    defer p1.deinit();
    _ = try staged.applyPackageWithRetention(&p1, 3, false);
    var p2 = try makeTestPkg(ctx, "pkg-a", "2.0.0", "x86_64", "2" ** 64);
    defer p2.deinit();
    _ = try staged.applyPackageWithRetention(&p2, 3, false);
    var p3 = try makeTestPkg(ctx, "pkg-a", "3.0.0", "x86_64", "3" ** 64);
    defer p3.deinit();
    const deleted_after_p3 = try staged.applyPackageWithRetention(&p3, 3, false);
    try std.testing.expectEqual(@as(u32, 0), deleted_after_p3);
    try std.testing.expectEqual(@as(u32, 3), try countPackages(staged.db));

    var p4 = try makeTestPkg(ctx, "pkg-a", "4.0.0", "x86_64", "4" ** 64);
    defer p4.deinit();
    const deleted_after_p4 = try staged.applyPackageWithRetention(&p4, 3, false);
    try std.testing.expectEqual(@as(u32, 1), deleted_after_p4);
    try std.testing.expectEqual(@as(u32, 3), try countPackages(staged.db));

    try std.testing.expect(!(try packageVersionExists(staged.db, "pkg-a", "1.0.0")));
    try std.testing.expect(try packageVersionExists(staged.db, "pkg-a", "2.0.0"));
    try std.testing.expect(try packageVersionExists(staged.db, "pkg-a", "3.0.0"));
    try std.testing.expect(try packageVersionExists(staged.db, "pkg-a", "4.0.0"));
}

test "applyPackageWithRetention supports keep count of one" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-keep-one" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "1" ** 64);
    defer p1.deinit();
    _ = try staged.applyPackageWithRetention(&p1, 1, false);
    try std.testing.expectEqual(@as(u32, 1), try countPackages(staged.db));

    var p2 = try makeTestPkg(ctx, "pkg-a", "2.0.0", "x86_64", "2" ** 64);
    defer p2.deinit();
    const deleted_after_p2 = try staged.applyPackageWithRetention(&p2, 1, false);
    try std.testing.expectEqual(@as(u32, 1), deleted_after_p2);
    try std.testing.expectEqual(@as(u32, 1), try countPackages(staged.db));

    try std.testing.expect(!(try packageVersionExists(staged.db, "pkg-a", "1.0.0")));
    try std.testing.expect(try packageVersionExists(staged.db, "pkg-a", "2.0.0"));
}

test "applyPackageWithRetention replaces concrete arch lineage with any" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-any-replaces-concrete" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p_old = try makeTestPkg(ctx, "linux-headers", "1.0.0", "x86_64", "a" ** 64);
    defer p_old.deinit();
    _ = try staged.db.insertPackageTransaction(&p_old);

    var p_new = try makeTestPkg(ctx, "linux-headers", "2.0.0", "any", "b" ** 64);
    defer p_new.deinit();
    _ = try staged.applyPackageWithRetention(&p_new, 3, false);

    try std.testing.expectEqual(@as(u32, 1), try countPackages(staged.db));
    try std.testing.expect(!(try packageVersionExists(staged.db, "linux-headers", "1.0.0")));
    try std.testing.expect(try packageVersionExists(staged.db, "linux-headers", "2.0.0"));
}

test "applyPackageWithRetention replaces any lineage with concrete arch" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-concrete-replaces-any" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p_old = try makeTestPkg(ctx, "linux-headers", "1.0.0", "any", "a" ** 64);
    defer p_old.deinit();
    _ = try staged.db.insertPackageTransaction(&p_old);

    var p_new = try makeTestPkg(ctx, "linux-headers", "2.0.0", "x86_64", "b" ** 64);
    defer p_new.deinit();
    _ = try staged.applyPackageWithRetention(&p_new, 3, false);

    try std.testing.expectEqual(@as(u32, 1), try countPackages(staged.db));
    try std.testing.expect(!(try packageVersionExists(staged.db, "linux-headers", "1.0.0")));
    try std.testing.expect(try packageVersionExists(staged.db, "linux-headers", "2.0.0"));
}

test "publish commit fails when required package archive is missing from shared pool" {
    const th = @import("test_helpers.zig");
    const sign_mod = @import("sign.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const keypair = try sign_mod.generateKeyPair();
    const key_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "keys-missing-archive" });
    defer ctx.allocator.free(key_dir);
    try path_mod.ensureDirExists(key_dir);
    const key_path = try std.fs.path.join(ctx.allocator, &.{ key_dir, "publish.key" });
    defer ctx.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);
    ctx.signing_key_path = key_path;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-missing-archive" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "a" ** 64);
    defer p1.deinit();
    _ = try staged.db.insertPackageTransaction(&p1);

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out-missing-archive" });
    defer ctx.allocator.free(output_dir);
    try std.testing.expectError(PublishError.InvalidInput, staged.commit(output_dir));
}

test "publish commit replaces output packages with exactly db-referenced set" {
    const th = @import("test_helpers.zig");
    const sign_mod = @import("sign.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const keypair = try sign_mod.generateKeyPair();
    const key_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "keys-coherence" });
    defer ctx.allocator.free(key_dir);
    try path_mod.ensureDirExists(key_dir);
    const key_path = try std.fs.path.join(ctx.allocator, &.{ key_dir, "publish.key" });
    defer ctx.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);
    ctx.signing_key_path = key_path;

    const pool_dir = try packagePoolDir(ctx);
    defer ctx.allocator.free(pool_dir);
    try path_mod.ensureDirExists(pool_dir);
    const p1_name = try std.fmt.allocPrint(ctx.allocator, "pkg-a-1.0.0-1-x86_64-{s}.pkg.tar.zst", .{"a" ** 64});
    defer ctx.allocator.free(p1_name);
    const p1_pool = try std.fs.path.join(ctx.allocator, &.{ pool_dir, p1_name });
    defer ctx.allocator.free(p1_pool);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), p1_pool, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "archive-a");
        f.close(path_mod.currentIo());
    }

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-coherence" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "a" ** 64);
    defer p1.deinit();
    _ = try staged.db.insertPackageTransaction(&p1);

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out-coherence" });
    defer ctx.allocator.free(output_dir);
    const out_packages = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages" });
    defer ctx.allocator.free(out_packages);
    try path_mod.ensureDirExists(out_packages);
    const stale = try std.fs.path.join(ctx.allocator, &.{ out_packages, "stale.pkg.tar.zst" });
    defer ctx.allocator.free(stale);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), stale, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "stale");
        f.close(path_mod.currentIo());
    }

    try staged.commit(output_dir);

    const expected_out = try std.fs.path.join(ctx.allocator, &.{ out_packages, p1_name });
    defer ctx.allocator.free(expected_out);
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), expected_out, .{}) catch return error.TestUnexpectedResult;
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), stale, .{}) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult;
}

test "publish commit fails when db content_hash is missing/invalid" {
    const th = @import("test_helpers.zig");
    const sign_mod = @import("sign.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const keypair = try sign_mod.generateKeyPair();
    const key_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "keys-invalid-hash" });
    defer ctx.allocator.free(key_dir);
    try path_mod.ensureDirExists(key_dir);
    const key_path = try std.fs.path.join(ctx.allocator, &.{ key_dir, "publish.key" });
    defer ctx.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);
    ctx.signing_key_path = key_path;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-invalid-hash" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "short-hash");
    defer p1.deinit();
    _ = try staged.db.insertPackageTransaction(&p1);

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out-invalid-hash" });
    defer ctx.allocator.free(output_dir);
    try std.testing.expectError(PublishError.InvalidInput, staged.commit(output_dir));
}

test "publish mapFsError preserves actionable classes" {
    try std.testing.expectEqual(PublishError.OutOfMemory, mapFsError(error.OutOfMemory));
    try std.testing.expectEqual(PublishError.PermissionDenied, mapFsError(error.AccessDenied));
    try std.testing.expectEqual(PublishError.InvalidInput, mapFsError(error.BadPathName));
    try std.testing.expectEqual(PublishError.FileSystem, mapFsError(error.FileNotFound));
}

test "publish commit does not replace live db when signing temp db fails" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const stage_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "publish-stage-sign-fail" });
    defer ctx.allocator.free(stage_dir);
    var staged = try stageEmpty(ctx, stage_dir);
    defer staged.deinit();

    var p1 = try makeTestPkg(ctx, "pkg-a", "1.0.0", "x86_64", "a" ** 64);
    defer p1.deinit();
    _ = try staged.db.insertPackageTransaction(&p1);

    // Seed shared pool so commit reaches signing phase.
    const pool_dir = try packagePoolDir(ctx);
    defer ctx.allocator.free(pool_dir);
    try path_mod.ensureDirExists(pool_dir);
    const p1_name = try std.fmt.allocPrint(ctx.allocator, "pkg-a-1.0.0-1-x86_64-{s}.pkg.tar.zst", .{"a" ** 64});
    defer ctx.allocator.free(p1_name);
    const p1_pool = try std.fs.path.join(ctx.allocator, &.{ pool_dir, p1_name });
    defer ctx.allocator.free(p1_pool);
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), p1_pool, .{});
        try f.writeStreamingAll(path_mod.currentIo(), "archive-a");
        f.close(path_mod.currentIo());
    }

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out-sign-fail" });
    defer ctx.allocator.free(output_dir);
    try path_mod.ensureDirExists(output_dir);
    const out_db = try std.fs.path.join(ctx.allocator, &.{ output_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(out_db);
    const out_sig = try std.fs.path.join(ctx.allocator, &.{ output_dir, repo_history.REPO_SIG_FILENAME });
    defer ctx.allocator.free(out_sig);

    // Pre-populate output dir with existing db/sig to verify they survive failed publish.
    {
        var pre_db = try RepoDB.init(ctx, out_db, false);
        defer {
            pre_db.deinit();
            ctx.allocator.destroy(pre_db);
        }
        var pre_pkg = try makeTestPkg(ctx, "pkg-pre", "0.1.0", "x86_64", "f" ** 64);
        defer pre_pkg.deinit();
        _ = try pre_db.insertPackageTransaction(&pre_pkg);
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), out_sig, .{ .truncate = true });
        try f.writeStreamingAll(path_mod.currentIo(), "live-sig-before");
        f.close(path_mod.currentIo());
    }

    // Use a non-existent key path so signing temp db must fail.
    const missing_key = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "keys", "missing.key" });
    defer ctx.allocator.free(missing_key);
    ctx.signing_key_path = missing_key;
    try std.testing.expectError(PublishError.FileSystem, staged.commit(output_dir));

    // Live DB should remain readable and unchanged as package count 1.
    var live_db = try RepoDB.init(ctx, out_db, true);
    defer {
        live_db.deinit();
        ctx.allocator.destroy(live_db);
    }
    try std.testing.expectEqual(@as(u32, 1), try countPackages(live_db));

    const sig_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), out_sig, .{});
    defer sig_file.close(path_mod.currentIo());
    var sig_buf: [64]u8 = undefined;
    const n = try sig_file.readPositionalAll(path_mod.currentIo(), &sig_buf, 0);
    try std.testing.expect(std.mem.eql(u8, sig_buf[0..n], "live-sig-before"));
}
