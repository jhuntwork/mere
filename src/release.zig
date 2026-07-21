const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const repository = @import("repository.zig");
const Repository = repository.Repository;
const repodb = @import("repodb.zig");
const repo_history = @import("repo_history.zig");
const package = @import("package.zig");
const hash = @import("hash.zig");
const import_mod = @import("import.zig");
const p = @import("path.zig");
const errors = @import("errors.zig");
const c = repodb.c;

/// Implements specification section 9.9 "Release Publication Requirements":
///
/// 1. Publication builds the output DB from a dev repo as the sole source
///    of truth; the output directory is a write-only target, never read as
///    input.
/// 2. Publication selects packages (all latest by default) applying
///    keep-count retention (default `repo_history.DEFAULT_KEEP_VERSIONS`
///    per (name, arch)).
/// 3. All selected package archives must exist in the dev repo's local
///    archive pool (`<dev-repo>/packages/`); publication fails loudly if any
///    required archive is missing.
/// 4. Publication fails loudly if a dev repo DB row and its corresponding
///    pool archive disagree on archive_hash (the (name, version, release,
///    arch) portion of the tuple match is guaranteed by construction, since
///    the pool path is derived directly from those same DB row fields).
/// 5. Archive filenames (both source pool and published packages/) use
///    `Package.canonicalArchiveName()`:
///    `<name>-<version>-<release>-<arch>-<archive_hash>.pkg.tar.zst`.
const Std = errors.StandardErrors;
pub const ReleaseError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData || Std.SignatureInvalid || error{
    ArchiveMissing,
    ArchiveHashMismatch,
    SigningFailed,
};

/// Select, for every (name, arch) pair present in `db`, the latest
/// `keep_count` versions (vercmp-ordered). Caller owns the returned list and
/// must call `pkg.deinit()` on each element, then `list.deinit(allocator)`.
fn selectPackagesWithRetention(ctx: *Context, db: *repodb.RepoDB, keep_count: u32) ReleaseError!std.ArrayList(package.Package) {
    var pairs = db.getDistinctPackageNameArch(ctx.allocator) catch |err| {
        return switch (err) {
            error.OutOfMemory => ReleaseError.OutOfMemory,
            error.PermissionDenied => ReleaseError.PermissionDenied,
            error.InvalidInput => ReleaseError.InvalidInput,
            error.SignatureInvalid => ReleaseError.SignatureInvalid,
            else => ctx.fail(ReleaseError.FileSystem, "dev repo", "failed to enumerate packages in dev repository"),
        };
    };
    defer {
        for (pairs.items) |pair| {
            ctx.allocator.free(pair.name);
            ctx.allocator.free(pair.arch);
        }
        pairs.deinit(ctx.allocator);
    }

    var selected: std.ArrayList(package.Package) = .empty;
    errdefer {
        for (selected.items) |*pkg| pkg.deinit();
        selected.deinit(ctx.allocator);
    }

    for (pairs.items) |pair| {
        var versions = db.getLatestPackagesByNameArch(ctx.allocator, pair.name, pair.arch, keep_count) catch |err| {
            return switch (err) {
                error.OutOfMemory => ReleaseError.OutOfMemory,
                error.PermissionDenied => ReleaseError.PermissionDenied,
                error.PackageNotFound => ctx.fail(ReleaseError.InvalidInput, pair.name, "package disappeared from dev repository during publish"),
                else => ctx.fail(ReleaseError.FileSystem, pair.name, "failed to select latest package versions"),
            };
        };
        // Ownership of each Package transfers into `selected`; only the
        // backing array of `versions` is released here.
        defer versions.deinit(ctx.allocator);

        for (versions.items) |pkg| {
            selected.append(ctx.allocator, pkg) catch return ReleaseError.OutOfMemory;
        }
    }

    return selected;
}

/// Verify a single selected package's archive is present in the dev repo's
/// pool (requirement 3) and that its actual content hashes to the archive_hash
/// recorded in the dev repo DB (requirement 4). Returns the ctx.allocator-owned
/// absolute path to the verified archive on success.
fn verifySelectedArchive(ctx: *Context, dev_packages_dir: []const u8, pkg: *const package.Package) ReleaseError![]const u8 {
    const canonical_name = pkg.canonicalArchiveName() catch {
        return ctx.fail(ReleaseError.InvalidInput, pkg.name orelse "unknown", "package archive_hash is missing or invalid; cannot derive canonical archive filename");
    };
    defer ctx.allocator.free(canonical_name);

    const source_path = std.fs.path.join(ctx.allocator, &.{ dev_packages_dir, canonical_name }) catch {
        return ReleaseError.OutOfMemory;
    };
    errdefer ctx.allocator.free(source_path);

    std.Io.Dir.accessAbsolute(p.currentIo(), source_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ctx.failFmt(
                ReleaseError.ArchiveMissing,
                pkg.name orelse "unknown",
                "required archive '{s}' not found in dev repo pool ({s})",
                .{ canonical_name, dev_packages_dir },
            ),
            else => ctx.fail(ReleaseError.FileSystem, source_path, "failed to check package archive in dev repo pool"),
        };
    };

    const actual_hash = hash.calculateFileHash(ctx, source_path) catch |err| {
        return switch (err) {
            error.OutOfMemory => ReleaseError.OutOfMemory,
            error.PermissionDenied => ReleaseError.PermissionDenied,
            else => ctx.fail(ReleaseError.FileSystem, source_path, "failed to compute package archive hash"),
        };
    };
    defer ctx.allocator.free(actual_hash);

    if (!std.mem.eql(u8, actual_hash, pkg.archive_hash)) {
        return ctx.failFmt(
            ReleaseError.ArchiveHashMismatch,
            pkg.name orelse "unknown",
            "archive '{s}' hash does not match dev repository database record (expected {s}, computed {s})",
            .{ canonical_name, pkg.archive_hash, actual_hash },
        );
    }

    return source_path;
}

/// Wipe all rows from `db` (packages, dependencies, provisions). Used to
/// rebuild the release output DB from scratch on every publish, since the
/// dev repo is the sole source of truth for what gets published (requirement 1).
fn clearAllPackages(db: *repodb.RepoDB) ReleaseError!void {
    const sqlite_db = db.db orelse return ReleaseError.FileSystem;

    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(sqlite_db, "BEGIN TRANSACTION;", null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return ReleaseError.FileSystem;
    }

    const statements = [_][]const u8{
        "DELETE FROM dependencies;",
        "DELETE FROM provisions;",
        "DELETE FROM packages;",
    };
    for (statements) |stmt_sql| {
        if (c.sqlite3_exec(sqlite_db, stmt_sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            _ = c.sqlite3_exec(sqlite_db, "ROLLBACK;", null, null, null);
            return ReleaseError.FileSystem;
        }
    }

    if (c.sqlite3_exec(sqlite_db, "COMMIT;", null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return ReleaseError.FileSystem;
    }
}

/// Returns true if a package with the same (name, version, release, arch)
/// tuple already exists in the given database.
fn packageExistsInDb(db: *repodb.RepoDB, pkg: *const package.Package) bool {
    var existing = db.getPackageExact(
        pkg.name orelse return false,
        pkg.version orelse return false,
        pkg.release orelse return false,
        pkg.arch orelse return false,
    ) catch return false;
    existing.deinit();
    return true;
}

/// Collect packages that *will* be pruned: those beyond `keep_count` for a
/// given (name, arch) pair, ordered by version descending. These are the
/// packages whose archive files should be deleted from the output directory
/// after pruneOldVersions removes their DB rows.
fn collectPruneCandidates(ctx: *Context, db: *repodb.RepoDB, name: []const u8, arch: []const u8, keep_count: u32) ReleaseError!std.ArrayList(package.Package) {
    // Fetch all packages for this (name, arch), then use version comparison
    // to identify which ones will be pruned (same logic as pruneOldVersions).
    const sqlite_db = db.db orelse return ReleaseError.FileSystem;
    const ver = @import("version.zig");

    const sql =
        \\SELECT name, version, release, arch, archive_hash
        \\FROM packages
        \\WHERE name = ? AND arch = ?
    ;

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sqlite_db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK or stmt == null) {
        return ctx.fail(ReleaseError.FileSystem, name, "failed to prepare prune candidate query");
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    _ = c.sqlite3_bind_text(stmt.?, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt.?, 2, arch.ptr, @intCast(arch.len), c.SQLITE_STATIC);

    const Candidate = struct {
        pkg: package.Package,
        keep: bool,
    };

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |*cand| {
            if (!cand.keep) continue; // kept ones transferred to result
            cand.pkg.deinit();
        }
        candidates.deinit(ctx.allocator);
    }

    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        var pkg = package.Package.init(ctx);
        errdefer pkg.deinit();

        const col_name = c.sqlite3_column_text(stmt.?, 0);
        const col_version = c.sqlite3_column_text(stmt.?, 1);
        const col_release: u32 = @intCast(c.sqlite3_column_int(stmt.?, 2));
        const col_arch = c.sqlite3_column_text(stmt.?, 3);
        const col_hash = c.sqlite3_column_text(stmt.?, 4);

        pkg.name = if (col_name != null) ctx.allocator.dupe(u8, std.mem.span(col_name.?)) catch return ReleaseError.OutOfMemory else null;
        pkg.version = if (col_version != null) ctx.allocator.dupe(u8, std.mem.span(col_version.?)) catch return ReleaseError.OutOfMemory else null;
        pkg.release = col_release;
        pkg.arch = if (col_arch != null) ctx.allocator.dupe(u8, std.mem.span(col_arch.?)) catch return ReleaseError.OutOfMemory else null;
        pkg.archive_hash = if (col_hash != null) ctx.allocator.dupe(u8, std.mem.span(col_hash.?)) catch return ReleaseError.OutOfMemory else "";

        candidates.append(ctx.allocator, .{ .pkg = pkg, .keep = false }) catch return ReleaseError.OutOfMemory;
    }

    if (candidates.items.len <= keep_count) {
        // Nothing to prune — mark all as kept so defer doesn't deinit them,
        // then return empty.
        for (candidates.items) |*cand| cand.keep = true;
        // Actually we need to deinit them since we're not returning them.
        for (candidates.items) |*cand| {
            cand.keep = false; // let defer handle cleanup
        }
        return std.ArrayList(package.Package){ .items = &.{}, .capacity = 0 };
    }

    // Mark the top keep_count by version.
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
                cand.pkg.version orelse "",
                cand.pkg.release orelse 0,
                best.pkg.version orelse "",
                best.pkg.release orelse 0,
            ) catch return ReleaseError.InvalidInput;
            if (cmp == .greater) best_idx = idx;
        }
        if (best_idx) |idx| {
            candidates.items[idx].keep = true;
        } else break;
    }

    // Collect the non-kept packages as prune candidates.
    var result: std.ArrayList(package.Package) = .empty;
    errdefer {
        for (result.items) |*pkg| pkg.deinit();
        result.deinit(ctx.allocator);
    }

    for (candidates.items) |*cand| {
        if (!cand.keep) {
            result.append(ctx.allocator, cand.pkg) catch return ReleaseError.OutOfMemory;
            // Prevent defer from deiniting transferred packages
            cand.pkg = package.Package.init(ctx);
            cand.keep = true;
        }
    }

    return result;
}

/// Publish merges new packages from a dev repo into the production output
/// directory, applies retention, removes orphaned archives, and signs.
///
/// The output directory's existing repo.db is the single source of truth
/// for what is currently published. The dev repo contributes *new* packages
/// only — it is a staging area, not an accumulator. Both paths must be
/// absolute; the caller (CLI layer) is responsible for resolving them.
///
/// Flow:
/// 1. Read all packages from the dev repo (with retention applied to its
///    own contents — only the latest N per name+arch are considered).
/// 2. Verify each selected archive exists and is hash-correct in the dev
///    repo's pool.
/// 3. Bootstrap the output directory if needed.
/// 4. Stage from the output directory's current repo.db (preserving
///    everything already published).
/// 5. Insert new packages (skip any that already exist in the output DB).
/// 6. Apply retention across the full output DB (prune to keep-count per
///    name+arch). Delete orphaned archive files for pruned rows.
/// 7. Sign and commit.
pub fn publish(ctx: *Context, dev_repo_dir: []const u8, output_dir: []const u8) ReleaseError!void {
    var dev_repo = Repository.init(ctx, dev_repo_dir, true) catch |err| {
        return switch (err) {
            error.OutOfMemory => ReleaseError.OutOfMemory,
            error.PermissionDenied => ReleaseError.PermissionDenied,
            error.InvalidInput => ctx.fail(ReleaseError.InvalidInput, dev_repo_dir, "dev repo has no repo.db; nothing to publish"),
            error.CorruptData => ReleaseError.CorruptData,
            error.SignatureInvalid => ReleaseError.SignatureInvalid,
            else => ctx.fail(ReleaseError.FileSystem, dev_repo_dir, "failed to open dev repository"),
        };
    };
    defer dev_repo.deinit();

    var selected = try selectPackagesWithRetention(ctx, dev_repo.db, repo_history.DEFAULT_KEEP_VERSIONS);
    defer {
        for (selected.items) |*pkg| pkg.deinit();
        selected.deinit(ctx.allocator);
    }

    const dev_packages_dir = std.fs.path.join(ctx.allocator, &.{ dev_repo_dir, "packages" }) catch {
        return ReleaseError.OutOfMemory;
    };
    defer ctx.allocator.free(dev_packages_dir);

    // Verify every selected package's archive exists in the dev repo's pool
    // and matches its recorded archive_hash *before* touching the output
    // directory at all, so a bad dev repo state fails loudly without
    // partially publishing anything.
    var source_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (source_paths.items) |sp| ctx.allocator.free(sp);
        source_paths.deinit(ctx.allocator);
    }
    for (selected.items) |*pkg| {
        const source_path = try verifySelectedArchive(ctx, dev_packages_dir, pkg);
        source_paths.append(ctx.allocator, source_path) catch {
            ctx.allocator.free(source_path);
            return ReleaseError.OutOfMemory;
        };
    }

    // Bootstrap the output directory (idempotent: creates repo.db +
    // packages/ with schema if missing, no-ops if already present).
    import_mod.bootstrapRepoSource(ctx, output_dir) catch {
        return ctx.fail(ReleaseError.FileSystem, output_dir, "failed to initialize release output directory");
    };

    // Acquire the output repo's exclusive lock and stage the next db state.
    // stageNext copies the output dir's current repo.db into .next/ — this
    // preserves everything already published.
    var staged = repo_history.stageNext(ctx, output_dir) catch |err| {
        return switch (err) {
            error.OutOfMemory => ReleaseError.OutOfMemory,
            error.PermissionDenied => ReleaseError.PermissionDenied,
            error.InvalidInput => ReleaseError.InvalidInput,
            else => ctx.fail(ReleaseError.FileSystem, output_dir, "failed to stage release output state"),
        };
    };
    defer staged.deinit();

    // Insert new packages from the dev repo. Skip any that already exist
    // in the output DB (same name+version+release+arch tuple).
    for (selected.items, source_paths.items) |*pkg, source_path| {
        const already_exists = packageExistsInDb(staged.db, pkg);
        if (already_exists) continue;

        const dest_path = import_mod.storeArtifactAtomically(ctx, pkg, source_path, output_dir) catch {
            return ctx.fail(ReleaseError.FileSystem, pkg.name orelse "unknown", "failed to publish package archive to release output");
        };
        ctx.allocator.free(dest_path);

        // Carry properties from dev repo through to the release output DB.
        const properties = dev_repo.db.getPackageProperties(
            ctx.allocator,
            pkg.name orelse "",
            pkg.version orelse "",
            pkg.release orelse 0,
            pkg.arch orelse "",
        ) catch null;
        defer if (properties) |props| ctx.allocator.free(props);

        _ = staged.db.insertPackageTransaction(pkg, properties) catch |err| {
            return switch (err) {
                error.OutOfMemory => ReleaseError.OutOfMemory,
                error.InvalidInput => ctx.fail(ReleaseError.InvalidInput, pkg.name orelse "unknown", "package data is invalid; cannot insert into release output database"),
                else => ctx.fail(ReleaseError.CorruptData, pkg.name orelse "unknown", "failed to insert package into release output database"),
            };
        };
    }

    // Apply retention across the full output DB. Collect the set of
    // (name, arch) pairs that might need pruning — both from newly
    // inserted packages and from everything already in the DB.
    const output_packages_dir = std.fs.path.join(ctx.allocator, &.{ output_dir, "packages" }) catch {
        return ReleaseError.OutOfMemory;
    };
    defer ctx.allocator.free(output_packages_dir);

    var pairs = staged.db.getDistinctPackageNameArch(ctx.allocator) catch |err| {
        return switch (err) {
            error.OutOfMemory => ReleaseError.OutOfMemory,
            else => ctx.fail(ReleaseError.FileSystem, output_dir, "failed to enumerate packages for retention"),
        };
    };
    defer {
        for (pairs.items) |pair| {
            ctx.allocator.free(pair.name);
            ctx.allocator.free(pair.arch);
        }
        pairs.deinit(ctx.allocator);
    }

    for (pairs.items) |pair| {
        // Collect packages that will be pruned (beyond keep-count) so we
        // can delete their archive files after removing the DB rows.
        var to_prune = try collectPruneCandidates(ctx, staged.db, pair.name, pair.arch, repo_history.DEFAULT_KEEP_VERSIONS);
        defer {
            for (to_prune.items) |*pkg| pkg.deinit();
            to_prune.deinit(ctx.allocator);
        }

        if (to_prune.items.len == 0) continue;

        // Prune DB rows.
        _ = repo_history.pruneOldVersions(
            staged.db,
            pair.name,
            pair.arch,
            repo_history.DEFAULT_KEEP_VERSIONS,
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => ReleaseError.OutOfMemory,
                else => ctx.fail(ReleaseError.FileSystem, pair.name, "failed to prune old package versions"),
            };
        };

        // Delete orphaned archive files for pruned packages.
        for (to_prune.items) |*pruned_pkg| {
            const canonical_name = pruned_pkg.canonicalArchiveName() catch continue;
            defer ctx.allocator.free(canonical_name);
            const archive_path = std.fs.path.join(ctx.allocator, &.{ output_packages_dir, canonical_name }) catch continue;
            defer ctx.allocator.free(archive_path);
            std.Io.Dir.deleteFileAbsolute(p.currentIo(), archive_path) catch {};
        }
    }

    staged.commit() catch {
        return ctx.fail(ReleaseError.SigningFailed, output_dir, "failed to sign and activate release output database");
    };
}

/// Test helper: insert a package row directly into a dev repo's DB (bypassing
/// `mere dev import`'s own auto-prune, so tests can build a dev repo state
/// with more than `DEFAULT_KEEP_VERSIONS` rows of a (name, arch) to exercise
/// `publish`'s own retention independent of import-time pruning) and place a
/// matching archive file at the canonical pool path, hashed correctly so
/// verifySelectedArchive's hash check passes by default. `content` is the
/// pool file's exact bytes; tests that want a hash mismatch write different
/// bytes to the file after calling this.
fn insertFakeDevPackage(
    ctx: *Context,
    dev_repo_dir: []const u8,
    name: []const u8,
    version: []const u8,
    arch: []const u8,
    content: []const u8,
) !void {
    var repo = try Repository.init(ctx, dev_repo_dir, false);
    defer repo.deinit();

    const archive_hash_hex = try hash.calculateBytesHash(ctx.allocator, content);
    defer ctx.allocator.free(archive_hash_hex);

    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, version);
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, arch);
    pkg.content_hash = try ctx.allocator.dupe(u8, "deadbeef");
    pkg.archive_hash = try ctx.allocator.dupe(u8, archive_hash_hex);
    pkg.signature = try ctx.allocator.dupe(u8, "aa" ** 64);

    _ = try repo.db.insertPackageTransaction(&pkg, null);

    const packages_dir = try std.fs.path.join(ctx.allocator, &.{ dev_repo_dir, "packages" });
    defer ctx.allocator.free(packages_dir);
    try p.ensureDirExists(packages_dir);

    const canonical_name = try pkg.canonicalArchiveName();
    defer ctx.allocator.free(canonical_name);
    const archive_path = try std.fs.path.join(ctx.allocator, &.{ packages_dir, canonical_name });
    defer ctx.allocator.free(archive_path);

    var f = try std.Io.Dir.createFileAbsolute(p.currentIo(), archive_path, .{});
    defer f.close(p.currentIo());
    try f.writeStreamingAll(p.currentIo(), content);
}

test "publish carries real imported packages through to a signed release output" {
    const th = @import("test_helpers.zig");
    const sign_mod = @import("sign.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;

    // End-to-end sanity check through the *real* `mere dev import` pipeline
    // (signed manifest, projection index, content hash) for two unrelated
    // packages, confirming publish carries both through correctly.
    for ([_][]const u8{ "alpha", "beta" }, 0..) |name, idx| {
        var pkg = package.Package.init(ctx);
        defer pkg.deinit();
        pkg.name = try ctx.allocator.dupe(u8, name);
        pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
        pkg.release = 1;
        pkg.arch = try ctx.allocator.dupe(u8, "x86_64");

        const archive_name = try std.fmt.allocPrint(ctx.allocator, "{s}-{d}.tar", .{ name, idx });
        defer ctx.allocator.free(archive_name);

        const result = try th.setupTestImport(ctx, &pkg, test_env, archive_name);
        ctx.allocator.free(result.db_path);
        ctx.allocator.free(result.pkg_path);
        ctx.allocator.free(result.secret_key_path);
    }

    const dev_repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", "import" });
    defer ctx.allocator.free(dev_repo_dir);
    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "release-output" });
    defer ctx.allocator.free(output_dir);

    try publish(ctx, dev_repo_dir, output_dir);

    var out_repo = try Repository.init(ctx, output_dir, true);
    defer out_repo.deinit();

    for ([_][]const u8{ "alpha", "beta" }) |name| {
        var found = try out_repo.db.getPackagesByName(ctx.allocator, name);
        defer {
            for (found.items) |*pk| pk.deinit();
            found.deinit(ctx.allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), found.items.len);

        const canonical_name = try found.items[0].canonicalArchiveName();
        defer ctx.allocator.free(canonical_name);
        const archive_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages", canonical_name });
        defer ctx.allocator.free(archive_path);
        try std.Io.Dir.accessAbsolute(p.currentIo(), archive_path, .{});
    }

    const pub_key_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, ".mere", "keys", "mere.pub" });
    defer ctx.allocator.free(pub_key_path);
    try sign_mod.verifySignature(ctx, out_repo.dbPath(), pub_key_path, out_repo.sigPath());
}

test "publish applies its own keep-count retention independent of dev-repo import-time pruning" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;

    const dev_repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "dev-repo" });
    defer ctx.allocator.free(dev_repo_dir);

    // Insert 5 versions of "widget" directly (bypassing `mere dev import`'s
    // own auto-prune-to-3), so the dev repo genuinely holds more rows than
    // DEFAULT_KEEP_VERSIONS when publish runs. Also one unrelated package.
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        const version = try std.fmt.allocPrint(ctx.allocator, "1.0.{d}", .{i});
        defer ctx.allocator.free(version);
        const content = try std.fmt.allocPrint(ctx.allocator, "widget contents v{d}", .{i});
        defer ctx.allocator.free(content);
        try insertFakeDevPackage(ctx, dev_repo_dir, "widget", version, "x86_64", content);
    }
    try insertFakeDevPackage(ctx, dev_repo_dir, "gadget", "2.3.0", "x86_64", "gadget contents");

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "release-output" });
    defer ctx.allocator.free(output_dir);

    try publish(ctx, dev_repo_dir, output_dir);

    var out_repo = try Repository.init(ctx, output_dir, true);
    defer out_repo.deinit();

    var widgets = try out_repo.db.getPackagesByName(ctx.allocator, "widget");
    defer {
        for (widgets.items) |*pk| pk.deinit();
        widgets.deinit(ctx.allocator);
    }
    try std.testing.expectEqual(@as(usize, repo_history.DEFAULT_KEEP_VERSIONS), @as(u32, @intCast(widgets.items.len)));

    // Exactly the top 3 of 5 versions (1.0.3, 1.0.4, 1.0.5) must remain.
    for ([_][]const u8{ "1.0.1", "1.0.2" }) |dropped_version| {
        for (widgets.items) |w| {
            try std.testing.expect(!std.mem.eql(u8, w.version.?, dropped_version));
        }
    }
    for ([_][]const u8{ "1.0.3", "1.0.4", "1.0.5" }) |kept_version| {
        var seen = false;
        for (widgets.items) |w| {
            if (std.mem.eql(u8, w.version.?, kept_version)) seen = true;
        }
        try std.testing.expect(seen);
    }

    var gadgets = try out_repo.db.getPackagesByName(ctx.allocator, "gadget");
    defer {
        for (gadgets.items) |*pk| pk.deinit();
        gadgets.deinit(ctx.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), gadgets.items.len);
}

test "publish fails loudly when a selected archive is missing from the dev repo pool" {
    var test_env = try (@import("test_helpers.zig")).createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;

    const dev_repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "dev-repo" });
    defer ctx.allocator.free(dev_repo_dir);
    try insertFakeDevPackage(ctx, dev_repo_dir, "widget", "1.0.0", "x86_64", "widget contents");

    // Delete the archive from the dev repo's pool to simulate a corrupted /
    // incomplete dev repo state (requirement 3: fail loudly, don't publish).
    {
        var repo = try Repository.init(ctx, dev_repo_dir, true);
        defer repo.deinit();
        var stored = try repo.db.getPackageExact("widget", "1.0.0", 1, "x86_64");
        defer stored.deinit();
        const canonical_name = try stored.canonicalArchiveName();
        defer ctx.allocator.free(canonical_name);
        const archive_path = try std.fs.path.join(ctx.allocator, &.{ dev_repo_dir, "packages", canonical_name });
        defer ctx.allocator.free(archive_path);
        try std.Io.Dir.deleteFileAbsolute(p.currentIo(), archive_path);
    }

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "release-output" });
    defer ctx.allocator.free(output_dir);

    try std.testing.expectError(ReleaseError.ArchiveMissing, publish(ctx, dev_repo_dir, output_dir));
    ctx.resetDiagnostics();

    // Archive verification happens before the output directory is ever
    // touched, so a failure here must leave it completely untouched.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(p.currentIo(), output_dir, .{}));
}

test "publish fails loudly when a selected archive's content does not match its recorded archive_hash" {
    var test_env = try (@import("test_helpers.zig")).createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;

    const dev_repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "dev-repo" });
    defer ctx.allocator.free(dev_repo_dir);
    try insertFakeDevPackage(ctx, dev_repo_dir, "widget", "1.0.0", "x86_64", "widget contents");

    // Corrupt the pool archive's content in place (same filename/path, since
    // the canonical name is derived from the DB row's own archive_hash, not
    // from the file's actual content) to simulate on-disk tampering or
    // corruption (requirement 4: fail loudly on db/archive mismatch).
    {
        var repo = try Repository.init(ctx, dev_repo_dir, true);
        defer repo.deinit();
        var stored = try repo.db.getPackageExact("widget", "1.0.0", 1, "x86_64");
        defer stored.deinit();
        const canonical_name = try stored.canonicalArchiveName();
        defer ctx.allocator.free(canonical_name);
        const archive_path = try std.fs.path.join(ctx.allocator, &.{ dev_repo_dir, "packages", canonical_name });
        defer ctx.allocator.free(archive_path);

        var f = try std.Io.Dir.createFileAbsolute(p.currentIo(), archive_path, .{ .truncate = true });
        defer f.close(p.currentIo());
        try f.writeStreamingAll(p.currentIo(), "corrupted contents, does not match archive_hash");
    }

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "release-output" });
    defer ctx.allocator.free(output_dir);

    try std.testing.expectError(ReleaseError.ArchiveHashMismatch, publish(ctx, dev_repo_dir, output_dir));
    ctx.resetDiagnostics();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(p.currentIo(), output_dir, .{}));
}

test "publish carries properties from dev repo through to release output" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;

    const dev_repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", "import" });
    defer ctx.allocator.free(dev_repo_dir);

    // Insert a package with properties JSON into the dev repo.
    const properties_json = "{\"description\":\"Test package\",\"url\":\"https://example.com\",\"licenses\":[\"MIT\"]}";
    {
        var repo = try Repository.init(ctx, dev_repo_dir, false);
        defer repo.deinit();

        const content = "fake archive content for properties test";
        const archive_hash_hex = try hash.calculateBytesHash(ctx.allocator, content);
        defer ctx.allocator.free(archive_hash_hex);

        var pkg = package.Package.init(ctx);
        defer pkg.deinit();
        pkg.name = try ctx.allocator.dupe(u8, "proptest");
        pkg.version = try ctx.allocator.dupe(u8, "2.0.0");
        pkg.release = 1;
        pkg.arch = try ctx.allocator.dupe(u8, @import("builtin").cpu.arch.genericName());
        pkg.content_hash = try ctx.allocator.dupe(u8, "deadbeef");
        pkg.archive_hash = try ctx.allocator.dupe(u8, archive_hash_hex);
        pkg.signature = try ctx.allocator.dupe(u8, "aa" ** 64);

        _ = try repo.db.insertPackageTransaction(&pkg, properties_json);

        // Place a matching archive file so verifySelectedArchive passes.
        const packages_dir = try std.fs.path.join(ctx.allocator, &.{ dev_repo_dir, "packages" });
        defer ctx.allocator.free(packages_dir);
        try p.ensureDirExists(packages_dir);

        const canonical_name = try pkg.canonicalArchiveName();
        defer ctx.allocator.free(canonical_name);
        const archive_path = try std.fs.path.join(ctx.allocator, &.{ packages_dir, canonical_name });
        defer ctx.allocator.free(archive_path);
        try p.writeFileAbsolute(archive_path, content);
    }

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "release-output" });
    defer ctx.allocator.free(output_dir);

    try publish(ctx, dev_repo_dir, output_dir);

    // Verify properties arrived in the output repo.db.
    var out_repo = try Repository.init(ctx, output_dir, true);
    defer out_repo.deinit();

    const got_props = try out_repo.db.getPackageProperties(
        ctx.allocator,
        "proptest",
        "2.0.0",
        1,
        @import("builtin").cpu.arch.genericName(),
    );
    defer if (got_props) |gp| ctx.allocator.free(gp);

    try std.testing.expect(got_props != null);
    try std.testing.expectEqualStrings(properties_json, got_props.?);
}
