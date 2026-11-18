const std = @import("std");
const Context = @import("mere.zig").Context;
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
const path_safety = @import("path_safety.zig");
const hash_mod = @import("hash.zig");
const manifest = @import("manifest.zig");
const fault_injection = @import("fault_injection.zig");

/// Store operations error set
const Std = errors.StandardErrors;
pub const StoreError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{SymlinkEscapesBoundary};
pub const ContentError = StoreError || Std.CorruptData;

/// Verify that an object already present in the store has the content
/// identity `expected_hash`, using the shared hash-compatibility policy.
/// Presence alone never establishes identity: an object that does not match
/// returns CorruptData and must not be admitted to a profile.
pub fn verifyObjectContent(
    ctx: *Context,
    store_path: []const u8,
    expected_hash: []const u8,
) ContentError!hash_mod.ContentVerification {
    if (expected_hash.len != 64) {
        return ctx.fail(error.CorruptData, store_path, "invalid expected content hash length");
    }

    const format = manifest.detectFormat(ctx.allocator, store_path) catch |err| {
        return ctx.fail(switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.PermissionDenied => error.PermissionDenied,
            error.InvalidInput => error.CorruptData,
            else => error.FileSystem,
        }, store_path, "failed to detect package manifest format");
    };

    var diag: hash_mod.HashDiag = .{};
    defer diag.deinit(ctx.allocator);
    const outcome = hash_mod.verifyStoreContent(ctx.allocator, store_path, format.storeHashFormat(), expected_hash, &diag) catch |err| {
        return ctx.failFmt(switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.PermissionDenied => error.PermissionDenied,
            error.InvalidInput => error.CorruptData,
            else => error.FileSystem,
        }, store_path, "failed to compute store content hash: {s}: {s}", .{
            diag.action orelse "hash tree",
            diag.path orelse store_path,
        });
    };
    if (outcome == .mismatch) {
        return ctx.fail(error.CorruptData, store_path, "store content hash mismatch");
    }
    return outcome;
}

/// Whether an existing object must be content-verified before admission.
/// A hardened object (root-owned and immutable, or root-owned and read-only
/// where immutable flags are unsupported) was verified when first admitted
/// and can only be changed by root, so it is trusted as present.
pub fn needsContentVerification(store_path: []const u8) bool {
    return !isHardened(store_path);
}

/// Construct a content-addressed store path from components.
///
/// Format: `<root>/mere/store/<hash>-<name>-<version>/`
///
/// Where:
/// - hash is 64 lowercase hex characters (full BLAKE3 output)
/// - name is the package name
/// - version is the package version (no release number)
///
/// Returns an allocated path string (caller owns, must free with ctx.allocator).
pub fn constructStorePath(
    ctx: *Context,
    content_hash: []const u8,
    name: []const u8,
    version: []const u8,
) StoreError![]const u8 {
    // Validate hash length (must be 64 hex chars)
    if (content_hash.len != 64) {
        return StoreError.InvalidInput;
    }

    // Validate all characters are lowercase hex.
    for (content_hash) |c| {
        const is_lower_hex = (c >= 'a' and c <= 'f') or std.ascii.isDigit(c);
        if (!is_lower_hex) {
            return StoreError.InvalidInput;
        }
    }

    // Construct store directory name: <hash>-<name>-<version>
    const store_dir_name = std.fmt.allocPrint(ctx.allocator, "{s}-{s}-{s}", .{ content_hash, name, version }) catch {
        return StoreError.OutOfMemory;
    };
    defer ctx.allocator.free(store_dir_name);

    // Join with root path
    return std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store", store_dir_name }) catch {
        return StoreError.OutOfMemory;
    };
}

/// Parse a store path to extract the content hash, name, and version.
///
/// Input format: `<root>/mere/store/<hash>-<name>-<version>/`
///
/// Returns the parsed components. All returned strings are slices into the input
/// (no allocation needed).
pub const StorePathComponents = struct {
    content_hash: []const u8,
    name: []const u8,
    version: []const u8,
};

pub fn parseStorePath(store_path: []const u8) StoreError!StorePathComponents {
    if (!std.fs.path.isAbsolute(store_path)) {
        return StoreError.InvalidInput;
    }

    const parent = std.fs.path.dirname(store_path) orelse {
        return StoreError.InvalidInput;
    };
    if (!std.mem.endsWith(u8, parent, "/mere/store")) {
        return StoreError.InvalidInput;
    }

    // Extract the basename (last component)
    const basename = std.fs.path.basename(store_path);

    // Hash is exactly 64 characters followed by '-'
    if (basename.len < 66) { // 64 + '-' + at least 1 char for name
        return StoreError.InvalidInput;
    }

    const hash_part = basename[0..64];

    // Validate lowercase hash characters
    for (hash_part) |c| {
        const is_lower_hex = (c >= 'a' and c <= 'f') or std.ascii.isDigit(c);
        if (!is_lower_hex) {
            return StoreError.InvalidInput;
        }
    }

    // Must have separator after hash
    if (basename[64] != '-') {
        return StoreError.InvalidInput;
    }

    // Find the last '-' to separate name from version
    const rest = basename[65..];
    const last_dash = std.mem.lastIndexOf(u8, rest, "-") orelse {
        return StoreError.InvalidInput;
    };

    const name = rest[0..last_dash];
    const version = rest[last_dash + 1 ..];

    if (name.len == 0 or version.len == 0) {
        return StoreError.InvalidInput;
    }

    return .{
        .content_hash = hash_part,
        .name = name,
        .version = version,
    };
}

/// Translate a physical store path (`{root}/mere/store/...`) into the *logical*
/// store path (`/mere/store/...`) used inside build and shell namespaces and on
/// a booted system.
///
/// Profile symlink targets must be logical. The build and shell namespaces
/// bind-mount `{root}/mere` onto `/mere` (see `namespace.buildSyntheticRoot`),
/// and a booted system has the store at `/mere` directly, so a logical target
/// resolves in all three contexts. A physical target that embeds the `--root`
/// staging prefix only resolves on the host: inside the build namespace it
/// dangles (the `--root` path is under `/home`, which build mode does not mount),
/// so `execve` of a profile binary fails with ENOENT before producing any output.
///
/// The mapping rewrites a leading `{root}/mere` to `/mere`. When `root_path` is
/// "/" (no `--root`) the physical path is already `/mere/...` and is returned
/// unchanged. Paths not under `{root}/mere` are returned unchanged. The result
/// is always newly allocated and owned by the caller.
pub fn toLogicalStorePath(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    physical: []const u8,
) error{OutOfMemory}![]u8 {
    // Normalize away any trailing slashes on the root (but keep a bare "/").
    var root = root_path;
    while (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];

    // With no --root the store already lives at its logical location.
    if (std.mem.eql(u8, root, "/")) {
        return allocator.dupe(u8, physical);
    }

    // Require a true path-boundary match against the root prefix so that a root
    // of "/root" does not spuriously match "/rootx/...".
    const under_root = std.mem.startsWith(u8, physical, root) and
        (physical.len == root.len or physical[root.len] == '/');
    if (!under_root) return allocator.dupe(u8, physical);

    const rest = physical[root.len..]; // "" or "/..."

    // Only rewrite paths that live under the bind-mounted mere directory.
    if (!std.mem.eql(u8, rest, "/mere") and !std.mem.startsWith(u8, rest, "/mere/")) {
        return allocator.dupe(u8, physical);
    }

    return allocator.dupe(u8, rest);
}

/// Check if a store path exists and is valid.
pub fn storePathExists(store_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), store_path, .{}) catch {
        return false;
    };
    return true;
}

/// Check if the current process is running with root privileges
pub fn isPrivileged() bool {
    return std.os.linux.geteuid() == 0;
}

/// Check if a store path has already been hardened (root-owned + immutable flag).
pub fn isHardened(store_path: []const u8) bool {
    const io = path_mod.currentIo();
    var dir = std.Io.Dir.openDirAbsolute(io, store_path, .{}) catch return false;
    defer dir.close(io);

    // Check root ownership
    const store_path_z = std.posix.toPosixPath(store_path) catch return false;
    var statx = std.mem.zeroes(std.os.linux.Statx);
    if (std.os.linux.errno(std.os.linux.statx(
        std.posix.AT.FDCWD,
        &store_path_z,
        0,
        .{ .UID = true },
        &statx,
    )) != .SUCCESS) return false;
    if (statx.uid != 0) return false;

    // Check immutable flag
    var flags: u64 = 0;
    if (std.os.linux.errno(std.os.linux.ioctl(dir.handle, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) {
        // Filesystem doesn't support flags — fall back to ownership + permissions check.
        // Root-owned + read-only is the hardened state on these filesystems.
        const stat = dir.stat(path_mod.currentIo()) catch return false;
        return (stat.permissions.toMode() & 0o222) == 0;
    }
    return (flags & FS_IMMUTABLE_FL) != 0;
}

// --- Store hardening ---

fn ior(typ: u8, nr: u8, comptime T: type) u32 {
    return (0x80 << 24) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, typ) << 8) | nr;
}
fn iow(typ: u8, nr: u8, comptime T: type) u32 {
    return (0x40 << 24) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, typ) << 8) | nr;
}

const FS_IOC_GETFLAGS = ior('f', 1, c_long);
const FS_IOC_SETFLAGS = iow('f', 2, c_long);
const FS_IMMUTABLE_FL: u64 = 0x00000010;

/// Outcome of the optional immutable-flag step. Root ownership and removal
/// of write bits are the required read-only protection; the immutable flag
/// is defense in depth, so its absence is reported, never fatal.
pub const ImmutableOutcome = enum {
    /// The flag was set on every entry.
    applied,
    /// The filesystem does not implement inode flags.
    unsupported,
    /// The filesystem supports flags but setting one failed, for example
    /// without CAP_LINUX_IMMUTABLE in a user namespace.
    failed,
    /// Hardening was disabled by MERE_NO_HARDEN, so no step ran at all.
    skipped,

    /// Combine per-entry outcomes; the most severe one wins. `skipped` is
    /// never produced per entry, so it does not take part in the ordering.
    fn merge(self: ImmutableOutcome, other: ImmutableOutcome) ImmutableOutcome {
        return if (@intFromEnum(other) > @intFromEnum(self)) other else self;
    }
};

pub const HardenResult = struct {
    files_processed: usize = 0,
    immutable: ImmutableOutcome = .applied,
    /// True unless the filesystem lacks inode-flag support. Retained for
    /// callers that only distinguish supported from unsupported.
    immutable_supported: bool = true,

    fn recordImmutable(self: *HardenResult, outcome: ImmutableOutcome) void {
        self.immutable = self.immutable.merge(outcome);
        if (outcome == .unsupported) self.immutable_supported = false;
    }
};

fn classifyFlagsErrno(e: std.os.linux.E) ImmutableOutcome {
    return switch (e) {
        .SUCCESS => .applied,
        // No inode-flag support on this filesystem or file type.
        .NOTTY, .OPNOTSUPP, .INVAL, .NOSYS => .unsupported,
        else => .failed,
    };
}

fn setImmutable(fd: std.posix.fd_t) ImmutableOutcome {
    fault_injection.hit(.store_harden_immutable) catch return .failed;
    var flags: u64 = 0;
    const get = std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_GETFLAGS, @intFromPtr(&flags)));
    if (get != .SUCCESS) return classifyFlagsErrno(get);
    flags |= FS_IMMUTABLE_FL;
    return classifyFlagsErrno(std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_SETFLAGS, @intFromPtr(&flags))));
}

fn clearImmutableFlag(fd: std.posix.fd_t) bool {
    var flags: u64 = 0;
    if (std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_GETFLAGS, @intFromPtr(&flags))) != .SUCCESS) return false;
    flags &= ~FS_IMMUTABLE_FL;
    return std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_SETFLAGS, @intFromPtr(&flags))) == .SUCCESS;
}

/// Harden a store object for system use.
///
/// 1. Validates the caller is root
/// 2. Validates the store path is within the store boundary
/// 3. Recursively: chown root:root, chmod read-only, set FS_IMMUTABLE_FL
/// 4. Validates all symlinks stay within the store path boundary
pub fn harden(ctx: *Context, store_path: []const u8) StoreError!HardenResult {
    ctx.acquireStoreLockForMutation() catch |err| return switch (err) {
        error.OutOfMemory => StoreError.OutOfMemory,
        error.PermissionDenied => StoreError.PermissionDenied,
        else => StoreError.FileSystem,
    };
    defer ctx.releaseStoreLock();
    return hardenLocked(ctx, store_path);
}

fn hardenLocked(ctx: *Context, store_path: []const u8) StoreError!HardenResult {
    if (std.c.getenv("MERE_NO_HARDEN")) |_| return .{ .immutable = .skipped };

    if (!isPrivileged()) {
        return ctx.fail(StoreError.PermissionDenied, store_path, "not running as root");
    }

    const store_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to construct store root path");
    };
    defer ctx.allocator.free(store_dir);

    if (!std.fs.path.isAbsolute(store_path)) {
        return ctx.fail(StoreError.InvalidInput, store_path, "store path must be absolute");
    }

    const normalized_store_dir = std.fs.path.resolve(ctx.allocator, &.{store_dir}) catch {
        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to normalize store root path");
    };
    defer ctx.allocator.free(normalized_store_dir);

    const normalized_store_path = std.fs.path.resolve(ctx.allocator, &.{store_path}) catch {
        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to normalize store path");
    };
    defer ctx.allocator.free(normalized_store_path);

    if (!path_safety.isWithinBoundary(normalized_store_path, normalized_store_dir)) {
        return ctx.fail(StoreError.InvalidInput, store_path, "not within store boundary");
    }

    const io = path_mod.currentIo();
    var dir = path_mod.openExistingDir(store_path) catch {
        return ctx.fail(StoreError.FileSystem, store_path, "failed to open store directory");
    };
    defer dir.close(io);

    var result = HardenResult{};

    var walker = dir.walk(ctx.allocator) catch return StoreError.OutOfMemory;
    defer walker.deinit();

    while (walker.next(io) catch return StoreError.FileSystem) |entry| {
        switch (entry.kind) {
            .directory => {
                var subdir = dir.openDir(io, entry.path, .{ .iterate = true }) catch {
                    const p = std.fs.path.join(ctx.allocator, &.{ store_path, entry.path }) catch
                        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to allocate path");
                    defer ctx.allocator.free(p);
                    return ctx.fail(StoreError.FileSystem, p, "failed to open subdirectory");
                };
                defer subdir.close(io);
                try hardenEntryOrFail(ctx, subdir.handle, store_path, entry.path, &result);
            },
            .file => {
                var file = dir.openFile(io, entry.path, .{}) catch {
                    const p = std.fs.path.join(ctx.allocator, &.{ store_path, entry.path }) catch
                        return ctx.fail(StoreError.OutOfMemory, store_path, "failed to allocate path");
                    defer ctx.allocator.free(p);
                    return ctx.fail(StoreError.FileSystem, p, "failed to open file");
                };
                defer file.close(io);
                try hardenEntryOrFail(ctx, file.handle, store_path, entry.path, &result);
            },
            .sym_link => {
                const entry_path = std.fs.path.join(ctx.allocator, &.{ store_path, entry.path }) catch {
                    return ctx.fail(StoreError.OutOfMemory, store_path, "failed to allocate symlink path");
                };
                defer ctx.allocator.free(entry_path);

                const symlink_result = path_safety.resolveWithinBoundary(ctx.allocator, entry_path, store_path) catch |err| {
                    const detail = switch (err) {
                        path_safety.PathSafetyError.EscapesBoundary => "symlink escapes store boundary",
                        path_safety.PathSafetyError.SymlinkLoop => "symlink loop detected",
                        path_safety.PathSafetyError.ChainTooDeep => "symlink chain too deep",
                        path_safety.PathSafetyError.InvalidSymlink => "invalid symlink",
                        path_safety.PathSafetyError.InvalidInput => "invalid symlink path",
                        path_safety.PathSafetyError.FileSystem => "failed to read symlink",
                        path_safety.PathSafetyError.OutOfMemory => "out of memory",
                    };
                    return ctx.fail(switch (err) {
                        path_safety.PathSafetyError.EscapesBoundary,
                        path_safety.PathSafetyError.SymlinkLoop,
                        path_safety.PathSafetyError.ChainTooDeep,
                        path_safety.PathSafetyError.InvalidSymlink,
                        => StoreError.SymlinkEscapesBoundary,
                        path_safety.PathSafetyError.InvalidInput => StoreError.InvalidInput,
                        path_safety.PathSafetyError.FileSystem => StoreError.FileSystem,
                        path_safety.PathSafetyError.OutOfMemory => StoreError.OutOfMemory,
                    }, entry_path, detail);
                };
                ctx.allocator.free(symlink_result.path);

                const path_z = std.posix.toPosixPath(entry.path) catch {
                    return ctx.fail(StoreError.InvalidInput, entry_path, "symlink path too long");
                };
                var failure: HardenFailure = undefined;
                lchownRoot(dir.handle, &path_z, &failure) catch {
                    return failHardenStep(ctx, entry_path, failure);
                };
            },
            else => {},
        }
    }

    try hardenEntryOrFail(ctx, dir.handle, store_path, "", &result);
    return result;
}

/// Required hardening steps. A failure of any of these leaves the object
/// without read-only protection and is returned to the caller.
const HardenStep = enum { stat, chown, chmod, lchown };

const HardenFailure = struct {
    step: HardenStep,
    errno: std.os.linux.E,
};

fn hardenStepCheckpoint(step: HardenStep) ?fault_injection.Checkpoint {
    return switch (step) {
        .stat => null,
        .chown, .lchown => .store_harden_chown,
        .chmod => .store_harden_chmod,
    };
}

fn runStep(step: HardenStep, rc: usize, failure: *HardenFailure) error{HardenFailed}!void {
    if (hardenStepCheckpoint(step)) |checkpoint| {
        fault_injection.hit(checkpoint) catch {
            failure.* = .{ .step = step, .errno = .PERM };
            return error.HardenFailed;
        };
    }
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS) {
        failure.* = .{ .step = step, .errno = e };
        return error.HardenFailed;
    }
}

fn lchownRoot(dir_fd: std.posix.fd_t, path_z: [*:0]const u8, failure: *HardenFailure) error{HardenFailed}!void {
    try runStep(.lchown, std.os.linux.fchownat(dir_fd, path_z, 0, 0, std.os.linux.AT.SYMLINK_NOFOLLOW), failure);
}

/// Harden one directory or regular file: root ownership and no write bits
/// (required), then the immutable flag (optional, recorded in `result`).
/// An entry that is already immutable, root-owned, and read-only is left
/// alone; chown and chmod on an immutable inode would fail with EPERM.
fn hardenEntry(fd: std.posix.fd_t, result: *HardenResult, failure: *HardenFailure) error{HardenFailed}!void {
    // Capture mode before fchown — chown clears setuid/setgid bits.
    var sx = std.mem.zeroes(std.os.linux.Statx);
    try runStep(.stat, std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &sx), failure);
    const mode: u32 = @as(u32, sx.mode) & 0o7777;

    var flags: u64 = 0;
    const flags_known = std.os.linux.errno(std.os.linux.ioctl(fd, FS_IOC_GETFLAGS, @intFromPtr(&flags))) == .SUCCESS;
    if (flags_known and (flags & FS_IMMUTABLE_FL) != 0) {
        if (sx.uid == 0 and (mode & 0o222) == 0) {
            result.recordImmutable(.applied);
            result.files_processed += 1;
            return;
        }
        // Immutable but not read-only protected: chown/chmod cannot repair it.
        failure.* = .{ .step = .chown, .errno = .PERM };
        return error.HardenFailed;
    }

    try runStep(.chown, std.os.linux.fchown(fd, 0, 0), failure);
    try runStep(.chmod, std.os.linux.fchmod(fd, mode & ~@as(u32, 0o222)), failure);
    result.recordImmutable(setImmutable(fd));
    result.files_processed += 1;
}

fn failHardenStep(ctx: *Context, subject: []const u8, failure: HardenFailure) StoreError {
    const err: StoreError = switch (failure.errno) {
        .PERM, .ACCES, .ROFS => StoreError.PermissionDenied,
        else => StoreError.FileSystem,
    };
    return ctx.failFmt(err, subject, "required store hardening step '{s}' failed: {s}", .{
        @tagName(failure.step),
        @tagName(failure.errno),
    });
}

fn hardenEntryOrFail(
    ctx: *Context,
    fd: std.posix.fd_t,
    store_path: []const u8,
    rel_path: []const u8,
    result: *HardenResult,
) StoreError!void {
    var failure: HardenFailure = undefined;
    hardenEntry(fd, result, &failure) catch {
        const subject = if (rel_path.len == 0)
            ctx.allocator.dupe(u8, store_path) catch return StoreError.OutOfMemory
        else
            std.fs.path.join(ctx.allocator, &.{ store_path, rel_path }) catch return StoreError.OutOfMemory;
        defer ctx.allocator.free(subject);
        return failHardenStep(ctx, subject, failure);
    };
}

/// Recursively clear filesystem immutable flags on a store path.
/// Must be called before deletion (GC). The public operation acquires the
/// process-wide store lock; the locked helper is used by tests and callers
/// that already hold it.
pub fn clearImmutable(ctx: *Context, store_path: []const u8) HardenResult {
    ctx.acquireStoreLockForMutation() catch return .{};
    defer ctx.releaseStoreLock();
    return clearImmutableLocked(ctx.allocator, store_path);
}

fn clearImmutableLocked(allocator: std.mem.Allocator, store_path: []const u8) HardenResult {
    const io = path_mod.currentIo();
    var result = HardenResult{};

    {
        var top = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return result;
        _ = clearImmutableFlag(top.handle);
        top.close(io);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return result;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return result;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                var subdir = dir.openDir(io, entry.path, .{ .iterate = true }) catch continue;
                defer subdir.close(io);
                if (!clearImmutableFlag(subdir.handle)) result.immutable_supported = false;
                result.files_processed += 1;
            },
            .file => {
                var file = dir.openFile(io, entry.path, .{}) catch continue;
                defer file.close(io);
                if (!clearImmutableFlag(file.handle)) result.immutable_supported = false;
                result.files_processed += 1;
            },
            else => {},
        }
    }

    return result;
}

// Tests

// Spec #4.1: Store path format validation
test "constructStorePath creates correct format" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    const hash = "a" ** 64; // 64 'a' characters
    const store_path = try constructStorePath(&ctx, hash, "nginx", "1.24.0");
    defer ctx.allocator.free(store_path);

    // Check that path contains expected components
    try std.testing.expect(std.mem.indexOf(u8, store_path, "mere/store/") != null);
    try std.testing.expect(std.mem.indexOf(u8, store_path, hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, store_path, "-nginx-1.24.0") != null);
}

// Spec #4.1: Store path format validation
test "constructStorePath rejects invalid hash length" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    // Too short
    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, "abc", "test", "1.0"));

    // Too long
    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, "a" ** 65, "test", "1.0"));
}

// Spec #4.1: Store path format validation
test "constructStorePath rejects non-hex characters" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    // Contains 'g' which is not hex
    const bad_hash = "g" ** 64;
    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, bad_hash, "test", "1.0"));
}

test "constructStorePath rejects uppercase hash" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    try std.testing.expectError(StoreError.InvalidInput, constructStorePath(&ctx, "A" ** 64, "test", "1.0"));
}

test "parseStorePath extracts components correctly" {
    const path = "/mere/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nginx-1.24.0";
    const components = try parseStorePath(path);

    try std.testing.expectEqualStrings("a" ** 64, components.content_hash);
    try std.testing.expectEqualStrings("nginx", components.name);
    try std.testing.expectEqualStrings("1.24.0", components.version);
}

test "parseStorePath handles package names with hyphens" {
    const path = "/mere/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-my-package-name-2.0.0";
    const components = try parseStorePath(path);

    try std.testing.expectEqualStrings("b" ** 64, components.content_hash);
    try std.testing.expectEqualStrings("my-package-name", components.name);
    try std.testing.expectEqualStrings("2.0.0", components.version);
}

test "toLogicalStorePath rewrites a --root store path to /mere" {
    const a = std.testing.allocator;
    const r = try toLogicalStorePath(
        a,
        "/home/u/.swamp/mere-dev/root",
        "/home/u/.swamp/mere-dev/root/mere/store/" ++ "a" ** 64 ++ "-busybox-1.37.0/bin/sh",
    );
    defer a.free(r);
    try std.testing.expectEqualStrings("/mere/store/" ++ "a" ** 64 ++ "-busybox-1.37.0/bin/sh", r);
}

test "toLogicalStorePath is identity when root is /" {
    const a = std.testing.allocator;
    const r = try toLogicalStorePath(a, "/", "/mere/store/pkg/bin/sh");
    defer a.free(r);
    try std.testing.expectEqualStrings("/mere/store/pkg/bin/sh", r);
}

test "toLogicalStorePath tolerates a trailing slash on root" {
    const a = std.testing.allocator;
    const r = try toLogicalStorePath(a, "/root/", "/root/mere/store/pkg/bin/sh");
    defer a.free(r);
    try std.testing.expectEqualStrings("/mere/store/pkg/bin/sh", r);
}

test "toLogicalStorePath leaves non-mere paths under root unchanged" {
    const a = std.testing.allocator;
    const r = try toLogicalStorePath(a, "/root", "/root/store/pkg/bin/sh");
    defer a.free(r);
    try std.testing.expectEqualStrings("/root/store/pkg/bin/sh", r);
}

test "toLogicalStorePath leaves paths outside root unchanged" {
    const a = std.testing.allocator;
    const r = try toLogicalStorePath(a, "/root", "/other/mere/store/pkg/bin/sh");
    defer a.free(r);
    try std.testing.expectEqualStrings("/other/mere/store/pkg/bin/sh", r);
}

test "toLogicalStorePath does not match a partial path component" {
    const a = std.testing.allocator;
    // "/root" must not be treated as a prefix of "/rootx/...".
    const r = try toLogicalStorePath(a, "/root", "/rootx/mere/store/pkg/bin/sh");
    defer a.free(r);
    try std.testing.expectEqualStrings("/rootx/mere/store/pkg/bin/sh", r);
}

test "parseStorePath rejects invalid paths" {
    // Too short
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("short"));

    // No separator after hash
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    // Missing version (no second dash in rest)
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nameonly"));

    // Not under /mere/store
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("/tmp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-name-1.0"));

    // Uppercase hash is not canonical
    try std.testing.expectError(StoreError.InvalidInput, parseStorePath("/mere/store/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-name-1.0"));
}

test "storePathExists returns correct values" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Existing path
    try std.testing.expect(storePathExists(test_env.path));

    // Non-existing path
    try std.testing.expect(!storePathExists("/nonexistent/path/12345"));
}

test "isPrivileged detects root" {
    const is_root = isPrivileged();
    // Can't test both cases in single test, just verify it returns a bool
    _ = is_root;
}

// Spec #7: Symlink validation (max depth, loop detection, boundary checking)
test "path safety rejects escapes, loops, and deep chains" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);

    const store_path = try std.fs.path.join(allocator, &.{ store_root, "a" ** 64 ++ "-test-1.0" });
    defer allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    // 1) Escaping symlink
    const escape_link = try std.fs.path.join(allocator, &.{ store_path, "escape_link" });
    defer allocator.free(escape_link);
    try std.Io.Dir.symLinkAbsolute(path_mod.currentIo(), "/etc/passwd", escape_link, .{});
    try std.testing.expectError(
        path_safety.PathSafetyError.EscapesBoundary,
        path_safety.resolveWithinBoundary(allocator, escape_link, store_path),
    );

    // 2) Symlink loop
    const loop_a = try std.fs.path.join(allocator, &.{ store_path, "loop_a" });
    defer allocator.free(loop_a);
    const loop_b = try std.fs.path.join(allocator, &.{ store_path, "loop_b" });
    defer allocator.free(loop_b);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "loop_b", "loop_a", .{});
        try store_dir_handle.symLink(path_mod.currentIo(), "loop_a", "loop_b", .{});
    }
    try std.testing.expectError(
        path_safety.PathSafetyError.SymlinkLoop,
        path_safety.resolveWithinBoundary(allocator, loop_a, store_path),
    );

    // 3) Chain too deep
    const prev = try std.fmt.allocPrint(allocator, "{s}/chain_0", .{store_path});
    defer allocator.free(prev);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "chain_1", "chain_0", .{});
    }

    var idx: u32 = 1;
    while (idx <= path_safety.MAX_SYMLINK_DEPTH + 1) : (idx += 1) {
        const current = try std.fmt.allocPrint(allocator, "{s}/chain_{d}", .{ store_path, idx });
        defer allocator.free(current);
        const next = try std.fmt.allocPrint(allocator, "chain_{d}", .{idx + 1});
        defer allocator.free(next);
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        const current_name = try std.fmt.allocPrint(allocator, "chain_{d}", .{idx});
        defer allocator.free(current_name);
        try store_dir_handle.symLink(path_mod.currentIo(), next, current_name, .{});
    }
    try std.testing.expectError(
        path_safety.PathSafetyError.ChainTooDeep,
        path_safety.resolveWithinBoundary(allocator, prev, store_path),
    );

    // 4) Valid in-store link
    const data_file = try std.fs.path.join(allocator, &.{ store_path, "data.txt" });
    defer allocator.free(data_file);
    {
        var f = try path_mod.makePathAndOpenFile(data_file);
        try f.writeStreamingAll(path_mod.currentIo(), "ok");
        f.close(path_mod.currentIo());
    }
    const ok_link = try std.fs.path.join(allocator, &.{ store_path, "ok_link" });
    defer allocator.free(ok_link);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "data.txt", "ok_link", .{});
    }
    {
        const result = try path_safety.resolveWithinBoundary(allocator, ok_link, store_path);
        defer allocator.free(result.path);
    }

    // 5) Broken link is allowed
    const broken = try std.fs.path.join(allocator, &.{ store_path, "broken_link" });
    defer allocator.free(broken);
    {
        var store_dir_handle = try path_mod.openExistingDir(store_path);
        defer store_dir_handle.close(path_mod.currentIo());
        try store_dir_handle.symLink(path_mod.currentIo(), "missing.txt", "broken_link", .{});
    }
    {
        const result = try path_safety.resolveWithinBoundary(allocator, broken, store_path);
        defer allocator.free(result.path);
    }
}

// Spec #4.1: Store admission idempotence (collision handling)
test "store admission handles existing path idempotently" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    // Create a store path that already exists
    const hash = "c" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash ++ "-existing-1.0" });
    defer ctx.allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    // Create a file in the existing store path to verify it's not empty
    const test_file = try std.fs.path.join(ctx.allocator, &.{ store_path, "test.txt" });
    defer ctx.allocator.free(test_file);
    var file = try path_mod.makePathAndOpenFile(test_file);
    try file.writeStreamingAll(path_mod.currentIo(), "existing content");
    file.close(path_mod.currentIo());

    // Verify the path exists
    try std.testing.expect(storePathExists(store_path));

    // Create a staging directory to simulate a second admission attempt
    const staging_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "staging" });
    defer ctx.allocator.free(staging_path);
    try path_mod.ensureDirExists(staging_path);

    const staging_file = try std.fs.path.join(ctx.allocator, &.{ staging_path, "test.txt" });
    defer ctx.allocator.free(staging_file);
    var staging_f = try path_mod.makePathAndOpenFile(staging_file);
    try staging_f.writeStreamingAll(path_mod.currentIo(), "new content");
    staging_f.close(path_mod.currentIo());

    // Under the 0.16 Io rename API, replacing an existing non-empty directory
    // surfaces as DirNotEmpty.
    try std.testing.expectError(error.DirNotEmpty, std.Io.Dir.renameAbsolute(staging_path, store_path, path_mod.currentIo()));

    // Original store path should still exist with original content
    try std.testing.expect(storePathExists(store_path));
    var verify_file = try path_mod.openExistingFile(test_file);
    defer verify_file.close(path_mod.currentIo());
    var buf: [100]u8 = undefined;
    const n = try verify_file.readPositionalAll(path_mod.currentIo(), &buf, 0);
    try std.testing.expectEqualStrings("existing content", buf[0..n]);

    // Clean up staging directory (simulating what install.zig does)
    path_mod.deleteTreeAbsolute(staging_path) catch {};
}

// Spec #7: Relative symlink that stays within boundary is accepted
test "resolveWithinBoundary accepts relative symlink within store" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create a store-like directory structure
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);

    const store_path = try std.fs.path.join(allocator, &.{ store_root, "d" ** 64 ++ "-reltest-1.0" });
    defer allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    // Create a subdirectory with a real file
    const lib_dir = try std.fs.path.join(allocator, &.{ store_path, "lib" });
    defer allocator.free(lib_dir);
    try path_mod.ensureDirExists(lib_dir);

    const real_file = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so.1.0" });
    defer allocator.free(real_file);
    {
        var f = try path_mod.makePathAndOpenFile(real_file);
        try f.writeStreamingAll(path_mod.currentIo(), "ELF...");
        f.close(path_mod.currentIo());
    }

    // Create a relative symlink: lib/libfoo.so -> libfoo.so.1.0
    const rel_link = try std.fs.path.join(allocator, &.{ lib_dir, "libfoo.so" });
    defer allocator.free(rel_link);
    {
        var lib_dir_handle = try path_mod.openExistingDir(lib_dir);
        defer lib_dir_handle.close(path_mod.currentIo());
        try lib_dir_handle.symLink(path_mod.currentIo(), "libfoo.so.1.0", "libfoo.so", .{});
    }

    // resolveWithinBoundary should accept this relative symlink
    const result = try path_safety.resolveWithinBoundary(allocator, rel_link, store_path);
    defer allocator.free(result.path);

    // The resolved path should be within the store boundary
    try std.testing.expect(path_safety.isWithinBoundary(result.path, store_path));
}

test "harden validates store boundary" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const outside_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "not-store" });
    defer ctx.allocator.free(outside_path);
    try path_mod.ensureDirExists(outside_path);

    if (isPrivileged()) {
        try std.testing.expectError(StoreError.InvalidInput, harden(ctx, outside_path));
    } else {
        try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, outside_path));
    }
}

test "harden rejects sibling-prefix path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const sibling_path = try std.fs.path.join(ctx.allocator, &.{
        test_env.path,
        "mere",
        "store-evil",
        "a" ** 64 ++ "-pkg-1.0.0",
    });
    defer ctx.allocator.free(sibling_path);
    try path_mod.ensureDirExists(sibling_path);

    if (isPrivileged()) {
        try std.testing.expectError(StoreError.InvalidInput, harden(ctx, sibling_path));
    } else {
        try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, sibling_path));
    }
}

test "harden requires privilege" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const hash_val = "a" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash_val ++ "-test-1.0" });
    defer ctx.allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    if (!isPrivileged()) {
        try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, store_path));
    }
}

test "harden preserves directory setgid and sticky bits" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    if (!isPrivileged()) return error.SkipZigTest;

    const io = path_mod.currentIo();
    const allocator = test_env.ctx.allocator;
    const dir_path = try std.fs.path.join(allocator, &.{ test_env.path, "harden-special" });
    defer allocator.free(dir_path);

    var dir = try path_mod.makePathAndOpenDir(dir_path);
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o3777));

    var result = HardenResult{};
    var failure: HardenFailure = undefined;
    try hardenEntry(dir.handle, &result, &failure);
    defer _ = clearImmutableFlag(dir.handle);

    const mode = (try dir.stat(io)).permissions.toMode() & 0o7777;
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o3555), mode);
}

test "harden detects escaping symlinks" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    if (!isPrivileged()) return error.SkipZigTest;

    const hash_val = "b" ** 64;
    const store_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", hash_val ++ "-escape-1.0" });
    defer ctx.allocator.free(store_path);
    try path_mod.ensureDirExists(store_path);

    const link_path = try std.fs.path.join(ctx.allocator, &.{ store_path, "escape_link" });
    defer ctx.allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(path_mod.currentIo(), "/etc/passwd", link_path, .{});

    try std.testing.expectError(StoreError.SymlinkEscapesBoundary, harden(ctx, store_path));
}

test "clearImmutable allows modification after clearing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "def-pkg-2.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }

    const file_path = try std.fs.path.join(allocator, &.{ store_path, "file.txt" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "content\n");
    }

    _ = clearImmutable(&test_env.ctx, store_path);

    {
        var f = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o644));
    }
}

test "clearImmutable handles empty directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "empty-pkg-1.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }

    const result = clearImmutable(&test_env.ctx, store_path);
    try std.testing.expectEqual(@as(usize, 0), result.files_processed);
}

test "isHardened returns false for user-owned store path" {
    if (isPrivileged()) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const hash_val = "c" ** 64;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", hash_val ++ "-pkg-1.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }

    try std.testing.expect(!isHardened(store_path));
}

test "isHardened returns false for nonexistent path" {
    try std.testing.expect(!isHardened("/mere/store/nonexistent-pkg-1.0"));
}

fn writeTestStoreFile(dir_path: []const u8, rel_path: []const u8, bytes: []const u8) !void {
    const io = path_mod.currentIo();
    const full = try std.fs.path.join(std.testing.allocator, &.{ dir_path, rel_path });
    defer std.testing.allocator.free(full);
    std.Io.Dir.deleteFileAbsolute(io, full) catch {};
    var file = try path_mod.makePathAndOpenFile(full);
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test "verifyObjectContent rejects a tampered existing object" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const object = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", ("e" ** 64) ++ "-pkg-1.0" });
    defer ctx.allocator.free(object);
    try writeTestStoreFile(object, "bin/tool", "original");

    const expected = try hash_mod.calculateStoreContentHash(ctx.allocator, object, null);
    defer ctx.allocator.free(expected);
    try std.testing.expectEqual(hash_mod.ContentVerification.match, try verifyObjectContent(ctx, object, expected));

    // Present at the right path is not the same as having the right content.
    try writeTestStoreFile(object, "bin/tool", "tampered");
    try std.testing.expectError(error.CorruptData, verifyObjectContent(ctx, object, expected));
    try std.testing.expectError(error.CorruptData, verifyObjectContent(ctx, object, "abc"));
}

test "immutable flag outcomes separate unsupported filesystems from failures" {
    try std.testing.expectEqual(ImmutableOutcome.applied, classifyFlagsErrno(.SUCCESS));
    try std.testing.expectEqual(ImmutableOutcome.unsupported, classifyFlagsErrno(.NOTTY));
    try std.testing.expectEqual(ImmutableOutcome.unsupported, classifyFlagsErrno(.OPNOTSUPP));
    try std.testing.expectEqual(ImmutableOutcome.failed, classifyFlagsErrno(.PERM));
    try std.testing.expectEqual(ImmutableOutcome.failed, classifyFlagsErrno(.IO));

    var result = HardenResult{};
    result.recordImmutable(.applied);
    try std.testing.expectEqual(ImmutableOutcome.applied, result.immutable);
    result.recordImmutable(.unsupported);
    try std.testing.expectEqual(ImmutableOutcome.unsupported, result.immutable);
    try std.testing.expect(!result.immutable_supported);
    result.recordImmutable(.failed);
    result.recordImmutable(.applied);
    try std.testing.expectEqual(ImmutableOutcome.failed, result.immutable);
}

test "hardenEntry returns an injected chown failure to the caller" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();
    try writeTestStoreFile(test_env.path, "entry", "x");
    const entry_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "entry" });
    defer std.testing.allocator.free(entry_path);
    var file = try std.Io.Dir.openFileAbsolute(io, entry_path, .{});
    defer file.close(io);

    fault_injection.setForTest(.store_harden_chown, .fail);
    defer fault_injection.clearForTest();

    var result = HardenResult{};
    var failure: HardenFailure = undefined;
    try std.testing.expectError(error.HardenFailed, hardenEntry(file.handle, &result, &failure));
    try std.testing.expectEqual(HardenStep.chown, failure.step);
    try std.testing.expectEqual(@as(usize, 0), result.files_processed);
}

test "hardenEntry surfaces a real chown failure without privilege" {
    if (isPrivileged()) return error.SkipZigTest;
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();
    try writeTestStoreFile(test_env.path, "entry", "x");
    const entry_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "entry" });
    defer std.testing.allocator.free(entry_path);
    var file = try std.Io.Dir.openFileAbsolute(io, entry_path, .{});
    defer file.close(io);

    var result = HardenResult{};
    var failure: HardenFailure = undefined;
    try std.testing.expectError(error.HardenFailed, hardenEntry(file.handle, &result, &failure));
    try std.testing.expectEqual(HardenStep.chown, failure.step);
    // EPERM normally; EINVAL in a user namespace where uid 0 is unmapped.
    try std.testing.expect(failure.errno != .SUCCESS);
}

test "harden returns an injected chmod failure instead of reporting success" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    if (!isPrivileged()) return error.SkipZigTest;

    const object = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", ("f" ** 64) ++ "-chmod-1.0" });
    defer ctx.allocator.free(object);
    try writeTestStoreFile(object, "payload", "x");

    fault_injection.setForTest(.store_harden_chmod, .fail);
    defer fault_injection.clearForTest();
    try std.testing.expectError(StoreError.PermissionDenied, harden(ctx, object));
}

test "harden reports an immutable-flag failure without failing required hardening" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    if (!isPrivileged()) return error.SkipZigTest;

    const object = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", ("9" ** 64) ++ "-immutable-1.0" });
    defer ctx.allocator.free(object);
    try writeTestStoreFile(object, "payload", "x");

    fault_injection.setForTest(.store_harden_immutable, .fail);
    defer fault_injection.clearForTest();
    const result = try harden(ctx, object);
    try std.testing.expectEqual(ImmutableOutcome.failed, result.immutable);

    // Required read-only protection was still applied.
    const io = path_mod.currentIo();
    const payload_path = try std.fs.path.join(ctx.allocator, &.{ object, "payload" });
    defer ctx.allocator.free(payload_path);
    var payload = try std.Io.Dir.openFileAbsolute(io, payload_path, .{});
    defer payload.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), (try payload.stat(io)).permissions.toMode() & 0o222);
}

test "harden is idempotent on an already-hardened object" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    if (!isPrivileged()) return error.SkipZigTest;

    const object = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", ("8" ** 64) ++ "-again-1.0" });
    defer ctx.allocator.free(object);
    try writeTestStoreFile(object, "payload", "x");

    _ = try harden(ctx, object);
    // Re-admitting an existing object re-runs hardening; immutable entries
    // must not turn into chown/chmod EPERM failures.
    _ = try harden(ctx, object);
}

test "harden reports skipped hardening when MERE_NO_HARDEN is set" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const object = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store", ("5" ** 64) ++ "-skipped-1.0" });
    defer ctx.allocator.free(object);
    try writeTestStoreFile(object, "payload", "x");

    try std.testing.expectEqual(@as(c_int, 0), c_setenv("MERE_NO_HARDEN", "1", 1));
    defer _ = c_unsetenv("MERE_NO_HARDEN");

    const result = try harden(ctx, object);
    try std.testing.expectEqual(ImmutableOutcome.skipped, result.immutable);
    try std.testing.expectEqual(@as(usize, 0), result.files_processed);
}

// Test-only libc environment control. std.c exposes getenv but not setenv
// in this Zig version; the store already links libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
const c_setenv = setenv;
const c_unsetenv = unsetenv;

/// Remove a store object that failed verification after it was hardened.
/// Hardened state is what later calls trust, so the object must not survive.
/// Removal follows garbage collection: clear immutable flags, restore owner
/// write bits so the tree can be unlinked, then delete it.
pub fn removeObject(ctx: *Context, store_path: []const u8) StoreError!void {
    ctx.acquireStoreLockForMutation() catch |err| return switch (err) {
        error.OutOfMemory => StoreError.OutOfMemory,
        error.PermissionDenied => StoreError.PermissionDenied,
        else => StoreError.FileSystem,
    };
    defer ctx.releaseStoreLock();

    _ = clearImmutableLocked(ctx.allocator, store_path);
    restoreWriteBits(ctx.allocator, store_path);
    path_mod.deleteTreeAbsolute(store_path) catch |err| {
        return ctx.failFmt(switch (err) {
            error.AccessDenied => StoreError.PermissionDenied,
            else => StoreError.FileSystem,
        }, store_path, "failed to remove store object that failed verification: {s}", .{@errorName(err)});
    };
}

fn restoreWriteBits(allocator: std.mem.Allocator, store_path: []const u8) void {
    const io = path_mod.currentIo();
    var dir = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const top = dir.stat(io) catch return;
    dir.setPermissions(io, .fromMode(top.permissions.toMode() | 0o200)) catch {};

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                var subdir = dir.openDir(io, entry.path, .{ .iterate = true }) catch continue;
                defer subdir.close(io);
                const st = subdir.stat(io) catch continue;
                subdir.setPermissions(io, .fromMode(st.permissions.toMode() | 0o200)) catch {};
            },
            .file => {
                var file = dir.openFile(io, entry.path, .{}) catch continue;
                defer file.close(io);
                const st = file.stat(io) catch continue;
                file.setPermissions(io, .fromMode(st.permissions.toMode() | 0o200)) catch {};
            },
            else => {},
        }
    }
}
