const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const config = @import("config.zig");
const Config = config.Config;
const RepoConfig = config.RepoConfig;
const RepoCache = @import("repocache.zig").RepoCache;
const repo_history = @import("repo_history.zig");
const sign = @import("sign.zig");
const kdl = @import("kdl.zig");

const default_sync_timeout_seconds: u32 = 30;

pub fn createCaches(ctx: *Context, cfg: *const Config) !std.ArrayList(*RepoCache) {
    var repocaches = std.ArrayList(*RepoCache){};
    errdefer {
        for (repocaches.items) |rc| {
            rc.*.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    var repo_configs = try cfg.getFilteredAndSortedRepos(ctx.allocator);
    defer repo_configs.deinit(ctx.allocator);

    for (repo_configs.items) |repo_cfg_ptr| {
        const rc_ptr = try ctx.allocator.create(RepoCache);
        var appended = false;
        errdefer {
            if (!appended) ctx.allocator.destroy(rc_ptr);
        }

        rc_ptr.* = RepoCache.fromConfig(ctx, repo_cfg_ptr) catch |err| {
            return ctx.fail(err, repo_cfg_ptr.name, "failed to initialize repository cache");
        };
        errdefer {
            if (!appended) rc_ptr.*.deinit();
        }

        try repocaches.append(ctx.allocator, rc_ptr);
        appended = true;
    }

    return repocaches;
}

fn resolveUserTrustedKdlPath(
    allocator: std.mem.Allocator,
    home_dir: ?[]const u8,
) ![]const u8 {
    const home = home_dir orelse return error.InvalidConfig;
    return std.fs.path.join(allocator, &.{ home, ".mere", "trusted.kdl" });
}

fn userTrustedKdlPath(ctx: *Context) ![]const u8 {
    return resolveUserTrustedKdlPath(ctx.allocator, ctx.home_dir orelse std.posix.getenv("HOME"));
}

pub fn loadTrustedFingerprints(ctx: *Context) !std.ArrayList([]const u8) {
    var fingerprints = std.ArrayList([]const u8){};
    errdefer {
        for (fingerprints.items) |fp| ctx.allocator.free(fp);
        fingerprints.deinit(ctx.allocator);
    }

    if (ctx.home_dir) |home| {
        const default_pub_path = std.fs.path.join(ctx.allocator, &.{ home, ".mere", "keys", "mere.pub" }) catch |err| {
            ctx.debug("failed to construct public key path: {}", .{err});
            return fingerprints;
        };
        defer ctx.allocator.free(default_pub_path);

        if (sign.PublicKey.loadFromFile(default_pub_path)) |pub_key| {
            if (pub_key.fingerprint(ctx.allocator)) |fp| {
                try fingerprints.append(ctx.allocator, fp);
            } else |fp_err| {
                ctx.debug("failed to get fingerprint: {}", .{fp_err});
            }
        } else |load_err| {
            ctx.debug("~/.mere/keys/mere.pub not found or invalid: {}", .{load_err});
        }
    }

    const auto_trusted_count = fingerprints.items.len;

    const trusted_path = userTrustedKdlPath(ctx) catch |err| {
        ctx.debug("failed to get trusted.kdl path: {}", .{err});
        return fingerprints;
    };
    defer ctx.allocator.free(trusted_path);

    const file = std.fs.openFileAbsolute(trusted_path, .{}) catch |err| {
        ctx.debug("trusted.kdl not found or inaccessible: {}", .{err});
        return fingerprints;
    };
    defer file.close();

    const content = file.readToEndAlloc(ctx.allocator, 1024 * 1024) catch |err| {
        ctx.debug("failed to read trusted.kdl: {}", .{err});
        return fingerprints;
    };
    defer ctx.allocator.free(content);

    var nodes = kdl.parseDocument(ctx.allocator, content) catch |err| {
        ctx.debug("failed to parse trusted.kdl: {}", .{err});
        return fingerprints;
    };
    defer {
        for (nodes.items) |*node| node.deinit();
        nodes.deinit(ctx.allocator);
    }

    for (nodes.items) |node| {
        if (std.mem.eql(u8, node.name, "trusted-fingerprint")) {
            if (node.getFirstArgString()) |fp_str| {
                if (fp_str.len != 64) {
                    ctx.debug("invalid fingerprint length in trusted.kdl: {d}", .{fp_str.len});
                    continue;
                }
                const fp_copy = try ctx.allocator.dupe(u8, fp_str);
                try fingerprints.append(ctx.allocator, fp_copy);
            }
        }
    }

    const from_trusted_kdl = fingerprints.items.len - auto_trusted_count;
    ctx.debug("loaded {d} trusted fingerprints total ({d} from trusted.kdl)", .{ fingerprints.items.len, from_trusted_kdl });
    return fingerprints;
}

fn appendDiscoveredLocalRepos(ctx: *Context, cfg: *Config) !void {
    var trusted_fps = try loadTrustedFingerprints(ctx);
    defer {
        for (trusted_fps.items) |fp| ctx.allocator.free(fp);
        trusted_fps.deinit(ctx.allocator);
    }

    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    const repos_dir_path = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo" });
    defer ctx.allocator.free(repos_dir_path);

    var repos_dir = std.fs.openDirAbsolute(repos_dir_path, .{ .iterate = true }) catch |err| {
        ctx.debug("local repos directory not found: {s} ({s})", .{ repos_dir_path, @errorName(err) });
        return;
    };
    defer repos_dir.close();

    var iter = repos_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const repo_name = entry.name;
        const repo_dir_path = try std.fs.path.join(ctx.allocator, &.{ repos_dir_path, repo_name });
        defer ctx.allocator.free(repo_dir_path);

        const current_state_path = repo_history.currentStatePath(ctx.allocator, repo_dir_path) catch {
            ctx.debug("skipping local repo {s}: out of memory building current state path", .{repo_name});
            continue;
        };
        defer ctx.allocator.free(current_state_path);

        const active_db_path = std.fs.path.join(ctx.allocator, &.{ current_state_path, repo_history.REPO_DB_FILENAME }) catch {
            ctx.debug("skipping local repo {s}: out of memory building current state db path", .{repo_name});
            continue;
        };
        defer ctx.allocator.free(active_db_path);

        const active_sig_path = std.fs.path.join(ctx.allocator, &.{ current_state_path, repo_history.REPO_SIG_FILENAME }) catch {
            ctx.debug("skipping local repo {s}: out of memory building current state sig path", .{repo_name});
            continue;
        };
        defer ctx.allocator.free(active_sig_path);

        std.fs.accessAbsolute(active_db_path, .{}) catch {
            ctx.debug("skipping {s}: current state missing db", .{repo_name});
            continue;
        };
        std.fs.accessAbsolute(active_sig_path, .{}) catch {
            ctx.debug("skipping {s}: current state missing db signature", .{repo_name});
            continue;
        };

        if (trusted_fps.items.len == 0) {
            ctx.debug("skipping local repo {s}: no trusted fingerprints configured", .{repo_name});
            continue;
        }

        var verify_result = sign.verifyWithTrustedFingerprints(ctx, active_db_path, active_sig_path, trusted_fps.items, loaded_keys.items) catch {
            ctx.debug("skipping local repo {s}: signature verification failed", .{repo_name});
            continue;
        };
        verify_result.deinit(ctx.allocator);

        for (cfg.repos.items) |existing| {
            if (std.mem.eql(u8, existing.name, repo_name)) {
                return ctx.fail(error.InvalidConfig, repo_name, "local repo name conflicts with configured remote repo");
            }
        }

        const url = try std.fmt.allocPrint(ctx.allocator, "file://{s}", .{repo_dir_path});
        errdefer ctx.allocator.free(url);

        const name_copy = try ctx.allocator.dupe(u8, repo_name);
        errdefer ctx.allocator.free(name_copy);

        var repo_fps = std.ArrayList([]const u8){};
        errdefer {
            for (repo_fps.items) |fp| ctx.allocator.free(fp);
            repo_fps.deinit(ctx.allocator);
        }
        for (trusted_fps.items) |fp| {
            const fp_copy = try ctx.allocator.dupe(u8, fp);
            try repo_fps.append(ctx.allocator, fp_copy);
        }

        try cfg.repos.append(cfg.alloc, RepoConfig{
            .name = name_copy,
            .url = url,
            .priority = 50,
            .trusted_fingerprints = repo_fps,
            .enabled = true,
            .sync_ttl_seconds = 0,
            .sync_timeout_seconds = default_sync_timeout_seconds,
            .archives_from_shared_pool = true,
        });
        ctx.debug("discovered local repo: {s}", .{repo_name});
    }
}

pub fn loadConfig(ctx: *Context) !Config {
    var cfg = try config.loadConfig(ctx);
    errdefer cfg.deinit();

    try appendDiscoveredLocalRepos(ctx, &cfg);

    return cfg;
}

test "loadTrustedFingerprints loads fingerprints from trusted.kdl" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const auto_pub_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, ".mere", "keys", "mere.pub" });
    defer test_env.ctx.allocator.free(auto_pub_path);
    std.fs.deleteFileAbsolute(auto_pub_path) catch {};

    const mere_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, ".mere" });
    defer test_env.ctx.allocator.free(mere_dir);
    try std.fs.cwd().makePath(mere_dir);

    const trusted_path = try std.fs.path.join(test_env.ctx.allocator, &.{ mere_dir, "trusted.kdl" });
    defer test_env.ctx.allocator.free(trusted_path);

    const trusted_content =
        \\trusted-fingerprint "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\trusted-fingerprint "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    ;

    const file = try std.fs.createFileAbsolute(trusted_path, .{});
    try file.writeAll(trusted_content);
    file.close();

    var fingerprints = try loadTrustedFingerprints(&test_env.ctx);
    defer {
        for (fingerprints.items) |fp| test_env.ctx.allocator.free(fp);
        fingerprints.deinit(test_env.ctx.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), fingerprints.items.len);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", fingerprints.items[0]);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", fingerprints.items[1]);
}

test "loadTrustedFingerprints returns empty list when file missing" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const auto_pub_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, ".mere", "keys", "mere.pub" });
    defer test_env.ctx.allocator.free(auto_pub_path);
    std.fs.deleteFileAbsolute(auto_pub_path) catch {};

    var fingerprints = try loadTrustedFingerprints(&test_env.ctx);
    defer fingerprints.deinit(test_env.ctx.allocator);

    try std.testing.expectEqual(@as(usize, 0), fingerprints.items.len);
}

test "resolveUserTrustedKdlPath uses provided home directory" {
    const path_value = try resolveUserTrustedKdlPath(std.testing.allocator, "/tmp/test-home");
    defer std.testing.allocator.free(path_value);

    try std.testing.expectEqualStrings("/tmp/test-home/.mere/trusted.kdl", path_value);
}

test "resolveUserTrustedKdlPath errors when home directory missing" {
    try std.testing.expectError(error.InvalidConfig, resolveUserTrustedKdlPath(std.testing.allocator, null));
}

test "appendDiscoveredLocalRepos finds valid repositories" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repo_root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", "testrepo" });
    defer test_env.ctx.allocator.free(repo_root);
    const current_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ repo_root, "current" });
    defer test_env.ctx.allocator.free(current_dir);
    try std.fs.cwd().makePath(repo_root);
    try std.fs.cwd().makePath(current_dir);

    const db_path = try std.fs.path.join(test_env.ctx.allocator, &.{ current_dir, "repo.db" });
    defer test_env.ctx.allocator.free(db_path);
    const db_file = try std.fs.createFileAbsolute(db_path, .{});
    try db_file.writeAll("dummy db content");
    db_file.close();

    const keypair = try sign.generateKeyPair();
    const secret_key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "testrepo.key" });
    defer test_env.ctx.allocator.free(secret_key_path);
    try keypair.secret_key.saveToFile(secret_key_path);

    const user_keys_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, ".mere", "keys" });
    defer test_env.ctx.allocator.free(user_keys_dir);
    try std.fs.cwd().makePath(user_keys_dir);
    const pubkey_path = try std.fs.path.join(test_env.ctx.allocator, &.{ user_keys_dir, "testrepo.pub" });
    defer test_env.ctx.allocator.free(pubkey_path);
    try keypair.public_key.saveToFile(pubkey_path);

    const fingerprint = try keypair.public_key.fingerprint(test_env.ctx.allocator);
    defer test_env.ctx.allocator.free(fingerprint);
    const trusted_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, ".mere", "trusted.kdl" });
    defer test_env.ctx.allocator.free(trusted_path);
    {
        const trusted_file = try std.fs.createFileAbsolute(trusted_path, .{});
        const line = try std.fmt.allocPrint(test_env.ctx.allocator, "trusted-fingerprint \"{s}\"\n", .{fingerprint});
        defer test_env.ctx.allocator.free(line);
        try trusted_file.writeAll(line);
        trusted_file.close();
    }

    const sig_path = try std.fs.path.join(test_env.ctx.allocator, &.{ current_dir, "repo.db.sig" });
    defer test_env.ctx.allocator.free(sig_path);
    test_env.ctx.signing_key_path = secret_key_path;
    _ = try sign.writeSignatureFileWithResolver(&test_env.ctx, db_path, sig_path, null, null);

    var cfg = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer cfg.deinit();

    try appendDiscoveredLocalRepos(&test_env.ctx, &cfg);

    try std.testing.expectEqual(@as(usize, 1), cfg.repos.items.len);
    try std.testing.expectEqualStrings("testrepo", cfg.repos.items[0].name);
    try std.testing.expect(std.mem.startsWith(u8, cfg.repos.items[0].url, "file://"));
}

test "appendDiscoveredLocalRepos skips directories without db" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const repos_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", "invalid" });
    defer test_env.ctx.allocator.free(repos_dir);
    try std.fs.cwd().makePath(repos_dir);

    var cfg = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer cfg.deinit();

    try appendDiscoveredLocalRepos(&test_env.ctx, &cfg);
    try std.testing.expectEqual(@as(usize, 0), cfg.repos.items.len);
}
