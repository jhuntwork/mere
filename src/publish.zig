//! Durable filesystem publication.
//!
//! Every helper here makes new state visible with a single rename (or, for
//! a new symlink, a single symlink(2) call), so readers observe either the
//! previous state or the complete new state. With `.durable`, the helpers
//! also order the fsync calls so the published state survives power loss:
//!
//!   1. write the content under a temporary name in the destination directory;
//!   2. fsync the file (or every file and directory in a staged tree);
//!   3. rename into place;
//!   4. fsync the containing directory.
//!
//! Error contract: `error.PublishedNotDurable` is the only error returned
//! after this call made new state visible. Every other error means this call
//! published nothing. Temporary entries are removed on a best-effort basis:
//! if removing one fails too, or the process terminates mid-publication, it
//! stays behind. Its name always contains `.mere-tmp-`, and it is never
//! visible under the final name.
//!
//! A no-replace publication that finds the destination present returns
//! `.exists`. It still fsyncs the directory under `.durable`, because the
//! existing entry may come from a process that stopped before its own fsync,
//! but nothing new became visible, so that fsync failing is an ordinary error.
//!
//! Platform assumptions (Linux only):
//!   - temporary files and symlinks share their destination directory;
//!     staged directories may have different parents on the same filesystem,
//!     where rename(2) is atomic;
//!   - fsync on a directory file descriptor persists that directory's
//!     entries (ext4, xfs and btrfs guarantee this). A new symlink is made
//!     durable through its parent's fsync alone; older btrfs kernels had bugs
//!     that could lose such a symlink's target;
//!   - `.no_replace` uses renameat2 RENAME_NOREPLACE and `.exchange` uses
//!     RENAME_EXCHANGE (Linux 3.15+). Where a filesystem rejects
//!     RENAME_NOREPLACE, files fall back to link(2), which refuses any existing
//!     entry. Directories fall back to checking that the destination is absent
//!     and then calling rename(2); a destination created between the check
//!     and the rename is replaced if it is an empty directory. RENAME_EXCHANGE
//!     has no fallback.
//!
//! The helpers never take the store lock. Callers publish from inside their
//! existing locked sections.
//!
//! See docs/design/durable-publication.md for the guarantee each caller
//! relies on.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const path_mod = @import("path.zig");
const fault_injection = @import("fault_injection.zig");

const Checkpoint = fault_injection.Checkpoint;

/// What a publication promises.
pub const Guarantee = enum {
    /// Readers see the old state or the complete new state. After power
    /// loss either state may be present, or the content may be incomplete.
    atomic,
    /// `atomic`, and once the call returns the new state survives power loss.
    durable,
};

/// Fault checkpoints fired immediately before and after the publishing
/// rename. Callers can pass their own pair so a restart test targets exactly
/// one publication; `fault_injection.hit` consumes a checkpoint once.
pub const Checkpoints = struct {
    before: Checkpoint,
    after: Checkpoint,

    pub const file: Checkpoints = .{
        .before = .publish_file_before_rename,
        .after = .publish_file_after_rename,
    };
    pub const directory: Checkpoints = .{
        .before = .publish_directory_before_rename,
        .after = .publish_directory_after_rename,
    };
    pub const symlink: Checkpoints = .{
        .before = .publish_symlink_before_rename,
        .after = .publish_symlink_after_rename,
    };
};

pub const Outcome = enum {
    /// This call made the new entry visible.
    published,
    /// A no-replace publication found an existing entry and left it alone.
    exists,
};

pub const Error = error{
    OutOfMemory,
    AccessDenied,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    FileNotFound,
    NotDir,
    IsDir,
    NameTooLong,
    InvalidInput,
    Unsupported,
    InjectedFailure,
    FileSystem,
    /// The new state is visible, but a later step (the directory fsync or an
    /// injected fault after the rename) failed, so it may not survive power
    /// loss. Callers must treat the publication as having happened.
    PublishedNotDurable,
};

const name_max = 255;
const temp_marker = ".mere-tmp-";
const temp_prefix_max = 200;
const temp_random_bytes = 8;

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

pub const FileOptions = struct {
    guarantee: Guarantee = .durable,
    /// When false, an existing destination is kept and `publish` returns
    /// `.exists`.
    replace: bool = true,
    /// Mode for the new file. Null means the default file mode for
    /// `beginFile`/`replaceFile` and the source file's mode for `copyFile`.
    /// The process umask applies.
    permissions: ?std.Io.File.Permissions = null,
    checkpoints: Checkpoints = .file,
};

/// A file being written under a temporary name in its destination directory.
/// Write to `file`, then call `publish`. Call `abort` (usually via `defer`)
/// to remove the temporary file on any path that does not publish; it is a
/// no-op after `publish`.
pub const StagedFile = struct {
    dir: std.Io.Dir,
    file: std.Io.File,
    options: FileOptions,
    name_buf: [name_max]u8 = undefined,
    name_len: usize = 0,
    temp_buf: [name_max]u8 = undefined,
    temp_len: usize = 0,
    state: enum { open, closed, finished } = .open,

    pub fn name(self: *const StagedFile) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn tempName(self: *const StagedFile) []const u8 {
        return self.temp_buf[0..self.temp_len];
    }

    /// Make the written content visible under its final name.
    pub fn publish(self: *StagedFile) Error!Outcome {
        std.debug.assert(self.state == .open);
        const io = path_mod.currentIo();

        if (self.options.guarantee == .durable) {
            syncFile(self.file) catch |err| {
                self.abort();
                return err;
            };
        }
        self.file.close(io);
        self.state = .closed;

        fault_injection.hit(self.options.checkpoints.before) catch {
            self.abort();
            return error.InjectedFailure;
        };

        var outcome: Outcome = .published;
        if (self.options.replace) {
            renameEntry(self.dir, self.tempName(), self.name(), .{}) catch |err| {
                self.abort();
                return err;
            };
            self.state = .finished;
        } else {
            outcome = linkFileNoReplace(self.dir, self.tempName(), self.name()) catch |err| {
                self.abort();
                return err;
            };
            // On success the rename consumed the temporary name, or the link
            // fallback left a second name that abort removes.
            self.abort();
        }

        return finishPublication(self.dir, outcome, self.options.checkpoints, self.options.guarantee);
    }

    /// Remove the temporary file. Safe to call more than once.
    pub fn abort(self: *StagedFile) void {
        const io = path_mod.currentIo();
        switch (self.state) {
            .finished => return,
            .open => self.file.close(io),
            .closed => {},
        }
        self.dir.deleteFile(io, self.tempName()) catch {};
        self.state = .finished;
    }
};

/// Create a temporary file in `dir` that `StagedFile.publish` will rename
/// to `name`. `name` must be a single path component.
pub fn beginFile(dir: std.Io.Dir, name: []const u8, options: FileOptions) Error!StagedFile {
    try validateName(name);
    var staged = StagedFile{
        .dir = dir,
        .file = undefined,
        .options = options,
    };
    @memcpy(staged.name_buf[0..name.len], name);
    staged.name_len = name.len;
    staged.temp_len = formatTempName(&staged.temp_buf, name).len;

    staged.file = dir.createFile(path_mod.currentIo(), staged.tempName(), .{
        .exclusive = true,
        .permissions = options.permissions orelse .default_file,
    }) catch |err| return mapError(err);
    return staged;
}

/// Publish `bytes` as `dir/name`.
pub fn replaceFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8, options: FileOptions) Error!Outcome {
    var staged = try beginFile(dir, name, options);
    defer staged.abort();
    staged.file.writeStreamingAll(path_mod.currentIo(), bytes) catch |err| return mapError(err);
    return staged.publish();
}

/// Publish a copy of the file at `source_path` (absolute) as `dir/name`.
/// The copy keeps the source's mode unless `options.permissions` is set.
pub fn copyFile(source_path: []const u8, dir: std.Io.Dir, name: []const u8, options: FileOptions) Error!Outcome {
    const io = path_mod.currentIo();
    const source = std.Io.Dir.openFileAbsolute(io, source_path, .{}) catch |err| return mapError(err);
    var reader: std.Io.File.Reader = .init(source, io, &.{});
    defer reader.file.close(io);

    var effective = options;
    if (effective.permissions == null) {
        const st = source.stat(io) catch |err| return mapError(err);
        reader.size = st.size;
        effective.permissions = st.permissions;
    }

    var staged = try beginFile(dir, name, effective);
    defer staged.abort();

    var buffer: [4096]u8 = undefined;
    var writer = staged.file.writer(io, &buffer);
    _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| return switch (err) {
        error.ReadFailed => mapError(reader.err orelse error.FileSystem),
        error.WriteFailed => mapError(writer.err orelse error.FileSystem),
    };
    writer.flush() catch |err| return mapError(writer.err orelse err);

    return staged.publish();
}

// ---------------------------------------------------------------------------
// Symlinks and pointers
// ---------------------------------------------------------------------------

pub const SymlinkOptions = struct {
    guarantee: Guarantee = .durable,
    checkpoints: Checkpoints = .symlink,
};

/// Point `dir/name` at `target`, replacing any existing entry of that name
/// in one rename. There is never a moment without `name`.
pub fn replaceSymlink(dir: std.Io.Dir, target: []const u8, name: []const u8, options: SymlinkOptions) Error!void {
    try validateName(name);
    const io = path_mod.currentIo();
    var temp_buf: [name_max]u8 = undefined;
    const temp = formatTempName(&temp_buf, name);

    dir.symLink(io, target, temp, .{}) catch |err| return mapError(err);

    fault_injection.hit(options.checkpoints.before) catch {
        dir.deleteFile(io, temp) catch {};
        return error.InjectedFailure;
    };
    renameEntry(dir, temp, name, .{}) catch |err| {
        dir.deleteFile(io, temp) catch {};
        return err;
    };
    _ = try finishPublication(dir, .published, options.checkpoints, options.guarantee);
}

/// Create `dir/name` -> `target` unless `name` already exists. symlink(2)
/// creates the entry atomically, so no temporary name is needed. The
/// checkpoints fire around the symlink call.
pub fn createSymlink(dir: std.Io.Dir, target: []const u8, name: []const u8, options: SymlinkOptions) Error!Outcome {
    try validateName(name);
    const io = path_mod.currentIo();

    fault_injection.hit(options.checkpoints.before) catch return error.InjectedFailure;
    var outcome: Outcome = .published;
    dir.symLink(io, target, name, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => outcome = .exists,
        else => return mapError(err),
    };
    return finishPublication(dir, outcome, options.checkpoints, options.guarantee);
}

// ---------------------------------------------------------------------------
// Directories
// ---------------------------------------------------------------------------

pub const DirectoryMode = enum {
    /// Publish only if `final` does not exist; otherwise return `.exists`
    /// and leave both trees untouched.
    no_replace,
    /// Atomically swap `staged` and `final`; both must exist. Afterwards the
    /// previous tree is at `staged` and the caller removes it.
    exchange,
};

pub const DirectoryOptions = struct {
    mode: DirectoryMode = .no_replace,
    guarantee: Guarantee = .durable,
    checkpoints: Checkpoints = .directory,
};

/// Publish the fully written tree at `staged_path` as `final_path`. Both
/// paths are absolute and on the same filesystem; they may have different
/// parent directories. Under `.durable` the destination parent is fsynced
/// after the rename, and so is the source parent when it differs, so the
/// staged name cannot reappear after power loss. The staged tree is never
/// removed by this function; on `.exists` or an error the caller still owns
/// it.
pub fn publishDirectory(
    allocator: std.mem.Allocator,
    staged_path: []const u8,
    final_path: []const u8,
    options: DirectoryOptions,
) Error!Outcome {
    if (!std.fs.path.isAbsolute(staged_path) or !std.fs.path.isAbsolute(final_path)) return error.InvalidInput;
    const staged_parent = std.fs.path.dirname(staged_path) orelse return error.InvalidInput;
    const final_parent = std.fs.path.dirname(final_path) orelse return error.InvalidInput;
    const same_parent = std.mem.eql(u8, staged_parent, final_parent);
    const staged_name = std.fs.path.basename(staged_path);
    const final_name = std.fs.path.basename(final_path);
    try validateName(staged_name);
    try validateName(final_name);

    if (options.guarantee == .durable) try syncTree(allocator, staged_path);

    const io = path_mod.currentIo();
    var source_dir = path_mod.openExistingDir(staged_parent) catch |err| return mapError(err);
    defer source_dir.close(io);
    var target_dir = if (same_parent)
        source_dir
    else
        path_mod.openExistingDir(final_parent) catch |err| return mapError(err);
    defer if (!same_parent) target_dir.close(io);

    fault_injection.hit(options.checkpoints.before) catch return error.InjectedFailure;

    var outcome: Outcome = .published;
    switch (options.mode) {
        .no_replace => {
            if (!try renameDirNoReplace(source_dir, staged_name, target_dir, final_name)) outcome = .exists;
        },
        .exchange => renameBetween(source_dir, staged_name, target_dir, final_name, .{ .EXCHANGE = true }) catch |err| {
            return if (err == error.InvalidInput) error.Unsupported else err;
        },
    }
    outcome = try finishPublication(target_dir, outcome, options.checkpoints, options.guarantee);
    if (outcome == .published and !same_parent and options.guarantee == .durable) {
        syncDir(source_dir) catch return error.PublishedNotDurable;
    }
    return outcome;
}

// ---------------------------------------------------------------------------
// Parent helper
// ---------------------------------------------------------------------------

/// An open parent directory and the final component of an absolute path,
/// for callers that hold absolute paths.
pub const Parent = struct {
    dir: std.Io.Dir,
    name: []const u8,

    pub fn close(self: *Parent) void {
        self.dir.close(path_mod.currentIo());
    }
};

pub fn openParent(absolute_path: []const u8) Error!Parent {
    if (!std.fs.path.isAbsolute(absolute_path)) return error.InvalidInput;
    const parent_path = std.fs.path.dirname(absolute_path) orelse return error.InvalidInput;
    const name = std.fs.path.basename(absolute_path);
    try validateName(name);
    const dir = path_mod.openExistingDir(parent_path) catch |err| return mapError(err);
    return .{ .dir = dir, .name = name };
}

// ---------------------------------------------------------------------------
// Sync primitives
// ---------------------------------------------------------------------------

/// fsync a directory so its entries survive power loss. Works on any open
/// directory handle, including O_PATH handles, by reopening "." for reading.
pub fn syncDir(dir: std.Io.Dir) Error!void {
    try checkInjectedSync(.directory);
    const io = path_mod.currentIo();
    // iterate = true is required: without it Zig opens the directory O_PATH,
    // and fsync() on an O_PATH fd fails with EBADF.
    var readable = dir.openDir(io, ".", .{ .iterate = true }) catch |err| return mapError(err);
    defer readable.close(io);
    try fsyncFd(readable.handle);
}

/// fsync every regular file in the tree at `dir_path` (absolute), then every
/// directory child-first. Symlinks are not followed.
pub fn syncTree(allocator: std.mem.Allocator, dir_path: []const u8) Error!void {
    try checkInjectedSync(.tree);
    _ = syncTreeWithOptions(allocator, dir_path, .{}) catch |err| return mapError(err);
}

fn syncFile(file: std.Io.File) Error!void {
    try checkInjectedSync(.file);
    try fsyncFd(file.handle);
}

fn fsyncFd(fd: std.posix.fd_t) Error!void {
    switch (linux.errno(linux.fsync(fd))) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
}

const SyncEntryFn = *const fn (?*anyopaque, std.Io.Dir, []const u8) anyerror!void;
const max_file_sync_workers: usize = 8;

const SyncTreeOptions = struct {
    max_file_workers: usize = max_file_sync_workers,
    sync_context: ?*anyopaque = null,
    sync_file_fn: SyncEntryFn = syncTreeFile,
    sync_directory_fn: SyncEntryFn = syncTreeDirectory,
};

const SyncTreeStats = struct {
    files_synchronized: usize,
    workers_started: usize,
};

fn syncTreeFile(_: ?*anyopaque, root: std.Io.Dir, rel_path: []const u8) !void {
    const io = path_mod.currentIo();
    var file = try root.openFile(io, rel_path, .{});
    defer file.close(io);
    try fsyncFd(file.handle);
}

fn syncTreeDirectory(_: ?*anyopaque, root: std.Io.Dir, rel_path: []const u8) !void {
    if (rel_path.len == 0) return fsyncFd(root.handle);

    const io = path_mod.currentIo();
    // iterate = true is required here: without it Zig opens the directory
    // O_PATH, and fsync() on an O_PATH fd fails with EBADF.
    var dir = try root.openDir(io, rel_path, .{ .iterate = true });
    defer dir.close(io);
    try fsyncFd(dir.handle);
}

const FileSyncShared = struct {
    root_path: []const u8,
    file_paths: []const []const u8,
    sync_context: ?*anyopaque,
    sync_file_fn: SyncEntryFn,
    mutex: std.Io.Mutex = .init,
    next_index: usize = 0,
    completed: usize = 0,
    first_error: ?anyerror = null,

    fn nextIndex(self: *@This()) ?usize {
        const io = path_mod.currentIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.first_error != null or self.next_index >= self.file_paths.len) return null;
        const index = self.next_index;
        self.next_index += 1;
        return index;
    }

    fn noteSuccess(self: *@This()) void {
        const io = path_mod.currentIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.completed += 1;
    }

    fn noteFailure(self: *@This(), err: anyerror) void {
        const io = path_mod.currentIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.first_error == null) self.first_error = err;
    }
};

const FileSyncWorker = struct {
    shared: *FileSyncShared,

    fn run(self: *@This()) void {
        const io = path_mod.currentIo();
        var root = std.Io.Dir.openDirAbsolute(io, self.shared.root_path, .{ .iterate = true }) catch |err| {
            self.shared.noteFailure(err);
            return;
        };
        defer root.close(io);

        while (self.shared.nextIndex()) |index| {
            self.shared.sync_file_fn(
                self.shared.sync_context,
                root,
                self.shared.file_paths[index],
            ) catch |err| {
                self.shared.noteFailure(err);
                return;
            };
            self.shared.noteSuccess();
        }
    }
};

// Recursively synchronize every file's data and metadata, then every
// directory's entries child-before-parent. The complete file barrier must
// succeed before directory synchronization begins, so callers cannot publish
// a partially synchronized staging tree via rename.
fn syncTreeWithOptions(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: SyncTreeOptions,
) !SyncTreeStats {
    const io = path_mod.currentIo();
    var root = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer root.close(io);

    var file_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_paths.items) |rel_path| allocator.free(rel_path);
        file_paths.deinit(allocator);
    }
    var directory_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (directory_paths.items) |rel_path| allocator.free(rel_path);
        directory_paths.deinit(allocator);
    }

    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .file => {
            const rel_path = try allocator.dupe(u8, entry.path);
            file_paths.append(allocator, rel_path) catch |err| {
                allocator.free(rel_path);
                return err;
            };
        },
        .directory => {
            const rel_path = try allocator.dupe(u8, entry.path);
            directory_paths.append(allocator, rel_path) catch |err| {
                allocator.free(rel_path);
                return err;
            };
        },
        else => {},
    };

    var stats = SyncTreeStats{
        .files_synchronized = 0,
        .workers_started = 0,
    };
    if (file_paths.items.len > 0) {
        const worker_limit = @max(@as(usize, 1), options.max_file_workers);
        const worker_count = @min(file_paths.items.len, worker_limit);
        var shared = FileSyncShared{
            .root_path = dir_path,
            .file_paths = file_paths.items,
            .sync_context = options.sync_context,
            .sync_file_fn = options.sync_file_fn,
        };
        var workers = try allocator.alloc(FileSyncWorker, worker_count);
        defer allocator.free(workers);
        var threads = try allocator.alloc(std.Thread, worker_count);
        defer allocator.free(threads);

        var spawned: usize = 0;
        while (spawned < worker_count) : (spawned += 1) {
            workers[spawned] = .{ .shared = &shared };
            threads[spawned] = std.Thread.spawn(.{}, FileSyncWorker.run, .{&workers[spawned]}) catch |err| {
                for (threads[0..spawned]) |thread| thread.join();
                return err;
            };
        }
        stats.workers_started = spawned;
        for (threads[0..spawned]) |thread| thread.join();
        stats.files_synchronized = shared.completed;
        if (shared.first_error) |err| return err;
    }

    std.mem.sort([]const u8, directory_paths.items, {}, struct {
        fn depth(rel_path: []const u8) usize {
            return std.mem.count(u8, rel_path, "/");
        }

        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const a_depth = depth(a);
            const b_depth = depth(b);
            if (a_depth != b_depth) return a_depth > b_depth;
            return std.mem.lessThan(u8, b, a);
        }
    }.lessThan);
    for (directory_paths.items) |rel_path| {
        try options.sync_directory_fn(options.sync_context, root, rel_path);
    }
    try options.sync_directory_fn(options.sync_context, root, "");

    return stats;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

const NameZ = struct {
    buf: [name_max + 1]u8,

    fn init(name: []const u8) NameZ {
        std.debug.assert(name.len <= name_max);
        var z: NameZ = undefined;
        @memcpy(z.buf[0..name.len], name);
        z.buf[name.len] = 0;
        return z;
    }

    fn ptr(self: *const NameZ) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }
};

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > name_max) return error.InvalidInput;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidInput;
    if (std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidInput;
}

/// `.<name prefix>.mere-tmp-<16 hex>`, at most 1 + 200 + 10 + 16 bytes.
fn formatTempName(buf: *[name_max]u8, name: []const u8) []const u8 {
    var random_bytes: [temp_random_bytes]u8 = undefined;
    path_mod.currentIo().random(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    const prefix = name[0..@min(name.len, temp_prefix_max)];
    return std.fmt.bufPrint(buf, ".{s}" ++ temp_marker ++ "{s}", .{ prefix, hex }) catch unreachable;
}

fn renameEntry(dir: std.Io.Dir, old_name: []const u8, new_name: []const u8, flags: linux.RENAME) Error!void {
    return renameBetween(dir, old_name, dir, new_name, flags);
}

fn renameBetween(old_dir: std.Io.Dir, old_name: []const u8, new_dir: std.Io.Dir, new_name: []const u8, flags: linux.RENAME) Error!void {
    const old_z = NameZ.init(old_name);
    const new_z = NameZ.init(new_name);
    switch (linux.errno(linux.renameat2(old_dir.handle, old_z.ptr(), new_dir.handle, new_z.ptr(), flags))) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
}

/// The steps after the publishing rename. `.published` fires the after
/// checkpoint and fsyncs the directory, and any failure there is
/// `PublishedNotDurable`. `.exists` means this call made nothing visible: the
/// after checkpoint does not fire, and the directory fsync, which covers an
/// existing entry whose publisher may have stopped before its own fsync,
/// fails with an ordinary error.
fn finishPublication(dir: std.Io.Dir, outcome: Outcome, checkpoints: Checkpoints, guarantee: Guarantee) Error!Outcome {
    switch (outcome) {
        .published => {
            fault_injection.hit(checkpoints.after) catch return error.PublishedNotDurable;
            if (guarantee == .durable) syncDir(dir) catch return error.PublishedNotDurable;
        },
        .exists => if (guarantee == .durable) try syncDir(dir),
    }
    return outcome;
}

fn renameNoReplaceErrno(old_dir: std.Io.Dir, old_z: *const NameZ, new_dir: std.Io.Dir, new_z: *const NameZ) linux.E {
    if (builtin.is_test and noreplace_unsupported_for_test) return .INVAL;
    return linux.errno(linux.renameat2(old_dir.handle, old_z.ptr(), new_dir.handle, new_z.ptr(), .{ .NOREPLACE = true }));
}

/// Publish `temp_name` as `new_name` unless `new_name` already exists.
fn linkFileNoReplace(dir: std.Io.Dir, temp_name: []const u8, new_name: []const u8) Error!Outcome {
    const temp_z = NameZ.init(temp_name);
    const new_z = NameZ.init(new_name);
    switch (renameNoReplaceErrno(dir, &temp_z, dir, &new_z)) {
        .SUCCESS => return .published,
        .EXIST => return .exists,
        // The filesystem does not support RENAME_NOREPLACE. link(2) also
        // refuses to replace and is supported for regular files everywhere
        // Mere runs; the caller removes the temporary name afterwards.
        .INVAL => {},
        else => |e| return errnoError(e),
    }
    switch (linux.errno(linux.linkat(dir.handle, temp_z.ptr(), dir.handle, new_z.ptr(), 0))) {
        .SUCCESS => return .published,
        .EXIST => return .exists,
        else => |e| return errnoError(e),
    }
}

/// Returns false when `new_name` already exists.
fn renameDirNoReplace(old_dir: std.Io.Dir, old_name: []const u8, new_dir: std.Io.Dir, new_name: []const u8) Error!bool {
    const old_z = NameZ.init(old_name);
    const new_z = NameZ.init(new_name);
    switch (renameNoReplaceErrno(old_dir, &old_z, new_dir, &new_z)) {
        .SUCCESS => return true,
        .EXIST, .NOTEMPTY => return false,
        .INVAL => {},
        else => |e| return errnoError(e),
    }
    // RENAME_NOREPLACE is unsupported here. A plain rename(2) replaces an
    // empty directory, so refuse any existing entry first. Only an entry
    // created between this check and the rename can still be replaced.
    if (new_dir.statFile(path_mod.currentIo(), new_name, .{ .follow_symlinks = false })) |_| {
        return false;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return mapError(err),
    }
    switch (linux.errno(linux.renameat2(old_dir.handle, old_z.ptr(), new_dir.handle, new_z.ptr(), .{}))) {
        .SUCCESS => return true,
        .EXIST, .NOTEMPTY => return false,
        else => |e| return errnoError(e),
    }
}

fn errnoError(e: linux.E) Error {
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NAMETOOLONG => error.NameTooLong,
        .INVAL => error.InvalidInput,
        .NOMEM => error.OutOfMemory,
        else => error.FileSystem,
    };
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpaceLeft,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        error.IsDir => error.IsDir,
        error.NameTooLong => error.NameTooLong,
        error.InvalidInput => error.InvalidInput,
        error.Unsupported => error.Unsupported,
        error.InjectedFailure => error.InjectedFailure,
        error.PublishedNotDurable => error.PublishedNotDurable,
        else => error.FileSystem,
    };
}

// Test-only injection of fsync failures, which fault checkpoints do not
// cover because they fire only around the rename.
const SyncTarget = enum { file, directory, tree };
var injected_sync_failure: ?SyncTarget = null;
var injected_sync_skip: usize = 0;

pub fn failNextDirectorySyncForTest() void {
    if (builtin.is_test) injected_sync_failure = .directory;
}

// Test-only: behave as if the filesystem rejects RENAME_NOREPLACE, so the
// link(2) and rename(2) fallbacks run on filesystems that support it.
var noreplace_unsupported_for_test = false;

fn checkInjectedSync(target: SyncTarget) Error!void {
    if (!builtin.is_test) return;
    if (injected_sync_failure == target) {
        if (injected_sync_skip > 0) {
            injected_sync_skip -= 1;
            return;
        }
        injected_sync_failure = null;
        return error.FileSystem;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testIo() std.Io {
    return path_mod.currentIo();
}

fn readTestFile(dir: std.Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(testIo(), name, testing.allocator, .limited(4096));
}

fn expectFileContent(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    const content = try readTestFile(dir, name);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

fn expectNoTempEntries(dir: std.Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(testIo())) |entry| {
        if (std.mem.indexOf(u8, entry.name, temp_marker) != null) {
            std.debug.print("unexpected temporary entry: {s}\n", .{entry.name});
            return error.TestUnexpectedResult;
        }
    }
}

fn expectLinkTarget(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.readLink(testIo(), name, &buf);
    try testing.expectEqualStrings(expected, buf[0..len]);
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testIo(), buf);
    return buf[0..len];
}

fn resetTestFaults() void {
    fault_injection.clearForTest();
    injected_sync_failure = null;
    injected_sync_skip = 0;
    noreplace_unsupported_for_test = false;
}

test "replaceFile creates and replaces a file without leaving temporary entries" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectEqual(Outcome.published, try replaceFile(tmp.dir, "data", "one", .{}));
    try expectFileContent(tmp.dir, "data", "one");
    try testing.expectEqual(Outcome.published, try replaceFile(tmp.dir, "data", "two", .{ .guarantee = .atomic }));
    try expectFileContent(tmp.dir, "data", "two");
    try expectNoTempEntries(tmp.dir);
}

test "replaceFile without replace keeps the existing file" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectEqual(Outcome.published, try replaceFile(tmp.dir, "data", "first", .{ .replace = false }));
    try testing.expectEqual(Outcome.exists, try replaceFile(tmp.dir, "data", "second", .{ .replace = false }));
    try expectFileContent(tmp.dir, "data", "first");
    try expectNoTempEntries(tmp.dir);
}

test "replaceFile applies requested permissions" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    _ = try replaceFile(tmp.dir, "secret", "x", .{ .permissions = std.Io.File.Permissions.fromMode(0o600) });
    const st = try tmp.dir.statFile(testIo(), "secret", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "file publication: fault before rename leaves the destination unchanged" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    _ = try replaceFile(tmp.dir, "data", "old", .{});
    fault_injection.setForTest(.publish_file_before_rename, .fail);
    try testing.expectError(error.InjectedFailure, replaceFile(tmp.dir, "data", "new", .{}));
    try expectFileContent(tmp.dir, "data", "old");
    try expectNoTempEntries(tmp.dir);
}

test "file publication: fault after rename reports a visible, non-durable publication" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    _ = try replaceFile(tmp.dir, "data", "old", .{});
    fault_injection.setForTest(.publish_file_after_rename, .fail);
    try testing.expectError(error.PublishedNotDurable, replaceFile(tmp.dir, "data", "new", .{}));
    try expectFileContent(tmp.dir, "data", "new");
    try expectNoTempEntries(tmp.dir);
}

test "file publication: file fsync failure publishes nothing" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    _ = try replaceFile(tmp.dir, "data", "old", .{});
    injected_sync_failure = .file;
    try testing.expectError(error.FileSystem, replaceFile(tmp.dir, "data", "new", .{}));
    try expectFileContent(tmp.dir, "data", "old");
    try expectNoTempEntries(tmp.dir);
}

test "file publication: directory fsync failure is reported after the rename" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    injected_sync_failure = .directory;
    try testing.expectError(error.PublishedNotDurable, replaceFile(tmp.dir, "data", "new", .{}));
    try expectFileContent(tmp.dir, "data", "new");
}

test "file publication: atomic guarantee skips fsync" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    injected_sync_failure = .file;
    _ = try replaceFile(tmp.dir, "data", "new", .{ .guarantee = .atomic });
    injected_sync_failure = .directory;
    _ = try replaceFile(tmp.dir, "data", "newer", .{ .guarantee = .atomic });
    try expectFileContent(tmp.dir, "data", "newer");
}

test "file publication: caller checkpoints replace the generic pair" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const custom: Checkpoints = .{ .before = .boot_before_staging, .after = .boot_after_staging };
    fault_injection.setForTest(.publish_file_before_rename, .fail);
    // The generic checkpoint is not consulted when the caller supplies its own.
    _ = try replaceFile(tmp.dir, "data", "one", .{ .checkpoints = custom });
    fault_injection.setForTest(.boot_before_staging, .fail);
    try testing.expectError(error.InjectedFailure, replaceFile(tmp.dir, "data", "two", .{ .checkpoints = custom }));
    try expectFileContent(tmp.dir, "data", "one");
}

test "beginFile abort removes the temporary file and is idempotent" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var staged = try beginFile(tmp.dir, "data", .{});
    try staged.file.writeStreamingAll(testIo(), "partial");
    staged.abort();
    staged.abort();
    try expectNoTempEntries(tmp.dir);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testIo(), "data", .{}));
}

test "beginFile rejects names that are not a single component" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ".", "..", "a/b" }) |bad| {
        try testing.expectError(error.InvalidInput, beginFile(tmp.dir, bad, .{}));
    }
}

test "temporary names stay within NAME_MAX for long destination names" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const long_name = "n" ** name_max;
    _ = try replaceFile(tmp.dir, long_name, "x", .{});
    try expectFileContent(tmp.dir, long_name, "x");
}

test "copyFile publishes a copy that keeps the source mode" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    {
        var source = try tmp.dir.createFile(testIo(), "source", .{ .permissions = .fromMode(0o640) });
        defer source.close(testIo());
        try source.writeStreamingAll(testIo(), "payload");
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    const source_path = try std.fs.path.join(testing.allocator, &.{ base, "source" });
    defer testing.allocator.free(source_path);

    try testing.expectEqual(Outcome.published, try copyFile(source_path, tmp.dir, "copy", .{}));
    try expectFileContent(tmp.dir, "copy", "payload");
    const st = try tmp.dir.statFile(testIo(), "copy", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o640), st.permissions.toMode() & 0o777);
    try testing.expectEqual(Outcome.exists, try copyFile(source_path, tmp.dir, "copy", .{ .replace = false }));
    try expectNoTempEntries(tmp.dir);
}

test "replaceSymlink creates and repoints a symlink" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try replaceSymlink(tmp.dir, "gen-1", "current", .{});
    try expectLinkTarget(tmp.dir, "current", "gen-1");
    try replaceSymlink(tmp.dir, "gen-2", "current", .{});
    try expectLinkTarget(tmp.dir, "current", "gen-2");
    try expectNoTempEntries(tmp.dir);
}

test "symlink publication: fault before rename keeps the old target" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try replaceSymlink(tmp.dir, "gen-1", "current", .{});
    fault_injection.setForTest(.publish_symlink_before_rename, .fail);
    try testing.expectError(error.InjectedFailure, replaceSymlink(tmp.dir, "gen-2", "current", .{}));
    try expectLinkTarget(tmp.dir, "current", "gen-1");
    try expectNoTempEntries(tmp.dir);
}

test "symlink publication: fault after rename reports the new target as visible" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try replaceSymlink(tmp.dir, "gen-1", "current", .{});
    fault_injection.setForTest(.publish_symlink_after_rename, .fail);
    try testing.expectError(error.PublishedNotDurable, replaceSymlink(tmp.dir, "gen-2", "current", .{}));
    try expectLinkTarget(tmp.dir, "current", "gen-2");
    try expectNoTempEntries(tmp.dir);
}

test "symlink publication: directory fsync failure is reported after the rename" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    injected_sync_failure = .directory;
    try testing.expectError(error.PublishedNotDurable, replaceSymlink(tmp.dir, "gen-1", "current", .{}));
    try expectLinkTarget(tmp.dir, "current", "gen-1");
}

test "createSymlink keeps an existing entry" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectEqual(Outcome.published, try createSymlink(tmp.dir, "/store/a", "pin", .{}));
    try testing.expectEqual(Outcome.exists, try createSymlink(tmp.dir, "/store/b", "pin", .{}));
    try expectLinkTarget(tmp.dir, "pin", "/store/a");

    fault_injection.setForTest(.publish_symlink_before_rename, .fail);
    try testing.expectError(error.InjectedFailure, createSymlink(tmp.dir, "/store/c", "other", .{}));
    var link_buf: [64]u8 = undefined;
    try testing.expectError(error.FileNotFound, tmp.dir.readLink(testIo(), "other", &link_buf));
}

fn makeStagedTree(base: []const u8, name: []const u8, marker: []const u8) ![]u8 {
    const staged = try std.fs.path.join(testing.allocator, &.{ base, name });
    errdefer testing.allocator.free(staged);
    const nested = try std.fs.path.join(testing.allocator, &.{ staged, "sub" });
    defer testing.allocator.free(nested);
    try path_mod.ensureDirExists(nested);
    var dir = try std.Io.Dir.openDirAbsolute(testIo(), nested, .{});
    defer dir.close(testIo());
    _ = try replaceFile(dir, "marker", marker, .{ .guarantee = .atomic });
    return staged;
}

fn expectTreeMarker(dir_path: []const u8, expected: []const u8) !void {
    const nested = try std.fs.path.join(testing.allocator, &.{ dir_path, "sub" });
    defer testing.allocator.free(nested);
    var dir = try std.Io.Dir.openDirAbsolute(testIo(), nested, .{});
    defer dir.close(testIo());
    try expectFileContent(dir, "marker", expected);
}

test "publishDirectory publishes a staged tree once" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const staged = try makeStagedTree(base, ".stage-1", "first");
    defer testing.allocator.free(staged);
    const final = try std.fs.path.join(testing.allocator, &.{ base, "final" });
    defer testing.allocator.free(final);

    try testing.expectEqual(Outcome.published, try publishDirectory(testing.allocator, staged, final, .{}));
    try expectTreeMarker(final, "first");

    const second = try makeStagedTree(base, ".stage-2", "second");
    defer testing.allocator.free(second);
    try testing.expectEqual(Outcome.exists, try publishDirectory(testing.allocator, second, final, .{}));
    try expectTreeMarker(final, "first");
    // The caller still owns the staged tree after `.exists`.
    try expectTreeMarker(second, "second");
}

test "publishDirectory exchange swaps the staged and live trees" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const live = try makeStagedTree(base, "root", "old");
    defer testing.allocator.free(live);
    const staged = try makeStagedTree(base, ".root-new", "new");
    defer testing.allocator.free(staged);

    try testing.expectEqual(Outcome.published, try publishDirectory(testing.allocator, staged, live, .{ .mode = .exchange }));
    try expectTreeMarker(live, "new");
    try expectTreeMarker(staged, "old");
}

test "directory publication: fault before rename publishes nothing" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const staged = try makeStagedTree(base, ".stage", "new");
    defer testing.allocator.free(staged);
    const final = try std.fs.path.join(testing.allocator, &.{ base, "final" });
    defer testing.allocator.free(final);

    fault_injection.setForTest(.publish_directory_before_rename, .fail);
    try testing.expectError(error.InjectedFailure, publishDirectory(testing.allocator, staged, final, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), final, .{}));
    try expectTreeMarker(staged, "new");
}

test "directory publication: fault after rename reports the tree as visible" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const staged = try makeStagedTree(base, ".stage", "new");
    defer testing.allocator.free(staged);
    const final = try std.fs.path.join(testing.allocator, &.{ base, "final" });
    defer testing.allocator.free(final);

    fault_injection.setForTest(.publish_directory_after_rename, .fail);
    try testing.expectError(error.PublishedNotDurable, publishDirectory(testing.allocator, staged, final, .{}));
    try expectTreeMarker(final, "new");
}

test "directory publication: tree fsync failure publishes nothing" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const staged = try makeStagedTree(base, ".stage", "new");
    defer testing.allocator.free(staged);
    const final = try std.fs.path.join(testing.allocator, &.{ base, "final" });
    defer testing.allocator.free(final);

    injected_sync_failure = .tree;
    try testing.expectError(error.FileSystem, publishDirectory(testing.allocator, staged, final, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), final, .{}));

    injected_sync_failure = .directory;
    try testing.expectError(error.PublishedNotDurable, publishDirectory(testing.allocator, staged, final, .{}));
    try expectTreeMarker(final, "new");
}

test "publishDirectory requires absolute paths" {
    try testing.expectError(error.InvalidInput, publishDirectory(testing.allocator, "rel/a", "rel/b", .{}));
    try testing.expectError(error.InvalidInput, publishDirectory(testing.allocator, "/x/a", "rel/b", .{}));
}

test "publishDirectory publishes across parent directories and syncs both" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const incoming = try std.fs.path.join(testing.allocator, &.{ base, ".incoming" });
    defer testing.allocator.free(incoming);
    try path_mod.ensureDirExists(incoming);
    const staged = try makeStagedTree(incoming, "abc123", "new");
    defer testing.allocator.free(staged);
    const final = try std.fs.path.join(testing.allocator, &.{ base, "object" });
    defer testing.allocator.free(final);

    try testing.expectEqual(Outcome.published, try publishDirectory(testing.allocator, staged, final, .{}));
    try expectTreeMarker(final, "new");
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), staged, .{}));

    // A failed parent fsync after a cross-directory rename is reported as a
    // visible, non-durable publication.
    const second = try makeStagedTree(incoming, "def456", "second");
    defer testing.allocator.free(second);
    const second_final = try std.fs.path.join(testing.allocator, &.{ base, "object-2" });
    defer testing.allocator.free(second_final);
    injected_sync_failure = .directory;
    try testing.expectError(error.PublishedNotDurable, publishDirectory(testing.allocator, second, second_final, .{}));
    try expectTreeMarker(second_final, "second");

    // Fail the source-parent syncDir specifically, after the destination
    // parent succeeds. Tree syncing uses its own direct fsync path.
    const source_fail = try makeStagedTree(incoming, "source-fail", "source-fail");
    defer testing.allocator.free(source_fail);
    const source_final = try std.fs.path.join(testing.allocator, &.{ base, "source-final" });
    defer testing.allocator.free(source_final);
    injected_sync_failure = .directory;
    injected_sync_skip = 1;
    try testing.expectError(error.PublishedNotDurable, publishDirectory(testing.allocator, source_fail, source_final, .{}));
    try expectTreeMarker(source_final, "source-fail");
    try testing.expectEqual(@as(?SyncTarget, null), injected_sync_failure);

    // An existing destination in another parent is left alone.
    const third = try makeStagedTree(incoming, "ghi789", "third");
    defer testing.allocator.free(third);
    try testing.expectEqual(Outcome.exists, try publishDirectory(testing.allocator, third, final, .{}));
    try expectTreeMarker(final, "new");
    try expectTreeMarker(third, "third");
}

test "openParent splits an absolute path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    const target = try std.fs.path.join(testing.allocator, &.{ base, "manifest" });
    defer testing.allocator.free(target);

    var parent = try openParent(target);
    defer parent.close();
    try testing.expectEqualStrings("manifest", parent.name);
    _ = try replaceFile(parent.dir, parent.name, "m", .{});
    try expectFileContent(tmp.dir, "manifest", "m");
    try testing.expectError(error.InvalidInput, openParent("relative/manifest"));
}

test "syncTree recursively syncs nested files and directories without following symlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    const allocator = testing.allocator;

    const root_dir = try std.fs.path.join(allocator, &.{ base, "fsync-tree-test" });
    defer allocator.free(root_dir);
    const nested_dir = try std.fs.path.join(allocator, &.{ root_dir, "sub", "nested" });
    defer allocator.free(nested_dir);
    try path_mod.ensureDirExists(nested_dir);

    const nested_file = try std.fs.path.join(allocator, &.{ nested_dir, "data.txt" });
    defer allocator.free(nested_file);
    {
        var f = try std.Io.Dir.createFileAbsolute(testIo(), nested_file, .{});
        try f.writeStreamingAll(testIo(), "hello");
        f.close(testIo());
    }

    // Dangling symlink: if syncTree opened walk entries without checking
    // .kind, following this would fail with FileNotFound.
    const sub_dir = try std.fs.path.join(allocator, &.{ root_dir, "sub" });
    defer allocator.free(sub_dir);
    const dangling_link = try std.fs.path.join(allocator, &.{ sub_dir, "dangling" });
    defer allocator.free(dangling_link);
    const dangling_target = try std.fs.path.join(allocator, &.{ root_dir, "does-not-exist" });
    defer allocator.free(dangling_target);
    try std.Io.Dir.symLinkAbsolute(testIo(), dangling_target, dangling_link, .{});

    try syncTree(allocator, root_dir);
}

test "syncTree bounds workers and synchronizes every regular file once" {
    const file_count = 20;
    const TestState = struct {
        mutex: std.Io.Mutex = .init,
        calls: [file_count]usize = @splat(0),

        fn syncFile(raw: ?*anyopaque, _: std.Io.Dir, rel_path: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const index = try std.fmt.parseInt(usize, rel_path["file-".len..], 10);
            const io = path_mod.currentIo();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.calls[index] += 1;
        }

        fn syncDirectory(_: ?*anyopaque, _: std.Io.Dir, _: []const u8) anyerror!void {}
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    const allocator = testing.allocator;

    const root_dir = try std.fs.path.join(allocator, &.{ base, "fsync-worker-bound" });
    defer allocator.free(root_dir);
    try path_mod.ensureDirExists(root_dir);

    for (0..file_count) |index| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/file-{d}", .{ root_dir, index });
        defer allocator.free(file_path);
        var file = try std.Io.Dir.createFileAbsolute(testIo(), file_path, .{});
        file.close(testIo());
    }
    const dangling_link = try std.fs.path.join(allocator, &.{ root_dir, "ignored-link" });
    defer allocator.free(dangling_link);
    const dangling_target = try std.fs.path.join(allocator, &.{ root_dir, "missing-target" });
    defer allocator.free(dangling_target);
    try std.Io.Dir.symLinkAbsolute(testIo(), dangling_target, dangling_link, .{});

    var state = TestState{};
    const stats = try syncTreeWithOptions(allocator, root_dir, .{
        .max_file_workers = 3,
        .sync_context = &state,
        .sync_file_fn = TestState.syncFile,
        .sync_directory_fn = TestState.syncDirectory,
    });

    try testing.expectEqual(@as(usize, 3), stats.workers_started);
    try testing.expectEqual(@as(usize, file_count), stats.files_synchronized);
    for (state.calls) |calls| try testing.expectEqual(@as(usize, 1), calls);
}

test "syncTree completes the file barrier before child-first directory sync" {
    const TestState = struct {
        mutex: std.Io.Mutex = .init,
        file_calls: usize = 0,
        directory_calls: usize = 0,
        directory_order: [3]u8 = undefined,
        fail_file_sync: bool = false,

        fn syncFile(raw: ?*anyopaque, _: std.Io.Dir, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const io = path_mod.currentIo();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.file_calls += 1;
            if (self.fail_file_sync) return error.InjectedSyncFailure;
        }

        fn syncDirectory(raw: ?*anyopaque, _: std.Io.Dir, rel_path: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.directory_order[self.directory_calls] = if (rel_path.len == 0)
                0
            else if (std.mem.eql(u8, rel_path, "sub"))
                1
            else if (std.mem.eql(u8, rel_path, "sub/nested"))
                2
            else
                return error.UnexpectedDirectory;
            self.directory_calls += 1;
        }
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    const allocator = testing.allocator;

    const root_dir = try std.fs.path.join(allocator, &.{ base, "fsync-barrier" });
    defer allocator.free(root_dir);
    const nested_dir = try std.fs.path.join(allocator, &.{ root_dir, "sub", "nested" });
    defer allocator.free(nested_dir);
    try path_mod.ensureDirExists(nested_dir);
    const file_path = try std.fs.path.join(allocator, &.{ nested_dir, "data" });
    defer allocator.free(file_path);
    var file = try std.Io.Dir.createFileAbsolute(testIo(), file_path, .{});
    file.close(testIo());

    var state = TestState{};
    _ = try syncTreeWithOptions(allocator, root_dir, .{
        .max_file_workers = 2,
        .sync_context = &state,
        .sync_file_fn = TestState.syncFile,
        .sync_directory_fn = TestState.syncDirectory,
    });
    try testing.expectEqual(@as(usize, 1), state.file_calls);
    try testing.expectEqual(@as(usize, 3), state.directory_calls);
    try testing.expectEqualSlices(u8, &.{ 2, 1, 0 }, &state.directory_order);

    state = TestState{ .fail_file_sync = true };
    try testing.expectError(error.InjectedSyncFailure, syncTreeWithOptions(allocator, root_dir, .{
        .max_file_workers = 2,
        .sync_context = &state,
        .sync_file_fn = TestState.syncFile,
        .sync_directory_fn = TestState.syncDirectory,
    }));
    try testing.expectEqual(@as(usize, 0), state.directory_calls);
}

test "syncTree fails for a nonexistent directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);
    const missing_dir = try std.fs.path.join(testing.allocator, &.{ base, "does-not-exist" });
    defer testing.allocator.free(missing_dir);

    try testing.expectError(error.FileNotFound, syncTree(testing.allocator, missing_dir));
}

test "no-replace .exists skips the after checkpoint and reports a failed fsync as an ordinary error" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    // File.
    _ = try replaceFile(tmp.dir, "data", "first", .{ .replace = false });
    fault_injection.setForTest(.publish_file_after_rename, .fail);
    try testing.expectEqual(Outcome.exists, try replaceFile(tmp.dir, "data", "second", .{ .replace = false }));
    // The checkpoint was not consumed by the call above.
    try testing.expectError(error.InjectedFailure, fault_injection.hit(.publish_file_after_rename));
    injected_sync_failure = .directory;
    try testing.expectError(error.FileSystem, replaceFile(tmp.dir, "data", "third", .{ .replace = false }));
    try expectFileContent(tmp.dir, "data", "first");

    // Symlink.
    _ = try createSymlink(tmp.dir, "/store/a", "pin", .{});
    fault_injection.setForTest(.publish_symlink_after_rename, .fail);
    try testing.expectEqual(Outcome.exists, try createSymlink(tmp.dir, "/store/b", "pin", .{}));
    try testing.expectError(error.InjectedFailure, fault_injection.hit(.publish_symlink_after_rename));
    injected_sync_failure = .directory;
    try testing.expectError(error.FileSystem, createSymlink(tmp.dir, "/store/b", "pin", .{}));
    try expectLinkTarget(tmp.dir, "pin", "/store/a");

    // Directory.
    const final = try makeStagedTree(base, "final", "first");
    defer testing.allocator.free(final);
    const staged = try makeStagedTree(base, ".stage", "second");
    defer testing.allocator.free(staged);
    fault_injection.setForTest(.publish_directory_after_rename, .fail);
    try testing.expectEqual(Outcome.exists, try publishDirectory(testing.allocator, staged, final, .{}));
    try testing.expectError(error.InjectedFailure, fault_injection.hit(.publish_directory_after_rename));
    injected_sync_failure = .directory;
    try testing.expectError(error.FileSystem, publishDirectory(testing.allocator, staged, final, .{}));
    try expectTreeMarker(final, "first");
    try expectNoTempEntries(tmp.dir);
}

test "createSymlink: faults and fsync failures after the symlink report it as visible" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    fault_injection.setForTest(.publish_symlink_after_rename, .fail);
    try testing.expectError(error.PublishedNotDurable, createSymlink(tmp.dir, "/store/a", "pin-a", .{}));
    try expectLinkTarget(tmp.dir, "pin-a", "/store/a");

    injected_sync_failure = .directory;
    try testing.expectError(error.PublishedNotDurable, createSymlink(tmp.dir, "/store/b", "pin-b", .{}));
    try expectLinkTarget(tmp.dir, "pin-b", "/store/b");
}

test "exchange publication: faults, sync failures and a missing target" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    const live = try makeStagedTree(base, "root", "old");
    defer testing.allocator.free(live);
    const staged = try makeStagedTree(base, ".root-new", "new");
    defer testing.allocator.free(staged);
    const exchange: DirectoryOptions = .{ .mode = .exchange };

    // Before the exchange: nothing changes.
    fault_injection.setForTest(.publish_directory_before_rename, .fail);
    try testing.expectError(error.InjectedFailure, publishDirectory(testing.allocator, staged, live, exchange));
    try expectTreeMarker(live, "old");
    try expectTreeMarker(staged, "new");

    // A failed tree sync: nothing changes.
    injected_sync_failure = .tree;
    try testing.expectError(error.FileSystem, publishDirectory(testing.allocator, staged, live, exchange));
    try expectTreeMarker(live, "old");

    // After the exchange: the new tree is live.
    fault_injection.setForTest(.publish_directory_after_rename, .fail);
    try testing.expectError(error.PublishedNotDurable, publishDirectory(testing.allocator, staged, live, exchange));
    try expectTreeMarker(live, "new");
    try expectTreeMarker(staged, "old");

    // A failed parent fsync after exchanging back: the exchange is visible.
    injected_sync_failure = .directory;
    try testing.expectError(error.PublishedNotDurable, publishDirectory(testing.allocator, staged, live, exchange));
    try expectTreeMarker(live, "old");
    try expectTreeMarker(staged, "new");

    // Exchange requires an existing target.
    const missing = try std.fs.path.join(testing.allocator, &.{ base, "missing" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, publishDirectory(testing.allocator, staged, missing, exchange));
    try expectTreeMarker(staged, "new");
}

test "file no-replace falls back to link(2) without RENAME_NOREPLACE" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    noreplace_unsupported_for_test = true;
    try testing.expectEqual(Outcome.published, try replaceFile(tmp.dir, "data", "first", .{ .replace = false }));
    try testing.expectEqual(Outcome.exists, try replaceFile(tmp.dir, "data", "second", .{ .replace = false }));
    try expectFileContent(tmp.dir, "data", "first");
    try expectNoTempEntries(tmp.dir);
}

test "directory no-replace fallback refuses any existing destination, including an empty one" {
    defer resetTestFaults();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmpPath(&tmp, &buf);

    noreplace_unsupported_for_test = true;
    const staged = try makeStagedTree(base, ".stage", "new");
    defer testing.allocator.free(staged);

    const empty = try std.fs.path.join(testing.allocator, &.{ base, "empty" });
    defer testing.allocator.free(empty);
    try path_mod.ensureDirExists(empty);
    try testing.expectEqual(Outcome.exists, try publishDirectory(testing.allocator, staged, empty, .{}));

    const full = try makeStagedTree(base, "full", "old");
    defer testing.allocator.free(full);
    try testing.expectEqual(Outcome.exists, try publishDirectory(testing.allocator, staged, full, .{}));
    try expectTreeMarker(full, "old");

    const final = try std.fs.path.join(testing.allocator, &.{ base, "final" });
    defer testing.allocator.free(final);
    try testing.expectEqual(Outcome.published, try publishDirectory(testing.allocator, staged, final, .{}));
    try expectTreeMarker(final, "new");
}
