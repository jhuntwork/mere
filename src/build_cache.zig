const std = @import("std");
const mere = @import("mere.zig");
const split_staging = @import("build_orchestrator/split_staging.zig");
const packaging = @import("packaging.zig");
const path_mod = @import("path.zig");
const recipe = @import("recipe.zig");
const hash = @import("hash.zig");
const test_helpers = @import("test_helpers.zig");

pub const ArtifactKind = enum {
    source_fetch,
    source_unpack,
    profile_realize,
    phase_run,
    split_stage,
    package_archive,

    pub fn asString(self: ArtifactKind) []const u8 {
        return @tagName(self);
    }
};

pub const CacheError = error{
    OutOfMemory,
    FileSystem,
    PermissionDenied,
    InvalidInput,
};

pub const CacheRecord = struct {
    kind: ArtifactKind,
    key_hex: []const u8,
    artifact_digest_hex: []const u8,
    actual_subpath: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CacheRecord) void {
        self.allocator.free(self.key_hex);
        self.allocator.free(self.artifact_digest_hex);
        if (self.actual_subpath) |subpath| self.allocator.free(subpath);
    }
};

pub const RestoredArtifact = struct {
    record: CacheRecord,
    restored_root: []const u8,
    actual_path: ?[]const u8,

    pub fn deinit(self: *RestoredArtifact) void {
        self.record.deinit();
        self.record.allocator.free(self.restored_root);
        if (self.actual_path) |path| self.record.allocator.free(path);
    }
};

pub const RestoredPackageArchive = struct {
    record: CacheRecord,
    archive_path: []const u8,
    content_hash: []const u8,
    archive_hash: []const u8,
    signature: []u8,

    pub fn deinit(self: *RestoredPackageArchive) void {
        self.record.deinit();
        self.record.allocator.free(self.archive_path);
        self.record.allocator.free(self.content_hash);
        self.record.allocator.free(self.archive_hash);
        self.record.allocator.free(self.signature);
    }
};

pub const CacheInspection = struct {
    record: CacheRecord,
    key_path: []const u8,
    artifact_dir: []const u8,
    artifact_meta_path: ?[]const u8,
    payload_dir: ?[]const u8,
    staging_dir: ?[]const u8,
    archive_path: ?[]const u8,
    sidecar_meta_path: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CacheInspection) void {
        self.record.deinit();
        self.allocator.free(self.key_path);
        self.allocator.free(self.artifact_dir);
        if (self.artifact_meta_path) |path| self.allocator.free(path);
        if (self.payload_dir) |path| self.allocator.free(path);
        if (self.staging_dir) |path| self.allocator.free(path);
        if (self.archive_path) |path| self.allocator.free(path);
        if (self.sidecar_meta_path) |path| self.allocator.free(path);
    }
};

pub const GcResult = struct {
    removed_key_records: usize = 0,
    removed_artifacts: usize = 0,
    retained_artifacts: usize = 0,
};

pub fn clear(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
) CacheError!usize {
    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);
    const io = path_mod.currentIo();

    var dir = path_mod.openExistingDir(cache_root) catch |err| {
        return switch (err) {
            error.FileNotFound => 0,
            else => mapFsError(err),
        };
    };
    defer dir.close(io);

    var iter = dir.iterate();
    var removed_count: usize = 0;

    while (iter.next(io) catch |err| return mapFsError(err)) |entry| {
        switch (entry.kind) {
            .directory => dir.deleteTree(io, entry.name) catch |err| return mapFsError(err),
            else => dir.deleteFile(io, entry.name) catch |err| return mapFsError(err),
        }

        removed_count += 1;
    }

    return removed_count;
}

pub fn parseArtifactKind(name: []const u8) ?ArtifactKind {
    inline for (std.meta.fields(ArtifactKind)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

pub fn computeSourceFetchKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
) CacheError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;

    out.writeAll("source-fetch-v1\n") catch return error.OutOfMemory;
    try appendRecipeVars(out, parsed_recipe);
    try appendSourceInputs(allocator, ctx, out, recipe_dir, parsed_recipe);
    try appendRecipeCompanionInputs(allocator, out, recipe_dir);

    buf = out_buf.toArrayList();
    return hash.calculateBytesHash(allocator, buf.items) catch |err| mapHashError(err);
}

pub fn computeSourceUnpackKey(
    allocator: std.mem.Allocator,
    fetch_key_hex: []const u8,
) CacheError![]const u8 {
    return std.fmt.allocPrint(allocator, "source-unpack-v2-{s}", .{fetch_key_hex}) catch error.OutOfMemory;
}

pub fn computeProfileRealizeKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    config: *const @import("config.zig").Config,
) CacheError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;

    out.writeAll("profile-realize-v1\n") catch return error.OutOfMemory;
    out.print("root={s}\n", .{ctx.root()}) catch return error.OutOfMemory;
    out.print("arch={s}\n", .{parsed_recipe.arch orelse ""}) catch return error.OutOfMemory;
    for (parsed_recipe.depends.items) |dep| {
        out.print("dep={s}\n", .{dep}) catch return error.OutOfMemory;
    }

    const config_kdl = config.toKdl() catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    defer config.alloc.free(config_kdl);
    out.writeAll(config_kdl) catch return error.OutOfMemory;

    buf = out_buf.toArrayList();
    return hash.calculateBytesHash(allocator, buf.items) catch |err| {
        return mapHashError(err);
    };
}

pub fn computePhaseStepKey(
    allocator: std.mem.Allocator,
    phase_name: []const u8,
    script: []const u8,
    recipe_env: []const recipe.KV,
    phase_env: []const recipe.KV,
    source_tree_hash: []const u8,
    profile_tree_hash: []const u8,
    ns_working_dir: []const u8,
) CacheError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;

    out.writeAll("phase-step-v1\n") catch return error.OutOfMemory;
    out.print("phase={s}\n", .{phase_name}) catch return error.OutOfMemory;
    out.print("script={s}\n", .{script}) catch return error.OutOfMemory;
    out.print("source_tree={s}\n", .{source_tree_hash}) catch return error.OutOfMemory;
    out.print("profile_tree={s}\n", .{profile_tree_hash}) catch return error.OutOfMemory;
    out.print("working_dir={s}\n", .{ns_working_dir}) catch return error.OutOfMemory;
    try appendKvList(out, "recipe_env", recipe_env);
    try appendKvList(out, "phase_env", phase_env);

    buf = out_buf.toArrayList();
    return hash.calculateBytesHash(allocator, buf.items) catch |err| {
        return mapHashError(err);
    };
}

pub fn computeSplitStageKey(
    allocator: std.mem.Allocator,
    parsed_recipe: *const recipe.Recipe,
    destdir_tree_hash: []const u8,
) CacheError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;

    out.writeAll("split-stage-v1\n") catch return error.OutOfMemory;
    out.print("destdir={s}\n", .{destdir_tree_hash}) catch return error.OutOfMemory;
    for (parsed_recipe.packages.items, 0..) |pkg, idx| {
        out.print("package[{d}].name={s}\n", .{ idx, pkg.name }) catch return error.OutOfMemory;
        for (pkg.pkgfiles.items) |pattern| {
            out.print("package[{d}].pattern={s}\n", .{ idx, pattern }) catch return error.OutOfMemory;
        }
    }

    buf = out_buf.toArrayList();
    return hash.calculateBytesHash(allocator, buf.items) catch |err| {
        return mapHashError(err);
    };
}

pub fn computePackageArchiveKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    artifact: *const recipe.BuildArtifact,
    staging_tree_hash: []const u8,
    injected_dependencies: []const packaging.InjectedDependency,
) CacheError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;

    out.writeAll("package-archive-v1\n") catch return error.OutOfMemory;
    out.print("staging={s}\n", .{staging_tree_hash}) catch return error.OutOfMemory;
    out.print("name={s}\n", .{if (artifact.name.len > 0) artifact.name else parsed_recipe.name}) catch return error.OutOfMemory;
    out.print("version={s}\n", .{parsed_recipe.version}) catch return error.OutOfMemory;
    out.print("release={d}\n", .{parsed_recipe.release}) catch return error.OutOfMemory;
    out.print("arch={s}\n", .{parsed_recipe.arch orelse "any"}) catch return error.OutOfMemory;

    const signing_key_hash = try computeSigningKeyHash(allocator, ctx);
    defer allocator.free(signing_key_hash);
    out.print("signing_key={s}\n", .{signing_key_hash}) catch return error.OutOfMemory;

    for (injected_dependencies) |dep| {
        out.print("dep.{s}={s}\n", .{ dep.dep_type.toNodeName(), dep.value }) catch return error.OutOfMemory;
        out.print("dep-constraint={s}\n", .{dep.version_constraint orelse ""}) catch return error.OutOfMemory;
    }

    buf = out_buf.toArrayList();
    return hash.calculateBytesHash(allocator, buf.items) catch |err| {
        return mapHashError(err);
    };
}

pub fn storeDirectoryForKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    kind: ArtifactKind,
    key_hex: []const u8,
    src_dir: []const u8,
    actual_path: ?[]const u8,
) CacheError!CacheRecord {
    const cache_root = buildCacheRoot(allocator, ctx) catch |err| {
        ctx.setDiagnosticContextFmt(src_dir, "failed to resolve build cache root ({s})", .{@errorName(err)});
        return err;
    };
    defer allocator.free(cache_root);

    const artifacts_root = std.fs.path.join(allocator, &.{ cache_root, "artifacts" }) catch |err| {
        ctx.setDiagnosticContextFmt(cache_root, "failed to build cache artifacts path ({s})", .{@errorName(err)});
        return mapFsError(err);
    };
    defer allocator.free(artifacts_root);
    const keys_root = std.fs.path.join(allocator, &.{ cache_root, "keys", kind.asString() }) catch |err| {
        ctx.setDiagnosticContextFmt(cache_root, "failed to build cache keys path for {s} ({s})", .{ kind.asString(), @errorName(err) });
        return mapFsError(err);
    };
    defer allocator.free(keys_root);
    ensurePath(artifacts_root) catch |err| {
        ctx.setDiagnosticContextFmt(artifacts_root, "failed to create cache artifacts root ({s})", .{@errorName(err)});
        return err;
    };
    ensurePath(keys_root) catch |err| {
        ctx.setDiagnosticContextFmt(keys_root, "failed to create cache keys root ({s})", .{@errorName(err)});
        return err;
    };

    const artifact_digest_hex = hash.calculateBuildSnapshotHash(allocator, src_dir, null) catch |err| {
        ctx.setDiagnosticContextFmt(src_dir, "failed to hash source tree for cache storage ({s})", .{@errorName(err)});
        return mapHashError(err);
    };
    errdefer allocator.free(artifact_digest_hex);

    const artifact_dir = std.fs.path.join(allocator, &.{ artifacts_root, artifact_digest_hex }) catch |err| {
        ctx.setDiagnosticContextFmt(artifacts_root, "failed to build artifact cache dir for {s} ({s})", .{ artifact_digest_hex, @errorName(err) });
        return mapFsError(err);
    };
    defer allocator.free(artifact_dir);
    const payload_dir = std.fs.path.join(allocator, &.{ artifact_dir, "payload" }) catch |err| {
        ctx.setDiagnosticContextFmt(artifact_dir, "failed to build cache payload dir ({s})", .{@errorName(err)});
        return mapFsError(err);
    };
    defer allocator.free(payload_dir);
    const metadata_path = std.fs.path.join(allocator, &.{ artifact_dir, "meta.kdl" }) catch |err| {
        ctx.setDiagnosticContextFmt(artifact_dir, "failed to build cache metadata path ({s})", .{@errorName(err)});
        return mapFsError(err);
    };
    defer allocator.free(metadata_path);

    const payload_exists = dirExists(payload_dir);
    if (!payload_exists) {
        ensurePath(artifact_dir) catch |err| {
            ctx.setDiagnosticContextFmt(artifact_dir, "failed to create artifact cache dir ({s})", .{@errorName(err)});
            return err;
        };
        copyTreeAtomic(allocator, ctx, src_dir, payload_dir) catch |err| {
            if (ctx.getDiagnosticContext().details == null) {
                ctx.setDiagnosticContextFmt(payload_dir, "failed to copy source tree into cache payload ({s})", .{@errorName(err)});
            }
            return err;
        };
        writeArtifactMetadata(metadata_path, kind, artifact_digest_hex) catch |err| {
            ctx.setDiagnosticContextFmt(metadata_path, "failed to write cache artifact metadata ({s})", .{@errorName(err)});
            return err;
        };
    }

    const actual_subpath = computeActualSubpath(allocator, src_dir, actual_path) catch |err| {
        ctx.setDiagnosticContextFmt(src_dir, "failed to compute cached actual subpath ({s})", .{@errorName(err)});
        return err;
    };
    errdefer if (actual_subpath) |subpath| allocator.free(subpath);

    const key_path = std.fs.path.join(allocator, &.{ keys_root, keyHexFilename(key_hex) }) catch |err| {
        ctx.setDiagnosticContextFmt(keys_root, "failed to build cache key record path for {s} ({s})", .{ key_hex, @errorName(err) });
        return mapFsError(err);
    };
    defer allocator.free(key_path);
    writeKeyRecord(allocator, key_path, kind, key_hex, artifact_digest_hex, actual_subpath) catch |err| {
        ctx.setDiagnosticContextFmt(key_path, "failed to write cache key record ({s})", .{@errorName(err)});
        return err;
    };

    return CacheRecord{
        .kind = kind,
        .key_hex = try allocator.dupe(u8, key_hex),
        .artifact_digest_hex = artifact_digest_hex,
        .actual_subpath = actual_subpath,
        .allocator = allocator,
    };
}

pub fn restoreDirectoryForKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    kind: ArtifactKind,
    key_hex: []const u8,
    dest_dir: []const u8,
) CacheError!?RestoredArtifact {
    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);

    const keys_root = std.fs.path.join(allocator, &.{ cache_root, "keys", kind.asString() }) catch |err| {
        ctx.setDiagnosticContextFmt(cache_root, "failed to build cache keys path ({s})", .{@errorName(err)});
        return err;
    };
    defer allocator.free(keys_root);
    const key_path = std.fs.path.join(allocator, &.{ keys_root, keyHexFilename(key_hex) }) catch |err| {
        ctx.setDiagnosticContextFmt(keys_root, "failed to build cache key path for {s} ({s})", .{ key_hex, @errorName(err) });
        return err;
    };
    defer allocator.free(key_path);

    if (!fileExists(key_path)) return null;

    var record = readKeyRecord(allocator, kind, key_path) catch |err| {
        ctx.setDiagnosticContextFmt(key_path, "failed to read cache key record ({s})", .{@errorName(err)});
        return err;
    };
    errdefer record.deinit();

    const payload_dir = std.fs.path.join(allocator, &.{ cache_root, "artifacts", record.artifact_digest_hex, "payload" }) catch |err| {
        ctx.setDiagnosticContextFmt(cache_root, "failed to build cache payload path for artifact {s} ({s})", .{ record.artifact_digest_hex, @errorName(err) });
        return err;
    };
    defer allocator.free(payload_dir);
    if (!dirExists(payload_dir)) return null;

    replaceTreeFromCache(allocator, ctx, payload_dir, dest_dir) catch |err| {
        ctx.setDiagnosticContextFmt(dest_dir, "failed to restore cached {s} tree from {s} ({s})", .{ kind.asString(), payload_dir, @errorName(err) });
        return err;
    };

    const restored_root = allocator.dupe(u8, dest_dir) catch |err| {
        ctx.setDiagnosticContextFmt(dest_dir, "failed to copy restored cache root ({s})", .{@errorName(err)});
        return err;
    };
    errdefer allocator.free(restored_root);

    const actual_path = if (record.actual_subpath) |subpath|
        std.fs.path.join(allocator, &.{ dest_dir, subpath }) catch |err| {
            ctx.setDiagnosticContextFmt(dest_dir, "failed to build restored cache subpath '{s}' ({s})", .{ subpath, @errorName(err) });
            return err;
        }
    else
        null;
    errdefer if (actual_path) |path| allocator.free(path);

    return RestoredArtifact{
        .record = record,
        .restored_root = restored_root,
        .actual_path = actual_path,
    };
}

pub fn inspectKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    kind: ArtifactKind,
    key_hex: []const u8,
) CacheError!?CacheInspection {
    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);

    const keys_root = try std.fs.path.join(allocator, &.{ cache_root, "keys", kind.asString() });
    defer allocator.free(keys_root);
    const key_path = try std.fs.path.join(allocator, &.{ keys_root, keyHexFilename(key_hex) });
    defer allocator.free(key_path);
    if (!fileExists(key_path)) return null;

    var record = try readKeyRecord(allocator, kind, key_path);
    errdefer record.deinit();

    const artifact_dir = try std.fs.path.join(allocator, &.{ cache_root, "artifacts", record.artifact_digest_hex });
    errdefer allocator.free(artifact_dir);

    const artifact_meta_path = blk: {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, "meta.kdl" });
        if (!fileExists(path)) {
            allocator.free(path);
            break :blk null;
        }
        break :blk path;
    };
    errdefer if (artifact_meta_path) |path| allocator.free(path);

    const payload_dir = if (kind == .package_archive) null else blk: {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, "payload" });
        if (!dirExists(path)) {
            allocator.free(path);
            break :blk null;
        }
        break :blk path;
    };
    errdefer if (payload_dir) |path| allocator.free(path);

    const staging_dir = if (kind == .package_archive) blk: {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, "staging" });
        if (!dirExists(path)) {
            allocator.free(path);
            break :blk null;
        }
        break :blk path;
    } else null;
    errdefer if (staging_dir) |path| allocator.free(path);

    const archive_path = if (kind == .package_archive) blk: {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, "archive.pkg.tar.zst" });
        if (!fileExists(path)) {
            allocator.free(path);
            break :blk null;
        }
        break :blk path;
    } else null;
    errdefer if (archive_path) |path| allocator.free(path);

    const sidecar_meta_path = switch (kind) {
        .split_stage => blk: {
            const path = try std.fs.path.join(allocator, &.{ artifact_dir, "split-stage.kdl" });
            if (!fileExists(path)) {
                allocator.free(path);
                break :blk null;
            }
            break :blk path;
        },
        .package_archive => blk: {
            const path = try std.fs.path.join(allocator, &.{ artifact_dir, "package-archive.kdl" });
            if (!fileExists(path)) {
                allocator.free(path);
                break :blk null;
            }
            break :blk path;
        },
        else => null,
    };
    errdefer if (sidecar_meta_path) |path| allocator.free(path);

    return CacheInspection{
        .record = record,
        .key_path = try allocator.dupe(u8, key_path),
        .artifact_dir = artifact_dir,
        .artifact_meta_path = artifact_meta_path,
        .payload_dir = payload_dir,
        .staging_dir = staging_dir,
        .archive_path = archive_path,
        .sidecar_meta_path = sidecar_meta_path,
        .allocator = allocator,
    };
}

pub fn gc(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
) CacheError!GcResult {
    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);
    const io = path_mod.currentIo();
    if (!dirExists(cache_root)) return .{};

    const keys_root = try std.fs.path.join(allocator, &.{ cache_root, "keys" });
    defer allocator.free(keys_root);
    const artifacts_root = try std.fs.path.join(allocator, &.{ cache_root, "artifacts" });
    defer allocator.free(artifacts_root);

    var result = GcResult{};
    var referenced_artifacts = std.StringHashMap(void).init(allocator);
    defer {
        var it = referenced_artifacts.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        referenced_artifacts.deinit();
    }

    const all_kinds = [_]ArtifactKind{
        .source_fetch,
        .source_unpack,
        .profile_realize,
        .phase_run,
        .split_stage,
        .package_archive,
    };

    for (all_kinds) |kind| {
        const kind_keys_dir = try std.fs.path.join(allocator, &.{ keys_root, kind.asString() });
        defer allocator.free(kind_keys_dir);
        if (!dirExists(kind_keys_dir)) continue;

        var dir = path_mod.openExistingDir(kind_keys_dir) catch |err| {
            return mapFsError(err);
        };
        defer dir.close(io);

        var walker = dir.walk(allocator) catch |err| {
            return mapFsError(err);
        };
        defer walker.deinit();

        while (walker.next(io) catch |err| return mapFsError(err)) |entry| {
            if (entry.kind != .file) continue;

            const key_path = try std.fs.path.join(allocator, &.{ kind_keys_dir, entry.path });
            defer allocator.free(key_path);

            var record = readKeyRecord(allocator, kind, key_path) catch |err| {
                if (fileExists(key_path)) {
                    std.Io.Dir.deleteFileAbsolute(io, key_path) catch |delete_err| return mapFsError(delete_err);
                    result.removed_key_records += 1;
                }
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                }
            };
            defer record.deinit();

            const artifact_dir = try std.fs.path.join(allocator, &.{ artifacts_root, record.artifact_digest_hex });
            defer allocator.free(artifact_dir);
            if (!artifactPayloadExists(allocator, kind, artifact_dir)) {
                std.Io.Dir.deleteFileAbsolute(io, key_path) catch |err| return mapFsError(err);
                result.removed_key_records += 1;
                continue;
            }

            const digest_key = try allocator.dupe(u8, record.artifact_digest_hex);
            errdefer allocator.free(digest_key);
            referenced_artifacts.put(digest_key, {}) catch |err| {
                allocator.free(digest_key);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                };
            };
        }
    }

    if (!dirExists(artifacts_root)) return result;

    var artifacts_dir = path_mod.openExistingDir(artifacts_root) catch |err| {
        return mapFsError(err);
    };
    defer artifacts_dir.close(io);

    var artifact_iter = artifacts_dir.iterate();
    while (artifact_iter.next(io) catch |err| return mapFsError(err)) |entry| {
        if (entry.kind != .directory) continue;

        if (referenced_artifacts.contains(entry.name)) {
            result.retained_artifacts += 1;
            continue;
        }

        artifacts_dir.deleteTree(io, entry.name) catch |err| return mapFsError(err);
        result.removed_artifacts += 1;
    }

    return result;
}

fn buildCacheRoot(allocator: std.mem.Allocator, ctx: *mere.Context) CacheError![]const u8 {
    return std.fs.path.join(allocator, &.{ ctx.root(), "mere", "dev", "cache", "build" }) catch error.OutOfMemory;
}

fn artifactPayloadExists(allocator: std.mem.Allocator, kind: ArtifactKind, artifact_dir: []const u8) bool {
    return switch (kind) {
        .package_archive => blk: {
            const archive_path = std.fs.path.join(allocator, &.{ artifact_dir, "archive.pkg.tar.zst" }) catch return false;
            defer allocator.free(archive_path);
            break :blk fileExists(archive_path);
        },
        else => blk: {
            const payload_dir = std.fs.path.join(allocator, &.{ artifact_dir, "payload" }) catch return false;
            defer allocator.free(payload_dir);
            break :blk dirExists(payload_dir);
        },
    };
}

pub fn storeSplitStagingForKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    key_hex: []const u8,
    workspace_recipe_root: []const u8,
    staged_packages: []const split_staging.StagedPackage,
) CacheError!CacheRecord {
    const pkg_root = try std.fs.path.join(allocator, &.{ workspace_recipe_root, "pkg" });
    defer allocator.free(pkg_root);

    var record = try storeDirectoryForKey(allocator, ctx, .split_stage, key_hex, pkg_root, null);
    errdefer record.deinit();

    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);
    const metadata_path = try std.fs.path.join(allocator, &.{ cache_root, "artifacts", record.artifact_digest_hex, "split-stage.kdl" });
    defer allocator.free(metadata_path);
    try writeSplitStageMetadata(allocator, metadata_path, staged_packages);
    return record;
}

pub fn restoreSplitStagingForKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    key_hex: []const u8,
    workspace_recipe_root: []const u8,
    packages: []const recipe.BuildArtifact,
    staged_packages: *std.ArrayList(split_staging.StagedPackage),
) CacheError!?CacheRecord {
    const pkg_root = std.fs.path.join(allocator, &.{ workspace_recipe_root, "pkg" }) catch |err| {
        ctx.setDiagnosticContextFmt(workspace_recipe_root, "failed to build split-stage package root ({s})", .{@errorName(err)});
        return err;
    };
    defer allocator.free(pkg_root);

    var restored = try restoreDirectoryForKey(allocator, ctx, .split_stage, key_hex, pkg_root);
    if (restored == null) return null;
    defer restored.?.deinit();

    split_staging.clearStagedPackages(allocator, staged_packages);

    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);
    const metadata_path = std.fs.path.join(allocator, &.{ cache_root, "artifacts", restored.?.record.artifact_digest_hex, "split-stage.kdl" }) catch |err| {
        ctx.setDiagnosticContextFmt(cache_root, "failed to build split-stage metadata path for artifact {s} ({s})", .{ restored.?.record.artifact_digest_hex, @errorName(err) });
        return err;
    };
    defer allocator.free(metadata_path);
    readSplitStageMetadata(allocator, ctx, metadata_path, workspace_recipe_root, packages, staged_packages) catch |err| {
        const diag = ctx.getDiagnosticContext();
        if (diag.subject == null and diag.details == null) {
            ctx.setDiagnosticContextFmt(metadata_path, "failed to read split-stage metadata ({s})", .{@errorName(err)});
        }
        return err;
    };

    return CacheRecord{
        .kind = restored.?.record.kind,
        .key_hex = try allocator.dupe(u8, restored.?.record.key_hex),
        .artifact_digest_hex = try allocator.dupe(u8, restored.?.record.artifact_digest_hex),
        .actual_subpath = null,
        .allocator = allocator,
    };
}

pub fn storePackageArchiveForKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    key_hex: []const u8,
    staging_dir: []const u8,
    archive_path: []const u8,
    content_hash: []const u8,
    archive_hash: []const u8,
    signature: []const u8,
) CacheError!CacheRecord {
    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);

    const artifacts_root = try std.fs.path.join(allocator, &.{ cache_root, "artifacts" });
    defer allocator.free(artifacts_root);
    const keys_root = try std.fs.path.join(allocator, &.{ cache_root, "keys", ArtifactKind.package_archive.asString() });
    defer allocator.free(keys_root);
    try ensurePath(artifacts_root);
    try ensurePath(keys_root);

    const artifact_digest_hex = hash.calculateFileHash(allocator, archive_path) catch |err| return mapHashError(err);
    errdefer allocator.free(artifact_digest_hex);
    if (!std.mem.eql(u8, artifact_digest_hex, archive_hash)) {
        return error.InvalidInput;
    }

    const artifact_dir = try std.fs.path.join(allocator, &.{ artifacts_root, artifact_digest_hex });
    defer allocator.free(artifact_dir);
    const metadata_path = try std.fs.path.join(allocator, &.{ artifact_dir, "meta.kdl" });
    defer allocator.free(metadata_path);
    const staging_cache_dir = try std.fs.path.join(allocator, &.{ artifact_dir, "staging" });
    defer allocator.free(staging_cache_dir);
    const archive_cache_path = try std.fs.path.join(allocator, &.{ artifact_dir, "archive.pkg.tar.zst" });
    defer allocator.free(archive_cache_path);
    const package_meta_path = try std.fs.path.join(allocator, &.{ artifact_dir, "package-archive.kdl" });
    defer allocator.free(package_meta_path);

    if (!dirExists(artifact_dir)) {
        try ensurePath(artifact_dir);
        try writeArtifactMetadata(metadata_path, .package_archive, artifact_digest_hex);
        try copyTreeAtomic(allocator, ctx, staging_dir, staging_cache_dir);
        try copyFileReplace(archive_path, archive_cache_path);
        try writePackageArchiveMetadata(allocator, package_meta_path, std.fs.path.basename(archive_path), content_hash, archive_hash, signature);
    }

    const key_path = try std.fs.path.join(allocator, &.{ keys_root, keyHexFilename(key_hex) });
    defer allocator.free(key_path);
    try writeKeyRecord(allocator, key_path, .package_archive, key_hex, artifact_digest_hex, null);

    return CacheRecord{
        .kind = .package_archive,
        .key_hex = try allocator.dupe(u8, key_hex),
        .artifact_digest_hex = artifact_digest_hex,
        .actual_subpath = null,
        .allocator = allocator,
    };
}

pub fn restorePackageArchiveForKey(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    key_hex: []const u8,
    staging_dir: []const u8,
    output_dir: []const u8,
) CacheError!?RestoredPackageArchive {
    const cache_root = try buildCacheRoot(allocator, ctx);
    defer allocator.free(cache_root);

    const keys_root = try std.fs.path.join(allocator, &.{ cache_root, "keys", ArtifactKind.package_archive.asString() });
    defer allocator.free(keys_root);
    const key_path = try std.fs.path.join(allocator, &.{ keys_root, keyHexFilename(key_hex) });
    defer allocator.free(key_path);
    if (!fileExists(key_path)) return null;

    var record = try readKeyRecord(allocator, .package_archive, key_path);
    errdefer record.deinit();

    const artifact_dir = try std.fs.path.join(allocator, &.{ cache_root, "artifacts", record.artifact_digest_hex });
    defer allocator.free(artifact_dir);
    const staging_cache_dir = try std.fs.path.join(allocator, &.{ artifact_dir, "staging" });
    defer allocator.free(staging_cache_dir);
    const archive_cache_path = try std.fs.path.join(allocator, &.{ artifact_dir, "archive.pkg.tar.zst" });
    defer allocator.free(archive_cache_path);
    const package_meta_path = try std.fs.path.join(allocator, &.{ artifact_dir, "package-archive.kdl" });
    defer allocator.free(package_meta_path);

    if (!dirExists(staging_cache_dir) or !fileExists(archive_cache_path)) return null;

    try replaceTreeFromCache(allocator, ctx, staging_cache_dir, staging_dir);
    const meta = try readPackageArchiveMetadata(allocator, package_meta_path);
    errdefer {
        allocator.free(meta.archive_basename);
        allocator.free(meta.content_hash);
        allocator.free(meta.signature);
    }

    const archive_path = try std.fs.path.join(allocator, &.{ output_dir, meta.archive_basename });
    errdefer allocator.free(archive_path);
    try copyFileReplace(archive_cache_path, archive_path);

    allocator.free(meta.archive_basename);

    return RestoredPackageArchive{
        .record = record,
        .archive_path = archive_path,
        .content_hash = meta.content_hash,
        .archive_hash = meta.archive_hash,
        .signature = meta.signature,
    };
}

fn keyHexFilename(key_hex: []const u8) []const u8 {
    return key_hex;
}

fn appendRecipeVars(
    writer: *std.Io.Writer,
    parsed_recipe: *const recipe.Recipe,
) CacheError!void {
    writer.writeAll("vars\n") catch return error.OutOfMemory;
    for (parsed_recipe.vars.items) |kv| {
        writer.print("{s}={s}\n", .{ kv.key, kv.value }) catch return error.OutOfMemory;
    }
}

fn appendKvList(
    writer: *std.Io.Writer,
    prefix: []const u8,
    kvs: []const recipe.KV,
) CacheError!void {
    for (kvs) |kv| {
        writer.print("{s}.{s}={s}\n", .{ prefix, kv.key, kv.value }) catch return error.OutOfMemory;
    }
}

fn appendSourceInputs(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    writer: *std.Io.Writer,
    recipe_dir: []const u8,
    parsed_recipe: *const recipe.Recipe,
) CacheError!void {
    const vars_ptr = if (parsed_recipe.vars.items.len > 0) &parsed_recipe.vars else null;
    for (parsed_recipe.sources.items, 0..) |src, idx| {
        const expanded = recipe.interpolate(allocator, ctx, src.url, parsed_recipe, vars_ptr) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidInput,
            };
        };
        defer allocator.free(expanded);

        writer.print("source[{d}].url={s}\n", .{ idx, expanded }) catch return error.OutOfMemory;
        writer.print("source[{d}].blake3={s}\n", .{ idx, src.blake3 orelse "" }) catch return error.OutOfMemory;
        writer.print("source[{d}].save_as={s}\n", .{ idx, src.save_as orelse "" }) catch return error.OutOfMemory;

        if (std.mem.indexOf(u8, expanded, "://") == null and recipe_dir.len > 0) {
            const local_path = try std.fs.path.join(allocator, &.{ recipe_dir, expanded });
            defer allocator.free(local_path);
            const file_hash = hash.calculateFileHash(allocator, local_path) catch |err| {
                return mapHashError(err);
            };
            defer allocator.free(file_hash);
            writer.print("source[{d}].local_hash={s}\n", .{ idx, file_hash }) catch return error.OutOfMemory;
        }
    }
}

fn appendRecipeCompanionInputs(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    recipe_dir: []const u8,
) CacheError!void {
    if (recipe_dir.len == 0) {
        writer.writeAll("companions=none\n") catch return error.OutOfMemory;
        return;
    }

    const io = path_mod.currentIo();
    var dir = path_mod.openExistingDir(recipe_dir) catch |err| {
        return mapFsError(err);
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch |err| {
            return mapFsError(err);
        } orelse break;

        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (std.mem.eql(u8, entry.name, "recipe.kdl")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, lessThan);

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (names.items) |name| {
        const abs_path = try std.fs.path.join(allocator, &.{ recipe_dir, name });
        defer allocator.free(abs_path);

        if (std.Io.Dir.readLinkAbsolute(io, abs_path, &target_buf)) |target_len| {
            writer.print("companion.symlink.{s}={s}\n", .{ name, target_buf[0..target_len] }) catch return error.OutOfMemory;
            continue;
        } else |_| {}

        const file_hash = hash.calculateFileHash(allocator, abs_path) catch |err| {
            return mapHashError(err);
        };
        defer allocator.free(file_hash);
        writer.print("companion.file.{s}={s}\n", .{ name, file_hash }) catch return error.OutOfMemory;
    }
}

fn computeActualSubpath(
    allocator: std.mem.Allocator,
    src_dir: []const u8,
    actual_path: ?[]const u8,
) CacheError!?[]const u8 {
    const ap = actual_path orelse return null;
    if (std.mem.eql(u8, ap, src_dir)) return null;
    if (!std.mem.startsWith(u8, ap, src_dir)) return error.InvalidInput;
    if (ap.len <= src_dir.len + 1) return error.InvalidInput;
    return allocator.dupe(u8, ap[src_dir.len + 1 ..]) catch error.OutOfMemory;
}

fn ensurePath(path: []const u8) CacheError!void {
    var dir = path_mod.makePathAndOpenDir(path) catch |err| return mapFsError(err);
    dir.close(path_mod.currentIo());
}

fn dirExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), path, .{}) catch return false;
    return true;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), path, .{}) catch return false;
    return true;
}

fn writeArtifactMetadata(
    metadata_path: []const u8,
    kind: ArtifactKind,
    artifact_digest_hex: []const u8,
) CacheError!void {
    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, metadata_path, .{ .truncate = true }) catch |err| {
        return mapFsError(err);
    };
    defer file.close(io);

    var buf: [384]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "kind \"{s}\"\nartifact_digest \"{s}\"\ncreated_at_unix {d}\n", .{
        kind.asString(),
        artifact_digest_hex,
        std.Io.Clock.real.now(io).toSeconds(),
    }) catch {
        return error.OutOfMemory;
    };
    file.writeStreamingAll(io, content) catch |err| {
        return mapFsError(err);
    };
}

fn writeSplitStageMetadata(
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    staged_packages: []const split_staging.StagedPackage,
) CacheError!void {
    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, metadata_path, .{ .truncate = true }) catch |err| {
        return mapFsError(err);
    };
    defer file.close(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;

    for (staged_packages) |staged| {
        out.print("package {d}\n", .{staged.pkg_index}) catch return error.OutOfMemory;
        for (staged.copied_files) |rel_path| {
            out.print("file \"{s}\"\n", .{rel_path}) catch return error.OutOfMemory;
        }
    }

    buf = out_buf.toArrayList();
    file.writeStreamingAll(io, buf.items) catch |err| {
        return mapFsError(err);
    };
}

fn writePackageArchiveMetadata(
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    archive_basename: []const u8,
    content_hash: []const u8,
    archive_hash: []const u8,
    signature: []const u8,
) CacheError!void {
    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, metadata_path, .{ .truncate = true }) catch |err| {
        return mapFsError(err);
    };
    defer file.close(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;
    const signature_hex = std.fmt.allocPrint(allocator, "{x}", .{signature}) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(signature_hex);
    out.print("archive \"{s}\"\n", .{archive_basename}) catch return error.OutOfMemory;
    out.print("content_hash \"{s}\"\n", .{content_hash}) catch return error.OutOfMemory;
    out.print("archive_hash \"{s}\"\n", .{archive_hash}) catch return error.OutOfMemory;
    out.print("signature_hex \"{s}\"\n", .{signature_hex}) catch return error.OutOfMemory;
    out.print("created_at_unix {d}\n", .{std.Io.Clock.real.now(io).toSeconds()}) catch return error.OutOfMemory;

    buf = out_buf.toArrayList();
    file.writeStreamingAll(io, buf.items) catch |err| {
        return mapFsError(err);
    };
}

fn writeKeyRecord(
    allocator: std.mem.Allocator,
    key_path: []const u8,
    kind: ArtifactKind,
    key_hex: []const u8,
    artifact_digest_hex: []const u8,
    actual_subpath: ?[]const u8,
) CacheError!void {
    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, key_path, .{ .truncate = true }) catch |err| {
        return mapFsError(err);
    };
    defer file.close(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var out_buf: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const out = &out_buf.writer;
    out.print("kind \"{s}\"\n", .{kind.asString()}) catch return error.OutOfMemory;
    out.print("key \"{s}\"\n", .{key_hex}) catch return error.OutOfMemory;
    out.print("artifact_digest \"{s}\"\n", .{artifact_digest_hex}) catch return error.OutOfMemory;
    out.print("recorded_at_unix {d}\n", .{std.Io.Clock.real.now(io).toSeconds()}) catch return error.OutOfMemory;
    if (actual_subpath) |subpath| {
        out.print("actual_subpath \"{s}\"\n", .{subpath}) catch return error.OutOfMemory;
    }
    buf = out_buf.toArrayList();
    file.writeStreamingAll(io, buf.items) catch |err| {
        return mapFsError(err);
    };
}

fn readKeyRecord(
    allocator: std.mem.Allocator,
    kind: ArtifactKind,
    key_path: []const u8,
) CacheError!CacheRecord {
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(key_path) catch |err| return mapFsError(err);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const content = reader.interface.allocRemaining(allocator, .limited(4096)) catch |err| return mapFsError(err);
    defer allocator.free(content);

    var file_kind: ?[]const u8 = null;
    var key_hex: ?[]const u8 = null;
    var artifact_digest_hex: ?[]const u8 = null;
    var actual_subpath: ?[]const u8 = null;

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "kind ")) {
            file_kind = try parseQuotedValue(allocator, line);
        } else if (std.mem.startsWith(u8, line, "key ")) {
            key_hex = try parseQuotedValue(allocator, line);
        } else if (std.mem.startsWith(u8, line, "artifact_digest ")) {
            artifact_digest_hex = try parseQuotedValue(allocator, line);
        } else if (std.mem.startsWith(u8, line, "actual_subpath ")) {
            actual_subpath = try parseQuotedValue(allocator, line);
        }
    }

    errdefer {
        if (file_kind) |value| allocator.free(value);
        if (key_hex) |value| allocator.free(value);
        if (artifact_digest_hex) |value| allocator.free(value);
        if (actual_subpath) |value| allocator.free(value);
    }

    const parsed_kind = file_kind orelse return error.InvalidInput;
    defer allocator.free(parsed_kind);
    if (!std.mem.eql(u8, parsed_kind, kind.asString())) return error.InvalidInput;

    return CacheRecord{
        .kind = kind,
        .key_hex = key_hex orelse return error.InvalidInput,
        .artifact_digest_hex = artifact_digest_hex orelse return error.InvalidInput,
        .actual_subpath = actual_subpath,
        .allocator = allocator,
    };
}

fn readSplitStageMetadata(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    metadata_path: []const u8,
    workspace_recipe_root: []const u8,
    packages: []const recipe.BuildArtifact,
    staged_packages: *std.ArrayList(split_staging.StagedPackage),
) CacheError!void {
    const io = path_mod.currentIo();
    var file = std.Io.Dir.openFileAbsolute(io, metadata_path, .{}) catch |err| {
        ctx.setDiagnosticContextFmt(metadata_path, "failed to read split-stage metadata ({s})", .{@errorName(err)});
        return mapFsError(err);
    };
    defer file.close(io);

    var read_buffer: [1024 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);

    var current_pkg_index: ?usize = null;
    var current_copied: std.ArrayList([]const u8) = .empty;
    defer {
        for (current_copied.items) |item| allocator.free(item);
        current_copied.deinit(allocator);
    }

    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| {
            ctx.setDiagnosticContextFmt(metadata_path, "failed to read split-stage metadata line ({s})", .{@errorName(err)});
            return mapFsError(err);
        };
        if (line == null) break;
        const trimmed = std.mem.trimEnd(u8, line.?, "\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "package ")) {
            if (current_pkg_index) |pkg_index| {
                appendRestoredStagedPackage(allocator, ctx, metadata_path, workspace_recipe_root, packages, pkg_index, &current_copied, staged_packages) catch |err| {
                    return err;
                };
                freeCopiedFileList(allocator, &current_copied);
            }
            current_pkg_index = parsePackageIndex(trimmed["package ".len..]) catch |err| {
                ctx.setDiagnosticContextFmt(metadata_path, "failed to parse split-stage package index from line '{s}' ({s})", .{ trimmed, @errorName(err) });
                return err;
            };
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "file ")) {
            const rel_path = parseQuotedValue(allocator, trimmed) catch |err| {
                ctx.setDiagnosticContextFmt(metadata_path, "failed to parse split-stage file entry from line '{s}' ({s})", .{ trimmed, @errorName(err) });
                return err;
            };
            current_copied.append(allocator, rel_path) catch |err| {
                allocator.free(rel_path);
                ctx.setDiagnosticContextFmt(metadata_path, "failed to append split-stage file entry '{s}' ({s})", .{ rel_path, @errorName(err) });
                return err;
            };
        }
    }

    if (current_pkg_index) |pkg_index| {
        appendRestoredStagedPackage(allocator, ctx, metadata_path, workspace_recipe_root, packages, pkg_index, &current_copied, staged_packages) catch |err| {
            return err;
        };
        freeCopiedFileList(allocator, &current_copied);
    }
}

const PackageArchiveMetadata = struct {
    archive_basename: []const u8,
    content_hash: []const u8,
    archive_hash: []const u8,
    signature: []u8,
};

fn readPackageArchiveMetadata(
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
) CacheError!PackageArchiveMetadata {
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(metadata_path) catch |err| return mapFsError(err);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const content = reader.interface.allocRemaining(allocator, .limited(16 * 1024)) catch |err| return mapFsError(err);
    defer allocator.free(content);

    var archive_basename: ?[]const u8 = null;
    var content_hash: ?[]const u8 = null;
    var archive_hash: ?[]const u8 = null;
    var signature_hex: ?[]const u8 = null;
    errdefer {
        if (archive_basename) |value| allocator.free(value);
        if (content_hash) |value| allocator.free(value);
        if (archive_hash) |value| allocator.free(value);
        if (signature_hex) |value| allocator.free(value);
    }

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "archive ")) {
            archive_basename = try parseQuotedValue(allocator, line);
        } else if (std.mem.startsWith(u8, line, "content_hash ")) {
            content_hash = try parseQuotedValue(allocator, line);
        } else if (std.mem.startsWith(u8, line, "archive_hash ")) {
            archive_hash = try parseQuotedValue(allocator, line);
        } else if (std.mem.startsWith(u8, line, "signature_hex ")) {
            signature_hex = try parseQuotedValue(allocator, line);
        }
    }

    const sig_hex = signature_hex orelse return error.InvalidInput;
    defer allocator.free(sig_hex);
    if (sig_hex.len % 2 != 0) return error.InvalidInput;
    const signature = try allocator.alloc(u8, sig_hex.len / 2);
    errdefer allocator.free(signature);
    _ = std.fmt.hexToBytes(signature, sig_hex) catch return error.InvalidInput;

    return PackageArchiveMetadata{
        .archive_basename = archive_basename orelse return error.InvalidInput,
        .content_hash = content_hash orelse return error.InvalidInput,
        .archive_hash = archive_hash orelse return error.InvalidInput,
        .signature = signature,
    };
}

fn appendRestoredStagedPackage(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    metadata_path: []const u8,
    workspace_recipe_root: []const u8,
    packages: []const recipe.BuildArtifact,
    pkg_index: usize,
    current_copied: *std.ArrayList([]const u8),
    staged_packages: *std.ArrayList(split_staging.StagedPackage),
) CacheError!void {
    if (pkg_index >= packages.len) {
        ctx.setDiagnosticContextFmt(metadata_path, "split-stage metadata references missing package index {d}", .{pkg_index});
        return error.InvalidInput;
    }

    const pkg_name = if (packages[pkg_index].name.len > 0) packages[pkg_index].name else "pkg";
    const staging_dir = std.fs.path.join(allocator, &.{ workspace_recipe_root, "pkg", pkg_name }) catch |err| {
        ctx.setDiagnosticContextFmt(workspace_recipe_root, "failed to build restored staging dir for package '{s}' ({s})", .{ pkg_name, @errorName(err) });
        return err;
    };
    errdefer allocator.free(staging_dir);

    const copied_files = allocator.alloc([]const u8, current_copied.items.len) catch |err| {
        ctx.setDiagnosticContextFmt(metadata_path, "failed to allocate restored copied-file list for package '{s}' ({s})", .{ pkg_name, @errorName(err) });
        return err;
    };
    var copied_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied_count) : (i += 1) allocator.free(copied_files[i]);
        allocator.free(copied_files);
    }
    for (current_copied.items, 0..) |rel_path, idx| {
        copied_files[idx] = allocator.dupe(u8, rel_path) catch |err| {
            ctx.setDiagnosticContextFmt(metadata_path, "failed to copy restored file entry '{s}' for package '{s}' ({s})", .{ rel_path, pkg_name, @errorName(err) });
            return err;
        };
        copied_count += 1;
    }

    staged_packages.append(allocator, .{
        .pkg_index = pkg_index,
        .staging_dir = staging_dir,
        .copied_files = copied_files,
    }) catch |err| {
        ctx.setDiagnosticContextFmt(metadata_path, "failed to append restored staged package '{s}' ({s})", .{ pkg_name, @errorName(err) });
        return err;
    };
}

fn parsePackageIndex(value: []const u8) CacheError!usize {
    return std.fmt.parseInt(usize, value, 10) catch error.InvalidInput;
}

fn freeCopiedFileList(allocator: std.mem.Allocator, copied: *std.ArrayList([]const u8)) void {
    for (copied.items) |item| allocator.free(item);
    copied.clearRetainingCapacity();
}

fn computeSigningKeyHash(allocator: std.mem.Allocator, ctx: *mere.Context) CacheError![]const u8 {
    const key_path = ctx.signing_key_path orelse blk: {
        const home = ctx.home_dir orelse return error.InvalidInput;
        break :blk try std.fmt.allocPrint(allocator, "{s}/.mere/keys/mere.key", .{home});
    };
    const owns_key_path = ctx.signing_key_path == null;
    defer if (owns_key_path) allocator.free(key_path);
    return hash.calculateFileHash(allocator, key_path) catch |err| {
        return mapHashError(err);
    };
}

fn copyFileReplace(src_path: []const u8, dest_path: []const u8) CacheError!void {
    const dest_parent = std.fs.path.dirname(dest_path) orelse return error.InvalidInput;
    const io = path_mod.currentIo();
    try ensurePath(dest_parent);
    std.Io.Dir.deleteFileAbsolute(io, dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return mapFsError(err),
    };
    std.Io.Dir.copyFileAbsolute(src_path, dest_path, io, .{}) catch |err| {
        return mapFsError(err);
    };
    try copyFileTimes(src_path, dest_path);
}

fn parseQuotedValue(allocator: std.mem.Allocator, line: []const u8) CacheError![]const u8 {
    const first = std.mem.indexOfScalar(u8, line, '"') orelse return error.InvalidInput;
    const rest = line[first + 1 ..];
    const last = std.mem.indexOfScalar(u8, rest, '"') orelse return error.InvalidInput;
    return allocator.dupe(u8, rest[0..last]) catch error.OutOfMemory;
}

fn replaceTreeFromCache(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    src_dir: []const u8,
    dest_dir: []const u8,
) CacheError!void {
    const parent_dir = std.fs.path.dirname(dest_dir) orelse return error.InvalidInput;
    const io = path_mod.currentIo();
    ensurePath(parent_dir) catch |err| {
        ctx.setDiagnosticContextFmt(parent_dir, "failed to create parent dir for cache restore ({s})", .{@errorName(err)});
        return err;
    };

    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes[0..], .lower);
    const tmp_dir = std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ dest_dir, rand_hex }) catch |err| {
        ctx.setDiagnosticContextFmt(dest_dir, "failed to allocate temporary cache restore dir path ({s})", .{@errorName(err)});
        return error.OutOfMemory;
    };
    defer allocator.free(tmp_dir);
    errdefer {
        if (std.fs.path.dirname(tmp_dir)) |tmp_parent| {
            const tmp_base = std.fs.path.basename(tmp_dir);
            if (path_mod.openExistingDir(tmp_parent)) |parent| {
                var owned = parent;
                defer owned.close(io);
                owned.deleteTree(io, tmp_base) catch {};
            } else |_| {}
        }
    }

    if (dirExists(tmp_dir)) {
        const tmp_parent = std.fs.path.dirname(tmp_dir) orelse return error.InvalidInput;
        const tmp_base = std.fs.path.basename(tmp_dir);
        var parent = path_mod.openExistingDir(tmp_parent) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidInput,
            else => return mapFsError(err),
        };
        defer parent.close(io);
        parent.deleteTree(io, tmp_base) catch |err| {
            ctx.setDiagnosticContextFmt(tmp_dir, "failed to clear stale temporary cache restore dir ({s})", .{@errorName(err)});
            return mapFsError(err);
        };
    }
    ensurePath(tmp_dir) catch |err| {
        ctx.setDiagnosticContextFmt(tmp_dir, "failed to create temporary cache restore dir ({s})", .{@errorName(err)});
        return err;
    };
    try copyTreeContents(allocator, ctx, src_dir, tmp_dir);

    if (!dirExists(dest_dir)) {
        std.Io.Dir.renameAbsolute(tmp_dir, dest_dir, io) catch |err| {
            ctx.setDiagnosticContextFmt(dest_dir, "failed to publish restored cache dir ({s})", .{@errorName(err)});
            return mapFsError(err);
        };
        return;
    }

    try exchangePaths(allocator, dest_dir, tmp_dir);
    {
        const tmp_parent = std.fs.path.dirname(tmp_dir) orelse return error.InvalidInput;
        const tmp_base = std.fs.path.basename(tmp_dir);
        var parent = path_mod.openExistingDir(tmp_parent) catch |err| return mapFsError(err);
        defer parent.close(io);
        parent.deleteTree(io, tmp_base) catch |err| {
            ctx.setDiagnosticContextFmt(tmp_dir, "failed to clean replaced cache restore temp dir ({s})", .{@errorName(err)});
            return mapFsError(err);
        };
    }
}

fn copyTreeAtomic(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    src_dir: []const u8,
    dest_dir: []const u8,
) CacheError!void {
    const parent_dir = std.fs.path.dirname(dest_dir) orelse return error.InvalidInput;
    const io = path_mod.currentIo();
    ensurePath(parent_dir) catch |err| {
        ctx.setDiagnosticContextFmt(parent_dir, "failed to create parent dir for cache tree copy ({s})", .{@errorName(err)});
        return err;
    };

    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes[0..], .lower);
    const tmp_dir = std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ dest_dir, rand_hex }) catch |err| {
        ctx.setDiagnosticContextFmt(dest_dir, "failed to allocate temporary cache dir path ({s})", .{@errorName(err)});
        return error.OutOfMemory;
    };
    defer allocator.free(tmp_dir);
    errdefer {
        if (std.fs.path.dirname(tmp_dir)) |tmp_parent| {
            const tmp_base = std.fs.path.basename(tmp_dir);
            if (path_mod.openExistingDir(tmp_parent)) |parent| {
                var owned = parent;
                defer owned.close(io);
                owned.deleteTree(io, tmp_base) catch {};
            } else |_| {}
        }
    }

    if (dirExists(tmp_dir)) {
        const tmp_parent = std.fs.path.dirname(tmp_dir) orelse return error.InvalidInput;
        const tmp_base = std.fs.path.basename(tmp_dir);
        var parent = path_mod.openExistingDir(tmp_parent) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidInput,
            else => return mapFsError(err),
        };
        defer parent.close(io);
        parent.deleteTree(io, tmp_base) catch |err| {
            ctx.setDiagnosticContextFmt(tmp_dir, "failed to clear stale temporary cache dir ({s})", .{@errorName(err)});
            return mapFsError(err);
        };
    }
    ensurePath(tmp_dir) catch |err| {
        ctx.setDiagnosticContextFmt(tmp_dir, "failed to create temporary cache dir ({s})", .{@errorName(err)});
        return err;
    };
    copyTreeContents(allocator, ctx, src_dir, tmp_dir) catch |err| {
        return err;
    };
    std.Io.Dir.renameAbsolute(tmp_dir, dest_dir, io) catch |err| {
        ctx.setDiagnosticContextFmt(dest_dir, "failed to publish temporary cache dir ({s})", .{@errorName(err)});
        return mapFsError(err);
    };
}

fn copyTreeContents(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    src_dir: []const u8,
    dest_dir: []const u8,
) CacheError!void {
    ensurePath(dest_dir) catch |err| {
        ctx.setDiagnosticContextFmt(dest_dir, "failed to create destination dir for cache tree copy ({s})", .{@errorName(err)});
        return err;
    };

    const src_contents = std.fs.path.join(allocator, &.{ src_dir, "." }) catch |err| {
        ctx.setDiagnosticContextFmt(src_dir, "failed to build source path for cache tree copy ({s})", .{@errorName(err)});
        return error.OutOfMemory;
    };
    defer allocator.free(src_contents);

    var child = std.process.spawn(path_mod.currentIo(), .{
        .argv = &.{ "/bin/cp", "-a", src_contents, dest_dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            ctx.setDiagnosticContextFmt(src_dir, "failed to spawn cache tree copy process ({s})", .{@errorName(err)});
            return error.OutOfMemory;
        },
        else => {
            ctx.setDiagnosticContextFmt(src_dir, "failed to spawn cache tree copy process ({s})", .{@errorName(err)});
            return error.FileSystem;
        },
    };
    defer child.kill(path_mod.currentIo());

    switch (child.wait(path_mod.currentIo()) catch |err| switch (err) {
        else => {
            ctx.setDiagnosticContextFmt(src_dir, "failed while waiting for cache tree copy process ({s})", .{@errorName(err)});
            return error.FileSystem;
        },
    }) {
        .exited => |code| {
            if (code != 0) {
                ctx.setDiagnosticContextFmt(src_dir, "cache tree copy process exited with status {d}", .{code});
                return error.FileSystem;
            }
        },
        else => {
            ctx.setDiagnosticContext(src_dir, "cache tree copy process terminated abnormally");
            return error.FileSystem;
        },
    }
}

fn copyFileTimes(src_path: []const u8, dest_path: []const u8) CacheError!void {
    const io = path_mod.currentIo();
    var src_file = std.Io.Dir.openFileAbsolute(io, src_path, .{}) catch |err| {
        return mapFsError(err);
    };
    defer src_file.close(io);
    const stat = src_file.stat(io) catch |err| {
        return mapFsError(err);
    };

    var dest_file = std.Io.Dir.openFileAbsolute(io, dest_path, .{ .mode = .read_write }) catch |err| {
        return mapFsError(err);
    };
    defer dest_file.close(io);
    dest_file.setTimestamps(io, .{
        .access_timestamp = .init(stat.atime),
        .modify_timestamp = .init(stat.mtime),
    }) catch |err| {
        return mapFsError(err);
    };
}

fn exchangePaths(allocator: std.mem.Allocator, left_path: []const u8, right_path: []const u8) CacheError!void {
    const left_z = allocator.dupeZ(u8, left_path) catch return error.OutOfMemory;
    defer allocator.free(left_z);
    const right_z = allocator.dupeZ(u8, right_path) catch return error.OutOfMemory;
    defer allocator.free(right_z);

    switch (std.posix.errno(std.os.linux.renameat2(
        std.os.linux.AT.FDCWD,
        left_z,
        std.os.linux.AT.FDCWD,
        right_z,
        .{ .EXCHANGE = true },
    ))) {
        .SUCCESS => {},
        .ACCES => return error.PermissionDenied,
        .BUSY => return error.FileSystem,
        .EXIST => return error.FileSystem,
        .INVAL => return error.InvalidInput,
        .IO => return error.FileSystem,
        .ISDIR => return error.InvalidInput,
        .LOOP => return error.InvalidInput,
        .MLINK => return error.FileSystem,
        .NAMETOOLONG => return error.InvalidInput,
        .NOENT => return error.InvalidInput,
        .NOSPC => return error.FileSystem,
        .NOTDIR => return error.InvalidInput,
        .PERM => return error.PermissionDenied,
        .ROFS => return error.PermissionDenied,
        .XDEV => return error.InvalidInput,
        else => return error.FileSystem,
    }
}

fn nsToTimespec(ns: i128) std.posix.timespec {
    return .{
        .sec = std.math.cast(isize, @divFloor(ns, std.time.ns_per_s)) orelse std.math.maxInt(isize),
        .nsec = std.math.cast(isize, @mod(ns, std.time.ns_per_s)) orelse std.math.maxInt(isize),
    };
}

fn mapHashError(err: anyerror) CacheError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PermissionDenied => error.PermissionDenied,
        error.InvalidInput => error.InvalidInput,
        else => error.FileSystem,
    };
}

fn mapFsError(err: anyerror) CacheError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied => error.PermissionDenied,
        error.BadPathName, error.NameTooLong, error.InvalidUtf8 => error.InvalidInput,
        else => error.FileSystem,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "build_cache stores and restores a source tree" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const src_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "src-tree" });
    defer test_env.ctx.allocator.free(src_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(src_dir);
        dir.close(io);
    }

    const src_file = try std.fs.path.join(test_env.ctx.allocator, &.{ src_dir, "hello.txt" });
    defer test_env.ctx.allocator.free(src_file);
    var file = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "hello");

    var record = try storeDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_fetch, "fetch-key", src_dir, null);
    defer record.deinit();

    const restore_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "restored-tree" });
    defer test_env.ctx.allocator.free(restore_dir);

    var restored = (try restoreDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_fetch, "fetch-key", restore_dir)).?;
    defer restored.deinit();

    const restored_file = try std.fs.path.join(test_env.ctx.allocator, &.{ restore_dir, "hello.txt" });
    defer test_env.ctx.allocator.free(restored_file);
    const content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, restored_file, test_env.ctx.allocator, .limited(64));
    defer test_env.ctx.allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "build_cache restores unpacked actual source subpath" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const src_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "unpacked-tree" });
    defer test_env.ctx.allocator.free(src_dir);
    const nested_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ src_dir, "pkg-1.0" });
    defer test_env.ctx.allocator.free(nested_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(nested_dir);
        dir.close(io);
    }

    const src_file = try std.fs.path.join(test_env.ctx.allocator, &.{ nested_dir, "hello.txt" });
    defer test_env.ctx.allocator.free(src_file);
    var file = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "nested");

    var record = try storeDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_unpack, "unpack-key", src_dir, nested_dir);
    defer record.deinit();

    const restore_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "restored-unpack" });
    defer test_env.ctx.allocator.free(restore_dir);

    var restored = (try restoreDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_unpack, "unpack-key", restore_dir)).?;
    defer restored.deinit();

    try std.testing.expect(restored.actual_path != null);
    const expected = try std.fs.path.join(test_env.ctx.allocator, &.{ restore_dir, "pkg-1.0" });
    defer test_env.ctx.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, restored.actual_path.?);
}

test "build_cache restore replaces existing destination tree" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const src_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "replace-src-tree" });
    defer test_env.ctx.allocator.free(src_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(src_dir);
        dir.close(io);
    }

    const src_file = try std.fs.path.join(test_env.ctx.allocator, &.{ src_dir, "fresh.txt" });
    defer test_env.ctx.allocator.free(src_file);
    var src_handle = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
    defer src_handle.close(io);
    try src_handle.writeStreamingAll(io, "fresh");

    var record = try storeDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_fetch, "replace-key", src_dir, null);
    defer record.deinit();

    const restore_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "replace-dest-tree" });
    defer test_env.ctx.allocator.free(restore_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(restore_dir);
        dir.close(io);
    }

    const stale_file = try std.fs.path.join(test_env.ctx.allocator, &.{ restore_dir, "stale.txt" });
    defer test_env.ctx.allocator.free(stale_file);
    var stale_handle = try std.Io.Dir.createFileAbsolute(io, stale_file, .{});
    defer stale_handle.close(io);
    try stale_handle.writeStreamingAll(io, "stale");

    var restored = (try restoreDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_fetch, "replace-key", restore_dir)).?;
    defer restored.deinit();

    const restored_file = try std.fs.path.join(test_env.ctx.allocator, &.{ restore_dir, "fresh.txt" });
    defer test_env.ctx.allocator.free(restored_file);
    const content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, restored_file, test_env.ctx.allocator, .limited(64));
    defer test_env.ctx.allocator.free(content);
    try std.testing.expectEqualStrings("fresh", content);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, stale_file, .{}));
}

test "build_cache restores split-stage metadata larger than 64 KiB" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "large-split"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "large-split" { files "usr/share/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();
    const io = path_mod.currentIo();

    const workspace_root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "workspace-large-split" });
    defer test_env.ctx.allocator.free(workspace_root);
    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_root, "pkg", "large-split" });
    defer test_env.ctx.allocator.free(staging_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(staging_dir);
        dir.close(io);
    }

    const staged_file = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "payload.txt" });
    defer test_env.ctx.allocator.free(staged_file);
    var file = try std.Io.Dir.createFileAbsolute(io, staged_file, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "payload");

    const copied_count: usize = 6000;
    var copied_files = try test_env.ctx.allocator.alloc([]const u8, copied_count);
    errdefer {
        for (copied_files) |rel_path| test_env.ctx.allocator.free(rel_path);
        test_env.ctx.allocator.free(copied_files);
    }
    for (0..copied_count) |i| {
        copied_files[i] = try std.fmt.allocPrint(test_env.ctx.allocator, "usr/share/path-{d}-with-extra-padding-to-grow-metadata.txt", .{i});
    }

    var staged_packages: std.ArrayList(split_staging.StagedPackage) = .empty;
    defer {
        split_staging.clearStagedPackages(test_env.ctx.allocator, &staged_packages);
        staged_packages.deinit(test_env.ctx.allocator);
    }
    try staged_packages.append(test_env.ctx.allocator, .{
        .pkg_index = 0,
        .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
        .copied_files = copied_files,
    });

    var stored = try storeSplitStagingForKey(
        test_env.ctx.allocator,
        &test_env.ctx,
        "large-split-key",
        workspace_root,
        staged_packages.items,
    );
    defer stored.deinit();

    split_staging.clearStagedPackages(test_env.ctx.allocator, &staged_packages);

    var restored_packages: std.ArrayList(split_staging.StagedPackage) = .empty;
    defer {
        split_staging.clearStagedPackages(test_env.ctx.allocator, &restored_packages);
        restored_packages.deinit(test_env.ctx.allocator);
    }

    var restored = try restoreSplitStagingForKey(
        test_env.ctx.allocator,
        &test_env.ctx,
        "large-split-key",
        workspace_root,
        parsed.packages.items,
        &restored_packages,
    );
    defer if (restored) |*hit| hit.deinit();

    try std.testing.expect(restored != null);
    try std.testing.expectEqual(@as(usize, 1), restored_packages.items.len);
    try std.testing.expectEqual(copied_count, restored_packages.items[0].copied_files.len);
    try std.testing.expectEqualStrings(
        "usr/share/path-0-with-extra-padding-to-grow-metadata.txt",
        restored_packages.items[0].copied_files[0],
    );
    try std.testing.expectEqualStrings(
        "usr/share/path-5999-with-extra-padding-to-grow-metadata.txt",
        restored_packages.items[0].copied_files[copied_count - 1],
    );
}

test "build_cache gc removes stale key records for missing artifacts" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const src_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "gc-src" });
    defer test_env.ctx.allocator.free(src_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(src_dir);
        dir.close(io);
    }

    const src_file = try std.fs.path.join(test_env.ctx.allocator, &.{ src_dir, "hello.txt" });
    defer test_env.ctx.allocator.free(src_file);
    var file = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "hello");

    var record = try storeDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_fetch, "gc-stale-key", src_dir, null);
    defer record.deinit();

    const cache_root = try buildCacheRoot(test_env.ctx.allocator, &test_env.ctx);
    defer test_env.ctx.allocator.free(cache_root);
    const artifact_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "artifacts", record.artifact_digest_hex });
    defer test_env.ctx.allocator.free(artifact_dir);
    {
        const artifact_parent = std.fs.path.dirname(artifact_dir) orelse unreachable;
        const artifact_base = std.fs.path.basename(artifact_dir);
        var dir = try path_mod.openExistingDir(artifact_parent);
        defer dir.close(io);
        try dir.deleteTree(io, artifact_base);
    }

    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "keys", ArtifactKind.source_fetch.asString(), keyHexFilename("gc-stale-key") });
    defer test_env.ctx.allocator.free(key_path);
    try std.Io.Dir.accessAbsolute(io, key_path, .{});

    const result = try gc(test_env.ctx.allocator, &test_env.ctx);
    try std.testing.expectEqual(@as(usize, 1), result.removed_key_records);
    std.Io.Dir.accessAbsolute(io, key_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    try std.testing.expect(false);
}

test "build_cache gc removes unreferenced artifacts" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const src_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "gc-orphan-src" });
    defer test_env.ctx.allocator.free(src_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(src_dir);
        dir.close(io);
    }

    const src_file = try std.fs.path.join(test_env.ctx.allocator, &.{ src_dir, "hello.txt" });
    defer test_env.ctx.allocator.free(src_file);
    var file = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "hello");

    var record = try storeDirectoryForKey(test_env.ctx.allocator, &test_env.ctx, .source_fetch, "gc-orphan-key", src_dir, null);
    defer record.deinit();

    const cache_root = try buildCacheRoot(test_env.ctx.allocator, &test_env.ctx);
    defer test_env.ctx.allocator.free(cache_root);
    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "keys", ArtifactKind.source_fetch.asString(), keyHexFilename("gc-orphan-key") });
    defer test_env.ctx.allocator.free(key_path);
    try std.Io.Dir.deleteFileAbsolute(io, key_path);

    const artifact_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "artifacts", record.artifact_digest_hex });
    defer test_env.ctx.allocator.free(artifact_dir);
    try std.Io.Dir.accessAbsolute(io, artifact_dir, .{});

    const result = try gc(test_env.ctx.allocator, &test_env.ctx);
    try std.testing.expectEqual(@as(usize, 1), result.removed_artifacts);
    std.Io.Dir.accessAbsolute(io, artifact_dir, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    try std.testing.expect(false);
}

test "build_cache clear removes all cache entries" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();

    const cache_root = try buildCacheRoot(test_env.ctx.allocator, &test_env.ctx);
    defer test_env.ctx.allocator.free(cache_root);
    {
        var dir = try path_mod.makePathAndOpenDir(cache_root);
        dir.close(io);
    }

    const keys_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "keys" });
    defer test_env.ctx.allocator.free(keys_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(keys_dir);
        dir.close(io);
    }

    const stamp_path = try std.fs.path.join(test_env.ctx.allocator, &.{ cache_root, "stamp.txt" });
    defer test_env.ctx.allocator.free(stamp_path);
    {
        var file = try std.Io.Dir.createFileAbsolute(io, stamp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ok");
    }

    const removed = try clear(test_env.ctx.allocator, &test_env.ctx);
    try std.testing.expectEqual(@as(usize, 2), removed);

    var dir = try path_mod.openExistingDir(cache_root);
    defer dir.close(io);
    var iter = dir.iterate();
    try std.testing.expect((try iter.next(io)) == null);
}
