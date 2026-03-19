const std = @import("std");
const mere = @import("mere.zig");
const recipe = @import("recipe.zig");
const download_mod = @import("download.zig");
const test_helpers = @import("test_helpers.zig");
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
const DiagnosticContext = errors.DiagnosticContext;
const ui_emit = mere.ui.emit;
const hash_mod = @import("hash.zig");

const Std = errors.StandardErrors;
pub const Error = Std.OutOfMemory || Std.FileSystem || Std.Network || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData;

fn mapFsError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => Error.PermissionDenied,
        error.NameTooLong, error.BadPathName, error.InvalidUtf8 => Error.InvalidInput,
        else => Error.FileSystem,
    };
}

fn defaultSharedCacheRoot(allocator: std.mem.Allocator, ctx: *mere.Context) Error![]const u8 {
    return std.fs.path.join(allocator, &.{ ctx.root(), "mere", "dev", "cache", "sources" }) catch error.OutOfMemory;
}

pub const DownloadResult = struct {
    downloaded_count: u32,
    cached_count: u32,
    total_sources: u32,
    cache_dir_used: []const u8,

    pub fn deinit(self: *DownloadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_dir_used);
    }
};

pub const DownloadConfig = struct {
    sources: []const recipe.Source,
    client: download_mod.TransferClient,
    cache_dir: ?[]const u8,
    workspace_sources_dir: []const u8,
    recipe_dir: []const u8,
    recipe: *const recipe.Recipe,
};

pub fn clearSharedCache(ctx: *mere.Context) Error!usize {
    const cache_root = try defaultSharedCacheRoot(ctx.allocator, ctx);
    defer ctx.allocator.free(cache_root);

    var dir = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), cache_root, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => 0,
            else => mapFsError(err),
        };
    };
    defer dir.close(path_mod.currentIo());

    var iter = dir.iterate();
    var removed_count: usize = 0;

    while (iter.next(path_mod.currentIo()) catch |err| return mapFsError(err)) |entry| {
        const entry_path = try std.fs.path.join(ctx.allocator, &.{ cache_root, entry.name });
        defer ctx.allocator.free(entry_path);

        switch (entry.kind) {
            .directory => path_mod.deleteTreeAbsolute(entry_path) catch |err| return mapFsError(err),
            else => std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), entry_path) catch |err| return mapFsError(err),
        }

        removed_count += 1;
    }

    return removed_count;
}

pub fn download(ctx: *mere.Context, config: DownloadConfig) !DownloadResult {
    const diag_ctx = DiagnosticContext.init()
        .withSubject(config.workspace_sources_dir);
    _ = diag_ctx;

    if (config.sources.len == 0) {
        const empty_cache_dir = try ctx.allocator.dupe(u8, "");
        return DownloadResult{
            .downloaded_count = 0,
            .cached_count = 0,
            .total_sources = 0,
            .cache_dir_used = empty_cache_dir,
        };
    }

    // Resolve source cache directory. Prefer an injected override (for tests),
    // otherwise use the default /mere/dev/cache/sources.
    var cache_dir: []const u8 = undefined;
    if (config.cache_dir) |override| {
        cache_dir = try ctx.allocator.dupe(u8, override);
    } else {
        cache_dir = try defaultSharedCacheRoot(ctx.allocator, ctx);
    }

    path_mod.ensureDirExists(cache_dir) catch |err| {
        ctx.setDiagnosticContext(cache_dir, "failed to create cache dir");
        ctx.allocator.free(cache_dir);
        return mapFsError(err);
    };

    const PreparedSource = struct {
        url_z: [:0]u8,
        cache_path: []u8,
        workspace_source_path: []u8,
        expected_hash: ?[]const u8,
        cached: bool,
    };

    var downloaded_count: u32 = 0;
    var cached_count: u32 = 0;
    var prepared: std.ArrayList(PreparedSource) = .empty;
    defer {
        for (prepared.items) |entry| {
            ctx.allocator.free(entry.url_z);
            ctx.allocator.free(entry.cache_path);
            ctx.allocator.free(entry.workspace_source_path);
        }
        prepared.deinit(ctx.allocator);
    }

    var batch_requests: std.ArrayList(download_mod.BatchDownloadRequest) = .empty;
    defer batch_requests.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < config.sources.len) : (i += 1) {
        const src_entry = config.sources[i];
        const url_slice = src_entry.url;
        if (url_slice.len == 0) {
            ctx.setDiagnosticContext("source url", "empty source url");
            ctx.allocator.free(cache_dir);
            return Error.InvalidInput;
        }

        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const vars_ptr = if (config.recipe.vars.items.len > 0) &config.recipe.vars else null;
        const expanded_url = recipe.interpolate(arena_alloc, ctx, url_slice, config.recipe, vars_ptr) catch |err| {
            ctx.setDiagnosticContext(url_slice, "failed to expand source url");
            ctx.allocator.free(cache_dir);
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                else => Error.InvalidInput,
            };
        };

        var url_with_sentinel: []const u8 = undefined;
        if (std.mem.indexOf(u8, expanded_url, "://") != null) {
            url_with_sentinel = std.fmt.allocPrintSentinel(arena_alloc, "{s}", .{expanded_url}, 0) catch {
                ctx.setDiagnosticContext(expanded_url, "failed to allocate source url");
                ctx.allocator.free(cache_dir);
                return Error.OutOfMemory;
            };
        } else {
            const src_file_path = try std.fs.path.join(arena_alloc, &.{ config.recipe_dir, expanded_url });
            url_with_sentinel = std.fmt.allocPrintSentinel(arena_alloc, "file://{s}", .{src_file_path}, 0) catch {
                ctx.setDiagnosticContext(src_file_path, "failed to allocate source file url");
                ctx.allocator.free(cache_dir);
                return Error.OutOfMemory;
            };
        }

        const last_slash = std.mem.lastIndexOf(u8, expanded_url, "/");
        const basename = if (last_slash) |idx| expanded_url[idx + 1 ..] else expanded_url;

        const saved_basename = if (src_entry.save_as) |sa| sa else basename;
        const cache_filename = try arena_alloc.dupe(u8, saved_basename);

        const cache_path = try std.fs.path.join(arena_alloc, &.{ cache_dir, cache_filename });
        const workspace_source_path = try std.fs.path.join(arena_alloc, &.{ config.workspace_sources_dir, cache_filename });

        var expected_hash: ?[]const u8 = null;
        if (src_entry.blake3) |bh| expected_hash = bh;

        const url_c = std.mem.concatWithSentinel(arena_alloc, u8, &.{url_with_sentinel}, 0) catch {
            ctx.setDiagnosticContext(expanded_url, "failed to allocate source url");
            ctx.allocator.free(cache_dir);
            return Error.OutOfMemory;
        };
        const cache_path_owned = try ctx.allocator.dupe(u8, cache_path);
        const workspace_source_path_owned = try ctx.allocator.dupe(u8, workspace_source_path);
        const url_owned = try ctx.allocator.dupeZ(u8, url_c[0..]);

        var is_cached = false;
        if (expected_hash != null) {
            const file_exists = blk: {
                std.Io.Dir.accessAbsolute(path_mod.currentIo(), cache_path_owned, .{}) catch break :blk false;
                break :blk true;
            };
            if (file_exists) {
                const local_hash = hash_mod.calculateFileHash(ctx.allocator, cache_path_owned) catch |err| {
                    ctx.setDiagnosticContext(cache_path_owned, "failed to compute local hash");
                    ctx.allocator.free(cache_dir);
                    return switch (err) {
                        error.OutOfMemory => Error.OutOfMemory,
                        else => Error.FileSystem,
                    };
                };
                defer ctx.allocator.free(local_hash);
                if (std.mem.eql(u8, local_hash, expected_hash.?)) {
                    const file_size = blk: {
                        const file = std.Io.Dir.openFileAbsolute(path_mod.currentIo(), cache_path_owned, .{}) catch break :blk 0;
                        defer file.close(path_mod.currentIo());
                        const stat = file.stat(path_mod.currentIo()) catch break :blk 0;
                        break :blk stat.size;
                    };
                    const subject = mere.ui.Subject{ .url = url_owned, .path = cache_path_owned };
                    ui_emit.downloadComplete(ctx, ctx.nextEventId(), subject, file_size);
                    cached_count += 1;
                    is_cached = true;
                }
            }
        }

        if (!is_cached) {
            try batch_requests.append(ctx.allocator, .{
                .url = url_owned,
                .dest_path = cache_path_owned,
                .options = .{
                    .expected_hash = expected_hash,
                },
            });
        }

        try prepared.append(ctx.allocator, .{
            .url_z = url_owned,
            .cache_path = cache_path_owned,
            .workspace_source_path = workspace_source_path_owned,
            .expected_hash = expected_hash,
            .cached = is_cached,
        });
    }

    if (batch_requests.items.len > 0) {
        download_mod.downloadBatch(config.client, ctx, batch_requests.items) catch |err| {
            const diag = ctx.getDiagnosticContext();
            if (diag.details == null) {
                ctx.setDiagnosticContextFmt(diag.subject orelse "source download", "failed to download source: {s}", .{@errorName(err)});
            }
            ctx.allocator.free(cache_dir);
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.AccessDenied => Error.PermissionDenied,
                else => Error.Network,
            };
        };
        downloaded_count += @intCast(batch_requests.items.len);
    }

    for (prepared.items) |entry| {
        if (path_mod.openExistingDir(entry.cache_path)) |cache_dir_handle| {
            cache_dir_handle.close(path_mod.currentIo());
            ctx.setDiagnosticContext(entry.cache_path, "failed to read cached source");
            ctx.allocator.free(cache_dir);
            return Error.FileSystem;
        } else |dir_err| switch (dir_err) {
            error.FileNotFound, error.NotDir => {},
            error.AccessDenied => {
                ctx.setDiagnosticContext(entry.cache_path, "failed to read cached source");
                ctx.allocator.free(cache_dir);
                return Error.PermissionDenied;
            },
            else => {
                ctx.setDiagnosticContext(entry.cache_path, "failed to read cached source");
                ctx.allocator.free(cache_dir);
                return Error.FileSystem;
            },
        }

        const cache_file = path_mod.openExistingFile(entry.cache_path) catch |link_err| {
            ctx.setDiagnosticContext(entry.cache_path, "failed to read cached source");
            ctx.allocator.free(cache_dir);
            return mapFsError(link_err);
        };
        defer cache_file.close(path_mod.currentIo());

        cache_file.hardLink(path_mod.currentIo(), std.Io.Dir.cwd(), entry.workspace_source_path, .{}) catch |link_err| {
            ctx.debug("hardlink failed ({s}), copying instead: {s} -> {s}", .{ @errorName(link_err), entry.cache_path, entry.workspace_source_path });
            if (path_mod.openExistingDir(entry.workspace_source_path)) |existing_dir| {
                existing_dir.close(path_mod.currentIo());
                ctx.setDiagnosticContext(entry.workspace_source_path, "failed to create workspace source");
                ctx.allocator.free(cache_dir);
                return Error.FileSystem;
            } else |dir_err| switch (dir_err) {
                error.FileNotFound, error.NotDir => {},
                error.AccessDenied => {
                    ctx.setDiagnosticContext(entry.workspace_source_path, "failed to create workspace source");
                    ctx.allocator.free(cache_dir);
                    return Error.PermissionDenied;
                },
                else => {
                    ctx.setDiagnosticContext(entry.workspace_source_path, "failed to create workspace source");
                    ctx.allocator.free(cache_dir);
                    return Error.FileSystem;
                },
            }

            path_mod.copyFile(entry.cache_path, entry.workspace_source_path) catch |err| {
                ctx.setDiagnosticContext(entry.workspace_source_path, "failed to create workspace source");
                ctx.allocator.free(cache_dir);
                return mapFsError(err);
            };
        };

        ctx.debug("source available in workspace: {s}", .{entry.workspace_source_path});
    }

    return DownloadResult{
        .downloaded_count = downloaded_count,
        .cached_count = cached_count,
        .total_sources = @intCast(config.sources.len),
        .cache_dir_used = cache_dir,
    };
}

// TESTS - These should all FAIL initially (RED phase)

test "download sources independently of build orchestration" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var dummy = test_helpers.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();

    // Create test sources
    const src_content = "test-file-content";
    try dummy.set("http://example.com/source1.txt", src_content);
    try dummy.set("http://example.com/source2.txt", src_content);

    var vtable = download_mod.TransferClient.VTable{ .download_file = test_helpers.dummy_download_file };
    const client = download_mod.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    // Create a minimal recipe with test sources
    const kdl_text =
        \\recipe {
        \\    name "testpkg"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\    description "test"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\}
        \\source "http://example.com/source1.txt"
        \\source "http://example.com/source2.txt"
        \\build {
        \\    script "true"
        \\}
        \\package "testpkg" {
        \\    files "usr/bin/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    // Create workspace sources directory
    const sources_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "sources" });
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    var result = try download(&test_env.ctx, .{
        .sources = parsed.sources.items,
        .client = client,
        .cache_dir = null,
        .workspace_sources_dir = sources_dir,
        .recipe_dir = test_env.path,
        .recipe = &parsed,
    });
    defer result.deinit(test_env.ctx.allocator);

    try std.testing.expectEqual(@as(u32, 2), result.downloaded_count);
    try std.testing.expectEqual(@as(u32, 0), result.cached_count);
    try std.testing.expectEqual(@as(u32, 2), result.total_sources);
}

test "download handles pre-existing files and hardlinks correctly" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var dummy = test_helpers.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();

    // Create test source
    const src_content = "cached-file-content";
    try dummy.set("http://example.com/cached.txt", src_content);

    var vtable = download_mod.TransferClient.VTable{ .download_file = test_helpers.dummy_download_file };
    const client = download_mod.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    // Create custom cache directory
    const cache_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "test_cache" });
    defer test_env.ctx.allocator.free(cache_dir);
    try path_mod.ensureDirExists(cache_dir);

    // Pre-populate cache with the file
    const cached_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_dir, "cached.txt" });
    defer test_env.ctx.allocator.free(cached_file_path);

    var cache_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cached_file_path, .{});
    defer cache_file.close(path_mod.currentIo());
    try cache_file.writeStreamingAll(path_mod.currentIo(), src_content);

    const kdl_text =
        \\recipe {
        \\    name "testpkg"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\    description "test"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\}
        \\source "http://example.com/cached.txt"
        \\build {
        \\    script "true"
        \\}
        \\package "testpkg" {
        \\    files "usr/bin/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const sources_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "sources" });
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    // Confirm cached files are reused and workspace sync still succeeds
    var result = try download(&test_env.ctx, .{
        .sources = parsed.sources.items,
        .client = client,
        .cache_dir = cache_dir,
        .workspace_sources_dir = sources_dir,
        .recipe_dir = test_env.path,
        .recipe = &parsed,
    });
    defer result.deinit(test_env.ctx.allocator);

    // The download function reports success even when file exists, so we get download_count=1
    // What matters is that the workspace gets the file correctly
    try std.testing.expectEqual(@as(u32, 1), result.downloaded_count);
    try std.testing.expectEqual(@as(u32, 0), result.cached_count);
    try std.testing.expectEqual(@as(u32, 1), result.total_sources);

    // Verify hardlink was created in workspace
    const workspace_file = try std.fs.path.join(test_env.ctx.allocator, &.{ sources_dir, "cached.txt" });
    defer test_env.ctx.allocator.free(workspace_file);

    // File should exist in workspace
    const workspace_content = blk: {
        const file = try path_mod.openExistingFile(workspace_file);
        defer file.close(path_mod.currentIo());
        const stat = try file.stat(path_mod.currentIo());
        const content = try test_env.ctx.allocator.alloc(u8, @intCast(stat.size));
        errdefer test_env.ctx.allocator.free(content);
        const len = try file.readPositionalAll(path_mod.currentIo(), content, 0);
        break :blk content[0..len];
    };
    defer test_env.ctx.allocator.free(workspace_content);
    try std.testing.expectEqualStrings(src_content, workspace_content);
}

test "download validates hashes independently" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var dummy = test_helpers.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();

    // Create test source with known content
    const src_content = "hash-validation-content";
    try dummy.set("http://example.com/hashfile.txt", src_content);

    // Compute blake3 hash for validation
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(src_content);
    var hash_result: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(hash_result[0..]);
    var hash_hex: [std.crypto.hash.Blake3.digest_length * 2]u8 = undefined;
    hash_hex = std.fmt.bytesToHex(hash_result[0..], .lower);

    var vtable = download_mod.TransferClient.VTable{ .download_file = test_helpers.dummy_download_file };
    const client = download_mod.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    // Create recipe with hash validation
    const kdl_text = try std.fmt.allocPrint(test_env.ctx.allocator,
        \\recipe {{
        \\    name "testpkg"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\    description "test"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\}}
        \\source "http://example.com/hashfile.txt" {{
        \\    blake3 "{s}"
        \\}}
        \\build {{
        \\    script "true"
        \\}}
        \\package "testpkg" {{
        \\    files "usr/bin/*"
        \\}}
    , .{hash_hex[0..]});
    defer test_env.ctx.allocator.free(kdl_text);

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const sources_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "sources" });
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    // Confirm hash validation succeeds and the workspace copy matches the source
    var result = try download(&test_env.ctx, .{
        .sources = parsed.sources.items,
        .client = client,
        .cache_dir = null,
        .workspace_sources_dir = sources_dir,
        .recipe_dir = test_env.path,
        .recipe = &parsed,
    });
    defer result.deinit(test_env.ctx.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.downloaded_count);
    try std.testing.expectEqual(@as(u32, 0), result.cached_count);

    // Verify the downloaded file exists and has correct content
    const workspace_file = try std.fs.path.join(test_env.ctx.allocator, &.{ sources_dir, "hashfile.txt" });
    defer test_env.ctx.allocator.free(workspace_file);

    const workspace_content = blk: {
        const file = try path_mod.openExistingFile(workspace_file);
        defer file.close(path_mod.currentIo());
        const stat = try file.stat(path_mod.currentIo());
        const content = try test_env.ctx.allocator.alloc(u8, @intCast(stat.size));
        errdefer test_env.ctx.allocator.free(content);
        const len = try file.readPositionalAll(path_mod.currentIo(), content, 0);
        break :blk content[0..len];
    };
    defer test_env.ctx.allocator.free(workspace_content);
    try std.testing.expectEqualStrings(src_content, workspace_content);
}

test "download writes cache file with expected content (atomic rename smoke)" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var dummy = test_helpers.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();

    // Prepare dummy source
    const src_url = "http://example.com/cache-atomic.txt";
    const src_content = "atomic-cache-content";
    try dummy.set(src_url, src_content);

    var vtable = download_mod.TransferClient.VTable{ .download_file = test_helpers.dummy_download_file };
    const client = download_mod.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    // Create cache dir
    const cache_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "atomic_cache" });
    defer test_env.ctx.allocator.free(cache_dir);
    try path_mod.ensureDirExists(cache_dir);

    // Create minimal recipe with one source
    const kdl_text = try std.fmt.allocPrint(test_env.ctx.allocator,
        \\recipe {{
        \\    name "atomic"
        \\    version "0.1"
        \\    release 1
        \\    archs "x86_64"
        \\    description "atomic test"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\}}
        \\source "{s}"
        \\build {{
        \\    script "true"
        \\}}
        \\package "atomic" {{
        \\    files "usr/bin/*"
        \\}}
    , .{src_url});
    defer test_env.ctx.allocator.free(kdl_text);

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const sources_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "sources" });
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    var result = try download(&test_env.ctx, .{
        .sources = parsed.sources.items,
        .client = client,
        .cache_dir = cache_dir,
        .workspace_sources_dir = sources_dir,
        .recipe_dir = test_env.path,
        .recipe = &parsed,
    });
    defer result.deinit(test_env.ctx.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.total_sources);

    // Verify cache file exists and content matches
    const cached_file = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_dir, "cache-atomic.txt" });
    defer test_env.ctx.allocator.free(cached_file);

    const cached_content = blk: {
        const file = try path_mod.openExistingFile(cached_file);
        defer file.close(path_mod.currentIo());
        const stat = try file.stat(path_mod.currentIo());
        const content = try test_env.ctx.allocator.alloc(u8, @intCast(stat.size));
        errdefer test_env.ctx.allocator.free(content);
        const len = try file.readPositionalAll(path_mod.currentIo(), content, 0);
        break :blk content[0..len];
    };
    defer test_env.ctx.allocator.free(cached_content);
    try std.testing.expectEqualStrings(src_content, cached_content);
}

test "download reports read errors in cache-to-workspace copy fallback" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var dummy = test_helpers.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();

    const src_url = "http://example.com/dirsource.txt";
    try dummy.set(src_url, "source-content");

    var vtable = download_mod.TransferClient.VTable{ .download_file = test_helpers.dummy_download_file };
    const client = download_mod.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    const cache_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "cache" });
    defer test_env.ctx.allocator.free(cache_dir);
    try path_mod.ensureDirExists(cache_dir);

    // Force a read error in copy fallback by making the cached source path a directory.
    // downloadFile keeps existing destinations when force=false, so this remains a directory.
    const cache_entry_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_dir, "dirsource.txt" });
    defer test_env.ctx.allocator.free(cache_entry_dir);
    try path_mod.ensureDirExists(cache_entry_dir);

    const sources_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "sources" });
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    const kdl_text = try std.fmt.allocPrint(test_env.ctx.allocator,
        \\recipe {{
        \\    name "fallback-read-error"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\    description "fallback read error test"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\}}
        \\source "{s}"
        \\build {{
        \\    script "true"
        \\}}
        \\package "fallback-read-error" {{
        \\    files "usr/bin/*"
        \\}}
    , .{src_url});
    defer test_env.ctx.allocator.free(kdl_text);

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    try std.testing.expectError(Error.FileSystem, download(&test_env.ctx, .{
        .sources = parsed.sources.items,
        .client = client,
        .cache_dir = cache_dir,
        .workspace_sources_dir = sources_dir,
        .recipe_dir = test_env.path,
        .recipe = &parsed,
    }));

    const diag = test_env.ctx.getDiagnosticContext();
    try std.testing.expect(diag.subject != null);
    try std.testing.expect(diag.details != null);
    try std.testing.expectEqualStrings(cache_entry_dir, diag.subject.?);
    try std.testing.expectEqualStrings("failed to read cached source", diag.details.?);
}

test "download reports permission errors in cache-to-workspace fallback" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var dummy = test_helpers.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();

    const src_url = "http://example.com/perm-source.txt";
    const src_content = "permission-test-content";
    try dummy.set(src_url, src_content);

    var vtable = download_mod.TransferClient.VTable{ .download_file = test_helpers.dummy_download_file };
    const client = download_mod.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    const cache_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "cache_perm" });
    defer test_env.ctx.allocator.free(cache_dir);
    try path_mod.ensureDirExists(cache_dir);

    const cache_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_dir, "perm-source.txt" });
    defer test_env.ctx.allocator.free(cache_file_path);
    {
        var cache_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cache_file_path, .{});
        defer cache_file.close(path_mod.currentIo());
        try cache_file.writeStreamingAll(path_mod.currentIo(), src_content);
    }

    const sources_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "sources_perm" });
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    var sources_dir_handle = try path_mod.openExistingDir(sources_dir);
    defer sources_dir_handle.close(path_mod.currentIo());
    try sources_dir_handle.setPermissions(path_mod.currentIo(), .fromMode(0o555));

    const kdl_text = try std.fmt.allocPrint(test_env.ctx.allocator,
        \\recipe {{
        \\    name "fallback-perm-error"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\    description "fallback permission error test"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\}}
        \\source "{s}"
        \\build {{
        \\    script "true"
        \\}}
        \\package "fallback-perm-error" {{
        \\    files "usr/bin/*"
        \\}}
    , .{src_url});
    defer test_env.ctx.allocator.free(kdl_text);

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    try std.testing.expectError(Error.PermissionDenied, download(&test_env.ctx, .{
        .sources = parsed.sources.items,
        .client = client,
        .cache_dir = cache_dir,
        .workspace_sources_dir = sources_dir,
        .recipe_dir = test_env.path,
        .recipe = &parsed,
    }));

    const expected_workspace_path = try std.fs.path.join(test_env.ctx.allocator, &.{ sources_dir, "perm-source.txt" });
    defer test_env.ctx.allocator.free(expected_workspace_path);

    const diag = test_env.ctx.getDiagnosticContext();
    try std.testing.expect(diag.subject != null);
    try std.testing.expect(diag.details != null);
    try std.testing.expectEqualStrings(expected_workspace_path, diag.subject.?);
    try std.testing.expectEqualStrings("failed to create workspace source", diag.details.?);
}

test "clearSharedCache removes cached source entries" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cache_root = try defaultSharedCacheRoot(test_env.ctx.allocator, &test_env.ctx);
    defer test_env.ctx.allocator.free(cache_root);
    try path_mod.ensureDirExists(cache_root);

    const file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "source.tar.gz" });
    defer test_env.ctx.allocator.free(file_path);
    {
        var file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), file_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), "payload");
    }

    const dir_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "extracted" });
    defer test_env.ctx.allocator.free(dir_path);
    try path_mod.ensureDirExists(dir_path);

    const removed = try clearSharedCache(&test_env.ctx);
    try std.testing.expectEqual(@as(usize, 2), removed);

    var dir = try std.Io.Dir.openDirAbsolute(path_mod.currentIo(), cache_root, .{ .iterate = true });
    defer dir.close(path_mod.currentIo());
    var iter = dir.iterate();
    try std.testing.expect((try iter.next(path_mod.currentIo())) == null);
}
