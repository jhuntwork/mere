//! Remote repository cache snapshots. Writers/collectors hold the cache sync
//! lock; readers pin one selected snapshot with a shared flock on its lease.
//! Only verification needs the pin: SQLite receives a copy of verified bytes.
const std = @import("std");
const mere = @import("mere.zig");
const path = @import("path.zig");
const publish = @import("publish.zig");
const history = @import("repo_history.zig");
const errors = @import("errors.zig");
const linux = std.os.linux;

const Std = errors.StandardErrors;
pub const Error = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.CorruptData || error{PublishedNotDurable};
const prefix = "snapshot-";
const lease_name = ".lease";

fn fail(ctx: *mere.Context, subject: []const u8, operation: []const u8, err: anyerror) Error {
    return ctx.failFmt(switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => Error.PermissionDenied,
        error.PublishedNotDurable => Error.PublishedNotDurable,
        else => Error.FileSystem,
    }, subject, "{s}: {s}", .{ operation, @errorName(err) });
}

fn validName(name: []const u8) bool {
    if (name.len != prefix.len + 32 or !std.mem.startsWith(u8, name, prefix)) return false;
    for (name[prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn validStageName(name: []const u8) bool {
    const suffix = ".staging";
    return name.len == 1 + prefix.len + 32 + suffix.len and name[0] == '.' and
        std.mem.endsWith(u8, name, suffix) and validName(name[1 .. name.len - suffix.len]);
}

/// Cache entries are untrusted (the container may be shared and sticky).
/// O_NONBLOCK prevents FIFO opens from hanging; O_NOFOLLOW rejects symlinks.
fn openLease(ctx: *mere.Context, dir: std.Io.Dir, label: []const u8) Error!?std.Io.File {
    const result = linux.openat(dir.handle, lease_name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .NOENT, .LOOP, .ACCES, .PERM, .NOTDIR, .NXIO, .NODEV => return null,
        else => |err| return ctx.failFmt(Error.FileSystem, label, "open snapshot lease: {s}", .{@tagName(err)}),
    }
    const file = std.Io.File{ .handle = @intCast(result), .flags = .{ .nonblocking = true } };
    const stat = file.stat(path.currentIo()) catch |err| {
        file.close(path.currentIo());
        return fail(ctx, label, "inspect snapshot lease", err);
    };
    if (stat.kind != .file) {
        file.close(path.currentIo());
        return null;
    }
    return file;
}

fn ownedByCollector(ctx: *mere.Context, dir: std.Io.Dir, label: []const u8) Error!bool {
    var stat: linux.Statx = undefined;
    switch (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true }, &stat))) {
        .SUCCESS => return stat.uid == linux.geteuid(),
        else => |err| return ctx.failFmt(Error.FileSystem, label, "inspect snapshot directory owner: {s}", .{@tagName(err)}),
    }
}

pub const Selection = struct {
    ctx: *mere.Context,
    directory: []const u8,
    db_path: []const u8,
    sig_path: []const u8,
    lease: ?std.Io.File = null,

    pub fn deinit(self: *Selection) void {
        // Closing releases the reader flock, including on verification errors.
        if (self.lease) |file| file.close(path.currentIo());
        self.ctx.allocator.free(self.sig_path);
        self.ctx.allocator.free(self.db_path);
        self.ctx.allocator.free(self.directory);
    }
};

pub fn flatSelection(ctx: *mere.Context, directory: []const u8) Error!Selection {
    const owned = ctx.allocator.dupe(u8, directory) catch |err| return fail(ctx, directory, "allocate selected directory", err);
    errdefer ctx.allocator.free(owned);
    const db = std.fs.path.join(ctx.allocator, &.{ owned, history.REPO_DB_FILENAME }) catch |err| return fail(ctx, directory, "allocate database path", err);
    errdefer ctx.allocator.free(db);
    const sig = std.fs.path.join(ctx.allocator, &.{ owned, history.REPO_SIG_FILENAME }) catch |err| return fail(ctx, directory, "allocate signature path", err);
    return .{ .ctx = ctx, .directory = owned, .db_path = db, .sig_path = sig };
}

/// Read current exactly once per attempt. Legacy fallback is permitted only
/// when the pointer itself is absent, never for a malformed/dangling pointer.
pub fn select(ctx: *mere.Context, cache_dir: []const u8) Error!Selection {
    const io = path.currentIo();
    var root = path.openExistingDir(cache_dir) catch |err| return fail(ctx, cache_dir, "open repository cache", err);
    defer root.close(io);
    // A collector may win between reading current and acquiring the lease.
    // Retry the selection, never mix paths from two different selections.
    for (0..4) |_| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = root.readLink(io, "current", &buffer) catch |err| switch (err) {
            error.FileNotFound => return flatSelection(ctx, cache_dir),
            else => return fail(ctx, cache_dir, "read snapshot selection", err),
        };
        const name = buffer[0..len];
        if (!validName(name)) return ctx.fail(Error.CorruptData, cache_dir, "invalid repository snapshot selection; run mere sync to refresh it");
        const directory = std.fs.path.join(ctx.allocator, &.{ cache_dir, name }) catch |err| return fail(ctx, cache_dir, "allocate snapshot path", err);
        defer ctx.allocator.free(directory);
        var dir = root.openDir(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return fail(ctx, directory, "open selected snapshot (run mere sync to refresh)", err),
        };
        defer dir.close(io);
        const lease = (try openLease(ctx, dir, directory)) orelse continue;
        var pinned = false;
        defer if (!pinned) lease.close(io);
        if (std.posix.errno(std.c.flock(lease.handle, std.c.LOCK.SH)) != .SUCCESS)
            return ctx.fail(Error.FileSystem, directory, "failed to acquire snapshot reader lease");
        // If GC removed this tree while the reader waited for its lease, its
        // old lease fd is still valid, but its directory entries are gone.
        dir.access(io, lease_name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return fail(ctx, directory, "check pinned snapshot", err),
        };
        var result = try flatSelection(ctx, directory);
        result.lease = lease;
        pinned = true;
        return result;
    }
    return ctx.fail(Error.FileSystem, cache_dir, "selected repository snapshot disappeared or is incomplete; run mere sync to refresh it");
}

pub const Stage = struct {
    ctx: *mere.Context,
    cache_dir: []const u8,
    directory: []const u8,
    final_path: []const u8,
    name: []const u8,

    pub fn deinit(self: *Stage) void {
        // Only the unpublished stage is disposable. Published snapshots are
        // retained even when a later pointer publication fails.
        path.deleteTreeAbsolute(self.directory) catch |err| {
            if (err != error.FileNotFound) self.ctx.debug("failed to remove repository stage {s}: {s}", .{ self.directory, @errorName(err) });
        };
        self.ctx.allocator.free(self.directory);
        self.ctx.allocator.free(self.final_path);
        self.ctx.allocator.free(self.name);
    }

    /// The caller has verified both staged files before calling this method.
    pub fn commit(self: *Stage) Error!void {
        const io = path.currentIo();
        var dir = std.Io.Dir.openDirAbsolute(io, self.directory, .{ .iterate = true }) catch |err| return fail(self.ctx, self.directory, "open verified snapshot stage", err);
        defer dir.close(io);
        dir.setPermissions(io, .fromMode(0o755)) catch |err| return fail(self.ctx, self.directory, "make verified snapshot readable", err);
        const outcome = publish.publishDirectory(self.ctx.allocator, self.directory, self.final_path, .{
            .checkpoints = .{ .before = .repository_snapshot_before_publish, .after = .repository_snapshot_after_publish },
        }) catch |err| {
            // The directory may be visible, but current has not changed. Only
            // a failure after selecting it is a committed refresh failure.
            if (err == error.PublishedNotDurable) return self.ctx.failFmt(Error.FileSystem, self.final_path, "snapshot directory visible but not selected; durability failed: {s}", .{@errorName(err)});
            return fail(self.ctx, self.final_path, "publish verified snapshot directory (not selected)", err);
        };
        if (outcome == .exists) return self.ctx.fail(Error.CorruptData, self.final_path, "repository snapshot name already exists");
        // Persist newly created cache ancestors too, before committing a
        // pointer inside them. A parent-only sync misses first-use durability.
        try syncAncestors(self.ctx, self.cache_dir);
        var root = path.openExistingDir(self.cache_dir) catch |err| return fail(self.ctx, self.cache_dir, "open snapshot parent", err);
        defer root.close(io);
        publish.replaceSymlink(root, self.name, "current", .{
            .checkpoints = .{ .before = .repository_snapshot_before_select, .after = .repository_snapshot_after_select },
        }) catch |err| return fail(self.ctx, self.cache_dir, "select verified repository snapshot", err);
    }
};

pub fn begin(ctx: *mere.Context, cache_dir: []const u8) Error!Stage {
    const io = path.currentIo();
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const name = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, hex }) catch |err| return fail(ctx, cache_dir, "allocate snapshot name", err);
    errdefer ctx.allocator.free(name);
    const directory = std.fmt.allocPrint(ctx.allocator, "{s}/.{s}.staging", .{ cache_dir, name }) catch |err| return fail(ctx, cache_dir, "allocate staging path", err);
    errdefer ctx.allocator.free(directory);
    const final_path = std.fs.path.join(ctx.allocator, &.{ cache_dir, name }) catch |err| return fail(ctx, cache_dir, "allocate snapshot path", err);
    errdefer ctx.allocator.free(final_path);
    var root = path.openExistingDir(cache_dir) catch |err| return fail(ctx, cache_dir, "open snapshot parent", err);
    defer root.close(io);
    root.createDir(io, std.fs.path.basename(directory), .fromMode(0o700)) catch |err| return fail(ctx, directory, "create private repository stage", err);
    errdefer path.deleteTreeAbsolute(directory) catch {}; // Best-effort cleanup after a setup failure.
    var dir = path.openExistingDir(directory) catch |err| return fail(ctx, directory, "open repository stage", err);
    defer dir.close(io);
    const lease = dir.createFile(io, lease_name, .{ .exclusive = true, .permissions = .fromMode(0o644) }) catch |err| return fail(ctx, directory, "create snapshot reader lease", err);
    lease.close(io);
    return .{ .ctx = ctx, .cache_dir = cache_dir, .directory = directory, .final_path = final_path, .name = name };
}

fn syncAncestors(ctx: *mere.Context, directory: []const u8) Error!void {
    var parent = std.fs.path.dirname(directory);
    while (parent) |name| {
        var dir = path.openExistingDir(name) catch |err| return fail(ctx, name, "open cache ancestor", err);
        defer dir.close(path.currentIo());
        publish.syncDir(dir) catch |err| return fail(ctx, name, "persist cache ancestor", err);
        if (std.mem.eql(u8, name, "/")) break;
        parent = std.fs.path.dirname(name);
    }
}

/// Caller holds the exclusive cache sync lock. Retain current and any reader-
/// pinned snapshots. Abandoned stages are safe to remove under that lock,
/// including before the first publication. Never remove legacy flat files,
/// unrecognized entries, or directories owned by a different uid.
pub fn collect(ctx: *mere.Context, cache_dir: []const u8) Error!usize {
    const io = path.currentIo();
    var selected = try select(ctx, cache_dir);
    defer selected.deinit();
    var root = std.Io.Dir.openDirAbsolute(io, cache_dir, .{ .iterate = true }) catch |err| return fail(ctx, cache_dir, "open snapshot collection directory", err);
    defer root.close(io);
    // A prior switch may have reported PublishedNotDurable. Persist its
    // actual selection before allowing collection of the previous snapshot.
    try syncAncestors(ctx, cache_dir);
    publish.syncDir(root) catch |err| return fail(ctx, cache_dir, "persist selection before snapshot collection", err);
    var count: usize = 0;
    var iterator = root.iterate();
    while (iterator.next(io) catch |err| return fail(ctx, cache_dir, "list repository snapshots", err)) |entry| {
        const abandoned_stage = validStageName(entry.name);
        if (entry.kind != .directory or (!abandoned_stage and !validName(entry.name))) continue;
        if (selected.lease != null and std.mem.eql(u8, entry.name, std.fs.path.basename(selected.directory))) continue;
        var dir = root.openDir(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            // A foreign/malformed cache entry must not stop collection.
            ctx.debug("skipping inaccessible snapshot entry {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        if (!try ownedByCollector(ctx, dir, entry.name)) continue;
        if (abandoned_stage) {
            // No active publisher can own this stage: the caller holds the
            // same exclusive sync lock used for the entire staging lifetime.
            root.deleteTree(io, entry.name) catch |err| return fail(ctx, entry.name, "remove abandoned repository stage", err);
            count += 1;
            continue;
        }
        const lease = (try openLease(ctx, dir, entry.name)) orelse {
            ctx.debug("skipping snapshot with missing or invalid lease: {s}", .{entry.name});
            continue;
        };
        defer lease.close(io);
        switch (std.posix.errno(std.c.flock(lease.handle, std.c.LOCK.EX | std.c.LOCK.NB))) {
            .SUCCESS => {},
            .AGAIN => continue, // A verifier is still using this pair.
            else => |err| return ctx.failFmt(Error.FileSystem, entry.name, "lock old snapshot for collection: {s}", .{@tagName(err)}),
        }
        root.deleteTree(io, entry.name) catch |err| return fail(ctx, entry.name, "remove old snapshot", err);
        count += 1;
    }
    publish.syncDir(root) catch |err| return fail(ctx, cache_dir, "persist snapshot collection", err);
    return count;
}

fn writePairForTest(ctx: *mere.Context, directory: []const u8, db: []const u8, sig: []const u8) !void {
    var dir = path.openExistingDir(directory) catch |err| return fail(ctx, directory, "open test pair directory", err);
    defer dir.close(path.currentIo());
    _ = try publish.replaceFile(dir, history.REPO_DB_FILENAME, db, .{});
    _ = try publish.replaceFile(dir, history.REPO_SIG_FILENAME, sig, .{});
}

fn expectPairForTest(selection: *Selection, db: []const u8, sig: []const u8) !void {
    var dir = try path.openExistingDir(selection.directory);
    defer dir.close(path.currentIo());
    const db_bytes = try dir.readFileAlloc(path.currentIo(), history.REPO_DB_FILENAME, selection.ctx.allocator, .limited(4096));
    defer selection.ctx.allocator.free(db_bytes);
    const sig_bytes = try dir.readFileAlloc(path.currentIo(), history.REPO_SIG_FILENAME, selection.ctx.allocator, .limited(4096));
    defer selection.ctx.allocator.free(sig_bytes);
    try std.testing.expectEqualStrings(db, db_bytes);
    try std.testing.expectEqualStrings(sig, sig_bytes);
}

test "repository snapshots pin one pair across refresh and collection" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const ctx = &env.ctx;
    var old = try begin(ctx, env.path);
    defer old.deinit();
    try writePairForTest(ctx, old.directory, "old-db", "old-sig");
    try old.commit();
    var reader = try select(ctx, env.path);
    var pinned = true;
    defer if (pinned) reader.deinit();
    var next = try begin(ctx, env.path);
    defer next.deinit();
    try writePairForTest(ctx, next.directory, "new-db", "new-sig");
    try next.commit();
    // Separate open descriptions even in one process contend on flock.
    try std.testing.expectEqual(@as(usize, 0), try collect(ctx, env.path));
    try expectPairForTest(&reader, "old-db", "old-sig");
    var current = try select(ctx, env.path);
    defer current.deinit();
    try expectPairForTest(&current, "new-db", "new-sig");
    reader.deinit();
    pinned = false;
    publish.failNextDirectorySyncForTest();
    try std.testing.expectError(Error.FileSystem, collect(ctx, env.path));
    try std.Io.Dir.accessAbsolute(path.currentIo(), old.final_path, .{});
    try std.testing.expectEqual(@as(usize, 1), try collect(ctx, env.path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path.currentIo(), old.final_path, .{}));
    try expectPairForTest(&current, "new-db", "new-sig");
}

test "repository snapshot migration never falls back from an invalid selection" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const ctx = &env.ctx;
    try writePairForTest(ctx, env.path, "legacy-db", "legacy-sig");
    var legacy = try select(ctx, env.path);
    defer legacy.deinit();
    try std.testing.expect(legacy.lease == null);
    var dir = try path.openExistingDir(env.path);
    defer dir.close(path.currentIo());
    try publish.replaceSymlink(dir, "../escape", "current", .{});
    try std.testing.expectError(Error.CorruptData, select(ctx, env.path));
    try publish.replaceSymlink(dir, "snapshot-" ++ "a" ** 32, "current", .{});
    try std.testing.expectError(Error.FileSystem, select(ctx, env.path));
    try expectPairForTest(&legacy, "legacy-db", "legacy-sig");
}

test "repository snapshot collection reclaims abandoned stages before first publication" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    var abandoned = try begin(&env.ctx, env.path);
    defer abandoned.deinit();
    var dir = try path.openExistingDir(abandoned.directory);
    defer dir.close(path.currentIo());
    _ = try publish.replaceFile(dir, history.REPO_DB_FILENAME, "partial-download", .{});
    try std.testing.expectEqual(@as(usize, 1), try collect(&env.ctx, env.path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path.currentIo(), abandoned.directory, .{}));
}

test "repository snapshot leases reject FIFOs and symlinks and collection skips malformed entries" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const ctx = &env.ctx;
    const io = path.currentIo();
    var old = try begin(ctx, env.path);
    defer old.deinit();
    try writePairForTest(ctx, old.directory, "old", "old");
    try old.commit();
    var current = try begin(ctx, env.path);
    defer current.deinit();
    try writePairForTest(ctx, current.directory, "current", "current");
    try current.commit();
    var root = try path.openExistingDir(env.path);
    defer root.close(io);
    const fifo_name = "snapshot-" ++ "a" ** 32;
    const link_name = "snapshot-" ++ "b" ** 32;
    const missing_name = "snapshot-" ++ "c" ** 32;
    for ([_][]const u8{ fifo_name, link_name, missing_name }) |name| try root.createDir(io, name, .default_dir);
    var fifo_dir = try root.openDir(io, fifo_name, .{});
    defer fifo_dir.close(io);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(fifo_dir.handle, lease_name, std.posix.S.IFIFO | 0o644, 0)));
    var link_dir = try root.openDir(io, link_name, .{});
    defer link_dir.close(io);
    try link_dir.symLink(io, "../" ++ fifo_name ++ "/.lease", lease_name, .{});
    // This must neither block opening the FIFO nor abort at the missing lease.
    try std.testing.expectEqual(@as(usize, 1), try collect(ctx, env.path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, old.final_path, .{}));
    for ([_][]const u8{ fifo_name, link_name, missing_name }) |name| try root.access(io, name, .{});
    for ([_][]const u8{ fifo_name, link_name, missing_name }) |name| {
        try publish.replaceSymlink(root, name, "current", .{});
        try std.testing.expectError(Error.FileSystem, select(ctx, env.path));
    }
    try publish.replaceSymlink(root, current.name, "current", .{});
    var selected = try select(ctx, env.path);
    defer selected.deinit();
    try expectPairForTest(&selected, "current", "current");
}

test "repository snapshot faults retain the previous selection until pointer commit" {
    const th = @import("test_helpers.zig");
    const faults = @import("fault_injection.zig");
    defer faults.clearForTest();
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const ctx = &env.ctx;
    const cases = [_]faults.Checkpoint{ .repository_snapshot_before_publish, .repository_snapshot_after_publish, .repository_snapshot_before_select, .repository_snapshot_after_select };
    for (cases) |checkpoint| {
        var old = try begin(ctx, env.path);
        defer old.deinit();
        try writePairForTest(ctx, old.directory, "old-db", "old-sig");
        try old.commit();
        var next = try begin(ctx, env.path);
        defer next.deinit();
        try writePairForTest(ctx, next.directory, "new-db", "new-sig");
        faults.setForTest(checkpoint, .fail);
        const committed = checkpoint == .repository_snapshot_after_select;
        if (committed) {
            try std.testing.expectError(Error.PublishedNotDurable, next.commit());
        } else {
            try std.testing.expectError(Error.FileSystem, next.commit());
        }
        var current = try select(ctx, env.path);
        defer current.deinit();
        try expectPairForTest(&current, if (committed) "new-db" else "old-db", if (committed) "new-sig" else "old-sig");
        // Even a committed failure keeps the previous directory available.
        try std.Io.Dir.accessAbsolute(path.currentIo(), old.final_path, .{});
    }
    var old = try select(ctx, env.path);
    defer old.deinit();
    var next = try begin(ctx, env.path);
    defer next.deinit();
    try writePairForTest(ctx, next.directory, "sync-fail", "sync-fail");
    publish.failNextDirectorySyncForTest();
    try std.testing.expectError(Error.FileSystem, next.commit());
    var still_old = try select(ctx, env.path);
    defer still_old.deinit();
    try std.testing.expectEqualStrings(old.directory, still_old.directory);
}

/// The shared test-env entry point dispatches before unrelated test bodies,
/// preventing nested crash-boundary suites from spawning recursive children.
pub fn runCrashChildForTest() !void {
    if (!@import("builtin").is_test) return;
    const root = std.c.getenv("MERE_SNAPSHOT_CRASH_ROOT") orelse return;
    const faults = @import("fault_injection.zig");
    faults.configureFromEnvironment();
    // A disposable child process owns all allocations until termination.
    var ctx = mere.Context.init(std.heap.page_allocator, std.mem.span(root));
    defer ctx.deinit();
    var stage = try begin(&ctx, ctx.root_path);
    defer stage.deinit();
    try writePairForTest(&ctx, stage.directory, "new-db", "new-sig");
    try stage.commit();
}

test "repository snapshot crash child" {
    try runCrashChildForTest();
}

test "repository snapshot subprocess restart preserves a coherent selected pair" {
    const th = @import("test_helpers.zig");
    var env = try th.createTestEnv();
    defer {
        env.cleanup();
        std.testing.allocator.destroy(env);
    }
    const ctx = &env.ctx;
    const executable = try std.process.executablePathAlloc(path.currentIo(), ctx.allocator);
    defer ctx.allocator.free(executable);
    for ([_][]const u8{ "repository_snapshot_before_publish", "repository_snapshot_after_publish", "repository_snapshot_before_select", "repository_snapshot_after_select" }) |checkpoint| {
        var old = try begin(ctx, env.path);
        defer old.deinit();
        try writePairForTest(ctx, old.directory, "old-db", "old-sig");
        try old.commit();
        var vars = std.process.Environ.Map.init(ctx.allocator);
        defer vars.deinit();
        try vars.put("MERE_SNAPSHOT_CRASH_ROOT", env.path);
        try vars.put("MERE_FAULT_CHECKPOINT", checkpoint);
        try vars.put("MERE_FAULT_ACTION", "terminate");
        const result = try std.process.run(ctx.allocator, path.currentIo(), .{
            .argv = &.{executable},
            .environ_map = &vars,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer ctx.allocator.free(result.stdout);
        defer ctx.allocator.free(result.stderr);
        try std.testing.expect(result.term == .exited);
        try std.testing.expectEqual(@as(u8, 86), result.term.exited);
        var current = try select(ctx, env.path);
        defer current.deinit();
        const committed = std.mem.eql(u8, checkpoint, "repository_snapshot_after_select");
        try expectPairForTest(&current, if (committed) "new-db" else "old-db", if (committed) "new-sig" else "old-sig");
        try std.Io.Dir.accessAbsolute(path.currentIo(), old.final_path, .{});
        // Collection holds the writer lock in production, so a subsequent
        // pass can reclaim a stage abandoned by a terminated publisher.
        _ = try collect(ctx, env.path);
        var dir = try std.Io.Dir.openDirAbsolute(path.currentIo(), env.path, .{ .iterate = true });
        defer dir.close(path.currentIo());
        var entries = dir.iterate();
        while (try entries.next(path.currentIo())) |entry| try std.testing.expect(!validStageName(entry.name));
    }
}
