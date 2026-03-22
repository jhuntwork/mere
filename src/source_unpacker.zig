const std = @import("std");
const mere = @import("mere.zig");
const recipe = @import("recipe.zig");
const extract = @import("extract.zig");
const test_helpers = @import("test_helpers.zig");
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
const DiagnosticContext = errors.DiagnosticContext;

/// Source unpacking error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during unpacking operations
/// - FileSystem: File operations failed (reading, writing, opening files, path operations)
/// - PermissionDenied: Insufficient permissions for source or destination filesystem operations
/// - InvalidInput: Invalid unpacking parameters or configuration
/// - CorruptData: Archive extraction failed due to corrupt data
///
/// Unpacking-Specific Errors:
/// - NoSources: No sources available for unpacking
const Std = errors.StandardErrors;
pub const UnpackError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData || error{NoSources};

pub const SourceArchiveFormat = enum {
    tar,
    tar_gz,
    tgz,
    tar_xz,
    tar_bz2,
    tar_zst,
    zip,
    unknown,

    pub fn isExtractable(self: SourceArchiveFormat) bool {
        return switch (self) {
            .tar, .tar_gz, .tgz, .tar_xz, .tar_bz2, .tar_zst, .zip => true,
            .unknown => false,
        };
    }
};

fn detectSourceArchiveFormat(filename: []const u8) SourceArchiveFormat {
    if (std.mem.endsWith(u8, filename, ".tar.gz")) return .tar_gz;
    if (std.mem.endsWith(u8, filename, ".tgz")) return .tgz;
    if (std.mem.endsWith(u8, filename, ".tar.xz")) return .tar_xz;
    if (std.mem.endsWith(u8, filename, ".tar.bz2")) return .tar_bz2;
    if (std.mem.endsWith(u8, filename, ".tar.zst")) return .tar_zst;
    if (std.mem.endsWith(u8, filename, ".tar")) return .tar;
    if (std.mem.endsWith(u8, filename, ".zip")) return .zip;
    return .unknown;
}

pub const UnpackResult = struct {
    /// The directory inside dest_dir which should be used as the actual source
    /// directory. This string is allocated with `allocator` and must be freed by
    /// the caller.
    actual_src_dir: []const u8,
    detected_format: SourceArchiveFormat,

    pub fn deinit(self: *UnpackResult, allocator: std.mem.Allocator) void {
        if (self.actual_src_dir.len > 0) allocator.free(self.actual_src_dir);
    }
};

/// Unpack the first matching source found in `workspace_sources_dir` into
/// `dest_dir`. This function is functional (it does not mutate any external
/// workspace struct). It returns the actual directory that should be used as
/// the source directory (for example, if the archive contains a single top-
/// level directory, that path is returned). The returned `actual_src_dir` is
/// allocated using `allocator`.
pub fn unpackFirstSource(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    workspace_sources_dir: []const u8,
    dest_dir: []const u8,
    r: *const recipe.Recipe,
) UnpackError!UnpackResult {
    // Set diagnostic context for source unpacking operations
    const diag_ctx = DiagnosticContext.init()
        .withSubject(workspace_sources_dir);
    _ = diag_ctx; // Context available for future error reporting enhancements

    // Select the first source that exists in workspace_sources_dir respecting save_as
    var selected_path: ?[]const u8 = null;

    var si: usize = 0;
    while (si < r.sources.items.len) : (si += 1) {
        const src_entry = r.sources.items[si];
        if (src_entry.url.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const vars_ptr = if (r.vars.items.len > 0) &r.vars else null;
        const expanded_url = recipe.interpolate(arena_alloc, ctx, src_entry.url, r, vars_ptr) catch |err| {
            ctx.debug("source unpack: failed to interpolate source URL: {s}", .{@errorName(err)});
            continue;
        };

        const last_slash = std.mem.lastIndexOf(u8, expanded_url, "/");
        const basename = if (last_slash) |idx| expanded_url[idx + 1 ..] else expanded_url;
        const saved_basename = if (src_entry.save_as) |sa| sa else basename;

        const ws_path = std.fs.path.join(allocator, &.{ workspace_sources_dir, saved_basename }) catch |err| {
            ctx.debug("source unpack: failed to join path: {s}", .{@errorName(err)});
            continue;
        };

        // Check existence
        var f = path_mod.openExistingFile(ws_path) catch |err| {
            ctx.debug("source unpack: workspace source not present: {s} ({s})", .{ ws_path, @errorName(err) });
            allocator.free(ws_path);
            continue;
        };
        f.close(path_mod.currentIo());

        selected_path = ws_path;
        break;
    }

    if (selected_path == null) return UnpackError.NoSources;
    const source_path = selected_path.?;
    // Ensure we free the allocated source_path on all returns
    defer allocator.free(source_path);
    var result: UnpackResult = .{ .actual_src_dir = "", .detected_format = .unknown };

    // Derive source_name
    const slash_idx = std.mem.lastIndexOf(u8, source_path, "/");
    const source_name = if (slash_idx) |idx| source_path[idx + 1 ..] else source_path;

    ctx.debug("unpacking first source: {s} -> {s}", .{ source_path, dest_dir });

    const format = detectSourceArchiveFormat(source_name);
    result.detected_format = format;

    if (format.isExtractable()) {
        extract.into(ctx, source_path, dest_dir) catch |err| {
            return switch (err) {
                error.OutOfMemory => UnpackError.OutOfMemory,
                error.PermissionDenied => UnpackError.PermissionDenied,
                error.InvalidInput, error.UnsupportedFormat, error.PackageExtractFailed => UnpackError.CorruptData,
                else => UnpackError.FileSystem,
            };
        };
    } else {
        // Copy as-is into dest_dir
        const dest_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_dir, source_name }) catch {
            return UnpackError.OutOfMemory;
        };
        defer allocator.free(dest_path);

        path_mod.copyFile(source_path, dest_path) catch |err| {
            return switch (err) {
                error.AccessDenied => UnpackError.PermissionDenied,
                else => UnpackError.FileSystem,
            };
        };
    }

    // After extraction, detect single top-level directory inside dest_dir
    var src_dir_handle = path_mod.openExistingDir(dest_dir) catch |err| {
        ctx.debug("failed to open dest dir for post-extract inspection {s}: {s}", .{ dest_dir, @errorName(err) });
        return UnpackError.FileSystem;
    };
    defer src_dir_handle.close(path_mod.currentIo());

    var iter = src_dir_handle.iterate();
    var single_dir_name: ?[]const u8 = null;
    defer if (single_dir_name) |name| allocator.free(name);
    var entry_count: usize = 0;
    while (true) {
        const entry = iter.next(path_mod.currentIo()) catch |err| {
            return switch (err) {
                error.AccessDenied => UnpackError.PermissionDenied,
                else => UnpackError.FileSystem,
            };
        };
        if (entry == null) break;
        const e = entry.?;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        entry_count += 1;
        if (entry_count == 1 and e.kind == .directory) {
            single_dir_name = try allocator.dupe(u8, e.name);
        } else {
            if (single_dir_name) |name| {
                allocator.free(name);
                single_dir_name = null;
            }
            single_dir_name = null;
            break;
        }
    }

    if (entry_count == 1) {
        if (single_dir_name) |name| {
            const new_src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_dir, name });
            result.actual_src_dir = new_src;
            // success
            return result;
        }
    }

    // Otherwise return dest_dir itself as the actual src dir
    const dest_dup = try allocator.dupe(u8, dest_dir);
    result.actual_src_dir = dest_dup;
    return result;
}

// Tests
test "SourceUnpacker extracts first source without mutating workspace state" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create sources dir and place a tar archive there
    const sources_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/sources", .{test_env.path});
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    const tar_name = "busybox-1.36.1.tar";
    const tar_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/{s}", .{ sources_dir, tar_name });
    defer test_env.ctx.allocator.free(tar_path);

    try test_helpers.createTestTarFile(&test_env.ctx, "busybox-1.36.1/file", tar_path);

    // Create a minimal recipe referencing the tar file
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
        \\source "busybox-1.36.1.tar"
        \\build {
        \\    script "true"
        \\}
        \\package "testpkg" {
        \\    files "usr/bin/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const dest_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/build-src", .{test_env.path});
    defer test_env.ctx.allocator.free(dest_dir);
    try path_mod.ensureDirExists(dest_dir);

    var res = try unpackFirstSource(test_env.ctx.allocator, &test_env.ctx, sources_dir, dest_dir, &parsed);
    defer res.deinit(test_env.ctx.allocator);

    try std.testing.expect(res.detected_format == .tar);
    try std.testing.expect(res.actual_src_dir.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, res.actual_src_dir, "busybox-1.36.1") != null);
}

test "SourceUnpacker handles single-directory detection functionally" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const sources_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/sources", .{test_env.path});
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    const tar_name = "onlydir.tar";
    const tar_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/{s}", .{ sources_dir, tar_name });
    defer test_env.ctx.allocator.free(tar_path);

    try test_helpers.createTestTarFile(&test_env.ctx, "onlydir/file", tar_path);

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
        \\source "onlydir.tar"
        \\build {
        \\    script "true"
        \\}
        \\package "testpkg" {
        \\    files "usr/bin/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const dest_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/build-src", .{test_env.path});
    defer test_env.ctx.allocator.free(dest_dir);
    try path_mod.ensureDirExists(dest_dir);

    var res = try unpackFirstSource(test_env.ctx.allocator, &test_env.ctx, sources_dir, dest_dir, &parsed);
    defer res.deinit(test_env.ctx.allocator);

    try std.testing.expect(res.detected_format == .tar);
    const expected_src_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/onlydir", .{dest_dir});
    defer test_env.ctx.allocator.free(expected_src_dir);
    try std.testing.expectEqualStrings(expected_src_dir, res.actual_src_dir);

    var actual_src_dir = try path_mod.openExistingDir(res.actual_src_dir);
    actual_src_dir.close(path_mod.currentIo());

    const extracted_file = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/file", .{res.actual_src_dir});
    defer test_env.ctx.allocator.free(extracted_file);
    const extracted_content = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        path_mod.currentIo(),
        extracted_file,
        test_env.ctx.allocator,
        .limited(1024 * 16),
    );
    defer test_env.ctx.allocator.free(extracted_content);
    try std.testing.expectEqualStrings("test content", extracted_content);
}

test "detectSourceArchiveFormat identifies common source archive types" {
    try std.testing.expect(detectSourceArchiveFormat("file.tar.gz") == .tar_gz);
    try std.testing.expect(detectSourceArchiveFormat("file.tgz") == .tgz);
    try std.testing.expect(detectSourceArchiveFormat("file.tar.xz") == .tar_xz);
    try std.testing.expect(detectSourceArchiveFormat("file.tar.bz2") == .tar_bz2);
    try std.testing.expect(detectSourceArchiveFormat("file.tar.zst") == .tar_zst);
    try std.testing.expect(detectSourceArchiveFormat("file.tar") == .tar);
    try std.testing.expect(detectSourceArchiveFormat("file.zip") == .zip);
    try std.testing.expect(detectSourceArchiveFormat("file.txt") == .unknown);
}

test "detectSourceArchiveFormat handles edge cases" {
    try std.testing.expect(detectSourceArchiveFormat("") == .unknown);
    try std.testing.expect(detectSourceArchiveFormat("my.tar.gz.backup") == .unknown);
    try std.testing.expect(detectSourceArchiveFormat("file.TAR.GZ") == .unknown);
    try std.testing.expect(detectSourceArchiveFormat("archive-1.2.3.tar.xz") == .tar_xz);
}

test "SourceArchiveFormat.isExtractable matches unpacking behavior" {
    try std.testing.expect(SourceArchiveFormat.tar.isExtractable());
    try std.testing.expect(SourceArchiveFormat.tar_gz.isExtractable());
    try std.testing.expect(SourceArchiveFormat.tgz.isExtractable());
    try std.testing.expect(SourceArchiveFormat.tar_xz.isExtractable());
    try std.testing.expect(SourceArchiveFormat.tar_bz2.isExtractable());
    try std.testing.expect(SourceArchiveFormat.tar_zst.isExtractable());
    try std.testing.expect(SourceArchiveFormat.zip.isExtractable());
    try std.testing.expect(!SourceArchiveFormat.unknown.isExtractable());
}

test "SourceUnpacker returns NoSources when workspace has no matching source file" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const sources_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/sources", .{test_env.path});
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    const dest_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/build-src", .{test_env.path});
    defer test_env.ctx.allocator.free(dest_dir);
    try path_mod.ensureDirExists(dest_dir);

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
        \\source "missing.tar"
        \\build {
        \\    script "true"
        \\}
        \\package "testpkg" {
        \\    files "usr/bin/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    try std.testing.expectError(
        UnpackError.NoSources,
        unpackFirstSource(test_env.ctx.allocator, &test_env.ctx, sources_dir, dest_dir, &parsed),
    );
}

test "SourceUnpacker reports malformed archive extraction failure" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const sources_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/sources", .{test_env.path});
    defer test_env.ctx.allocator.free(sources_dir);
    try path_mod.ensureDirExists(sources_dir);

    const bad_tar_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/bad.tar", .{sources_dir});
    defer test_env.ctx.allocator.free(bad_tar_path);
    {
        var bad_tar = try path_mod.makePathAndOpenFile(bad_tar_path);
        defer bad_tar.close(path_mod.currentIo());
        try bad_tar.writeStreamingAll(path_mod.currentIo(), "not a tar archive");
    }

    const dest_dir = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/build-src", .{test_env.path});
    defer test_env.ctx.allocator.free(dest_dir);
    try path_mod.ensureDirExists(dest_dir);

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
        \\source "bad.tar"
        \\build {
        \\    script "true"
        \\}
        \\package "testpkg" {
        \\    files "usr/bin/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    try std.testing.expectError(
        UnpackError.FileSystem,
        unpackFirstSource(test_env.ctx.allocator, &test_env.ctx, sources_dir, dest_dir, &parsed),
    );
}
