const std = @import("std");
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
const posix = std.posix;

const c = @cImport({
    @cInclude("sched.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("errno.h");
    @cInclude("string.h");
    @cInclude("stddef.h");
    @cInclude("stdlib.h");
    @cInclude("sys/sysmacros.h");
});

const MS_RDONLY: c_ulong = 1;
const MS_NOSUID: c_ulong = 2;
const MS_NODEV: c_ulong = 4;
const MS_NOEXEC: c_ulong = 8;
const MS_REMOUNT: c_ulong = 32;
const MS_BIND: c_ulong = 4096;
const MS_REC: c_ulong = 16384;
const MS_PRIVATE: c_ulong = 262144;

const DEV_NULL_MAJOR: u32 = 1;
const DEV_NULL_MINOR: u32 = 3;
const DEV_ZERO_MAJOR: u32 = 1;
const DEV_ZERO_MINOR: u32 = 5;
const DEV_RANDOM_MAJOR: u32 = 1;
const DEV_RANDOM_MINOR: u32 = 8;
const DEV_URANDOM_MAJOR: u32 = 1;
const DEV_URANDOM_MINOR: u32 = 9;
const DEV_TTY_MAJOR: u32 = 5;
const DEV_TTY_MINOR: u32 = 0;

fn buildEnvBasePath(allocator: std.mem.Allocator, xdg_runtime: ?[]const u8) ![]const u8 {
    if (xdg_runtime) |runtime| {
        return std.fs.path.join(allocator, &.{ runtime, "mere", "env" });
    }
    return allocator.dupe(u8, "/tmp/mere/env");
}

pub const EnvMode = enum {
    shell,
    build,
};

pub const EnvOptions = struct {
    profile_root: []const u8,
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    // Build namespaces run as real user by default; set true for recipes that require root-inside-namespace.
    needs_root: bool = false,
    no_etc_overlay: bool = false,
    env: ?[]const [*:0]const u8 = null,
    output_handler: ?OutputHandler = null,
    // The host path to the mere directory (contains store/, keys/, config.kdl).
    // Bind-mounted into the namespace so store symlinks resolve.
    // Defaults to "/mere"; set to "{root}/mere" when using --root.
    mere_root: []const u8 = "/mere",
};

pub const OutputHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, bytes: []const u8, is_stderr: bool) void,

    pub fn handle(self: OutputHandler, bytes: []const u8, is_stderr: bool) void {
        self.handleFn(self.ctx, bytes, is_stderr);
    }
};

pub fn cloneHostEnvWithVar(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) ![]const [*:0]const u8 {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const envp = std.c.environ;
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const kv = std.mem.span(entry);
        const sep = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try env_map.put(kv[0..sep], kv[sep + 1 ..]);
    }

    try env_map.put(key, value);

    const count = env_map.count();
    var result = try allocator.alloc([*:0]const u8, count);
    errdefer allocator.free(result);

    var result_index: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < result_index) : (j += 1) {
            const slice = std.mem.span(result[j]);
            allocator.free(result[j][0 .. slice.len + 1]);
        }
    }

    var it = env_map.iterator();
    while (it.next()) |entry| {
        const kv = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer allocator.free(kv);
        const kv_z = try allocator.dupeZ(u8, kv);
        result[result_index] = kv_z.ptr;
        result_index += 1;
    }

    return result;
}

pub fn freeOwnedEnv(allocator: std.mem.Allocator, envp: []const [*:0]const u8) void {
    for (envp) |ptr| {
        const slice = std.mem.span(ptr);
        allocator.free(ptr[0 .. slice.len + 1]);
    }
    allocator.free(envp);
}

const SessionInfo = struct {
    id: [32]u8,
    base_path: []const u8,
    root_path: []const u8,
    mode: EnvMode,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SessionInfo) void {
        self.allocator.free(self.base_path);
        self.allocator.free(self.root_path);
    }
};

const NamespaceIdentity = struct {
    uid: c_uint,
    gid: c_uint,
};

fn insideIdentity(mode: EnvMode, needs_root: bool, original_uid: c_uint, original_gid: c_uint) NamespaceIdentity {
    return if (mode == .build and needs_root)
        .{ .uid = 0, .gid = 0 }
    else
        .{ .uid = original_uid, .gid = original_gid };
}

const Std = errors.StandardErrors;
pub const EnvError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    UserNamespacesDisabled,
    OverlayFsUnavailable,
    ProfileNotFound,
    WorkspaceNotFound,
    SessionSetupError,
    SyntheticRootSetupError,
    DeviceSetupError,
    EtcSetupError,
    WorkingDirectoryUnavailable,
    UnshareError,
    MountPrivateError, // mount(MS_PRIVATE) failed
    MountRestricted, // mount syscall was denied by kernel/sandbox policy
    MountSourceMissing, // bind mount source path does not exist
    MountBindError, // bind mount failed
    MountTmpfsError, // tmpfs mount failed
    MountProcError, // proc mount failed
    MountOverlayError, // overlayfs mount failed
    ChrootError,
    SetuidError,
    ExecError,
    UidMapError,
    GidMapError,
    ForkError,
    MknodError,
};

pub fn enterEnv(allocator: std.mem.Allocator, mode: EnvMode, opts: EnvOptions) EnvError!void {
    try validateInputs(opts, mode);
    try checkCapabilities(mode, opts.no_etc_overlay);

    const original_uid = c.getuid();
    const original_gid = c.getgid();
    const identity = insideIdentity(mode, opts.needs_root, original_uid, original_gid);

    try createUserNamespace();
    try writeIdMappings(original_uid, original_gid, identity);
    try createMountNamespace();
    try createPidNamespace();
    try makeMountsPrivate();

    // A private procfs can only be mounted by a process that is itself inside
    // the new PID namespace, and unshare(CLONE_NEWPID) moves only *children*
    // into it - so everything from here runs in a forked child that is PID 1
    // there.
    //
    // The alternative, bind-mounting the host /proc, leaks the entire host
    // process table into the environment: measured on a developer machine, 246
    // host pids visible and 91 host command lines readable from inside a
    // `mere shell`. It is not a full chroot escape - the user namespace's
    // ptrace gate already blocks /proc/<pid>/root and /proc/<pid>/environ for
    // processes outside it - but a build or shell has no business enumerating
    // what else is running on the machine, and a procfs that reflects this PID
    // namespace is what "isolated build" is supposed to mean.
    const child_pid = try forkPidNamespaceInit();
    if (child_pid != 0) {
        // Not in the new PID namespace; the child is its init. Reap it and
        // mirror its status so callers still observe the command's result.
        std.process.exit(waitForExitStatus(child_pid));
    }

    var session = try createSession(allocator, mode);
    defer session.deinit();

    try buildSyntheticRoot(allocator, &session, opts.profile_root, opts.mere_root);

    switch (mode) {
        .shell => try applyShellMounts(allocator, &session, opts),
        .build => try applyBuildMounts(allocator, &session, opts),
    }

    try mountProc(allocator, session.root_path);
    try mountTmpfsInRoot(allocator, session.root_path, "tmp");
    try chrootAndChdir(session.root_path, opts.cwd);
    try dropPrivileges(identity.uid, identity.gid);
    try execCommand(allocator, opts.command, opts.env);
}

pub fn forkAndEnterEnv(allocator: std.mem.Allocator, mode: EnvMode, opts: EnvOptions) EnvError!u8 {
    var stdout_pipe: [2]posix.fd_t = undefined;
    if (c.pipe(&stdout_pipe) != 0) return EnvError.ForkError;
    errdefer {
        _ = c.close(stdout_pipe[0]);
        _ = c.close(stdout_pipe[1]);
    }
    var stderr_pipe: [2]posix.fd_t = undefined;
    if (c.pipe(&stderr_pipe) != 0) return EnvError.ForkError;
    errdefer {
        _ = c.close(stderr_pipe[0]);
        _ = c.close(stderr_pipe[1]);
    }

    const pid = c.fork();
    if (pid < 0) return EnvError.ForkError;

    if (pid == 0) {
        _ = c.close(stdout_pipe[0]);
        _ = c.close(stderr_pipe[0]);
        _ = c.dup2(stdout_pipe[1], c.STDOUT_FILENO);
        _ = c.dup2(stderr_pipe[1], c.STDERR_FILENO);
        _ = c.close(stdout_pipe[1]);
        _ = c.close(stderr_pipe[1]);

        enterEnv(allocator, mode, opts) catch {
            std.process.exit(1);
        };
        unreachable;
    }

    _ = c.close(stdout_pipe[1]);
    _ = c.close(stderr_pipe[1]);

    var poll_fds = [_]c.struct_pollfd{
        .{ .fd = stdout_pipe[0], .events = c.POLLIN | c.POLLHUP | c.POLLERR, .revents = 0 },
        .{ .fd = stderr_pipe[0], .events = c.POLLIN | c.POLLHUP | c.POLLERR, .revents = 0 },
    };
    var open_streams: usize = 2;
    var read_buf: [4096]u8 = undefined;

    while (open_streams > 0) {
        const poll_rc = c.poll(&poll_fds, poll_fds.len, -1);
        if (poll_rc <= 0) continue;

        var i: usize = 0;
        while (i < poll_fds.len) : (i += 1) {
            const pfd = &poll_fds[i];
            if (pfd.fd < 0) continue;
            if ((pfd.revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) == 0) continue;

            const n = c.read(pfd.fd, &read_buf, read_buf.len);
            if (n > 0) {
                const data = read_buf[0..@intCast(n)];
                const is_stderr = i == 1;
                if (opts.output_handler) |handler| {
                    handler.handle(data, is_stderr);
                } else {
                    if (is_stderr) {
                        std.Io.File.stderr().writeStreamingAll(path_mod.currentIo(), data) catch {};
                    } else {
                        std.Io.File.stdout().writeStreamingAll(path_mod.currentIo(), data) catch {};
                    }
                }
            } else {
                _ = c.close(pfd.fd);
                pfd.fd = -1;
                open_streams -= 1;
            }
        }
    }

    var wait_status: c_int = 0;
    if (c.waitpid(@intCast(pid), &wait_status, 0) < 0) return 128;
    // Decode the wait status: exit code is in bits 8-15 if exited normally
    const status: u32 = @bitCast(wait_status);
    if (status & 0x7f == 0) {
        // Normal exit: extract exit code from bits 8-15
        return @truncate(status >> 8);
    }
    // Killed by signal
    return 128;
}

fn validateInputs(opts: EnvOptions, mode: EnvMode) EnvError!void {
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), opts.profile_root, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => EnvError.ProfileNotFound,
            error.AccessDenied => EnvError.PermissionDenied,
            else => EnvError.FileSystem,
        };
    };

    if (opts.cwd) |cwd| {
        if (cwd.len == 0 or cwd[0] != '/') {
            return EnvError.InvalidInput;
        }
    }

    if (mode == .build) {
        if (opts.workspace) |ws| {
            std.Io.Dir.accessAbsolute(path_mod.currentIo(), ws, .{}) catch |err| {
                return switch (err) {
                    error.FileNotFound => EnvError.WorkspaceNotFound,
                    error.AccessDenied => EnvError.PermissionDenied,
                    else => EnvError.FileSystem,
                };
            };
        }
    }
}

fn checkCapabilities(mode: EnvMode, no_etc_overlay: bool) EnvError!void {
    const io = path_mod.currentIo();
    if (std.Io.Dir.openFileAbsolute(io, "/proc/sys/user/max_user_namespaces", .{})) |file| {
        defer file.close(io);
        var buf: [32]u8 = undefined;
        if (file.readPositionalAll(io, &buf, 0)) |bytes_read| {
            const content = std.mem.trim(u8, buf[0..bytes_read], " \n\t");
            if (std.mem.eql(u8, content, "0")) {
                return EnvError.UserNamespacesDisabled;
            }
        } else |_| {}
    } else |_| {}

    if (mode == .shell and !no_etc_overlay) {
        if (std.Io.Dir.openFileAbsolute(io, "/proc/filesystems", .{})) |file| {
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            if (file.readPositionalAll(io, &buf, 0)) |bytes_read| {
                if (std.mem.indexOf(u8, buf[0..bytes_read], "overlay") == null) {
                    return EnvError.OverlayFsUnavailable;
                }
            } else |_| {}
        } else |_| {}
    }
}

fn createUserNamespace() EnvError!void {
    const rc: c_int = c.unshare(c.CLONE_NEWUSER);
    if (rc != 0) {
        return EnvError.UnshareError;
    }
}

fn writeIdMappings(uid: c_uint, gid: c_uint, identity: NamespaceIdentity) EnvError!void {
    const io = path_mod.currentIo();
    // Disable setgroups before writing gid_map
    if (std.Io.Dir.openFileAbsolute(io, "/proc/self/setgroups", .{ .mode = .write_only })) |file| {
        defer file.close(io);
        file.writeStreamingAll(io, "deny") catch {};
    } else |_| {}

    {
        var buf: [64]u8 = undefined;
        const id_map = std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ identity.uid, uid }) catch {
            return EnvError.OutOfMemory;
        };

        var file = std.Io.Dir.openFileAbsolute(io, "/proc/self/uid_map", .{ .mode = .write_only }) catch {
            return EnvError.UidMapError;
        };
        defer file.close(io);
        file.writeStreamingAll(io, id_map) catch {
            return EnvError.UidMapError;
        };
    }

    {
        var buf: [64]u8 = undefined;
        const id_map = std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ identity.gid, gid }) catch {
            return EnvError.OutOfMemory;
        };

        var file = std.Io.Dir.openFileAbsolute(io, "/proc/self/gid_map", .{ .mode = .write_only }) catch {
            return EnvError.GidMapError;
        };
        defer file.close(io);
        file.writeStreamingAll(io, id_map) catch {
            return EnvError.GidMapError;
        };
    }
}

fn createMountNamespace() EnvError!void {
    const rc: c_int = c.unshare(c.CLONE_NEWNS);
    if (rc != 0) {
        return EnvError.UnshareError;
    }
}

fn createPidNamespace() EnvError!void {
    const rc: c_int = c.unshare(c.CLONE_NEWPID);
    if (rc != 0) {
        return EnvError.UnshareError;
    }
}

/// Fork so the child becomes PID 1 of the PID namespace created by
/// `createPidNamespace`. Returns 0 in the child and the child's pid in the
/// parent.
fn forkPidNamespaceInit() EnvError!c_int {
    const pid = c.fork();
    if (pid < 0) return EnvError.ForkError;
    return pid;
}

/// Wait for `pid` and translate its wait status into an exit code, retrying
/// across EINTR. Signal deaths are reported as 128.
fn waitForExitStatus(pid: c_int) u8 {
    var wait_status: c_int = 0;
    while (true) {
        if (c.waitpid(pid, &wait_status, 0) >= 0) break;
        if (std.c._errno().* == c.EINTR) continue;
        return 128;
    }
    return decodeWaitStatus(wait_status);
}

/// Translate a `waitpid` status into an exit code. The exit code lives in bits
/// 8-15 when the low 7 bits indicate a normal exit; a signal death reports 128.
fn decodeWaitStatus(wait_status: c_int) u8 {
    const status: u32 = @bitCast(wait_status);
    if (status & 0x7f == 0) return @truncate(status >> 8);
    return 128;
}

fn makeMountsPrivate() EnvError!void {
    const rc = c.mount(null, "/", null, MS_REC | MS_PRIVATE, null);
    if (rc != 0) {
        return EnvError.MountPrivateError;
    }
}

fn generateSessionId() [32]u8 {
    var bytes: [16]u8 = undefined;
    path_mod.currentIo().random(&bytes);

    var hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

fn createSessionAtBase(allocator: std.mem.Allocator, mode: EnvMode, env_base: []const u8) EnvError!SessionInfo {
    const io = path_mod.currentIo();
    const id = generateSessionId();

    const base_path = std.fmt.allocPrint(allocator, "{s}/{s}/", .{ env_base, id }) catch {
        return EnvError.OutOfMemory;
    };
    errdefer allocator.free(base_path);

    const root_path = std.fmt.allocPrint(allocator, "{s}root/", .{base_path}) catch {
        return EnvError.OutOfMemory;
    };
    errdefer allocator.free(root_path);

    const dirs_to_create = [_][]const u8{ base_path, root_path };

    for (dirs_to_create) |dir| {
        const clean_dir = if (dir.len > 0 and dir[dir.len - 1] == '/')
            dir[0 .. dir.len - 1]
        else
            dir;

        std.Io.Dir.cwd().createDirPath(io, clean_dir) catch {
            return EnvError.SessionSetupError;
        };
    }

    if (mode == .shell) {
        const etc_upper = std.fmt.allocPrint(allocator, "{s}etc-upper", .{base_path}) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(etc_upper);

        const etc_work = std.fmt.allocPrint(allocator, "{s}etc-work", .{base_path}) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(etc_work);

        std.Io.Dir.cwd().createDirPath(io, etc_upper) catch return EnvError.SessionSetupError;
        std.Io.Dir.cwd().createDirPath(io, etc_work) catch return EnvError.SessionSetupError;
    } else {
        const etc_gen = std.fmt.allocPrint(allocator, "{s}etc-gen", .{base_path}) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(etc_gen);

        std.Io.Dir.cwd().createDirPath(io, etc_gen) catch return EnvError.SessionSetupError;
    }

    return SessionInfo{
        .id = id,
        .base_path = base_path,
        .root_path = root_path,
        .mode = mode,
        .allocator = allocator,
    };
}

fn createSession(allocator: std.mem.Allocator, mode: EnvMode) EnvError!SessionInfo {
    if (c.getenv("XDG_RUNTIME_DIR")) |xdg_runtime| {
        const xdg_base = buildEnvBasePath(allocator, std.mem.span(xdg_runtime)) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(xdg_base);

        if (createSessionAtBase(allocator, mode, xdg_base)) |session| {
            return session;
        } else |err| switch (err) {
            EnvError.SessionSetupError => {},
            else => return err,
        }
    }

    const tmp_base = buildEnvBasePath(allocator, null) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(tmp_base);

    return createSessionAtBase(allocator, mode, tmp_base);
}

fn buildSyntheticRoot(allocator: std.mem.Allocator, session: *const SessionInfo, profile_root: []const u8, mere_root: []const u8) EnvError!void {
    const io = path_mod.currentIo();
    const root = if (session.root_path.len > 0 and session.root_path[session.root_path.len - 1] == '/')
        session.root_path[0 .. session.root_path.len - 1]
    else
        session.root_path;

    // Create base directories that aren't from the profile
    const base_dirs = [_][]const u8{ "etc", "home", "tmp", "dev", "proc", "run", "var", "mere" };

    for (base_dirs) |dir| {
        const full_path = std.fs.path.join(allocator, &.{ root, dir }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(full_path);

        std.Io.Dir.cwd().createDirPath(io, full_path) catch return EnvError.SyntheticRootSetupError;
    }

    if (session.mode == .build) {
        const work_path = std.fs.path.join(allocator, &.{ root, "work" }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(work_path);

        std.Io.Dir.cwd().createDirPath(io, work_path) catch return EnvError.SyntheticRootSetupError;
    }

    // Bind-mount profile directories (bin, sbin, lib, usr) if they exist in the profile
    // The profile is a "root-ish" view - it has bin/, sbin/, lib/, usr/ at its root
    // which correspond to /bin, /sbin, /lib, /usr in the real system
    const profile_dirs = [_][]const u8{ "bin", "sbin", "lib", "usr" };

    for (profile_dirs) |dir| {
        const source_path = std.fs.path.join(allocator, &.{ profile_root, dir }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(source_path);

        // Check if this directory exists in the profile
        std.Io.Dir.accessAbsolute(io, source_path, .{}) catch {
            // Directory doesn't exist in profile, skip it
            continue;
        };

        const target_path = std.fs.path.join(allocator, &.{ root, dir }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(target_path);

        // Create the mount point directory
        std.Io.Dir.cwd().createDirPath(io, target_path) catch return EnvError.SyntheticRootSetupError;

        // Bind-mount the profile directory (read-only for safety)
        try mountBind(source_path, target_path, true);
    }

    // Bind-mount the mere directory so store symlinks resolve.
    // Uses the actual mere root (respects --root flag) rather than hardcoded /mere.
    // This is read-write in shell mode so `mere install` etc. work from inside the shell.
    const mere_target = std.fs.path.join(allocator, &.{ root, "mere" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(mere_target);

    const read_only_mere = session.mode == .build;
    try mountBind(mere_root, mere_target, read_only_mere);
}

fn applyShellMounts(allocator: std.mem.Allocator, session: *const SessionInfo, opts: EnvOptions) EnvError!void {
    const root = if (session.root_path.len > 0 and session.root_path[session.root_path.len - 1] == '/')
        session.root_path[0 .. session.root_path.len - 1]
    else
        session.root_path;

    const bind_mounts = [_][2][]const u8{
        .{ "/home", "home" },
        .{ "/var", "var" },
        .{ "/run", "run" },
        .{ "/dev", "dev" },
    };

    for (bind_mounts) |mount_info| {
        const source = mount_info[0];
        const target_rel = mount_info[1];

        const target = std.fs.path.join(allocator, &.{ root, target_rel }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(target);

        try mountBind(source, target, false);
    }

    const etc_target = std.fs.path.join(allocator, &.{ root, "etc" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(etc_target);

    if (opts.no_etc_overlay) {
        try mountBind("/etc", etc_target, true);
    } else {
        const base = if (session.base_path.len > 0 and session.base_path[session.base_path.len - 1] == '/')
            session.base_path[0 .. session.base_path.len - 1]
        else
            session.base_path;

        const upperdir = std.fs.path.join(allocator, &.{ base, "etc-upper" }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(upperdir);

        const workdir = std.fs.path.join(allocator, &.{ base, "etc-work" }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(workdir);

        mountOverlay(etc_target, "/etc", upperdir, workdir) catch {
            try mountBind("/etc", etc_target, true);
        };
    }
}

fn applyBuildMounts(allocator: std.mem.Allocator, session: *const SessionInfo, opts: EnvOptions) EnvError!void {
    const root = if (session.root_path.len > 0 and session.root_path[session.root_path.len - 1] == '/')
        session.root_path[0 .. session.root_path.len - 1]
    else
        session.root_path;

    const base = if (session.base_path.len > 0 and session.base_path[session.base_path.len - 1] == '/')
        session.base_path[0 .. session.base_path.len - 1]
    else
        session.base_path;

    if (opts.workspace) |ws| {
        const work_target = std.fs.path.join(allocator, &.{ root, "work" }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(work_target);

        try mountBind(ws, work_target, false);
    }

    try mountTmpfsInRoot(allocator, root, "var");
    try mountTmpfsInRoot(allocator, root, "run");

    const etc_gen = std.fs.path.join(allocator, &.{ base, "etc-gen" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(etc_gen);

    try generateMinimalEtc(allocator, etc_gen);

    const etc_target = std.fs.path.join(allocator, &.{ root, "etc" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(etc_target);

    try mountBind(etc_gen, etc_target, false);

    const dev_target = std.fs.path.join(allocator, &.{ root, "dev" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(dev_target);

    try setupMinimalDev(allocator, dev_target);
}

fn mountBind(source: []const u8, target: []const u8, read_only: bool) EnvError!void {
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), source, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => EnvError.MountSourceMissing,
            error.AccessDenied => EnvError.PermissionDenied,
            else => EnvError.FileSystem,
        };
    };

    const src_c = toCString(source) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(src_c);

    const tgt_c = toCString(target) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(tgt_c);

    var rc = c.mount(src_c.ptr, tgt_c.ptr, null, MS_BIND | MS_REC, null);
    if (rc != 0) {
        switch (std.c._errno().*) {
            c.EPERM, c.EACCES => return EnvError.MountRestricted,
            c.ENOENT => return EnvError.MountSourceMissing,
            else => {},
        }
        return EnvError.MountBindError;
    }

    if (read_only) {
        rc = c.mount(null, tgt_c.ptr, null, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_REC, null);
        if (rc != 0) {
            switch (std.c._errno().*) {
                c.EPERM, c.EACCES => return EnvError.MountRestricted,
                else => {},
            }
            return EnvError.MountBindError;
        }
    }
}

fn mountTmpfs(target: []const u8, options: ?[]const u8) EnvError!void {
    const tgt_c = toCString(target) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(tgt_c);

    const fs_type = toCString("tmpfs") catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(fs_type);

    const opts_ptr: ?*const anyopaque = if (options) |o| blk: {
        const opts_c = toCString(o) catch return EnvError.OutOfMemory;
        break :blk @ptrCast(opts_c.ptr);
    } else null;
    defer if (options != null) {
        const ptr: [*]u8 = @ptrCast(@constCast(opts_ptr.?));
        std.heap.page_allocator.free(ptr[0 .. options.?.len + 1]);
    };

    const flags: c_ulong = MS_NODEV | MS_NOSUID;

    const rc = c.mount(null, tgt_c.ptr, fs_type.ptr, flags, opts_ptr);
    if (rc != 0) {
        return EnvError.MountTmpfsError;
    }
}

fn mountTmpfsInRoot(allocator: std.mem.Allocator, root: []const u8, subdir: []const u8) EnvError!void {
    const target = std.fs.path.join(allocator, &.{ root, subdir }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(target);

    try mountTmpfs(target, "size=1G");
}

fn mountOverlay(target: []const u8, lowerdir: []const u8, upperdir: []const u8, workdir: []const u8) EnvError!void {
    const tgt_c = toCString(target) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(tgt_c);

    const fs_type = toCString("overlay") catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(fs_type);

    var opts_buf: [1024]u8 = undefined;
    const opts = std.fmt.bufPrint(&opts_buf, "lowerdir={s},upperdir={s},workdir={s}", .{ lowerdir, upperdir, workdir }) catch {
        return EnvError.OutOfMemory;
    };

    const opts_c = toCString(opts) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(opts_c);

    const flags: c_ulong = 0;

    const rc = c.mount(null, tgt_c.ptr, fs_type.ptr, flags, @ptrCast(opts_c.ptr));
    if (rc != 0) {
        return EnvError.MountOverlayError;
    }
}

fn mountProc(allocator: std.mem.Allocator, root: []const u8) EnvError!void {
    const root_clean = if (root.len > 0 and root[root.len - 1] == '/')
        root[0 .. root.len - 1]
    else
        root;

    const target = std.fs.path.join(allocator, &.{ root_clean, "proc" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(target);

    const tgt_c = toCString(target) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(tgt_c);

    const fs_type = toCString("proc") catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(fs_type);

    // A procfs of our own, showing only the processes in this PID namespace.
    // This is deliberately not a bind mount of the host /proc, which would
    // expose the host process table and command lines to anything running in
    // the environment. Mounting proc is permitted here because we hold
    // CAP_SYS_ADMIN in the user namespace that owns this PID namespace, and
    // (thanks to the fork in enterEnv) we are inside that namespace.
    //
    // This fails closed on purpose: falling back to a host bind mount would
    // quietly reintroduce the leak it exists to prevent.
    const flags: c_ulong = MS_NOSUID | MS_NODEV | MS_NOEXEC;
    const rc = c.mount(fs_type.ptr, tgt_c.ptr, fs_type.ptr, flags, null);
    if (rc != 0) {
        switch (std.c._errno().*) {
            c.EPERM, c.EACCES => return EnvError.MountRestricted,
            else => {},
        }
        return EnvError.MountProcError;
    }
}

fn setupMinimalDev(allocator: std.mem.Allocator, dev_path: []const u8) EnvError!void {
    try mountTmpfs(dev_path, "size=64k,mode=755");

    const devices = [_]struct { name: []const u8, major: u32, minor: u32, mode: u16 }{
        .{ .name = "null", .major = DEV_NULL_MAJOR, .minor = DEV_NULL_MINOR, .mode = 0o666 },
        .{ .name = "zero", .major = DEV_ZERO_MAJOR, .minor = DEV_ZERO_MINOR, .mode = 0o666 },
        .{ .name = "random", .major = DEV_RANDOM_MAJOR, .minor = DEV_RANDOM_MINOR, .mode = 0o666 },
        .{ .name = "urandom", .major = DEV_URANDOM_MAJOR, .minor = DEV_URANDOM_MINOR, .mode = 0o666 },
        .{ .name = "tty", .major = DEV_TTY_MAJOR, .minor = DEV_TTY_MINOR, .mode = 0o666 },
    };

    for (devices) |dev| {
        const path = std.fs.path.join(allocator, &.{ dev_path, dev.name }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(path);

        const path_c = toCString(path) catch return EnvError.OutOfMemory;
        defer std.heap.page_allocator.free(path_c);

        const dev_num = c.makedev(dev.major, dev.minor);

        const rc = c.mknod(path_c.ptr, std.os.linux.S.IFCHR | dev.mode, dev_num);
        if (rc != 0 and std.c._errno().* != c.EEXIST) {
            try bindDeviceNode(path, dev.name);
        }
    }

    const io = path_mod.currentIo();
    var dev_dir = std.Io.Dir.openDirAbsolute(io, dev_path, .{}) catch {
        return EnvError.DeviceSetupError;
    };
    defer dev_dir.close(io);

    dev_dir.symLink(io, "/proc/self/fd", "fd", .{}) catch |err| {
        if (err != error.PathAlreadyExists) {
            return EnvError.DeviceSetupError;
        }
    };

    dev_dir.symLink(io, "/proc/self/fd/0", "stdin", .{}) catch {};
    dev_dir.symLink(io, "/proc/self/fd/1", "stdout", .{}) catch {};
    dev_dir.symLink(io, "/proc/self/fd/2", "stderr", .{}) catch {};

    // Mount /dev/shm for POSIX semaphores
    const shm_path = std.fs.path.join(allocator, &.{ dev_path, "shm" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(shm_path);
    std.Io.Dir.cwd().createDirPath(io, shm_path) catch return EnvError.DeviceSetupError;
    try mountTmpfs(shm_path, null);
}

fn bindDeviceNode(target: []const u8, name: []const u8) EnvError!void {
    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, target, .{}) catch {
        return EnvError.DeviceSetupError;
    };
    file.close(io);

    var host_path_buf: [256]u8 = undefined;
    const host_path = std.fmt.bufPrint(&host_path_buf, "/dev/{s}", .{name}) catch {
        return EnvError.OutOfMemory;
    };

    try mountBind(host_path, target, false);
}

fn generateMinimalEtc(allocator: std.mem.Allocator, etc_path: []const u8) EnvError!void {
    const io = path_mod.currentIo();
    std.Io.Dir.cwd().createDirPath(io, etc_path) catch return EnvError.EtcSetupError;

    const passwd_content = "root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n";
    try writeFile(allocator, etc_path, "passwd", passwd_content);

    const group_content = "root:x:0:\nnogroup:x:65534:\n";
    try writeFile(allocator, etc_path, "group", group_content);

    const hosts_content = "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n";
    try writeFile(allocator, etc_path, "hosts", hosts_content);

    if (readHostFile("/etc/resolv.conf", 4096)) |content| {
        defer std.heap.page_allocator.free(content);
        try writeFile(allocator, etc_path, "resolv.conf", content);
    }

    const ssl_certs_path = std.fs.path.join(allocator, &.{ etc_path, "ssl", "certs" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(ssl_certs_path);

    std.Io.Dir.cwd().createDirPath(io, ssl_certs_path) catch return EnvError.EtcSetupError;

    if (readHostFile("/etc/ssl/certs/ca-certificates.crt", 1024 * 1024)) |content| {
        defer std.heap.page_allocator.free(content);
        try writeFile(allocator, ssl_certs_path, "ca-certificates.crt", content);
    }
}

fn writeFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8, content: []const u8) EnvError!void {
    const io = path_mod.currentIo();
    const file_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(file_path);

    var file = std.Io.Dir.createFileAbsolute(io, file_path, .{}) catch {
        return EnvError.EtcSetupError;
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch {
        return EnvError.EtcSetupError;
    };
}

fn readHostFile(file_path: []const u8, max_size: usize) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(path_mod.currentIo(), file_path, std.heap.page_allocator, .limited(max_size)) catch null;
}

fn chrootAndChdir(root_path: []const u8, cwd: ?[]const u8) EnvError!void {
    const root = if (root_path.len > 0 and root_path[root_path.len - 1] == '/')
        root_path[0 .. root_path.len - 1]
    else
        root_path;

    const root_c = toCString(root) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(root_c);

    const rc_chroot = c.chroot(root_c.ptr);
    if (rc_chroot != 0) {
        return EnvError.ChrootError;
    }

    const target_cwd = cwd orelse "/";
    const cwd_c = toCString(target_cwd) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(cwd_c);

    const rc_chdir = c.chdir(cwd_c.ptr);
    if (rc_chdir != 0) {
        return if (cwd != null)
            EnvError.WorkingDirectoryUnavailable
        else
            EnvError.ChrootError;
    }
}

fn dropPrivileges(uid: c_uint, gid: c_uint) EnvError!void {
    const rc_gid = c.setresgid(gid, gid, gid);
    if (rc_gid != 0) {
        return EnvError.SetuidError;
    }

    const rc_uid = c.setresuid(uid, uid, uid);
    if (rc_uid != 0) {
        return EnvError.SetuidError;
    }
}

fn execCommand(allocator: std.mem.Allocator, command: ?[]const []const u8, env_opt: ?[]const [*:0]const u8) EnvError!void {
    // Always use /bin/sh -l as the default shell in namespace environments.
    // The host's $SHELL (e.g., /bin/bash) likely doesn't exist in the profile.
    // Use -l for login shell to source /etc/profile and ~/.profile.
    var owns_cmd = false;
    const cmd: []const []const u8 = if (command) |c_cmd|
        c_cmd
    else blk: {
        const default_shell = allocator.alloc([]const u8, 2) catch return EnvError.OutOfMemory;
        default_shell[0] = "/bin/sh";
        default_shell[1] = "-l";
        owns_cmd = true;
        break :blk default_shell;
    };
    errdefer if (owns_cmd) allocator.free(cmd);

    if (cmd.len == 0) {
        return EnvError.InvalidInput;
    }

    const argv = allocator.allocSentinel(?[*:0]const u8, cmd.len, null) catch {
        return EnvError.OutOfMemory;
    };
    errdefer allocator.free(argv);

    var allocated_argv: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < allocated_argv) : (i += 1) {
            if (argv[i]) |ptr| {
                const slice: [:0]const u8 = std.mem.span(ptr);
                allocator.free(@constCast(slice));
            }
        }
    }

    for (cmd, 0..) |arg, i| {
        argv[i] = (allocator.dupeZ(u8, arg) catch return EnvError.OutOfMemory).ptr;
        allocated_argv += 1;
    }

    var owned_envp: ?[:null]?[*:0]const u8 = null;
    defer if (owned_envp) |buf| allocator.free(buf);

    const envp: [*:null]const ?[*:0]const u8 = if (env_opt) |e| blk: {
        const buf = allocator.allocSentinel(?[*:0]const u8, e.len, null) catch return EnvError.OutOfMemory;
        for (e, 0..) |entry, i| buf[i] = entry;
        owned_envp = buf;
        break :blk buf.ptr;
    } else @ptrCast(std.c.environ);

    const exec_path = try resolveExecutablePath(allocator, cmd[0], env_opt);
    defer allocator.free(exec_path);

    const exec_path_z = allocator.dupeZ(u8, exec_path) catch return EnvError.OutOfMemory;
    defer allocator.free(exec_path_z);

    _ = c.execve(exec_path_z.ptr, @ptrCast(argv.ptr), @ptrCast(envp));
    // execve only returns on error; if we get here, exec failed
    for (argv[0..allocated_argv]) |arg| {
        if (arg) |ptr| {
            const slice: [:0]const u8 = std.mem.span(ptr);
            allocator.free(@constCast(slice));
        }
    }
    allocator.free(argv);
    if (owns_cmd) {
        allocator.free(cmd);
    }
    return EnvError.ExecError;
}

fn resolveExecutablePath(
    allocator: std.mem.Allocator,
    arg0: []const u8,
    env_opt: ?[]const [*:0]const u8,
) EnvError![]u8 {
    if (std.mem.indexOfScalar(u8, arg0, '/')) |_| {
        return allocator.dupe(u8, arg0) catch return EnvError.OutOfMemory;
    }

    const path_value = findEnvValue(env_opt, "PATH") orelse "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    var it = std.mem.tokenizeScalar(u8, path_value, ':');
    while (it.next()) |entry| {
        const candidate = if (entry.len == 0)
            std.fmt.allocPrint(allocator, "./{s}", .{arg0}) catch return EnvError.OutOfMemory
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry, arg0 }) catch return EnvError.OutOfMemory;
        errdefer allocator.free(candidate);

        std.Io.Dir.accessAbsolute(path_mod.currentIo(), candidate, .{}) catch {
            continue;
        };
        return candidate;
    }

    return EnvError.ExecError;
}

fn findEnvValue(env_opt: ?[]const [*:0]const u8, key: []const u8) ?[]const u8 {
    const envp = env_opt orelse return null;
    for (envp) |entry| {
        const kv = std.mem.span(entry);
        const sep = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..sep], key)) return kv[sep + 1 ..];
    }
    return null;
}

fn toCString(s: []const u8) error{OutOfMemory}![:0]u8 {
    var buf = std.heap.page_allocator.alloc(u8, s.len + 1) catch return error.OutOfMemory;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

test "toCString converts correctly" {
    const result = try toCString("hello");
    defer std.heap.page_allocator.free(result.ptr[0 .. result.len + 1]);

    try std.testing.expectEqualStrings("hello", result);
    try std.testing.expectEqual(@as(u8, 0), result.ptr[result.len]);
}

test "generateSessionId produces valid hex" {
    const id = generateSessionId();
    try std.testing.expectEqual(@as(usize, 32), id.len);

    for (id) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }

    const id2 = generateSessionId();
    try std.testing.expect(!std.mem.eql(u8, &id, &id2));
}

test "EnvOptions defaults" {
    const opts = EnvOptions{
        .profile_root = "/mere/profiles/system/current",
    };

    try std.testing.expect(opts.command == null);
    try std.testing.expect(opts.cwd == null);
    try std.testing.expect(opts.workspace == null);
    try std.testing.expect(opts.no_etc_overlay == false);
    try std.testing.expect(opts.env == null);
    try std.testing.expectEqualStrings("/mere", opts.mere_root);
}

test "EnvOptions mere_root can be overridden" {
    const opts = EnvOptions{
        .profile_root = "/custom/root/mere/profiles/shell-abc123/root",
        .mere_root = "/custom/root/mere",
    };

    try std.testing.expectEqualStrings("/custom/root/mere", opts.mere_root);
}

test "cloneHostEnvWithVar injects requested variable" {
    const allocator = std.testing.allocator;

    const envp = try cloneHostEnvWithVar(allocator, "MERE_PROFILE", "zig");
    defer freeOwnedEnv(allocator, envp);

    var found = false;
    for (envp) |entry| {
        const kv = std.mem.span(entry);
        if (std.mem.eql(u8, kv, "MERE_PROFILE=zig")) {
            found = true;
            break;
        }
    }

    try std.testing.expect(found);
}

test "SessionInfo deinit frees memory" {
    const allocator = std.testing.allocator;

    var session = SessionInfo{
        .id = generateSessionId(),
        .base_path = try allocator.dupe(u8, "/tmp/mere/env/test/"),
        .root_path = try allocator.dupe(u8, "/tmp/mere/env/test/root/"),
        .mode = .shell,
        .allocator = allocator,
    };

    session.deinit();
    // If deinit works correctly, there should be no memory leaks
    // The testing allocator will detect leaks if any occur
}

test "EnvMode enum values" {
    try std.testing.expectEqual(EnvMode.shell, EnvMode.shell);
    try std.testing.expectEqual(EnvMode.build, EnvMode.build);
    try std.testing.expect(EnvMode.shell != EnvMode.build);
}

test "insideIdentity preserves user identity for build mode by default" {
    const identity = insideIdentity(.build, false, 1000, 1000);
    try std.testing.expectEqual(@as(c_uint, 1000), identity.uid);
    try std.testing.expectEqual(@as(c_uint, 1000), identity.gid);
}

test "insideIdentity maps build mode to root when explicitly requested" {
    const identity = insideIdentity(.build, true, 1000, 1000);
    try std.testing.expectEqual(@as(c_uint, 0), identity.uid);
    try std.testing.expectEqual(@as(c_uint, 0), identity.gid);
}

test "insideIdentity preserves user identity for shell mode" {
    const identity = insideIdentity(.shell, true, 1001, 1002);
    try std.testing.expectEqual(@as(c_uint, 1001), identity.uid);
    try std.testing.expectEqual(@as(c_uint, 1002), identity.gid);
}

test "validateInputs returns ProfileNotFound for nonexistent profile" {
    const opts = EnvOptions{
        .profile_root = "/nonexistent/path/that/does/not/exist",
    };

    const result = validateInputs(opts, .shell);
    try std.testing.expectError(EnvError.ProfileNotFound, result);
}

test "validateInputs returns WorkspaceNotFound for build mode with nonexistent workspace" {
    // Create a temporary directory for profile_root
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf) catch unreachable;
    const tmp_path = path_buf[0..tmp_path_len];

    const opts = EnvOptions{
        .profile_root = tmp_path,
        .workspace = "/nonexistent/workspace/path",
    };

    const result = validateInputs(opts, .build);
    try std.testing.expectError(EnvError.WorkspaceNotFound, result);
}

test "validateInputs succeeds for valid shell mode options" {
    // Create a temporary directory for profile_root
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf) catch unreachable;
    const tmp_path = path_buf[0..tmp_path_len];

    const opts = EnvOptions{
        .profile_root = tmp_path,
    };

    // Should succeed
    try validateInputs(opts, .shell);
}

test "validateInputs succeeds for valid build mode options with workspace" {
    // Create temporary directories for profile_root and workspace
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf) catch unreachable;
    const tmp_path = path_buf[0..tmp_path_len];

    // Create workspace subdirectory
    try tmp_dir.dir.createDir(path_mod.currentIo(), "workspace", .default_dir);
    const workspace_path = std.fs.path.join(std.testing.allocator, &.{ tmp_path, "workspace" }) catch unreachable;
    defer std.testing.allocator.free(workspace_path);

    const opts = EnvOptions{
        .profile_root = tmp_path,
        .workspace = workspace_path,
    };

    // Should succeed
    try validateInputs(opts, .build);
}

test "validateInputs rejects relative cwd" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf) catch unreachable;
    const tmp_path = path_buf[0..tmp_path_len];

    const opts = EnvOptions{
        .profile_root = tmp_path,
        .cwd = "relative/path",
    };

    const result = validateInputs(opts, .shell);
    try std.testing.expectError(EnvError.InvalidInput, result);
}

test "validateInputs allows null workspace in build mode" {
    // Create a temporary directory for profile_root
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf) catch unreachable;
    const tmp_path = path_buf[0..tmp_path_len];

    const opts = EnvOptions{
        .profile_root = tmp_path,
        .workspace = null, // No workspace
    };

    // Should succeed - workspace is optional
    try validateInputs(opts, .build);
}

test "generateSessionId produces unique IDs" {
    var ids: [10][32]u8 = undefined;

    for (&ids) |*id| {
        id.* = generateSessionId();
    }

    // Verify all IDs are unique
    for (ids, 0..) |id1, i| {
        for (ids[i + 1 ..]) |id2| {
            try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
        }
    }
}

test "toCString handles empty string" {
    const result = try toCString("");
    defer std.heap.page_allocator.free(result.ptr[0 .. result.len + 1]);

    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expectEqual(@as(u8, 0), result.ptr[0]);
}

test "toCString handles string with special characters" {
    const input = "hello\nworld\ttab";
    const result = try toCString(input);
    defer std.heap.page_allocator.free(result.ptr[0 .. result.len + 1]);

    try std.testing.expectEqualStrings(input, result);
    try std.testing.expectEqual(@as(u8, 0), result.ptr[result.len]);
}

test "bindDeviceNode fails when bind mount fails" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    const target = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "dev-node" });
    defer std.testing.allocator.free(target);

    // Use a guaranteed-nonexistent host device path segment to force bind failure.
    try std.testing.expectError(EnvError.MountSourceMissing, bindDeviceNode(target, "__definitely_missing_device__"));
}

test "EnvError covers all error cases" {
    // Verify that we can create all error types
    const all_errors = [_]EnvError{
        EnvError.OutOfMemory,
        EnvError.FileSystem,
        EnvError.PermissionDenied,
        EnvError.UserNamespacesDisabled,
        EnvError.OverlayFsUnavailable,
        EnvError.ProfileNotFound,
        EnvError.WorkspaceNotFound,
        EnvError.SessionSetupError,
        EnvError.SyntheticRootSetupError,
        EnvError.DeviceSetupError,
        EnvError.EtcSetupError,
        EnvError.WorkingDirectoryUnavailable,
        EnvError.InvalidInput,
        EnvError.UnshareError,
        EnvError.MountPrivateError,
        EnvError.MountRestricted,
        EnvError.MountSourceMissing,
        EnvError.MountBindError,
        EnvError.MountTmpfsError,
        EnvError.MountProcError,
        EnvError.MountOverlayError,
        EnvError.ChrootError,
        EnvError.SetuidError,
        EnvError.ExecError,
        EnvError.UidMapError,
        EnvError.GidMapError,
        EnvError.ForkError,
        EnvError.MknodError,
    };

    // Just verify we can iterate through all error types
    try std.testing.expectEqual(@as(usize, 28), all_errors.len);
}

test "buildEnvBasePath uses explicit XDG runtime dir when provided" {
    const allocator = std.testing.allocator;

    const path = try buildEnvBasePath(allocator, "/tmp/xdg-runtime");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/xdg-runtime/mere/env", path);
}

test "buildEnvBasePath falls back to /tmp when XDG runtime dir is missing" {
    const allocator = std.testing.allocator;

    const path = try buildEnvBasePath(allocator, null);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/mere/env", path);
}

test "createSessionAtBase creates a session under the requested base" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(path_mod.currentIo(), &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];
    const base = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "mere", "env" });
    defer std.testing.allocator.free(base);

    var session = try createSessionAtBase(std.testing.allocator, .shell, base);
    defer session.deinit();

    try std.testing.expect(std.mem.startsWith(u8, session.base_path, base));
    try std.testing.expect(std.fs.path.isAbsolute(session.root_path));
}
