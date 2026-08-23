const std = @import("std");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const Repository = @import("repository.zig").Repository;
const Package = @import("package.zig").Package;
const download = @import("download.zig");
const sign = @import("sign.zig");
const path = @import("path.zig");
const kdl = @import("kdl.zig");
const repo_history = @import("repo_history.zig");
const ui = @import("ui/mod.zig");
const hash = @import("hash.zig");

/// Repository cache operations error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during cache operations
/// - FileSystem: Cache file operations failed
/// - Network: Remote repository download failed
/// - PermissionDenied: Insufficient permissions for cache operations
/// - SignatureInvalid: Cache signature verification failed
const Std = errors.StandardErrors;
pub const RepoCacheError = Std.OutOfMemory || Std.FileSystem || Std.Network || Std.PermissionDenied || Std.SignatureInvalid || Std.CorruptData;

pub const SyncOptions = struct {
    force: bool = false,
    interval_seconds: u64 = default_sync_interval_seconds,
    timeout_seconds: u32 = default_sync_timeout_seconds,
    /// Ordinary operations retain availability by falling back to a verified
    /// cache. The explicit `mere sync` operation disables this fallback.
    allow_stale_fallback: bool = true,
    /// Override current time (unix seconds) for tests.
    now: ?u64 = null,
};

const default_sync_interval_seconds: u64 = 15 * 60;
const default_sync_timeout_seconds: u32 = 30;

/// Compute the cache identity hash for a repo's trust context.
/// Returns "{name}-{hex16}" where hex16 is the first 16 characters of the
/// lowercase hex encoding of BLAKE3(sorted_fingerprints || "\0" || name).
///
/// Algorithm:
/// 1. Sort fingerprints lexicographically
/// 2. Concatenate: sorted_fp1 ++ sorted_fp2 ++ ... ++ "\0" ++ name
/// 3. BLAKE3 hash the concatenation
/// 4. Take first 16 hex characters
///
/// Caller owns returned memory.
fn computeCacheIdentity(
    allocator: std.mem.Allocator,
    name: []const u8,
    fingerprints: []const []const u8,
) ![]const u8 {
    // Make a mutable copy of the fingerprint slice for sorting
    const sorted = try allocator.alloc([]const u8, fingerprints.len);
    defer allocator.free(sorted);
    @memcpy(sorted, fingerprints);

    // Sort lexicographically
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Hash: sorted fingerprints concatenated, then "\0", then name
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (sorted) |fp| {
        hasher.update(fp);
    }
    hasher.update("\x00");
    hasher.update(name);

    var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(&digest);

    // Take first 8 bytes (16 hex chars)
    const hex16 = std.fmt.bytesToHex(digest[0..8].*, .lower);

    // Format as "{name}-{hex16}"
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, hex16[0..16] });
}

pub const RepoCache = struct {
    /// Context for logging and allocation
    ctx: *mere.Context,
    /// The configuration name of the repository (owned)
    name: []const u8,
    /// The remote/source URL (owned)
    url: []const u8,
    /// Absolute path to the local cache directory (owned)
    cache_dir: []const u8,
    /// Allowlist of trusted key fingerprints for signature verification (owned)
    trusted_fingerprints: []const []const u8,
    /// The managed local Repository instance (directory, db, packages)
    repository: ?Repository,
    /// Repository priority for conflict resolution (lower number = higher priority)
    priority: u8 = 100,
    /// Whether this is a local (file://) repository
    is_local: bool = false,
    /// Automatic refresh interval in seconds (remote repos only; local repos ignore)
    sync_interval_seconds: u64 = default_sync_interval_seconds,
    /// Sync timeout in seconds (remote repos only; local repos ignore)
    sync_timeout_seconds: u32 = default_sync_timeout_seconds,

    // Additional fields for sync status, last update time, etc. can be added here.

    /// Initialize a RepoCache.
    ///
    /// This constructor takes ownership by duping all input strings.
    /// Callers must call deinit() to free all owned state.
    pub fn init(
        ctx: *mere.Context,
        name: []const u8,
        url: []const u8,
        trusted_fingerprints: []const []const u8,
        priority: u8,
    ) !RepoCache {
        const allocator = ctx.allocator;

        const owned_name = allocator.dupe(u8, name) catch return RepoCacheError.OutOfMemory;
        errdefer allocator.free(owned_name);

        const owned_url = allocator.dupe(u8, url) catch return RepoCacheError.OutOfMemory;
        errdefer allocator.free(owned_url);

        const owned_fps = dupeFingerprints(allocator, trusted_fingerprints) catch return RepoCacheError.OutOfMemory;
        errdefer freeFingerprints(allocator, owned_fps);

        const identity = computeCacheIdentity(allocator, owned_name, owned_fps) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(identity);

        const local = std.mem.startsWith(u8, owned_url, "file://");
        const cache_dir = if (local)
            allocator.dupe(u8, owned_url["file://".len..]) catch {
                return RepoCacheError.OutOfMemory;
            }
        else
            std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "cache", "repos", identity }) catch {
                return RepoCacheError.OutOfMemory;
            };
        errdefer allocator.free(cache_dir);

        return RepoCache{
            .ctx = ctx,
            .name = owned_name,
            .url = owned_url,
            .cache_dir = cache_dir,
            .trusted_fingerprints = owned_fps,
            .repository = null,
            .priority = priority,
            .is_local = local,
            .sync_interval_seconds = default_sync_interval_seconds,
            .sync_timeout_seconds = default_sync_timeout_seconds,
        };
    }

    pub fn fromConfig(
        ctx: *mere.Context,
        config: *const @import("config.zig").RepoConfig,
    ) !RepoCache {
        var cache = try RepoCache.init(
            ctx,
            config.name,
            config.url,
            config.trusted_fingerprints.items,
            config.priority,
        );
        cache.sync_interval_seconds = config.sync_interval_seconds;
        cache.sync_timeout_seconds = config.sync_timeout_seconds;
        return cache;
    }

    /// Open the cached repository database, verifying it against
    /// trusted_fingerprints first. This is the single choke point every
    /// caller passes through before ever reading from the database, so it
    /// catches the case sync() itself doesn't: a repo.db that was verified
    /// at some earlier download but has been usable (and trusted) ever
    /// since with no re-check - including when sync() was skipped
    /// entirely (TTL, or the caller opted out of syncing) or fell back to
    /// stale cached metadata after a failed sync.
    pub fn ensureRepository(self: *RepoCache, loaded_keys: []const sign.LoadedKey) !void {
        if (self.repository == null) {
            var verify_result = try self.verifyCachedDb(loaded_keys);
            defer verify_result.deinit(self.ctx.allocator);

            // Open sqlite directly against the bytes just verified, rather
            // than letting it reopen cache_dir's repo.db from disk — see
            // RepoDB.initFromVerifiedBytes.
            self.repository = Repository.initFromVerifiedBytes(self.ctx, self.cache_dir, verify_result.file_bytes) catch |err| {
                const diag = self.ctx.getDiagnosticContext();
                if (diag.details == null) {
                    self.ctx.setDiagnosticContextFmt(self.cache_dir, "failed to initialize repository: {s}", .{@errorName(err)});
                }
                return switch (err) {
                    error.OutOfMemory => RepoCacheError.OutOfMemory,
                    error.PermissionDenied => RepoCacheError.PermissionDenied,
                    else => RepoCacheError.FileSystem,
                };
            };
        }
    }

    /// Verify the repo.db currently sitting in cache_dir against
    /// trusted_fingerprints. Shared by ensureRepository() (every repo,
    /// every open) and syncLocal() (local repos specifically, so a bad
    /// signature is caught at sync time with a clear error rather than
    /// deferred to whenever the database is first opened).
    fn verifyCachedDb(self: *RepoCache, loaded_keys: []const sign.LoadedKey) RepoCacheError!sign.VerifyFileResult {
        const allocator = self.ctx.allocator;
        const paths = try buildRepoPaths(self, allocator);
        defer {
            allocator.free(paths.db_path);
            allocator.free(paths.sig_path);
        }

        if (self.trusted_fingerprints.len == 0) {
            self.ctx.setDiagnosticContext(self.name, "no trusted fingerprints configured for repository");
            return RepoCacheError.SignatureInvalid;
        }

        return sign.verifyWithTrustedFingerprints(self.ctx, paths.db_path, paths.sig_path, self.trusted_fingerprints, loaded_keys) catch {
            const diag = self.ctx.getDiagnosticContext();
            if (diag.details) |details| {
                self.ctx.setDiagnosticContext(self.name, details);
            } else {
                self.ctx.setDiagnosticContext(self.name, "failed to verify repository database signature");
            }
            return RepoCacheError.SignatureInvalid;
        };
    }

    /// Deinitialize a RepoCache, cleaning up resources owned by this object.
    ///
    /// NOTE: RepoCache borrows its name/url/fingerprint metadata and owns only
    /// its cache_dir plus any initialized repository state.
    pub fn deinit(self: *RepoCache) void {
        if (self.repository) |*repo| {
            repo.deinit();
        }
        self.ctx.allocator.free(self.cache_dir);
        freeFingerprints(self.ctx.allocator, self.trusted_fingerprints);
        self.ctx.allocator.free(self.name);
        self.ctx.allocator.free(self.url);
    }

    /// Returns the path to the local cache directory: /mere/cache/[repo-name]
    /// Ownership: Borrowed slice owned by RepoCache.
    pub fn cacheDir(self: RepoCache) []const u8 {
        return self.cache_dir;
    }

    /// Syncs the remote repository DB and signature into the local cache directory.
    ///
    /// Errors:
    ///   - OutOfMemory: When memory allocation fails
    ///   - FileSystem: When file operations fail
    ///   - PermissionDenied: When file permissions prevent operations
    ///   - SignatureInvalid: When the repository signature is invalid
    /// Syncs the remote repository DB and signature using a provided transfer client.
    pub fn sync(
        self: *RepoCache,
        client: download.TransferClient,
        options: SyncOptions,
        loaded_keys: []const sign.LoadedKey,
    ) !void {
        // Local repos point cache_dir directly at the source directory.
        // No download needed — just verify the signature in-place.
        if (self.is_local) {
            try self.syncLocal(loaded_keys);
            ui.emit.logFmtSeverity(self.ctx, null, .info, "verified local repository metadata for {s}", .{self.name});
            return;
        }

        const allocator = self.ctx.allocator;
        const cache_dir = self.cache_dir;
        const now: u64 = if (options.now) |forced| forced else @intCast(std.Io.Clock.real.now(path.currentIo()).toSeconds());

        // Synchronize the check/download/publish sequence per repository. The
        // lock is deliberately narrower than Mere's root-wide mutation lock,
        // so searches and operations using unrelated repositories do not
        // serialize each other.
        var cache_dir_handle = path.makePathAndOpenDirMode(cache_dir, std.Io.File.Permissions.fromMode(0o1777)) catch |err| {
            return switch (err) {
                error.FileNotFound => RepoCacheError.FileSystem,
                error.AccessDenied => RepoCacheError.PermissionDenied,
                else => RepoCacheError.FileSystem,
            };
        };
        cache_dir_handle.close(path.currentIo());
        const sync_lock_fd = try acquireSyncLock(self);
        defer releaseSyncLock(sync_lock_fd);

        // Re-check freshness after acquiring the lock: another process may
        // have completed the refresh while this caller was waiting.
        if (!options.force) {
            if (try shouldSkipSync(self, now, options.interval_seconds)) {
                return;
            }
        }

        // Build remote URLs (null-terminated for curl client).
        // Remote repo URLs are directory roots that contain repo.db, repo.db.sig, and packages/.
        const db_url = remoteRepoDbUrl(allocator, self.url) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(db_url);

        const sig_url = remoteRepoSigUrl(allocator, self.url) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(sig_url);

        // Build local paths
        const db_path = std.fs.path.join(allocator, &.{ cache_dir, repo_history.REPO_DB_FILENAME }) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(db_path);

        const sig_path = std.fs.path.join(allocator, &.{ cache_dir, repo_history.REPO_SIG_FILENAME }) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(sig_path);

        // Download to temporary files first
        const db_tmp = std.fs.path.join(allocator, &.{ cache_dir, ".repo.db.tmp" }) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(db_tmp);

        const sig_tmp = std.fs.path.join(allocator, &.{ cache_dir, ".repo.db.sig.tmp" }) catch {
            return RepoCacheError.OutOfMemory;
        };
        defer allocator.free(sig_tmp);

        const sync_result = syncDownloadAndVerify(
            self,
            client,
            db_url,
            sig_url,
            db_tmp,
            sig_tmp,
            db_path,
            sig_path,
            options.timeout_seconds,
            loaded_keys,
        );
        if (sync_result) |_| {
            // best-effort: failing to write last_sync should not abort install
            writeLastSync(self, now) catch |err| {
                self.ctx.debug("failed to write last_sync.kdl for repo {s}: {s}", .{ self.name, @errorName(err) });
            };

            ui.emit.logFmtSeverity(self.ctx, null, .info, "refreshed repository metadata for {s}", .{self.name});
            return;
        } else |err| {
            if (options.allow_stale_fallback and try cacheUsable(self)) {
                const hint = if (err == RepoCacheError.PermissionDenied)
                    " (permission denied — check ownership of cache directory)"
                else
                    "";
                const age = try cacheAgeSeconds(self, now);
                if (age) |seconds| {
                    ui.emit.logFmtSeverity(self.ctx, null, .warn, "sync failed for repo {s}{s}; using verified cached metadata ({d}s old)", .{ self.name, hint, seconds });
                } else {
                    ui.emit.logFmtSeverity(self.ctx, null, .warn, "sync failed for repo {s}{s}; using verified cached metadata", .{ self.name, hint });
                }
                return;
            }
            return err;
        }
    }

    /// Sync a local (file://) repository.
    ///
    /// There is nothing to download — cache_dir points directly at the
    /// source directory — but the signature still needs checking here.
    /// Auto-discovered dev repos (repo_sources.zig) verify before ever
    /// constructing a RepoCache, but a file:// repo declared in config.kdl
    /// reaches this path with its own trusted_fingerprints unverified.
    fn syncLocal(self: *RepoCache, loaded_keys: []const sign.LoadedKey) RepoCacheError!void {
        var verify_result = try self.verifyCachedDb(loaded_keys);
        verify_result.deinit(self.ctx.allocator);
        self.ctx.debug("local repo {s}: signature verification passed", .{self.name});
    }

    pub fn archiveCacheDir(self: *RepoCache) ![]const u8 {
        return std.fs.path.join(self.ctx.allocator, &.{ self.ctx.root_path, "mere", "cache", "packages" }) catch {
            return RepoCacheError.OutOfMemory;
        };
    }

    pub fn archiveCachePath(
        self: *RepoCache,
        pkg: *const Package,
    ) ![]const u8 {
        const archive_dir = try self.archiveCacheDir();
        defer self.ctx.allocator.free(archive_dir);
        const filename = pkg.canonicalArchiveName() catch {
            return RepoCacheError.OutOfMemory;
        };
        defer self.ctx.allocator.free(filename);
        return std.fs.path.join(self.ctx.allocator, &.{ archive_dir, filename }) catch {
            return RepoCacheError.OutOfMemory;
        };
    }

    pub fn archiveUrl(self: *RepoCache, pkg: *const Package) ![:0]const u8 {
        const archive_name = pkg.canonicalArchiveName() catch {
            return RepoCacheError.OutOfMemory;
        };
        defer self.ctx.allocator.free(archive_name);
        const archive_base_url = try self.archiveBaseUrl();
        defer self.ctx.allocator.free(archive_base_url);

        const result = std.fmt.allocPrint(self.ctx.allocator, "{s}/{s}\x00", .{ archive_base_url, archive_name }) catch {
            return RepoCacheError.OutOfMemory;
        };
        return @ptrCast(result[0 .. result.len - 1 :0]);
    }

    pub fn ensurePackageArchiveCached(self: *RepoCache, pkg: *const Package, client: download.TransferClient) ![]u8 {
        const dest_path = try self.archiveCachePath(pkg);
        defer self.ctx.allocator.free(dest_path);

        std.Io.Dir.accessAbsolute(path.currentIo(), dest_path, .{}) catch {
            const cache_dir = try self.archiveCacheDir();
            defer self.ctx.allocator.free(cache_dir);

            path.ensureDirExists(cache_dir) catch |err| {
                return self.ctx.fail(err, cache_dir, "failed to create package cache directory");
            };

            const archive_url = try self.archiveUrl(pkg);
            defer self.ctx.allocator.free(archive_url);

            try download.downloadFile(client, self.ctx, archive_url, dest_path, download.DownloadOptions{
                .expected_hash = if (pkg.archive_hash.len > 0) pkg.archive_hash else null,
            });
        };

        return try self.ctx.allocator.dupe(u8, dest_path);
    }

    /// Resolve the base URL used for archive fetches.
    /// All repos use "<repo-url>/packages" — local repos have file:// URLs
    /// that already point at the directory containing repo.db, so
    /// "<file://...>/packages" resolves to the packages/ subdir.
    fn archiveBaseUrl(self: *RepoCache) ![]const u8 {
        const url_base = trimTrailingSlash(self.url);
        return std.fmt.allocPrint(self.ctx.allocator, "{s}/packages", .{url_base}) catch {
            return RepoCacheError.OutOfMemory;
        };
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    if (url.len > 0 and url[url.len - 1] == '/') {
        return url[0 .. url.len - 1];
    }
    return url;
}

fn remoteRepoDbUrl(allocator: std.mem.Allocator, repo_url: []const u8) ![:0]u8 {
    const url_base = trimTrailingSlash(repo_url);
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ url_base, repo_history.REPO_DB_FILENAME }, 0);
}

fn remoteRepoSigUrl(allocator: std.mem.Allocator, repo_url: []const u8) ![:0]u8 {
    const url_base = trimTrailingSlash(repo_url);
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ url_base, repo_history.REPO_SIG_FILENAME }, 0);
}

const last_sync_filename = "last_sync.kdl";

fn lastSyncPath(self: *RepoCache) RepoCacheError![]const u8 {
    return std.fs.path.join(self.ctx.allocator, &.{ self.cache_dir, last_sync_filename }) catch {
        return RepoCacheError.OutOfMemory;
    };
}

fn readLastSync(self: *RepoCache, allocator: std.mem.Allocator) RepoCacheError!?u64 {
    const path_buf = try lastSyncPath(self);
    defer allocator.free(path_buf);

    const io = path.currentIo();
    const file = std.Io.Dir.openFileAbsolute(io, path_buf, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => null,
            error.AccessDenied => RepoCacheError.PermissionDenied,
            else => RepoCacheError.FileSystem,
        };
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        return switch (err) {
            error.AccessDenied => RepoCacheError.PermissionDenied,
            else => RepoCacheError.FileSystem,
        };
    };

    if (stat.size > 64 * 1024) {
        return null;
    }

    const buffer = allocator.alloc(u8, @intCast(stat.size)) catch {
        return RepoCacheError.OutOfMemory;
    };
    defer allocator.free(buffer);

    const bytes_read = file.readPositionalAll(io, buffer, 0) catch |err| {
        return switch (err) {
            error.AccessDenied => RepoCacheError.PermissionDenied,
            else => RepoCacheError.FileSystem,
        };
    };
    if (bytes_read != stat.size) {
        return RepoCacheError.FileSystem;
    }

    var nodes = kdl.parseDocument(allocator, buffer) catch {
        return null;
    };
    defer {
        for (nodes.items) |*node| node.deinit();
        nodes.deinit(allocator);
    }

    for (nodes.items) |node| {
        if (!std.mem.eql(u8, node.name, "sync")) continue;
        const at_i = node.getIntProperty("at") orelse return null;
        if (at_i < 0) return null;
        return @intCast(at_i);
    }

    return null;
}

fn mapFsAccessError(err: anyerror) RepoCacheError {
    return switch (err) {
        error.OutOfMemory => RepoCacheError.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => RepoCacheError.PermissionDenied,
        else => RepoCacheError.FileSystem,
    };
}

fn writeLastSync(self: *RepoCache, timestamp: u64) RepoCacheError!void {
    const path_buf = try lastSyncPath(self);
    defer self.ctx.allocator.free(path_buf);

    const tmp_path = std.fmt.allocPrint(self.ctx.allocator, "{s}.tmp", .{path_buf}) catch {
        return RepoCacheError.OutOfMemory;
    };
    defer self.ctx.allocator.free(tmp_path);

    const io = path.currentIo();
    const file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch |err| return mapFsAccessError(err);
    defer file.close(io);

    const line = std.fmt.allocPrint(self.ctx.allocator, "sync at={d}\n", .{timestamp}) catch {
        return RepoCacheError.OutOfMemory;
    };
    defer self.ctx.allocator.free(line);
    file.writeStreamingAll(io, line) catch |err| return mapFsAccessError(err);

    std.Io.Dir.renameAbsolute(tmp_path, path_buf, io) catch |err| return mapFsAccessError(err);
}

fn buildRepoPaths(self: *RepoCache, allocator: std.mem.Allocator) RepoCacheError!struct {
    db_path: []const u8,
    sig_path: []const u8,
} {
    const db_path = std.fs.path.join(allocator, &.{ self.cache_dir, repo_history.REPO_DB_FILENAME }) catch {
        return RepoCacheError.OutOfMemory;
    };
    const sig_path = std.fs.path.join(allocator, &.{ self.cache_dir, repo_history.REPO_SIG_FILENAME }) catch {
        allocator.free(db_path);
        return RepoCacheError.OutOfMemory;
    };

    return .{ .db_path = db_path, .sig_path = sig_path };
}

fn cacheUsable(self: *RepoCache) RepoCacheError!bool {
    const last_sync = try readLastSync(self, self.ctx.allocator);
    if (last_sync == null) return false;

    return try cacheFilesExist(self);
}

fn cacheFilesExist(self: *RepoCache) RepoCacheError!bool {
    const paths = try buildRepoPaths(self, self.ctx.allocator);
    defer {
        self.ctx.allocator.free(paths.db_path);
        self.ctx.allocator.free(paths.sig_path);
    }

    const db_exists = pathExists(paths.db_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.AccessDenied => return RepoCacheError.PermissionDenied,
        else => return RepoCacheError.FileSystem,
    };
    if (!db_exists) return false;

    const sig_exists = pathExists(paths.sig_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.AccessDenied => return RepoCacheError.PermissionDenied,
        else => return RepoCacheError.FileSystem,
    };
    if (!sig_exists) return false;

    return true;
}

fn cacheAgeSeconds(self: *RepoCache, now: u64) RepoCacheError!?u64 {
    const last_sync = try readLastSync(self, self.ctx.allocator);
    if (last_sync == null or now < last_sync.?) return null;
    return now - last_sync.?;
}

fn acquireSyncLock(self: *RepoCache) RepoCacheError!std.posix.fd_t {
    const lock_path = std.fs.path.join(self.ctx.allocator, &.{ self.cache_dir, ".sync.lock" }) catch return RepoCacheError.OutOfMemory;
    defer self.ctx.allocator.free(lock_path);
    const lock_file = std.Io.Dir.createFileAbsolute(path.currentIo(), lock_path, .{ .truncate = false }) catch |err| return mapFsAccessError(err);
    const fd = lock_file.handle;
    if (std.posix.errno(std.c.flock(fd, std.c.LOCK.EX)) != .SUCCESS) {
        _ = std.c.close(fd);
        return RepoCacheError.FileSystem;
    }
    return fd;
}

fn releaseSyncLock(fd: std.posix.fd_t) void {
    _ = std.c.flock(fd, std.c.LOCK.UN);
    _ = std.c.close(fd);
}

fn shouldSkipSync(self: *RepoCache, now: u64, interval_seconds: u64) RepoCacheError!bool {
    const last_sync = try readLastSync(self, self.ctx.allocator);
    if (last_sync == null) return false;
    if (interval_seconds == 0) return false;

    if (!try cacheFilesExist(self)) return false;

    // Equal timestamps are common for immediate repeat operations. A future
    // timestamp, however, is not evidence that metadata remains fresh.
    if (now < last_sync.?) return false;
    if (now - last_sync.? <= interval_seconds) {
        return true;
    }
    return false;
}

fn dupeFingerprints(allocator: std.mem.Allocator, fps: []const []const u8) ![]const []const u8 {
    const duped = try allocator.alloc([]const u8, fps.len);
    var i: usize = 0;
    errdefer {
        for (duped[0..i]) |fp| allocator.free(fp);
        allocator.free(duped);
    }
    for (fps) |fp| {
        duped[i] = try allocator.dupe(u8, fp);
        i += 1;
    }
    return duped;
}

fn freeFingerprints(allocator: std.mem.Allocator, fps: []const []const u8) void {
    for (fps) |fp| allocator.free(fp);
    allocator.free(fps);
}

fn pathExists(path_buf: []const u8) anyerror!bool {
    const io = path.currentIo();
    const file = std.Io.Dir.openFileAbsolute(io, path_buf, .{}) catch |err| {
        return err;
    };
    file.close(io);
    return true;
}

fn syncDownloadAndVerify(
    self: *RepoCache,
    client: download.TransferClient,
    db_url: []const u8,
    sig_url: []const u8,
    db_tmp: []const u8,
    sig_tmp: []const u8,
    db_path: []const u8,
    sig_path: []const u8,
    timeout_seconds: u32,
    loaded_keys: []const sign.LoadedKey,
) RepoCacheError!void {
    download.downloadFile(
        client,
        self.ctx,
        @ptrCast(db_url),
        db_tmp,
        download.DownloadOptions{ .force = true, .timeout = timeout_seconds },
    ) catch |err| {
        return mapDownloadError(err);
    };
    download.downloadFile(
        client,
        self.ctx,
        @ptrCast(sig_url),
        sig_tmp,
        download.DownloadOptions{ .force = true, .timeout = timeout_seconds },
    ) catch |err| {
        return mapDownloadError(err);
    };

    // Verify the signature on the temp DB using trusted fingerprints
    self.ctx.debug("about to verify signature with db_tmp={s}, sig_tmp={s}, trusted_fingerprints count={d}", .{ db_tmp, sig_tmp, self.trusted_fingerprints.len });

    if (self.trusted_fingerprints.len == 0) {
        self.ctx.setDiagnosticContext(self.name, "no trusted fingerprints configured for repository");
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), db_tmp) catch {};
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), sig_tmp) catch {};
        return RepoCacheError.SignatureInvalid;
    }

    var result = sign.verifyWithTrustedFingerprints(self.ctx, db_tmp, sig_tmp, self.trusted_fingerprints, loaded_keys) catch {
        const diag = self.ctx.getDiagnosticContext();
        if (diag.details) |details| {
            self.ctx.setDiagnosticContext(self.name, details);
        } else {
            self.ctx.setDiagnosticContext(self.name, "failed to verify repository database signature");
        }
        // Clean up temp files if verification fails
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), db_tmp) catch {};
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), sig_tmp) catch {};
        return RepoCacheError.SignatureInvalid;
    };
    result.deinit(self.ctx.allocator);
    self.ctx.debug("signature verification PASSED for DB: {s} with sig: {s}", .{ db_tmp, sig_tmp });

    // Replace DB + signature as a coherent pair with rollback on partial failure.
    try replaceCachedDbAndSigWithRollback(self.ctx.allocator, db_tmp, sig_tmp, db_path, sig_path);
}

fn replaceCachedDbAndSigWithRollback(
    allocator: std.mem.Allocator,
    new_db_tmp: []const u8,
    new_sig_tmp: []const u8,
    live_db_path: []const u8,
    live_sig_path: []const u8,
) RepoCacheError!void {
    const db_backup = std.fmt.allocPrint(allocator, "{s}.bak", .{live_db_path}) catch return RepoCacheError.OutOfMemory;
    defer allocator.free(db_backup);
    const sig_backup = std.fmt.allocPrint(allocator, "{s}.bak", .{live_sig_path}) catch return RepoCacheError.OutOfMemory;
    defer allocator.free(sig_backup);

    std.Io.Dir.deleteFileAbsolute(path.currentIo(), db_backup) catch {};
    std.Io.Dir.deleteFileAbsolute(path.currentIo(), sig_backup) catch {};

    var moved_live_db = false;
    var moved_live_sig = false;

    std.Io.Dir.renameAbsolute(live_db_path, db_backup, path.currentIo()) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFsAccessError(err),
    };
    moved_live_db = pathExists(db_backup) catch false;

    std.Io.Dir.renameAbsolute(live_sig_path, sig_backup, path.currentIo()) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, path.currentIo()) catch {};
            return mapFsAccessError(err);
        },
    };
    moved_live_sig = pathExists(sig_backup) catch false;

    std.Io.Dir.renameAbsolute(new_db_tmp, live_db_path, path.currentIo()) catch |err| {
        if (moved_live_sig) std.Io.Dir.renameAbsolute(sig_backup, live_sig_path, path.currentIo()) catch {};
        if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, path.currentIo()) catch {};
        return mapFsAccessError(err);
    };

    std.Io.Dir.renameAbsolute(new_sig_tmp, live_sig_path, path.currentIo()) catch |err| {
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), live_db_path) catch {};
        if (moved_live_db) std.Io.Dir.renameAbsolute(db_backup, live_db_path, path.currentIo()) catch {};
        if (moved_live_sig) std.Io.Dir.renameAbsolute(sig_backup, live_sig_path, path.currentIo()) catch {};
        return mapFsAccessError(err);
    };

    std.Io.Dir.deleteFileAbsolute(path.currentIo(), db_backup) catch {};
    std.Io.Dir.deleteFileAbsolute(path.currentIo(), sig_backup) catch {};
}

fn isLocalRepo(self: *const RepoCache) bool {
    return self.is_local;
}

fn mapDownloadError(err: anyerror) RepoCacheError {
    return switch (err) {
        error.OutOfMemory => RepoCacheError.OutOfMemory,
        error.Network, error.ConnectionTimeout => RepoCacheError.Network,
        error.PermissionDenied => RepoCacheError.PermissionDenied,
        error.AccessDenied => RepoCacheError.PermissionDenied,
        else => RepoCacheError.FileSystem,
    };
}

test "remote repo urls resolve to repo.db and repo.db.sig under repo directory" {
    const db_url = try remoteRepoDbUrl(std.testing.allocator, "https://repo.example.com/core/new");
    defer std.testing.allocator.free(db_url);
    try std.testing.expectEqualStrings("https://repo.example.com/core/new/repo.db", db_url);

    const sig_url = try remoteRepoSigUrl(std.testing.allocator, "https://repo.example.com/core/new/");
    defer std.testing.allocator.free(sig_url);
    try std.testing.expectEqualStrings("https://repo.example.com/core/new/repo.db.sig", sig_url);
}

test "future last-sync timestamps do not suppress refresh" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    var cache = try RepoCache.init(ctx, "future", "https://repo.example.com/future", &.{}, 100);
    defer cache.deinit();
    try path.ensureDirExists(cache.cache_dir);

    const db_path = try std.fs.path.join(ctx.allocator, &.{ cache.cache_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(db_path);
    const sig_path = try std.fs.path.join(ctx.allocator, &.{ cache.cache_dir, repo_history.REPO_SIG_FILENAME });
    defer ctx.allocator.free(sig_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(path.currentIo(), db_path, .{});
        file.close(path.currentIo());
    }
    {
        const file = try std.Io.Dir.createFileAbsolute(path.currentIo(), sig_path, .{});
        file.close(path.currentIo());
    }
    try writeLastSync(&cache, 200);

    try std.testing.expect(!try shouldSkipSync(&cache, 100, 900));
    try std.testing.expect(try shouldSkipSync(&cache, 200, 900));
    try std.testing.expect(try shouldSkipSync(&cache, 250, 900));
}

test "RepoCache.sync downloads and verifies DB and signature" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Prepare dummy remote DB and signature files
    const repo_name = "testrepo";
    const db_bytes = "dummy-db-bytes";
    const remote_dir = test_env.path;
    const db_file = try std.fs.path.join(ctx.allocator, &.{ remote_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(db_file);

    const sig_file = try std.fs.path.join(ctx.allocator, &.{ remote_dir, repo_history.REPO_SIG_FILENAME });
    defer ctx.allocator.free(sig_file);

    // Write dummy DB file
    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), db_file, .{});
        try f.writeStreamingAll(path.currentIo(), db_bytes);
        f.close(path.currentIo());
    }

    // Generate keypair and sign the DB
    const secret_key_path = try std.fs.path.join(ctx.allocator, &.{ remote_dir, "repo.key" });
    defer ctx.allocator.free(secret_key_path);
    const keypair = try sign.generateKeyPair();
    try keypair.secret_key.saveToFile(secret_key_path);

    // Store the public key in user keys directory so verifyWithTrustedFingerprints can find it
    const user_keys_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, ".mere", "keys" });
    defer ctx.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);

    const pubkey_path = try std.fs.path.join(ctx.allocator, &.{ user_keys_dir, "testrepo.pub" });
    defer ctx.allocator.free(pubkey_path);
    try keypair.public_key.saveToFile(pubkey_path);

    // Compute fingerprint for the trusted fingerprints list
    const fingerprint = try keypair.public_key.fingerprint(ctx.allocator);
    defer ctx.allocator.free(fingerprint);

    // Set the signing key path in the context to ensure the correct key is used
    ctx.signing_key_path = secret_key_path;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_file, sig_file, null, null);

    // Use file:// URL for the remote
    const url = try std.fmt.allocPrintSentinel(ctx.allocator, "file://{s}", .{remote_dir}, 0);
    defer ctx.allocator.free(url);

    // Construct RepoCache with trusted fingerprint
    const trusted_fps = [_][]const u8{fingerprint};
    var repocache = try RepoCache.init(
        ctx,
        repo_name,
        url,
        &trusted_fps,
        100, // default priority
    );
    defer repocache.deinit();

    // For local repos, cache_dir should point directly at the source directory
    try std.testing.expect(repocache.is_local);
    try std.testing.expectEqualStrings(remote_dir, repocache.cacheDir());

    // Run sync (for local repos, this verifies the signature in-place)
    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }
    try repocache.sync(client, .{}, loaded_keys.items);

    // Check that the DB and signature exist in the cache directory (which is the source dir)
    const cache_dir = repocache.cacheDir();

    var cache_dir_handle = try path.makePathAndOpenDir(cache_dir);
    defer cache_dir_handle.close(path.currentIo());

    var db_exists = true;
    cache_dir_handle.access(path.currentIo(), repo_history.REPO_DB_FILENAME, .{}) catch {
        db_exists = false;
    };
    try std.testing.expect(db_exists);

    var sig_exists = true;
    cache_dir_handle.access(path.currentIo(), repo_history.REPO_SIG_FILENAME, .{}) catch {
        sig_exists = false;
    };
    try std.testing.expect(sig_exists);
}

// Regression: a file:// repo declared in config.kdl (as opposed to an
// auto-discovered dev repo, which verifies before ever constructing a
// RepoCache) previously skipped signature verification entirely - sync()
// on a local repo was a no-op. A repo.db signed with a key that isn't in
// the configured trusted_fingerprints must be rejected.
test "RepoCache.sync rejects a local repo signed with an untrusted key" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const remote_dir = test_env.path;
    const db_file = try std.fs.path.join(ctx.allocator, &.{ remote_dir, repo_history.REPO_DB_FILENAME });
    defer ctx.allocator.free(db_file);
    const sig_file = try std.fs.path.join(ctx.allocator, &.{ remote_dir, repo_history.REPO_SIG_FILENAME });
    defer ctx.allocator.free(sig_file);

    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), db_file, .{});
        try f.writeStreamingAll(path.currentIo(), "dummy-db-bytes");
        f.close(path.currentIo());
    }

    // Sign with a DIFFERENT key than the one the repo config trusts -
    // simulating an attacker (or a stale/misconfigured mirror) serving a
    // repo.db that isn't actually signed by a key this config trusts.
    const attacker_key_path = try std.fs.path.join(ctx.allocator, &.{ remote_dir, "attacker.key" });
    defer ctx.allocator.free(attacker_key_path);
    const attacker_keypair = try sign.generateKeyPair();
    try attacker_keypair.secret_key.saveToFile(attacker_key_path);
    ctx.signing_key_path = attacker_key_path;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_file, sig_file, null, null);

    // The trusted fingerprint belongs to a completely different key.
    const trusted_keypair = try sign.generateKeyPair();
    const trusted_fingerprint = try trusted_keypair.public_key.fingerprint(ctx.allocator);
    defer ctx.allocator.free(trusted_fingerprint);

    const url = try std.fmt.allocPrintSentinel(ctx.allocator, "file://{s}", .{remote_dir}, 0);
    defer ctx.allocator.free(url);

    const trusted_fps = [_][]const u8{trusted_fingerprint};
    var repocache = try RepoCache.init(ctx, "testrepo", url, &trusted_fps, 100);
    defer repocache.deinit();
    try std.testing.expect(repocache.is_local);

    var curl_client = try download.CurlTransferClient.init(ctx, "mere");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    try std.testing.expectError(RepoCacheError.SignatureInvalid, repocache.sync(client, .{}, loaded_keys.items));
}

// Regression: previously, a repo.db already sitting in cache_dir from an
// earlier sync was trusted forever afterward with no re-check -
// ensureRepository() just opened it. Tampering with the cached file after
// it was verified (a local attacker, or on-disk corruption) went
// undetected on every subsequent use as long as sync() itself didn't run
// again (TTL not expired, or the caller opted out of syncing).
// ensureRepository() must now re-verify every time it actually opens the
// database (i.e. whenever self.repository is not already held open).
test "ensureRepository rejects a cached db that was tampered with after being verified" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const keypair = try sign.generateKeyPair();
    const key_path = try std.fs.path.join(allocator, &.{ test_env.path, "repo.key" });
    defer allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);
    const trusted_fingerprint = try keypair.public_key.fingerprint(allocator);
    defer allocator.free(trusted_fingerprint);
    const trusted_fps = [_][]const u8{trusted_fingerprint};

    // The public key must be discoverable by loadAllKeys() so
    // verifyWithTrustedFingerprints can match it against the fingerprint.
    const user_keys_dir = try std.fs.path.join(allocator, &.{ test_env.path, ".mere", "keys" });
    defer allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const pubkey_path = try std.fs.path.join(allocator, &.{ user_keys_dir, "testrepo.pub" });
    defer allocator.free(pubkey_path);
    try keypair.public_key.saveToFile(pubkey_path);

    // Use RepoCache's own computed cache_dir rather than guessing the path -
    // it's derived from a hash of name+fingerprints.
    var probe = try RepoCache.init(ctx, "testrepo", "https://repo.example.com", &trusted_fps, 100);
    const cache_dir = try allocator.dupe(u8, probe.cacheDir());
    defer allocator.free(cache_dir);
    probe.deinit();

    try path.ensureDirExists(cache_dir);
    const db_file = try std.fs.path.join(allocator, &.{ cache_dir, repo_history.REPO_DB_FILENAME });
    defer allocator.free(db_file);
    const sig_file = try std.fs.path.join(allocator, &.{ cache_dir, repo_history.REPO_SIG_FILENAME });
    defer allocator.free(sig_file);

    // Simulate a repo.db already cached from an earlier successful sync.
    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), db_file, .{});
        try f.writeStreamingAll(path.currentIo(), "original-trusted-db-bytes");
        f.close(path.currentIo());
    }
    ctx.signing_key_path = key_path;
    _ = try sign.writeSignatureFileWithResolver(ctx, db_file, sig_file, null, null);

    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    // A fresh RepoCache (self.repository == null) pointing at the
    // already-cached, still-untampered db opens cleanly.
    {
        var repocache = try RepoCache.init(ctx, "testrepo", "https://repo.example.com", &trusted_fps, 100);
        defer repocache.deinit();
        try repocache.ensureRepository(loaded_keys.items);
    }

    // Now tamper with the cached db in place - no sync() involved, just
    // direct on-disk modification (a local attacker, or corruption).
    {
        const f = try std.Io.Dir.openFileAbsolute(path.currentIo(), db_file, .{ .mode = .write_only });
        try f.writePositionalAll(path.currentIo(), "tampered-bytes-appended", 26);
        f.close(path.currentIo());
    }

    // A second, fresh RepoCache instance (simulating the next mere
    // invocation) must reject the now-tampered cached db.
    {
        var repocache = try RepoCache.init(ctx, "testrepo", "https://repo.example.com", &trusted_fps, 100);
        defer repocache.deinit();
        try std.testing.expectError(RepoCacheError.SignatureInvalid, repocache.ensureRepository(loaded_keys.items));
    }
}

test "writeLastSync reports permission denied for read-only cache dir" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const cache_dir = try std.fs.path.join(allocator, &.{ test_env.path, "readonly-cache" });
    defer allocator.free(cache_dir);
    try path.ensureDirExists(cache_dir);

    var cache_dir_handle = try path.openExistingDir(cache_dir);
    defer cache_dir_handle.close(path.currentIo());
    try cache_dir_handle.setPermissions(path.currentIo(), .fromMode(0o555));
    defer cache_dir_handle.setPermissions(path.currentIo(), .fromMode(0o755)) catch {};

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}", .{cache_dir});
    defer allocator.free(repo_url);
    const no_fps = [_][]const u8{};
    var cache = try RepoCache.init(ctx, "readonly-repo", repo_url, &no_fps, 100);
    defer cache.deinit();

    try std.testing.expectError(RepoCacheError.PermissionDenied, writeLastSync(&cache, 12345));
}

test "replaceCachedDbAndSigWithRollback restores live pair when sig swap fails" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const allocator = test_env.ctx.allocator;

    const cache_dir = try std.fs.path.join(allocator, &.{ test_env.path, "swap-rollback" });
    defer allocator.free(cache_dir);
    try path.ensureDirExists(cache_dir);

    const live_db = try std.fs.path.join(allocator, &.{ cache_dir, repo_history.REPO_DB_FILENAME });
    defer allocator.free(live_db);
    const live_sig = try std.fs.path.join(allocator, &.{ cache_dir, repo_history.REPO_SIG_FILENAME });
    defer allocator.free(live_sig);
    const new_db_tmp = try std.fs.path.join(allocator, &.{ cache_dir, ".repo.db.tmp" });
    defer allocator.free(new_db_tmp);
    const missing_sig_tmp = try std.fs.path.join(allocator, &.{ cache_dir, ".repo.db.sig.tmp" });
    defer allocator.free(missing_sig_tmp);

    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), live_db, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "old-db");
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), live_sig, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "old-sig");
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), new_db_tmp, .{});
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "new-db");
    }
    // Intentionally do not create missing_sig_tmp so second rename fails.

    try std.testing.expectError(
        RepoCacheError.FileSystem,
        replaceCachedDbAndSigWithRollback(allocator, new_db_tmp, missing_sig_tmp, live_db, live_sig),
    );

    {
        const f = try std.Io.Dir.openFileAbsolute(path.currentIo(), live_db, .{});
        defer f.close(path.currentIo());
        var buf: [64]u8 = undefined;
        const n = try f.readPositionalAll(path.currentIo(), &buf, 0);
        try std.testing.expectEqualStrings("old-db", buf[0..n]);
    }
    {
        const f = try std.Io.Dir.openFileAbsolute(path.currentIo(), live_sig, .{});
        defer f.close(path.currentIo());
        var buf: [64]u8 = undefined;
        const n = try f.readPositionalAll(path.currentIo(), &buf, 0);
        try std.testing.expectEqualStrings("old-sig", buf[0..n]);
    }
}

test "ensurePackageArchiveCached uses dummy HTTP client" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // ensurePackageArchiveCached now verifies the download against
    // pkg.archive_hash, so the dummy body's hash must be real - a
    // placeholder like "b" * 64 would (correctly) get rejected as a
    // hash mismatch.
    const archive_body = "archive-bytes";
    const archive_hash = try hash.calculateBytesHash(ctx.allocator, archive_body);
    defer ctx.allocator.free(archive_hash);

    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    const archive_url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://repo.example.com/packages/mypkg-1.2.3-1-x86_64-{s}.pkg.tar.zst",
        .{archive_hash},
    );
    defer ctx.allocator.free(archive_url);
    try dummy.set(archive_url, archive_body);
    var vtable = download.TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var cache = try RepoCache.init(
        ctx,
        "testrepo",
        "https://repo.example.com",
        &.{},
        100,
    );
    defer cache.deinit();
    var pkg = Package{
        .ctx = ctx,
        .name = "mypkg",
        .version = "1.2.3",
        .release = 1,
        .arch = "x86_64",
        .signature = null,
        .dependencies = undefined,
        .provisions = undefined,
        .content_hash = archive_hash,
        .archive_hash = archive_hash,
    };

    const archive_path = try cache.ensurePackageArchiveCached(&pkg, client);
    defer ctx.allocator.free(archive_path);

    const file = try std.Io.Dir.openFileAbsolute(path.currentIo(), archive_path, .{});
    defer file.close(path.currentIo());
    var buf: [32]u8 = undefined;
    const n = try file.readPositionalAll(path.currentIo(), &buf, 0);
    try std.testing.expectEqualStrings("archive-bytes", buf[0..n]);
}

// Regression: ensurePackageArchiveCached previously downloaded archives
// with DownloadOptions{} (no expected_hash), so a tampered or corrupted
// archive would be silently cached and later extracted despite the repo
// db already knowing the correct archive_hash. It must now be rejected
// before ever landing in the cache.
test "ensurePackageArchiveCached rejects a downloaded archive that doesn't match the known hash" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const correct_hash = try hash.calculateBytesHash(ctx.allocator, "expected-bytes");
    defer ctx.allocator.free(correct_hash);

    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    const archive_url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://repo.example.com/packages/mypkg-1.2.3-1-x86_64-{s}.pkg.tar.zst",
        .{correct_hash},
    );
    defer ctx.allocator.free(archive_url);
    // The server serves different bytes than what the (correct) hash promises -
    // a tampered mirror or a corrupted transfer, either way it must be rejected.
    try dummy.set(archive_url, "tampered-bytes-served-instead");
    var vtable = download.TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var cache = try RepoCache.init(ctx, "testrepo", "https://repo.example.com", &.{}, 100);
    defer cache.deinit();
    var pkg = Package{
        .ctx = ctx,
        .name = "mypkg",
        .version = "1.2.3",
        .release = 1,
        .arch = "x86_64",
        .signature = null,
        .dependencies = undefined,
        .provisions = undefined,
        .content_hash = correct_hash,
        .archive_hash = correct_hash,
    };

    try std.testing.expectError(error.SignatureVerificationFailed, cache.ensurePackageArchiveCached(&pkg, client));

    // The bad archive must not have been left behind under its final name.
    const cache_path = try cache.archiveCachePath(&pkg);
    defer ctx.allocator.free(cache_path);
    std.Io.Dir.accessAbsolute(path.currentIo(), cache_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestUnexpectedResult;
}
