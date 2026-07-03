const std = @import("std");
const builtin = @import("builtin");
const mere = @import("mere.zig");
const repo_sources = @import("repo_sources.zig");
const repocache = @import("repocache.zig");
const package = @import("package.zig");
const errors = @import("errors.zig");
const download = @import("download.zig");
const sign = @import("sign.zig");
const testing = std.testing;
const th = @import("test_helpers.zig");
const config_mod = @import("config.zig");
const path = @import("path.zig");
const Repository = @import("repository.zig").Repository;

const Std = errors.StandardErrors;
pub const SearchError = Std.OutOfMemory || Std.FileSystem || Std.CorruptData || error{
    PackageNotFound,
};

pub const SearchResult = struct {
    repo_name: []const u8,
    is_local: bool,
    name: []const u8,
    version: []const u8,
    release: u32,
    arch: []const u8,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_name);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.arch);
    }
};

const target_arch = @tagName(builtin.cpu.arch);

fn matchesArch(arch: []const u8) bool {
    return std.mem.eql(u8, arch, target_arch) or std.mem.eql(u8, arch, "any");
}

pub fn searchPackages(ctx: *mere.Context, term: []const u8, client: download.TransferClient) SearchError!std.ArrayList(SearchResult) {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit(ctx.allocator);
        results.deinit(ctx.allocator);
    }

    const cfg = ctx.getConfig() catch {
        return ctx.fail(SearchError.FileSystem, term, "failed to load configuration");
    };

    var repocaches = repo_sources.createCaches(ctx, cfg) catch {
        return ctx.fail(SearchError.FileSystem, term, "failed to initialize repositories");
    };
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    var loaded_keys = sign.loadAllKeys(ctx) catch {
        return ctx.fail(SearchError.FileSystem, term, "failed to load trusted keys");
    };
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    // Check if any remote repo needs an initial sync
    var needs_sync = false;
    for (repocaches.items) |rc| {
        if (!rc.is_local) {
            rc.ensureRepository(loaded_keys.items) catch {
                needs_sync = true;
                break;
            };
        }
    }

    if (needs_sync) {
        for (repocaches.items) |rc| {
            if (rc.is_local) continue;
            rc.sync(client, .{
                .force = false,
                .ttl_seconds = rc.sync_ttl_seconds,
                .timeout_seconds = rc.sync_timeout_seconds,
            }, loaded_keys.items) catch {
                ctx.debug("skipping repo {s}: sync failed", .{rc.name});
                continue;
            };
        }
    }

    for (repocaches.items) |rc| {
        rc.ensureRepository(loaded_keys.items) catch {
            ctx.debug("skipping repo {s}: failed to open", .{rc.name});
            continue;
        };

        const repo = &(rc.repository.?);
        var matches = repo.db.searchByName(ctx.allocator, term) catch {
            ctx.debug("skipping repo {s}: search query failed", .{rc.name});
            continue;
        };
        defer {
            for (matches.items) |*pkg| pkg.deinit();
            matches.deinit(ctx.allocator);
        }

        for (matches.items) |*pkg| {
            const pkg_arch = pkg.arch orelse continue;
            if (!matchesArch(pkg_arch)) continue;

            const result = SearchResult{
                .repo_name = ctx.allocator.dupe(u8, rc.name) catch return SearchError.OutOfMemory,
                .is_local = rc.is_local,
                .name = ctx.allocator.dupe(u8, pkg.name orelse continue) catch return SearchError.OutOfMemory,
                .version = ctx.allocator.dupe(u8, pkg.version orelse "?") catch return SearchError.OutOfMemory,
                .release = pkg.release orelse 0,
                .arch = ctx.allocator.dupe(u8, pkg_arch) catch return SearchError.OutOfMemory,
            };
            results.append(ctx.allocator, result) catch return SearchError.OutOfMemory;
        }
    }

    return results;
}

fn insertSearchTestPackage(ctx: *mere.Context, repo: *Repository, name: []const u8, arch: []const u8) !void {
    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, arch);
    pkg.signature = try ctx.allocator.dupe(u8, "sig");
    pkg.content_hash = try std.fmt.allocPrint(ctx.allocator, "hash-{s}-{s}", .{ name, arch });
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    _ = try repo.db.insertPackageTransaction(&pkg);
}

fn setupSearchTestRepo(test_env: *th.TestEnv) !th.TestRepoSetup {
    const ctx = &test_env.ctx;
    ctx.configuration = config_mod.Config.init(ctx, ctx.allocator);

    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "repo" });
    errdefer ctx.allocator.free(repo_dir);
    try path.ensureDirExists(repo_dir);

    const keypair = try sign.generateKeyPair();
    const key_path = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "repo.key" });
    defer ctx.allocator.free(key_path);
    try keypair.secret_key.saveToFile(key_path);

    ctx.signing_key_path = try ctx.allocator.dupe(u8, key_path);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    try insertSearchTestPackage(ctx, &repo, "python", target_arch);
    try insertSearchTestPackage(ctx, &repo, "python", if (std.mem.eql(u8, target_arch, "x86_64")) "aarch64" else "x86_64");
    try insertSearchTestPackage(ctx, &repo, "curl", target_arch);
    try insertSearchTestPackage(ctx, &repo, "vim", "any");

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
        .name = try ctx.allocator.dupe(u8, "test"),
        .url = try ctx.allocator.dupe(u8, repo_url),
        .priority = 100,
        .trusted_fingerprints = fps,
    });

    return th.TestRepoSetup{ .ctx = ctx, .repo_dir = repo_dir };
}

test "search filters results to current architecture" {
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    var setup = try setupSearchTestRepo(test_env);
    defer setup.deinit();

    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    var vtable = download.TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var results = try searchPackages(ctx, "python", client);
    defer {
        for (results.items) |*r| r.deinit(ctx.allocator);
        results.deinit(ctx.allocator);
    }

    // Should find python for current arch only, not the other arch
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("python", results.items[0].name);
    try testing.expectEqualStrings(target_arch, results.items[0].arch);
}

test "search includes arch 'any' packages" {
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    var setup = try setupSearchTestRepo(test_env);
    defer setup.deinit();

    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    var vtable = download.TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var results = try searchPackages(ctx, "vim", client);
    defer {
        for (results.items) |*r| r.deinit(ctx.allocator);
        results.deinit(ctx.allocator);
    }

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("vim", results.items[0].name);
    try testing.expectEqualStrings("any", results.items[0].arch);
}

test "search auto-syncs when no cached repo DB exists" {
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    var setup = try setupSearchTestRepo(test_env);
    defer setup.deinit();

    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    var vtable = download.TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    var results = try searchPackages(ctx, "curl", client);
    defer {
        for (results.items) |*r| r.deinit(ctx.allocator);
        results.deinit(ctx.allocator);
    }

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("curl", results.items[0].name);
}
