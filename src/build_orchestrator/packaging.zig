const std = @import("std");
const build_artifacts = @import("artifact_model.zig");
const cache_solver = @import("cache_solver.zig");
const manpage_compress = @import("../manpage_compress.zig");
const mere = @import("../mere.zig");
const meta = @import("../meta.zig");
const hash = @import("../hash.zig");
const path_mod = @import("../path.zig");
const recipe = @import("../recipe.zig");
const packaging = @import("../packaging.zig");
const strip = @import("../strip.zig");
const cmake_fixup = @import("../cmake_fixup.zig");
const split_staging = @import("split_staging.zig");

const ui = mere.ui;
const emit = mere.ui.emit;

pub const PackageError = error{
    OutOfMemory,
    FileSystem,
    PermissionDenied,
    InvalidInput,
    PackageCreationFailed,
};

pub const CreatePackageArtifactFn = *const fn (*mere.Context, packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult;
pub const EmitPackageMetadataReportFn = *const fn (std.mem.Allocator, *mere.Context, []const u8, usize, []const u8) void;
pub const PackageArchiveNodeRecorder = struct {
    ptr: *anyopaque,
    record_fn: *const fn (*anyopaque, build_artifacts.NodeExecutionKind, []const u8, []const u8) anyerror!void,

    pub fn record(self: PackageArchiveNodeRecorder, execution: build_artifacts.NodeExecutionKind, key_hex: []const u8, digest_hex: []const u8) !void {
        return self.record_fn(self.ptr, execution, key_hex, digest_hex);
    }
};

const InjectedDepsForPackage = struct {
    items: std.ArrayList(packaging.InjectedDependency),

    fn init() InjectedDepsForPackage {
        return .{ .items = .empty };
    }

    fn deinit(self: *InjectedDepsForPackage, allocator: std.mem.Allocator) void {
        for (self.items.items) |dep| {
            allocator.free(dep.value);
            if (dep.version_constraint) |expr| allocator.free(expr);
        }
        self.items.deinit(allocator);
    }
};

const PackageArchiveJob = struct {
    artifact: *recipe.BuildArtifact,
    staged: split_staging.StagedPackage,
    output_dir: []const u8,
    package_cache_key: []const u8,
    injected_dependencies: []const packaging.InjectedDependency,
};

const PackageArchiveFailure = struct {
    err: anyerror,
    subject: ?[]const u8,
    details: ?[]const u8,
};

const PackageArchiveJobState = struct {
    arena: std.heap.ArenaAllocator,
    job: PackageArchiveJob,
    result: ?packaging.PackageArtifactResult = null,
    failure: ?PackageArchiveFailure = null,

    fn init(job: PackageArchiveJob) PackageArchiveJobState {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .job = job,
            .result = null,
            .failure = null,
        };
    }

    fn deinit(self: *PackageArchiveJobState) void {
        if (self.result) |*result| {
            result.deinit(self.arena.allocator());
        }
        self.arena.deinit();
    }
};

const PackageArchiveWorkerShared = struct {
    root_path: []const u8,
    home_dir: ?[]const u8,
    signing_key_path: ?[]const u8,
    stop_on_error: bool,
    create_package_artifact_fn: CreatePackageArtifactFn,
    parsed_recipe: *recipe.Recipe,
    jobs: []PackageArchiveJobState,
    mutex: std.Io.Mutex = .init,
    next_index: usize = 0,
    failure_seen: bool = false,
};

const PackageArchiveWorker = struct {
    shared: *PackageArchiveWorkerShared,

    fn run(self: *@This()) void {
        while (true) {
            const index = self.nextJobIndex() orelse return;
            self.runJob(index);
        }
    }

    fn nextJobIndex(self: *@This()) ?usize {
        self.shared.mutex.lockUncancelable(path_mod.currentIo());
        defer self.shared.mutex.unlock(path_mod.currentIo());

        if (self.shared.stop_on_error and self.shared.failure_seen) return null;
        if (self.shared.next_index >= self.shared.jobs.len) return null;

        const index = self.shared.next_index;
        self.shared.next_index += 1;
        return index;
    }

    fn noteFailure(self: *@This()) void {
        self.shared.mutex.lockUncancelable(path_mod.currentIo());
        defer self.shared.mutex.unlock(path_mod.currentIo());
        self.shared.failure_seen = true;
    }

    fn runJob(self: *@This(), index: usize) void {
        var state = &self.shared.jobs[index];
        const worker_alloc = state.arena.allocator();
        var worker_ctx = mere.Context.init(worker_alloc, self.shared.root_path);
        defer worker_ctx.deinit();
        worker_ctx.home_dir = self.shared.home_dir;
        worker_ctx.signing_key_path = self.shared.signing_key_path;

        const cfg = packaging.PackageArtifactConfig{
            .staging_dir = state.job.staged.staging_dir,
            .recipe = self.shared.parsed_recipe,
            .artifact = state.job.artifact,
            .output_dir = state.job.output_dir,
            .injected_dependencies = state.job.injected_dependencies,
        };

        state.result = self.shared.create_package_artifact_fn(&worker_ctx, cfg) catch |err| {
            const diag = worker_ctx.getDiagnosticContext();
            state.failure = .{
                .err = err,
                .subject = diag.subject,
                .details = diag.details,
            };
            if (self.shared.stop_on_error) self.noteFailure();
            return;
        };
    }
};

pub fn packageArtifacts(
    allocator: std.mem.Allocator,
    ctx_opt: ?*mere.Context,
    stop_on_error: bool,
    cache: bool,
    create_package_artifact_fn: CreatePackageArtifactFn,
    parsed_recipe: *recipe.Recipe,
    staged_packages: []const split_staging.StagedPackage,
    packaged_archives: *std.ArrayList([]const u8),
    packaging_errors_encountered: *bool,
    emit_package_metadata_report: EmitPackageMetadataReportFn,
    package_archive_node_recorder: ?PackageArchiveNodeRecorder,
) PackageError!void {
    const ctx = ctx_opt orelse return error.InvalidInput;
    ctx.setDiagnosticContext(parsed_recipe.name, null);

    if (staged_packages.len == 0) return;

    const injected_by_pkg = try buildInjectedDependenciesForSplit(allocator, ctx, parsed_recipe, staged_packages);
    defer {
        for (injected_by_pkg) |*entry| entry.deinit(allocator);
        allocator.free(injected_by_pkg);
    }

    var package_jobs: std.ArrayList(PackageArchiveJobState) = .empty;
    defer {
        for (package_jobs.items) |*job| job.deinit();
        package_jobs.deinit(allocator);
    }

    var ci: usize = 0;
    while (ci < staged_packages.len) : (ci += 1) {
        const staged = staged_packages[ci];
        const artifact = &parsed_recipe.packages.items[staged.pkg_index];
        const staging_dir = staged.staging_dir;

        try prepareArtifactStaging(allocator, ctx, staging_dir, artifact.strip, artifact.compress_manpages, artifact.services.items);
        const packaged = try packageStagedPackage(
            allocator,
            ctx,
            cache,
            parsed_recipe,
            artifact,
            staged,
            injected_by_pkg,
            &package_jobs,
            packaged_archives,
            packaging_errors_encountered,
            emit_package_metadata_report,
            package_archive_node_recorder,
        );
        if (!packaged) continue;
    }

    try executePackageArchiveJobs(
        allocator,
        ctx,
        stop_on_error,
        create_package_artifact_fn,
        parsed_recipe,
        &package_jobs,
        packaged_archives,
        packaging_errors_encountered,
        emit_package_metadata_report,
        package_archive_node_recorder,
    );
}

fn prepareArtifactStaging(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    staging_dir: []const u8,
    strip_enabled: bool,
    compress_manpages_enabled: bool,
    services: []const recipe.ServiceDef,
) PackageError!void {
    const etc_path = std.fs.path.join(allocator, &.{ staging_dir, "etc" }) catch {
        return ctx.fail(error.OutOfMemory, staging_dir, "failed to build etc path");
    };
    defer allocator.free(etc_path);

    const etc_defaults_path = std.fs.path.join(allocator, &.{ staging_dir, "etc-defaults" }) catch {
        return ctx.fail(error.OutOfMemory, staging_dir, "failed to build etc-defaults path");
    };
    defer allocator.free(etc_defaults_path);

    std.Io.Dir.accessAbsolute(path_mod.currentIo(), etc_path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            ctx.setDiagnosticContext(etc_path, "failed to access etc directory");
            ctx.debug("etc access check failed: {s}", .{@errorName(err)});
        }
    };

    std.Io.Dir.renameAbsolute(etc_path, etc_defaults_path, path_mod.currentIo()) catch |err| {
        if (err != error.FileNotFound) {
            ctx.setDiagnosticContext(etc_path, "failed to relocate etc directory");
            ctx.debug("etc relocation skipped: {s}", .{@errorName(err)});
        }
    };

    for (services) |*svc| {
        try generateServiceSourceDir(allocator, ctx, staging_dir, svc);
    }

    if (compress_manpages_enabled) {
        if (manpage_compress.compressDirectory(ctx, staging_dir)) |cr| {
            if (cr.files_compressed > 0 or cr.symlinks_rewritten > 0) {
                ctx.debug(
                    "compressed {d} man pages and rewrote {d} symlinks in {s}",
                    .{ cr.files_compressed, cr.symlinks_rewritten, staging_dir },
                );
            }
        } else |err| {
            return switch (err) {
                error.OutOfMemory => ctx.fail(error.OutOfMemory, staging_dir, "failed to compress staged man pages"),
                error.FileSystem => ctx.fail(error.FileSystem, staging_dir, "failed to compress staged man pages"),
                error.Internal => ctx.fail(error.PackageCreationFailed, staging_dir, "failed to compress staged man pages"),
            };
        }
    }

    if (cmake_fixup.fixupStagingDir(allocator, staging_dir)) |cr| {
        if (cr.files_fixed > 0) {
            ctx.debug("fixed cmake store paths in {d} files in {s}", .{ cr.files_fixed, staging_dir });
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => ctx.fail(error.OutOfMemory, staging_dir, "failed to fix cmake store paths"),
            error.FileSystem => ctx.fail(error.FileSystem, staging_dir, "failed to fix cmake store paths"),
        };
    }

    if (!strip_enabled) return;
    if (strip.stripDirectory(ctx, staging_dir, null)) |sr| {
        if (sr.files_stripped > 0) {
            ctx.debug("stripped {d} files in {s}", .{ sr.files_stripped, staging_dir });
        }
        if (sr.files_failed > 0) {
            var failed_buf: [32]u8 = undefined;
            const failed_text = std.fmt.bufPrint(&failed_buf, "{d}", .{sr.files_failed}) catch {
                emit.logLineSeverity(ctx, .build, .warn, "strip skipped files; rerun with -v for file-level failures");
                return;
            };
            const segments = [_]ui.Segment{
                .{ .text = "strip ", .kind = .normal },
                .{ .text = "skipped", .kind = .warn },
                .{ .text = " ", .kind = .normal },
                .{ .text = failed_text, .kind = .detail },
                .{ .text = " files in ", .kind = .normal },
                .{ .text = staging_dir, .kind = .detail },
                .{ .text = "; rerun with -v for file-level failures", .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .build, .warn, &segments);
        }
    } else |err| {
        return switch (err) {
            error.OutOfMemory => ctx.fail(error.OutOfMemory, staging_dir, "failed to strip staged package outputs"),
            error.FileSystem => ctx.fail(error.FileSystem, staging_dir, "failed to strip staged package outputs"),
        };
    }
}

fn generateServiceSourceDir(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    staging_dir: []const u8,
    svc: *const recipe.ServiceDef,
) PackageError!void {
    const io = path_mod.currentIo();

    const svc_dir = std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", svc.name }) catch
        return ctx.fail(error.OutOfMemory, staging_dir, "failed to build service source path");
    defer allocator.free(svc_dir);
    path_mod.ensureDirExists(svc_dir) catch |err|
        return ctx.fail(mapPackageFsError(err), svc_dir, "failed to create service source directory");

    var dir = std.Io.Dir.openDirAbsolute(io, svc_dir, .{}) catch |err|
        return ctx.fail(mapPackageFsError(err), svc_dir, "failed to open service source directory");
    defer dir.close(io);

    // type
    writeServiceFile(ctx, dir, io, "type", if (svc.service_type == .daemon) "longrun\n" else "oneshot\n") catch |err|
        return ctx.fail(err, svc_dir, "failed to write service type file");

    switch (svc.service_type) {
        .daemon => {
            var run_buf: std.ArrayList(u8) = .empty;
            defer run_buf.deinit(allocator);
            run_buf.appendSlice(allocator, "#!/bin/execlineb -P\nfdmove -c 2 1\n") catch return error.OutOfMemory;
            for (svc.command.items, 0..) |arg, i| {
                if (i > 0) run_buf.append(allocator, ' ') catch return error.OutOfMemory;
                run_buf.appendSlice(allocator, arg) catch return error.OutOfMemory;
            }
            run_buf.append(allocator, '\n') catch return error.OutOfMemory;
            writeServiceFile(ctx, dir, io, "run", run_buf.items) catch |err|
                return ctx.fail(err, svc_dir, "failed to write service run script");

            const log_name = std.fmt.allocPrint(allocator, "{s}-log\n", .{svc.name}) catch return error.OutOfMemory;
            defer allocator.free(log_name);
            if (svc.log) {
                writeServiceFile(ctx, dir, io, "producer-for", log_name) catch |err|
                    return ctx.fail(err, svc_dir, "failed to write producer-for");
            }

            if (svc.ready_notification) |fd| {
                var fd_buf: [20]u8 = undefined;
                const fd_str = std.fmt.bufPrint(&fd_buf, "{d}\n", .{fd}) catch return error.OutOfMemory;
                writeServiceFile(ctx, dir, io, "notification-fd", fd_str) catch |err|
                    return ctx.fail(err, svc_dir, "failed to write notification-fd");
            }

            if (svc.log) {
                try generateLogServiceDir(allocator, ctx, staging_dir, svc.name);
            }
        },
        .oneshot => {
            if (svc.up.items.len > 0) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                buf.appendSlice(allocator, "#!/bin/execlineb -P\n") catch return error.OutOfMemory;
                for (svc.up.items) |arg| {
                    buf.appendSlice(allocator, arg) catch return error.OutOfMemory;
                    buf.append(allocator, ' ') catch return error.OutOfMemory;
                }
                buf.append(allocator, '\n') catch return error.OutOfMemory;
                writeServiceFile(ctx, dir, io, "up", buf.items) catch |err|
                    return ctx.fail(err, svc_dir, "failed to write oneshot up script");
            }
            if (svc.down.items.len > 0) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                buf.appendSlice(allocator, "#!/bin/execlineb -P\n") catch return error.OutOfMemory;
                for (svc.down.items) |arg| {
                    buf.appendSlice(allocator, arg) catch return error.OutOfMemory;
                    buf.append(allocator, ' ') catch return error.OutOfMemory;
                }
                buf.append(allocator, '\n') catch return error.OutOfMemory;
                writeServiceFile(ctx, dir, io, "down", buf.items) catch |err|
                    return ctx.fail(err, svc_dir, "failed to write oneshot down script");
            }
        },
    }

    if (svc.depends_on.items.len > 0) {
        const deps_dir = std.fs.path.join(allocator, &.{ svc_dir, "dependencies.d" }) catch return error.OutOfMemory;
        defer allocator.free(deps_dir);
        path_mod.ensureDirExists(deps_dir) catch |err|
            return ctx.fail(mapPackageFsError(err), deps_dir, "failed to create dependencies.d");
        var deps_handle = std.Io.Dir.openDirAbsolute(io, deps_dir, .{}) catch |err|
            return ctx.fail(mapPackageFsError(err), deps_dir, "failed to open dependencies.d");
        defer deps_handle.close(io);
        for (svc.depends_on.items) |dep| {
            var f = deps_handle.createFile(io, dep, .{}) catch |err|
                return ctx.fail(mapPackageFsError(err), deps_dir, "failed to create dependency file");
            f.close(io);
        }
    }

    if (svc.essential) {
        writeServiceFile(ctx, dir, io, "flag-essential", "") catch |err|
            return ctx.fail(err, svc_dir, "failed to write flag-essential");
    }

    ctx.debug("generated s6-rc source: {s}", .{svc.name});
}

fn generateLogServiceDir(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    staging_dir: []const u8,
    service_name: []const u8,
) PackageError!void {
    const io = path_mod.currentIo();

    const log_name = std.fmt.allocPrint(allocator, "{s}-log", .{service_name}) catch return error.OutOfMemory;
    defer allocator.free(log_name);

    const log_dir = std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", log_name }) catch return error.OutOfMemory;
    defer allocator.free(log_dir);
    path_mod.ensureDirExists(log_dir) catch |err|
        return ctx.fail(mapPackageFsError(err), log_dir, "failed to create log service directory");

    var dir = std.Io.Dir.openDirAbsolute(io, log_dir, .{}) catch |err|
        return ctx.fail(mapPackageFsError(err), log_dir, "failed to open log service directory");
    defer dir.close(io);

    writeServiceFile(ctx, dir, io, "type", "longrun\n") catch |err|
        return ctx.fail(err, log_dir, "failed to write log type");

    const consumer_for = std.fmt.allocPrint(allocator, "{s}\n", .{service_name}) catch return error.OutOfMemory;
    defer allocator.free(consumer_for);
    writeServiceFile(ctx, dir, io, "consumer-for", consumer_for) catch |err|
        return ctx.fail(err, log_dir, "failed to write consumer-for");

    const pipeline_name = std.fmt.allocPrint(allocator, "{s}-pipeline\n", .{service_name}) catch return error.OutOfMemory;
    defer allocator.free(pipeline_name);
    writeServiceFile(ctx, dir, io, "pipeline-name", pipeline_name) catch |err|
        return ctx.fail(err, log_dir, "failed to write pipeline-name");

    const run_script = std.fmt.allocPrint(allocator, "#!/bin/execlineb -P\ns6-log -b -- t /var/log/{s}\n", .{service_name}) catch return error.OutOfMemory;
    defer allocator.free(run_script);
    writeServiceFile(ctx, dir, io, "run", run_script) catch |err|
        return ctx.fail(err, log_dir, "failed to write log run script");
}

fn writeServiceFile(ctx: *mere.Context, dir: std.Io.Dir, io: std.Io, name: []const u8, content: []const u8) PackageError!void {
    _ = ctx;
    var f = dir.createFile(io, name, .{}) catch |err| return mapPackageFsError(err);
    defer f.close(io);
    f.writeStreamingAll(io, content) catch |err| return mapPackageFsError(err);
}

fn mapPackageFsError(err: anyerror) PackageError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.PermissionDenied,
        else => error.FileSystem,
    };
}

fn packageStagedPackage(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    cache: bool,
    parsed_recipe: *recipe.Recipe,
    artifact: *recipe.BuildArtifact,
    staged: split_staging.StagedPackage,
    injected_by_pkg: []const InjectedDepsForPackage,
    package_jobs: *std.ArrayList(PackageArchiveJobState),
    packaged_archives: *std.ArrayList([]const u8),
    packaging_errors_encountered: *bool,
    emit_package_metadata_report: EmitPackageMetadataReportFn,
    package_archive_node_recorder: ?PackageArchiveNodeRecorder,
) PackageError!bool {
    const staging_dir = staged.staging_dir;
    const output_dir = std.fs.path.dirname(staging_dir) orelse staging_dir;

    var restored = cache_solver.restore(
        allocator,
        ctx,
        cache_solver.restorePackageArchiveRequest(
            cache,
            parsed_recipe,
            artifact,
            staging_dir,
            injected_by_pkg[staged.pkg_index].items.items,
            output_dir,
        ),
    ) catch |err| {
        packaging_errors_encountered.* = true;
        return switch (err) {
            error.OutOfMemory => ctx.fail(error.OutOfMemory, artifact.name, "failed to resolve package cache; out of memory"),
            error.PermissionDenied => ctx.fail(error.PermissionDenied, artifact.name, "failed to resolve package cache; permission denied on staging_dir or output_dir"),
            error.FileSystem => ctx.fail(error.PackageCreationFailed, artifact.name, "failed to resolve package cache; filesystem error reading staging or output directory"),
            error.InvalidInput => ctx.fail(error.PackageCreationFailed, artifact.name, "failed to resolve package cache; invalid input computing archive key"),
        };
    };
    if (restored) |*result| {
        defer result.deinit();
        const hit = result.package_archive;
        artifact.markBuilt(allocator, hit.archive_path, hit.content_hash, hit.archive_hash, hit.signature) catch {
            packaging_errors_encountered.* = true;
            return ctx.fail(error.PackageCreationFailed, artifact.name, "failed to restore cached package metadata");
        };

        const ap_dup = allocator.dupe(u8, hit.archive_path) catch {
            ctx.setDiagnosticContext(artifact.name, "failed to copy cached archive path");
            packaging_errors_encountered.* = true;
            return error.OutOfMemory;
        };

        packaged_archives.append(allocator, ap_dup) catch {
            allocator.free(ap_dup);
            ctx.setDiagnosticContext(artifact.name, "failed to record cached archive path");
            packaging_errors_encountered.* = true;
            return error.OutOfMemory;
        };

        const pkg_subject = if (artifact.name.len > 0) artifact.name else "artifact";
        const segments = [_]ui.Segment{
            .{ .text = pkg_subject, .kind = .normal },
            .{ .text = " packaged", .kind = .success },
            .{ .text = " from cache: ", .kind = .normal },
            .{ .text = hit.archive_path, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, .build, .info, &segments);
        emit_package_metadata_report(
            allocator,
            ctx,
            if (artifact.name.len > 0) artifact.name else parsed_recipe.name,
            staged.copied_files.len,
            staging_dir,
        );
        if (package_archive_node_recorder) |recorder| {
            recorder.record(.restored_from_cache, hit.key_hex, hit.archive_hash) catch {
                packaging_errors_encountered.* = true;
                return ctx.fail(error.OutOfMemory, artifact.name, "failed to record package archive node");
            };
        }

        return true;
    }

    var job_state = PackageArchiveJobState.init(.{
        .artifact = artifact,
        .staged = staged,
        .output_dir = output_dir,
        .package_cache_key = undefined,
        .injected_dependencies = injected_by_pkg[staged.pkg_index].items.items,
    });
    const package_key = cache_solver.packageArchiveKey(
        job_state.arena.allocator(),
        ctx,
        parsed_recipe,
        artifact,
        staging_dir,
        injected_by_pkg[staged.pkg_index].items.items,
    ) catch |err| {
        packaging_errors_encountered.* = true;
        return switch (err) {
            error.OutOfMemory => ctx.fail(error.OutOfMemory, artifact.name, "failed to compute package cache key"),
            error.PermissionDenied => ctx.fail(error.PermissionDenied, artifact.name, "failed to compute package cache key"),
            else => ctx.fail(error.PackageCreationFailed, artifact.name, "failed to compute package cache key"),
        };
    };
    job_state.job.package_cache_key = package_key;
    try package_jobs.append(allocator, job_state);

    return true;
}

fn executePackageArchiveJobs(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    stop_on_error: bool,
    create_package_artifact_fn: CreatePackageArtifactFn,
    parsed_recipe: *recipe.Recipe,
    package_jobs: *std.ArrayList(PackageArchiveJobState),
    packaged_archives: *std.ArrayList([]const u8),
    packaging_errors_encountered: *bool,
    emit_package_metadata_report: EmitPackageMetadataReportFn,
    package_archive_node_recorder: ?PackageArchiveNodeRecorder,
) PackageError!void {
    if (package_jobs.items.len == 0) return;

    var shared = PackageArchiveWorkerShared{
        .root_path = ctx.root(),
        .home_dir = ctx.home_dir,
        .signing_key_path = ctx.signing_key_path,
        .stop_on_error = stop_on_error,
        .create_package_artifact_fn = create_package_artifact_fn,
        .parsed_recipe = parsed_recipe,
        .jobs = package_jobs.items,
    };

    const worker_count: usize = @min(package_jobs.items.len, 4);
    var workers = try allocator.alloc(PackageArchiveWorker, worker_count);
    defer allocator.free(workers);
    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var wi: usize = 0;
    while (wi < worker_count) : (wi += 1) {
        workers[wi] = .{ .shared = &shared };
        threads[wi] = std.Thread.spawn(.{}, PackageArchiveWorker.run, .{&workers[wi]}) catch |err| {
            return switch (err) {
                error.OutOfMemory => ctx.fail(error.OutOfMemory, "package worker", "failed to spawn package archive worker"),
                else => ctx.fail(error.PackageCreationFailed, "package worker", "failed to spawn package archive worker"),
            };
        };
    }
    for (threads) |thread| thread.join();

    for (package_jobs.items) |*job_state| {
        if (job_state.failure) |failure| {
            packaging_errors_encountered.* = true;
            if (failure.subject) |subject| {
                ctx.setDiagnosticContext(subject, failure.details);
            } else if (failure.details) |details| {
                ctx.setDiagnosticContext("package artifact", details);
            } else {
                const pkg_subject = if (job_state.job.artifact.name.len > 0) job_state.job.artifact.name else "artifact";
                ctx.setDiagnosticContextFmt(pkg_subject, "failed to create package artifact: {s}", .{@errorName(failure.err)});
            }

            if (stop_on_error) {
                return switch (failure.err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.AccessDenied => error.PermissionDenied,
                    else => error.PackageCreationFailed,
                };
            }

            const pkg_subject = if (job_state.job.artifact.name.len > 0) job_state.job.artifact.name else "artifact";
            const segments = [_]ui.Segment{
                .{ .text = pkg_subject, .kind = .normal },
                .{ .text = " package failed", .kind = .warn },
            };
            emit.logSegmentsSeverity(ctx, .build, .warn, &segments);
            continue;
        }

        if (job_state.result) |*result| {
            try finalizePackageArchiveJob(
                allocator,
                ctx,
                parsed_recipe,
                &job_state.job,
                result,
                packaged_archives,
                packaging_errors_encountered,
                emit_package_metadata_report,
                package_archive_node_recorder,
            );
        }
    }
}

fn finalizePackageArchiveJob(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *recipe.Recipe,
    job: *const PackageArchiveJob,
    result: *const packaging.PackageArtifactResult,
    packaged_archives: *std.ArrayList([]const u8),
    packaging_errors_encountered: *bool,
    emit_package_metadata_report: EmitPackageMetadataReportFn,
    package_archive_node_recorder: ?PackageArchiveNodeRecorder,
) PackageError!void {
    job.artifact.markBuilt(allocator, result.archive_path, result.content_hash, result.archive_hash, result.signature) catch {
        packaging_errors_encountered.* = true;
        return ctx.fail(error.PackageCreationFailed, job.artifact.name, "failed to record package metadata");
    };

    const ap_dup = allocator.dupe(u8, result.archive_path) catch {
        ctx.setDiagnosticContext(job.artifact.name, "failed to copy archive path");
        packaging_errors_encountered.* = true;
        return error.OutOfMemory;
    };
    errdefer allocator.free(ap_dup);

    packaged_archives.append(allocator, ap_dup) catch {
        packaging_errors_encountered.* = true;
        ctx.setDiagnosticContext(job.artifact.name, "failed to record archive path");
        return error.OutOfMemory;
    };

    const pkg_subject = if (job.artifact.name.len > 0) job.artifact.name else "artifact";
    const segments = [_]ui.Segment{
        .{ .text = pkg_subject, .kind = .normal },
        .{ .text = " packaged", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = result.archive_path, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, .info, &segments);
    var files_buf: [32]u8 = undefined;
    var groups_buf: [32]u8 = undefined;
    var saved_buf: [32]u8 = undefined;
    const files_text = std.fmt.bufPrint(&files_buf, "{d}", .{result.deduplication.files_deduplicated}) catch return;
    const groups_text = std.fmt.bufPrint(&groups_buf, "{d}", .{result.deduplication.groups_deduplicated}) catch return;
    const saved_text = std.fmt.bufPrint(&saved_buf, "{d}", .{result.deduplication.bytes_saved}) catch return;
    const dedup_segments = [_]ui.Segment{
        .{ .text = "  dedup: files=", .kind = .normal },
        .{ .text = files_text, .kind = .detail },
        .{ .text = " groups=", .kind = .normal },
        .{ .text = groups_text, .kind = .detail },
        .{ .text = " bytes_saved=", .kind = .normal },
        .{ .text = saved_text, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, .info, &dedup_segments);

    emit_package_metadata_report(
        allocator,
        ctx,
        if (job.artifact.name.len > 0) job.artifact.name else parsed_recipe.name,
        job.staged.copied_files.len,
        job.staged.staging_dir,
    );

    if (package_archive_node_recorder) |recorder| {
        recorder.record(.executed, job.package_cache_key, result.archive_hash) catch {
            packaging_errors_encountered.* = true;
            return ctx.fail(error.OutOfMemory, job.artifact.name, "failed to record package archive node");
        };
    }

    var stored = cache_solver.persist(
        allocator,
        ctx,
        cache_solver.persistPackageArchiveRequest(
            parsed_recipe,
            job.artifact,
            job.staged.staging_dir,
            job.injected_dependencies,
            result,
        ),
    ) catch |err| {
        packaging_errors_encountered.* = true;
        return switch (err) {
            error.OutOfMemory => ctx.fail(error.OutOfMemory, job.artifact.name, "failed to persist package cache"),
            error.PermissionDenied => ctx.fail(error.PermissionDenied, job.artifact.name, "failed to persist package cache"),
            else => ctx.fail(error.PackageCreationFailed, job.artifact.name, "failed to persist package cache"),
        };
    };
    stored.deinit();
}

fn buildInjectedDependenciesForSplit(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    staged_packages: []const split_staging.StagedPackage,
) PackageError![]InjectedDepsForPackage {
    var injected = try allocator.alloc(InjectedDepsForPackage, parsed_recipe.packages.items.len);
    errdefer allocator.free(injected);
    for (injected) |*entry| entry.* = InjectedDepsForPackage.init();
    errdefer {
        for (injected) |*entry| entry.deinit(allocator);
    }

    var runtime_owner_by_stem = std.StringHashMap(usize).init(allocator);
    defer {
        var it = runtime_owner_by_stem.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        runtime_owner_by_stem.deinit();
    }

    for (staged_packages) |staged| {
        for (staged.copied_files) |rel_path| {
            const runtime_stem = runtimeLibraryStemForPath(rel_path) orelse continue;
            try recordRuntimeOwnerForStem(allocator, ctx, &runtime_owner_by_stem, runtime_stem, staged.pkg_index, rel_path);
        }
    }

    for (staged_packages) |staged| {
        var seen_runtime_pkgs = std.StringHashMap(void).init(allocator);
        defer {
            var seen_it = seen_runtime_pkgs.iterator();
            while (seen_it.next()) |entry| allocator.free(entry.key_ptr.*);
            seen_runtime_pkgs.deinit();
        }

        for (staged.copied_files) |rel_path| {
            const interface_stem = buildInterfaceStemForPath(rel_path) orelse continue;
            const owner_idx = runtime_owner_by_stem.get(interface_stem) orelse continue;
            if (owner_idx == staged.pkg_index) continue;

            const runtime_pkg_name = parsed_recipe.packages.items[owner_idx].name;
            if (runtime_pkg_name.len == 0) {
                return ctx.fail(error.InvalidInput, interface_stem, "runtime package name is empty");
            }
            if (seen_runtime_pkgs.contains(runtime_pkg_name)) continue;
            const runtime_pkg_name_copy = allocator.dupe(u8, runtime_pkg_name) catch {
                return ctx.fail(error.OutOfMemory, runtime_pkg_name, "failed to track injected runtime dependency");
            };
            seen_runtime_pkgs.put(runtime_pkg_name_copy, {}) catch {
                allocator.free(runtime_pkg_name_copy);
                return ctx.fail(error.OutOfMemory, runtime_pkg_name, "failed to track injected runtime dependency");
            };
            const exact_constraint = std.fmt.allocPrint(allocator, "={s}-{d}", .{
                parsed_recipe.version,
                parsed_recipe.release,
            }) catch {
                return ctx.fail(error.OutOfMemory, runtime_pkg_name, "failed to format injected dependency constraint");
            };
            defer allocator.free(exact_constraint);

            try appendInjectedDependency(
                allocator,
                &injected[staged.pkg_index],
                .split_runtime,
                runtime_pkg_name,
                exact_constraint,
            );
        }
    }

    return injected;
}

fn appendInjectedDependency(
    allocator: std.mem.Allocator,
    injected: *InjectedDepsForPackage,
    dep_type: meta.DependencyType,
    dep_name: []const u8,
    exact_constraint: []const u8,
) PackageError!void {
    for (injected.items.items) |existing| {
        if (existing.dep_type != dep_type) continue;
        if (!std.mem.eql(u8, existing.value, dep_name)) continue;
        return;
    }

    const dep_name_copy = allocator.dupe(u8, dep_name) catch return error.OutOfMemory;
    errdefer allocator.free(dep_name_copy);
    const constraint_copy = allocator.dupe(u8, exact_constraint) catch return error.OutOfMemory;
    errdefer allocator.free(constraint_copy);

    injected.items.append(allocator, .{
        .dep_type = dep_type,
        .value = dep_name_copy,
        .version_constraint = constraint_copy,
    }) catch return error.OutOfMemory;
}

fn recordRuntimeOwnerForStem(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    runtime_owner_by_stem: *std.StringHashMap(usize),
    stem: []const u8,
    pkg_index: usize,
    rel_path: []const u8,
) PackageError!void {
    if (runtime_owner_by_stem.get(stem)) |existing_pkg_index| {
        if (existing_pkg_index != pkg_index) {
            return ctx.failFmt(error.InvalidInput, rel_path, "runtime library stem owned by multiple split packages: {s}", .{stem});
        }
        return;
    }

    const stem_copy = allocator.dupe(u8, stem) catch {
        return ctx.fail(error.OutOfMemory, stem, "failed to copy runtime library stem");
    };
    errdefer allocator.free(stem_copy);

    runtime_owner_by_stem.put(stem_copy, pkg_index) catch {
        return ctx.fail(error.OutOfMemory, rel_path, "failed to record runtime library stem ownership");
    };
}

fn buildInterfaceStemForPath(rel_path: []const u8) ?[]const u8 {
    if (libraryStemForStaticArchive(rel_path)) |stem| return stem;
    if (libraryStemForUnversionedLinkerPath(rel_path)) |stem| return stem;
    if (libraryStemForPkgConfig(rel_path)) |stem| return stem;
    return null;
}

fn runtimeLibraryStemForPath(rel_path: []const u8) ?[]const u8 {
    if (!isLibraryPath(rel_path)) return null;
    const base = std.fs.path.basename(rel_path);
    return libraryStemFromVersionedSharedObject(base);
}

fn libraryStemForStaticArchive(rel_path: []const u8) ?[]const u8 {
    if (!isLibraryPath(rel_path)) return null;
    const base = std.fs.path.basename(rel_path);
    if (!std.mem.startsWith(u8, base, "lib")) return null;
    if (!std.mem.endsWith(u8, base, ".a")) return null;
    if (base.len <= 5) return null;
    return base[3 .. base.len - 2];
}

fn libraryStemForUnversionedLinkerPath(rel_path: []const u8) ?[]const u8 {
    if (!isLibraryPath(rel_path)) return null;
    const base = std.fs.path.basename(rel_path);
    if (!std.mem.startsWith(u8, base, "lib")) return null;
    if (!std.mem.endsWith(u8, base, ".so")) return null;
    if (base.len <= 6) return null;
    return base[3 .. base.len - 3];
}

fn libraryStemForPkgConfig(rel_path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rel_path, "usr/lib/pkgconfig/") and
        !std.mem.startsWith(u8, rel_path, "usr/lib64/pkgconfig/") and
        !std.mem.startsWith(u8, rel_path, "usr/share/pkgconfig/"))
    {
        return null;
    }
    const base = std.fs.path.basename(rel_path);
    if (!std.mem.startsWith(u8, base, "lib")) return null;
    if (!std.mem.endsWith(u8, base, ".pc")) return null;
    if (base.len <= 6) return null;
    return base[3 .. base.len - 3];
}

fn libraryStemFromVersionedSharedObject(base: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, base, "lib")) return null;
    const marker = std.mem.indexOf(u8, base, ".so.") orelse return null;
    if (marker <= 3 or marker + 4 >= base.len) return null;
    return base[3..marker];
}

fn isLibraryPath(rel_path: []const u8) bool {
    return std.mem.startsWith(u8, rel_path, "usr/lib/") or
        std.mem.startsWith(u8, rel_path, "lib/") or
        std.mem.startsWith(u8, rel_path, "usr/lib64/") or
        std.mem.startsWith(u8, rel_path, "lib64/");
}

test "packageArtifacts records archive metadata for staged packages" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "pack"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "pack" { files "usr/bin/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack" });
    defer test_env.ctx.allocator.free(staging_dir);
    var staging_dir_handle = try path_mod.makePathAndOpenDir(staging_dir);
    staging_dir_handle.close(path_mod.currentIo());

    const copied_files = try test_env.ctx.allocator.alloc([]const u8, 0);
    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
            .copied_files = copied_files,
        },
    };
    defer {
        staged_packages[0].deinit(test_env.ctx.allocator);
    }

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer {
        for (packaged_archives.items) |p| test_env.ctx.allocator.free(p);
        packaged_archives.deinit(test_env.ctx.allocator);
    }
    var packaging_errors_encountered = false;

    const expected_archive_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "stub.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(expected_archive_path);

    const StubPackager = struct {
        pub var calls: usize = 0;
        pub var expected_staging_dir: []const u8 = "";

        pub fn create(ctx: *mere.Context, cfg: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            calls += 1;
            try std.testing.expectEqualStrings(expected_staging_dir, cfg.staging_dir);
            const archive_path = try std.fs.path.join(ctx.allocator, &.{ cfg.staging_dir, "stub.pkg.tar.zst" });
            try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = archive_path, .data = "archive" });
            const content_hash = try ctx.allocator.dupe(u8, "hash");
            const archive_hash = try hash.calculateFileHash(ctx, archive_path);
            const package_name = try ctx.allocator.dupe(u8, cfg.artifact.name);
            return packaging.PackageArtifactResult{
                .archive_path = archive_path,
                .content_hash = content_hash,
                .archive_hash = archive_hash,
                .signature = try ctx.allocator.dupe(u8, "sig"),
                .package_name = package_name,
            };
        }
    };

    const NoopMetadataReport = struct {
        pub fn emit(_: std.mem.Allocator, _: *mere.Context, _: []const u8, _: usize, _: []const u8) void {}
    };

    StubPackager.calls = 0;
    StubPackager.expected_staging_dir = staging_dir;

    try packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        true,
        true,
        &StubPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &NoopMetadataReport.emit,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), StubPackager.calls);
    try std.testing.expect(!packaging_errors_encountered);
    try std.testing.expectEqual(@as(usize, 1), packaged_archives.items.len);
    try std.testing.expectEqualStrings(expected_archive_path, packaged_archives.items[0]);
}

test "packageArtifacts returns error when archive creation fails under stop policy" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "packfailstop"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "packfailstop" { files "usr/bin/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-fail-stop" });
    defer test_env.ctx.allocator.free(staging_dir);
    var staging_dir_handle = try path_mod.makePathAndOpenDir(staging_dir);
    staging_dir_handle.close(path_mod.currentIo());

    const copied_files = try test_env.ctx.allocator.alloc([]const u8, 0);
    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
            .copied_files = copied_files,
        },
    };
    defer {
        staged_packages[0].deinit(test_env.ctx.allocator);
    }

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer packaged_archives.deinit(test_env.ctx.allocator);
    var packaging_errors_encountered = false;

    const FailingPackager = struct {
        pub fn create(_: *mere.Context, _: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            return packaging.PackagingError.CreationFailed;
        }
    };

    const NoopMetadataReport = struct {
        pub fn emit(_: std.mem.Allocator, _: *mere.Context, _: []const u8, _: usize, _: []const u8) void {}
    };

    const err = packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        true,
        true,
        &FailingPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &NoopMetadataReport.emit,
        null,
    ) catch |e| {
        try std.testing.expectEqual(error.PackageCreationFailed, e);
        try std.testing.expect(packaging_errors_encountered);
        try std.testing.expectEqual(@as(usize, 0), packaged_archives.items.len);
        return;
    };
    _ = err;
    try std.testing.expect(false);
}

test "packageArtifacts compresses man pages by default before packaging" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "packman"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "packman" { files "usr/share/man/man1/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-man" });
    defer test_env.ctx.allocator.free(staging_dir);
    const man_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "usr", "share", "man", "man1" });
    defer test_env.ctx.allocator.free(man_dir);
    var man_dir_handle = try path_mod.makePathAndOpenDir(man_dir);
    man_dir_handle.close(path_mod.currentIo());

    const manpage_path = try std.fs.path.join(test_env.ctx.allocator, &.{ man_dir, "mere.1" });
    defer test_env.ctx.allocator.free(manpage_path);
    var manpage = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), manpage_path, .{});
    defer manpage.close(path_mod.currentIo());
    try manpage.writeStreamingAll(path_mod.currentIo(), "manual page");

    const copied_files = try test_env.ctx.allocator.alloc([]const u8, 0);
    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
            .copied_files = copied_files,
        },
    };
    defer staged_packages[0].deinit(test_env.ctx.allocator);

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer {
        for (packaged_archives.items) |p| test_env.ctx.allocator.free(p);
        packaged_archives.deinit(test_env.ctx.allocator);
    }
    var packaging_errors_encountered = false;

    const StubPackager = struct {
        pub fn create(ctx: *mere.Context, cfg: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            const archive_path = try std.fs.path.join(ctx.allocator, &.{ cfg.staging_dir, "stub.pkg.tar.zst" });
            try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = archive_path, .data = "archive" });
            const archive_hash = try hash.calculateFileHash(ctx, archive_path);
            return .{
                .archive_path = archive_path,
                .content_hash = try ctx.allocator.dupe(u8, "hash"),
                .archive_hash = archive_hash,
                .signature = try ctx.allocator.dupe(u8, "sig"),
                .package_name = try ctx.allocator.dupe(u8, cfg.artifact.name),
            };
        }
    };

    const NoopMetadataReport = struct {
        pub fn emit(_: std.mem.Allocator, _: *mere.Context, _: []const u8, _: usize, _: []const u8) void {}
    };

    try packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        true,
        true,
        &StubPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &NoopMetadataReport.emit,
        null,
    );

    try std.testing.expect(!packaging_errors_encountered);
    const compressed_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}.zst", .{manpage_path});
    defer test_env.ctx.allocator.free(compressed_path);
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), compressed_path, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), manpage_path, .{}));
}

test "packageArtifacts respects compress-manpages false" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "packmanoptout"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "packmanoptout" {
        \\    compress-manpages false
        \\    files "usr/share/man/man1/*"
        \\}
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-man-optout" });
    defer test_env.ctx.allocator.free(staging_dir);
    const man_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "usr", "share", "man", "man1" });
    defer test_env.ctx.allocator.free(man_dir);
    var man_dir_handle = try path_mod.makePathAndOpenDir(man_dir);
    man_dir_handle.close(path_mod.currentIo());

    const manpage_path = try std.fs.path.join(test_env.ctx.allocator, &.{ man_dir, "mere.1" });
    defer test_env.ctx.allocator.free(manpage_path);
    var manpage = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), manpage_path, .{});
    defer manpage.close(path_mod.currentIo());
    try manpage.writeStreamingAll(path_mod.currentIo(), "manual page");

    const copied_files = try test_env.ctx.allocator.alloc([]const u8, 0);
    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
            .copied_files = copied_files,
        },
    };
    defer staged_packages[0].deinit(test_env.ctx.allocator);

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer {
        for (packaged_archives.items) |p| test_env.ctx.allocator.free(p);
        packaged_archives.deinit(test_env.ctx.allocator);
    }
    var packaging_errors_encountered = false;

    const StubPackager = struct {
        pub fn create(ctx: *mere.Context, cfg: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            const archive_path = try std.fs.path.join(ctx.allocator, &.{ cfg.staging_dir, "stub.pkg.tar.zst" });
            try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = archive_path, .data = "archive" });
            const archive_hash = try hash.calculateFileHash(ctx, archive_path);
            return .{
                .archive_path = archive_path,
                .content_hash = try ctx.allocator.dupe(u8, "hash"),
                .archive_hash = archive_hash,
                .signature = try ctx.allocator.dupe(u8, "sig"),
                .package_name = try ctx.allocator.dupe(u8, cfg.artifact.name),
            };
        }
    };

    const NoopMetadataReport = struct {
        pub fn emit(_: std.mem.Allocator, _: *mere.Context, _: []const u8, _: usize, _: []const u8) void {}
    };

    try packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        true,
        true,
        &StubPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &NoopMetadataReport.emit,
        null,
    );

    try std.testing.expect(!packaging_errors_encountered);
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), manpage_path, .{});
    const compressed_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}.zst", .{manpage_path});
    defer test_env.ctx.allocator.free(compressed_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), compressed_path, .{}));
}

test "packageArtifacts continues on archive failure under continue policy" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "packfailcontinue"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "packfailcontinue" { files "usr/bin/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-fail-continue" });
    defer test_env.ctx.allocator.free(staging_dir);
    var staging_dir_handle = try path_mod.makePathAndOpenDir(staging_dir);
    staging_dir_handle.close(path_mod.currentIo());

    const copied_files = try test_env.ctx.allocator.alloc([]const u8, 0);
    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
            .copied_files = copied_files,
        },
    };
    defer {
        staged_packages[0].deinit(test_env.ctx.allocator);
    }

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer packaged_archives.deinit(test_env.ctx.allocator);
    var packaging_errors_encountered = false;

    const FailingPackager = struct {
        pub fn create(_: *mere.Context, _: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            return packaging.PackagingError.CreationFailed;
        }
    };

    const NoopMetadataReport = struct {
        pub fn emit(_: std.mem.Allocator, _: *mere.Context, _: []const u8, _: usize, _: []const u8) void {}
    };

    try packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        false,
        true,
        &FailingPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &NoopMetadataReport.emit,
        null,
    );

    try std.testing.expect(packaging_errors_encountered);
    try std.testing.expectEqual(@as(usize, 0), packaged_archives.items.len);
}

test "packageArtifacts emits per-package metadata report callback" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "pack-report"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "pack-report" { files "usr/bin/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-report" });
    defer test_env.ctx.allocator.free(staging_dir);
    var staging_dir_handle = try path_mod.makePathAndOpenDir(staging_dir);
    staging_dir_handle.close(path_mod.currentIo());

    const copied_files = try test_env.ctx.allocator.alloc([]const u8, 1);
    copied_files[0] = try test_env.ctx.allocator.dupe(u8, "usr/bin/pack-report");
    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, staging_dir),
            .copied_files = copied_files,
        },
    };
    defer {
        staged_packages[0].deinit(test_env.ctx.allocator);
    }

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer {
        for (packaged_archives.items) |p| test_env.ctx.allocator.free(p);
        packaged_archives.deinit(test_env.ctx.allocator);
    }
    var packaging_errors_encountered = false;

    const StubPackager = struct {
        pub fn create(ctx_inner: *mere.Context, cfg: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            const archive_path = try std.fs.path.join(ctx_inner.allocator, &.{ cfg.staging_dir, "stub.pkg.tar.zst" });
            try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = archive_path, .data = "archive" });
            const content_hash = try ctx_inner.allocator.dupe(u8, "hash");
            const archive_hash = try hash.calculateFileHash(ctx_inner, archive_path);
            const package_name = try ctx_inner.allocator.dupe(u8, cfg.artifact.name);
            return packaging.PackageArtifactResult{
                .archive_path = archive_path,
                .content_hash = content_hash,
                .archive_hash = archive_hash,
                .signature = try ctx_inner.allocator.dupe(u8, "sig"),
                .package_name = package_name,
            };
        }
    };

    const MetadataCapture = struct {
        pub var calls: usize = 0;
        pub var pkg_name: []const u8 = "";
        pub var files: usize = 0;
        pub var staging: []const u8 = "";

        pub fn emit(_: std.mem.Allocator, _: *mere.Context, name: []const u8, file_count: usize, staging_dir_in: []const u8) void {
            calls += 1;
            pkg_name = name;
            files = file_count;
            staging = staging_dir_in;
        }
    };

    MetadataCapture.calls = 0;
    MetadataCapture.pkg_name = "";
    MetadataCapture.files = 0;
    MetadataCapture.staging = "";

    try packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        true,
        true,
        &StubPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &MetadataCapture.emit,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), MetadataCapture.calls);
    try std.testing.expectEqualStrings("pack-report", MetadataCapture.pkg_name);
    try std.testing.expectEqual(@as(usize, 1), MetadataCapture.files);
    try std.testing.expectEqualStrings(staging_dir, MetadataCapture.staging);
}

test "packageArtifacts creates package archives concurrently and preserves output order" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "pack-parallel"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "pack-a" { files "usr/bin/a" }
        \\package "pack-b" { files "usr/bin/b" }
        \\package "pack-c" { files "usr/bin/c" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    var staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-a" }),
            .copied_files = try test_env.ctx.allocator.alloc([]const u8, 0),
        },
        .{
            .pkg_index = 1,
            .staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-b" }),
            .copied_files = try test_env.ctx.allocator.alloc([]const u8, 0),
        },
        .{
            .pkg_index = 2,
            .staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-pack-c" }),
            .copied_files = try test_env.ctx.allocator.alloc([]const u8, 0),
        },
    };
    defer {
        for (&staged_packages) |*staged| staged.deinit(test_env.ctx.allocator);
    }

    for (&staged_packages) |staged| {
        var staged_dir_handle = try path_mod.makePathAndOpenDir(staged.staging_dir);
        staged_dir_handle.close(path_mod.currentIo());
    }

    var packaged_archives: std.ArrayList([]const u8) = .empty;
    defer {
        for (packaged_archives.items) |p| test_env.ctx.allocator.free(p);
        packaged_archives.deinit(test_env.ctx.allocator);
    }
    var packaging_errors_encountered = false;

    const ParallelTracker = struct {
        mutex: std.Io.Mutex = .init,
        active: usize = 0,
        max_active: usize = 0,

        fn begin(self: *@This()) void {
            self.mutex.lockUncancelable(path_mod.currentIo());
            defer self.mutex.unlock(path_mod.currentIo());
            self.active += 1;
            if (self.active > self.max_active) self.max_active = self.active;
        }

        fn end(self: *@This()) void {
            self.mutex.lockUncancelable(path_mod.currentIo());
            defer self.mutex.unlock(path_mod.currentIo());
            self.active -= 1;
        }
    };

    const StubPackager = struct {
        pub var tracker = ParallelTracker{};

        pub fn create(ctx: *mere.Context, cfg: packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult {
            tracker.begin();
            defer tracker.end();

            try std.Io.sleep(path_mod.currentIo(), .fromMilliseconds(50), .awake);

            const archive_name = try std.fmt.allocPrint(ctx.allocator, "{s}.pkg.tar.zst", .{cfg.artifact.name});
            defer ctx.allocator.free(archive_name);

            const archive_path = try std.fs.path.join(ctx.allocator, &.{ cfg.output_dir, archive_name });
            try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = archive_path, .data = "archive" });
            const archive_hash = try hash.calculateFileHash(ctx, archive_path);

            return packaging.PackageArtifactResult{
                .archive_path = archive_path,
                .content_hash = try ctx.allocator.dupe(u8, "hash"),
                .archive_hash = archive_hash,
                .signature = try ctx.allocator.dupe(u8, "sig"),
                .package_name = try ctx.allocator.dupe(u8, cfg.artifact.name),
            };
        }
    };

    const NoopMetadataReport = struct {
        pub fn emit(_: std.mem.Allocator, _: *mere.Context, _: []const u8, _: usize, _: []const u8) void {}
    };

    StubPackager.tracker = .{};

    try packageArtifacts(
        test_env.ctx.allocator,
        &test_env.ctx,
        true,
        false,
        &StubPackager.create,
        &parsed,
        &staged_packages,
        &packaged_archives,
        &packaging_errors_encountered,
        &NoopMetadataReport.emit,
        null,
    );

    try std.testing.expect(!packaging_errors_encountered);
    try std.testing.expect(StubPackager.tracker.max_active > 1);
    try std.testing.expectEqual(@as(usize, 3), packaged_archives.items.len);
    try std.testing.expectStringEndsWith(packaged_archives.items[0], "pack-a.pkg.tar.zst");
    try std.testing.expectStringEndsWith(packaged_archives.items[1], "pack-b.pkg.tar.zst");
    try std.testing.expectStringEndsWith(packaged_archives.items[2], "pack-c.pkg.tar.zst");
}

test "buildInjectedDependenciesForSplit injects exact split runtime dependency from sibling library stems" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "split"
        \\    version "1.2.3"
        \\    release 7
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "libfoo" { files "usr/lib/libfoo.so" "usr/lib/libfoo.so.1.2.3" }
        \\package "libfoo-dev" { files "usr/lib/libfoo.a" "usr/lib/pkgconfig/libfoo.pc" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const runtime_staging = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-runtime" });
    defer test_env.ctx.allocator.free(runtime_staging);
    const dev_staging = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-dev" });
    defer test_env.ctx.allocator.free(dev_staging);

    const runtime_lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_staging, "usr/lib" });
    defer test_env.ctx.allocator.free(runtime_lib_dir);
    const dev_lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ dev_staging, "usr/lib" });
    defer test_env.ctx.allocator.free(dev_lib_dir);
    var runtime_lib_dir_handle = try path_mod.makePathAndOpenDir(runtime_lib_dir);
    runtime_lib_dir_handle.close(path_mod.currentIo());
    var dev_lib_dir_handle = try path_mod.makePathAndOpenDir(dev_lib_dir);
    dev_lib_dir_handle.close(path_mod.currentIo());

    const runtime_lib = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_staging, "usr/lib/libfoo.so.1.2.3" });
    defer test_env.ctx.allocator.free(runtime_lib);
    try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = runtime_lib, .data = "x" });

    const runtime_link = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_staging, "usr/lib/libfoo.so" });
    defer test_env.ctx.allocator.free(runtime_link);
    try std.Io.Dir.cwd().symLink(path_mod.currentIo(), "libfoo.so.1.2.3", runtime_link, .{});

    const dev_static = try std.fs.path.join(test_env.ctx.allocator, &.{ dev_staging, "usr/lib/libfoo.a" });
    defer test_env.ctx.allocator.free(dev_static);
    try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = dev_static, .data = "archive" });

    const dev_pkgconfig_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ dev_staging, "usr/lib/pkgconfig" });
    defer test_env.ctx.allocator.free(dev_pkgconfig_dir);
    var dev_pkgconfig_dir_handle = try path_mod.makePathAndOpenDir(dev_pkgconfig_dir);
    dev_pkgconfig_dir_handle.close(path_mod.currentIo());
    const dev_pkgconfig = try std.fs.path.join(test_env.ctx.allocator, &.{ dev_pkgconfig_dir, "libfoo.pc" });
    defer test_env.ctx.allocator.free(dev_pkgconfig);
    try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = dev_pkgconfig, .data = "Name: libfoo\n" });

    const runtime_files = try test_env.ctx.allocator.alloc([]const u8, 2);
    runtime_files[0] = try test_env.ctx.allocator.dupe(u8, "usr/lib/libfoo.so.1.2.3");
    runtime_files[1] = try test_env.ctx.allocator.dupe(u8, "usr/lib/libfoo.so");
    const dev_files = try test_env.ctx.allocator.alloc([]const u8, 2);
    dev_files[0] = try test_env.ctx.allocator.dupe(u8, "usr/lib/libfoo.a");
    dev_files[1] = try test_env.ctx.allocator.dupe(u8, "usr/lib/pkgconfig/libfoo.pc");

    const staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, runtime_staging),
            .copied_files = runtime_files,
        },
        .{
            .pkg_index = 1,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, dev_staging),
            .copied_files = dev_files,
        },
    };
    defer {
        staged_packages[0].deinit(test_env.ctx.allocator);
        staged_packages[1].deinit(test_env.ctx.allocator);
    }

    const injected = try buildInjectedDependenciesForSplit(
        test_env.ctx.allocator,
        &test_env.ctx,
        &parsed,
        &staged_packages,
    );
    defer {
        for (injected) |*entry| entry.deinit(test_env.ctx.allocator);
        test_env.ctx.allocator.free(injected);
    }

    try std.testing.expectEqual(@as(usize, 0), injected[0].items.items.len);
    try std.testing.expectEqual(@as(usize, 1), injected[1].items.items.len);
    try std.testing.expectEqual(meta.DependencyType.split_runtime, injected[1].items.items[0].dep_type);
    try std.testing.expectEqualStrings("libfoo", injected[1].items.items[0].value);
    try std.testing.expect(injected[1].items.items[0].version_constraint != null);
    try std.testing.expectEqualStrings("=1.2.3-7", injected[1].items.items[0].version_constraint.?);
}

test "buildInjectedDependenciesForSplit rejects ambiguous sibling runtime owners for same library stem" {
    const th = @import("../test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "split"
        \\    version "1.2.3"
        \\    release 7
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "libfoo-one" { files "usr/lib/libfoo.so.1.2.3" }
        \\package "libfoo-two" { files "usr/lib/libfoo.so.1.2.4" }
        \\package "libfoo-dev" { files "usr/lib/libfoo.a" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const runtime_one = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-runtime-one" });
    defer test_env.ctx.allocator.free(runtime_one);
    const runtime_two = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-runtime-two" });
    defer test_env.ctx.allocator.free(runtime_two);
    const dev_staging = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging-dev" });
    defer test_env.ctx.allocator.free(dev_staging);

    const runtime_one_lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_one, "usr/lib" });
    defer test_env.ctx.allocator.free(runtime_one_lib_dir);
    const runtime_two_lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_two, "usr/lib" });
    defer test_env.ctx.allocator.free(runtime_two_lib_dir);
    const dev_lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ dev_staging, "usr/lib" });
    defer test_env.ctx.allocator.free(dev_lib_dir);

    var runtime_one_lib_dir_handle = try path_mod.makePathAndOpenDir(runtime_one_lib_dir);
    runtime_one_lib_dir_handle.close(path_mod.currentIo());
    var runtime_two_lib_dir_handle = try path_mod.makePathAndOpenDir(runtime_two_lib_dir);
    runtime_two_lib_dir_handle.close(path_mod.currentIo());
    var dev_lib_dir_handle = try path_mod.makePathAndOpenDir(dev_lib_dir);
    dev_lib_dir_handle.close(path_mod.currentIo());

    const runtime_one_lib = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_one, "usr/lib/libfoo.so.1.2.3" });
    defer test_env.ctx.allocator.free(runtime_one_lib);
    const runtime_two_lib = try std.fs.path.join(test_env.ctx.allocator, &.{ runtime_two, "usr/lib/libfoo.so.1.2.4" });
    defer test_env.ctx.allocator.free(runtime_two_lib);
    const dev_static = try std.fs.path.join(test_env.ctx.allocator, &.{ dev_staging, "usr/lib/libfoo.a" });
    defer test_env.ctx.allocator.free(dev_static);

    try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = runtime_one_lib, .data = "x" });
    try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = runtime_two_lib, .data = "x" });
    try std.Io.Dir.cwd().writeFile(path_mod.currentIo(), .{ .sub_path = dev_static, .data = "archive" });

    const runtime_one_files = try test_env.ctx.allocator.alloc([]const u8, 1);
    runtime_one_files[0] = try test_env.ctx.allocator.dupe(u8, "usr/lib/libfoo.so.1.2.3");
    const runtime_two_files = try test_env.ctx.allocator.alloc([]const u8, 1);
    runtime_two_files[0] = try test_env.ctx.allocator.dupe(u8, "usr/lib/libfoo.so.1.2.4");
    const dev_files = try test_env.ctx.allocator.alloc([]const u8, 1);
    dev_files[0] = try test_env.ctx.allocator.dupe(u8, "usr/lib/libfoo.a");

    const staged_packages = [_]split_staging.StagedPackage{
        .{
            .pkg_index = 0,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, runtime_one),
            .copied_files = runtime_one_files,
        },
        .{
            .pkg_index = 1,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, runtime_two),
            .copied_files = runtime_two_files,
        },
        .{
            .pkg_index = 2,
            .staging_dir = try test_env.ctx.allocator.dupe(u8, dev_staging),
            .copied_files = dev_files,
        },
    };
    defer {
        staged_packages[0].deinit(test_env.ctx.allocator);
        staged_packages[1].deinit(test_env.ctx.allocator);
        staged_packages[2].deinit(test_env.ctx.allocator);
    }

    try std.testing.expectError(
        error.InvalidInput,
        buildInjectedDependenciesForSplit(
            test_env.ctx.allocator,
            &test_env.ctx,
            &parsed,
            &staged_packages,
        ),
    );
}

test "generateServiceSourceDir creates daemon longrun with logging pipeline" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const staging_dir = try std.fs.path.join(allocator, &.{ test_env.path, "staging" });
    defer allocator.free(staging_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(staging_dir);
        dir.close(io);
    }

    var svc = try recipe.ServiceDef.init(allocator);
    defer svc.deinit(allocator);
    svc.name = try allocator.dupe(u8, "ntpd");
    svc.service_type = .daemon;
    try svc.command.append(allocator, try allocator.dupe(u8, "/usr/bin/ntpd"));
    try svc.command.append(allocator, try allocator.dupe(u8, "-n"));
    try svc.command.append(allocator, try allocator.dupe(u8, "-d"));
    try svc.depends_on.append(allocator, try allocator.dupe(u8, "network"));

    try generateServiceSourceDir(allocator, &test_env.ctx, staging_dir, &svc);

    // Verify main service dir
    const svc_dir = try std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", "ntpd" });
    defer allocator.free(svc_dir);

    // type file
    const type_path = try std.fs.path.join(allocator, &.{ svc_dir, "type" });
    defer allocator.free(type_path);
    const type_content = try readTestFile(allocator, io, type_path);
    defer allocator.free(type_content);
    try std.testing.expectEqualStrings("longrun\n", type_content);

    // run script contains shebang and command
    const run_path = try std.fs.path.join(allocator, &.{ svc_dir, "run" });
    defer allocator.free(run_path);
    const run_content = try readTestFile(allocator, io, run_path);
    defer allocator.free(run_content);
    try std.testing.expect(std.mem.startsWith(u8, run_content, "#!/bin/execlineb -P\n"));
    try std.testing.expect(std.mem.indexOf(u8, run_content, "fdmove -c 2 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, run_content, "/usr/bin/ntpd") != null);

    // producer-for links to log service
    const pf_path = try std.fs.path.join(allocator, &.{ svc_dir, "producer-for" });
    defer allocator.free(pf_path);
    const pf_content = try readTestFile(allocator, io, pf_path);
    defer allocator.free(pf_content);
    try std.testing.expectEqualStrings("ntpd-log\n", pf_content);

    // dependency file exists
    const dep_path = try std.fs.path.join(allocator, &.{ svc_dir, "dependencies.d", "network" });
    defer allocator.free(dep_path);
    std.Io.Dir.accessAbsolute(io, dep_path, .{}) catch
        return error.TestUnexpectedResult;

    // Verify log service dir
    const log_dir = try std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", "ntpd-log" });
    defer allocator.free(log_dir);

    const log_type_path = try std.fs.path.join(allocator, &.{ log_dir, "type" });
    defer allocator.free(log_type_path);
    const log_type = try readTestFile(allocator, io, log_type_path);
    defer allocator.free(log_type);
    try std.testing.expectEqualStrings("longrun\n", log_type);

    const cf_path = try std.fs.path.join(allocator, &.{ log_dir, "consumer-for" });
    defer allocator.free(cf_path);
    const cf_content = try readTestFile(allocator, io, cf_path);
    defer allocator.free(cf_content);
    try std.testing.expectEqualStrings("ntpd\n", cf_content);

    const pn_path = try std.fs.path.join(allocator, &.{ log_dir, "pipeline-name" });
    defer allocator.free(pn_path);
    const pn_content = try readTestFile(allocator, io, pn_path);
    defer allocator.free(pn_content);
    try std.testing.expectEqualStrings("ntpd-pipeline\n", pn_content);

    // log run script references s6-log and the service name
    const log_run_path = try std.fs.path.join(allocator, &.{ log_dir, "run" });
    defer allocator.free(log_run_path);
    const log_run = try readTestFile(allocator, io, log_run_path);
    defer allocator.free(log_run);
    try std.testing.expect(std.mem.indexOf(u8, log_run, "s6-log") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_run, "/var/log/ntpd") != null);
}

test "generateServiceSourceDir creates oneshot with up script" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const staging_dir = try std.fs.path.join(allocator, &.{ test_env.path, "staging" });
    defer allocator.free(staging_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(staging_dir);
        dir.close(io);
    }

    var svc = try recipe.ServiceDef.init(allocator);
    defer svc.deinit(allocator);
    svc.name = try allocator.dupe(u8, "hostname");
    svc.service_type = .oneshot;
    try svc.up.append(allocator, try allocator.dupe(u8, "/usr/bin/hostname"));
    try svc.up.append(allocator, try allocator.dupe(u8, "-F"));
    try svc.up.append(allocator, try allocator.dupe(u8, "/etc/hostname"));
    try svc.depends_on.append(allocator, try allocator.dupe(u8, "mount-rw"));

    try generateServiceSourceDir(allocator, &test_env.ctx, staging_dir, &svc);

    const svc_dir = try std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", "hostname" });
    defer allocator.free(svc_dir);

    // type
    const type_path = try std.fs.path.join(allocator, &.{ svc_dir, "type" });
    defer allocator.free(type_path);
    const type_content = try readTestFile(allocator, io, type_path);
    defer allocator.free(type_content);
    try std.testing.expectEqualStrings("oneshot\n", type_content);

    // up script
    const up_path = try std.fs.path.join(allocator, &.{ svc_dir, "up" });
    defer allocator.free(up_path);
    const up_content = try readTestFile(allocator, io, up_path);
    defer allocator.free(up_content);
    try std.testing.expect(std.mem.startsWith(u8, up_content, "#!/bin/execlineb -P\n"));
    try std.testing.expect(std.mem.indexOf(u8, up_content, "/usr/bin/hostname") != null);

    // no log service for oneshots
    const log_dir = try std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", "hostname-log" });
    defer allocator.free(log_dir);
    std.Io.Dir.accessAbsolute(io, log_dir, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestUnexpectedResult; // log dir should not exist
}

test "generateServiceSourceDir creates notification-fd for ready daemons" {
    const th = @import("../test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const staging_dir = try std.fs.path.join(allocator, &.{ test_env.path, "staging" });
    defer allocator.free(staging_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(staging_dir);
        dir.close(io);
    }

    var svc = try recipe.ServiceDef.init(allocator);
    defer svc.deinit(allocator);
    svc.name = try allocator.dupe(u8, "greetd");
    svc.service_type = .daemon;
    try svc.command.append(allocator, try allocator.dupe(u8, "/usr/bin/greetd"));
    svc.ready_notification = 3;

    try generateServiceSourceDir(allocator, &test_env.ctx, staging_dir, &svc);

    const svc_dir = try std.fs.path.join(allocator, &.{ staging_dir, "usr", "share", "s6-rc", "sources", "greetd" });
    defer allocator.free(svc_dir);

    const nfd_path = try std.fs.path.join(allocator, &.{ svc_dir, "notification-fd" });
    defer allocator.free(nfd_path);
    const nfd_content = try readTestFile(allocator, io, nfd_path);
    defer allocator.free(nfd_content);
    try std.testing.expectEqualStrings("3\n", nfd_content);
}

fn readTestFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const read = file.readPositionalAll(io, buf, 0) catch {
        return error.TestUnexpectedResult;
    };
    return buf[0..read];
}
