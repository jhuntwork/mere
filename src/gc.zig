// Garbage Collection
//
// This module implements the filesystem-driven GC root and reachability model.
//
// GC is filesystem-driven and does not perform transitive dependency closure at GC time.
// A generation is already the realized closure of what's needed—all store paths referenced
// by the profile. GC keeps exactly what generations/pins reference.
//
// Algorithm:
// 1. Collect reachable set from gc-roots symlinks
// 2. Enumerate candidates in /mere/store/
// 3. Delete unreachable store objects
// 4. Delete unreferenced package archives from /mere/cache/packages
// 5. Prune unkept generations

const std = @import("std");
const generation = @import("generation.zig");
const gcroots = @import("gcroots.zig");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const package_mod = @import("package.zig");
const repodb = @import("repodb.zig");
const repo_history = @import("repo_history.zig");

/// GC error set
const Std = errors.StandardErrors;
pub const GCError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || error{
    NoRoots, // No GC roots found (dangerous to proceed)
    LockFailed,
};

fn mapGcFsError(err: anyerror) GCError {
    return switch (err) {
        error.OutOfMemory => GCError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => GCError.PermissionDenied,
        else => GCError.FileSystem,
    };
}

/// Result of a GC operation
pub const GCResult = struct {
    deleted_paths: std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GCResult {
        return GCResult{
            .deleted_paths = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GCResult) void {
        for (self.deleted_paths.items) |path| {
            self.allocator.free(path);
        }
        self.deleted_paths.deinit(self.allocator);
    }

    /// Add a path to the deleted list
    pub fn addDeleted(self: *GCResult, path: []const u8) GCError!void {
        const owned = self.allocator.dupe(u8, path) catch {
            return GCError.OutOfMemory;
        };
        self.deleted_paths.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return GCError.OutOfMemory;
        };
    }
};

/// Options for garbage collection
pub const GCOptions = struct {
    /// If true, don't actually delete anything, just report what would be deleted
    dry_run: bool = false,
};

/// Perform garbage collection.
///
/// Deletes store paths that are not reachable from any GC root.
pub fn collectGarbage(
    ctx: *mere.Context,
    options: GCOptions,
) GCError!GCResult {
    const allocator = ctx.allocator;
    const gc_roots_dir = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return ctx.fail(GCError.OutOfMemory, ctx.root_path, "out of memory building gc-roots path");
    };
    defer allocator.free(gc_roots_dir);

    const store_dir = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(GCError.OutOfMemory, ctx.root_path, "out of memory building store path");
    };
    defer allocator.free(store_dir);

    const profiles_dir = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return ctx.fail(GCError.OutOfMemory, ctx.root_path, "out of memory building profiles path");
    };
    defer allocator.free(profiles_dir);

    const package_pool_dir = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "cache", "packages" }) catch {
        return ctx.fail(GCError.OutOfMemory, ctx.root_path, "out of memory building package pool path");
    };
    defer allocator.free(package_pool_dir);

    const repo_root_dir = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "dev", "repo" }) catch {
        return ctx.fail(GCError.OutOfMemory, ctx.root_path, "out of memory building repo root path");
    };
    defer allocator.free(repo_root_dir);

    return collectGarbageAtPathsWithPackagePool(ctx, gc_roots_dir, store_dir, profiles_dir, package_pool_dir, repo_root_dir, options);
}

fn collectGarbageAtPaths(
    ctx: *mere.Context,
    gc_roots_dir: []const u8,
    store_dir: []const u8,
    profiles_dir: []const u8,
    options: GCOptions,
) GCError!GCResult {
    return collectGarbageAtPathsWithPackagePool(ctx, gc_roots_dir, store_dir, profiles_dir, null, null, options);
}

fn collectGarbageAtPathsWithPackagePool(
    ctx: *mere.Context,
    gc_roots_dir: []const u8,
    store_dir: []const u8,
    profiles_dir: []const u8,
    package_pool_dir: ?[]const u8,
    repo_root_dir: ?[]const u8,
    options: GCOptions,
) GCError!GCResult {
    const allocator = ctx.allocator;
    var result = GCResult.init(allocator);
    errdefer result.deinit();

    // Step 1: Collect reachable store paths from gc-roots
    var reachable = try collectReachable(ctx, gc_roots_dir);
    defer {
        var iter = reachable.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        reachable.deinit();
    }

    // Safety check: refuse to run if no roots exist
    if (reachable.count() == 0) {
        return ctx.fail(GCError.NoRoots, gc_roots_dir, "no GC roots found");
    }

    // Step 2: Enumerate store candidates
    var store_handle_opt: ?std.fs.Dir = null;
    store_handle_opt = std.fs.openDirAbsolute(store_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        error.AccessDenied => return ctx.fail(GCError.PermissionDenied, store_dir, "permission denied opening store directory"),
        else => return ctx.fail(GCError.FileSystem, store_dir, "failed to open store directory"),
    };
    if (store_handle_opt) |*store_handle| {
        defer store_handle.close();

        var iter = store_handle.iterate();
        while (true) {
            const entry = iter.next() catch |err| {
                return ctx.fail(mapGcFsError(err), store_dir, "failed to iterate store directory");
            };
            if (entry == null) break;
            const e = entry.?;

            // Only consider directories (don't follow symlinks)
            if (e.kind != .directory) continue;

            // Skip the .incoming staging directory (used during package installation)
            if (std.mem.eql(u8, e.name, ".incoming")) continue;

            // Build full store path
            const store_path = std.fs.path.join(allocator, &.{ store_dir, e.name }) catch {
                return ctx.fail(GCError.OutOfMemory, store_dir, "out of memory building store path");
            };
            defer allocator.free(store_path);

            // Check if reachable
            if (reachable.contains(store_path)) {
                continue; // Keep it
            }

            // Not reachable - candidate for deletion
            result.addDeleted(store_path) catch {
                return ctx.fail(GCError.OutOfMemory, store_path, "out of memory recording deleted path");
            };

            if (!options.dry_run) {
                // Make directory writable before deletion (store paths are read-only)
                makeWritable(store_path);
                // Actually delete
                std.fs.deleteTreeAbsolute(store_path) catch |err| {
                    switch (err) {
                        error.AccessDenied => return ctx.fail(GCError.PermissionDenied, store_path, "permission denied deleting store path"),
                        else => return ctx.fail(GCError.FileSystem, store_path, "failed to delete store path"),
                    }
                };
            }
        }
    }

    // Step 4: Prune unreferenced package archives
    if (package_pool_dir) |pool_dir| {
        const root_dir = repo_root_dir orelse return ctx.fail(GCError.FileSystem, pool_dir, "missing repo root for package pool GC");
        try prunePackagePool(ctx, pool_dir, root_dir, options, &result);
    }

    // Step 5: Prune unkept generations
    try pruneGenerations(ctx, profiles_dir, gcroots.DEFAULT_RETENTION_COUNT, options, &result);

    return result;
}

fn prunePackagePool(
    ctx: *mere.Context,
    package_pool_dir: []const u8,
    repo_root_dir: []const u8,
    options: GCOptions,
    result: *GCResult,
) GCError!void {
    const allocator = ctx.allocator;
    var referenced = try collectReferencedPackageArchives(ctx, repo_root_dir);
    defer {
        var iter = referenced.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        referenced.deinit();
    }

    var pool_dir_opt: ?std.fs.Dir = null;
    pool_dir_opt = std.fs.openDirAbsolute(package_pool_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        error.AccessDenied => return ctx.fail(GCError.PermissionDenied, package_pool_dir, "permission denied opening package pool"),
        else => return ctx.fail(GCError.FileSystem, package_pool_dir, "failed to open package pool"),
    };
    if (pool_dir_opt) |*pool_dir| {
        defer pool_dir.close();

        var iter = pool_dir.iterate();
        while (true) {
            const entry = iter.next() catch |err| {
                return ctx.fail(mapGcFsError(err), package_pool_dir, "failed to iterate package pool");
            };
            if (entry == null) break;
            const e = entry.?;

            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".pkg.tar.zst")) continue;
            if (referenced.contains(e.name)) continue;

            const archive_path = std.fs.path.join(allocator, &.{ package_pool_dir, e.name }) catch {
                return ctx.fail(GCError.OutOfMemory, package_pool_dir, "out of memory building package archive path");
            };
            defer allocator.free(archive_path);

            result.addDeleted(archive_path) catch {
                return ctx.fail(GCError.OutOfMemory, archive_path, "out of memory recording deleted package archive");
            };

            if (!options.dry_run) {
                std.fs.deleteFileAbsolute(archive_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    error.AccessDenied => return ctx.fail(GCError.PermissionDenied, archive_path, "permission denied deleting package archive"),
                    else => return ctx.fail(GCError.FileSystem, archive_path, "failed to delete package archive"),
                };
            }
        }
    }
}

fn collectReferencedPackageArchives(
    ctx: *mere.Context,
    repo_root_dir: []const u8,
) GCError!std.StringHashMap(void) {
    const allocator = ctx.allocator;
    var referenced = std.StringHashMap(void).init(allocator);
    errdefer {
        var iter = referenced.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        referenced.deinit();
    }

    var repo_root_opt: ?std.fs.Dir = null;
    repo_root_opt = std.fs.openDirAbsolute(repo_root_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        error.AccessDenied => return ctx.fail(GCError.PermissionDenied, repo_root_dir, "permission denied opening repo root"),
        else => return ctx.fail(GCError.FileSystem, repo_root_dir, "failed to open repo root"),
    };
    if (repo_root_opt) |*repo_root| {
        defer repo_root.close();

        var iter = repo_root.iterate();
        while (true) {
            const entry = iter.next() catch |err| {
                return ctx.fail(mapGcFsError(err), repo_root_dir, "failed to iterate repo root");
            };
            if (entry == null) break;
            const e = entry.?;

            if (e.kind != .directory) continue;

            const repo_dir = std.fs.path.join(allocator, &.{ repo_root_dir, e.name }) catch {
                return ctx.fail(GCError.OutOfMemory, repo_root_dir, "out of memory building repo path");
            };
            defer allocator.free(repo_dir);

            const current_db_path = std.fs.path.join(allocator, &.{ repo_dir, repo_history.CURRENT_STATE_DIR, repo_history.REPO_DB_FILENAME }) catch {
                return ctx.fail(GCError.OutOfMemory, repo_dir, "out of memory building current repo db path");
            };
            defer allocator.free(current_db_path);
            try collectReferencedPackageArchivesFromDb(ctx, current_db_path, &referenced);

            const previous_db_path = std.fs.path.join(allocator, &.{ repo_dir, repo_history.PREVIOUS_STATE_DIR, repo_history.REPO_DB_FILENAME }) catch {
                return ctx.fail(GCError.OutOfMemory, repo_dir, "out of memory building previous repo db path");
            };
            defer allocator.free(previous_db_path);
            try collectReferencedPackageArchivesFromDb(ctx, previous_db_path, &referenced);
        }
    }

    return referenced;
}

fn collectReferencedPackageArchivesFromDb(
    ctx: *mere.Context,
    db_path: []const u8,
    referenced: *std.StringHashMap(void),
) GCError!void {
    std.fs.accessAbsolute(db_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        error.AccessDenied => return ctx.fail(GCError.PermissionDenied, db_path, "permission denied accessing repository database"),
        else => return ctx.fail(GCError.FileSystem, db_path, "failed to access repository database"),
    };

    var db = repodb.RepoDB.init(ctx, db_path, true) catch |err| {
        return switch (err) {
            error.OutOfMemory => ctx.fail(GCError.OutOfMemory, db_path, "failed to open repository database"),
            error.PermissionDenied => ctx.fail(GCError.PermissionDenied, db_path, "permission denied opening repository database"),
            else => ctx.fail(GCError.FileSystem, db_path, "failed to open repository database"),
        };
    };
    defer {
        db.deinit();
        ctx.allocator.destroy(db);
    }

    const sqlite_db = db.db orelse return ctx.fail(GCError.FileSystem, db_path, "repository database is not open");
    const sql = "SELECT name, version, release, arch, archive_hash FROM packages;";
    var stmt: ?*repodb.c.sqlite3_stmt = null;
    const prepare_rc = repodb.c.sqlite3_prepare_v2(sqlite_db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (prepare_rc != repodb.c.SQLITE_OK or stmt == null) {
        return ctx.fail(GCError.FileSystem, db_path, "failed to query package archive references");
    }
    defer _ = repodb.c.sqlite3_finalize(stmt.?);

    while (true) {
        const step = repodb.c.sqlite3_step(stmt.?);
        if (step == repodb.c.SQLITE_DONE) break;
        if (step != repodb.c.SQLITE_ROW) {
            return ctx.fail(GCError.FileSystem, db_path, "failed to read package archive references");
        }

        const name_c = repodb.c.sqlite3_column_text(stmt.?, 0);
        const version_c = repodb.c.sqlite3_column_text(stmt.?, 1);
        const release = repodb.c.sqlite3_column_int(stmt.?, 2);
        const arch_c = repodb.c.sqlite3_column_text(stmt.?, 3);
        const archive_hash_c = repodb.c.sqlite3_column_text(stmt.?, 4);

        if (name_c == null or version_c == null or arch_c == null or archive_hash_c == null) {
            return ctx.fail(GCError.FileSystem, db_path, "package row missing canonical archive fields");
        }

        const archive_hash = std.mem.span(archive_hash_c);
        if (!isValidArchiveHash(archive_hash)) {
            return ctx.fail(GCError.FileSystem, archive_hash, "package row has invalid archive_hash");
        }

        const archive_name = std.fmt.allocPrint(
            ctx.allocator,
            "{s}-{s}-{d}-{s}-{s}.pkg.tar.zst",
            .{
                std.mem.span(name_c),
                std.mem.span(version_c),
                @as(u32, @intCast(release)),
                std.mem.span(arch_c),
                archive_hash,
            },
        ) catch {
            return ctx.fail(GCError.OutOfMemory, db_path, "out of memory building archive name");
        };
        defer ctx.allocator.free(archive_name);

        try addReferencedArchiveName(ctx, referenced, archive_name);
    }
}

fn addReferencedArchiveName(
    ctx: *mere.Context,
    referenced: *std.StringHashMap(void),
    archive_name: []const u8,
) GCError!void {
    if (referenced.contains(archive_name)) return;

    const owned = ctx.allocator.dupe(u8, archive_name) catch {
        return ctx.fail(GCError.OutOfMemory, archive_name, "out of memory recording referenced package archive");
    };
    referenced.put(owned, {}) catch {
        ctx.allocator.free(owned);
        return ctx.fail(GCError.OutOfMemory, archive_name, "out of memory recording referenced package archive");
    };
}

fn isValidArchiveHash(archive_hash: []const u8) bool {
    if (archive_hash.len != 64) return false;
    for (archive_hash) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex) return false;
    }
    return true;
}

fn pruneGenerations(
    ctx: *mere.Context,
    profiles_dir: []const u8,
    retention_count: u32,
    options: GCOptions,
    result: *GCResult,
) GCError!void {
    const allocator = ctx.allocator;
    var profiles_handle = std.fs.openDirAbsolute(profiles_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => return, // No profiles directory = nothing to prune
            error.AccessDenied => ctx.fail(GCError.PermissionDenied, profiles_dir, "permission denied opening profiles directory"),
            else => ctx.fail(GCError.FileSystem, profiles_dir, "failed to open profiles directory"),
        };
    };
    defer profiles_handle.close();

    var iter = profiles_handle.iterate();
    while (true) {
        const entry = iter.next() catch |err| {
            return ctx.fail(mapGcFsError(err), profiles_dir, "failed to iterate profiles directory");
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind != .directory) continue;

        const profile_dir = std.fs.path.join(allocator, &.{ profiles_dir, e.name }) catch {
            return ctx.fail(GCError.OutOfMemory, profiles_dir, "out of memory building profile path");
        };
        defer allocator.free(profile_dir);

        const all_gens = generation.listGenerations(allocator, profile_dir) catch |err| switch (err) {
            generation.GenerationError.OutOfMemory => return ctx.fail(GCError.OutOfMemory, profile_dir, "out of memory listing generations"),
            generation.GenerationError.PermissionDenied => return ctx.fail(GCError.PermissionDenied, profile_dir, "permission denied listing generations"),
            else => return ctx.fail(GCError.FileSystem, profile_dir, "failed to list generations"),
        };
        defer allocator.free(all_gens);

        if (all_gens.len == 0) continue;

        const kept_gens = gcroots.getKeptGenerations(allocator, profile_dir, retention_count) catch |err| switch (err) {
            gcroots.GCRootsError.OutOfMemory => return ctx.fail(GCError.OutOfMemory, profile_dir, "out of memory determining kept generations"),
            gcroots.GCRootsError.PermissionDenied => return ctx.fail(GCError.PermissionDenied, profile_dir, "permission denied reading keep markers"),
            else => return ctx.fail(GCError.FileSystem, profile_dir, "failed to determine kept generations"),
        };
        defer allocator.free(kept_gens);

        const current_gen = try readCurrentGeneration(ctx, profile_dir);

        for (all_gens) |gen| {
            if (isKeptGeneration(gen, current_gen, kept_gens)) continue;

            const gen_path = generation.getGenerationPath(allocator, profile_dir, gen) catch {
                return ctx.fail(GCError.OutOfMemory, profile_dir, "out of memory building generation path");
            };
            defer allocator.free(gen_path);

            result.addDeleted(gen_path) catch {
                return ctx.fail(GCError.OutOfMemory, gen_path, "out of memory recording deleted path");
            };

            if (!options.dry_run) {
                std.fs.deleteTreeAbsolute(gen_path) catch |err| {
                    return switch (err) {
                        error.AccessDenied => ctx.fail(GCError.PermissionDenied, gen_path, "permission denied deleting generation"),
                        else => ctx.fail(GCError.FileSystem, gen_path, "failed to delete generation"),
                    };
                };
            }
        }
    }
}

fn isKeptGeneration(gen: u32, current: ?u32, kept: []const u32) bool {
    if (current) |cur| {
        if (gen == cur) return true;
    }
    for (kept) |k| {
        if (gen == k) return true;
    }
    return false;
}

fn readCurrentGeneration(ctx: *mere.Context, profile_dir: []const u8) GCError!?u32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ profile_dir, generation.CURRENT_SYMLINK }) catch {
        return ctx.fail(GCError.FileSystem, profile_dir, "failed to build current symlink path");
    };

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(current_path, &target_buf) catch |err| {
        return switch (err) {
            error.FileNotFound => null,
            error.AccessDenied => ctx.fail(GCError.PermissionDenied, current_path, "permission denied reading current symlink"),
            else => ctx.fail(GCError.FileSystem, current_path, "failed to read current symlink"),
        };
    };

    return generation.parseGenerationNumber(target);
}

/// Make a directory and its contents writable (to allow deletion).
/// Best-effort: silently ignores failures since we'll try to delete anyway.
fn makeWritable(dir_path: []const u8) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(std.heap.page_allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .directory) {
            var subdir = dir.openDir(entry.path, .{}) catch continue;
            defer subdir.close();
            const stat = subdir.stat() catch continue;
            subdir.chmod(stat.mode | 0o200) catch {}; // Add write bit for owner
        } else {
            var file = dir.openFile(entry.path, .{ .mode = .read_write }) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            file.chmod(stat.mode | 0o200) catch {}; // Add write bit for owner
        }
    }

    // Also chmod the directory itself
    const stat = dir.stat() catch return;
    dir.chmod(stat.mode | 0o200) catch {};
}

/// Collect all reachable store paths from GC roots.
///
/// Returns a set of store paths that should be kept.
/// Walks the nested structure: gc-roots/profiles/<name>/{current, kept/gen-N}
fn collectReachable(
    ctx: *mere.Context,
    gc_roots_dir: []const u8,
) GCError!std.StringHashMap(void) {
    const allocator = ctx.allocator;
    var reachable = std.StringHashMap(void).init(allocator);
    errdefer {
        var iter = reachable.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        reachable.deinit();
    }

    // Open gc-roots directory
    var dir = std.fs.openDirAbsolute(gc_roots_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => reachable, // No roots dir = no roots
            error.AccessDenied => ctx.fail(GCError.PermissionDenied, gc_roots_dir, "permission denied opening gc-roots"),
            else => ctx.fail(GCError.FileSystem, gc_roots_dir, "failed to open gc-roots"),
        };
    };
    defer dir.close();

    // Walk the gc-roots directory recursively to find all symlinks
    var walker = dir.walk(allocator) catch |err| {
        return ctx.fail(mapGcFsError(err), gc_roots_dir, "failed to walk gc-roots");
    };
    defer walker.deinit();

    while (walker.next() catch |err| {
        return ctx.fail(mapGcFsError(err), gc_roots_dir, "failed to iterate gc-roots");
    }) |entry| {
        // Only process symlinks (skip .note files, directories, etc)
        if (entry.kind != .sym_link) continue;

        // Build full path to the symlink
        const root_path = std.fs.path.join(allocator, &.{ gc_roots_dir, entry.path }) catch {
            return ctx.fail(GCError.OutOfMemory, gc_roots_dir, "out of memory building gc-root path");
        };
        defer allocator.free(root_path);

        // Read symlink target
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.readLinkAbsolute(root_path, &target_buf) catch |err| {
            switch (err) {
                error.FileNotFound => continue,
                error.AccessDenied => return ctx.fail(GCError.PermissionDenied, root_path, "permission denied reading gc-root"),
                else => return ctx.fail(GCError.FileSystem, root_path, "failed to read gc-root"),
            }
        };

        var resolved_target: []const u8 = target;
        var resolved_owned: ?[]const u8 = null;
        if (!std.fs.path.isAbsolute(target)) {
            const base_dir = std.fs.path.dirname(root_path) orelse gc_roots_dir;
            resolved_owned = std.fs.path.resolvePosix(allocator, &.{ base_dir, target }) catch {
                return ctx.fail(GCError.OutOfMemory, root_path, "out of memory resolving gc-root target");
            };
            resolved_target = resolved_owned.?;
        }
        defer if (resolved_owned) |owned| allocator.free(owned);

        // Determine what store paths this root reaches
        try collectFromRoot(ctx, resolved_target, &reachable);
    }

    return reachable;
}

/// Collect store paths reachable from a single root.
///
/// If root points to a profile directory, read the manifest and extract store paths.
/// If root points directly to a store path, add that path.
fn collectFromRoot(
    ctx: *mere.Context,
    root_target: []const u8,
    reachable: *std.StringHashMap(void),
) GCError!void {
    const allocator = ctx.allocator;
    // Check if this is a profile directory (contains manifest.json)
    const manifest_path = std.fs.path.join(allocator, &.{ root_target, generation.MANIFEST_FILENAME }) catch {
        return ctx.fail(GCError.OutOfMemory, root_target, "out of memory building manifest path");
    };
    defer allocator.free(manifest_path);

    // Try to read as a generation manifest
    if (std.fs.accessAbsolute(manifest_path, .{})) |_| {
        // This is a generation - read manifest and extract store paths
        var manifest = generation.readManifest(allocator, root_target) catch |err| {
            return switch (err) {
                error.OutOfMemory => ctx.fail(GCError.OutOfMemory, root_target, "out of memory reading generation manifest"),
                error.PermissionDenied => ctx.fail(GCError.PermissionDenied, root_target, "permission denied reading generation manifest"),
                error.FileSystem,
                error.InvalidManifest,
                error.GenerationNotFound,
                error.InvalidInput,
                error.ParseError,
                error.ProfilesNotFound,
                error.NoCurrentGeneration,
                error.NoPreviousGeneration,
                => ctx.fail(GCError.FileSystem, root_target, "failed to read generation manifest"),
            };
        };
        defer manifest.deinit();

        for (manifest.packages.items) |pkg| {
            try addReachable(ctx, reachable, pkg.store_path);
        }
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            error.AccessDenied => return ctx.fail(GCError.PermissionDenied, manifest_path, "permission denied reading manifest"),
            else => return ctx.fail(GCError.FileSystem, manifest_path, "failed to access manifest"),
        }
        // Not a generation - check if it's a direct store path
        // A store path looks like /mere/store/<hash>-<name>-<version>/
        if (std.mem.indexOf(u8, root_target, "/store/")) |_| {
            try addReachable(ctx, reachable, root_target);
        }
        // Also handle symlinks to symlinks (e.g., gc-roots/profiles/system/current -> profiles/system/current -> gen-N)
        // Try to resolve further
        var resolve_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.readLinkAbsolute(root_target, &resolve_buf)) |resolved| {
            // Recursively collect from the resolved target
            try collectFromRoot(ctx, resolved, reachable);
        } else |_| {
            // Not a symlink, that's fine
        }
    }
}

/// Add a store path to the reachable set.
fn addReachable(
    ctx: *mere.Context,
    reachable: *std.StringHashMap(void),
    store_path: []const u8,
) GCError!void {
    const allocator = ctx.allocator;
    // Normalize: remove trailing slash if present
    const normalized = if (store_path.len > 0 and store_path[store_path.len - 1] == '/')
        store_path[0 .. store_path.len - 1]
    else
        store_path;

    if (reachable.contains(normalized)) {
        return; // Already added
    }

    const owned = allocator.dupe(u8, normalized) catch {
        return ctx.fail(GCError.OutOfMemory, store_path, "out of memory adding reachable store path");
    };
    reachable.put(owned, {}) catch {
        allocator.free(owned);
        return ctx.fail(GCError.OutOfMemory, store_path, "out of memory adding reachable store path");
    };
}

/// Check if any GC roots exist.
fn hasRootsAt(gc_roots_dir: []const u8) GCError!bool {
    var dir = std.fs.openDirAbsolute(gc_roots_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => false,
            error.AccessDenied => GCError.PermissionDenied,
            else => GCError.FileSystem,
        };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next() catch |err| {
            return mapGcFsError(err);
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind == .sym_link) {
            return true;
        }
    }
    return false;
}

// Tests

const TestRepoPackage = struct {
    name: []const u8,
    version: []const u8,
    release: u32,
    arch: []const u8,
    content_hash: []const u8,
    archive_hash: []const u8,
};

fn makeTestRepoPackage(ctx: *mere.Context, spec: TestRepoPackage) !package_mod.Package {
    var pkg = package_mod.Package.init(ctx);
    pkg.name = try ctx.allocator.dupe(u8, spec.name);
    pkg.version = try ctx.allocator.dupe(u8, spec.version);
    pkg.release = spec.release;
    pkg.arch = try ctx.allocator.dupe(u8, spec.arch);
    pkg.signature = try ctx.allocator.dupe(u8, "deadbeef");
    pkg.content_hash = try ctx.allocator.dupe(u8, spec.content_hash);
    pkg.archive_hash = try ctx.allocator.dupe(u8, spec.archive_hash);
    return pkg;
}

fn writeRepoStateDb(
    ctx: *mere.Context,
    state_dir: []const u8,
    pkgs: []const TestRepoPackage,
) !void {
    try std.fs.cwd().makePath(state_dir);

    const db_path = try std.fs.path.join(ctx.allocator, &.{ state_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(db_path);

    var db = try repodb.RepoDB.init(ctx, db_path, false);
    defer {
        db.deinit();
        ctx.allocator.destroy(db);
    }

    for (pkgs) |spec| {
        var pkg = try makeTestRepoPackage(ctx, spec);
        defer pkg.deinit();
        _ = try db.insertPackageTransaction(&pkg);
    }
}

fn createPackagePoolArchive(
    allocator: std.mem.Allocator,
    package_pool_dir: []const u8,
    archive_name: []const u8,
) ![]const u8 {
    const archive_path = try std.fs.path.join(allocator, &.{ package_pool_dir, archive_name });
    errdefer allocator.free(archive_path);

    var file = try std.fs.createFileAbsolute(archive_path, .{});
    defer file.close();
    try file.writeAll("archive");

    return archive_path;
}

// Spec #12: GC refuses to run with no roots (safety measure)
test "collectGarbage with no roots fails" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    // Create a store object
    const store_obj = try std.fs.path.join(allocator, &.{ store_dir, "abc123-test-1.0" });
    defer allocator.free(store_obj);
    try std.fs.cwd().makePath(store_obj);

    // GC should fail with NoRoots
    const result = collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{});
    try std.testing.expectError(GCError.NoRoots, result);
}

// Spec #12: GC preserves reachable store paths (pin-based roots)
test "collectGarbage keeps rooted store paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    // Create two store objects
    const kept_obj = try std.fs.path.join(allocator, &.{ store_dir, "abc123-kept-1.0" });
    defer allocator.free(kept_obj);
    try std.fs.cwd().makePath(kept_obj);

    const unreachable_obj = try std.fs.path.join(allocator, &.{ store_dir, "def456-unreachable-2.0" });
    defer allocator.free(unreachable_obj);
    try std.fs.cwd().makePath(unreachable_obj);

    // Create a pin pointing to the kept object
    const pin_path = try std.fs.path.join(allocator, &.{ gc_roots_dir, "my-pin" });
    defer allocator.free(pin_path);

    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(kept_obj, "my-pin", .{}) catch {};

    // GC should only want to delete unreachable
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = true });
    defer gc_result.deinit();

    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gc_result.deleted_paths.items[0], "def456-unreachable-2.0"));
}

// Spec #12: GC preserves reachable store paths (generation manifest)
test "collectGarbage collects from generation manifest" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create store objects
    const pkg1_path = try std.fs.path.join(allocator, &.{ store_dir, "abc123-pkg1-1.0" });
    defer allocator.free(pkg1_path);
    try std.fs.cwd().makePath(pkg1_path);

    const pkg2_path = try std.fs.path.join(allocator, &.{ store_dir, "def456-pkg2-2.0" });
    defer allocator.free(pkg2_path);
    try std.fs.cwd().makePath(pkg2_path);

    const unreachable_path = try std.fs.path.join(allocator, &.{ store_dir, "xyz789-old-0.1" });
    defer allocator.free(unreachable_path);
    try std.fs.cwd().makePath(unreachable_path);

    // Create a generation with pkg1 and pkg2
    const gen_dir = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_dir);
    try std.fs.cwd().makePath(gen_dir);

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();

    try manifest.addPackage(
        "pkg1",
        "1.0",
        1,
        "x86_64",
        pkg1_path,
        "abc1230000000000000000000000000000000000000000000000000000000000",
    );
    try manifest.addPackage(
        "pkg2",
        "2.0",
        1,
        "x86_64",
        pkg2_path,
        "def4560000000000000000000000000000000000000000000000000000000000",
    );

    try generation.writeManifest(allocator, gen_dir, &manifest);

    // Create gc-root pointing to generation
    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(gen_dir, "gen-1", .{}) catch {};

    // GC should only want to delete unreachable (old-0.1)
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = true });
    defer gc_result.deinit();

    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gc_result.deleted_paths.items[0], "xyz789-old-0.1"));
}

// Spec #12: GC deletes unreachable store paths
test "collectGarbage actual deletion" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    // Create a store object to delete
    const to_delete = try std.fs.path.join(allocator, &.{ store_dir, "abc123-delete-me-1.0" });
    defer allocator.free(to_delete);
    try std.fs.cwd().makePath(to_delete);

    // Put a file inside it
    const inner_file = try std.fs.path.join(allocator, &.{ to_delete, "somefile" });
    defer allocator.free(inner_file);
    var file = try std.fs.createFileAbsolute(inner_file, .{});
    file.close();

    // Create a kept object with a root
    const kept = try std.fs.path.join(allocator, &.{ store_dir, "def456-kept-2.0" });
    defer allocator.free(kept);
    try std.fs.cwd().makePath(kept);

    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(kept, "my-pin", .{}) catch {};

    // Actually run GC (not dry-run)
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = false });
    defer gc_result.deinit();

    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);

    // Verify delete-me is gone
    std.fs.accessAbsolute(to_delete, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestUnexpectedResult;
}

// Spec #12: GC prunes unkept generations
test "collectGarbage prunes unkept generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    const profile_dir = try std.fs.path.join(allocator, &.{ profiles_dir, "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create a reachable store object and pin it so GC has roots.
    const kept_obj = try std.fs.path.join(allocator, &.{ store_dir, "abc123-kept-1.0" });
    defer allocator.free(kept_obj);
    try std.fs.cwd().makePath(kept_obj);

    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(kept_obj, "my-pin", .{}) catch {};

    // Create generations 1-4 with valid manifests.
    for ([_]u32{ 1, 2, 3, 4 }) |gen| {
        const gen_dir = try generation.getGenerationPath(allocator, profile_dir, gen);
        defer allocator.free(gen_dir);
        try std.fs.cwd().makePath(gen_dir);

        var manifest = generation.GenerationManifest.init(allocator, gen);
        defer manifest.deinit();
        try manifest.addPackage(
            "pkg",
            "1.0",
            1,
            "x86_64",
            kept_obj,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
        try generation.writeManifest(allocator, gen_dir, &manifest);
    }

    // Point current to gen-1 so it stays kept even though it's not recent.
    var profile_handle = try std.fs.openDirAbsolute(profile_dir, .{});
    defer profile_handle.close();
    profile_handle.symLink("gen-1", "current", .{}) catch {};

    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = true });
    defer gc_result.deinit();

    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gc_result.deleted_paths.items[0], "gen-2"));
}

test "hasRootsAt" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    // Initially no roots
    try std.testing.expect(!try hasRootsAt(gc_roots_dir));

    // Add a symlink
    var handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer handle.close();
    handle.symLink("/some/target", "my-root", .{}) catch {};

    // Now has roots
    try std.testing.expect(try hasRootsAt(gc_roots_dir));
}

test "gc mapGcFsError preserves actionable classes" {
    try std.testing.expectEqual(GCError.OutOfMemory, mapGcFsError(error.OutOfMemory));
    try std.testing.expectEqual(GCError.PermissionDenied, mapGcFsError(error.AccessDenied));
    try std.testing.expectEqual(GCError.FileSystem, mapGcFsError(error.FileNotFound));
}

test "addReachable normalizes trailing slash" {
    const allocator = std.testing.allocator;

    var reachable = std.StringHashMap(void).init(allocator);
    defer {
        var iter = reachable.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        reachable.deinit();
    }

    var ctx = mere.Context.init(allocator, null);
    defer ctx.deinit();

    try addReachable(&ctx, &reachable, "/mere/store/abc-pkg-1.0/");
    try addReachable(&ctx, &reachable, "/mere/store/abc-pkg-1.0"); // No trailing slash

    // Should only have one entry (deduplicated)
    try std.testing.expectEqual(@as(u32, 1), reachable.count());
    try std.testing.expect(reachable.contains("/mere/store/abc-pkg-1.0"));
}

// Spec #12: GC preserves reachable store paths referenced by generation manifests and pins
test "collectGarbage preserves store paths from both pins and generation manifests" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    const profile_dir = try std.fs.path.join(allocator, &.{ profiles_dir, "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create three store objects: two reachable (one via pin, one via generation), one unreachable
    const pinned_obj = try std.fs.path.join(allocator, &.{ store_dir, "aaa111-pinned-1.0" });
    defer allocator.free(pinned_obj);
    try std.fs.cwd().makePath(pinned_obj);

    const gen_obj = try std.fs.path.join(allocator, &.{ store_dir, "bbb222-gen-pkg-2.0" });
    defer allocator.free(gen_obj);
    try std.fs.cwd().makePath(gen_obj);

    const unreachable_obj = try std.fs.path.join(allocator, &.{ store_dir, "ccc333-orphan-3.0" });
    defer allocator.free(unreachable_obj);
    try std.fs.cwd().makePath(unreachable_obj);

    // Create a pin root pointing to pinned_obj
    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(pinned_obj, "my-pin", .{}) catch {};

    // Create a generation with gen_obj referenced in its manifest
    const gen_dir = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_dir);
    try std.fs.cwd().makePath(gen_dir);

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "gen-pkg",
        "2.0",
        1,
        "x86_64",
        gen_obj,
        "bbb2220000000000000000000000000000000000000000000000000000000000",
    );
    try generation.writeManifest(allocator, gen_dir, &manifest);

    // Create gc-root symlink pointing to the generation directory
    gc_roots_handle.symLink(gen_dir, "gen-root", .{}) catch {};

    // Run GC in dry-run mode
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = true });
    defer gc_result.deinit();

    // Only the unreachable object should be marked for deletion
    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gc_result.deleted_paths.items[0], "ccc333-orphan-3.0"));

    // Verify both reachable objects still exist
    std.fs.accessAbsolute(pinned_obj, .{}) catch return error.TestUnexpectedResult;
    std.fs.accessAbsolute(gen_obj, .{}) catch return error.TestUnexpectedResult;
}

// Spec #12: GC deletes unreachable store paths
test "collectGarbage deletes multiple unreachable store paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    // Create one rooted store object
    const kept_obj = try std.fs.path.join(allocator, &.{ store_dir, "aaa111-kept-1.0" });
    defer allocator.free(kept_obj);
    try std.fs.cwd().makePath(kept_obj);

    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(kept_obj, "keep-pin", .{}) catch {};

    // Create two unreachable store objects with files inside
    const orphan1 = try std.fs.path.join(allocator, &.{ store_dir, "bbb222-orphan1-1.0" });
    defer allocator.free(orphan1);
    try std.fs.cwd().makePath(orphan1);
    {
        const f_path = try std.fs.path.join(allocator, &.{ orphan1, "file.txt" });
        defer allocator.free(f_path);
        var f = try std.fs.createFileAbsolute(f_path, .{});
        f.close();
    }

    const orphan2 = try std.fs.path.join(allocator, &.{ store_dir, "ccc333-orphan2-2.0" });
    defer allocator.free(orphan2);
    try std.fs.cwd().makePath(orphan2);
    {
        const f_path = try std.fs.path.join(allocator, &.{ orphan2, "data.bin" });
        defer allocator.free(f_path);
        var f = try std.fs.createFileAbsolute(f_path, .{});
        f.close();
    }

    // Actually run GC (not dry-run)
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = false });
    defer gc_result.deinit();

    // Both orphans should be deleted
    try std.testing.expectEqual(@as(usize, 2), gc_result.deleted_paths.items.len);

    // Verify orphans are gone
    std.fs.accessAbsolute(orphan1, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        std.fs.accessAbsolute(orphan2, .{}) catch |err2| {
            try std.testing.expectEqual(error.FileNotFound, err2);
            // Verify kept object still exists
            std.fs.accessAbsolute(kept_obj, .{}) catch return error.TestUnexpectedResult;
            return;
        };
        return error.TestUnexpectedResult;
    };
    return error.TestUnexpectedResult;
}

// Spec #12: GC only deletes store directories, not symlinks or files
test "collectGarbage only deletes directories in store" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    // Create a rooted store object so GC has roots and will run
    const kept_obj = try std.fs.path.join(allocator, &.{ store_dir, "aaa111-kept-1.0" });
    defer allocator.free(kept_obj);
    try std.fs.cwd().makePath(kept_obj);

    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(kept_obj, "keep-pin", .{}) catch {};

    // Create an unreachable directory (should be deleted)
    const unreachable_dir = try std.fs.path.join(allocator, &.{ store_dir, "bbb222-orphan-1.0" });
    defer allocator.free(unreachable_dir);
    try std.fs.cwd().makePath(unreachable_dir);

    // Create a plain file in the store (should NOT be deleted by GC)
    const store_file = try std.fs.path.join(allocator, &.{ store_dir, "stray-file.txt" });
    defer allocator.free(store_file);
    {
        var f = try std.fs.createFileAbsolute(store_file, .{});
        try f.writeAll("stray file");
        f.close();
    }

    // Create a symlink in the store (should NOT be deleted by GC)
    var store_handle = try std.fs.openDirAbsolute(store_dir, .{});
    defer store_handle.close();
    store_handle.symLink("/some/target", "stray-symlink", .{}) catch {};

    const store_symlink = try std.fs.path.join(allocator, &.{ store_dir, "stray-symlink" });
    defer allocator.free(store_symlink);

    // Run GC for real
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = false });
    defer gc_result.deinit();

    // Only the unreachable directory should be deleted
    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gc_result.deleted_paths.items[0], "bbb222-orphan-1.0"));

    // Verify the directory is gone
    std.fs.accessAbsolute(unreachable_dir, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);

        // Verify the plain file still exists
        std.fs.accessAbsolute(store_file, .{}) catch return error.TestUnexpectedResult;

        // Verify the symlink still exists (check via readLink)
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = std.fs.readLinkAbsolute(store_symlink, &link_buf) catch return error.TestUnexpectedResult;

        return;
    };
    return error.TestUnexpectedResult;
}

// Spec #12: .keep marker causes generation to be preserved during GC pruning
test "collectGarbage preserves explicitly kept generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    const profile_dir = try std.fs.path.join(allocator, &.{ profiles_dir, "system" });
    defer allocator.free(profile_dir);
    try std.fs.cwd().makePath(profile_dir);

    // Create a store object referenced by all generations
    const pkg_obj = try std.fs.path.join(allocator, &.{ store_dir, "aaa111-pkg-1.0" });
    defer allocator.free(pkg_obj);
    try std.fs.cwd().makePath(pkg_obj);

    // Create a pin so GC has roots and will run
    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(pkg_obj, "keep-pin", .{}) catch {};

    // Create generations 1-5 with valid manifests
    for ([_]u32{ 1, 2, 3, 4, 5 }) |gen| {
        const gen_dir = try generation.getGenerationPath(allocator, profile_dir, gen);
        defer allocator.free(gen_dir);
        try std.fs.cwd().makePath(gen_dir);

        var manifest = generation.GenerationManifest.init(allocator, gen);
        defer manifest.deinit();
        try manifest.addPackage(
            "pkg",
            "1.0",
            1,
            "x86_64",
            pkg_obj,
            "aaa1110000000000000000000000000000000000000000000000000000000000",
        );
        try generation.writeManifest(allocator, gen_dir, &manifest);
    }

    // Point current to gen-5
    var profile_handle = try std.fs.openDirAbsolute(profile_dir, .{});
    defer profile_handle.close();
    profile_handle.symLink("gen-5", "current", .{}) catch {};

    // Explicitly keep gen-1 with a .keep marker
    try gcroots.keepGeneration(allocator, profile_dir, 1, "important baseline");

    // Run GC in dry-run mode (DEFAULT_RETENTION_COUNT = 2, so keeps gen-4, gen-5 by recency)
    // gen-1 should also be kept due to .keep marker
    // gen-2 and gen-3 should be pruned
    var gc_result = try collectGarbageAtPaths(&test_env.ctx, gc_roots_dir, store_dir, profiles_dir, .{ .dry_run = true });
    defer gc_result.deinit();

    // Should prune exactly gen-2 and gen-3
    try std.testing.expectEqual(@as(usize, 2), gc_result.deleted_paths.items.len);

    // Verify the pruned generations are gen-2 and gen-3 (not gen-1)
    var found_gen2 = false;
    var found_gen3 = false;
    for (gc_result.deleted_paths.items) |deleted_path| {
        if (std.mem.endsWith(u8, deleted_path, "gen-2")) found_gen2 = true;
        if (std.mem.endsWith(u8, deleted_path, "gen-3")) found_gen3 = true;
        // gen-1 must NOT be in the deleted list
        try std.testing.expect(!std.mem.endsWith(u8, deleted_path, "gen-1"));
    }
    try std.testing.expect(found_gen2);
    try std.testing.expect(found_gen3);
}

test "collectGarbage prunes unreferenced package pool archives" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "gc-roots" });
    defer allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const store_dir = try std.fs.path.join(allocator, &.{ test_env.path, "store" });
    defer allocator.free(store_dir);
    try std.fs.cwd().makePath(store_dir);

    const profiles_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles" });
    defer allocator.free(profiles_dir);
    try std.fs.cwd().makePath(profiles_dir);

    const package_pool_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "cache", "packages" });
    defer allocator.free(package_pool_dir);
    try std.fs.cwd().makePath(package_pool_dir);

    const repo_root_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "dev", "repo" });
    defer allocator.free(repo_root_dir);
    try std.fs.cwd().makePath(repo_root_dir);

    const kept_obj = try std.fs.path.join(allocator, &.{ store_dir, "aaa111-kept-1.0" });
    defer allocator.free(kept_obj);
    try std.fs.cwd().makePath(kept_obj);

    var gc_roots_handle = try std.fs.openDirAbsolute(gc_roots_dir, .{});
    defer gc_roots_handle.close();
    gc_roots_handle.symLink(kept_obj, "keep-pin", .{}) catch {};

    const repo_dir = try std.fs.path.join(allocator, &.{ repo_root_dir, "local" });
    defer allocator.free(repo_dir);
    try std.fs.cwd().makePath(repo_dir);

    const current_state_dir = try std.fs.path.join(allocator, &.{ repo_dir, repo_history.CURRENT_STATE_DIR });
    defer allocator.free(current_state_dir);
    try writeRepoStateDb(&test_env.ctx, current_state_dir, &.{
        .{
            .name = "bash",
            .version = "5.3",
            .release = 2,
            .arch = "x86_64",
            .content_hash = "1" ** 64,
            .archive_hash = "a" ** 64,
        },
    });

    const previous_state_dir = try std.fs.path.join(allocator, &.{ repo_dir, repo_history.PREVIOUS_STATE_DIR });
    defer allocator.free(previous_state_dir);
    try writeRepoStateDb(&test_env.ctx, previous_state_dir, &.{
        .{
            .name = "coreutils",
            .version = "9.7",
            .release = 1,
            .arch = "x86_64",
            .content_hash = "2" ** 64,
            .archive_hash = "b" ** 64,
        },
    });

    const kept_current_name = "bash-5.3-2-x86_64-" ++ ("a" ** 64) ++ ".pkg.tar.zst";
    const kept_previous_name = "coreutils-9.7-1-x86_64-" ++ ("b" ** 64) ++ ".pkg.tar.zst";
    const orphan_name = "grep-3.12-1-x86_64-" ++ ("c" ** 64) ++ ".pkg.tar.zst";

    const kept_current_path = try createPackagePoolArchive(allocator, package_pool_dir, kept_current_name);
    defer allocator.free(kept_current_path);
    const kept_previous_path = try createPackagePoolArchive(allocator, package_pool_dir, kept_previous_name);
    defer allocator.free(kept_previous_path);
    const orphan_path = try createPackagePoolArchive(allocator, package_pool_dir, orphan_name);
    defer allocator.free(orphan_path);

    var gc_result = try collectGarbageAtPathsWithPackagePool(
        &test_env.ctx,
        gc_roots_dir,
        store_dir,
        profiles_dir,
        package_pool_dir,
        repo_root_dir,
        .{ .dry_run = false },
    );
    defer gc_result.deinit();

    try std.testing.expectEqual(@as(usize, 1), gc_result.deleted_paths.items.len);
    try std.testing.expect(std.mem.endsWith(u8, gc_result.deleted_paths.items[0], orphan_name));

    std.fs.accessAbsolute(orphan_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.fs.accessAbsolute(kept_current_path, .{}) catch return error.TestUnexpectedResult;
    std.fs.accessAbsolute(kept_previous_path, .{}) catch return error.TestUnexpectedResult;
}
