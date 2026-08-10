// SPDX-License-Identifier: MIT
const std = @import("std");
const mere = @import("mere.zig");
const package = @import("package.zig");
const path = @import("path.zig");
const ver = @import("version.zig");
const errors = @import("errors.zig");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

const Std = errors.StandardErrors;
pub const RepoDBError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData || Std.SignatureInvalid || error{
    PackageNotFound,
    PackageAlreadyExists,
    DependencyNotFound,
    DependencyResolutionFailed,
};

const schema =
    \\CREATE TABLE IF NOT EXISTS schema_version (
    \\    version INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS packages (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    version TEXT,
    \\    release INTEGER NOT NULL,
    \\    arch TEXT,
    \\    properties TEXT,
    \\    signature BLOB,
    \\    content_hash TEXT,
    \\    archive_hash TEXT,
    \\    UNIQUE(name, version, release, arch)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_package_name ON packages(name);
    \\CREATE INDEX IF NOT EXISTS idx_package_name_version ON packages(name, version);
    \\
    \\CREATE TABLE IF NOT EXISTS dependencies (
    \\    id INTEGER PRIMARY KEY,
    \\    source_package_id INTEGER NOT NULL,
    \\    dependency_type TEXT NOT NULL,
    \\    target_resource TEXT NOT NULL,
    \\    target_type TEXT NOT NULL,
    \\    version_constraint TEXT,
    \\    FOREIGN KEY (source_package_id) REFERENCES packages(id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_dependency_source ON dependencies(source_package_id);
    \\CREATE INDEX IF NOT EXISTS idx_dependency_target_resource ON dependencies(target_resource);
    \\CREATE INDEX IF NOT EXISTS idx_dependency_target_type ON dependencies(target_type);
    \\
    \\CREATE TABLE IF NOT EXISTS provisions (
    \\    id INTEGER PRIMARY KEY,
    \\    package_id INTEGER NOT NULL,
    \\    resource TEXT NOT NULL,
    \\    type TEXT NOT NULL,
    \\    FOREIGN KEY (package_id) REFERENCES packages(id)
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_provision_resource ON provisions(resource);
    \\CREATE INDEX IF NOT EXISTS idx_provision_package ON provisions(package_id);
;

/// A (name, arch) pair from the packages table. Caller owns both strings.
pub const NameArch = struct {
    name: []const u8,
    arch: []const u8,
};

pub const DependencyRequirement = struct {
    dependency_type: package.DependencyType,
    target_resource: []const u8,
    target_type: []const u8,
    version_constraint: ?[]const u8,

    pub fn deinit(self: *DependencyRequirement, allocator: std.mem.Allocator) void {
        allocator.free(self.target_resource);
        allocator.free(self.target_type);
        if (self.version_constraint) |expr| allocator.free(expr);
    }
};

pub const RepoDB = struct {
    ctx: *mere.Context,
    db_path: []const u8,
    db: ?*c.sqlite3,
    read_only: bool,

    pub fn init(ctx: *mere.Context, db_path: []const u8, read_only: bool) !*RepoDB {
        if (db_path.len == 0) {
            return ctx.fail(RepoDBError.InvalidInput, "repository db", "db path is empty");
        }

        for (db_path) |byte| {
            if (byte == 0) {
                return ctx.fail(RepoDBError.InvalidInput, "repository db", "db path contains null byte");
            }
        }

        const allocator = ctx.allocator;
        const self = try allocator.create(RepoDB);
        errdefer allocator.destroy(self);

        const db_path_copy = allocator.dupe(u8, db_path) catch {
            return ctx.fail(RepoDBError.OutOfMemory, db_path, "failed to allocate repository db path");
        };
        errdefer allocator.free(db_path_copy);

        self.* = RepoDB{
            .ctx = ctx,
            .db_path = db_path_copy,
            .db = null,
            .read_only = read_only,
        };

        self.open() catch {
            return ctx.fail(RepoDBError.FileSystem, db_path, "failed to open repository db");
        };

        // Only initialize schema for read-write databases (import, repo remove, bootstrap).
        // Read-only consumers (install, build, resolve) must not write to the DB.
        if (!read_only) {
            self.initSchema() catch |err| {
                return switch (err) {
                    error.OutOfMemory => ctx.fail(RepoDBError.OutOfMemory, db_path, "failed to initialize repository schema"),
                    error.InvalidInput => ctx.fail(RepoDBError.InvalidInput, db_path, "repository database schema is outdated or invalid"),
                    else => ctx.fail(RepoDBError.CorruptData, db_path, "failed to initialize repository schema"),
                };
            };
        }

        return self;
    }

    /// Opens a read-only RepoDB from bytes the caller has already verified
    /// against a trusted signature, instead of letting sqlite read db_path
    /// from disk itself. Without this, a caller that hashes db_path to
    /// verify it and then opens db_path via sqlite3_open_v2 has a window
    /// between the two reads where the on-disk file could be swapped out
    /// from under the verified hash.
    ///
    /// db_path is used only as a diagnostic label; the actual database
    /// content comes entirely from `bytes`. `bytes` is copied into a
    /// sqlite-owned buffer, so the caller may free its copy immediately
    /// after this call returns.
    pub fn initFromVerifiedBytes(ctx: *mere.Context, db_path: []const u8, bytes: []const u8) !*RepoDB {
        if (db_path.len == 0) {
            return ctx.fail(RepoDBError.InvalidInput, "repository db", "db path is empty");
        }

        const allocator = ctx.allocator;
        const self = try allocator.create(RepoDB);
        errdefer allocator.destroy(self);

        const db_path_copy = allocator.dupe(u8, db_path) catch {
            return ctx.fail(RepoDBError.OutOfMemory, db_path, "failed to allocate repository db path");
        };
        errdefer allocator.free(db_path_copy);

        self.* = RepoDB{
            .ctx = ctx,
            .db_path = db_path_copy,
            .db = null,
            .read_only = true,
        };

        self.openFromBytes(bytes) catch {
            return ctx.fail(RepoDBError.CorruptData, db_path, "failed to open repository db from verified bytes");
        };

        return self;
    }

    fn openFromBytes(self: *RepoDB, bytes: []const u8) !void {
        const rc_open = c.sqlite3_open_v2(":memory:", &self.db, c.SQLITE_OPEN_READWRITE, null);
        if (rc_open != c.SQLITE_OK) {
            if (self.db != null) {
                _ = c.sqlite3_close(self.db);
            }
            self.db = null;
            return RepoDBError.FileSystem;
        }

        const buf_size: c.sqlite3_int64 = @intCast(bytes.len);
        const raw_buf = c.sqlite3_malloc64(@intCast(bytes.len));
        if (raw_buf == null) {
            _ = c.sqlite3_close(self.db);
            self.db = null;
            return RepoDBError.OutOfMemory;
        }
        const sqlite_buf: [*]u8 = @ptrCast(raw_buf.?);
        @memcpy(sqlite_buf[0..bytes.len], bytes);

        const flags: c_uint = c.SQLITE_DESERIALIZE_READONLY | c.SQLITE_DESERIALIZE_FREEONCLOSE;
        const rc = c.sqlite3_deserialize(self.db, "main", sqlite_buf, buf_size, buf_size, flags);
        if (rc != c.SQLITE_OK) {
            // On failure with FREEONCLOSE set, sqlite3_deserialize() has
            // already freed sqlite_buf itself.
            _ = c.sqlite3_close(self.db);
            self.db = null;
            return RepoDBError.FileSystem;
        }
    }

    fn open(self: *RepoDB) !void {
        // Ensure we pass a NUL-terminated C string to sqlite3_open_v2.
        var c_path = try self.ctx.allocator.alloc(u8, self.db_path.len + 1);
        defer self.ctx.allocator.free(c_path);
        std.mem.copyForwards(u8, c_path[0..self.db_path.len], self.db_path);
        c_path[self.db_path.len] = 0;

        const flags: c_int = if (self.read_only)
            c.SQLITE_OPEN_READONLY
        else
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;

        const rc = c.sqlite3_open_v2(@as([*c]const u8, c_path.ptr), &self.db, flags, null);

        if (rc != c.SQLITE_OK) {
            if (self.db != null) {
                _ = c.sqlite3_close(self.db);
            }
            self.db = null;
            return RepoDBError.FileSystem;
        }
    }

    fn initSchema(self: *RepoDB) !void {
        var err_msg: [*c]u8 = null;
        const exec_rc = c.sqlite3_exec(self.db, schema, null, null, &err_msg);
        if (exec_rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return RepoDBError.CorruptData;
        }

        // Normalize databases created before schema_version had a uniqueness
        // constraint, then enforce the invariant for future initializations.
        // Keep the first row for each version so this is safe for existing DBs.
        const schema_version_migration =
            "BEGIN IMMEDIATE;" ++
            "DELETE FROM schema_version WHERE rowid NOT IN (" ++
            "SELECT MIN(rowid) FROM schema_version GROUP BY version);" ++
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_schema_version_version " ++
            "ON schema_version(version);" ++
            "INSERT OR IGNORE INTO schema_version (version) VALUES (1);" ++
            "COMMIT;";
        const version_rc = c.sqlite3_exec(self.db, schema_version_migration, null, null, &err_msg);
        if (version_rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, null);
            return RepoDBError.CorruptData;
        }

        try self.validateRequiredSchema();
    }

    fn validateRequiredSchema(self: *RepoDB) !void {
        const sql =
            "SELECT 1 FROM pragma_table_info('packages') WHERE name = 'archive_hash' LIMIT 1;";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        const step = c.sqlite3_step(stmt.?);
        if (step == c.SQLITE_ROW) return;
        if (step == c.SQLITE_DONE) return RepoDBError.InvalidInput;
        return RepoDBError.CorruptData;
    }

    pub fn prepareStatement(self: *RepoDB, sql: []const u8) !?*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const prepare_rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prepare_rc != c.SQLITE_OK) {
            return RepoDBError.CorruptData;
        }
        return stmt;
    }

    pub fn deinit(self: *RepoDB) void {
        if (self.db) |db_conn| {
            _ = c.sqlite3_close(db_conn);
            self.db = null;
        }
        self.ctx.allocator.free(self.db_path);
        // Do not destroy(self) here; owner is responsible for freeing memory.
    }

    pub fn getPackagesByName(self: *RepoDB, allocator: std.mem.Allocator, pkg_name: []const u8) !std.ArrayList(package.Package) {
        if (self.db == null) {
            return RepoDBError.FileSystem;
        }

        const sql =
            \\SELECT name, version, release, arch, signature, content_hash, archive_hash
            \\FROM packages
            \\WHERE name = ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);

        var candidates: std.ArrayList(package.Package) = .empty;
        errdefer {
            for (candidates.items) |*pkg| pkg.deinit();
            candidates.deinit(allocator);
        }

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const pkg = try self.parsePackageFromRow(stmt.?);
            candidates.append(allocator, pkg) catch |err| {
                var pkg_mut = pkg;
                pkg_mut.deinit();
                return err;
            };
        }

        if (candidates.items.len == 0) {
            return self.ctx.fail(RepoDBError.PackageNotFound, pkg_name, null);
        }

        return candidates;
    }

    pub fn getLatestPackageByName(self: *RepoDB, allocator: std.mem.Allocator, pkg_name: []const u8) !package.Package {
        var candidates = try self.getPackagesByName(allocator, pkg_name);
        defer {
            for (candidates.items) |*pkg| pkg.deinit();
            candidates.deinit(allocator);
        }

        // Find the package with highest version using vercmp
        var best_idx: usize = 0;
        for (candidates.items[1..], 1..) |candidate, idx| {
            const best = candidates.items[best_idx];
            const cmp = ver.comparePackageVersions(
                candidate.version orelse "",
                candidate.release orelse 0,
                best.version orelse "",
                best.release orelse 0,
            ) catch return RepoDBError.InvalidInput;
            if (cmp == .greater) {
                best_idx = idx;
            }
        }

        // Move the best package out of the list before cleanup
        const result = candidates.items[best_idx];
        // Replace with a dummy to prevent double-free in defer
        candidates.items[best_idx] = package.Package.init(self.ctx);

        return result;
    }

    pub fn getLatestPackageByNameArch(
        self: *RepoDB,
        allocator: std.mem.Allocator,
        pkg_name: []const u8,
        pkg_arch: []const u8,
    ) !package.Package {
        if (self.db == null) return RepoDBError.FileSystem;

        const sql =
            \\SELECT id, name, version, release, arch, signature, content_hash, archive_hash
            \\FROM packages
            \\WHERE name = ? AND arch = ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 2, pkg_arch.ptr, @intCast(pkg_arch.len), null);

        const Candidate = struct {
            id: i64,
            pkg: package.Package,
        };

        var candidates: std.ArrayList(Candidate) = .empty;
        defer {
            for (candidates.items) |*cand| cand.pkg.deinit();
            candidates.deinit(allocator);
        }

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const pkg_id = c.sqlite3_column_int64(stmt.?, 0);
            const pkg = try self.parsePackageFromRowOffset(stmt.?, 1);
            candidates.append(allocator, .{ .id = pkg_id, .pkg = pkg }) catch |err| {
                var pkg_mut = pkg;
                pkg_mut.deinit();
                return err;
            };
        }

        if (candidates.items.len == 0) {
            return self.ctx.fail(RepoDBError.PackageNotFound, pkg_name, null);
        }

        var best_idx: usize = 0;
        for (candidates.items[1..], 1..) |candidate, idx| {
            const best = candidates.items[best_idx].pkg;
            const cmp = ver.comparePackageVersions(
                candidate.pkg.version orelse "",
                candidate.pkg.release orelse 0,
                best.version orelse "",
                best.release orelse 0,
            ) catch return RepoDBError.InvalidInput;
            if (cmp == .greater) best_idx = idx;
        }

        var result = candidates.items[best_idx].pkg;
        try self.loadPackageRelations(candidates.items[best_idx].id, &result);
        candidates.items[best_idx].pkg = package.Package.init(self.ctx);
        return result;
    }

    pub fn getLatestPackagesByNameArch(
        self: *RepoDB,
        allocator: std.mem.Allocator,
        pkg_name: []const u8,
        pkg_arch: []const u8,
        keep_count: u32,
    ) !std.ArrayList(package.Package) {
        if (self.db == null) return RepoDBError.FileSystem;
        if (keep_count == 0) return RepoDBError.InvalidInput;

        const sql =
            \\SELECT id, name, version, release, arch, signature, content_hash, archive_hash
            \\FROM packages
            \\WHERE name = ? AND arch = ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 2, pkg_arch.ptr, @intCast(pkg_arch.len), null);

        const Candidate = struct {
            id: i64,
            pkg: package.Package,
        };

        var candidates: std.ArrayList(Candidate) = .empty;
        defer {
            for (candidates.items) |*cand| cand.pkg.deinit();
            candidates.deinit(allocator);
        }

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const pkg_id = c.sqlite3_column_int64(stmt.?, 0);
            const pkg = try self.parsePackageFromRowOffset(stmt.?, 1);
            candidates.append(allocator, .{ .id = pkg_id, .pkg = pkg }) catch |err| {
                var pkg_mut = pkg;
                pkg_mut.deinit();
                return err;
            };
        }

        if (candidates.items.len == 0) {
            return self.ctx.fail(RepoDBError.PackageNotFound, pkg_name, null);
        }

        var selected: std.ArrayList(package.Package) = .empty;
        errdefer {
            for (selected.items) |*pkg| pkg.deinit();
            selected.deinit(allocator);
        }

        const take_count: usize = @min(candidates.items.len, keep_count);
        var selected_count: usize = 0;
        while (selected_count < take_count) : (selected_count += 1) {
            var best_idx: usize = 0;
            for (candidates.items[1..], 1..) |candidate, idx| {
                if (candidate.pkg.name == null) continue;
                const best = candidates.items[best_idx].pkg;
                if (best.name == null) {
                    best_idx = idx;
                    continue;
                }
                const cmp = ver.comparePackageVersions(
                    candidate.pkg.version orelse "",
                    candidate.pkg.release orelse 0,
                    best.version orelse "",
                    best.release orelse 0,
                ) catch return RepoDBError.InvalidInput;
                if (cmp == .greater) best_idx = idx;
            }

            var result = candidates.items[best_idx].pkg;
            try self.loadPackageRelations(candidates.items[best_idx].id, &result);
            candidates.items[best_idx].pkg = package.Package.init(self.ctx);
            try selected.append(allocator, result);
        }

        return selected;
    }

    pub fn getPackageExact(
        self: *RepoDB,
        pkg_name: []const u8,
        pkg_version: []const u8,
        pkg_release: u32,
        pkg_arch: []const u8,
    ) !package.Package {
        if (self.db == null) return RepoDBError.FileSystem;

        const sql =
            \\SELECT id, name, version, release, arch, signature, content_hash, archive_hash
            \\FROM packages
            \\WHERE name = ? AND version = ? AND release = ? AND arch = ?
            \\LIMIT 1
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 2, pkg_version.ptr, @intCast(pkg_version.len), null);
        _ = c.sqlite3_bind_int(stmt.?, 3, @intCast(pkg_release));
        _ = c.sqlite3_bind_text(stmt.?, 4, pkg_arch.ptr, @intCast(pkg_arch.len), null);

        if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) {
            return self.ctx.fail(RepoDBError.PackageNotFound, pkg_name, null);
        }

        const pkg_id = c.sqlite3_column_int64(stmt.?, 0);
        var pkg = try self.parsePackageFromRowOffset(stmt.?, 1);
        errdefer pkg.deinit();
        try self.loadPackageRelations(pkg_id, &pkg);
        return pkg;
    }

    /// Get the properties JSON string for a specific package by name/version/release/arch.
    /// Returns null if the package has no properties, or an allocator-owned copy of the JSON text.
    pub fn getPackageProperties(
        self: *RepoDB,
        allocator: std.mem.Allocator,
        pkg_name: []const u8,
        pkg_version: []const u8,
        pkg_release: u32,
        pkg_arch: []const u8,
    ) !?[]const u8 {
        if (self.db == null) return RepoDBError.FileSystem;

        const sql =
            \\SELECT properties FROM packages
            \\WHERE name = ? AND version = ? AND release = ? AND arch = ?
            \\LIMIT 1
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 2, pkg_version.ptr, @intCast(pkg_version.len), null);
        _ = c.sqlite3_bind_int(stmt.?, 3, @intCast(pkg_release));
        _ = c.sqlite3_bind_text(stmt.?, 4, pkg_arch.ptr, @intCast(pkg_arch.len), null);

        if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) {
            return null;
        }

        const col_type = c.sqlite3_column_type(stmt.?, 0);
        if (col_type == c.SQLITE_NULL) return null;

        const text_ptr = c.sqlite3_column_text(stmt.?, 0);
        if (text_ptr == null) return null;
        const text_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 0));
        const text: [*]const u8 = @ptrCast(text_ptr.?);
        return allocator.dupe(u8, text[0..text_len]) catch return RepoDBError.OutOfMemory;
    }

    /// Search for packages whose name contains the given substring (case-insensitive).
    /// Returns the latest version of each matching (name, arch) pair.
    pub fn searchByName(self: *RepoDB, allocator: std.mem.Allocator, term: []const u8) !std.ArrayList(package.Package) {
        var results: std.ArrayList(package.Package) = .empty;
        errdefer {
            for (results.items) |*pkg| pkg.deinit();
            results.deinit(allocator);
        }

        if (self.db == null) return RepoDBError.FileSystem;

        const sql =
            \\SELECT name, version, release, arch, signature, content_hash, archive_hash
            \\FROM packages
            \\WHERE name LIKE '%' || ? || '%'
            \\ORDER BY name, arch
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, term.ptr, @intCast(term.len), null);

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const pkg = try self.parsePackageFromRow(stmt.?);
            results.append(allocator, pkg) catch |err| {
                var pkg_mut = pkg;
                pkg_mut.deinit();
                return err;
            };
        }

        return results;
    }
    /// Get all dependencies for a package by name.
    /// Uses vercmp algorithm to find the latest version of the package.
    /// Errors:
    ///   - CorruptData: When preparing or executing the query fails
    ///   - PackageNotFound: When no package with the given name exists
    ///   - OutOfMemory: When memory allocation fails
    ///   - InvalidInput: When dependency data is invalid
    pub fn getDependenciesForPackage(self: *RepoDB, allocator: std.mem.Allocator, pkg_name: []const u8) !std.array_list.AlignedManaged(package.Dependency, null) {
        var deps = std.array_list.AlignedManaged(package.Dependency, null){
            .items = &.{},
            .capacity = 0,
            .allocator = allocator,
        };
        errdefer deps.deinit();

        // Find the package ID for the given name (latest version using vercmp)
        const sql_pkg =
            \\SELECT id, version, release FROM packages
            \\WHERE name = ?
        ;
        var stmt_pkg: ?*c.sqlite3_stmt = null;
        const rc1 = c.sqlite3_prepare_v2(self.db, sql_pkg.ptr, @intCast(sql_pkg.len), &stmt_pkg, null);
        if (rc1 != c.SQLITE_OK or stmt_pkg == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt_pkg.?);

        _ = c.sqlite3_bind_text(stmt_pkg.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);

        // Collect all versions and find the best using vercmp
        const Candidate = struct { id: i32, version_str: []const u8, rel: u32 };
        var candidates: std.ArrayList(Candidate) = .empty;
        defer {
            for (candidates.items) |cand| allocator.free(cand.version_str);
            candidates.deinit(allocator);
        }

        while (c.sqlite3_step(stmt_pkg.?) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int(stmt_pkg.?, 0);
            const ver_ptr = c.sqlite3_column_text(stmt_pkg.?, 1);
            const rel = @as(u32, @intCast(c.sqlite3_column_int(stmt_pkg.?, 2)));

            const version_str = if (ver_ptr != null)
                allocator.dupe(u8, std.mem.span(ver_ptr)) catch return RepoDBError.OutOfMemory
            else
                allocator.dupe(u8, "") catch return RepoDBError.OutOfMemory;

            candidates.append(allocator, .{ .id = id, .version_str = version_str, .rel = rel }) catch {
                allocator.free(version_str);
                return RepoDBError.OutOfMemory;
            };
        }

        if (candidates.items.len == 0) {
            // Use setDiagnosticContext to copy pkg_name to arena since it may be freed before CLI reads it
            return self.ctx.fail(RepoDBError.PackageNotFound, pkg_name, null);
        }

        // Find highest version using vercmp
        var best_idx: usize = 0;
        for (candidates.items[1..], 1..) |cand, idx| {
            const best = candidates.items[best_idx];
            const cmp = ver.comparePackageVersions(cand.version_str, cand.rel, best.version_str, best.rel) catch return RepoDBError.InvalidInput;
            if (cmp == .greater) {
                best_idx = idx;
            }
        }

        const pkg_id = candidates.items[best_idx].id;

        // Query dependencies for this package ID
        const sql_deps =
            \\SELECT dependency_type, target_resource, version_constraint
            \\FROM dependencies
            \\WHERE source_package_id = ?
        ;
        var stmt_deps: ?*c.sqlite3_stmt = null;
        const rc2 = c.sqlite3_prepare_v2(self.db, sql_deps.ptr, @intCast(sql_deps.len), &stmt_deps, null);
        if (rc2 != c.SQLITE_OK or stmt_deps == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt_deps.?);

        _ = c.sqlite3_bind_int(stmt_deps.?, 1, pkg_id);

        while (c.sqlite3_step(stmt_deps.?) == c.SQLITE_ROW) {
            const dep_type_ptr = c.sqlite3_column_text(stmt_deps.?, 0);
            const dep_resource_ptr = c.sqlite3_column_text(stmt_deps.?, 1);
            const dep_version_ptr = c.sqlite3_column_text(stmt_deps.?, 2);
            if (dep_type_ptr == null or dep_resource_ptr == null) continue;

            const dep_type = std.mem.span(dep_type_ptr);
            const dep_resource = std.mem.span(dep_resource_ptr);

            const dep_type_obj = package.DependencyType.fromString(dep_type) catch {
                return RepoDBError.InvalidInput;
            };

            const dep_version = if (dep_version_ptr != null) std.mem.span(dep_version_ptr) else null;
            var dep = package.Dependency.initWithConstraint(allocator, dep_resource, dep_type_obj, dep_version) catch {
                return RepoDBError.OutOfMemory;
            };
            errdefer dep.deinit(allocator);

            deps.append(dep) catch {
                return RepoDBError.OutOfMemory;
            };
        }

        return deps;
    }

    /// Get dependencies for an exact package tuple (name, version, release, arch).
    /// Returns dependency target resource and optional version constraint as stored.
    pub fn getDependenciesForPackageExact(
        self: *RepoDB,
        allocator: std.mem.Allocator,
        pkg_name: []const u8,
        pkg_version: []const u8,
        pkg_release: u32,
        pkg_arch: []const u8,
    ) !std.ArrayList(DependencyRequirement) {
        if (self.db == null) return RepoDBError.FileSystem;

        var deps: std.ArrayList(DependencyRequirement) = .empty;
        errdefer {
            for (deps.items) |*dep| dep.deinit(allocator);
            deps.deinit(allocator);
        }

        const sql =
            \\SELECT d.dependency_type, d.target_resource, d.target_type, d.version_constraint
            \\FROM dependencies d
            \\JOIN packages p ON p.id = d.source_package_id
            \\WHERE p.name = ? AND p.version = ? AND p.release = ? AND p.arch = ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, pkg_name.ptr, @intCast(pkg_name.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 2, pkg_version.ptr, @intCast(pkg_version.len), null);
        _ = c.sqlite3_bind_int(stmt.?, 3, @intCast(pkg_release));
        _ = c.sqlite3_bind_text(stmt.?, 4, pkg_arch.ptr, @intCast(pkg_arch.len), null);

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const dep_type_ptr = c.sqlite3_column_text(stmt.?, 0);
            const dep_resource_ptr = c.sqlite3_column_text(stmt.?, 1);
            const target_type_ptr = c.sqlite3_column_text(stmt.?, 2);
            const version_constraint_ptr = c.sqlite3_column_text(stmt.?, 3);
            if (dep_type_ptr == null or dep_resource_ptr == null or target_type_ptr == null) continue;

            const dep_type = package.DependencyType.fromString(std.mem.span(dep_type_ptr)) catch {
                return RepoDBError.InvalidInput;
            };
            const dep_resource = try allocator.dupe(u8, std.mem.span(dep_resource_ptr));
            errdefer allocator.free(dep_resource);
            const target_type = try allocator.dupe(u8, std.mem.span(target_type_ptr));
            errdefer allocator.free(target_type);
            const version_constraint = if (version_constraint_ptr != null)
                try allocator.dupe(u8, std.mem.span(version_constraint_ptr))
            else
                null;
            errdefer if (version_constraint) |expr| allocator.free(expr);

            try deps.append(allocator, .{
                .dependency_type = dep_type,
                .target_resource = dep_resource,
                .target_type = target_type,
                .version_constraint = version_constraint,
            });
        }

        return deps;
    }

    pub fn getPackagesByProvision(self: *RepoDB, allocator: std.mem.Allocator, resource: []const u8) !std.ArrayList(package.Package) {
        if (self.db == null) {
            return RepoDBError.FileSystem;
        }

        const sql =
            \\SELECT p.name, p.version, p.release, p.arch, p.signature, p.content_hash, p.archive_hash
            \\FROM packages p
            \\JOIN provisions v ON v.package_id = p.id
            \\WHERE v.resource = ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, resource.ptr, @intCast(resource.len), null);

        var candidates: std.ArrayList(package.Package) = .empty;
        errdefer {
            for (candidates.items) |*pkg| pkg.deinit();
            candidates.deinit(allocator);
        }

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const pkg = try self.parsePackageFromRow(stmt.?);
            candidates.append(allocator, pkg) catch |err| {
                var pkg_mut = pkg;
                pkg_mut.deinit();
                return err;
            };
        }

        if (candidates.items.len == 0) {
            return RepoDBError.PackageNotFound;
        }

        return candidates;
    }

    pub fn getLatestPackageByProvision(self: *RepoDB, allocator: std.mem.Allocator, resource: []const u8) !package.Package {
        var candidates = try self.getPackagesByProvision(allocator, resource);
        defer {
            for (candidates.items) |*pkg| pkg.deinit();
            candidates.deinit(allocator);
        }

        // Find the package with highest version using vercmp
        var best_idx: usize = 0;
        for (candidates.items[1..], 1..) |candidate, idx| {
            const best = candidates.items[best_idx];
            const cmp = ver.comparePackageVersions(
                candidate.version orelse "",
                candidate.release orelse 0,
                best.version orelse "",
                best.release orelse 0,
            ) catch return RepoDBError.InvalidInput;
            if (cmp == .greater) {
                best_idx = idx;
            }
        }

        // Move the best package out of the list before cleanup
        const result = candidates.items[best_idx];
        // Replace with a dummy to prevent double-free in defer
        candidates.items[best_idx] = package.Package.init(self.ctx);

        return result;
    }

    /// Get the latest version of a package that provides a bin resource whose
    /// basename matches the given bare name. Only matches provisions of type 'bin'.
    /// This enables resolving shebang-discovered dependencies like 'python3' against
    /// provisions stored as full paths like '/usr/bin/python3'.
    ///
    /// The search term must be a bare name (no '/' characters). If it contains a '/',
    /// callers should use getLatestPackageByProvision for exact matching instead.
    ///
    /// Errors:
    ///   - FileSystem: When database connection is not open
    ///   - CorruptData: When preparing or executing the query fails
    ///   - PackageNotFound: When no package provides a matching bin resource
    ///   - InvalidInput: When retrieved data is invalid or search term contains '/'
    ///   - OutOfMemory: When memory allocation fails
    pub fn getPackagesByBinBasename(self: *RepoDB, allocator: std.mem.Allocator, bare_name: []const u8) !std.ArrayList(package.Package) {
        if (self.db == null) {
            return RepoDBError.FileSystem;
        }

        // Only match bare names — if it contains '/', use exact provision matching
        if (std.mem.indexOfScalar(u8, bare_name, '/') != null) {
            return RepoDBError.InvalidInput;
        }

        // Match bin provisions where the resource ends with '/<bare_name>'
        // This uses SQLite LIKE with a pattern: '%/' || bare_name
        const sql =
            \\SELECT p.name, p.version, p.release, p.arch, p.signature, p.content_hash, p.archive_hash
            \\FROM packages p
            \\JOIN provisions v ON v.package_id = p.id
            \\WHERE v.type = 'bin' AND v.resource LIKE '%/' || ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt.?, 1, bare_name.ptr, @intCast(bare_name.len), null);

        var candidates: std.ArrayList(package.Package) = .empty;
        errdefer {
            for (candidates.items) |*pkg| pkg.deinit();
            candidates.deinit(allocator);
        }

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const pkg = try self.parsePackageFromRow(stmt.?);
            candidates.append(allocator, pkg) catch |err| {
                var pkg_mut = pkg;
                pkg_mut.deinit();
                return err;
            };
        }

        if (candidates.items.len == 0) {
            return RepoDBError.PackageNotFound;
        }

        return candidates;
    }

    pub fn getLatestPackageByBinBasename(self: *RepoDB, allocator: std.mem.Allocator, bare_name: []const u8) !package.Package {
        var candidates = try self.getPackagesByBinBasename(allocator, bare_name);
        defer {
            for (candidates.items) |*pkg| pkg.deinit();
            candidates.deinit(allocator);
        }

        // Find the package with highest version using vercmp
        var best_idx: usize = 0;
        for (candidates.items[1..], 1..) |candidate, idx| {
            const best = candidates.items[best_idx];
            const cmp = ver.comparePackageVersions(
                candidate.version orelse "",
                candidate.release orelse 0,
                best.version orelse "",
                best.release orelse 0,
            ) catch return RepoDBError.InvalidInput;
            if (cmp == .greater) {
                best_idx = idx;
            }
        }

        // Move the best package out of the list before cleanup
        const result = candidates.items[best_idx];
        candidates.items[best_idx] = package.Package.init(self.ctx);

        return result;
    }

    /// Inserts a package into the database (package row only, no dependencies/provisions).
    /// This is an internal function - external callers should use insertPackageTransaction.
    /// Errors:
    ///   - CorruptData: When preparing or executing the query fails
    ///   - InvalidInput: When package data is invalid or missing
    fn insertPackage(self: *RepoDB, pkg: *package.Package, properties: ?[]const u8) !i64 {
        if (pkg.name == null or pkg.name.?.len == 0 or
            pkg.version == null or pkg.version.?.len == 0 or
            pkg.release == null or
            pkg.arch == null or pkg.arch.?.len == 0 or
            (pkg.signature == null or pkg.signature.?.len == 0) or
            pkg.content_hash.len == 0 or
            pkg.archive_hash.len == 0)
        {
            return RepoDBError.InvalidInput;
        }

        const sql =
            "INSERT INTO packages (name, version, release, arch, signature, content_hash, archive_hash, properties) VALUES (?, ?, ?, ?, ?, ?, ?, ?);";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_text(stmt, 1, pkg.name.?.ptr, @intCast(pkg.name.?.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, pkg.version.?.ptr, @intCast(pkg.version.?.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, @intCast(pkg.release.?));
        _ = c.sqlite3_bind_text(stmt, 4, pkg.arch.?.ptr, @intCast(pkg.arch.?.len), null);
        _ = c.sqlite3_bind_blob(stmt, 5, pkg.signature.?.ptr, @intCast(pkg.signature.?.len), null);
        _ = c.sqlite3_bind_text(stmt, 6, pkg.content_hash.ptr, @intCast(pkg.content_hash.len), null);
        _ = c.sqlite3_bind_text(stmt, 7, pkg.archive_hash.ptr, @intCast(pkg.archive_hash.len), null);
        if (properties) |props| {
            _ = c.sqlite3_bind_text(stmt, 8, props.ptr, @intCast(props.len), null);
        } else {
            _ = c.sqlite3_bind_null(stmt, 8);
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            // Check for constraint violation (e.g., unique constraint on name/version/release)
            const extended_err = c.sqlite3_extended_errcode(self.db);
            if (extended_err == c.SQLITE_CONSTRAINT_UNIQUE or extended_err == c.SQLITE_CONSTRAINT_PRIMARYKEY) {
                return RepoDBError.PackageAlreadyExists;
            }
            return RepoDBError.CorruptData;
        }

        return c.sqlite3_last_insert_rowid(self.db);
    }

    /// Inserts a dependency for a package.
    /// Errors:
    ///   - CorruptData: When preparing or executing the query fails
    pub fn insertDependency(self: *RepoDB, pkg_id: i64, dep: package.Dependency) !void {
        const sql =
            "INSERT INTO dependencies (source_package_id, dependency_type, target_resource, target_type, version_constraint) VALUES (?, ?, ?, ?, ?);";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        const dep_type = dep.dep_type.toString();
        _ = c.sqlite3_bind_int64(stmt.?, 1, pkg_id);
        _ = c.sqlite3_bind_text(stmt.?, 2, dep_type.ptr, @intCast(dep_type.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 3, dep.resource.ptr, @intCast(dep.resource.len), null);
        _ = c.sqlite3_bind_text(stmt.?, 4, dep_type.ptr, @intCast(dep_type.len), null);
        if (dep.version_constraint) |expr| {
            _ = c.sqlite3_bind_text(stmt.?, 5, expr.ptr, @intCast(expr.len), null);
        } else {
            _ = c.sqlite3_bind_null(stmt.?, 5);
        }

        if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
            return RepoDBError.CorruptData;
        }
    }

    /// Inserts a provision for a package.
    /// Errors:
    ///   - CorruptData: When preparing or executing the query fails
    pub fn insertProvision(self: *RepoDB, pkg_id: i64, prov: package.Provision) !void {
        const sql =
            "INSERT INTO provisions (package_id, resource, type) VALUES (?, ?, ?);";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        _ = c.sqlite3_bind_int64(stmt.?, 1, pkg_id);
        _ = c.sqlite3_bind_text(stmt.?, 2, prov.resource.ptr, @intCast(prov.resource.len), null);
        const prov_type = prov.prov_type.toString();
        _ = c.sqlite3_bind_text(stmt.?, 3, prov_type.ptr, @intCast(prov_type.len), null);

        if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
            return RepoDBError.CorruptData;
        }
    }

    /// Batch-insert dependencies for a package using a single prepared statement.
    /// This prepares the INSERT once, binds each dependency in turn, executes,
    /// resets the statement, and finalizes it once at the end.
    pub fn insertDependencies(self: *RepoDB, pkg_id: i64, deps: []const package.Dependency) !void {
        if (deps.len == 0) return;

        const sql =
            "INSERT INTO dependencies (source_package_id, dependency_type, target_resource, target_type, version_constraint) VALUES (?, ?, ?, ?, ?);";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        for (deps) |dep| {
            const dep_type = dep.dep_type.toString();
            _ = c.sqlite3_bind_int64(stmt.?, 1, pkg_id);
            _ = c.sqlite3_bind_text(stmt.?, 2, dep_type.ptr, @intCast(dep_type.len), null);
            _ = c.sqlite3_bind_text(stmt.?, 3, dep.resource.ptr, @intCast(dep.resource.len), null);
            _ = c.sqlite3_bind_text(stmt.?, 4, dep_type.ptr, @intCast(dep_type.len), null);
            if (dep.version_constraint) |expr| {
                _ = c.sqlite3_bind_text(stmt.?, 5, expr.ptr, @intCast(expr.len), null);
            } else {
                _ = c.sqlite3_bind_null(stmt.?, 5);
            }

            if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
                return RepoDBError.CorruptData;
            }

            // Reset and clear bindings so next iteration can bind new values safely
            _ = c.sqlite3_reset(stmt.?);
            _ = c.sqlite3_clear_bindings(stmt.?);
        }
    }

    /// Batch-insert provisions for a package using a single prepared statement.
    pub fn insertProvisions(self: *RepoDB, pkg_id: i64, provs: []const package.Provision) !void {
        if (provs.len == 0) return;

        const sql =
            "INSERT INTO provisions (package_id, resource, type) VALUES (?, ?, ?);";

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(stmt.?);

        for (provs) |prov| {
            const prov_type = prov.prov_type.toString();
            _ = c.sqlite3_bind_int64(stmt.?, 1, pkg_id);
            _ = c.sqlite3_bind_text(stmt.?, 2, prov.resource.ptr, @intCast(prov.resource.len), null);
            _ = c.sqlite3_bind_text(stmt.?, 3, prov_type.ptr, @intCast(prov_type.len), null);

            if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
                return RepoDBError.CorruptData;
            }

            _ = c.sqlite3_reset(stmt.?);
            _ = c.sqlite3_clear_bindings(stmt.?);
        }
    }

    /// Persist a fully-constructed Package into the database inside a single
    /// transaction. This function performs only storage operations: callers are
    /// responsible for parsing, signature verification, and any artifact handling.
    ///
    /// Errors:
    ///   - FileSystem: When the DB connection is not open
    ///   - CorruptData: When SQLite operations fail
    ///   - InvalidInput: When package data is invalid (propagated from insertPackage)
    ///   - OutOfMemory: When memory allocation fails (propagated)
    pub fn insertPackageTransaction(self: *RepoDB, pkg: *package.Package, properties: ?[]const u8) !i64 {
        if (self.db == null) {
            return RepoDBError.FileSystem;
        }

        var err_msg: [*c]u8 = null;
        const begin_rc = c.sqlite3_exec(self.db, "BEGIN TRANSACTION;", null, null, &err_msg);
        if (begin_rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return RepoDBError.CorruptData;
        }

        // Insert package row
        var pkg_id: i64 = 0;
        pkg_id = self.insertPackage(pkg, properties) catch |err| {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return err;
        };

        // Batch-insert dependencies if present
        const deps_slice = pkg.dependencies.items;
        if (deps_slice.len > 0) {
            self.insertDependencies(pkg_id, deps_slice) catch |err| {
                var rbmsg: [*c]u8 = null;
                _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
                if (rbmsg != null) c.sqlite3_free(rbmsg);
                return err;
            };
        }

        // Batch-insert provisions if present
        const provs_slice = pkg.provisions.items;
        if (provs_slice.len > 0) {
            self.insertProvisions(pkg_id, provs_slice) catch |err| {
                var rbmsg: [*c]u8 = null;
                _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
                if (rbmsg != null) c.sqlite3_free(rbmsg);
                return err;
            };
        }

        const commit_rc = c.sqlite3_exec(self.db, "COMMIT;", null, null, &err_msg);
        if (commit_rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return RepoDBError.CorruptData;
        }

        return pkg_id;
    }

    fn parsePackageFromRowOffset(self: *RepoDB, stmt: *c.sqlite3_stmt, base_col: c_int) !package.Package {
        const name_ptr = c.sqlite3_column_text(stmt, base_col + 0);
        const version_ptr = c.sqlite3_column_text(stmt, base_col + 1);
        const release = c.sqlite3_column_int(stmt, base_col + 2);
        if (release < 0) {
            return RepoDBError.InvalidInput;
        }
        const arch_ptr = c.sqlite3_column_text(stmt, base_col + 3);
        const signature_blob = c.sqlite3_column_blob(stmt, base_col + 4);
        const content_hash_ptr = c.sqlite3_column_text(stmt, base_col + 5);
        const archive_hash_ptr = c.sqlite3_column_text(stmt, base_col + 6);

        if (name_ptr == null or version_ptr == null or arch_ptr == null or signature_blob == null) {
            return RepoDBError.InvalidInput;
        }

        const name = self.ctx.allocator.dupe(u8, std.mem.span(name_ptr)) catch {
            return RepoDBError.OutOfMemory;
        };
        errdefer self.ctx.allocator.free(name);

        const version = self.ctx.allocator.dupe(u8, std.mem.span(version_ptr)) catch {
            return RepoDBError.OutOfMemory;
        };
        errdefer self.ctx.allocator.free(version);

        const arch = self.ctx.allocator.dupe(u8, std.mem.span(arch_ptr)) catch {
            return RepoDBError.OutOfMemory;
        };
        errdefer self.ctx.allocator.free(arch);

        // Read signature as blob and copy into allocator-owned buffer
        const sig_len_c = c.sqlite3_column_bytes(stmt, base_col + 4);
        const sig_len = @as(usize, @intCast(sig_len_c));
        if (sig_len == 0) {
            return RepoDBError.InvalidInput;
        }
        const sig_buf = self.ctx.allocator.alloc(u8, sig_len) catch {
            return RepoDBError.OutOfMemory;
        };
        errdefer self.ctx.allocator.free(sig_buf);
        // Copy from SQLite blob pointer into allocated buffer (use context-inferred ptrCast)
        const sig_ptr: [*]const u8 = @ptrCast(signature_blob.?);
        std.mem.copyForwards(u8, sig_buf[0..sig_len], sig_ptr[0..sig_len]);
        const signature = sig_buf[0..sig_len];

        if (content_hash_ptr == null) {
            return RepoDBError.InvalidInput;
        }
        const content_hash = self.ctx.allocator.dupe(u8, std.mem.span(content_hash_ptr)) catch {
            return RepoDBError.OutOfMemory;
        };
        errdefer self.ctx.allocator.free(content_hash);
        if (archive_hash_ptr == null) {
            return RepoDBError.InvalidInput;
        }
        const archive_hash = self.ctx.allocator.dupe(u8, std.mem.span(archive_hash_ptr)) catch {
            return RepoDBError.OutOfMemory;
        };

        return package.Package{
            .ctx = self.ctx,
            .name = name,
            .version = version,
            .release = @as(u32, @intCast(release)),
            .arch = arch,
            .signature = signature,
            .dependencies = std.array_list.AlignedManaged(package.Dependency, null){
                .items = &.{},
                .capacity = 0,
                .allocator = self.ctx.allocator,
            },
            .provisions = std.array_list.AlignedManaged(package.Provision, null){
                .items = &.{},
                .capacity = 0,
                .allocator = self.ctx.allocator,
            },
            .content_hash = content_hash,
            .archive_hash = archive_hash,
        };
    }

    fn parsePackageFromRow(self: *RepoDB, stmt: *c.sqlite3_stmt) !package.Package {
        return self.parsePackageFromRowOffset(stmt, 0);
    }

    fn loadPackageRelations(self: *RepoDB, pkg_id: i64, pkg: *package.Package) !void {
        const dep_sql =
            \\SELECT dependency_type, target_resource, version_constraint
            \\FROM dependencies
            \\WHERE source_package_id = ?
        ;
        var dep_stmt: ?*c.sqlite3_stmt = null;
        const dep_rc = c.sqlite3_prepare_v2(self.db, dep_sql.ptr, @intCast(dep_sql.len), &dep_stmt, null);
        if (dep_rc != c.SQLITE_OK or dep_stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(dep_stmt.?);

        _ = c.sqlite3_bind_int64(dep_stmt.?, 1, pkg_id);
        while (c.sqlite3_step(dep_stmt.?) == c.SQLITE_ROW) {
            const dep_type_ptr = c.sqlite3_column_text(dep_stmt.?, 0);
            const dep_resource_ptr = c.sqlite3_column_text(dep_stmt.?, 1);
            const dep_version_ptr = c.sqlite3_column_text(dep_stmt.?, 2);
            if (dep_type_ptr == null or dep_resource_ptr == null) continue;

            const dep_type = package.DependencyType.fromString(std.mem.span(dep_type_ptr)) catch {
                return RepoDBError.InvalidInput;
            };
            const dep_resource = std.mem.span(dep_resource_ptr);

            const dep_version = if (dep_version_ptr != null) std.mem.span(dep_version_ptr) else null;
            var dep = package.Dependency.initWithConstraint(self.ctx.allocator, dep_resource, dep_type, dep_version) catch {
                return RepoDBError.OutOfMemory;
            };
            errdefer dep.deinit(self.ctx.allocator);
            pkg.dependencies.append(dep) catch return RepoDBError.OutOfMemory;
        }

        const prov_sql =
            \\SELECT resource, type
            \\FROM provisions
            \\WHERE package_id = ?
        ;
        var prov_stmt: ?*c.sqlite3_stmt = null;
        const prov_rc = c.sqlite3_prepare_v2(self.db, prov_sql.ptr, @intCast(prov_sql.len), &prov_stmt, null);
        if (prov_rc != c.SQLITE_OK or prov_stmt == null) return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(prov_stmt.?);

        _ = c.sqlite3_bind_int64(prov_stmt.?, 1, pkg_id);
        while (c.sqlite3_step(prov_stmt.?) == c.SQLITE_ROW) {
            const prov_resource_ptr = c.sqlite3_column_text(prov_stmt.?, 0);
            const prov_type_ptr = c.sqlite3_column_text(prov_stmt.?, 1);
            if (prov_resource_ptr == null or prov_type_ptr == null) continue;

            const prov_type = package.ProvisionType.fromString(std.mem.span(prov_type_ptr)) catch {
                return RepoDBError.InvalidInput;
            };
            const prov_resource = std.mem.span(prov_resource_ptr);

            var prov = package.Provision.init(self.ctx.allocator, prov_resource, prov_type) catch {
                return RepoDBError.OutOfMemory;
            };
            errdefer prov.deinit(self.ctx.allocator);
            pkg.provisions.append(prov) catch return RepoDBError.OutOfMemory;
        }
    }

    test "RepoDB insertPackage, insertDependency, insertProvision" {
        const th = @import("test_helpers.zig");
        var test_env = try th.createTestEnv();
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }
        var ctx = test_env.ctx;
        const db_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "test_repodb_insert.db" });
        defer ctx.allocator.free(db_path);

        var db = try RepoDB.init(&ctx, db_path, false);
        defer {
            db.deinit();
            ctx.allocator.destroy(db);
        }

        // Create a dummy package
        var pkg = @import("package.zig").Package.init(&ctx);
        defer pkg.deinit();
        pkg.name = try ctx.allocator.dupe(u8, "insert-test");
        pkg.version = try ctx.allocator.dupe(u8, "1.2.3");
        pkg.release = 42;
        // Convert hex fixture to raw signature bytes for internal representation
        const sig_hex = "deadbeef";
        const sig_len = sig_hex.len / 2;
        var sig_buf = try ctx.allocator.alloc(u8, sig_len);
        _ = try std.fmt.hexToBytes(sig_buf, sig_hex);
        pkg.signature = sig_buf[0..sig_len];
        pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
        pkg.content_hash = try ctx.allocator.dupe(u8, "dummyhash");
        pkg.archive_hash = try ctx.allocator.dupe(u8, "archivehash");

        // Insert package
        const pkg_id = try db.insertPackage(&pkg, null);

        // Insert dependency
        var dep = try @import("package.zig").Dependency.init(ctx.allocator, "libfoo.so", try @import("package.zig").DependencyType.fromString("elf-needed"));
        defer dep.deinit(ctx.allocator);
        try db.insertDependency(pkg_id, dep);

        // Insert provision
        var prov = try package.Provision.init(ctx.allocator, "libfoo.so.1", @import("package.zig").ProvisionType.elf_soname);
        defer prov.deinit(ctx.allocator);
        try db.insertProvision(pkg_id, prov);

        // Check package exists
        const sql = "SELECT name, version, release, arch, signature, content_hash, archive_hash FROM packages WHERE id = ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db.db, sql.ptr, @intCast(sql.len), &stmt, null);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
        defer _ = c.sqlite3_finalize(stmt.?);
        _ = c.sqlite3_bind_int64(stmt.?, 1, pkg_id);
        try std.testing.expect(c.sqlite3_step(stmt.?) == c.SQLITE_ROW);
        const name = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(stmt.?, 0)));
        const version = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(stmt.?, 1)));
        const release = c.sqlite3_column_int(stmt.?, 2);
        const arch = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(stmt.?, 3)));
        // Read signature as blob and compare to the original package.signature bytes
        const sig_blob_ptr = c.sqlite3_column_blob(stmt.?, 4);
        const sig_blob_len_c = c.sqlite3_column_bytes(stmt.?, 4);
        const sig_blob_len = @as(usize, @intCast(sig_blob_len_c));
        const content_hash = c.sqlite3_column_text(stmt.?, 5);
        const archive_hash = c.sqlite3_column_text(stmt.?, 6);
        try std.testing.expectEqualStrings("insert-test", name);
        try std.testing.expectEqualStrings("1.2.3", version);
        try std.testing.expectEqual(@as(c_int, 42), release);
        try std.testing.expectEqualStrings("x86_64", arch);
        try std.testing.expectEqual(@as(usize, pkg.signature.?.len), sig_blob_len);
        // Ensure the SQLite blob pointer is not null before casting and comparing
        try std.testing.expect(sig_blob_ptr != null);
        const sig_ptr: [*]const u8 = @ptrCast(sig_blob_ptr.?);
        try std.testing.expectEqualSlices(u8, pkg.signature.?, sig_ptr[0..sig_blob_len]);
        try std.testing.expect(content_hash != null and std.mem.eql(u8, std.mem.span(content_hash), "dummyhash"));
        try std.testing.expect(archive_hash != null and std.mem.eql(u8, std.mem.span(archive_hash), "archivehash"));

        // Check dependency exists
        const dep_sql = "SELECT dependency_type, target_resource FROM dependencies WHERE source_package_id = ?;";
        var dep_stmt: ?*c.sqlite3_stmt = null;
        const rc_dep = c.sqlite3_prepare_v2(db.db, dep_sql.ptr, @intCast(dep_sql.len), &dep_stmt, null);
        try std.testing.expectEqual(c.SQLITE_OK, rc_dep);
        defer _ = c.sqlite3_finalize(dep_stmt.?);
        _ = c.sqlite3_bind_int64(dep_stmt.?, 1, pkg_id);
        try std.testing.expect(c.sqlite3_step(dep_stmt.?) == c.SQLITE_ROW);
        const dep_type = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(dep_stmt.?, 0)));
        const dep_resource = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(dep_stmt.?, 1)));
        try std.testing.expectEqualStrings("elf-needed", dep_type);
        try std.testing.expectEqualStrings("libfoo.so", dep_resource);

        // Check provision exists
        const prov_sql = "SELECT resource, type FROM provisions WHERE package_id = ?;";
        var prov_stmt: ?*c.sqlite3_stmt = null;
        const rc_prov = c.sqlite3_prepare_v2(db.db, prov_sql.ptr, @intCast(prov_sql.len), &prov_stmt, null);
        try std.testing.expectEqual(c.SQLITE_OK, rc_prov);
        defer _ = c.sqlite3_finalize(prov_stmt.?);
        _ = c.sqlite3_bind_int64(prov_stmt.?, 1, pkg_id);
        try std.testing.expect(c.sqlite3_step(prov_stmt.?) == c.SQLITE_ROW);
        const prov_resource = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(prov_stmt.?, 0)));
        const prov_type = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(prov_stmt.?, 1)));
        try std.testing.expectEqualStrings("libfoo.so.1", prov_resource);
        try std.testing.expectEqualStrings("elf-soname", prov_type);
    }

    test "RepoDB dependency version_constraint persists and loads" {
        const th = @import("test_helpers.zig");
        var test_env = try th.createTestEnv();
        defer {
            test_env.cleanup();
            std.testing.allocator.destroy(test_env);
        }
        var ctx = test_env.ctx;
        const db_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "test_repodb_dep_constraint.db" });
        defer ctx.allocator.free(db_path);

        var db = try RepoDB.init(&ctx, db_path, false);
        defer {
            db.deinit();
            ctx.allocator.destroy(db);
        }

        var pkg = package.Package.init(&ctx);
        defer pkg.deinit();
        pkg.name = try ctx.allocator.dupe(u8, "libfoo-dev");
        pkg.version = try ctx.allocator.dupe(u8, "1.2.3");
        pkg.release = 4;
        pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
        pkg.signature = try ctx.allocator.dupe(u8, "sig");
        pkg.content_hash = try ctx.allocator.dupe(u8, "hash");
        pkg.archive_hash = try ctx.allocator.dupe(u8, "archivehash");

        var dep = try package.Dependency.initWithConstraint(ctx.allocator, "libfoo", .elf_needed, "=1.2.3-4");
        defer dep.deinit(ctx.allocator);
        try pkg.dependencies.append(dep);
        dep = package.Dependency{
            .resource = "",
            .dep_type = .elf_needed,
            .version_constraint = null,
        };

        _ = try db.insertPackageTransaction(&pkg, null);

        const sql = "SELECT version_constraint FROM dependencies LIMIT 1;";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db.db, sql.ptr, @intCast(sql.len), &stmt, null);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
        defer _ = c.sqlite3_finalize(stmt.?);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
        const vc_ptr = c.sqlite3_column_text(stmt.?, 0);
        try std.testing.expect(vc_ptr != null);
        try std.testing.expectEqualStrings("=1.2.3-4", std.mem.span(vc_ptr.?));

        var loaded = try db.getPackageExact("libfoo-dev", "1.2.3", 4, "x86_64");
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 1), loaded.dependencies.items.len);
        try std.testing.expect(loaded.dependencies.items[0].version_constraint != null);
        try std.testing.expectEqualStrings("=1.2.3-4", loaded.dependencies.items[0].version_constraint.?);
    }
    /// Return the set of distinct (name, arch) pairs present in the packages table.
    /// Caller owns the returned list and each string within it; free with allocator.
    pub fn getDistinctPackageNameArch(self: *RepoDB, allocator: std.mem.Allocator) RepoDBError!std.ArrayList(NameArch) {
        var result: std.ArrayList(NameArch) = .empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.name);
                allocator.free(item.arch);
            }
            result.deinit(allocator);
        }

        if (self.db == null) return RepoDBError.FileSystem;

        const sql = "SELECT DISTINCT name, arch FROM packages";
        const stmt = self.prepareStatement(sql) catch return RepoDBError.CorruptData;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name_ptr = c.sqlite3_column_text(stmt, 0);
            const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const arch_ptr = c.sqlite3_column_text(stmt, 1);
            const arch_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));

            if (name_ptr == null or arch_ptr == null) continue;

            const name_copy = allocator.dupe(u8, name_ptr[0..name_len]) catch return RepoDBError.OutOfMemory;
            errdefer allocator.free(name_copy);
            const arch_copy = allocator.dupe(u8, arch_ptr[0..arch_len]) catch return RepoDBError.OutOfMemory;

            result.append(allocator, .{ .name = name_copy, .arch = arch_copy }) catch return RepoDBError.OutOfMemory;
        }

        return result;
    }

    /// Delete a package and all its associated dependencies and provisions.
    /// This performs cascading deletion since the schema doesn't have CASCADE DELETE.
    ///
    /// Parameters:
    ///   - name: Package name
    ///   - version: Package version
    ///   - release: Package release number
    ///   - arch: Package architecture
    ///
    /// Errors:
    ///   - FileSystem: When the DB connection is not open
    ///   - CorruptData: When SQLite operations fail
    ///   - PackageNotFound: When no matching package exists
    pub fn deletePackage(
        self: *RepoDB,
        name: []const u8,
        version: []const u8,
        release: u32,
        arch: []const u8,
    ) RepoDBError!void {
        if (self.db == null) {
            return RepoDBError.FileSystem;
        }

        // First, find the package ID
        const find_sql = "SELECT id FROM packages WHERE name = ? AND version = ? AND release = ? AND arch = ?";
        var find_stmt: ?*c.sqlite3_stmt = null;
        const find_rc = c.sqlite3_prepare_v2(self.db, find_sql.ptr, @intCast(find_sql.len), &find_stmt, null);
        if (find_rc != c.SQLITE_OK or find_stmt == null) {
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(find_stmt.?);

        _ = c.sqlite3_bind_text(find_stmt.?, 1, name.ptr, @intCast(name.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(find_stmt.?, 2, version.ptr, @intCast(version.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(find_stmt.?, 3, @intCast(release));
        _ = c.sqlite3_bind_text(find_stmt.?, 4, arch.ptr, @intCast(arch.len), c.SQLITE_STATIC);

        if (c.sqlite3_step(find_stmt.?) != c.SQLITE_ROW) {
            return RepoDBError.PackageNotFound;
        }

        const pkg_id = c.sqlite3_last_insert_rowid(self.db);
        _ = pkg_id; // We'll use the id from the query result
        const found_id = c.sqlite3_column_int64(find_stmt.?, 0);

        // Begin transaction for atomic deletion
        var err_msg: [*c]u8 = null;
        const begin_rc = c.sqlite3_exec(self.db, "BEGIN TRANSACTION;", null, null, &err_msg);
        if (begin_rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return RepoDBError.CorruptData;
        }

        // Delete dependencies first (foreign key references packages)
        const del_deps_sql = "DELETE FROM dependencies WHERE source_package_id = ?";
        var del_deps_stmt: ?*c.sqlite3_stmt = null;
        const del_deps_rc = c.sqlite3_prepare_v2(self.db, del_deps_sql.ptr, @intCast(del_deps_sql.len), &del_deps_stmt, null);
        if (del_deps_rc != c.SQLITE_OK or del_deps_stmt == null) {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(del_deps_stmt.?);

        _ = c.sqlite3_bind_int64(del_deps_stmt.?, 1, found_id);
        if (c.sqlite3_step(del_deps_stmt.?) != c.SQLITE_DONE) {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return RepoDBError.CorruptData;
        }

        // Delete provisions (foreign key references packages)
        const del_provs_sql = "DELETE FROM provisions WHERE package_id = ?";
        var del_provs_stmt: ?*c.sqlite3_stmt = null;
        const del_provs_rc = c.sqlite3_prepare_v2(self.db, del_provs_sql.ptr, @intCast(del_provs_sql.len), &del_provs_stmt, null);
        if (del_provs_rc != c.SQLITE_OK or del_provs_stmt == null) {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(del_provs_stmt.?);

        _ = c.sqlite3_bind_int64(del_provs_stmt.?, 1, found_id);
        if (c.sqlite3_step(del_provs_stmt.?) != c.SQLITE_DONE) {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return RepoDBError.CorruptData;
        }

        // Delete the package itself
        const del_pkg_sql = "DELETE FROM packages WHERE id = ?";
        var del_pkg_stmt: ?*c.sqlite3_stmt = null;
        const del_pkg_rc = c.sqlite3_prepare_v2(self.db, del_pkg_sql.ptr, @intCast(del_pkg_sql.len), &del_pkg_stmt, null);
        if (del_pkg_rc != c.SQLITE_OK or del_pkg_stmt == null) {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return RepoDBError.CorruptData;
        }
        defer _ = c.sqlite3_finalize(del_pkg_stmt.?);

        _ = c.sqlite3_bind_int64(del_pkg_stmt.?, 1, found_id);
        if (c.sqlite3_step(del_pkg_stmt.?) != c.SQLITE_DONE) {
            var rbmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(self.db, "ROLLBACK;", null, null, &rbmsg);
            if (rbmsg != null) c.sqlite3_free(rbmsg);
            return RepoDBError.CorruptData;
        }

        // Commit transaction
        const commit_rc = c.sqlite3_exec(self.db, "COMMIT;", null, null, &err_msg);
        if (commit_rc != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return RepoDBError.CorruptData;
        }
    }
};

test "RepoDB.initFromVerifiedBytes queries correctly and stays usable after the source file is deleted" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const db_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "test_repodb.db" });
    defer test_env.ctx.allocator.free(db_path);

    // Build a real repo.db on disk with the normal read-write path.
    {
        var db = try RepoDB.init(&test_env.ctx, db_path, false);
        defer {
            db.deinit();
            test_env.ctx.allocator.destroy(db);
        }
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(
            db.db,
            "INSERT INTO packages (name, version, release, arch, content_hash, archive_hash) VALUES ('demo', '1.0.0', 1, 'x86_64', 'a', 'b');",
            null,
            null,
            &err_msg,
        );
        if (err_msg != null) c.sqlite3_free(err_msg);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
    }

    // Read the file's bytes exactly as sign.verifyWithTrustedFingerprints would.
    const io = path.currentIo();
    var file = try std.Io.Dir.openFileAbsolute(io, db_path, .{});
    const stat = try file.stat(io);
    const bytes = try test_env.ctx.allocator.alloc(u8, @intCast(stat.size));
    defer test_env.ctx.allocator.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    file.close(io);

    // Simulate the swap window this fix closes: remove the on-disk repo.db
    // right after "verification" reads it. A caller that let sqlite reopen
    // db_path itself (the pre-fix TOCTOU) would now fail; the deserialized
    // in-memory copy must still work.
    try std.Io.Dir.deleteFileAbsolute(io, db_path);

    var db = try RepoDB.initFromVerifiedBytes(&test_env.ctx, db_path, bytes);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    const stmt = try db.prepareStatement("SELECT name, version FROM packages WHERE name = 'demo'");
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    const name = std.mem.span(@as([*c]const u8, @ptrCast(c.sqlite3_column_text(stmt, 0))));
    try std.testing.expectEqualStrings("demo", name);

    // Read-only enforcement: a write attempt must fail.
    var write_err_msg: [*c]u8 = null;
    const write_rc = c.sqlite3_exec(db.db, "DELETE FROM packages;", null, null, &write_err_msg);
    if (write_err_msg != null) c.sqlite3_free(write_err_msg);
    try std.testing.expect(write_rc != c.SQLITE_OK);
}

test "RepoDB basic usage: init, schema, prepareStatement" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const db_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "test_repodb.db" });
    defer test_env.ctx.allocator.free(db_path);

    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }

    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Check schema_version table exists and version is 1
    const sql = "SELECT version FROM schema_version";
    const stmt = try db.prepareStatement(sql);
    defer _ = c.sqlite3_finalize(stmt);

    const rc = c.sqlite3_step(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, rc);
    const version = c.sqlite3_column_int(stmt, 0);
    try std.testing.expectEqual(@as(c_int, 1), version);
}

test "RepoDB init repairs duplicate schema versions and stays idempotent" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "duplicate_schema_version.db" });
    defer allocator.free(db_path);

    const c_db_path = try allocator.alloc(u8, db_path.len + 1);
    defer allocator.free(c_db_path);
    @memcpy(c_db_path[0..db_path.len], db_path);
    c_db_path[db_path.len] = 0;

    var sqlite_db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open(c_db_path.ptr, &sqlite_db));
    const legacy_schema =
        "CREATE TABLE schema_version (version INTEGER NOT NULL);" ++
        "INSERT INTO schema_version (version) VALUES (1);" ++
        "INSERT INTO schema_version (version) VALUES (1);";
    var err_msg: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(sqlite_db, legacy_schema, null, null, &err_msg));
    if (err_msg != null) c.sqlite3_free(err_msg);
    _ = c.sqlite3_close(sqlite_db);
    sqlite_db = null;

    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    const count_stmt = try db.prepareStatement("SELECT COUNT(*) FROM schema_version");
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(count_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(count_stmt, 0));
    _ = c.sqlite3_finalize(count_stmt);
    db.deinit();
    allocator.destroy(db);

    var reopened = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        reopened.deinit();
        allocator.destroy(reopened);
    }
    const reopened_stmt = try reopened.prepareStatement("SELECT COUNT(*) FROM schema_version");
    defer _ = c.sqlite3_finalize(reopened_stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(reopened_stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(reopened_stmt, 0));
}

test "RepoDB init rejects outdated packages schema missing archive_hash" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const db_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "outdated_repodb.db" });
    defer test_env.ctx.allocator.free(db_path);

    {
        const c_db_path = try test_env.ctx.allocator.alloc(u8, db_path.len + 1);
        defer test_env.ctx.allocator.free(c_db_path);
        @memcpy(c_db_path[0..db_path.len], db_path);
        c_db_path[db_path.len] = 0;

        var sqlite_db: ?*c.sqlite3 = null;
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open(c_db_path.ptr, &sqlite_db));
        defer _ = c.sqlite3_close(sqlite_db);

        const legacy_schema =
            \\CREATE TABLE IF NOT EXISTS schema_version (
            \\    version INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    id INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    version TEXT,
            \\    release INTEGER NOT NULL,
            \\    arch TEXT,
            \\    properties TEXT,
            \\    signature BLOB,
            \\    content_hash TEXT,
            \\    UNIQUE(name, version, release, arch)
            \\);
            \\INSERT INTO schema_version (version) VALUES (1);
        ;
        var err_msg: [*c]u8 = null;
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(sqlite_db, legacy_schema, null, null, &err_msg));
    }

    try std.testing.expectError(RepoDBError.InvalidInput, RepoDB.init(&test_env.ctx, db_path, false));
}

test "RepoDB deletePackage cascades to dependencies and provisions" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_delete.db" });
    defer allocator.free(db_path);

    // Create and open DB
    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Insert a package with dependencies and provisions
    var pkg = package.Package.init(&test_env.ctx);
    defer pkg.deinit();
    pkg.name = try allocator.dupe(u8, "testpkg");
    pkg.version = try allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try allocator.dupe(u8, "x86_64");
    pkg.signature = try allocator.dupe(u8, "testsig");
    pkg.content_hash = try allocator.dupe(u8, "testhash");
    pkg.archive_hash = try allocator.dupe(u8, "testarchivehash");

    const pkg_id = try db.insertPackage(&pkg, null);

    // Insert dependencies
    var dep1 = try package.Dependency.init(allocator, "libfoo.so", try package.DependencyType.fromString("elf-needed"));
    defer dep1.deinit(allocator);
    try db.insertDependency(pkg_id, dep1);

    var dep2 = try package.Dependency.init(allocator, "libbar.so", try package.DependencyType.fromString("elf-needed"));
    defer dep2.deinit(allocator);
    try db.insertDependency(pkg_id, dep2);

    // Insert provisions
    var prov1 = try package.Provision.init(allocator, "libtestpkg.so.1", package.ProvisionType.elf_soname);
    defer prov1.deinit(allocator);
    try db.insertProvision(pkg_id, prov1);

    var prov2 = try package.Provision.init(allocator, "/usr/bin/testpkg", package.ProvisionType.bin);
    defer prov2.deinit(allocator);
    try db.insertProvision(pkg_id, prov2);

    // Verify data was inserted
    {
        const count_deps_sql = "SELECT COUNT(*) FROM dependencies WHERE source_package_id = ?";
        var count_stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db.db, count_deps_sql.ptr, @intCast(count_deps_sql.len), &count_stmt, null);
        defer _ = c.sqlite3_finalize(count_stmt.?);
        _ = c.sqlite3_bind_int64(count_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(count_stmt.?);
        const dep_count = c.sqlite3_column_int(count_stmt.?, 0);
        try std.testing.expectEqual(@as(c_int, 2), dep_count);
    }
    {
        const count_provs_sql = "SELECT COUNT(*) FROM provisions WHERE package_id = ?";
        var count_stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db.db, count_provs_sql.ptr, @intCast(count_provs_sql.len), &count_stmt, null);
        defer _ = c.sqlite3_finalize(count_stmt.?);
        _ = c.sqlite3_bind_int64(count_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(count_stmt.?);
        const prov_count = c.sqlite3_column_int(count_stmt.?, 0);
        try std.testing.expectEqual(@as(c_int, 2), prov_count);
    }

    // Delete the package
    try db.deletePackage("testpkg", "1.0.0", 1, "x86_64");

    // Verify package is gone
    {
        const check_pkg_sql = "SELECT COUNT(*) FROM packages WHERE name = 'testpkg'";
        var check_stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db.db, check_pkg_sql.ptr, @intCast(check_pkg_sql.len), &check_stmt, null);
        defer _ = c.sqlite3_finalize(check_stmt.?);
        _ = c.sqlite3_step(check_stmt.?);
        const pkg_count = c.sqlite3_column_int(check_stmt.?, 0);
        try std.testing.expectEqual(@as(c_int, 0), pkg_count);
    }

    // Verify dependencies are gone (cascaded)
    {
        const check_deps_sql = "SELECT COUNT(*) FROM dependencies WHERE source_package_id = ?";
        var check_stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db.db, check_deps_sql.ptr, @intCast(check_deps_sql.len), &check_stmt, null);
        defer _ = c.sqlite3_finalize(check_stmt.?);
        _ = c.sqlite3_bind_int64(check_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(check_stmt.?);
        const dep_count = c.sqlite3_column_int(check_stmt.?, 0);
        try std.testing.expectEqual(@as(c_int, 0), dep_count);
    }

    // Verify provisions are gone (cascaded)
    {
        const check_provs_sql = "SELECT COUNT(*) FROM provisions WHERE package_id = ?";
        var check_stmt: ?*c.sqlite3_stmt = null;
        _ = c.sqlite3_prepare_v2(db.db, check_provs_sql.ptr, @intCast(check_provs_sql.len), &check_stmt, null);
        defer _ = c.sqlite3_finalize(check_stmt.?);
        _ = c.sqlite3_bind_int64(check_stmt.?, 1, pkg_id);
        _ = c.sqlite3_step(check_stmt.?);
        const prov_count = c.sqlite3_column_int(check_stmt.?, 0);
        try std.testing.expectEqual(@as(c_int, 0), prov_count);
    }
}

test "RepoDB deletePackage returns PackageNotFound for non-existent package" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_delete_notfound.db" });
    defer allocator.free(db_path);

    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Try to delete a package that doesn't exist
    const result = db.deletePackage("nonexistent", "1.0.0", 1, "x86_64");
    try std.testing.expectError(RepoDBError.PackageNotFound, result);
}

test "RepoDB: getLatestPackageByName, getDependenciesForPackage, getLatestPackageByProvision" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_repodb.db" });
    defer allocator.free(db_path);

    // Create and open DB
    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Insert test data using prepared statements
    {
        // Create package 'foo' 1.0.0
        var p1 = package.Package.init(&test_env.ctx);
        defer p1.deinit();
        p1.name = try allocator.dupe(u8, "foo");
        p1.version = try allocator.dupe(u8, "1.0.0");
        p1.release = 1;
        p1.arch = try allocator.dupe(u8, "x86_64");
        p1.signature = try allocator.dupe(u8, "sig1");
        p1.content_hash = try allocator.dupe(u8, "h1");
        p1.archive_hash = try allocator.dupe(u8, "ah1");
        _ = try db.insertPackage(&p1, null);

        // Create package 'foo' 1.0.1 (the one that will have dependency/provision)
        var p2 = package.Package.init(&test_env.ctx);
        defer p2.deinit();
        p2.name = try allocator.dupe(u8, "foo");
        p2.version = try allocator.dupe(u8, "1.0.1");
        p2.release = 2;
        p2.arch = try allocator.dupe(u8, "x86_64");
        p2.signature = try allocator.dupe(u8, "sig2");
        p2.content_hash = try allocator.dupe(u8, "h2");
        p2.archive_hash = try allocator.dupe(u8, "ah2");
        const p2_id = try db.insertPackage(&p2, null);

        // Create package 'bar' 2.0.0
        var p3 = package.Package.init(&test_env.ctx);
        defer p3.deinit();
        p3.name = try allocator.dupe(u8, "bar");
        p3.version = try allocator.dupe(u8, "2.0.0");
        p3.release = 1;
        p3.arch = try allocator.dupe(u8, "x86_64");
        p3.signature = try allocator.dupe(u8, "sig3");
        p3.content_hash = try allocator.dupe(u8, "h3");
        p3.archive_hash = try allocator.dupe(u8, "ah3");
        _ = try db.insertPackage(&p3, null);

        // Insert dependency for p2 -> libbar.so
        var dep = try package.Dependency.init(allocator, "libbar.so", try package.DependencyType.fromString("elf-needed"));
        defer dep.deinit(allocator);
        try db.insertDependency(p2_id, dep);

        // Insert provision for p2 -> libfoo.so.1
        var prov = try package.Provision.init(allocator, "libfoo.so.1", package.ProvisionType.elf_soname);
        defer prov.deinit(allocator);
        try db.insertProvision(p2_id, prov);
    }

    // Test getLatestPackageByName
    {
        var pkg = try db.getLatestPackageByName(allocator, "foo");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("foo", pkg.name.?);
        try std.testing.expectEqualStrings("1.0.1", pkg.version.?);
        try std.testing.expectEqual(@as(u32, 2), pkg.release.?);
        try std.testing.expect(std.mem.eql(u8, pkg.signature.?, "sig2"));
    }

    // Test getDependenciesForPackage
    {
        var deps = try db.getDependenciesForPackage(allocator, "foo");
        defer {
            for (deps.items) |*dep| dep.deinit(allocator);
            deps.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), deps.items.len);
        try std.testing.expectEqualStrings("libbar.so", deps.items[0].resource);
        try std.testing.expectEqual(package.DependencyType.elf_needed, deps.items[0].dep_type);
    }

    // Test getLatestPackageByProvision
    {
        var pkg = try db.getLatestPackageByProvision(allocator, "libfoo.so.1");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("foo", pkg.name.?);
        try std.testing.expectEqualStrings("1.0.1", pkg.version.?);
        try std.testing.expectEqual(@as(u32, 2), pkg.release.?);
        try std.testing.expect(std.mem.eql(u8, pkg.signature.?, "sig2"));
    }
}

test "RepoDB: getLatestPackageByBinBasename matches bare names against bin provisions" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_bin_basename.db" });
    defer allocator.free(db_path);

    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Insert package 'python' with bin provision '/usr/bin/python3'
    {
        var p1 = package.Package.init(&test_env.ctx);
        defer p1.deinit();
        p1.name = try allocator.dupe(u8, "python");
        p1.version = try allocator.dupe(u8, "3.12.0");
        p1.release = 1;
        p1.arch = try allocator.dupe(u8, "x86_64");
        p1.signature = try allocator.dupe(u8, "sig_py");
        p1.content_hash = try allocator.dupe(u8, "hash_py");
        p1.archive_hash = try allocator.dupe(u8, "archive_hash_py");
        const p1_id = try db.insertPackage(&p1, null);

        var prov = try package.Provision.init(allocator, "/usr/bin/python3", .bin);
        defer prov.deinit(allocator);
        try db.insertProvision(p1_id, prov);
    }

    // Insert package 'bash' with bin provision '/bin/bash'
    {
        var p2 = package.Package.init(&test_env.ctx);
        defer p2.deinit();
        p2.name = try allocator.dupe(u8, "bash");
        p2.version = try allocator.dupe(u8, "5.2.0");
        p2.release = 1;
        p2.arch = try allocator.dupe(u8, "x86_64");
        p2.signature = try allocator.dupe(u8, "sig_bash");
        p2.content_hash = try allocator.dupe(u8, "hash_bash");
        p2.archive_hash = try allocator.dupe(u8, "archive_hash_bash");
        const p2_id = try db.insertPackage(&p2, null);

        var prov = try package.Provision.init(allocator, "/bin/bash", .bin);
        defer prov.deinit(allocator);
        try db.insertProvision(p2_id, prov);
    }

    // Insert package 'coreutils' with elf-soname provision (should NOT match basename search)
    {
        var p3 = package.Package.init(&test_env.ctx);
        defer p3.deinit();
        p3.name = try allocator.dupe(u8, "coreutils");
        p3.version = try allocator.dupe(u8, "9.0");
        p3.release = 1;
        p3.arch = try allocator.dupe(u8, "x86_64");
        p3.signature = try allocator.dupe(u8, "sig_cu");
        p3.content_hash = try allocator.dupe(u8, "hash_cu");
        p3.archive_hash = try allocator.dupe(u8, "archive_hash_cu");
        const p3_id = try db.insertPackage(&p3, null);

        var prov = try package.Provision.init(allocator, "libcoreutils.so.1", .elf_soname);
        defer prov.deinit(allocator);
        try db.insertProvision(p3_id, prov);
    }

    // Bare name "python3" should match "/usr/bin/python3" -> package "python"
    {
        var pkg = try db.getLatestPackageByBinBasename(allocator, "python3");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("python", pkg.name.?);
        try std.testing.expectEqualStrings("3.12.0", pkg.version.?);
    }

    // Bare name "bash" should match "/bin/bash" -> package "bash"
    {
        var pkg = try db.getLatestPackageByBinBasename(allocator, "bash");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("bash", pkg.name.?);
    }

    // Name with '/' should be rejected as InvalidInput
    {
        const result = db.getLatestPackageByBinBasename(allocator, "/usr/bin/python3");
        try std.testing.expectError(RepoDBError.InvalidInput, result);
    }

    // Non-existent bare name should return PackageNotFound
    {
        const result = db.getLatestPackageByBinBasename(allocator, "nonexistent");
        try std.testing.expectError(RepoDBError.PackageNotFound, result);
    }

    // elf-soname provision should NOT be matched by basename search
    {
        const result = db.getLatestPackageByBinBasename(allocator, "libcoreutils.so.1");
        try std.testing.expectError(RepoDBError.PackageNotFound, result);
    }
}

test "RepoDB resolveTransitiveDependencies resolves all dependencies recursively" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;
    const allocator = ctx.allocator;

    // Create and open DB
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_dep_resolve.db" });
    defer allocator.free(db_path);
    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&ctx, db_path, false);
    defer {
        db.deinit();
        ctx.allocator.destroy(db);
    }

    // Insert test data: A -> B -> C using prepared statements
    {
        var pA = package.Package.init(&ctx);
        defer pA.deinit();
        pA.name = try allocator.dupe(u8, "A");
        pA.version = try allocator.dupe(u8, "1.0.0");
        pA.release = 1;
        pA.arch = try allocator.dupe(u8, "x86_64");
        pA.signature = try allocator.dupe(u8, "sigA");
        pA.content_hash = try allocator.dupe(u8, "hA");
        pA.archive_hash = try allocator.dupe(u8, "ahA");
        const idA = try db.insertPackage(&pA, null);

        var pB = package.Package.init(&ctx);
        defer pB.deinit();
        pB.name = try allocator.dupe(u8, "B");
        pB.version = try allocator.dupe(u8, "1.0.0");
        pB.release = 1;
        pB.arch = try allocator.dupe(u8, "x86_64");
        pB.signature = try allocator.dupe(u8, "sigB");
        pB.content_hash = try allocator.dupe(u8, "hB");
        pB.archive_hash = try allocator.dupe(u8, "ahB");
        const idB = try db.insertPackage(&pB, null);

        var pC = package.Package.init(&ctx);
        defer pC.deinit();
        pC.name = try allocator.dupe(u8, "C");
        pC.version = try allocator.dupe(u8, "1.0.0");
        pC.release = 1;
        pC.arch = try allocator.dupe(u8, "x86_64");
        pC.signature = try allocator.dupe(u8, "sigC");
        pC.content_hash = try allocator.dupe(u8, "hC");
        pC.archive_hash = try allocator.dupe(u8, "ahC");
        _ = try db.insertPackage(&pC, null);

        // A -> B
        var depAB = try package.Dependency.init(allocator, "B", try package.DependencyType.fromString("elf-needed"));
        defer depAB.deinit(allocator);
        try db.insertDependency(idA, depAB);

        // B -> C
        var depBC = try package.Dependency.init(allocator, "C", try package.DependencyType.fromString("elf-needed"));
        defer depBC.deinit(allocator);
        try db.insertDependency(idB, depBC);
    }
}

// Spec #3: Vercmp splits into digit/non-digit runs and compares correctly
test "RepoDB vercmp correctly orders 1.10 > 1.9" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_vercmp.db" });
    defer allocator.free(db_path);

    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Insert versions that would be misordered by string comparison
    // String ordering: "1.10" < "1.9" (because '1' < '9')
    // Correct vercmp: "1.10" > "1.9" (because 10 > 9)
    {
        // Insert 1.9 first
        var p1 = package.Package.init(&test_env.ctx);
        defer p1.deinit();
        p1.name = try allocator.dupe(u8, "testpkg");
        p1.version = try allocator.dupe(u8, "1.9");
        p1.release = 1;
        p1.arch = try allocator.dupe(u8, "x86_64");
        p1.signature = try allocator.dupe(u8, "sig1");
        p1.content_hash = try allocator.dupe(u8, "h1");
        p1.archive_hash = try allocator.dupe(u8, "ah1");
        _ = try db.insertPackage(&p1, null);

        // Insert 1.10 second (higher version, but string-sorts lower)
        var p2 = package.Package.init(&test_env.ctx);
        defer p2.deinit();
        p2.name = try allocator.dupe(u8, "testpkg");
        p2.version = try allocator.dupe(u8, "1.10");
        p2.release = 1;
        p2.arch = try allocator.dupe(u8, "x86_64");
        p2.signature = try allocator.dupe(u8, "sig2");
        p2.content_hash = try allocator.dupe(u8, "h2");
        p2.archive_hash = try allocator.dupe(u8, "ah2");
        _ = try db.insertPackage(&p2, null);
    }

    // getLatestPackageByName should return 1.10, not 1.9
    {
        var pkg = try db.getLatestPackageByName(allocator, "testpkg");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("1.10", pkg.version.?);
    }
}

// Spec #3: Epoch prefix overrides version comparison
test "RepoDB vercmp handles epoch correctly" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_vercmp_epoch.db" });
    defer allocator.free(db_path);

    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Epoch should take precedence: 1:1.0 > 2.0
    {
        var p1 = package.Package.init(&test_env.ctx);
        defer p1.deinit();
        p1.name = try allocator.dupe(u8, "epochpkg");
        p1.version = try allocator.dupe(u8, "2.0");
        p1.release = 1;
        p1.arch = try allocator.dupe(u8, "x86_64");
        p1.signature = try allocator.dupe(u8, "sig1");
        p1.content_hash = try allocator.dupe(u8, "h1");
        p1.archive_hash = try allocator.dupe(u8, "ah1");
        _ = try db.insertPackage(&p1, null);

        var p2 = package.Package.init(&test_env.ctx);
        defer p2.deinit();
        p2.name = try allocator.dupe(u8, "epochpkg");
        p2.version = try allocator.dupe(u8, "1:1.0");
        p2.release = 1;
        p2.arch = try allocator.dupe(u8, "x86_64");
        p2.signature = try allocator.dupe(u8, "sig2");
        p2.content_hash = try allocator.dupe(u8, "h2");
        p2.archive_hash = try allocator.dupe(u8, "ah2");
        _ = try db.insertPackage(&p2, null);
    }

    // getLatestPackageByName should return 1:1.0 (epoch 1 wins over no epoch)
    {
        var pkg = try db.getLatestPackageByName(allocator, "epochpkg");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("1:1.0", pkg.version.?);
    }
}

// Spec #3: Tilde sorts before everything including empty string
test "RepoDB vercmp handles tilde pre-release correctly" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;
    const db_path = try std.fs.path.join(allocator, &.{ test_env.path, "test_vercmp_tilde.db" });
    defer allocator.free(db_path);

    {
        const f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }
    var db = try RepoDB.init(&test_env.ctx, db_path, false);
    defer {
        db.deinit();
        test_env.ctx.allocator.destroy(db);
    }

    // Tilde sorts before release: 1.0~rc1 < 1.0
    {
        var p1 = package.Package.init(&test_env.ctx);
        defer p1.deinit();
        p1.name = try allocator.dupe(u8, "tildepkg");
        p1.version = try allocator.dupe(u8, "1.0~rc1");
        p1.release = 1;
        p1.arch = try allocator.dupe(u8, "x86_64");
        p1.signature = try allocator.dupe(u8, "sig1");
        p1.content_hash = try allocator.dupe(u8, "h1");
        p1.archive_hash = try allocator.dupe(u8, "ah1");
        _ = try db.insertPackage(&p1, null);

        var p2 = package.Package.init(&test_env.ctx);
        defer p2.deinit();
        p2.name = try allocator.dupe(u8, "tildepkg");
        p2.version = try allocator.dupe(u8, "1.0");
        p2.release = 1;
        p2.arch = try allocator.dupe(u8, "x86_64");
        p2.signature = try allocator.dupe(u8, "sig2");
        p2.content_hash = try allocator.dupe(u8, "h2");
        p2.archive_hash = try allocator.dupe(u8, "ah2");
        _ = try db.insertPackage(&p2, null);
    }

    // getLatestPackageByName should return 1.0, not 1.0~rc1
    {
        var pkg = try db.getLatestPackageByName(allocator, "tildepkg");
        defer pkg.deinit();
        try std.testing.expectEqualStrings("1.0", pkg.version.?);
    }
}
