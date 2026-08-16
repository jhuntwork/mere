//! Ownership and reclamation for scratch directories (spec §4.3).
//!
//! Store staging (`/mere/store/.incoming/<rand>/`) is only meaningful while the
//! process that created it is alive. Any abnormal exit - a crash, SIGKILL, a
//! cancelled invocation - used to leak the whole tree permanently, and nothing
//! swept `.incoming` at all.
//!
//! Liveness is an exclusive `flock(2)` on the scratch directory's own fd. No
//! lock file, no state file, nothing on disk that has to be created, parsed, or
//! cleaned up afterwards - the claim exists only as long as the fd does. The
//! lock rides on the open file description, so the kernel releases it when the
//! owner exits however it exits, and it survives `execve`. That means no
//! heartbeat, no timeout, and no pid check for pid reuse to defeat, and it
//! leaves nothing behind for the sweep to distinguish from real content.
//!
//! The lock follows the inode, so a staging directory renamed into the store
//! carries the claim with it until the owner closes the fd. That is harmless:
//! the store object is complete by then, and nothing about it is marked on disk.

const std = @import("std");
const path_mod = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const ScratchError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

/// A directory whose claim is free is only reclaimed once it is at least this
/// old. The claim alone cannot distinguish "abandoned" from "created moments
/// ago and about to be claimed", so age closes that window.
pub const DEFAULT_GRACE_SECONDS: i64 = 300;

/// A held claim on a scratch directory. Released by `release`, or by the kernel
/// when the owning process exits.
pub const Claim = struct {
    fd: std.posix.fd_t,

    pub fn release(self: *Claim) void {
        if (self.fd < 0) return;
        // Closing drops the flock; there is nothing else to undo.
        _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

/// Claim `dir_path`, which must already exist.
///
/// `inheritable` clears FD_CLOEXEC so the claim survives into an exec'd
/// process - what namespace sessions need, since the session stays in use for
/// as long as the shell or build command runs.
pub fn claim(allocator: std.mem.Allocator, dir_path: []const u8, inheritable: bool) ScratchError!Claim {
    const dir_path_z = allocator.dupeZ(u8, dir_path) catch return ScratchError.OutOfMemory;
    defer allocator.free(dir_path_z);

    // NOFOLLOW so a symlink standing in for the directory is refused rather
    // than followed to whatever it points at.
    const fd = std.c.open(dir_path_z.ptr, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        return switch (std.posix.errno(fd)) {
            .ACCES, .PERM => ScratchError.PermissionDenied,
            .NOTDIR, .LOOP => ScratchError.InvalidInput,
            else => ScratchError.FileSystem,
        };
    }

    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
        // Callers generate unique names, so contention means the name collided
        // with live work rather than being stale.
        _ = std.c.close(fd);
        return ScratchError.FileSystem;
    }

    if (inheritable) {
        // Best effort: losing the inheritance only means the claim is released
        // at exec rather than at command exit, which makes the directory look
        // abandoned early rather than causing live work to be deleted.
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 0));
    }

    return .{ .fd = fd };
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
            result.skipped += 1;
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
    const path_z = allocator.dupeZ(u8, child_abs) catch return .skip;
    defer allocator.free(path_z);

    const fd = std.c.open(path_z.ptr, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0));
    if (fd < 0) return .skip;
    defer _ = std.c.close(fd);

    // Contended means the owner is alive, whatever the directory's age.
    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return .live;
    _ = std.c.flock(fd, std.c.LOCK.UN);

    // Uncontended means either abandoned, or created just now and not yet
    // claimed. There is no on-disk marker to tell those apart - which is the
    // price of not having a lock file - so age decides.
    const age = now_seconds - meta.mtime_seconds;
    return if (age >= grace_seconds) .reclaim else .skip;
}

// Tests

test "sweep reclaims a directory whose claim was dropped and spares one still held" {
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

    // grace 0: the flock, not the age, is what separates the two.
    const result = sweep(alloc, base, 0);
    try std.testing.expectEqual(@as(usize, 1), result.reclaimed);
    try std.testing.expectEqual(@as(usize, 1), result.live);

    var still_there = try path_mod.openExistingDir(live_dir);
    still_there.close(path_mod.currentIo());
    try std.testing.expectError(error.FileNotFound, path_mod.openExistingDir(dead_dir));

    live_claim.release();
}

// A held claim outranks age: a long extraction can leave the staging directory's
// own mtime well behind while the install is still running.
test "sweep spares a held claim regardless of age" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const dir = try std.fs.path.join(alloc, &.{ base, "slow" });
    defer alloc.free(dir);
    try path_mod.ensureDirExists(dir);
    var held = try claim(alloc, dir, false);
    defer held.release();

    const result = sweep(alloc, base, 0);
    try std.testing.expectEqual(@as(usize, 0), result.reclaimed);
    try std.testing.expectEqual(@as(usize, 1), result.live);

    var still_there = try path_mod.openExistingDir(dir);
    still_there.close(path_mod.currentIo());
}

// The window between mkdir and claim: unclaimed and brand new is
// indistinguishable from unclaimed and abandoned, so the grace period must
// protect it.
test "sweep spares an unclaimed directory inside the grace period" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

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

// The whole point of locking the directory rather than a file: a staging
// directory is renamed into the store as-is, and its content hash covers
// exactly what it contains. A claim must leave no trace, inside or beside it.
test "claiming a directory writes nothing to disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const dir = try std.fs.path.join(alloc, &.{ base, "staging" });
    defer alloc.free(dir);
    try path_mod.ensureDirExists(dir);

    var held = try claim(alloc, dir, false);
    defer held.release();

    // Nothing inside the claimed directory...
    {
        var opened = try path_mod.openExistingDir(dir);
        defer opened.close(path_mod.currentIo());
        var it = opened.iterate();
        var count: usize = 0;
        while (try it.next(path_mod.currentIo())) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 0), count);
    }

    // ...and nothing beside it either.
    {
        var opened = try path_mod.openExistingDir(base);
        defer opened.close(path_mod.currentIo());
        var it = opened.iterate();
        var names: usize = 0;
        while (try it.next(path_mod.currentIo())) |e| {
            try std.testing.expectEqualStrings("staging", e.name);
            names += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), names);
    }
}

// A claim survives the rename that admits a staging directory to the store, so
// the owner keeps holding it right through admission.
test "a claim follows the directory across a rename" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const staging = try std.fs.path.join(alloc, &.{ base, "staging" });
    defer alloc.free(staging);
    const final = try std.fs.path.join(alloc, &.{ base, "final" });
    defer alloc.free(final);
    try path_mod.ensureDirExists(staging);

    var held = try claim(alloc, staging, false);
    defer held.release();

    try std.Io.Dir.renameAbsolute(staging, final, path_mod.currentIo());

    // Still claimed under its new name.
    try std.testing.expectError(ScratchError.FileSystem, claim(alloc, final, false));
}

test "claim refuses a symlink standing in for the directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(path_mod.currentIo(), &buf);
    const base = buf[0..base_len];

    const real = try std.fs.path.join(alloc, &.{ base, "real" });
    defer alloc.free(real);
    try path_mod.ensureDirExists(real);

    const link = try std.fs.path.join(alloc, &.{ base, "link" });
    defer alloc.free(link);
    {
        var d = try path_mod.openExistingDir(base);
        defer d.close(path_mod.currentIo());
        try d.symLink(path_mod.currentIo(), real, "link", .{});
    }

    try std.testing.expectError(ScratchError.InvalidInput, claim(alloc, link, false));
}
