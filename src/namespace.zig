const std = @import("std");
const errors = @import("errors.zig");
const builtin = @import("builtin");
const posix = std.posix;

const c = @cImport({
    @cInclude("sched.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
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

fn getEnvBasePath(allocator: std.mem.Allocator) ![]const u8 {
    return buildEnvBasePath(allocator, std.posix.getenv("XDG_RUNTIME_DIR"));
}

pub const EnvMode = enum {
    shell,
    build,
};

pub const EnvOptions = struct {
    profile_root: []const u8,
    command: ?[]const []const u8 = null,
    workspace: ?[]const u8 = null,
    // Build namespaces run as real user by default; set true for recipes that require root-inside-namespace.
    needs_root: bool = false,
    no_etc_overlay: bool = false,
    env: ?[]const [*:0]const u8 = null,
    output_handler: ?OutputHandler = null,
};

pub const OutputHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, bytes: []const u8, is_stderr: bool) void,

    pub fn handle(self: OutputHandler, bytes: []const u8, is_stderr: bool) void {
        self.handleFn(self.ctx, bytes, is_stderr);
    }
};

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
    UnshareError,
    MountPrivateError, // mount(MS_PRIVATE) failed
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
    try makeMountsPrivate();

    var session = try createSession(allocator, mode);
    defer session.deinit();

    try buildSyntheticRoot(allocator, &session, opts.profile_root);

    switch (mode) {
        .shell => try applyShellMounts(allocator, &session, opts),
        .build => try applyBuildMounts(allocator, &session, opts),
    }

    try mountProc(allocator, session.root_path);
    try mountTmpfsInRoot(allocator, session.root_path, "tmp");
    try chrootAndChdir(session.root_path);
    try dropPrivileges(identity.uid, identity.gid);
    try execCommand(allocator, opts.command, opts.env);
}

pub fn forkAndEnterEnv(allocator: std.mem.Allocator, mode: EnvMode, opts: EnvOptions) EnvError!u8 {
    const stdout_pipe = posix.pipe() catch return EnvError.ForkError;
    errdefer {
        posix.close(stdout_pipe[0]);
        posix.close(stdout_pipe[1]);
    }
    const stderr_pipe = posix.pipe() catch return EnvError.ForkError;
    errdefer {
        posix.close(stderr_pipe[0]);
        posix.close(stderr_pipe[1]);
    }

    const pid = posix.fork() catch return EnvError.ForkError;

    if (pid == 0) {
        posix.close(stdout_pipe[0]);
        posix.close(stderr_pipe[0]);
        _ = c.dup2(stdout_pipe[1], c.STDOUT_FILENO);
        _ = c.dup2(stderr_pipe[1], c.STDERR_FILENO);
        posix.close(stdout_pipe[1]);
        posix.close(stderr_pipe[1]);

        enterEnv(allocator, mode, opts) catch {
            std.process.exit(1);
        };
        unreachable;
    }

    posix.close(stdout_pipe[1]);
    posix.close(stderr_pipe[1]);

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
                        std.fs.File.stderr().writeAll(data) catch {};
                    } else {
                        std.fs.File.stdout().writeAll(data) catch {};
                    }
                }
            } else {
                posix.close(pfd.fd);
                pfd.fd = -1;
                open_streams -= 1;
            }
        }
    }

    const result = posix.waitpid(pid, 0);
    // Decode the wait status: exit code is in bits 8-15 if exited normally
    const status = result.status;
    if (status & 0x7f == 0) {
        // Normal exit: extract exit code from bits 8-15
        return @truncate(status >> 8);
    }
    // Killed by signal
    return 128;
}

fn validateInputs(opts: EnvOptions, mode: EnvMode) EnvError!void {
    std.fs.accessAbsolute(opts.profile_root, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => EnvError.ProfileNotFound,
            error.AccessDenied => EnvError.PermissionDenied,
            else => EnvError.FileSystem,
        };
    };

    if (mode == .build) {
        if (opts.workspace) |ws| {
            std.fs.accessAbsolute(ws, .{}) catch |err| {
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
    if (std.fs.openFileAbsolute("/proc/sys/user/max_user_namespaces", .{})) |file| {
        defer file.close();
        var buf: [32]u8 = undefined;
        if (file.readAll(&buf)) |bytes_read| {
            const content = std.mem.trim(u8, buf[0..bytes_read], " \n\t");
            if (std.mem.eql(u8, content, "0")) {
                return EnvError.UserNamespacesDisabled;
            }
        } else |_| {}
    } else |_| {}

    if (mode == .shell and !no_etc_overlay) {
        if (std.fs.openFileAbsolute("/proc/filesystems", .{})) |file| {
            defer file.close();
            var buf: [4096]u8 = undefined;
            if (file.readAll(&buf)) |bytes_read| {
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
    // Disable setgroups before writing gid_map
    if (std.fs.openFileAbsolute("/proc/self/setgroups", .{ .mode = .write_only })) |file| {
        defer file.close();
        file.writeAll("deny") catch {};
    } else |_| {}

    {
        var buf: [64]u8 = undefined;
        const id_map = std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ identity.uid, uid }) catch {
            return EnvError.OutOfMemory;
        };

        var file = std.fs.openFileAbsolute("/proc/self/uid_map", .{ .mode = .write_only }) catch {
            return EnvError.UidMapError;
        };
        defer file.close();
        file.writeAll(id_map) catch {
            return EnvError.UidMapError;
        };
    }

    {
        var buf: [64]u8 = undefined;
        const id_map = std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ identity.gid, gid }) catch {
            return EnvError.OutOfMemory;
        };

        var file = std.fs.openFileAbsolute("/proc/self/gid_map", .{ .mode = .write_only }) catch {
            return EnvError.GidMapError;
        };
        defer file.close();
        file.writeAll(id_map) catch {
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

fn makeMountsPrivate() EnvError!void {
    const rc = c.mount(null, "/", null, MS_REC | MS_PRIVATE, null);
    if (rc != 0) {
        return EnvError.MountPrivateError;
    }
}

fn generateSessionId() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    var hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

fn createSession(allocator: std.mem.Allocator, mode: EnvMode) EnvError!SessionInfo {
    const id = generateSessionId();

    const env_base = getEnvBasePath(allocator) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(env_base);

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

        std.fs.cwd().makePath(clean_dir) catch {
            return EnvError.FileSystem;
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

        std.fs.cwd().makePath(etc_upper) catch return EnvError.FileSystem;
        std.fs.cwd().makePath(etc_work) catch return EnvError.FileSystem;
    } else {
        const etc_gen = std.fmt.allocPrint(allocator, "{s}etc-gen", .{base_path}) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(etc_gen);

        std.fs.cwd().makePath(etc_gen) catch return EnvError.FileSystem;
    }

    return SessionInfo{
        .id = id,
        .base_path = base_path,
        .root_path = root_path,
        .mode = mode,
        .allocator = allocator,
    };
}

fn buildSyntheticRoot(allocator: std.mem.Allocator, session: *const SessionInfo, profile_root: []const u8) EnvError!void {
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

        std.fs.cwd().makePath(full_path) catch return EnvError.FileSystem;
    }

    if (session.mode == .build) {
        const work_path = std.fs.path.join(allocator, &.{ root, "work" }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(work_path);

        std.fs.cwd().makePath(work_path) catch return EnvError.FileSystem;
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
        std.fs.accessAbsolute(source_path, .{}) catch {
            // Directory doesn't exist in profile, skip it
            continue;
        };

        const target_path = std.fs.path.join(allocator, &.{ root, dir }) catch {
            return EnvError.OutOfMemory;
        };
        defer allocator.free(target_path);

        // Create the mount point directory
        std.fs.cwd().makePath(target_path) catch return EnvError.FileSystem;

        // Bind-mount the profile directory (read-only for safety)
        try mountBind(source_path, target_path, true);
    }

    // Bind-mount /mere so store symlinks resolve
    // This is read-write in shell mode so `mere install` etc. work from inside the shell
    const mere_target = std.fs.path.join(allocator, &.{ root, "mere" }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(mere_target);

    const read_only_mere = session.mode == .build;
    try mountBind("/mere", mere_target, read_only_mere);
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
    const src_c = toCString(source) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(src_c);

    const tgt_c = toCString(target) catch return EnvError.OutOfMemory;
    defer std.heap.page_allocator.free(tgt_c);

    var rc = c.mount(src_c.ptr, tgt_c.ptr, null, MS_BIND | MS_REC, null);
    if (rc != 0) {
        return EnvError.MountBindError;
    }

    if (read_only) {
        rc = c.mount(null, tgt_c.ptr, null, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_REC, null);
        if (rc != 0) {
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

    // Bind mount host /proc rather than mounting a new proc filesystem.
    // This works in user namespaces where mount -t proc is restricted.
    // Don't make it read-only - the remount can fail and /proc has its own protections.
    try mountBind("/proc", target, false);
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

    var dev_dir = std.fs.openDirAbsolute(dev_path, .{}) catch {
        return EnvError.FileSystem;
    };
    defer dev_dir.close();

    dev_dir.symLink("/proc/self/fd", "fd", .{}) catch |err| {
        if (err != error.PathAlreadyExists) {
            return EnvError.FileSystem;
        }
    };

    dev_dir.symLink("/proc/self/fd/0", "stdin", .{}) catch {};
    dev_dir.symLink("/proc/self/fd/1", "stdout", .{}) catch {};
    dev_dir.symLink("/proc/self/fd/2", "stderr", .{}) catch {};
}

fn bindDeviceNode(target: []const u8, name: []const u8) EnvError!void {
    var file = std.fs.createFileAbsolute(target, .{}) catch {
        return EnvError.FileSystem;
    };
    file.close();

    var host_path_buf: [256]u8 = undefined;
    const host_path = std.fmt.bufPrint(&host_path_buf, "/dev/{s}", .{name}) catch {
        return EnvError.OutOfMemory;
    };

    try mountBind(host_path, target, false);
}

fn generateMinimalEtc(allocator: std.mem.Allocator, etc_path: []const u8) EnvError!void {
    std.fs.cwd().makePath(etc_path) catch return EnvError.FileSystem;

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

    std.fs.cwd().makePath(ssl_certs_path) catch return EnvError.FileSystem;

    if (readHostFile("/etc/ssl/certs/ca-certificates.crt", 1024 * 1024)) |content| {
        defer std.heap.page_allocator.free(content);
        try writeFile(allocator, ssl_certs_path, "ca-certificates.crt", content);
    }
}

fn writeFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8, content: []const u8) EnvError!void {
    const path = std.fs.path.join(allocator, &.{ dir_path, name }) catch {
        return EnvError.OutOfMemory;
    };
    defer allocator.free(path);

    var file = std.fs.createFileAbsolute(path, .{}) catch {
        return EnvError.FileSystem;
    };
    defer file.close();

    file.writeAll(content) catch {
        return EnvError.FileSystem;
    };
}

fn readHostFile(path: []const u8, max_size: usize) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(std.heap.page_allocator, max_size) catch null;
}

fn chrootAndChdir(root_path: []const u8) EnvError!void {
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

    const rc_chdir = c.chdir("/");
    if (rc_chdir != 0) {
        return EnvError.ChrootError;
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

    const envp: [*:null]const ?[*:0]const u8 = if (env_opt) |e|
        @ptrCast(e.ptr)
    else
        @ptrCast(std.c.environ);

    std.posix.execvpeZ(argv[0].?, argv, envp) catch {};
    // execvpeZ only returns on error; if we get here, exec failed
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
    try std.testing.expect(opts.workspace == null);
    try std.testing.expect(opts.no_etc_overlay == false);
    try std.testing.expect(opts.env == null);
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
    const tmp_path = tmp_dir.dir.realpath(".", &path_buf) catch unreachable;

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
    const tmp_path = tmp_dir.dir.realpath(".", &path_buf) catch unreachable;

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
    const tmp_path = tmp_dir.dir.realpath(".", &path_buf) catch unreachable;

    // Create workspace subdirectory
    try tmp_dir.dir.makeDir("workspace");
    const workspace_path = std.fs.path.join(std.testing.allocator, &.{ tmp_path, "workspace" }) catch unreachable;
    defer std.testing.allocator.free(workspace_path);

    const opts = EnvOptions{
        .profile_root = tmp_path,
        .workspace = workspace_path,
    };

    // Should succeed
    try validateInputs(opts, .build);
}

test "validateInputs allows null workspace in build mode" {
    // Create a temporary directory for profile_root
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_dir.dir.realpath(".", &path_buf) catch unreachable;

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
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const target = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "dev-node" });
    defer std.testing.allocator.free(target);

    // Use a guaranteed-nonexistent host device path segment to force bind failure.
    try std.testing.expectError(EnvError.MountBindError, bindDeviceNode(target, "__definitely_missing_device__"));
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
        EnvError.InvalidInput,
        EnvError.UnshareError,
        EnvError.MountPrivateError,
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
    try std.testing.expectEqual(@as(usize, 21), all_errors.len);
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
