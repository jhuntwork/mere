const std = @import("std");
const mere = @import("../mere.zig");
const recipe = @import("../recipe.zig");
const test_helpers = @import("../test_helpers.zig");

pub const BuildEnvironmentConfig = struct {
    sources_dir: []const u8,
    build_dir: []const u8,
    destdir: []const u8,
    recipe_env: []const recipe.KV = &.{},
};

pub fn createHostBuildEnv(ctx: *mere.Context, config: BuildEnvironmentConfig) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(ctx.allocator);
    errdefer env.deinit();

    try setVar(ctx, &env, "PATH", "/bin:/usr/bin:/sbin:/usr/sbin");
    try setVar(ctx, &env, "PREFIX", "/usr");
    try setVar(ctx, &env, "CFLAGS", "-O2 -pipe -ffunction-sections -fdata-sections -Werror-implicit-function-declaration");
    try setVar(ctx, &env, "CXXFLAGS", "-O2 -pipe -ffunction-sections -fdata-sections -Werror-implicit-function-declaration");
    try setVar(ctx, &env, "LDFLAGS", "-Wl,--gc-sections");
    try setVar(ctx, &env, "MERE_BUILD_DIR", config.build_dir);
    try setVar(ctx, &env, "MERE_SOURCES_DIR", config.sources_dir);
    try setVar(ctx, &env, "MERE_DESTDIR", config.destdir);
    try setVar(ctx, &env, "DESTDIR", config.destdir);
    try setBuildAppDataDirs(ctx, &env, config.build_dir);

    try applyEnvOverrides(ctx, &env, config.recipe_env);
    return env;
}

pub fn createPhaseHostEnv(
    ctx: *mere.Context,
    base_env: *const std.process.Environ.Map,
    phase_env: []const recipe.KV,
) !std.process.Environ.Map {
    var env = try cloneEnvMap(ctx.allocator, base_env);
    errdefer env.deinit();
    try applyEnvOverrides(ctx, &env, phase_env);
    return env;
}

fn setVar(ctx: *mere.Context, env: *std.process.Environ.Map, key: []const u8, value: []const u8) !void {
    env.put(key, value) catch {
        return ctx.fail(error.OutOfMemory, key, "failed to set environment variable");
    };
}

fn setBuildAppDataDirs(ctx: *mere.Context, env: *std.process.Environ.Map, build_dir: []const u8) !void {
    try setVar(ctx, env, "HOME", build_dir);
    try setBuildSubdirVar(ctx, env, build_dir, ".cache", "XDG_CACHE_HOME");
    try setBuildSubdirVar(ctx, env, build_dir, ".config", "XDG_CONFIG_HOME");
    try setBuildSubdirVar(ctx, env, build_dir, ".local/state", "XDG_STATE_HOME");
    try setBuildSubdirVar(ctx, env, build_dir, ".local/share", "XDG_DATA_HOME");
}

fn setBuildSubdirVar(
    ctx: *mere.Context,
    env: *std.process.Environ.Map,
    build_dir: []const u8,
    subdir: []const u8,
    key: []const u8,
) !void {
    const path = std.fs.path.join(ctx.allocator, &.{ build_dir, subdir }) catch {
        return ctx.fail(error.OutOfMemory, key, "failed to allocate environment path");
    };
    defer ctx.allocator.free(path);
    try setVar(ctx, env, key, path);
}

fn applyEnvOverrides(ctx: *mere.Context, env: *std.process.Environ.Map, vars: []const recipe.KV) !void {
    for (vars) |kv| {
        try setVar(ctx, env, kv.key, kv.value);
    }
}

fn cloneEnvMap(allocator: std.mem.Allocator, src: *const std.process.Environ.Map) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();

    var it = src.iterator();
    while (it.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return env;
}

test "createHostBuildEnv sets deterministic base variables" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var env = try createHostBuildEnv(&test_env.ctx, .{
        .sources_dir = "/tmp/sources",
        .build_dir = "/tmp/build-src",
        .destdir = "/tmp/dest",
    });
    defer env.deinit();

    try std.testing.expectEqualStrings("/bin:/usr/bin:/sbin:/usr/sbin", env.get("PATH").?);
    try std.testing.expectEqualStrings("/usr", env.get("PREFIX").?);
    try std.testing.expectEqualStrings("/tmp/build-src", env.get("MERE_BUILD_DIR").?);
    try std.testing.expectEqualStrings("/tmp/sources", env.get("MERE_SOURCES_DIR").?);
    try std.testing.expectEqualStrings("/tmp/dest", env.get("MERE_DESTDIR").?);
    try std.testing.expectEqualStrings("/tmp/dest", env.get("DESTDIR").?);
    try std.testing.expectEqualStrings("/tmp/build-src", env.get("HOME").?);
    try std.testing.expectEqualStrings("/tmp/build-src/.cache", env.get("XDG_CACHE_HOME").?);
    try std.testing.expectEqualStrings("/tmp/build-src/.config", env.get("XDG_CONFIG_HOME").?);
    try std.testing.expectEqualStrings("/tmp/build-src/.local/state", env.get("XDG_STATE_HOME").?);
    try std.testing.expectEqualStrings("/tmp/build-src/.local/share", env.get("XDG_DATA_HOME").?);
}

test "createHostBuildEnv applies recipe env over defaults" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const vars = [_]recipe.KV{
        .{ .key = "CFLAGS", .value = "-O2 -march=x86-64" },
        .{ .key = "LDFLAGS", .value = "-static" },
        .{ .key = "HOME", .value = "/tmp/custom-home" },
    };

    var env = try createHostBuildEnv(&test_env.ctx, .{
        .sources_dir = "/tmp/sources",
        .build_dir = "/tmp/build-src",
        .destdir = "/tmp/dest",
        .recipe_env = &vars,
    });
    defer env.deinit();

    try std.testing.expectEqualStrings("-O2 -march=x86-64", env.get("CFLAGS").?);
    try std.testing.expectEqualStrings("-static", env.get("LDFLAGS").?);
    try std.testing.expectEqualStrings("-O2 -pipe -ffunction-sections -fdata-sections -Werror-implicit-function-declaration", env.get("CXXFLAGS").?);
    try std.testing.expectEqualStrings("/tmp/custom-home", env.get("HOME").?);
}

test "createPhaseHostEnv overlays phase env without mutating base env" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const recipe_vars = [_]recipe.KV{
        .{ .key = "CC", .value = "clang" },
        .{ .key = "CFLAGS", .value = "-O2" },
    };
    var base_env = try createHostBuildEnv(&test_env.ctx, .{
        .sources_dir = "/tmp/sources",
        .build_dir = "/tmp/build-src",
        .destdir = "/tmp/dest",
        .recipe_env = &recipe_vars,
    });
    defer base_env.deinit();

    const phase_vars = [_]recipe.KV{
        .{ .key = "CFLAGS", .value = "-O0 -g" },
        .{ .key = "PHASE_ONLY", .value = "1" },
    };

    var phase_env = try createPhaseHostEnv(&test_env.ctx, &base_env, &phase_vars);
    defer phase_env.deinit();

    try std.testing.expectEqualStrings("-O2", base_env.get("CFLAGS").?);
    try std.testing.expect(phase_env.get("PHASE_ONLY") != null);
    try std.testing.expectEqualStrings("-O0 -g", phase_env.get("CFLAGS").?);
    try std.testing.expectEqualStrings("clang", phase_env.get("CC").?);
}
