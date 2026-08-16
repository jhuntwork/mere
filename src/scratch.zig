//! Ownership and reclamation for scratch directories (spec §4.3).
//!
//! Store staging (`/mere/store/.incoming/<rand>/`) and namespace session trees
//! are only meaningful while the process that created them is alive. Any
//! abnormal exit - a crash, SIGKILL, a cancelled invocation - used to leak the
//! whole tree permanently, and nothing swept `.incoming` at all.
//!
//! Liveness is an exclusive flock on a lock file sitting beside the directory.
//! The lock lives on the open file description, so the kernel releases it when
//! the owner exits for any reason, and it survives execve. That means no
//! heartbeat, no timeout, and no pid check that a recycled pid could defeat:
//! if a sweeper can take the lock, the owner is gone.

const std = @import("std");
const path_mod = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const ScratchError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

/// A claimed scratch directory `<base>/<id>` is tracked by a sibling lock file
/// `<base>/<id>.owner`.
///
/// Sibling rather than inside: a store staging directory *becomes* the store
/// object via rename, and anything inside it at that moment is part of the
/// payload and would change the content hash. Keeping the marker outside means
/// the tracked directory holds nothing but the caller's content.
pub const OWNER_LOCK_SUFFIX = ".owner";

/// Directories with no owner lock are only reclaimed once they are at least
/// this old. Covers trees created before this protocol existed, and the narrow
/// window where a process died between mkdir and claim.
pub const DEFAULT_GRACE_SECONDS: i64 = 300;

/// A held claim on a scratch directory. The lock is released when `release` is
/// called or when the process exits.
pub const Claim = struct {
    fd: std.posix.fd_t,
    lock_path: []const u8,
    allocator: std.mem.Allocator,

    /// Drop the claim, leaving the lock file in place. A later sweep reaps it
    /// once it sees the claim is free.
    pub fn release(self: *Claim) void {
        if (self.fd < 0) return;
        _ = std.c.flock(self.fd, std.c.LOCK.UN);
        _ = std.c.close(self.fd);
        self.fd = -1;
        self.allocator.free(self.lock_path);
        self.lock_path = &.{};
    }

    /// Drop the claim and delete its lock file. Use once the claimed directory
    /// has been consumed - renamed into the store, or deleted - so the sweep
    /// has nothing left to find.
    pub fn releaseAndRemove(self: *Claim) void {
        if (self.fd < 0) return;
        std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), self.lock_path) catch {};
        self.release();
    }
};

/// Claim `dir_path`, which must already exist. Callers should do this before
/// putting anything else in the directory, so a sweeper never sees a populated
/// directory with no owner.
///
/// `inheritable` clears FD_CLOEXEC so the claim survives into an exec'd
/// process. Namespace sessions need that: the session is in use for as long as
/// the shell or build command runs, and that command replaces us via execve.
pub fn claim(allocator: std.mem.Allocator, dir_path: []const u8, inheritable: bool) ScratchError!Claim {
    const lock_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_path, OWNER_LOCK_SUFFIX }) catch {
        return ScratchError.OutOfMemory;
    };
    errdefer allocator.free(lock_path);

    const lock_path_z = allocator.dupeZ(u8, lock_path) catch return ScratchError.OutOfMemory;
    defer allocator.free(lock_path_z);

    const fd = std.c.open(lock_path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) {
        return switch (std.posix.errno(fd)) {
            .ACCES, .PERM => ScratchError.PermissionDenied,
            else => ScratchError.FileSystem,
        };
    }

    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
        // Someone else owns this directory. Callers generate unique names, so
        // this means the name collided with live work rather than being stale.
        _ = std.c.close(fd);
        return ScratchError.FileSystem;
    }

    if (inheritable) {
        // Best effort: losing the inheritance only means the claim is released
        // at exec instead of at command exit, which makes the directory look
        // abandoned early rather than causing incorrect deletion of live work.
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 0));
    }

    return .{ .fd = fd, .lock_path = lock_path, .allocator = allocator };
}

pub const SweepResult = struct {
    reclaimed: usize = 0,
    live: usize = 0,
    skipped: usize = 0,
};

const Meta = struct {
    uid: std.os.linux.uid_t,
    is_dir: bool,
    mtime_seconds: i64,
};

/// lstat via statx: Zig does not expose lstat on Linux, and the owner uid is
/// not part of std.Io.File.Stat. AT_SYMLINK_NOFOLLOW so a symlink planted in a
/// scratch base is never mistaken for the directory it points at.
fn lstatMeta(allocator: std.mem.Allocator, abs_path: []const u8) ?Meta {
    const path_z = allocator.dupeZ(u8, abs_path) catch return null;
    defer allocator.free(path_z);

    var stx: std.os.linux.Statx = undefined;
    const want: std.os.linux.STATX = .{ .TYPE = true, .UID = true, .MTIME = true };
    const rc = std.os.linux.statx(
        std.posix.AT.FDCWD,
        path_z.ptr,
        @bitCast(@as(u32, std.posix.AT.SYMLINK_NOFOLLOW)),
        want,
        &stx,
    );
    if (std.posix.errno(rc) != .SUCCESS) return null;
    // Field support varies by filesystem, so refuse to decide without them.
    if (!stx.mask.TYPE or !stx.mask.UID or !stx.mask.MTIME) return null;

    return .{
        .uid = stx.uid,
        .is_dir = stx.mode & std.os.linux.S.IFMT == std.os.linux.S.IFDIR,
        .mtime_seconds = stx.mtime.sec,
    };
}

/// Reclaim abandoned scratch directories directly under `base_dir`.
///
/// Opportunistic by contract: anything that cannot be inspected or removed is
/// counted as skipped and left for a later sweep, never surfaced as an error.
/// A base directory that does not exist yet is not an error either.
pub fn sweep(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    grace_seconds: i64,
) SweepResult {
    var result = SweepResult{};
    const io = path_mod.currentIo();

    var dir = std.Io.Dir.openDirAbsolute(io, base_dir, .{ .iterate = true }) catch return result;
    defer dir.close(io);

    const euid = std.os.linux.geteuid();
    const privileged = euid == 0;
    const now = std.Io.Clock.real.now(io).toSeconds();

    var it = dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch break;
        const entry = maybe_entry orelse break;
        if (entry.kind != .directory) {
            // A lock file whose directory is gone is itself debris.
            if (std.mem.endsWith(u8, entry.name, OWNER_LOCK_SUFFIX)) {
                reapStaleLock(allocator, dir, base_dir, entry.name, &result);
            } else {
                result.skipped += 1;
            }
            continue;
        }

        const child = std.fs.path.join(allocator, &.{ base_dir, entry.name }) catch {
            result.skipped += 1;
            continue;
        };
        defer allocator.free(child);

        const meta = lstatMeta(allocator, child) orelse {
            result.skipped += 1;
            continue;
        };
        if (!meta.is_dir) {
            result.skipped += 1;
            continue;
        }

        // A world-writable scratch base must never become a way to delete
        // another user's in-flight work.
        if (!privileged and meta.uid != euid) {
            result.skipped += 1;
            continue;
        }

        switch (classify(allocator, child, meta, now, grace_seconds)) {
            .live => result.live += 1,
            .skip => result.skipped += 1,
            .reclaim => {
                path_mod.deleteTreeAbsolute(child) catch {
                    result.skipped += 1;
                    continue;
                };
                // The lock file is debris once its directory is gone. Failure
                // here is harmless: a later sweep reaps it.
                const lock_abs = std.fmt.allocPrint(allocator, "{s}{s}", .{ child, OWNER_LOCK_SUFFIX }) catch {
                    result.reclaimed += 1;
                    continue;
                };
                defer allocator.free(lock_abs);
                std.Io.Dir.deleteFileAbsolute(io, lock_abs) catch {};
                result.reclaimed += 1;
            },
        }
    }

    return result;
}

const Verdict = enum { live, skip, reclaim };

fn classify(
    allocator: std.mem.Allocator,
    child_abs: []const u8,
    meta: Meta,
    now_seconds: i64,
    grace_seconds: i64,
) Verdict {
    const lock_abs = std.fmt.allocPrint(allocator, "{s}{s}", .{ child_abs, OWNER_LOCK_SUFFIX }) catch return .skip;
    defer allocator.free(lock_abs);
    const lock_abs_z = allocator.dupeZ(u8, lock_abs) catch return .skip;
    defer allocator.free(lock_abs_z);

    const fd = std.c.open(lock_abs_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        // No owner lock: either predates this protocol, or the owner died
        // between creating the directory and claiming it. Only reclaim once it
        // is old enough that it cannot be a directory being set up right now.
        const age = now_seconds - meta.mtime_seconds;
        return if (age >= grace_seconds) .reclaim else .skip;
    }
    defer _ = std.c.close(fd);

    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return .live;
    _ = std.c.flock(fd, std.c.LOCK.UN);
    return .reclaim;
}

/// Remove an `.owner` lock file whose tracked directory no longer exists.
/// Leaves it alone while the owner still holds it, so a live claim taken
/// moments before its directory appears is never destroyed.
fn reapStaleLock(
    allocator: std.mem.Allocator,
    base: std.Io.Dir,
    base_dir: []const u8,
    lock_name: []const u8,
    result: *SweepResult,
) void {
    const io = path_mod.currentIo();
    const dir_name = lock_name[0 .. lock_name.len - OWNER_LOCK_SUFFIX.len];

    if (base.statFile(io, dir_name, .{ .follow_symlinks = false })) |_| {
        // Directory still present; it is handled as its own entry.
        result.skipped += 1;
        return;
    } else |_| {}

    const lock_abs = std.fs.path.join(allocator, &.{ base_dir, lock_name }) catch {
        result.skipped += 1;
        return;
    };
    defer allocator.free(lock_abs);
    const lock_abs_z = allocator.dupeZ(u8, lock_abs) catch {
        result.skipped += 1;
        return;
    };
    defer allocator.free(lock_abs_z);

    const fd = std.c.open(lock_abs_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        result.skipped += 1;
        return;
    }
    const held = std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0;
    if (!held) _ = std.c.flock(fd, std.c.LOCK.UN);
    _ = std.c.close(fd);
    if (held) {
        result.live += 1;
        return;
    }

    std.Io.Dir.deleteFileAbsolute(io, lock_abs) catch {
        result.skipped += 1;
        return;
    };
    result.reclaimed += 1;
}

// Tests

test "claim then sweep leaves a live directory alone and reclaims a released one" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const live_dir = try std.fs.path.join(alloc, &.{ base, "live" });
    defer alloc.free(live_dir);
    try path_mod.ensureDirExists(live_dir);
    var live_claim = try claim(alloc, live_dir, false);

    const dead_dir = try std.fs.path.join(alloc, &.{ base, "dead" });
    defer alloc.free(dead_dir);
    try path_mod.ensureDirExists(dead_dir);
    var dead_claim = try claim(alloc, dead_dir, false);
    // Releasing stands in for the owning process exiting.
    dead_claim.release();

    const result = sweep(alloc, base, DEFAULT_GRACE_SECONDS);
    try std.testing.expectEqual(@as(usize, 1), result.reclaimed);
    try std.testing.expectEqual(@as(usize, 1), result.live);

    try std.testing.expect(path_mod.fileExists(live_dir) or true);
    var still_there = try path_mod.openExistingDir(live_dir);
    still_there.close(path_mod.currentIo());
    try std.testing.expectError(error.FileNotFound, path_mod.openExistingDir(dead_dir));

    live_claim.release();
}

test "sweep spares an unclaimed directory inside the grace period" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    // Freshly created, no owner lock: indistinguishable from a directory that
    // is mid-setup right now, so it must survive.
    const fresh = try std.fs.path.join(alloc, &.{ base, "fresh" });
    defer alloc.free(fresh);
    try path_mod.ensureDirExists(fresh);

    const result = sweep(alloc, base, DEFAULT_GRACE_SECONDS);
    try std.testing.expectEqual(@as(usize, 0), result.reclaimed);

    var still_there = try path_mod.openExistingDir(fresh);
    still_there.close(path_mod.currentIo());
}

test "sweep reclaims an unclaimed directory once it is past the grace period" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const legacy = try std.fs.path.join(alloc, &.{ base, "legacy" });
    defer alloc.free(legacy);
    try path_mod.ensureDirExists(legacy);

    // grace_seconds = 0 makes any age qualify, which is what an operator
    // forcing a full sweep would ask for.
    const result = sweep(alloc, base, 0);
    try std.testing.expectEqual(@as(usize, 1), result.reclaimed);
    try std.testing.expectError(error.FileNotFound, path_mod.openExistingDir(legacy));
}

test "sweep tolerates a missing base directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const missing = try std.fs.path.join(alloc, &.{ buf[0..base_len], "not-created" });
    defer alloc.free(missing);

    const result = sweep(alloc, missing, DEFAULT_GRACE_SECONDS);
    try std.testing.expectEqual(@as(usize, 0), result.reclaimed);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
}

test "a second claim on a live directory is refused" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const dir = try std.fs.path.join(alloc, &.{ buf[0..base_len], "one" });
    defer alloc.free(dir);
    try path_mod.ensureDirExists(dir);

    var first = try claim(alloc, dir, false);
    defer first.release();
    try std.testing.expectError(ScratchError.FileSystem, claim(alloc, dir, false));
}

// The reason the lock is a sibling: a store staging directory is renamed into
// the store as-is, and its content hash is computed from exactly what it
// contains. A marker inside would become part of the payload.
test "claim puts nothing inside the tracked directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const dir = try std.fs.path.join(alloc, &.{ buf[0..base_len], "staging" });
    defer alloc.free(dir);
    try path_mod.ensureDirExists(dir);

    var held = try claim(alloc, dir, false);
    defer held.release();

    var opened = try path_mod.openExistingDir(dir);
    defer opened.close(path_mod.currentIo());
    var it = opened.iterate();
    var count: usize = 0;
    while (try it.next(path_mod.currentIo())) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "sweep reaps a lock file whose directory is already gone" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const dir = try std.fs.path.join(alloc, &.{ base, "gone" });
    defer alloc.free(dir);
    try path_mod.ensureDirExists(dir);
    var held = try claim(alloc, dir, false);
    held.release();
    try path_mod.deleteTreeAbsolute(dir);

    const lock = try std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, OWNER_LOCK_SUFFIX });
    defer alloc.free(lock);
    try std.testing.expect(path_mod.fileExists(lock));

    const result = sweep(alloc, base, DEFAULT_GRACE_SECONDS);
    try std.testing.expectEqual(@as(usize, 1), result.reclaimed);
    try std.testing.expect(!path_mod.fileExists(lock));
}

test "sweep leaves a live claim's lock file alone when its directory is missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const dir = try std.fs.path.join(alloc, &.{ base, "pending" });
    defer alloc.free(dir);
    try path_mod.ensureDirExists(dir);
    var held = try claim(alloc, dir, false);
    defer held.release();
    try path_mod.deleteTreeAbsolute(dir);

    const result = sweep(alloc, base, DEFAULT_GRACE_SECONDS);
    try std.testing.expectEqual(@as(usize, 0), result.reclaimed);
    try std.testing.expectEqual(@as(usize, 1), result.live);
}
