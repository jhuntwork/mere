const std = @import("std");
const activation = @import("activation.zig");
const archive = @import("archive.zig");
const config = @import("config.zig");
const download = @import("download.zig");
const generation = @import("generation.zig");
const hash = @import("hash.zig");
const import_mod = @import("import.zig");
const install = @import("install.zig");
const manifest = @import("manifest.zig");
const path = @import("path.zig");
const profile = @import("profile.zig");
const projection_index = @import("projection_index.zig");
const sign = @import("sign.zig");
const store = @import("store.zig");
const test_helpers = @import("test_helpers.zig");

const package_count = 8;
const files_per_package = 24;
const bytes_per_file = 1024;
const cold_install_samples = 5;
const warm_install_samples = 9;
const generation_samples = 7;
const activation_samples = 11;

fn monotonicNs() i128 {
    return std.Io.Clock.Timestamp.now(path.currentIo(), .awake).raw.toNanoseconds();
}

fn elapsedNs(started_at: i128) u64 {
    return @intCast(monotonicNs() - started_at);
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn printResult(name: []const u8, samples: []u64) void {
    const value_ns = median(samples);
    std.debug.print("{s}\t{d}\t{d}\n", .{ name, samples.len, value_ns / std.time.ns_per_us });
}

fn createBenchmarkPackage(ctx: anytype, fixture_root: []const u8, package_index: usize) ![]const u8 {
    const name = try std.fmt.allocPrint(ctx.allocator, "bench-{d:0>2}", .{package_index});
    errdefer ctx.allocator.free(name);

    const staging = try std.fs.path.join(ctx.allocator, &.{ fixture_root, "package-staging", name });
    defer ctx.allocator.free(staging);
    try path.ensureDirExists(staging);

    const payload_dir = try std.fs.path.join(ctx.allocator, &.{ staging, "usr", "share", "mere-benchmark", name });
    defer ctx.allocator.free(payload_dir);
    try path.ensureDirExists(payload_dir);

    var payload: [bytes_per_file]u8 = undefined;
    @memset(&payload, @intCast('a' + package_index % 26));
    for (0..files_per_package) |file_index| {
        const file_path = try std.fmt.allocPrint(ctx.allocator, "{s}/file-{d:0>3}", .{ payload_dir, file_index });
        defer ctx.allocator.free(file_path);
        var file = try path.makePathAndOpenFile(file_path);
        try file.writeStreamingAll(path.currentIo(), &payload);
        file.close(path.currentIo());
    }

    const content_hash = try hash.calculateStoreContentHash(ctx.allocator, staging, null);
    defer ctx.allocator.free(content_hash);
    var content_hash_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&content_hash_bytes, content_hash);

    const metadata_dir = try std.fs.path.join(ctx.allocator, &.{ staging, manifest.META_DIR });
    defer ctx.allocator.free(metadata_dir);
    try path.ensureDirExists(metadata_dir);

    const secret_key_path = try std.fs.path.join(ctx.allocator, &.{ fixture_root, ".mere", "keys", "mere.key" });
    defer ctx.allocator.free(secret_key_path);
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);
    const package_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = 1706745600,
        .release = 1,
        .arch = test_helpers.host_arch,
        .name = name,
        .version = "1.0.0",
        .content_hash = content_hash_bytes,
    };
    try manifest.writeManifest(ctx, staging, &package_manifest, &secret_key.key);

    var projection = try projection_index.deriveFromPayload(ctx.allocator, staging);
    defer projection.deinit();
    try projection_index.writeFile(ctx.allocator, staging, &projection);

    const archive_path = try std.fmt.allocPrint(ctx.allocator, "{s}/archives/{s}.mpk", .{ fixture_root, name });
    defer ctx.allocator.free(archive_path);
    const archive_dir = std.fs.path.dirname(archive_path).?;
    try path.ensureDirExists(archive_dir);
    try archive.createPackageArchive(ctx, staging, archive_path);

    ctx.signing_key_path = secret_key_path;
    const one = [_][]const u8{archive_path};
    try import_mod.packages(ctx, "benchmark", one[0..], false);
    return name;
}

fn makeWritable(target: []const u8) void {
    const io = path.currentIo();
    var dir = std.Io.Dir.openDirAbsolute(io, target, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(std.heap.page_allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                var child = dir.openDir(io, entry.path, .{ .iterate = true }) catch continue;
                defer child.close(io);
                const stat = child.stat(io) catch continue;
                child.setPermissions(io, .fromMode(stat.permissions.toMode() | 0o200)) catch {};
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

fn resetInstallState(allocator: std.mem.Allocator, fixture_root: []const u8) !void {
    for ([_][]const u8{ "store", "profiles", "cache", "gc-roots" }) |leaf| {
        const target = try std.fs.path.join(allocator, &.{ fixture_root, "mere", leaf });
        defer allocator.free(target);
        _ = store.clearImmutable(allocator, target);
        makeWritable(target);
        path.deleteTreeAbsolute(target) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
}

test "install and activation performance baseline" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    var package_names: [package_count][]const u8 = undefined;
    for (0..package_count) |index| {
        package_names[index] = try createBenchmarkPackage(ctx, test_env.path, index);
    }
    defer for (package_names) |name| ctx.allocator.free(name);

    ctx.configuration = config.Config.init(ctx, ctx.allocator);
    defer {
        if (ctx.configuration) |*cfg| cfg.deinit();
        ctx.configuration = null;
    }

    var curl_client = try download.CurlTransferClient.init(ctx, "mere-performance-baseline");
    defer download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    var cold_times: [cold_install_samples]u64 = undefined;
    for (&cold_times) |*sample| {
        try resetInstallState(ctx.allocator, test_env.path);
        ctx.resetDiagnostics();
        const started_at = monotonicNs();
        _ = try install.installPackagesFromConfig(ctx, &package_names, client, false, false, false, "benchmark");
        sample.* = elapsedNs(started_at);
    }

    var warm_times: [warm_install_samples]u64 = undefined;
    for (&warm_times) |*sample| {
        ctx.resetDiagnostics();
        const started_at = monotonicNs();
        _ = try install.installPackagesFromConfig(ctx, &package_names, client, false, false, false, "benchmark");
        sample.* = elapsedNs(started_at);
    }

    const store_root = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "store" });
    defer ctx.allocator.free(store_root);
    const named_profile_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "benchmark" });
    defer ctx.allocator.free(named_profile_dir);
    const named_root = try profile.getRootPath(ctx.allocator, named_profile_dir);
    defer ctx.allocator.free(named_root);
    var installed_manifest = try generation.readManifest(ctx.allocator, store_root, named_root);
    defer installed_manifest.deinit();

    const generation_profile_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "generation-benchmark" });
    defer ctx.allocator.free(generation_profile_dir);
    try path.ensureDirExists(generation_profile_dir);

    var generation_times: [generation_samples]u64 = undefined;
    var generation_numbers: [generation_samples]u32 = undefined;
    var parent: ?u32 = null;
    for (&generation_times, &generation_numbers) |*sample, *number| {
        const started_at = monotonicNs();
        number.* = try profile.createGeneration(ctx, generation_profile_dir, store_root, installed_manifest.packages.items, parent);
        sample.* = elapsedNs(started_at);
        parent = number.*;
    }

    // Generation construction does not require privilege, but constructing a
    // profile literally named "system" enforces root-owned store objects.
    // Build under a neutral name, then publish the completed synthetic fixture
    // at the system path used by the activation API.
    const system_profile_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer ctx.allocator.free(system_profile_dir);
    try std.Io.Dir.renameAbsolute(generation_profile_dir, system_profile_dir, path.currentIo());

    var fast_activation_times: [activation_samples]u64 = undefined;
    for (&fast_activation_times, 0..) |*sample, index| {
        const generation_number = generation_numbers[index % generation_numbers.len];
        const started_at = monotonicNs();
        _ = try activation.activateSystemGeneration(ctx, generation_number, .fast);
        sample.* = elapsedNs(started_at);
    }

    var full_activation_times: [activation_samples]u64 = undefined;
    for (&full_activation_times, 0..) |*sample, index| {
        const generation_number = generation_numbers[index % generation_numbers.len];
        const started_at = monotonicNs();
        _ = try activation.activateSystemGeneration(ctx, generation_number, .full_store);
        sample.* = elapsedNs(started_at);
    }

    std.debug.print(
        "\nMere install/activation performance baseline\n" ++
            "fixture\tpackages={d}\tfiles_per_package={d}\tbytes_per_file={d}\n" ++
            "scenario\tsamples\tmedian_us\n",
        .{ package_count, files_per_package, bytes_per_file },
    );
    printResult("cold_local_install", &cold_times);
    printResult("warm_noop_install", &warm_times);
    printResult("incremental_generation", &generation_times);
    printResult("fast_activation", &fast_activation_times);
    printResult("full_store_activation", &full_activation_times);
}
