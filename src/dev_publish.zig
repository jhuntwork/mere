const std = @import("std");
const mere = @import("mere.zig");
const path = @import("path.zig");
const publish_mod = @import("publish.zig");
const package_mod = @import("package.zig");
const RepoDB = @import("repodb.zig").RepoDB;
const repodb_c = @import("repodb.zig").c;
const Repository = @import("repository.zig").Repository;
const RepoError = @import("repository.zig").Error;

const Selector = union(enum) {
    name_only: []const u8,
    exact: struct {
        name: []const u8,
        version: []const u8,
        release: u32,
        arch: []const u8,
    },
};

pub const Result = struct {
    applied_count: usize,
};

fn parseSelector(input: []const u8) !Selector {
    if (input.len == 0) return error.InvalidInput;

    if (std.mem.indexOfScalar(u8, input, '@')) |at| {
        if (at == 0 or at + 1 >= input.len) return error.InvalidInput;

        const name = input[0..at];
        const rest = input[at + 1 ..];
        const colon_idx = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.InvalidInput;
        if (colon_idx == 0 or colon_idx + 1 >= rest.len) return error.InvalidInput;

        const version_release = rest[0..colon_idx];
        const arch = rest[colon_idx + 1 ..];
        const dash_idx = std.mem.lastIndexOfScalar(u8, version_release, '-') orelse return error.InvalidInput;
        if (dash_idx == 0 or dash_idx + 1 >= version_release.len) return error.InvalidInput;

        const version = version_release[0..dash_idx];
        const release_str = version_release[dash_idx + 1 ..];
        const release = std.fmt.parseInt(u32, release_str, 10) catch return error.InvalidInput;

        return .{ .exact = .{
            .name = name,
            .version = version,
            .release = release,
            .arch = arch,
        } };
    }

    return .{ .name_only = input };
}

pub fn publish(
    ctx: *mere.Context,
    repo_name: []const u8,
    out_dir: []const u8,
    selectors: []const []const u8,
    keep_count: u32,
) !Result {
    if (keep_count == 0) {
        return ctx.fail(RepoError.InvalidInput, "keep", "keep count must be at least 1");
    }

    const repo_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo", repo_name }) catch {
        return RepoError.OutOfMemory;
    };
    defer ctx.allocator.free(repo_dir);

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_dir_abs = path.resolveToAbsolutePath(out_dir, &out_buf) catch {
        return RepoError.InvalidInput;
    };

    var repo = try Repository.init(ctx, repo_dir, true);
    defer repo.deinit();

    var selected = try collectSelectedPackages(ctx, repo.db, selectors, keep_count);
    defer {
        for (selected.items) |*pkg| pkg.deinit();
        selected.deinit(ctx.allocator);
    }

    var stage_tmp = path.createTempDir("mere-publish") catch {
        return RepoError.FileSystem;
    };
    defer stage_tmp.cleanup();

    const stage_dir = std.fmt.allocPrint(ctx.allocator, "/tmp/{s}", .{stage_tmp.sub_path}) catch {
        return RepoError.OutOfMemory;
    };
    defer ctx.allocator.free(stage_dir);

    var staged = try publish_mod.stageFromPublishedBaseline(ctx, stage_dir, out_dir_abs);
    defer staged.deinit();

    for (selected.items) |*pkg| {
        _ = try staged.applyPackageWithRetention(pkg, keep_count, true);
    }

    try staged.commit(out_dir_abs);

    return .{
        .applied_count = selected.items.len,
    };
}

fn appendUniqueSelectedPackage(
    ctx: *mere.Context,
    selected: *std.ArrayList(package_mod.Package),
    seen: *std.StringHashMap(void),
    pkg: package_mod.Package,
) !void {
    const key = std.fmt.allocPrint(
        ctx.allocator,
        "{s}|{s}|{d}|{s}",
        .{ pkg.name.?, pkg.version.?, pkg.release.?, pkg.arch.? },
    ) catch return RepoError.OutOfMemory;

    if (seen.contains(key)) {
        ctx.allocator.free(key);
        var pkg_mut = pkg;
        pkg_mut.deinit();
        return;
    }

    seen.put(key, {}) catch {
        ctx.allocator.free(key);
        var pkg_mut = pkg;
        pkg_mut.deinit();
        return RepoError.OutOfMemory;
    };

    selected.append(ctx.allocator, pkg) catch return RepoError.OutOfMemory;
}

fn collectSelectedPackages(
    ctx: *mere.Context,
    repo_db: *RepoDB,
    selectors: []const []const u8,
    keep_count: u32,
) !std.ArrayList(package_mod.Package) {
    var selected: std.ArrayList(package_mod.Package) = .{};
    errdefer {
        for (selected.items) |*pkg| pkg.deinit();
        selected.deinit(ctx.allocator);
    }

    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer {
        var iter = seen.keyIterator();
        while (iter.next()) |key| {
            ctx.allocator.free(key.*);
        }
        seen.deinit();
    }

    var name_arch_pairs = try repo_db.getDistinctPackageNameArch(ctx.allocator);
    defer {
        for (name_arch_pairs.items) |pair| {
            ctx.allocator.free(pair.name);
            ctx.allocator.free(pair.arch);
        }
        name_arch_pairs.deinit(ctx.allocator);
    }

    if (selectors.len == 0) {
        for (name_arch_pairs.items) |pair| {
            var pkgs = try repo_db.getLatestPackagesByNameArch(ctx.allocator, pair.name, pair.arch, keep_count);
            defer {
                for (pkgs.items) |*pkg| pkg.deinit();
                pkgs.deinit(ctx.allocator);
            }
            for (pkgs.items) |*pkg| {
                const owned_pkg = pkg.*;
                pkg.* = package_mod.Package.init(ctx);
                try appendUniqueSelectedPackage(ctx, &selected, &seen, owned_pkg);
            }
        }
        return selected;
    }

    for (selectors) |selector_raw| {
        const selector = parseSelector(selector_raw) catch {
            return ctx.fail(RepoError.InvalidInput, selector_raw, "invalid package selector; use <name> or <name>@<version>-<release>:<arch>");
        };

        switch (selector) {
            .name_only => |name| {
                var found_arch = false;
                for (name_arch_pairs.items) |pair| {
                    if (!std.mem.eql(u8, pair.name, name)) continue;
                    found_arch = true;
                    var pkgs = try repo_db.getLatestPackagesByNameArch(ctx.allocator, pair.name, pair.arch, keep_count);
                    defer {
                        for (pkgs.items) |*pkg| pkg.deinit();
                        pkgs.deinit(ctx.allocator);
                    }
                    for (pkgs.items) |*pkg| {
                        const owned_pkg = pkg.*;
                        pkg.* = package_mod.Package.init(ctx);
                        try appendUniqueSelectedPackage(ctx, &selected, &seen, owned_pkg);
                    }
                }
                if (!found_arch) {
                    return ctx.fail(RepoError.InvalidInput, name, "package name not found in local dev repo");
                }
            },
            .exact => |sel| {
                const pkg = try repo_db.getPackageExact(sel.name, sel.version, sel.release, sel.arch);
                try appendUniqueSelectedPackage(ctx, &selected, &seen, pkg);
            },
        }
    }

    return selected;
}

test "parseSelector supports name-only" {
    const sel = try parseSelector("hello");
    switch (sel) {
        .name_only => |name| try std.testing.expectEqualStrings("hello", name),
        else => try std.testing.expect(false),
    }
}

test "parseSelector supports exact selector" {
    const sel = try parseSelector("hello@1.2.3-4:x86_64");
    switch (sel) {
        .exact => |exact| {
            try std.testing.expectEqualStrings("hello", exact.name);
            try std.testing.expectEqualStrings("1.2.3", exact.version);
            try std.testing.expectEqual(@as(u32, 4), exact.release);
            try std.testing.expectEqualStrings("x86_64", exact.arch);
        },
        else => try std.testing.expect(false),
    }
}

test "parseSelector rejects invalid selectors" {
    try std.testing.expectError(error.InvalidInput, parseSelector(""));
    try std.testing.expectError(error.InvalidInput, parseSelector("@1.2.3-1:x86_64"));
    try std.testing.expectError(error.InvalidInput, parseSelector("hello@1.2.3:x86_64"));
    try std.testing.expectError(error.InvalidInput, parseSelector("hello@1.2.3-a:x86_64"));
    try std.testing.expectError(error.InvalidInput, parseSelector("hello@1.2.3-1:"));
}

test "publish rejects keep count below 1" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    try std.testing.expectError(
        RepoError.InvalidInput,
        publish(&test_env.ctx, "repo", test_env.path, &.{}, 0),
    );
}

fn makeTestPkg(ctx: *mere.Context, name: []const u8, version: []const u8, release: u32, hash: []const u8) !package_mod.Package {
    var pkg = package_mod.Package.init(ctx);
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, version);
    pkg.release = release;
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    pkg.content_hash = try ctx.allocator.dupe(u8, hash);
    pkg.archive_hash = try ctx.allocator.dupe(u8, hash);
    pkg.signature = try ctx.allocator.dupe(u8, "deadbeef");
    return pkg;
}

fn createPoolArchive(ctx: *mere.Context, name: []const u8, version: []const u8, release: u32, arch: []const u8, hash: []const u8) !void {
    const pool_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "cache", "packages" });
    defer ctx.allocator.free(pool_dir);
    try std.fs.cwd().makePath(pool_dir);

    const archive_name = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}-{d}-{s}-{s}.pkg.tar.zst", .{ name, version, release, arch, hash });
    defer ctx.allocator.free(archive_name);
    const archive_path = try std.fs.path.join(ctx.allocator, &.{ pool_dir, archive_name });
    defer ctx.allocator.free(archive_path);

    var file = try path.makePathAndOpenFile(archive_path);
    defer file.close();
    try file.writeAll("archive");
}

fn countPublishedPackages(ctx: *mere.Context, output_dir: []const u8) !u32 {
    const db_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "repo.db" });
    defer ctx.allocator.free(db_path);

    var db = try RepoDB.init(ctx, db_path, true);
    defer {
        db.deinit();
        ctx.allocator.destroy(db);
    }

    const sqlite_db = db.db orelse return error.FileSystem;
    const sql = "SELECT COUNT(*) FROM packages;";
    var stmt: ?*repodb_c.sqlite3_stmt = null;
    if (repodb_c.sqlite3_prepare_v2(sqlite_db, sql.ptr, @intCast(sql.len), &stmt, null) != repodb_c.SQLITE_OK or stmt == null) {
        return error.FileSystem;
    }
    defer _ = repodb_c.sqlite3_finalize(stmt.?);
    if (repodb_c.sqlite3_step(stmt.?) != repodb_c.SQLITE_ROW) return error.FileSystem;
    return @intCast(repodb_c.sqlite3_column_int(stmt.?, 0));
}

test "publish with keep count selects latest local versions on initial publish" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", "local" });
    defer ctx.allocator.free(repo_dir);
    try repository.setupStateLayout(ctx.allocator, repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    var pkg4 = try makeTestPkg(ctx, "llvm", "21.1.8", 4, "4" ** 64);
    defer pkg4.deinit();
    _ = try repo.db.insertPackageTransaction(&pkg4);
    try createPoolArchive(ctx, "llvm", "21.1.8", 4, "x86_64", "4" ** 64);

    var pkg5 = try makeTestPkg(ctx, "llvm", "21.1.8", 5, "5" ** 64);
    defer pkg5.deinit();
    _ = try repo.db.insertPackageTransaction(&pkg5);
    try createPoolArchive(ctx, "llvm", "21.1.8", 5, "x86_64", "5" ** 64);

    var pkg6 = try makeTestPkg(ctx, "llvm", "21.1.8", 6, "6" ** 64);
    defer pkg6.deinit();
    _ = try repo.db.insertPackageTransaction(&pkg6);
    try createPoolArchive(ctx, "llvm", "21.1.8", 6, "x86_64", "6" ** 64);

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out" });
    defer ctx.allocator.free(output_dir);

    const result = try publish(ctx, "local", output_dir, &.{}, 2);
    try std.testing.expectEqual(@as(usize, 2), result.applied_count);
    try std.testing.expectEqual(@as(u32, 2), try countPublishedPackages(ctx, output_dir));

    const pkg5_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages", "llvm-21.1.8-5-x86_64-" ++ ("5" ** 64) ++ ".pkg.tar.zst" });
    defer ctx.allocator.free(pkg5_path);
    try std.fs.accessAbsolute(pkg5_path, .{});

    const pkg6_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages", "llvm-21.1.8-6-x86_64-" ++ ("6" ** 64) ++ ".pkg.tar.zst" });
    defer ctx.allocator.free(pkg6_path);
    try std.fs.accessAbsolute(pkg6_path, .{});
}

test "publish with keep count retains published baseline lineage" {
    const th = @import("test_helpers.zig");
    const repository = @import("repository.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "dev", "repo", "local" });
    defer ctx.allocator.free(repo_dir);
    try repository.setupStateLayout(ctx.allocator, repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    var pkg6 = try makeTestPkg(ctx, "llvm", "21.1.8", 6, "6" ** 64);
    defer pkg6.deinit();
    _ = try repo.db.insertPackageTransaction(&pkg6);
    try createPoolArchive(ctx, "llvm", "21.1.8", 6, "x86_64", "6" ** 64);
    try createPoolArchive(ctx, "llvm", "21.1.8", 5, "x86_64", "5" ** 64);

    const output_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "published-out-existing" });
    defer ctx.allocator.free(output_dir);
    try std.fs.cwd().makePath(output_dir);

    const output_db = try std.fs.path.join(ctx.allocator, &.{ output_dir, "repo.db" });
    defer ctx.allocator.free(output_db);
    var published_db = try RepoDB.init(ctx, output_db, false);
    defer {
        published_db.deinit();
        ctx.allocator.destroy(published_db);
    }

    var pkg5 = try makeTestPkg(ctx, "llvm", "21.1.8", 5, "5" ** 64);
    defer pkg5.deinit();
    _ = try published_db.insertPackageTransaction(&pkg5);

    const result = try publish(ctx, "local", output_dir, &.{}, 2);
    try std.testing.expectEqual(@as(usize, 1), result.applied_count);
    try std.testing.expectEqual(@as(u32, 2), try countPublishedPackages(ctx, output_dir));

    const pkg5_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages", "llvm-21.1.8-5-x86_64-" ++ ("5" ** 64) ++ ".pkg.tar.zst" });
    defer ctx.allocator.free(pkg5_path);
    try std.fs.accessAbsolute(pkg5_path, .{});

    const pkg6_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "packages", "llvm-21.1.8-6-x86_64-" ++ ("6" ** 64) ++ ".pkg.tar.zst" });
    defer ctx.allocator.free(pkg6_path);
    try std.fs.accessAbsolute(pkg6_path, .{});
}
