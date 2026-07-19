const std = @import("std");
const archive = @import("archive.zig");
const Context = @import("mere.zig").Context;
const ui = @import("mere.zig").ui;
const path = @import("path.zig");
const repocache = @import("repocache.zig").RepoCache;
const package = @import("package.zig").Package;
const download = @import("download.zig");
const config_mod = @import("config.zig");
const namespace = @import("namespace.zig");
const repository = @import("repository.zig");
const sign = @import("sign.zig");
const manifest = @import("manifest.zig");
const hash = @import("hash.zig");
const projection_index = @import("projection_index.zig");
const store = @import("store.zig");
const Repository = repository.Repository;

pub const host_arch = @tagName(@import("builtin").cpu.arch);

fn makeWritable(dir_path: []const u8) void {
    const io = path.currentIo();
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(std.heap.page_allocator) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                // Must use iterate=true to get a real fd (not O_PATH) for fchmod
                var subdir = dir.openDir(io, entry.path, .{ .iterate = true }) catch continue;
                defer subdir.close(io);
                const stat = subdir.stat(io) catch continue;
                subdir.setPermissions(io, .fromMode(stat.permissions.toMode() | 0o200)) catch {};
            },
            .file => {
                var file = dir.openFile(io, entry.path, .{}) catch continue;
                defer file.close(io);
                const stat = file.stat(io) catch continue;
                file.setPermissions(io, .fromMode(stat.permissions.toMode() | 0o200)) catch {};
            },
            else => {},
        }
    }

    const stat = dir.stat(io) catch return;
    dir.setPermissions(io, .fromMode(stat.permissions.toMode() | 0o200)) catch {};
}

/// Simple test env struct that holds a temporary directory and its path
pub const TestEnv = struct {
    debug_allocator: std.heap.DebugAllocator(.{}),
    ctx: Context,
    path: []const u8,
    tmp: std.testing.TmpDir,

    pub fn cleanup(self: *TestEnv) void {
        const allocator = self.debug_allocator.allocator();
        // Ensure any diagnostic arena allocations are released before deinit
        self.ctx.resetDiagnostics();
        // Clear immutable flags before making writable (tests running as root
        // may have set chattr +i via store.harden)
        _ = store.clearImmutable(allocator, self.path);
        self.ctx.deinit();
        makeWritable(self.path);
        self.tmp.cleanup();
        allocator.free(self.path);
        // Check for leaks, but don't crash the test if there are any.
        _ = self.debug_allocator.deinit();
    }
};

/// Creates a temporary test env.
/// Returns a TestDir struct containing the directory and its absolute path.
/// The caller is responsible for calling cleanup() on the returned struct.
pub fn createTestEnv() !*TestEnv {
    // Allocate TestEnv on the heap using the global allocator
    const test_env = try std.testing.allocator.create(TestEnv);

    // Placement-initialize the debug allocator inside the TestEnv
    @field(test_env, "debug_allocator") = std.heap.DebugAllocator(.{}){ .backing_allocator = std.testing.allocator };
    const allocator = @field(test_env, "debug_allocator").allocator();

    // Create a temporary directory
    test_env.tmp = std.testing.tmpDir(.{});

    // Get the absolute path of the temporary directory
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir_path_len = try test_env.tmp.dir.realPath(path.currentIo(), &buf);
    const temp_dir_path_slice = buf[0..temp_dir_path_len];

    // Allocate memory for the path to ensure it remains valid
    test_env.path = try allocator.dupe(u8, temp_dir_path_slice);

    test_env.ctx = Context.init(allocator, test_env.path);

    // Ensure library helpers that derive HOME use the test tempdir instead of the real user HOME.
    test_env.ctx.home_dir = test_env.path;

    // Create default signing key in the test home so code that relies on the
    // default key path (~/.mere/keys/mere.key) will work in tests that do not
    // explicitly set ctx.signing_key_path.
    const key_dir = try std.fs.path.join(allocator, &.{ test_env.path, ".mere", "keys" });
    defer allocator.free(key_dir);
    try std.Io.Dir.cwd().createDirPath(path.currentIo(), key_dir);

    const r = try sign.generateAndSaveKeyPair(&test_env.ctx, key_dir);
    test_env.ctx.allocator.free(r.public_key_path);
    test_env.ctx.allocator.free(r.secret_key_path);

    return test_env;
}

/// Creates a package archive with a single file entry using archive.createPackageArchive.
/// This is the preferred way to create valid test package archives.
/// The ctx.allocator will be used for temporary allocations.
/// The output file will be written to output_path.
pub fn createTestTarFile(ctx: *Context, name: []const u8, output_path: []const u8) !void {
    // Create a temp staging directory
    const staging_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.home_dir.?, ".test_tar_staging" });
    defer ctx.allocator.free(staging_dir);
    try std.Io.Dir.cwd().createDirPath(path.currentIo(), staging_dir);
    defer std.Io.Dir.cwd().deleteTree(path.currentIo(), staging_dir) catch {};

    // Create the file with content
    const file_path = try std.fs.path.join(ctx.allocator, &.{ staging_dir, name });
    defer ctx.allocator.free(file_path);
    var f = try path.makePathAndOpenFile(file_path);
    try f.writeStreamingAll(path.currentIo(), "test content");
    f.close(path.currentIo());

    // Create a package archive using libarchive + zstd
    try archive.createPackageArchive(ctx, staging_dir, output_path);
}

/// Creates a tar archive with raw control over path names using std.tar.Writer.
/// Use this ONLY for security tests that need malicious paths (e.g., "../etc/passwd")
/// that libarchive would normalize or reject. For normal valid archives, use createTestTarFile().
///
/// The caller is responsible for freeing the returned memory using std.testing.allocator.free().
pub fn createMaliciousTarContents(name: []const u8) ![]const u8 {
    // Create a buffer to hold the tar file
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    // Create a tar writer using the writer function from std.tar
    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };

    // If the path contains directories, create them first
    if (std.fs.path.dirname(name)) |dir_name| {
        try tar_writer.writeDir(dir_name, .{});
    }

    // Write a file with the given name and empty content
    try tar_writer.writeFileBytes(name, "test content", .{});

    // Create a fixed-size array to hold the tar contents
    const tar_contents = try std.testing.allocator.alloc(u8, buffer.written().len);

    // Copy the buffer contents to the fixed-size array
    @memcpy(tar_contents, buffer.written());

    return tar_contents;
}

/// Dummy HTTP client for download tests
pub const DummyClient = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) DummyClient {
        return DummyClient{
            .allocator = allocator,
            .map = .{},
        };
    }

    pub fn set(self: *DummyClient, url: []const u8, body: []const u8) !void {
        // Free previous value if present to avoid leaks
        if (self.map.get(url)) |old_body| {
            if (old_body.len > 0) {
                self.allocator.free(old_body);
            }
        }
        const copy = try self.allocator.dupe(u8, body);
        try self.map.put(self.allocator, url, copy);
    }

    pub fn getBody(self: *DummyClient, url: []const u8) []const u8 {
        if (self.map.get(url)) |body| return body;
        return "";
    }

    pub fn deinit(self: *DummyClient) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.len > 0) {
                self.allocator.free(entry.value_ptr.*);
            }
        }
        // Do not free keys, as they are not heap-allocated (StringHashMapUnmanaged does not own key memory).
        self.map.deinit(self.allocator);
    }
};

pub fn dummy_download_file(
    ptr: *anyopaque,
    ctx: *Context,
    url: [:0]const u8,
    dest_path: []const u8,
    options: download.DownloadOptions,
    _: u64,
    _: ui.Subject,
) !u64 {
    const client = @as(*DummyClient, @ptrCast(@alignCast(ptr)));
    const clean_url = if (std.mem.indexOfScalar(u8, url, 0)) |idx| url[0..idx] else url;
    const body = blk: {
        const mapped = client.getBody(clean_url);
        if (mapped.len > 0 or !std.mem.startsWith(u8, clean_url, "file://")) break :blk mapped;

        const file_path = clean_url["file://".len..];
        const file = path.openExistingFile(file_path) catch return error.FileSystem;
        defer file.close(path.currentIo());
        const stat = file.stat(path.currentIo()) catch return error.FileSystem;
        const file_len: usize = @intCast(stat.size);
        const data = try client.allocator.alloc(u8, file_len);
        errdefer client.allocator.free(data);
        const bytes_read = file.readPositionalAll(path.currentIo(), data, 0) catch return error.FileSystem;
        break :blk data[0..bytes_read];
    };
    defer if (std.mem.startsWith(u8, clean_url, "file://") and client.getBody(clean_url).len == 0) client.allocator.free(body);

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_abs = path.resolveToAbsolutePath(dest_path, &dest_buf) catch |err| {
        return ctx.fail(err, dest_path, "failed to resolve destination path");
    };
    const temp_path = try std.fmt.allocPrint(ctx.allocator, "{s}.part", .{dest_abs});
    defer ctx.allocator.free(temp_path);

    const temp_exists = blk: {
        std.Io.Dir.accessAbsolute(path.currentIo(), temp_path, .{}) catch break :blk false;
        break :blk true;
    };

    var initial_size: u64 = 0;
    var can_resume = false;
    if (options.allow_resume and temp_exists) {
        const temp_file = std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{ .mode = .read_write }) catch {
            return ctx.fail(error.FileSystem, temp_path, "failed to open partial download file");
        };
        initial_size = temp_file.length(path.currentIo()) catch {
            temp_file.close(path.currentIo());
            return ctx.fail(error.FileSystem, temp_path, "failed to get partial download size");
        };
        temp_file.close(path.currentIo());
        can_resume = initial_size > 0;
    }

    const file = if (can_resume)
        std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{ .mode = .read_write }) catch {
            return ctx.fail(error.FileSystem, temp_path, "failed to open download file");
        }
    else
        std.Io.Dir.createFileAbsolute(path.currentIo(), temp_path, .{ .read = true, .truncate = true }) catch {
            return ctx.fail(error.FileSystem, temp_path, "failed to create download file");
        };
    defer file.close(path.currentIo());

    const body_to_write = blk: {
        if (!can_resume) break :blk body;
        if (initial_size >= body.len) break :blk body[0..0];
        break :blk body[@intCast(initial_size)..];
    };

    file.writePositionalAll(path.currentIo(), body_to_write, initial_size) catch {
        return ctx.fail(error.FileSystem, temp_path, "failed to write downloaded data");
    };

    const final_bytes_total = initial_size + body_to_write.len;

    if (options.expected_hash) |expected_hash| {
        const actual_hex = hash.calculateFileHash(ctx, temp_path) catch |err| {
            return ctx.fail(err, temp_path, "failed to hash downloaded file");
        };
        defer ctx.allocator.free(actual_hex);

        if (!std.mem.eql(u8, actual_hex, expected_hash)) {
            ctx.setDiagnosticContextFmt(
                clean_url,
                "blake3 mismatch; expected={s} actual={s}",
                .{ expected_hash, actual_hex },
            );
            return error.SignatureVerificationFailed;
        }
    }

    const dest_exists = blk: {
        std.Io.Dir.accessAbsolute(path.currentIo(), dest_abs, .{}) catch break :blk false;
        break :blk true;
    };
    if (!dest_exists) {
        std.Io.Dir.renameAbsolute(temp_path, dest_abs, path.currentIo()) catch {
            return ctx.fail(error.FileSystem, dest_abs, "failed to move download into destination");
        };
    } else if (options.force) {
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), dest_abs) catch {
            return ctx.fail(error.FileSystem, dest_abs, "failed to remove existing destination file");
        };
        std.Io.Dir.renameAbsolute(temp_path, dest_abs, path.currentIo()) catch {
            return ctx.fail(error.FileSystem, dest_abs, "failed to replace destination file");
        };
    }

    return final_bytes_total;
}

// MockSigner returns deterministic raw signature bytes (fixed-size) matching SignerFn.
// This returns a `[sign.c.crypto_sign_BYTES]u8` signature by value (no allocator ownership).
pub fn MockSigner(_: *Context, _: []const u8, _: []const u8) sign.SignError![sign.c.crypto_sign_BYTES]u8 {
    var sig: [sign.c.crypto_sign_BYTES]u8 = undefined;
    var i: usize = 0;
    while (i < sig.len) : (i += 1) {
        sig[i] = 0xAA;
    }
    return sig;
}

// MockPubWriter writes a deterministic 32-byte public key file to pub_path.
pub fn MockPubWriter(ctx: *Context, _: []const u8, pub_path: []const u8) sign.SignError!void {
    var pub_buf: [sign.c.crypto_sign_PUBLICKEYBYTES]u8 = undefined;
    var i: usize = 0;
    while (i < pub_buf.len) : (i += 1) {
        pub_buf[i] = 0x42;
    }
    _ = ctx;
    const pub_key = sign.PublicKey{ .key = pub_buf };
    return pub_key.saveToFile(pub_path);
}

/// Resolve the active current-state directory for a local repo root
/// (`.../mere/dev/repo/<name>/current`).
/// Caller owns the returned path.
/// Resolve the active repo DB path (`repo.db` at repo root) for a local repo.
/// Caller owns the returned path.
pub fn resolveActiveRepoDbPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    const db_path = try std.fs.path.join(allocator, &.{ repo_root, "repo.db" });
    std.Io.Dir.accessAbsolute(path.currentIo(), db_path, .{}) catch return error.FileNotFound;
    return db_path;
}

/// Helper for import tests: sets up package archive, keys, db, and imports it.
/// Returns paths for further assertions.
pub fn setupTestImport(
    ctx: *Context,
    pkg: *@import("package.zig").Package,
    test_env: anytype,
    archive_name: []const u8,
) !struct {
    db_path: []const u8,
    pkg_path: []const u8,
    secret_key_path: []const u8,
} {
    const import_mod = @import("import.zig");

    // Create a temp directory with the package contents to compute hash
    const content_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "pkg_content" });
    defer ctx.allocator.free(content_dir);
    try path.ensureDirExists(content_dir);

    // Create a dummy file in the content directory so we have content to hash
    const dummy_file_path = try std.fs.path.join(ctx.allocator, &.{ content_dir, "dummy.txt" });
    defer ctx.allocator.free(dummy_file_path);
    {
        var f = try path.makePathAndOpenFile(dummy_file_path);
        try f.writeStreamingAll(path.currentIo(), "test content");
        f.close(path.currentIo());
    }

    // Compute content hash for the package content
    const content_hash_hex = try hash.calculateStoreContentHash(ctx.allocator, content_dir, null);
    defer ctx.allocator.free(content_hash_hex);

    // Parse content hash hex to bytes
    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex) catch unreachable;

    // Create manifest.v1 binary data
    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = @intCast(std.Io.Clock.real.now(path.currentIo()).toSeconds()),
        .release = pkg.release orelse 1,
        .arch = pkg.arch orelse host_arch,
        .name = pkg.name orelse "testpkg",
        .version = pkg.version orelse "1.0.0",
        .content_hash = content_hash_bytes,
    };

    // Use the default key created by createTestEnv() at ~/.mere/keys/mere.key
    // This ensures loadAllKeys() will find the key when verifying
    const secret_key_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, ".mere", "keys", "mere.key" });
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    try manifest.writeManifest(ctx, content_dir, &pkg_manifest, &secret_key.key);

    var projection = try projection_index.deriveFromPayload(ctx.allocator, content_dir);
    defer projection.deinit();
    try projection_index.writeFile(ctx.allocator, content_dir, &projection);

    // Create package archive with manifest.v1, manifest.v1.sig, and content.
    const pkg_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, archive_name });
    errdefer ctx.allocator.free(pkg_path);
    try archive.createPackageArchive(ctx, content_dir, pkg_path);

    // Set signing key in context (enables bootstrap)
    ctx.signing_key_path = secret_key_path;

    const repo_name = "import";
    const single = [_][]const u8{pkg_path};
    try import_mod.packages(ctx, repo_name, single[0..], false);

    // Resolve the active current-state DB path.
    const repo_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", repo_name });
    defer ctx.allocator.free(repo_root);

    const db_path = try resolveActiveRepoDbPath(ctx.allocator, repo_root);

    return .{
        .db_path = db_path,
        .pkg_path = pkg_path,
        .secret_key_path = secret_key_path,
    };
}

/// Create valid manifest.v1 binary data for tests.
/// Caller owns returned memory.
pub fn createTestManifest(allocator: std.mem.Allocator, name: []const u8, version: []const u8, release: u32, arch: []const u8, content_hash_hex: []const u8) ![]u8 {
    var content_hash_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex);

    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = @intCast(std.Io.Clock.real.now(path.currentIo()).toSeconds()),
        .release = release,
        .arch = arch,
        .name = name,
        .version = version,
        .content_hash = content_hash_bytes,
    };

    return pkg_manifest.encode(allocator);
}

/// Create a test RepoConfig with empty trusted_fingerprints for testing.
/// This is used by tests that need a RepoConfig but don't care about fingerprint verification.
pub fn createTestRepoConfig(
    allocator: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
) !@import("config.zig").RepoConfig {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const url_copy = try allocator.dupe(u8, url);
    errdefer allocator.free(url_copy);

    return @import("config.zig").RepoConfig{
        .name = name_copy,
        .url = url_copy,
        .priority = 100,
        .trusted_fingerprints = .empty,
    };
}

test "createTestEnvironment creates a valid test environment" {
    // Create a test environment
    var test_env = try createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Verify that the path is not empty
    try std.testing.expect(test_env.path.len > 0);

    // Verify that we can create a file in the temporary directory
    const test_file = "test.txt";
    const test_content = "Hello, world!";

    // Create a file directly in the temporary directory
    const file = try test_env.tmp.dir.createFile(path.currentIo(), test_file, .{});
    try file.writeStreamingAll(path.currentIo(), test_content);
    file.close(path.currentIo());

    // Verify that the file exists and has the correct content
    const read_file = try test_env.tmp.dir.openFile(path.currentIo(), test_file, .{});
    defer read_file.close(path.currentIo());

    var buffer: [100]u8 = undefined;
    const bytes_read = try read_file.readPositionalAll(path.currentIo(), &buffer, 0);
    try std.testing.expectEqualStrings(test_content, buffer[0..bytes_read]);

    test_env.ctx.debug("test file created: {s}", .{test_file});
}

test "resolveActiveRepoDbPath follows flat layout" {
    var test_env = try createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const repo_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "dev", "repo", "fixture" });
    defer allocator.free(repo_root);
    try path.ensureDirExists(repo_root);

    const db_path = try std.fs.path.join(allocator, &.{ repo_root, "repo.db" });
    defer allocator.free(db_path);
    {
        var f = try path.makePathAndOpenFile(db_path);
        f.close(path.currentIo());
    }

    const resolved = try resolveActiveRepoDbPath(allocator, repo_root);
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings(db_path, resolved);
}

test "setupTestImport returns active current-state repo.db path" {
    var test_env = try createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;
    var pkg = package.init(&ctx);
    defer pkg.deinit();

    pkg.name = try ctx.allocator.dupe(u8, "helper-testpkg");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, host_arch);
    pkg.content_hash = try ctx.allocator.dupe(u8, "dummyhash");
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);

    const result = try setupTestImport(&ctx, &pkg, test_env, "helper-test-pkg.tar");
    defer ctx.allocator.free(result.db_path);
    defer ctx.allocator.free(result.pkg_path);
    defer ctx.allocator.free(result.secret_key_path);

    try std.testing.expect(std.mem.endsWith(u8, result.db_path, "/repo.db"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.db_path, 1, "/current/"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.db_path, 1, "import.db"));
    try std.Io.Dir.accessAbsolute(path.currentIo(), result.db_path, .{});
}

pub fn ensurePackageArchiveCached(
    cache: *repocache,
    pkg: *const package,
    client: ?download.TransferClient,
) ![]const u8 {
    const ctx = cache.ctx;
    const cache_path = try cache.archiveCachePath(pkg);
    defer ctx.allocator.free(cache_path);

    // Ensure cache directory exists
    const archive_dir = try cache.archiveCacheDir();
    defer ctx.allocator.free(archive_dir);
    try path.ensureDirExists(archive_dir);

    var need_download = false;
    std.Io.Dir.accessAbsolute(path.currentIo(), cache_path, .{}) catch {
        need_download = true;
    };

    if (need_download) {
        const downloaded_path = try cache.ensurePackageArchiveCached(pkg, client.?);
        ctx.allocator.free(downloaded_path);
    }

    const result = try ctx.allocator.dupe(u8, cache_path);
    errdefer ctx.allocator.free(result);
    return result;
}

fn rewriteNamespaceWorkPath(allocator: std.mem.Allocator, input: []const u8, workspace_root: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "/work", workspace_root);
}

pub fn hostNamespaceRunner(
    allocator: std.mem.Allocator,
    _: namespace.EnvMode,
    opts: namespace.EnvOptions,
) anyerror!u8 {
    const argv = opts.command orelse return namespace.EnvError.InvalidInput;
    const workspace_root = opts.workspace orelse return namespace.EnvError.WorkspaceNotFound;
    const requested_cwd = opts.cwd orelse "/work";

    var host_argv = try allocator.alloc([]const u8, argv.len);
    defer {
        for (host_argv) |arg| allocator.free(arg);
        allocator.free(host_argv);
    }
    for (argv, 0..) |arg, i| {
        host_argv[i] = try rewriteNamespaceWorkPath(allocator, arg, workspace_root);
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    if (opts.env) |envp| {
        for (envp) |entry| {
            const pair = std.mem.span(entry);
            const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const host_value = try rewriteNamespaceWorkPath(allocator, pair[eq_idx + 1 ..], workspace_root);
            defer allocator.free(host_value);
            try env_map.put(pair[0..eq_idx], host_value);
        }
    }

    const host_cwd = try rewriteNamespaceWorkPath(allocator, requested_cwd, workspace_root);
    defer allocator.free(host_cwd);

    const result = try std.process.run(allocator, path.currentIo(), .{
        .argv = host_argv,
        .cwd = .{ .path = host_cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (opts.output_handler) |handler| {
        if (result.stdout.len > 0) handler.handle(result.stdout, false);
        if (result.stderr.len > 0) handler.handle(result.stderr, true);
    }

    return switch (result.term) {
        .exited => |code| @intCast(code),
        else => 1,
    };
}

pub const TestRepoSetup = struct {
    ctx: *Context,
    repo_dir: []const u8,

    pub fn deinit(self: *TestRepoSetup) void {
        if (self.ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        self.ctx.configuration = null;
        if (self.ctx.signing_key_path) |key_path| {
            self.ctx.allocator.free(key_path);
            self.ctx.signing_key_path = null;
        }
        self.ctx.allocator.free(self.repo_dir);
    }
};

pub fn setupBusyboxRepo(test_env: *TestEnv) !TestRepoSetup {
    const ctx = &test_env.ctx;
    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);
    errdefer {
        if (ctx.configuration) |*cfg| {
            cfg.deinit();
        }
        ctx.configuration = null;
    }

    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "repo" });
    errdefer ctx.allocator.free(repo_dir);
    try path.ensureDirExists(repo_dir);

    const keypair = try sign.generateKeyPair();
    const key_path = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "repo.key" });
    defer ctx.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    const packages_dir = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "packages" });
    defer ctx.allocator.free(packages_dir);
    try path.ensureDirExists(packages_dir);

    var pkg = package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, "busybox");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, host_arch);

    const pkg_staging = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "busybox_staging" });
    defer ctx.allocator.free(pkg_staging);
    try path.ensureDirExists(pkg_staging);

    const bin_dir = try std.fs.path.join(ctx.allocator, &.{ pkg_staging, "bin" });
    defer ctx.allocator.free(bin_dir);
    try path.ensureDirExists(bin_dir);

    const sh_path = try std.fs.path.join(ctx.allocator, &.{ bin_dir, "sh" });
    defer ctx.allocator.free(sh_path);
    var sh_file = try path.makePathAndOpenFile(sh_path);
    try sh_file.writeStreamingAll(path.currentIo(), "#!/bin/sh\nexit 0\n");
    sh_file.close(path.currentIo());

    const content_hash_str = try hash.calculateStoreContentHash(ctx.allocator, pkg_staging, null);
    defer ctx.allocator.free(content_hash_str);

    const mere_dir = try std.fs.path.join(ctx.allocator, &.{ pkg_staging, manifest.META_DIR });
    defer ctx.allocator.free(mere_dir);
    try path.ensureDirExists(mere_dir);

    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_str) catch unreachable;
    pkg.content_hash = try ctx.allocator.dupe(u8, content_hash_str);

    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = host_arch,
        .name = "busybox",
        .version = "1.0.0",
        .content_hash = content_hash_bytes,
    };

    const secret_key = try sign.SecretKey.loadFromFile(key_path);
    try manifest.writeManifest(ctx, pkg_staging, &pkg_manifest, &secret_key.key);
    var projection = try projection_index.deriveFromPayload(ctx.allocator, pkg_staging);
    defer projection.deinit();
    try projection_index.writeFile(ctx.allocator, pkg_staging, &projection);

    const tmp_pkg_file = try std.fs.path.join(ctx.allocator, &.{ packages_dir, "busybox.tmp.pkg.tar.zst" });
    defer ctx.allocator.free(tmp_pkg_file);
    try archive.createPackageArchive(ctx, pkg_staging, tmp_pkg_file);

    pkg.archive_hash = try hash.calculateFileHash(ctx, tmp_pkg_file);
    const pkg_canon = try pkg.canonicalArchiveName();
    defer ctx.allocator.free(pkg_canon);
    const pkg_file = try std.fs.path.join(ctx.allocator, &.{ packages_dir, pkg_canon });
    defer ctx.allocator.free(pkg_file);
    try std.Io.Dir.renameAbsolute(tmp_pkg_file, pkg_file, path.currentIo());

    ctx.signing_key_path = try ctx.allocator.dupe(u8, key_path);
    const sig_bytes = try sign.signWithResolvedKey(ctx, pkg_file, null, null);
    var sig_buf = try ctx.allocator.alloc(u8, sign.c.crypto_sign_BYTES);
    std.mem.copyForwards(u8, sig_buf, sig_bytes[0..sign.c.crypto_sign_BYTES]);
    pkg.signature = sig_buf[0..sign.c.crypto_sign_BYTES];

    _ = try repo.db.insertPackageTransaction(&pkg, null);
    try repo.signDb();

    const fingerprint = try keypair.public_key.fingerprint(ctx.allocator);
    defer ctx.allocator.free(fingerprint);

    const user_keys_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, ".mere", "keys" });
    defer ctx.allocator.free(user_keys_dir);
    try path.ensureDirExists(user_keys_dir);
    const user_pub = try std.fs.path.join(ctx.allocator, &.{ user_keys_dir, "repo.pub" });
    defer ctx.allocator.free(user_pub);
    try keypair.public_key.saveToFile(user_pub);

    var fps: std.ArrayList([]const u8) = .empty;
    try fps.append(ctx.allocator, try ctx.allocator.dupe(u8, fingerprint));

    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}", .{repo_dir});
    defer ctx.allocator.free(repo_url);

    try ctx.configuration.?.repos.append(ctx.allocator, config_mod.RepoConfig{
        .name = try ctx.allocator.dupe(u8, "repo"),
        .url = try ctx.allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    return TestRepoSetup{ .ctx = ctx, .repo_dir = repo_dir };
}
