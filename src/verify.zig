// System verification: store, profiles, and GC roots
//
// This module implements the "mere verify" command logic.
// It performs integrity checks without mutating state.

const std = @import("std");
const errors = @import("errors.zig");
const config = @import("config.zig");
const repo_sources = @import("repo_sources.zig");
const generation = @import("generation.zig");
const hash = @import("hash.zig");
const manifest = @import("manifest.zig");
const path_safety = @import("path_safety.zig");
const profile = @import("profile.zig");
const sign = @import("sign.zig");
const store = @import("store.zig");
const Context = @import("mere.zig").Context;

const Std = errors.StandardErrors;
pub const VerifyError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput;

pub const VerifyOptions = struct {
    verify_store: bool,
    verify_profiles: bool,
    verify_gc_roots: bool,
    full_hash: bool,
    profile: ?[]const u8 = null,
};

pub const IssueKind = enum {
    store,
    profile,
    gc_roots,
    trust,
};

pub const Issue = struct {
    kind: IssueKind,
    path: []const u8,
    message: []const u8,
};

pub const VerifyResult = struct {
    issues: std.ArrayList(Issue) = .{},
    store_checked: usize = 0,
    store_issues: usize = 0,
    profile_realizations_checked: usize = 0,
    profile_issues: usize = 0,
    gc_roots_checked: usize = 0,
    gc_roots_issues: usize = 0,

    pub fn deinit(self: *VerifyResult, allocator: std.mem.Allocator) void {
        for (self.issues.items) |issue| {
            allocator.free(issue.path);
            allocator.free(issue.message);
        }
        self.issues.deinit(allocator);
    }
};

pub fn verifyAll(ctx: *Context, opts: VerifyOptions) VerifyError!VerifyResult {
    var result = VerifyResult{};
    errdefer result.deinit(ctx.allocator);

    if (opts.verify_store) {
        var trusted_fps = try collectTrustedFingerprints(ctx);
        defer {
            for (trusted_fps.items) |fp| ctx.allocator.free(fp);
            trusted_fps.deinit(ctx.allocator);
        }
        try verifyStore(ctx, opts.full_hash, trusted_fps.items, &result);
    }

    if (opts.verify_profiles) {
        try verifyProfiles(ctx, opts.profile, opts.full_hash, &result);
    }

    if (opts.verify_gc_roots) {
        try verifyGCRoots(ctx, &result);
    }

    return result;
}

fn addIssue(ctx: *Context, result: *VerifyResult, kind: IssueKind, path: []const u8, message: []const u8) VerifyError!void {
    const path_copy = try ctx.allocator.dupe(u8, path);
    errdefer ctx.allocator.free(path_copy);
    const msg_copy = try ctx.allocator.dupe(u8, message);
    errdefer ctx.allocator.free(msg_copy);
    try result.issues.append(ctx.allocator, Issue{
        .kind = kind,
        .path = path_copy,
        .message = msg_copy,
    });
}

fn addProfileIssue(
    ctx: *Context,
    result: *VerifyResult,
    path: []const u8,
    profile_name: []const u8,
    realization_name: []const u8,
    message: []const u8,
) VerifyError!void {
    const full = std.fmt.allocPrint(
        ctx.allocator,
        "profile {s} {s}: {s}",
        .{ profile_name, realization_name, message },
    ) catch {
        return ctx.fail(VerifyError.OutOfMemory, path, "failed to format profile issue");
    };
    defer ctx.allocator.free(full);
    try addIssue(ctx, result, .profile, path, full);
}

fn collectTrustedFingerprints(ctx: *Context) VerifyError!std.ArrayList([]const u8) {
    var trusted = std.ArrayList([]const u8){};
    errdefer {
        for (trusted.items) |fp| ctx.allocator.free(fp);
        trusted.deinit(ctx.allocator);
    }

    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer seen.deinit();

    var cfg_opt: ?*config.Config = null;
    if (ctx.getConfig()) |cfg| {
        cfg_opt = cfg;
    } else |_| {
        return ctx.fail(VerifyError.InvalidInput, "config", "failed to load config for trusted fingerprint verification");
    }

    if (cfg_opt) |cfg| {
        for (cfg.repos.items) |repo| {
            for (repo.trusted_fingerprints.items) |fp| {
                if (seen.contains(fp)) continue;
                try seen.put(fp, {});
                const copy = try ctx.allocator.dupe(u8, fp);
                try trusted.append(ctx.allocator, copy);
            }
        }
    }

    var user_fps = repo_sources.loadTrustedFingerprints(ctx) catch {
        return ctx.fail(VerifyError.InvalidInput, "trusted-fingerprints", "failed to load trusted fingerprints");
    };
    defer {
        for (user_fps.items) |fp| ctx.allocator.free(fp);
        user_fps.deinit(ctx.allocator);
    }

    for (user_fps.items) |fp| {
        if (seen.contains(fp)) continue;
        try seen.put(fp, {});
        const copy = try ctx.allocator.dupe(u8, fp);
        try trusted.append(ctx.allocator, copy);
    }

    return trusted;
}

fn verifyStore(
    ctx: *Context,
    full_hash: bool,
    trusted_fingerprints: []const []const u8,
    result: *VerifyResult,
) VerifyError!void {
    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(VerifyError.OutOfMemory, "store", "failed to construct store path");
    };
    defer ctx.allocator.free(store_root);

    var dir = std.fs.openDirAbsolute(store_root, .{ .iterate = true }) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => VerifyError.PermissionDenied,
            error.FileNotFound => VerifyError.FileSystem,
            else => VerifyError.FileSystem,
        }, store_root, "failed to open store directory");
    };
    defer dir.close();

    if (trusted_fingerprints.len == 0) {
        return ctx.fail(VerifyError.InvalidInput, store_root, "no trusted fingerprints configured for store verification");
    }

    var loaded_keys = sign.loadAllKeys(ctx) catch |err| {
        return ctx.fail(switch (err) {
            error.OutOfMemory => VerifyError.OutOfMemory,
            error.PermissionDenied => VerifyError.PermissionDenied,
            error.InvalidKey => VerifyError.InvalidInput,
            else => VerifyError.FileSystem,
        }, store_root, "failed to load trusted public keys");
    };
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => VerifyError.PermissionDenied,
            else => VerifyError.FileSystem,
        }, store_root, "failed to iterate store directory");
    }) |entry| {
        const entry_path = std.fs.path.join(ctx.allocator, &.{ store_root, entry.name }) catch {
            return ctx.fail(VerifyError.OutOfMemory, store_root, "failed to build store entry path");
        };
        defer ctx.allocator.free(entry_path);

        if (std.mem.eql(u8, entry.name, ".incoming")) {
            // Staging directory used during installation.
            continue;
        }

        if (entry.kind != .directory) {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "store entry is not a directory");
            continue;
        }

        result.store_checked += 1;

        const components = store.parseStorePath(entry_path) catch {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "invalid store path format");
            continue;
        };

        const manifest_path = std.fs.path.join(ctx.allocator, &.{ entry_path, manifest.MANIFEST_FILENAME }) catch {
            return ctx.fail(VerifyError.OutOfMemory, entry_path, "failed to construct manifest path");
        };
        defer ctx.allocator.free(manifest_path);

        const sig_path = std.fs.path.join(ctx.allocator, &.{ entry_path, manifest.MANIFEST_SIG_FILENAME }) catch {
            return ctx.fail(VerifyError.OutOfMemory, entry_path, "failed to construct manifest signature path");
        };
        defer ctx.allocator.free(sig_path);

        std.fs.accessAbsolute(manifest_path, .{}) catch {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "manifest.v1 missing");
            continue;
        };

        std.fs.accessAbsolute(sig_path, .{}) catch {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "manifest.v1.sig missing");
            continue;
        };

        const manifest_bytes = manifest.readManifestFile(ctx, entry_path) catch {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "failed to read manifest.v1");
            continue;
        };
        defer ctx.allocator.free(manifest_bytes);

        const pkg_manifest = manifest.PackageManifestV1.decode(manifest_bytes) catch {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "failed to decode manifest.v1");
            continue;
        };

        const manifest_hash = pkg_manifest.contentHashHex(ctx.allocator) catch {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "failed to format manifest content hash");
            continue;
        };
        defer ctx.allocator.free(manifest_hash);

        if (!std.mem.eql(u8, manifest_hash, components.content_hash)) {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "store path hash does not match manifest content hash");
        }

        if (!std.mem.eql(u8, pkg_manifest.name, components.name)) {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "manifest name does not match store path name");
        }

        if (!std.mem.eql(u8, pkg_manifest.version, components.version)) {
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, "manifest version does not match store path version");
        }

        if (trusted_fingerprints.len > 0) {
            const verify_result = sign.verifyManifestWithTrustedFingerprints(ctx, manifest_path, sig_path, trusted_fingerprints, loaded_keys.items) catch {
                result.store_issues += 1;
                try addIssue(ctx, result, .store, entry_path, "manifest signature verification failed");
                continue;
            };
            ctx.allocator.free(verify_result.verifying_fingerprint);
        }

        path_safety.validateStorePayload(ctx.allocator, entry_path) catch |err| {
            const detail = switch (err) {
                path_safety.PathSafetyError.EscapesBoundary => "symlink escapes store boundary",
                path_safety.PathSafetyError.SymlinkLoop => "symlink loop detected",
                path_safety.PathSafetyError.ChainTooDeep => "symlink chain too deep",
                path_safety.PathSafetyError.InvalidSymlink => "invalid symlink",
                path_safety.PathSafetyError.InvalidInput => "invalid symlink path",
                path_safety.PathSafetyError.FileSystem => "failed to read symlink",
                path_safety.PathSafetyError.OutOfMemory => "out of memory",
            };
            result.store_issues += 1;
            try addIssue(ctx, result, .store, entry_path, detail);
        };

        if (full_hash) {
            const computed = hash.calculateStoreContentHash(ctx.allocator, entry_path, null) catch {
                result.store_issues += 1;
                try addIssue(ctx, result, .store, entry_path, "failed to compute store content hash");
                continue;
            };
            defer ctx.allocator.free(computed);

            if (!std.mem.eql(u8, computed, manifest_hash)) {
                result.store_issues += 1;
                try addIssue(ctx, result, .store, entry_path, "computed store hash does not match manifest content hash");
            }
        }
    }
}

fn verifyProfiles(
    ctx: *Context,
    profile_filter: ?[]const u8,
    full_hash: bool,
    result: *VerifyResult,
) VerifyError!void {
    const profiles_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return ctx.fail(VerifyError.OutOfMemory, "profiles", "failed to construct profiles path");
    };
    defer ctx.allocator.free(profiles_root);

    var dir = std.fs.openDirAbsolute(profiles_root, .{ .iterate = true }) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => VerifyError.PermissionDenied,
            error.FileNotFound => VerifyError.FileSystem,
            else => VerifyError.FileSystem,
        }, profiles_root, "failed to open profiles directory");
    };
    defer dir.close();

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(VerifyError.OutOfMemory, "store", "failed to construct store root path");
    };
    defer ctx.allocator.free(store_root);

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => VerifyError.PermissionDenied,
            else => VerifyError.FileSystem,
        }, profiles_root, "failed to iterate profiles directory");
    }) |entry| {
        if (entry.kind != .directory) continue;
        if (profile_filter) |pf| {
            if (!std.mem.eql(u8, entry.name, pf)) continue;
        }

        const profile_dir = std.fs.path.join(ctx.allocator, &.{ profiles_root, entry.name }) catch {
            return ctx.fail(VerifyError.OutOfMemory, profiles_root, "failed to build profile path");
        };
        defer ctx.allocator.free(profile_dir);

        var profile_dir_handle = std.fs.openDirAbsolute(profile_dir, .{ .iterate = true }) catch {
            result.profile_issues += 1;
            try addIssue(ctx, result, .profile, profile_dir, "failed to open profile directory");
            continue;
        };
        defer profile_dir_handle.close();

        const require_root_owned = std.mem.eql(u8, entry.name, "system");
        if (require_root_owned) {
            var piter = profile_dir_handle.iterate();
            while (piter.next() catch |err| {
                return ctx.fail(switch (err) {
                    error.AccessDenied => VerifyError.PermissionDenied,
                    else => VerifyError.FileSystem,
                }, profile_dir, "failed to iterate profile directory");
            }) |pentry| {
                if (pentry.kind != .directory) continue;
                if (generation.parseGenerationNumber(pentry.name) == null) continue;

                const gen_path = std.fs.path.join(ctx.allocator, &.{ profile_dir, pentry.name }) catch {
                    return ctx.fail(VerifyError.OutOfMemory, profile_dir, "failed to build generation path");
                };
                defer ctx.allocator.free(gen_path);

                result.profile_realizations_checked += 1;

                var gen_manifest = generation.readManifest(ctx.allocator, gen_path) catch {
                    result.profile_issues += 1;
                    try addProfileIssue(ctx, result, gen_path, entry.name, pentry.name, "generation manifest missing or invalid");
                    continue;
                };
                defer gen_manifest.deinit();

                try verifyProfileManifestPackages(ctx, result, store_root, entry.name, pentry.name, require_root_owned, full_hash, &gen_manifest);
            }
        } else {
            const root_path = profile.getRootPath(ctx.allocator, profile_dir) catch {
                return ctx.fail(VerifyError.OutOfMemory, profile_dir, "failed to build profile root path");
            };
            defer ctx.allocator.free(root_path);

            std.fs.accessAbsolute(root_path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.AccessDenied => {
                    result.profile_issues += 1;
                    try addIssue(ctx, result, .profile, root_path, "failed to access profile root");
                    continue;
                },
                else => {
                    result.profile_issues += 1;
                    try addIssue(ctx, result, .profile, root_path, "failed to access profile root");
                    continue;
                },
            };

            result.profile_realizations_checked += 1;
            var root_manifest = generation.readManifest(ctx.allocator, root_path) catch {
                result.profile_issues += 1;
                try addProfileIssue(ctx, result, root_path, entry.name, "root", "profile manifest missing or invalid");
                continue;
            };
            defer root_manifest.deinit();

            try verifyProfileManifestPackages(ctx, result, store_root, entry.name, "root", require_root_owned, full_hash, &root_manifest);
        }
    }
}

fn verifyProfileManifestPackages(
    ctx: *Context,
    result: *VerifyResult,
    store_root: []const u8,
    profile_name: []const u8,
    realization_name: []const u8,
    require_root_owned: bool,
    full_hash: bool,
    manifest_data: *generation.GenerationManifest,
) VerifyError!void {
    for (manifest_data.packages.items) |pkg| {
        if (!path_safety.isWithinBoundary(pkg.store_path, store_root)) {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "store path outside store root");
            continue;
        }

        std.fs.accessAbsolute(pkg.store_path, .{}) catch {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "store path does not exist");
            continue;
        };

        const stat_buf = std.posix.fstatat(std.posix.AT.FDCWD, pkg.store_path, 0) catch {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "failed to stat store path");
            continue;
        };

        if ((stat_buf.mode & std.posix.S.IFMT) != std.posix.S.IFDIR) {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "store path is not a directory");
        }

        if (require_root_owned) {
            if (stat_buf.uid != 0 or stat_buf.gid != 0) {
                result.profile_issues += 1;
                try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "store path is not root-owned");
            }
            if ((stat_buf.mode & 0o222) != 0) {
                result.profile_issues += 1;
                try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "store path is writable");
            }
        }

        if (pkg.content_hash.len != 64) {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "invalid content hash length in profile manifest");
        }

        if (full_hash) {
            const computed = hash.calculateStoreContentHash(ctx.allocator, pkg.store_path, null) catch {
                result.profile_issues += 1;
                try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "failed to compute store content hash");
                continue;
            };
            defer ctx.allocator.free(computed);

            if (!std.mem.eql(u8, computed, pkg.content_hash)) {
                result.profile_issues += 1;
                try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "computed store hash does not match profile manifest");
            }
        }

        const components = store.parseStorePath(pkg.store_path) catch {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "invalid store path format");
            continue;
        };

        if (!std.mem.eql(u8, components.content_hash, pkg.content_hash)) {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "profile manifest content hash does not match store path");
        }

        if (!std.mem.eql(u8, components.name, pkg.name)) {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "package name does not match store path");
        }

        if (!std.mem.eql(u8, components.version, pkg.version)) {
            result.profile_issues += 1;
            try addProfileIssue(ctx, result, pkg.store_path, profile_name, realization_name, "package version does not match store path");
        }
    }
}

fn verifyGCRoots(ctx: *Context, result: *VerifyResult) VerifyError!void {
    const gc_roots_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return ctx.fail(VerifyError.OutOfMemory, "gc-roots", "failed to construct gc-roots path");
    };
    defer ctx.allocator.free(gc_roots_dir);

    var dir = std.fs.openDirAbsolute(gc_roots_dir, .{ .iterate = true }) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => VerifyError.PermissionDenied,
            error.FileNotFound => VerifyError.FileSystem,
            else => VerifyError.FileSystem,
        }, gc_roots_dir, "failed to open gc-roots directory");
    };
    defer dir.close();

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(VerifyError.OutOfMemory, "store", "failed to construct store root path");
    };
    defer ctx.allocator.free(store_root);

    const profiles_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "profiles" }) catch {
        return ctx.fail(VerifyError.OutOfMemory, "profiles", "failed to construct profiles root path");
    };
    defer ctx.allocator.free(profiles_root);

    var walker = dir.walk(ctx.allocator) catch {
        return ctx.fail(VerifyError.OutOfMemory, gc_roots_dir, "failed to walk gc-roots directory");
    };
    defer walker.deinit();

    while (walker.next() catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => VerifyError.PermissionDenied,
            else => VerifyError.FileSystem,
        }, gc_roots_dir, "failed to iterate gc-roots directory");
    }) |entry| {
        const full_path = std.fs.path.join(ctx.allocator, &.{ gc_roots_dir, entry.path }) catch {
            return ctx.fail(VerifyError.OutOfMemory, gc_roots_dir, "failed to build gc-root path");
        };
        defer ctx.allocator.free(full_path);

        if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.path, ".note")) {
                continue;
            }
            result.gc_roots_issues += 1;
            try addIssue(ctx, result, .gc_roots, full_path, "unexpected file in gc-roots");
            continue;
        }

        if (entry.kind != .sym_link) continue;

        result.gc_roots_checked += 1;

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.readLinkAbsolute(full_path, &link_buf) catch {
            result.gc_roots_issues += 1;
            try addIssue(ctx, result, .gc_roots, full_path, "failed to read gc-root symlink");
            continue;
        };

        var checked_target: []const u8 = target;
        var resolved_target: ?[]const u8 = null;
        defer if (resolved_target) |p| ctx.allocator.free(p);

        if (std.mem.startsWith(u8, entry.path, "pins/")) {
            const resolved = path_safety.resolveWithinBoundary(ctx.allocator, target, store_root) catch |err| {
                result.gc_roots_issues += 1;
                try addIssue(ctx, result, .gc_roots, full_path, switch (err) {
                    path_safety.PathSafetyError.EscapesBoundary => "pin target outside store root",
                    path_safety.PathSafetyError.SymlinkLoop => "pin target symlink loop detected",
                    path_safety.PathSafetyError.ChainTooDeep => "pin target symlink chain too deep",
                    path_safety.PathSafetyError.InvalidSymlink,
                    path_safety.PathSafetyError.InvalidInput,
                    path_safety.PathSafetyError.FileSystem,
                    => "pin target symlink is invalid",
                    path_safety.PathSafetyError.OutOfMemory => "out of memory while validating pin target",
                });
                continue;
            };
            resolved_target = resolved.path;
            checked_target = resolved.path;
        } else if (std.mem.startsWith(u8, entry.path, "profiles/")) {
            const resolved = path_safety.resolveWithinBoundary(ctx.allocator, target, profiles_root) catch |err| {
                result.gc_roots_issues += 1;
                try addIssue(ctx, result, .gc_roots, full_path, switch (err) {
                    path_safety.PathSafetyError.EscapesBoundary => "profile root outside profiles directory",
                    path_safety.PathSafetyError.SymlinkLoop => "profile target symlink loop detected",
                    path_safety.PathSafetyError.ChainTooDeep => "profile target symlink chain too deep",
                    path_safety.PathSafetyError.InvalidSymlink,
                    path_safety.PathSafetyError.InvalidInput,
                    path_safety.PathSafetyError.FileSystem,
                    => "profile target symlink is invalid",
                    path_safety.PathSafetyError.OutOfMemory => "out of memory while validating profile target",
                });
                continue;
            };
            resolved_target = resolved.path;
            checked_target = resolved.path;
        }

        std.fs.accessAbsolute(checked_target, .{}) catch {
            result.gc_roots_issues += 1;
            try addIssue(ctx, result, .gc_roots, full_path, "gc-root target does not exist");
            continue;
        };
    }
}

test "verify store reports invalid store path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    const bad_path = try std.fs.path.join(ctx.allocator, &.{ store_root, "not-a-store-path" });
    defer ctx.allocator.free(bad_path);
    try std.fs.cwd().makePath(bad_path);

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyStore(ctx, false, &[_][]const u8{"a" ** 64}, &result);
    try std.testing.expect(result.store_issues > 0);
}

test "verify store skips incoming directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    const incoming_dir = try std.fs.path.join(ctx.allocator, &.{ store_root, ".incoming" });
    defer ctx.allocator.free(incoming_dir);
    try std.fs.cwd().makePath(incoming_dir);

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyStore(ctx, false, &[_][]const u8{"a" ** 64}, &result);
    try std.testing.expectEqual(@as(usize, 0), result.store_issues);
    try std.testing.expectEqual(@as(usize, 0), result.store_checked);
}

test "verify store fails when trusted fingerprints are missing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try std.testing.expectError(VerifyError.InvalidInput, verifyStore(ctx, false, &[_][]const u8{}, &result));
}

test "verify gc roots reports broken symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const gc_roots_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "gc-roots" });
    defer ctx.allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const pins_dir = try std.fs.path.join(ctx.allocator, &.{ gc_roots_dir, "pins" });
    defer ctx.allocator.free(pins_dir);
    try std.fs.cwd().makePath(pins_dir);

    // Create broken pin root
    var pins_handle = try std.fs.openDirAbsolute(pins_dir, .{});
    defer pins_handle.close();
    try pins_handle.symLink("/mere/store/does-not-exist", "broken", .{});

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyGCRoots(ctx, &result);
    try std.testing.expect(result.gc_roots_issues > 0);
}

test "verify gc roots rejects pin target with canonical escape" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const gc_roots_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "gc-roots" });
    defer ctx.allocator.free(gc_roots_dir);
    try std.fs.cwd().makePath(gc_roots_dir);

    const pins_dir = try std.fs.path.join(ctx.allocator, &.{ gc_roots_dir, "pins" });
    defer ctx.allocator.free(pins_dir);
    try std.fs.cwd().makePath(pins_dir);

    const escaped_target = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "user", "gen-1" });
    defer ctx.allocator.free(escaped_target);
    try std.fs.cwd().makePath(escaped_target);

    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    const lexical_inside_store_but_escapes = try std.fmt.allocPrint(ctx.allocator, "{s}/../profiles/user/gen-1", .{store_root});
    defer ctx.allocator.free(lexical_inside_store_but_escapes);

    var pins_handle = try std.fs.openDirAbsolute(pins_dir, .{});
    defer pins_handle.close();
    try pins_handle.symLink(lexical_inside_store_but_escapes, "escaped", .{});

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyGCRoots(ctx, &result);
    try std.testing.expect(result.gc_roots_issues > 0);

    var found = false;
    for (result.issues.items) |issue| {
        if (std.mem.containsAtLeast(u8, issue.message, 1, "pin target outside store root")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "verify profiles accepts valid named profile root manifest" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    const content_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const store_path = try store.constructStorePath(ctx, content_hash, "demo", "1.0.0");
    defer ctx.allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    const profile_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "user" });
    defer ctx.allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    const root_dir = try profile.getRootPath(ctx.allocator, profile_root);
    defer ctx.allocator.free(root_dir);
    try std.fs.cwd().makePath(root_dir);

    var manifest_data = generation.GenerationManifest.initRoot(ctx.allocator);
    defer manifest_data.deinit();
    try manifest_data.addPackage("demo", "1.0.0", 1, "x86_64", store_path, content_hash);
    try generation.writeManifest(ctx.allocator, root_dir, &manifest_data);

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyProfiles(ctx, null, false, &result);
    try std.testing.expectEqual(@as(usize, 1), result.profile_realizations_checked);
    try std.testing.expectEqual(@as(usize, 0), result.profile_issues);
}

test "verify profiles reports missing store path with profile context" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    const content_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const missing_store = try store.constructStorePath(ctx, content_hash, "demo", "1.0.0");
    defer ctx.allocator.free(missing_store);

    const profile_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "user" });
    defer ctx.allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    const root_dir = try profile.getRootPath(ctx.allocator, profile_root);
    defer ctx.allocator.free(root_dir);
    try std.fs.cwd().makePath(root_dir);

    var manifest_data = generation.GenerationManifest.initRoot(ctx.allocator);
    defer manifest_data.deinit();
    try manifest_data.addPackage("demo", "1.0.0", 1, "x86_64", missing_store, content_hash);
    try generation.writeManifest(ctx.allocator, root_dir, &manifest_data);

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyProfiles(ctx, null, false, &result);
    try std.testing.expect(result.profile_issues > 0);
    try std.testing.expect(result.issues.items.len > 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.issues.items[0].message, 1, "profile user root"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.issues.items[0].message, 1, "store path does not exist"));
}

test "verify profiles reports profile manifest hash mismatch without full hash" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    try std.fs.cwd().makePath(store_root);

    const store_hash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const manifest_hash = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const store_path = try store.constructStorePath(ctx, store_hash, "demo", "1.0.0");
    defer ctx.allocator.free(store_path);
    try std.fs.cwd().makePath(store_path);

    const profile_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "user" });
    defer ctx.allocator.free(profile_root);
    try std.fs.cwd().makePath(profile_root);

    const root_dir = try profile.getRootPath(ctx.allocator, profile_root);
    defer ctx.allocator.free(root_dir);
    try std.fs.cwd().makePath(root_dir);

    var manifest_data = generation.GenerationManifest.initRoot(ctx.allocator);
    defer manifest_data.deinit();
    try manifest_data.addPackage("demo", "1.0.0", 1, "x86_64", store_path, manifest_hash);
    try generation.writeManifest(ctx.allocator, root_dir, &manifest_data);

    var result = VerifyResult{};
    defer result.deinit(ctx.allocator);

    try verifyProfiles(ctx, null, false, &result);
    try std.testing.expect(result.profile_issues > 0);

    var found = false;
    for (result.issues.items) |issue| {
        if (std.mem.containsAtLeast(u8, issue.message, 1, "profile manifest content hash does not match store path")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
