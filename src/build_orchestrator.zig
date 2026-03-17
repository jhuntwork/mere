/// Build execution coordinator.
///
/// `planBuild()` prepares a workspace, sources, and environment for a recipe.
/// `executeBuild()` runs the remaining build stages and returns a `BuildResult`.
///
/// `BuildResult` owns duplicated `packages_created` buffers.
/// Call `BuildResult.deinit()` when finished.
const std = @import("std");
const mere = @import("mere.zig");
const download = @import("download.zig");
const recipe = @import("recipe.zig");
const workspace_manager = @import("workspace_manager.zig");
const errors = @import("errors.zig");
const hash = @import("hash.zig");
const source_manager = @import("source_manager.zig");
const source_unpacker = @import("source_unpacker.zig");
const artifact_model = @import("build_orchestrator/artifact_model.zig");
const build_environment = @import("build_orchestrator/environment.zig");
const package_staging = @import("package_staging.zig");
const packaging = @import("packaging.zig");
const config_mod = @import("config.zig");
const repo_sources = @import("repo_sources.zig");
const namespace = @import("namespace.zig");
const build_profile = @import("build_orchestrator/build_profile.zig");
const build_cache = @import("build_cache.zig");
const cache_solver = @import("build_orchestrator/cache_solver.zig");
const meta = @import("meta.zig");
const path_mod = @import("path.zig");
const namespace_paths = @import("build_orchestrator/namespace_paths.zig");
const split_staging_stage = @import("build_orchestrator/split_staging.zig");
const packaging_stage = @import("build_orchestrator/packaging.zig");
const ui = mere.ui;
const emit = mere.ui.emit;

const NamespaceRunnerFn = *const fn (std.mem.Allocator, namespace.EnvMode, namespace.EnvOptions) anyerror!u8;
const StagePackageFilesFn = *const fn (*mere.Context, package_staging.PackageStagingConfig) anyerror!package_staging.PackageStagingResult;
const CreatePackageArtifactFn = *const fn (*mere.Context, packaging.PackageArtifactConfig) anyerror!packaging.PackageArtifactResult;

const StagedPackage = split_staging_stage.StagedPackage;
const ReportListLimit: usize = 12;
const BuildLogFilename = "build.log";
const BuildReportFilename = "build-report.kdl";

fn defaultCreatePackageArtifact(ctx: *mere.Context, config: packaging.PackageArtifactConfig) !packaging.PackageArtifactResult {
    var packager = packaging.Packager.init(ctx);
    return packager.createPackageArtifact(config);
}

fn computeRecipeHashHex(allocator: std.mem.Allocator, recipe_buf: ?[]const u8) ![]const u8 {
    return hash.calculateBytesHash(allocator, recipe_buf orelse "recipe:unknown");
}

fn envMapToCArray(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
) ![]const [*:0]const u8 {
    const count = env_map.count();
    var result = try allocator.alloc([*:0]const u8, count);
    errdefer allocator.free(result);

    var i: usize = 0;
    var it = env_map.iterator();
    while (it.next()) |entry| {
        const kv_str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        defer allocator.free(kv_str);
        const kv_z = try allocator.dupeZ(u8, kv_str);
        result[i] = kv_z.ptr;
        i += 1;
    }

    return result;
}

fn freeCEnvArray(allocator: std.mem.Allocator, envp: []const [*:0]const u8) void {
    for (envp) |ptr| {
        const slice = std.mem.span(ptr);
        allocator.free(ptr[0 .. slice.len + 1]);
    }
    allocator.free(envp);
}

fn emitBuildStepStart(ctx: *mere.Context, step_name: []const u8, is_last: bool) void {
    emit.stepStartLast(ctx, .build, step_name, is_last);
}

fn emitBuildStepSuccess(ctx: *mere.Context, step_name: []const u8) void {
    emit.stepEnd(ctx, .build, step_name, true);
}

fn emitBuildStepFailure(ctx: *mere.Context, step_name: []const u8) void {
    emit.stepEnd(ctx, .build, step_name, false);
}

fn emitBuildLabelDetail(
    ctx: *mere.Context,
    severity: ui.Severity,
    label: []const u8,
    detail: []const u8,
) void {
    const segments = [_]ui.Segment{
        .{ .text = label, .kind = .normal },
        .{ .text = ": ", .kind = .normal },
        .{ .text = detail, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, severity, &segments);
}

fn emitBuildStatusDetail(
    ctx: *mere.Context,
    severity: ui.Severity,
    subject: []const u8,
    action: []const u8,
    detail: []const u8,
) void {
    const segments = [_]ui.Segment{
        .{ .text = subject, .kind = .normal },
        .{ .text = " ", .kind = .normal },
        .{ .text = action, .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = detail, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, severity, &segments);
}

fn emitBuildCacheDigest(
    ctx: *mere.Context,
    subject: []const u8,
    restored_from_cache: bool,
    digest_hex: []const u8,
) void {
    emitBuildStatusDetail(
        ctx,
        .info,
        subject,
        if (restored_from_cache) "restored from cache" else "cached",
        digest_hex,
    );
}

fn emitBuildPhaseCacheDigest(
    ctx: *mere.Context,
    phase_name: []const u8,
    restored_from_cache: bool,
    digest_hex: []const u8,
) void {
    var detail_buf: [160]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{s} ({s})", .{ phase_name, digest_hex }) catch return;
    emitBuildStatusDetail(
        ctx,
        .info,
        "phase",
        if (restored_from_cache) "restored from cache" else "cached",
        detail,
    );
}

const SplitConflict = struct {
    path: []const u8,
    first_pkg: usize,
    second_pkg: usize,
};

const SplitStagingReport = struct {
    total_assigned_paths: usize = 0,
    unique_paths: usize = 0,
    conflicts: std.ArrayList(SplitConflict),
    unassigned_paths: std.ArrayList([]const u8),

    fn init() SplitStagingReport {
        return .{
            .conflicts = .{},
            .unassigned_paths = .{},
        };
    }

    fn deinit(self: *SplitStagingReport, allocator: std.mem.Allocator) void {
        for (self.conflicts.items) |entry| allocator.free(entry.path);
        self.conflicts.deinit(allocator);
        for (self.unassigned_paths.items) |entry| allocator.free(entry);
        self.unassigned_paths.deinit(allocator);
    }

    fn conflictCount(self: *const SplitStagingReport) usize {
        return self.conflicts.items.len;
    }

    fn unassignedCount(self: *const SplitStagingReport) usize {
        return self.unassigned_paths.items.len;
    }
};

fn collectSplitStagingReport(
    ctx: *mere.Context,
    staged_packages: []const StagedPackage,
    workspace_destdir: []const u8,
) !SplitStagingReport {
    const allocator = ctx.allocator;
    var path_owner = std.StringHashMap(usize).init(allocator);
    defer {
        var it = path_owner.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        path_owner.deinit();
    }

    var report = SplitStagingReport.init();
    errdefer report.deinit(allocator);

    for (staged_packages) |staged| {
        for (staged.copied_files) |rel_path| {
            report.total_assigned_paths += 1;
            if (path_owner.get(rel_path)) |owner_pkg_idx| {
                if (owner_pkg_idx != staged.pkg_index) {
                    try report.conflicts.append(allocator, .{
                        .path = try allocator.dupe(u8, rel_path),
                        .first_pkg = owner_pkg_idx,
                        .second_pkg = staged.pkg_index,
                    });
                }
                continue;
            }

            const key = allocator.dupe(u8, rel_path) catch {
                return ctx.fail(error.OutOfMemory, rel_path, "report: out of memory while tracking assigned files");
            };
            path_owner.put(key, staged.pkg_index) catch {
                allocator.free(key);
                return ctx.fail(error.OutOfMemory, rel_path, "report: out of memory while tracking assigned files");
            };
        }
    }
    var dest_dir = std.fs.openDirAbsolute(workspace_destdir, .{ .iterate = true }) catch |err| {
        return ctx.fail(
            if (err == error.OutOfMemory) error.OutOfMemory else error.FileSystem,
            workspace_destdir,
            "report: unable to inspect destdir",
        );
    };
    defer dest_dir.close();

    var walker = dest_dir.walk(allocator) catch |err| {
        return ctx.fail(
            if (err == error.OutOfMemory) error.OutOfMemory else error.FileSystem,
            workspace_destdir,
            "report: unable to walk destdir",
        );
    };
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch |err| {
            return ctx.fail(
                if (err == error.OutOfMemory) error.OutOfMemory else error.FileSystem,
                workspace_destdir,
                "report: failed while scanning destdir",
            );
        };
        if (entry == null) break;
        const entry_val = entry.?;
        if (entry_val.kind != .file and entry_val.kind != .sym_link) continue;

        if (!path_owner.contains(entry_val.path)) {
            try report.unassigned_paths.append(allocator, try allocator.dupe(u8, entry_val.path));
        }
    }

    report.unique_paths = path_owner.count();
    return report;
}

fn emitSplitStagingReport(
    ctx: *mere.Context,
    parsed_recipe: *const recipe.Recipe,
    report: *const SplitStagingReport,
) void {
    const allocator = ctx.allocator;
    const conflict_count = report.conflictCount();
    const unassigned_count = report.unassignedCount();

    const assigned_text = std.fmt.allocPrint(allocator, "{d}", .{report.total_assigned_paths}) catch {
        emit.logLineSeverity(ctx, .build, .warn, "report: out of memory while formatting split summary");
        return;
    };
    defer allocator.free(assigned_text);
    const unique_text = std.fmt.allocPrint(allocator, "{d}", .{report.unique_paths}) catch {
        emit.logLineSeverity(ctx, .build, .warn, "report: out of memory while formatting split summary");
        return;
    };
    defer allocator.free(unique_text);
    const conflicts_text = std.fmt.allocPrint(allocator, "{d}", .{conflict_count}) catch {
        emit.logLineSeverity(ctx, .build, .warn, "report: out of memory while formatting split summary");
        return;
    };
    defer allocator.free(conflicts_text);
    const unassigned_text = std.fmt.allocPrint(allocator, "{d}", .{unassigned_count}) catch {
        emit.logLineSeverity(ctx, .build, .warn, "report: out of memory while formatting split summary");
        return;
    };
    defer allocator.free(unassigned_text);

    const conflict_kind: ui.SegmentKind = if (conflict_count > 0) .warn else .detail;
    const unassigned_kind: ui.SegmentKind = if (unassigned_count > 0) .warn else .detail;
    const summary_segments = [_]ui.Segment{
        .{ .text = "split report: assigned=", .kind = .normal },
        .{ .text = assigned_text, .kind = .detail },
        .{ .text = " unique=", .kind = .normal },
        .{ .text = unique_text, .kind = .detail },
        .{ .text = " conflicts=", .kind = .normal },
        .{ .text = conflicts_text, .kind = conflict_kind },
        .{ .text = " unassigned=", .kind = .normal },
        .{ .text = unassigned_text, .kind = unassigned_kind },
    };
    const summary_severity: ui.Severity = if (conflict_count > 0 or unassigned_count > 0) .warn else .info;
    emit.logSegmentsSeverity(ctx, .build, summary_severity, &summary_segments);

    if (conflict_count > 0) {
        var si: usize = 0;
        const conflict_limit = @min(conflict_count, ReportListLimit);
        while (si < conflict_limit) : (si += 1) {
            const sample = report.conflicts.items[si];
            const first_pkg = parsed_recipe.packages.items[sample.first_pkg].name;
            const second_pkg = parsed_recipe.packages.items[sample.second_pkg].name;
            const conflict_segments = [_]ui.Segment{
                .{ .text = "  conflict:", .kind = .warn },
                .{ .text = " ", .kind = .normal },
                .{ .text = sample.path, .kind = .detail },
                .{ .text = " in ", .kind = .normal },
                .{ .text = first_pkg, .kind = .normal },
                .{ .text = " and ", .kind = .normal },
                .{ .text = second_pkg, .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .build, .warn, &conflict_segments);
        }
        if (conflict_count > conflict_limit) {
            const more_conflicts = std.fmt.allocPrint(allocator, "{d}", .{conflict_count - conflict_limit}) catch {
                emit.logLineSeverity(ctx, .build, .warn, "report: out of memory while formatting conflict summary");
                return;
            };
            defer allocator.free(more_conflicts);
            const more_segments = [_]ui.Segment{
                .{ .text = "  conflict", .kind = .warn },
                .{ .text = " ... +", .kind = .normal },
                .{ .text = more_conflicts, .kind = .detail },
                .{ .text = " more", .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .build, .warn, &more_segments);
        }
    }

    if (unassigned_count > 0) {
        const unassigned_limit = @min(unassigned_count, ReportListLimit);
        var ui_idx: usize = 0;
        while (ui_idx < unassigned_limit) : (ui_idx += 1) {
            const path_unassigned = report.unassigned_paths.items[ui_idx];
            const unassigned_segments = [_]ui.Segment{
                .{ .text = "  unassigned:", .kind = .warn },
                .{ .text = " ", .kind = .normal },
                .{ .text = path_unassigned, .kind = .detail },
            };
            emit.logSegmentsSeverity(ctx, .build, .warn, &unassigned_segments);
        }
        if (unassigned_count > unassigned_limit) {
            const more_unassigned = std.fmt.allocPrint(allocator, "{d}", .{unassigned_count - unassigned_limit}) catch {
                emit.logLineSeverity(ctx, .build, .warn, "report: out of memory while formatting unassigned summary");
                return;
            };
            defer allocator.free(more_unassigned);
            const more_segments = [_]ui.Segment{
                .{ .text = "  unassigned", .kind = .warn },
                .{ .text = " ... +", .kind = .normal },
                .{ .text = more_unassigned, .kind = .detail },
                .{ .text = " more", .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .build, .warn, &more_segments);
        }
    }
}

fn buildLogPath(allocator: std.mem.Allocator, recipe_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ recipe_root, BuildLogFilename });
}

fn buildReportPath(allocator: std.mem.Allocator, recipe_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ recipe_root, BuildReportFilename });
}

fn writeKdlQuotedString(writer: anytype, raw: []const u8) !void {
    try writer.writeByte('"');
    for (raw) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{{{x:0>2}}}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeBuildReport(
    allocator: std.mem.Allocator,
    parsed_recipe: *const recipe.Recipe,
    workspace: *const workspace_manager.Workspace,
    report: *const SplitStagingReport,
) !void {
    const report_path = try buildReportPath(allocator, workspace.recipe_root);
    defer allocator.free(report_path);

    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);
    var writer = content.writer(allocator);

    try writer.writeAll("build-report {\n");
    try writer.writeAll("  recipe ");
    try writeKdlQuotedString(&writer, parsed_recipe.name);
    try writer.writeByte('\n');
    try writer.writeAll("  version ");
    try writeKdlQuotedString(&writer, parsed_recipe.version);
    try writer.writeByte('\n');
    try writer.print("  release {d}\n", .{parsed_recipe.release});
    try writer.writeAll("  arch ");
    try writeKdlQuotedString(&writer, parsed_recipe.arch orelse "unknown");
    try writer.writeByte('\n');
    try writer.writeAll("  workspace ");
    try writeKdlQuotedString(&writer, workspace.recipe_root);
    try writer.writeByte('\n');
    try writer.writeAll("}\n\n");

    try writer.print(
        "split-staging assigned={d} unique={d} conflicts={d} unassigned={d}\n",
        .{
            report.total_assigned_paths,
            report.unique_paths,
            report.conflictCount(),
            report.unassignedCount(),
        },
    );

    for (report.conflicts.items) |entry| {
        try writer.writeAll("conflict ");
        try writer.writeAll("path=");
        try writeKdlQuotedString(&writer, entry.path);
        try writer.writeAll(" first-package=");
        try writeKdlQuotedString(&writer, parsed_recipe.packages.items[entry.first_pkg].name);
        try writer.writeAll(" second-package=");
        try writeKdlQuotedString(&writer, parsed_recipe.packages.items[entry.second_pkg].name);
        try writer.writeByte('\n');
    }

    for (report.unassigned_paths.items) |entry| {
        try writer.writeAll("unassigned ");
        try writeKdlQuotedString(&writer, entry);
        try writer.writeByte('\n');
    }

    try path_mod.ensureParent(report_path);
    const file = try std.fs.createFileAbsolute(report_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content.items);
}

fn emitFinalBuildArtifactPaths(
    ctx: *mere.Context,
    workspace: *const workspace_manager.Workspace,
) void {
    const allocator = ctx.allocator;
    emitBuildLabelDetail(ctx, .info, "workspace", workspace.recipe_root);

    const log_path = buildLogPath(allocator, workspace.recipe_root) catch return;
    defer allocator.free(log_path);
    if (std.fs.accessAbsolute(log_path, .{})) |_| {
        emitBuildLabelDetail(ctx, .info, "build log", log_path);
    } else |_| {}

    const report_path = buildReportPath(allocator, workspace.recipe_root) catch return;
    defer allocator.free(report_path);
    if (std.fs.accessAbsolute(report_path, .{})) |_| {
        emitBuildLabelDetail(ctx, .info, "build report", report_path);
    } else |_| {}
}

/// BuildExecutionState centralizes the mutable context required to execute a build.
/// Phase-specific helpers will progressively populate these fields so that resource
/// ownership and teardown can be handled in one place.
pub const BuildExecutionState = struct {
    ctx: *mere.Context,
    allocator: std.mem.Allocator,
    recipe_buf: ?[]const u8,
    recipe_dir: []const u8,
    download_client: ?download.TransferClient,
    cache: bool,
    cache_dir: ?[]const u8,
    progress_cb: ?*ProgressCallback,
    failure_policy: FailurePolicy,
    progress_recorder: ProgressRecorder,

    // Scratch fields that later helpers will populate.
    parsed_recipe: ?*recipe.Recipe,
    src_working_dir: ?[]const u8,
    src_working_dir_buffer: ?[]u8,
    host_env: ?std.process.EnvMap,
    pkg_install_dir: ?[]u8,
    build_profile_instance: ?build_profile.BuildProfile,
    namespace_runner: NamespaceRunnerFn,
    recipe_loaded: bool,
    execution: cache_solver.ExecutionTrace,
    staged_packages: std.ArrayList(StagedPackage),
    split_staging_errors_encountered: bool,
    stage_package_files_fn: StagePackageFilesFn,
    packaging_errors_encountered: bool,
    packaged_archives: std.ArrayList([]const u8),
    create_package_artifact_fn: CreatePackageArtifactFn,

    pub fn init(allocator: std.mem.Allocator, ctx: *mere.Context, request: BuildRequest) BuildExecutionState {
        return BuildExecutionState{
            .ctx = ctx,
            .allocator = allocator,
            .recipe_buf = request.recipe_text,
            .recipe_dir = request.recipe_dir,
            .download_client = request.download_client,
            .cache = request.cache,
            .cache_dir = request.cache_dir,
            .progress_cb = request.progress_callback,
            .failure_policy = request.failure_policy,
            .progress_recorder = .{ .completed_steps = 0 },
            .parsed_recipe = null,
            .src_working_dir = null,
            .src_working_dir_buffer = null,
            .host_env = null,
            .pkg_install_dir = null,
            .build_profile_instance = null,
            .namespace_runner = &namespace.forkAndEnterEnv,
            .recipe_loaded = false,
            .execution = .{},
            .staged_packages = .{},
            .split_staging_errors_encountered = false,
            .stage_package_files_fn = &package_staging.stagePackageFiles,
            .packaging_errors_encountered = false,
            .packaged_archives = .{},
            .create_package_artifact_fn = &defaultCreatePackageArtifact,
        };
    }

    pub fn deinit(self: *BuildExecutionState) void {
        if (self.src_working_dir_buffer) |buf| {
            self.allocator.free(buf);
            self.src_working_dir_buffer = null;
        }
        if (self.host_env) |*env| {
            env.deinit();
            self.host_env = null;
        }
        if (self.pkg_install_dir) |dir| {
            self.allocator.free(dir);
            self.pkg_install_dir = null;
        }
        if (self.build_profile_instance) |*profile| {
            // Note: cleanup() or preserve() should have been called before deinit
            // This is a safety fallback
            profile.cleanup();
            self.build_profile_instance = null;
        }
        self.execution.deinit();
        var ci: usize = 0;
        while (ci < self.staged_packages.items.len) : (ci += 1) self.staged_packages.items[ci].deinit(self.allocator);
        self.staged_packages.deinit(self.allocator);
        var pi: usize = 0;
        while (pi < self.packaged_archives.items.len) : (pi += 1) {
            self.allocator.free(self.packaged_archives.items[pi]);
        }
        self.packaged_archives.deinit(self.allocator);
        self.src_working_dir = null;
        self.recipe_loaded = false;
        self.parsed_recipe = null;
    }

    pub fn resetPackagedArchives(self: *BuildExecutionState) void {
        var i: usize = 0;
        while (i < self.packaged_archives.items.len) : (i += 1) {
            self.allocator.free(self.packaged_archives.items[i]);
        }
        self.packaged_archives.clearRetainingCapacity();
    }

    pub fn takePackagedArchives(self: *BuildExecutionState) std.ArrayList([]const u8) {
        const taken = self.packaged_archives;
        self.packaged_archives = .{};
        return taken;
    }
};
pub const BuildStatus = enum {
    success,
    partial_failure,
    failure,
};

pub const FailurePolicy = enum {
    StopOnError,
    ContinueOnError,
};

/// Build orchestration error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during build operations
/// - FileSystem: File operations failed (workspace creation, artifact handling, archive creation, etc.)
/// - PermissionDenied: Insufficient permissions for build operations
/// - InvalidInput: Invalid build configuration or recipe data
/// - Network: Network operations failed during source download or dependency installation
///
/// Build-Specific Errors:
/// - WorkspaceCreationFailed: Failed to create or set up build workspace
/// - DependencyInstallFailed: Failed to install one or more recipe dependencies
/// - SourceDownloadFailed: Failed to download recipe sources
/// - PhaseExecutionFailed: Build phase (prepare/build/check/install) failed
/// - SplitStagingFailed: Failed to stage one or more split packages
/// - PackageCreationFailed: Failed to create package archive
const Std = errors.StandardErrors;
pub const BuildError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.Network || error{
    WorkspaceCreationFailed,
    DependencyInstallFailed,
    SourceDownloadFailed,
    PhaseExecutionFailed,
    SplitStagingFailed,
    PackageCreationFailed,
};

pub const BuildResult = struct {
    status: BuildStatus,
    packages_created: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BuildResult) void {
        // Free each duplicated archive path owned by the result, then deinit the list.
        for (self.packages_created.items[0..self.packages_created.items.len]) |p| {
            self.allocator.free(p);
        }
        self.packages_created.deinit(self.allocator);
        // Defensive note: BuildResult.allocator is not freed here. The allocator's lifetime
        // is managed by the caller/context that provided it.
    }
};

pub const ProgressRecorder = struct {
    completed_steps: usize,
};

pub const ProgressCallback = struct {
    on_step: ?*const fn (*ProgressRecorder) void,
    userdata: ?*ProgressRecorder,
};

pub const BuildRequest = struct {
    recipe_text: ?[]const u8 = null,
    recipe_dir: []const u8,
    download_client: ?download.TransferClient = null,
    cache: bool = true,
    cache_dir: ?[]const u8,
    progress_callback: ?*ProgressCallback = null,
    failure_policy: FailurePolicy = FailurePolicy.StopOnError,
    pub fn init() BuildRequest {
        return .{
            .recipe_text = null,
            .recipe_dir = "",
            .download_client = null,
            .cache = true,
            .cache_dir = null,
            .progress_callback = null,
            .failure_policy = FailurePolicy.StopOnError,
        };
    }
};

pub fn planBuild(ctx: *mere.Context, request: BuildRequest) !BuildPlan {
    const allocator = ctx.allocator;

    var state = BuildExecutionState.init(allocator, ctx, request);
    errdefer state.deinit();

    var r = try loadRecipe(&state);
    errdefer r.deinit();
    state.recipe_loaded = true;

    emit.phaseStart(state.ctx, .prepare, recipeSubject(&r));

    var workspace_stage = try createWorkspace(&state, &r);
    errdefer workspace_stage.deinit();
    const workspace = workspace_stage.workspace;

    emit.stepStartLast(state.ctx, .prepare, "fetch sources", false);
    restoreOrFetchSources(&state, &r, &workspace) catch |err| {
        emit.stepEnd(state.ctx, .prepare, "fetch sources", false);
        emit.phaseEnd(state.ctx, .prepare, false);
        return err;
    };
    emit.stepEnd(state.ctx, .prepare, "fetch sources", true);

    emit.stepStartLast(state.ctx, .prepare, "unpack", true);
    restoreOrUnpackSources(&state, &r, &workspace) catch |err| {
        emit.stepEnd(state.ctx, .prepare, "unpack", false);
        emit.phaseEnd(state.ctx, .prepare, false);
        return err;
    };
    emit.stepEnd(state.ctx, .prepare, "unpack", true);
    emit.phaseEnd(state.ctx, .prepare, true);

    _ = try prepareEnvironment(&state, &r, &workspace);

    return BuildPlan{
        .state = state,
        .parsed_recipe = r,
        .workspace_stage = workspace_stage,
    };
}

pub fn executeBuild(ctx: *mere.Context, request: BuildRequest) !BuildResult {
    var build_plan = try planBuild(ctx, request);
    defer build_plan.deinit();
    return build_plan.execute();
}

pub const BuildPlan = struct {
    state: BuildExecutionState,
    parsed_recipe: recipe.Recipe,
    workspace_stage: WorkspaceStage,

    pub fn deinit(self: *BuildPlan) void {
        self.workspace_stage.deinit();
        self.parsed_recipe.deinit();
        self.state.deinit();
    }

    pub fn execute(self: *BuildPlan) !BuildResult {
        const workspace = self.workspace_stage.workspace;
        errdefer appendBuildProfileDiagnostic(&self.state, workspace.profile_dir);

        const host_env = if (self.state.host_env) |*env| env else {
            self.state.ctx.setDiagnosticContext("host_env", "missing build environment");
            return BuildError.InvalidInput;
        };

        emit.phaseStart(self.state.ctx, .build, recipeSubject(&self.parsed_recipe));

        try self.runProfileStage(&workspace);
        try self.runDependenciesStage();
        try self.runRecipeExecutionStage(&workspace, host_env);
        try self.runPackagingStage(&workspace);
        return self.runFinalizeStage(&workspace);
    }

    fn runProfileStage(self: *BuildPlan, workspace: *const workspace_manager.Workspace) !void {
        emitBuildStepStart(self.state.ctx, "create profile", false);
        createBuildProfile(&self.state, workspace) catch |err| {
            emitBuildStepFailure(self.state.ctx, "create profile");
            return err;
        };
        emitBuildStepSuccess(self.state.ctx, "create profile");
    }

    fn runDependenciesStage(self: *BuildPlan) !void {
        emitBuildStepStart(self.state.ctx, "install dependencies", false);
        installDependencies(&self.state, &self.parsed_recipe) catch |err| {
            emitBuildStepFailure(self.state.ctx, "install dependencies");
            return err;
        };
        emitBuildStepSuccess(self.state.ctx, "install dependencies");
    }

    fn runRecipeExecutionStage(
        self: *BuildPlan,
        workspace: *const workspace_manager.Workspace,
        host_env: *std.process.EnvMap,
    ) !void {
        emitBuildStepStart(self.state.ctx, "recipe execution", false);
        executePhases(&self.state, &self.parsed_recipe, host_env, workspace) catch |err| {
            emitBuildStepFailure(self.state.ctx, "recipe execution");
            return err;
        };
        emitBuildStepSuccess(self.state.ctx, "recipe execution");
    }

    fn runPackagingStage(self: *BuildPlan, workspace: *const workspace_manager.Workspace) !void {
        emitBuildStepStart(self.state.ctx, "stage packages", false);
        restoreOrStageSplitPackages(
            &self.state,
            &self.parsed_recipe,
            workspace,
        ) catch |err| {
            emitBuildStepFailure(self.state.ctx, "stage packages");
            return err;
        };
        emitBuildStepSuccess(self.state.ctx, "stage packages");
        emitBuildStepStart(self.state.ctx, "package artifacts", false);
        self.state.resetPackagedArchives();
        self.state.packaging_errors_encountered = false;
        const package_archive_recorder = packaging_stage.PackageArchiveNodeRecorder{
            .ptr = @ptrCast(&self.state),
            .record_fn = &recordPackageArchiveNode,
        };
        packaging_stage.packageArtifacts(
            self.state.allocator,
            self.state.ctx,
            self.state.failure_policy == FailurePolicy.StopOnError,
            self.state.cache,
            self.state.create_package_artifact_fn,
            &self.parsed_recipe,
            self.state.staged_packages.items,
            &self.state.packaged_archives,
            &self.state.packaging_errors_encountered,
            emitPackageMetadataReport,
            package_archive_recorder,
        ) catch |err| {
            emitBuildStepFailure(self.state.ctx, "package artifacts");
            return err;
        };
        var split_report = collectSplitStagingReport(
            self.state.ctx,
            self.state.staged_packages.items,
            workspace.destdir,
        ) catch |err| {
            self.state.ctx.debug("failed to collect split staging report: {s}", .{@errorName(err)});
            emit.logFmtSeverity(
                self.state.ctx,
                .build,
                .warn,
                "report: unable to collect split staging report ({s})",
                .{@errorName(err)},
            );
            emitBuildStepSuccess(self.state.ctx, "package artifacts");
            return;
        };
        defer split_report.deinit(self.state.allocator);

        emitSplitStagingReport(self.state.ctx, &self.parsed_recipe, &split_report);
        writeBuildReport(
            self.state.allocator,
            &self.parsed_recipe,
            workspace,
            &split_report,
        ) catch |err| {
            self.state.ctx.debug("failed to write build report: {s}", .{@errorName(err)});
            emit.logFmtSeverity(
                self.state.ctx,
                .build,
                .warn,
                "report: unable to write build report ({s})",
                .{@errorName(err)},
            );
        };
        emitBuildStepSuccess(self.state.ctx, "package artifacts");
    }

    fn runFinalizeStage(self: *BuildPlan, workspace: *const workspace_manager.Workspace) !BuildResult {
        emitBuildStepStart(self.state.ctx, "finalize", true);

        const result = finalizeResult(&self.state, workspace, &self.parsed_recipe) catch |err| {
            emitBuildStepFailure(self.state.ctx, "finalize");
            return err;
        };
        emit.stepEnd(self.state.ctx, .build, "finalize", true);
        emit.phaseEnd(self.state.ctx, .build, true);

        if (self.state.build_profile_instance) |*profile| {
            if (result.status == .success) {
                self.state.allocator.free(profile.profile_path);
            } else {
                profile.cleanup();
            }
            self.state.build_profile_instance = null;
        }

        return result;
    }
};

fn restoreOrStageSplitPackages(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    workspace: *const workspace_manager.Workspace,
) BuildError!void {
    var restored = cache_solver.restore(
        state.allocator,
        state.ctx,
        cache_solver.restoreSplitStageRequest(
            state.cache,
            parsed_recipe,
            workspace.destdir,
            workspace.recipe_root,
            &state.staged_packages,
        ),
    ) catch |err| {
        return mapBuildCacheError(state.ctx, workspace.recipe_root, "failed to restore split-stage cache", err);
    };
    if (restored) |*result| {
        defer result.deinit();
        const hit = result.node;
        state.split_staging_errors_encountered = false;
        try recordNodeResult(state, .split_stage, .restored_from_cache, .split_tree, hit.key_hex, hit.digest_hex, null);
        emitBuildCacheDigest(state.ctx, "split staging", true, hit.digest_hex);
        return;
    }

    split_staging_stage.stageSplitPackages(
        state.allocator,
        state.ctx,
        state.failure_policy == FailurePolicy.StopOnError,
        state.stage_package_files_fn,
        parsed_recipe.name,
        parsed_recipe.packages.items,
        workspace.recipe_root,
        workspace.destdir,
        &state.staged_packages,
        &state.split_staging_errors_encountered,
    ) catch |err| {
        return err;
    };

    var stored = cache_solver.persist(
        state.allocator,
        state.ctx,
        cache_solver.persistSplitStageRequest(
            parsed_recipe,
            workspace.destdir,
            workspace.recipe_root,
            state.staged_packages.items,
        ),
    ) catch |err| {
        return mapBuildCacheError(state.ctx, workspace.recipe_root, "failed to persist split-stage cache", err);
    };
    defer stored.deinit();
    try recordNodeResult(state, .split_stage, .executed, .split_tree, stored.key_hex, stored.digest_hex, null);
    emitBuildCacheDigest(state.ctx, "split staging", false, stored.digest_hex);
}

fn appendBuildProfileDiagnostic(state: *const BuildExecutionState, workspace_profile_dir: []const u8) void {
    const ctx = state.ctx;
    const diag = ctx.getDiagnosticContext();
    const details = diag.details orelse "";
    if (std.mem.indexOf(u8, details, "build_profile=") != null) return;

    const profile = if (state.build_profile_instance) |*p| p.profile_path else "<none>";
    const subject = diag.subject orelse workspace_profile_dir;
    if (details.len == 0) {
        ctx.setDiagnosticContextFmt(subject, "build_profile={s}", .{profile});
    } else {
        ctx.setDiagnosticContextFmt(subject, "{s}; build_profile={s}", .{ details, profile });
    }
}

const WorkspaceStage = struct {
    manager: workspace_manager.WorkspaceManager,
    workspace: workspace_manager.Workspace,

    pub fn deinit(self: *WorkspaceStage) void {
        _ = self.manager;
        self.workspace.deinit();
    }
};

fn createWorkspace(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe) BuildError!WorkspaceStage {
    const ctx = state.ctx;

    // Use setDiagnosticContext to copy recipe name to arena since recipe may be freed before CLI reads context
    ctx.setDiagnosticContext(parsed_recipe.name, null);

    var manager = workspace_manager.WorkspaceManager.init(ctx);
    const workspace = manager.createWorkspace(parsed_recipe) catch |err| {
        const diag = ctx.getDiagnosticContext();
        if (diag.details == null) {
            ctx.setDiagnosticContext(parsed_recipe.name, "failed to create workspace");
        }
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            else => BuildError.WorkspaceCreationFailed,
        };
    };

    state.src_working_dir = workspace.src_dir;

    return WorkspaceStage{
        .manager = manager,
        .workspace = workspace,
    };
}

/// Create a build profile for isolated dependency installation.
fn createBuildProfile(state: *BuildExecutionState, workspace: *const workspace_manager.Workspace) BuildError!void {
    const ctx = state.ctx;

    ctx.debug("creating isolated build profile", .{});

    const profile = build_profile.BuildProfile.create(ctx, workspace.profile_dir) catch |err| {
        ctx.setDiagnosticContext("build_profile", "failed to create build profile");
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            error.PermissionDenied => BuildError.PermissionDenied,
            else => BuildError.WorkspaceCreationFailed,
        };
    };

    state.build_profile_instance = profile;
    const segments = [_]ui.Segment{
        .{ .text = "profile ", .kind = .normal },
        .{ .text = "created", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = profile.profile_path, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, .info, &segments);
}

fn downloadSources(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe, workspace: *const workspace_manager.Workspace) BuildError!void {
    const ctx = state.ctx;

    try stageRecipeCompanionFiles(state, workspace);

    if (parsed_recipe.sources.items.len == 0) {
        return;
    }

    const client = state.download_client orelse {
        return ctx.fail(BuildError.InvalidInput, "download_client", "missing download client");
    };

    const cfg = source_manager.DownloadConfig{
        .sources = parsed_recipe.sources.items,
        .client = client,
        .cache_dir = state.cache_dir,
        .workspace_sources_dir = workspace.sources_dir,
        .recipe_dir = state.recipe_dir,
        .recipe = parsed_recipe,
    };

    var result = source_manager.download(ctx, cfg) catch |err| {
        // Preserve detailed diagnostics from lower layers (URL/hash mismatch).
        // Only provide a fallback when no details are present.
        const diag = ctx.getDiagnosticContext();
        if (diag.details == null) {
            ctx.setDiagnosticContextFmt(diag.subject orelse cfg.recipe_dir, "failed to download sources: {s}", .{@errorName(err)});
        }
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            else => BuildError.SourceDownloadFailed,
        };
    };
    defer result.deinit(ctx.allocator);
}

fn stageRecipeCompanionFiles(state: *BuildExecutionState, workspace: *const workspace_manager.Workspace) BuildError!void {
    const ctx = state.ctx;

    // Some tests construct recipes from in-memory text and intentionally leave recipe_dir empty.
    if (state.recipe_dir.len == 0) return;

    var recipe_dir = std.fs.openDirAbsolute(state.recipe_dir, .{ .iterate = true }) catch |err| {
        ctx.setDiagnosticContext(state.recipe_dir, "failed to open recipe directory");
        return switch (err) {
            error.AccessDenied => BuildError.PermissionDenied,
            else => BuildError.FileSystem,
        };
    };
    defer recipe_dir.close();

    var it = recipe_dir.iterate();
    while (true) {
        const entry = it.next() catch |iter_err| {
            ctx.setDiagnosticContext(state.recipe_dir, "failed to iterate recipe directory");
            return switch (iter_err) {
                error.AccessDenied => BuildError.PermissionDenied,
                else => BuildError.FileSystem,
            };
        } orelse break;

        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }

        if (std.mem.eql(u8, entry.name, "recipe.kdl")) continue;

        const src_path = std.fs.path.join(state.allocator, &.{ state.recipe_dir, entry.name }) catch {
            return ctx.fail(BuildError.OutOfMemory, state.recipe_dir, "failed to allocate companion source path");
        };
        defer state.allocator.free(src_path);

        const dest_path = std.fs.path.join(state.allocator, &.{ workspace.sources_dir, entry.name }) catch {
            return ctx.fail(BuildError.OutOfMemory, workspace.sources_dir, "failed to allocate workspace source path");
        };
        defer state.allocator.free(dest_path);

        var dest_exists = true;
        std.fs.accessAbsolute(dest_path, .{}) catch |access_err| switch (access_err) {
            error.FileNotFound => dest_exists = false,
            error.AccessDenied => return ctx.fail(BuildError.PermissionDenied, dest_path, "cannot access workspace source path"),
            else => return ctx.fail(BuildError.FileSystem, dest_path, "failed to check existing workspace source"),
        };
        if (dest_exists) {
            ctx.debug("companion source already staged: {s}", .{dest_path});
            continue;
        }

        std.fs.copyFileAbsolute(src_path, dest_path, .{}) catch |copy_err| {
            return switch (copy_err) {
                error.PathAlreadyExists => {
                    ctx.debug("companion source already staged: {s}", .{dest_path});
                    continue;
                },
                error.AccessDenied => ctx.fail(BuildError.PermissionDenied, src_path, "failed to stage companion source"),
                else => ctx.fail(BuildError.FileSystem, src_path, "failed to stage companion source"),
            };
        };

        ctx.debug("staged companion source: {s} -> {s}", .{ src_path, dest_path });
    }
}

fn restoreOrFetchSources(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe, workspace: *const workspace_manager.Workspace) BuildError!void {
    const Miss = struct {
        state: *BuildExecutionState,
        parsed_recipe: *const recipe.Recipe,
        workspace: *const workspace_manager.Workspace,

        fn run(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try downloadSources(self.state, self.parsed_recipe, self.workspace);
        }
    };
    const miss = Miss{
        .state = state,
        .parsed_recipe = parsed_recipe,
        .workspace = workspace,
    };

    var solved = cache_solver.solveSourceFetch(
        .{
            .allocator = state.allocator,
            .ctx = state.ctx,
            .cache = state.cache,
        },
        .{
            .recipe_dir = state.recipe_dir,
            .parsed_recipe = parsed_recipe,
            .workspace_sources_dir = workspace.sources_dir,
        },
        .{ .ptr = @constCast(&miss), .run_fn = Miss.run },
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            error.PermissionDenied => BuildError.PermissionDenied,
            error.InvalidInput => BuildError.InvalidInput,
            error.FileSystem => BuildError.FileSystem,
            error.SourceDownloadFailed => BuildError.SourceDownloadFailed,
            else => state.ctx.fail(BuildError.FileSystem, workspace.sources_dir, "failed to solve source fetch"),
        };
    };
    defer solved.deinit();
    try recordNodeResult(state, .source_fetch, solved.execution, .source_fetch, solved.output.key_hex, solved.output.digest_hex, solved.output.actual_subpath);
    if (solved.execution == .restored_from_cache) {
        const segments = [_]ui.Segment{
            .{ .text = "sources ", .kind = .normal },
            .{ .text = "restored from cache", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = solved.output.digest_hex, .kind = .detail },
        };
        emit.logSegmentsSeverity(state.ctx, .prepare, .info, &segments);
    } else {
        const segments = [_]ui.Segment{
            .{ .text = "sources ", .kind = .normal },
            .{ .text = "cached", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = solved.output.digest_hex, .kind = .detail },
        };
        emit.logSegmentsSeverity(state.ctx, .prepare, .info, &segments);
    }
}

fn unpackSources(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe, workspace: *const workspace_manager.Workspace) BuildError!void {
    if (parsed_recipe.sources.items.len == 0) {
        return;
    }

    const ctx = state.ctx;
    const allocator = state.allocator;

    var unpack_res = source_unpacker.unpackFirstSource(allocator, ctx, workspace.sources_dir, workspace.src_dir, parsed_recipe) catch |err| {
        if (err == source_unpacker.UnpackError.NoSources) {
            return;
        }
        ctx.setDiagnosticContext(workspace.src_dir, "failed to unpack first source");
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            error.PermissionDenied => BuildError.PermissionDenied,
            else => BuildError.FileSystem,
        };
    };
    defer unpack_res.deinit(allocator);

    const dup = allocator.dupe(u8, unpack_res.actual_src_dir) catch {
        return ctx.fail(BuildError.OutOfMemory, unpack_res.actual_src_dir, "failed to copy source dir");
    };

    if (state.src_working_dir_buffer) |buf| {
        allocator.free(buf);
    }

    state.src_working_dir = dup;
    state.src_working_dir_buffer = dup;

    const segments = [_]ui.Segment{
        .{ .text = "source dir ", .kind = .normal },
        .{ .text = "unpacked", .kind = .success },
        .{ .text = ": ", .kind = .normal },
        .{ .text = dup, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .prepare, .info, &segments);
}

fn restoreOrUnpackSources(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe, workspace: *const workspace_manager.Workspace) BuildError!void {
    if (parsed_recipe.sources.items.len == 0) return;
    const Miss = struct {
        state: *BuildExecutionState,
        parsed_recipe: *const recipe.Recipe,
        workspace: *const workspace_manager.Workspace,

        fn run(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try unpackSources(self.state, self.parsed_recipe, self.workspace);
        }
    };
    const miss = Miss{
        .state = state,
        .parsed_recipe = parsed_recipe,
        .workspace = workspace,
    };

    var solved = cache_solver.solveSourceUnpack(
        .{
            .allocator = state.allocator,
            .ctx = state.ctx,
            .cache = state.cache,
        },
        .{
            .recipe_dir = state.recipe_dir,
            .parsed_recipe = parsed_recipe,
            .workspace_sources_dir = workspace.sources_dir,
            .workspace_src_dir = workspace.src_dir,
            .actual_src_dir = &state.src_working_dir,
        },
        .{ .ptr = @constCast(&miss), .run_fn = Miss.run },
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            error.PermissionDenied => BuildError.PermissionDenied,
            error.InvalidInput => BuildError.InvalidInput,
            error.FileSystem => BuildError.FileSystem,
            else => state.ctx.fail(BuildError.FileSystem, workspace.src_dir, "failed to solve source unpack"),
        };
    };
    defer solved.deinit();

    const actual = solved.output.actual_path orelse solved.output.restored_root orelse state.src_working_dir orelse workspace.src_dir;
    const dup = state.allocator.dupe(u8, actual) catch {
        return state.ctx.fail(BuildError.OutOfMemory, actual, "failed to copy source dir");
    };
    if (state.src_working_dir_buffer) |buf| state.allocator.free(buf);
    state.src_working_dir = dup;
    state.src_working_dir_buffer = dup;
    try recordNodeResult(state, .source_unpack, solved.execution, .source_unpack, solved.output.key_hex, solved.output.digest_hex, solved.output.actual_subpath);
    if (solved.execution == .restored_from_cache) {
        const segments = [_]ui.Segment{
            .{ .text = "source tree ", .kind = .normal },
            .{ .text = "restored from cache", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = solved.output.digest_hex, .kind = .detail },
        };
        emit.logSegmentsSeverity(state.ctx, .prepare, .info, &segments);
    } else {
        const segments = [_]ui.Segment{
            .{ .text = "source tree ", .kind = .normal },
            .{ .text = "cached", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = solved.output.digest_hex, .kind = .detail },
        };
        emit.logSegmentsSeverity(state.ctx, .prepare, .info, &segments);
    }
}

fn mapBuildCacheError(ctx: *mere.Context, subject: []const u8, details: []const u8, err: anyerror) BuildError {
    const diag = ctx.getDiagnosticContext();
    if (diag.subject == null and diag.details == null) {
        ctx.setDiagnosticContext(subject, details);
    }
    return switch (err) {
        error.OutOfMemory => BuildError.OutOfMemory,
        error.PermissionDenied => BuildError.PermissionDenied,
        error.InvalidInput => BuildError.InvalidInput,
        else => BuildError.FileSystem,
    };
}

fn recordNodeResult(
    state: *BuildExecutionState,
    node_kind: artifact_model.NodeKind,
    execution_kind: artifact_model.NodeExecutionKind,
    artifact_kind: artifact_model.ArtifactKind,
    key_hex: []const u8,
    digest_hex: []const u8,
    actual_subpath: ?[]const u8,
) BuildError!void {
    var node = artifact_model.BuildNode.init(
        state.allocator,
        node_kind,
        execution_kind,
        key_hex,
        artifact_kind,
        digest_hex,
        actual_subpath,
    ) catch {
        return state.ctx.fail(BuildError.OutOfMemory, key_hex, "failed to record build node");
    };
    errdefer node.deinit();

    state.execution.recordNode(state.allocator, node) catch {
        return state.ctx.fail(BuildError.OutOfMemory, key_hex, "failed to append build node");
    };
}

fn recordPackageArchiveNode(
    ptr: *anyopaque,
    execution_kind: artifact_model.NodeExecutionKind,
    key_hex: []const u8,
    digest_hex: []const u8,
) anyerror!void {
    const state: *BuildExecutionState = @ptrCast(@alignCast(ptr));
    try recordNodeResult(state, .package_archive, execution_kind, .package_archive, key_hex, digest_hex, null);
}

fn prepareEnvironment(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe, workspace: *const workspace_manager.Workspace) BuildError!*std.process.EnvMap {
    const allocator = state.allocator;
    const ctx = state.ctx;

    const src_dir = state.src_working_dir orelse workspace.src_dir;
    var host_env = build_environment.createHostBuildEnv(ctx, .{
        .sources_dir = workspace.sources_dir,
        .build_dir = src_dir,
        .destdir = workspace.destdir,
        .recipe_env = parsed_recipe.env.items,
    }) catch |err| {
        return ctx.fail(if (err == error.OutOfMemory) BuildError.OutOfMemory else BuildError.FileSystem, workspace.recipe_root, "failed to build host environment");
    };
    errdefer host_env.deinit();

    const pkg_install_dir = std.fs.path.join(allocator, &.{ workspace.recipe_root, "pkg", "install" }) catch {
        return ctx.fail(BuildError.OutOfMemory, workspace.recipe_root, "failed to alloc package install dir");
    };
    errdefer allocator.free(pkg_install_dir);

    if (state.host_env) |*existing| {
        existing.deinit();
        state.host_env = null;
    }
    if (state.pkg_install_dir) |existing_pkg| {
        allocator.free(existing_pkg);
        state.pkg_install_dir = null;
    }

    state.host_env = host_env;
    state.pkg_install_dir = pkg_install_dir;

    const env_ptr = &state.host_env.?;
    return env_ptr;
}

fn installDependencies(state: *BuildExecutionState, parsed_recipe: *const recipe.Recipe) BuildError!void {
    if (parsed_recipe.depends.items.len == 0) {
        return;
    }

    const ctx = state.ctx;

    const client_for_install = state.download_client orelse {
        return ctx.fail(BuildError.InvalidInput, "download_client", "missing download client");
    };

    if (state.build_profile_instance) |*profile| {
        return restoreOrInstallDependenciesToBuildProfile(state, parsed_recipe, profile, client_for_install);
    }

    return ctx.fail(BuildError.InvalidInput, "build_profile", "missing build profile for dependency installation");
}

fn restoreOrInstallDependenciesToBuildProfile(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    profile: *build_profile.BuildProfile,
    client: download.TransferClient,
) BuildError!void {
    const ctx = state.ctx;
    const config = ctx.configuration orelse {
        return ctx.fail(BuildError.InvalidInput, "config", "no configuration loaded for dependency installation");
    };

    var restored_profile = cache_solver.restore(
        state.allocator,
        ctx,
        cache_solver.restoreProfileTreeRequest(
            state.cache,
            parsed_recipe,
            &config,
            profile.root(),
        ),
    ) catch |err| {
        return mapBuildCacheError(ctx, profile.root(), "failed to restore dependency profile cache", err);
    };
    if (restored_profile) |*result| {
        defer result.deinit();
        const hit = result.node;
        try recordNodeResult(state, .profile_realize, .restored_from_cache, .profile_tree, hit.key_hex, hit.digest_hex, hit.actual_subpath);
        emitBuildCacheDigest(ctx, "dependency profile", true, hit.digest_hex);
        return;
    }

    try installDependenciesToBuildProfile(state, parsed_recipe, profile, client);

    var stored = cache_solver.persist(
        state.allocator,
        ctx,
        cache_solver.persistProfileTreeRequest(
            parsed_recipe,
            &config,
            profile.root(),
        ),
    ) catch |err| {
        return mapBuildCacheError(ctx, profile.root(), "failed to persist dependency profile cache", err);
    };
    defer stored.deinit();
    try recordNodeResult(state, .profile_realize, .executed, .profile_tree, stored.key_hex, stored.digest_hex, stored.actual_subpath);
    emitBuildCacheDigest(ctx, "dependency profile", false, stored.digest_hex);
}

/// Install dependencies to the build profile
fn installDependenciesToBuildProfile(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    profile: *build_profile.BuildProfile,
    client: download.TransferClient,
) BuildError!void {
    const ctx = state.ctx;

    ctx.debug("installing {d} dependencies to build profile", .{parsed_recipe.depends.items.len});

    // Get configuration for repository access
    const config = ctx.configuration orelse {
        return ctx.fail(BuildError.InvalidInput, "config", "no configuration loaded for dependency installation");
    };

    config.validate() catch {
        return BuildError.InvalidInput;
    };

    // Create RepoCaches from the configuration
    var repocaches = repo_sources.createCaches(ctx, &config) catch |err| {
        ctx.setDiagnosticContext("config", "failed to create repo caches from config");
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            error.Network => BuildError.Network,
            error.PermissionDenied => BuildError.PermissionDenied,
            error.FileSystem => BuildError.FileSystem,
            error.SignatureInvalid => BuildError.InvalidInput,
            error.CorruptData => BuildError.FileSystem,
            error.RollbackDetected => BuildError.InvalidInput,
        };
    };
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    // Install all dependency roots in one pass to avoid repeated repo sync churn.
    const install_mod = @import("install.zig");
    install_mod.installPackagesToProfile(
        ctx,
        repocaches.items,
        parsed_recipe.depends.items,
        client,
        false, // reinstall
        false, // verify_store
        false, // force_sync
        null, // profile_name (not creating a generation)
        profile.root(), // target_profile_path
    ) catch |err| {
        if (ctx.diagnostic_context == null) {
            ctx.setDiagnosticContext(parsed_recipe.name, "failed to install dependencies to profile");
        }
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            error.PermissionDenied => BuildError.PermissionDenied,
            error.CorruptData => BuildError.DependencyInstallFailed,
            error.RollbackDetected => BuildError.DependencyInstallFailed,
            else => BuildError.DependencyInstallFailed,
        };
    };
}

fn executePhases(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    host_env: *std.process.EnvMap,
    workspace: *const workspace_manager.Workspace,
) BuildError!void {
    const working_dir = state.src_working_dir orelse {
        state.ctx.setDiagnosticContext("working_dir", "missing source working directory");
        return BuildError.InvalidInput;
    };
    // Note: Don't set diagnostic context here - the CLI already sets context with recipe_path
    // which is valid for the entire CLI handler. Setting context here with parsed_recipe.name
    // would require duplication since the recipe may be freed before CLI reads the context.

    return restoreOrExecutePhases(state, parsed_recipe, working_dir, host_env, workspace);
}

fn restoreOrExecutePhases(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    host_working_dir: []const u8,
    host_env: *std.process.EnvMap,
    workspace: *const workspace_manager.Workspace,
) BuildError!void {
    var exec_ctx = try prepareNamespaceExecution(state, host_working_dir, workspace);
    defer exec_ctx.deinit();

    const profile_tree_hash = hash.calculateStoreContentHash(state.allocator, exec_ctx.profile_root, null) catch |err| {
        return switch (err) {
            error.OutOfMemory => state.ctx.fail(BuildError.OutOfMemory, exec_ctx.profile_root, "failed to hash build profile"),
            error.PermissionDenied => state.ctx.fail(BuildError.PermissionDenied, exec_ctx.profile_root, "failed to hash build profile"),
            else => state.ctx.fail(BuildError.FileSystem, exec_ctx.profile_root, "failed to hash build profile"),
        };
    };
    defer state.allocator.free(profile_tree_hash);
    return executePreparedPhases(state, parsed_recipe, workspace, &exec_ctx, host_env, profile_tree_hash);
}

fn executePreparedPhases(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    workspace: *const workspace_manager.Workspace,
    exec_ctx: *NamespaceExecutionContext,
    host_env: *std.process.EnvMap,
    profile_tree_hash: []const u8,
) BuildError!void {
    const phases = [_]struct { name: []const u8, script: ?[]const u8 }{
        .{ .name = "prepare", .script = parsed_recipe.prepare },
        .{ .name = "build", .script = parsed_recipe.build_phase },
        .{ .name = "check", .script = parsed_recipe.check },
        .{ .name = "install", .script = parsed_recipe.install_phase },
    };

    for (phases) |phase| {
        const phase_script = phase.script orelse continue;
        if (phase_script.len == 0) continue;
        const source_tree_hash = hash.calculateStoreContentHash(state.allocator, workspace.src_dir, null) catch |err| {
            return switch (err) {
                error.OutOfMemory => state.ctx.fail(BuildError.OutOfMemory, workspace.src_dir, "failed to hash source tree"),
                error.PermissionDenied => state.ctx.fail(BuildError.PermissionDenied, workspace.src_dir, "failed to hash source tree"),
                else => state.ctx.fail(BuildError.FileSystem, workspace.src_dir, "failed to hash source tree"),
            };
        };
        defer state.allocator.free(source_tree_hash);

        const phase_output_dir = if (std.mem.eql(u8, phase.name, "install")) workspace.destdir else workspace.src_dir;
        const phase_artifact_kind = artifact_model.phaseOutputKind(phase.name) orelse {
            return state.ctx.fail(BuildError.InvalidInput, phase.name, "unsupported phase artifact kind");
        };
        const phase_node_kind = artifact_model.phaseNodeKind(phase.name) orelse {
            return state.ctx.fail(BuildError.InvalidInput, phase.name, "unsupported phase node kind");
        };
        const phase_env = phaseEnvVars(parsed_recipe, phase.name);
        var restored = cache_solver.restore(
            state.allocator,
            state.ctx,
            cache_solver.restorePhaseOutputRequest(
                state.cache,
                phase.name,
                phase_script,
                parsed_recipe.env.items,
                phase_env,
                source_tree_hash,
                profile_tree_hash,
                exec_ctx.ns_working_dir,
                phase_output_dir,
            ),
        ) catch |err| {
            return mapBuildCacheError(state.ctx, phase_output_dir, "failed to restore phase cache", err);
        };
        if (restored) |*result| {
            defer result.deinit();
            const hit = result.node;
            try recordNodeResult(state, phase_node_kind, .restored_from_cache, phase_artifact_kind, hit.key_hex, hit.digest_hex, hit.actual_subpath);
            emit.stepStartLast(exec_ctx.ctx, .build, phase.name, true);
            emit.stepEnd(exec_ctx.ctx, .build, phase.name, true);
            emitBuildPhaseCacheDigest(state.ctx, phase.name, true, hit.digest_hex);
            continue;
        }

        try runOneNamespacePhase(state, parsed_recipe, workspace, exec_ctx, host_env, phase.name, phase.script);

        var stored = cache_solver.persist(
            state.allocator,
            state.ctx,
            cache_solver.persistPhaseOutputRequest(
                phase.name,
                phase_script,
                parsed_recipe.env.items,
                phase_env,
                source_tree_hash,
                profile_tree_hash,
                exec_ctx.ns_working_dir,
                phase_output_dir,
            ),
        ) catch |err| {
            return mapBuildCacheError(state.ctx, phase_output_dir, "failed to persist phase cache", err);
        };
        defer stored.deinit();
        try recordNodeResult(state, phase_node_kind, .executed, phase_artifact_kind, stored.key_hex, stored.digest_hex, stored.actual_subpath);
        emitBuildPhaseCacheDigest(state.ctx, phase.name, false, stored.digest_hex);
    }
}

const NamespaceExecutionContext = struct {
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    profile_root: []const u8,
    ns_working_dir: []const u8,
    output_capture: ScriptOutputCapture,

    fn deinit(self: *NamespaceExecutionContext) void {
        self.output_capture.deinit();
        self.allocator.free(self.ns_working_dir);
        self.allocator.free(self.profile_root);
    }
};

fn prepareNamespaceExecution(
    state: *BuildExecutionState,
    host_working_dir: []const u8,
    workspace: *const workspace_manager.Workspace,
) BuildError!NamespaceExecutionContext {
    const allocator = state.allocator;
    const ctx = state.ctx;

    const profile_root = if (state.build_profile_instance) |*profile|
        allocator.dupe(u8, profile.root()) catch {
            return ctx.fail(BuildError.OutOfMemory, "profile_root", "failed to copy build profile root");
        }
    else
        resolveSystemProfileRoot(allocator, ctx.root_path) catch {
            return ctx.fail(BuildError.OutOfMemory, "profile_root", "failed to resolve system profile root");
        };
    errdefer allocator.free(profile_root);

    std.fs.accessAbsolute(profile_root, .{}) catch {
        return ctx.fail(BuildError.InvalidInput, profile_root, "profile not found");
    };

    ctx.debug("using profile for namespace: {s}", .{profile_root});

    const ns_working_dir = namespace_paths.translateWorkspacePathToNamespace(allocator, host_working_dir, workspace.recipe_root) catch {
        return ctx.fail(BuildError.OutOfMemory, host_working_dir, "failed to translate working dir for namespace");
    };
    errdefer allocator.free(ns_working_dir);

    const build_log_path = std.fs.path.join(allocator, &.{ workspace.recipe_root, "build.log" }) catch null;
    if (build_log_path) |log_path| {
        defer allocator.free(log_path);
        const log_segments = [_]ui.Segment{
            .{ .text = "log ", .kind = .normal },
            .{ .text = "writing", .kind = .success },
            .{ .text = ": ", .kind = .normal },
            .{ .text = log_path, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, .build, .info, &log_segments);
    }

    const output_capture = ScriptOutputCapture.init(allocator, workspace.recipe_root);

    return NamespaceExecutionContext{
        .allocator = allocator,
        .ctx = ctx,
        .profile_root = profile_root,
        .ns_working_dir = ns_working_dir,
        .output_capture = output_capture,
    };
}

fn runOneNamespacePhase(
    state: *BuildExecutionState,
    parsed_recipe: *const recipe.Recipe,
    workspace: *const workspace_manager.Workspace,
    exec_ctx: *NamespaceExecutionContext,
    host_env: *std.process.EnvMap,
    phase_name: []const u8,
    phase_script_opt: ?[]const u8,
) BuildError!void {
    const phase_script = phase_script_opt orelse return;
    if (phase_script.len == 0) return;

    emit.stepStartLast(exec_ctx.ctx, .build, phase_name, true);
    var phase_step_open = true;
    errdefer if (phase_step_open) emit.stepEnd(exec_ctx.ctx, .build, phase_name, false);

    const phase_script_full = std.fmt.allocPrint(
        exec_ctx.allocator,
        \\cd {s}
        \\trap 'retval=$?; echo "Build failed. Spawning debug shell..."; echo "Exit the shell to continue."; /bin/sh -i; exit $retval' ERR
        \\set -e
        \\{s}
    ,
        .{ exec_ctx.ns_working_dir, phase_script },
    ) catch {
        return exec_ctx.ctx.fail(BuildError.OutOfMemory, "phase_script", "failed to build phase script");
    };
    defer exec_ctx.allocator.free(phase_script_full);
    const cmd_args = [_][]const u8{ "/bin/sh", "-e", "-c", phase_script_full };
    exec_ctx.ctx.debug("full command: {s}", .{phase_script_full});

    const phase_env = phaseEnvVars(parsed_recipe, phase_name);
    var host_phase_env = build_environment.createPhaseHostEnv(exec_ctx.ctx, host_env, phase_env) catch |err| {
        return exec_ctx.ctx.fail(
            if (err == error.OutOfMemory) BuildError.OutOfMemory else BuildError.FileSystem,
            phase_name,
            "failed to build phase environment",
        );
    };
    defer host_phase_env.deinit();

    var ns_env_map = namespace_paths.createNamespaceEnvMap(exec_ctx.allocator, &host_phase_env, workspace.recipe_root) catch {
        return exec_ctx.ctx.fail(BuildError.OutOfMemory, phase_name, "failed to build namespace environment");
    };
    defer ns_env_map.deinit();

    const envp = envMapToCArray(exec_ctx.allocator, &ns_env_map) catch {
        return exec_ctx.ctx.fail(BuildError.OutOfMemory, phase_name, "failed to build envp array");
    };
    defer freeCEnvArray(exec_ctx.allocator, envp);

    const opts = namespace.EnvOptions{
        .profile_root = exec_ctx.profile_root,
        .command = &cmd_args,
        .workspace = workspace.recipe_root,
        .needs_root = parsed_recipe.needs_root,
        .no_etc_overlay = false,
        .env = envp,
        .output_handler = .{
            .ctx = @ptrCast(&exec_ctx.output_capture),
            .handleFn = ScriptOutputCapture.handleChunk,
        },
    };

    const exit_code = state.namespace_runner(exec_ctx.allocator, .build, opts) catch |err| {
        state.ctx.setDiagnosticContext("namespace", "failed to fork and enter env");
        return switch (err) {
            namespace.EnvError.UserNamespacesDisabled => BuildError.PermissionDenied,
            namespace.EnvError.ProfileNotFound => BuildError.InvalidInput,
            namespace.EnvError.WorkspaceNotFound => BuildError.InvalidInput,
            else => BuildError.PhaseExecutionFailed,
        };
    };

    if (exit_code != 0) {
        phase_step_open = false;
        return handlePhaseFailure(state, workspace, exec_ctx.ctx, phase_name, exit_code);
    }

    emit.stepEnd(exec_ctx.ctx, .build, phase_name, true);
    phase_step_open = false;
}

fn handlePhaseFailure(
    state: *BuildExecutionState,
    workspace: *const workspace_manager.Workspace,
    ctx: *mere.Context,
    phase_name: []const u8,
    exit_code: u8,
) BuildError {
    emit.stepEnd(ctx, .build, phase_name, false);

    const trace_summary = state.execution.formatSummaryAlloc(state.allocator) catch null;
    defer if (trace_summary) |summary| state.allocator.free(summary);
    if (trace_summary) |summary| {
        ctx.debug("execution trace: {s}", .{summary});
    }

    if (state.build_profile_instance) |*profile| {
        profile.preserve();
        state.build_profile_instance = null;
    }

    const preserved_segments = [_]ui.Segment{
        .{ .text = "build workspace ", .kind = .normal },
        .{ .text = "preserved", .kind = .warn },
        .{ .text = ": ", .kind = .normal },
        .{ .text = workspace.recipe_root, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, .warn, &preserved_segments);
    ctx.setDiagnosticContextFmt(
        workspace.recipe_root,
        "build phase '{s}' failed with exit code {d}",
        .{ phase_name, exit_code },
    );

    return BuildError.PhaseExecutionFailed;
}

fn phaseEnvVars(parsed_recipe: *const recipe.Recipe, phase_name: []const u8) []const recipe.KV {
    if (std.mem.eql(u8, phase_name, "prepare")) return parsed_recipe.prepare_env.items;
    if (std.mem.eql(u8, phase_name, "build")) return parsed_recipe.build_env.items;
    if (std.mem.eql(u8, phase_name, "check")) return parsed_recipe.check_env.items;
    if (std.mem.eql(u8, phase_name, "install")) return parsed_recipe.install_env.items;
    return &.{};
}

fn resolveSystemProfileRoot(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ root_path, "mere", "profiles", "system", "current" });
}

const ScriptOutputCapture = struct {
    log_file: ?std.fs.File = null,

    fn init(allocator: std.mem.Allocator, recipe_root: []const u8) ScriptOutputCapture {
        var self = ScriptOutputCapture{
            .log_file = null,
        };

        const log_path = std.fs.path.join(allocator, &.{ recipe_root, "build.log" }) catch return self;
        defer allocator.free(log_path);
        self.log_file = std.fs.createFileAbsolute(log_path, .{ .truncate = true }) catch null;
        return self;
    }

    fn deinit(self: *ScriptOutputCapture) void {
        if (self.log_file) |file| {
            file.close();
            self.log_file = null;
        }
    }

    fn handleChunk(ctx_ptr: *anyopaque, bytes: []const u8, is_stderr: bool) void {
        const self: *ScriptOutputCapture = @ptrCast(@alignCast(ctx_ptr));
        self.onChunk(bytes, is_stderr);
    }

    fn onChunk(self: *ScriptOutputCapture, bytes: []const u8, is_stderr: bool) void {
        if (self.log_file) |*file| {
            _ = file.writeAll(bytes) catch {};
        }
        if (is_stderr) {
            _ = std.fs.File.stderr().writeAll(bytes) catch {};
        } else {
            _ = std.fs.File.stdout().writeAll(bytes) catch {};
        }
    }
};

fn emitPackageMetadataReport(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    pkg_name: []const u8,
    files_copied: usize,
    staging_dir: []const u8,
) void {
    var pkg_meta = meta.readFile(allocator, staging_dir) catch |err| {
        var files_buf: [32]u8 = undefined;
        const files_text = std.fmt.bufPrint(&files_buf, "{d}", .{files_copied}) catch return;
        const unavailable_segments = [_]ui.Segment{
            .{ .text = "report ", .kind = .normal },
            .{ .text = pkg_name, .kind = .detail },
            .{ .text = ": files=", .kind = .normal },
            .{ .text = files_text, .kind = .detail },
            .{ .text = " metadata ", .kind = .normal },
            .{ .text = "unavailable", .kind = .warn },
            .{ .text = " (", .kind = .normal },
            .{ .text = @errorName(err), .kind = .detail },
            .{ .text = ")", .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, .build, .warn, &unavailable_segments);
        return;
    };
    defer pkg_meta.deinit();

    var files_buf: [32]u8 = undefined;
    var deps_buf: [32]u8 = undefined;
    var provs_buf: [32]u8 = undefined;
    const files_text = std.fmt.bufPrint(&files_buf, "{d}", .{files_copied}) catch return;
    const deps_text = std.fmt.bufPrint(&deps_buf, "{d}", .{pkg_meta.dependencies.items.len}) catch return;
    const provs_text = std.fmt.bufPrint(&provs_buf, "{d}", .{pkg_meta.provisions.items.len}) catch return;
    const report_segments = [_]ui.Segment{
        .{ .text = "report ", .kind = .normal },
        .{ .text = pkg_name, .kind = .detail },
        .{ .text = ": files=", .kind = .normal },
        .{ .text = files_text, .kind = .detail },
        .{ .text = " deps=", .kind = .normal },
        .{ .text = deps_text, .kind = .detail },
        .{ .text = " provides=", .kind = .normal },
        .{ .text = provs_text, .kind = .detail },
    };
    emit.logSegmentsSeverity(ctx, .build, .info, &report_segments);

    const dep_limit = @min(pkg_meta.dependencies.items.len, ReportListLimit);
    var di: usize = 0;
    while (di < dep_limit) : (di += 1) {
        const dep = pkg_meta.dependencies.items[di];
        const dep_segments = [_]ui.Segment{
            .{ .text = "  dep ", .kind = .normal },
            .{ .text = dep.dep_type.toNodeName(), .kind = .label },
            .{ .text = ": ", .kind = .normal },
            .{ .text = dep.value, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, .build, .info, &dep_segments);
    }
    if (pkg_meta.dependencies.items.len > dep_limit) {
        var more_buf: [32]u8 = undefined;
        const more_text = std.fmt.bufPrint(&more_buf, "{d}", .{pkg_meta.dependencies.items.len - dep_limit}) catch return;
        const dep_more_segments = [_]ui.Segment{
            .{ .text = "  dep ... +", .kind = .normal },
            .{ .text = more_text, .kind = .detail },
            .{ .text = " more", .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, .build, .info, &dep_more_segments);
    }

    const prov_limit = @min(pkg_meta.provisions.items.len, ReportListLimit);
    var pi: usize = 0;
    while (pi < prov_limit) : (pi += 1) {
        const prov = pkg_meta.provisions.items[pi];
        const prov_segments = [_]ui.Segment{
            .{ .text = "  provide ", .kind = .normal },
            .{ .text = prov.prov_type.toNodeName(), .kind = .label },
            .{ .text = ": ", .kind = .normal },
            .{ .text = prov.value, .kind = .detail },
        };
        emit.logSegmentsSeverity(ctx, .build, .info, &prov_segments);
    }
    if (pkg_meta.provisions.items.len > prov_limit) {
        var more_buf: [32]u8 = undefined;
        const more_text = std.fmt.bufPrint(&more_buf, "{d}", .{pkg_meta.provisions.items.len - prov_limit}) catch return;
        const prov_more_segments = [_]ui.Segment{
            .{ .text = "  provide ... +", .kind = .normal },
            .{ .text = more_text, .kind = .detail },
            .{ .text = " more", .kind = .normal },
        };
        emit.logSegmentsSeverity(ctx, .build, .info, &prov_more_segments);
    }
}

pub fn buildOutputsRoot(ctx: *mere.Context) ![]const u8 {
    return std.fs.path.join(ctx.allocator, &.{ ctx.root(), "mere", "dev", "outputs" });
}

pub fn clearBuildOutputs(ctx: *mere.Context) !usize {
    const output_root = try buildOutputsRoot(ctx);
    defer ctx.allocator.free(output_root);

    var dir = std.fs.openDirAbsolute(output_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();

    var removed: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entry_path = try std.fs.path.join(ctx.allocator, &.{ output_root, entry.name });
        defer ctx.allocator.free(entry_path);

        switch (entry.kind) {
            .file, .sym_link => {
                try std.fs.deleteFileAbsolute(entry_path);
                removed += 1;
            },
            .directory => {
                try std.fs.deleteTreeAbsolute(entry_path);
                removed += 1;
            },
            else => {},
        }
    }

    return removed;
}

pub fn collectBuildOutputPackageArchives(ctx: *mere.Context, out_paths: *std.ArrayList([]const u8)) !void {
    const outputs_dir = try buildOutputsRoot(ctx);
    defer ctx.allocator.free(outputs_dir);

    var dir = std.fs.openDirAbsolute(outputs_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => error.InvalidInput,
            error.AccessDenied => error.PermissionDenied,
            else => error.FileSystem,
        };
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(ctx.allocator, &.{ outputs_dir, entry.name });
            defer ctx.allocator.free(subdir_path);

            var subdir = std.fs.openDirAbsolute(subdir_path, .{ .iterate = true }) catch continue;
            defer subdir.close();

            var sub_iter = subdir.iterate();
            while (try sub_iter.next()) |sub_entry| {
                if (sub_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, sub_entry.name, ".pkg.tar.zst")) continue;

                const pkg_path = try std.fs.path.join(ctx.allocator, &.{ subdir_path, sub_entry.name });
                try out_paths.append(ctx.allocator, pkg_path);
            }
        }
    }

    std.mem.sort([]const u8, out_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (out_paths.items.len == 0) return error.InvalidInput;
}

fn exportPackagedArchives(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    packaged_archives: *std.ArrayList([]const u8),
    build_subdir: []const u8,
) !void {
    const output_root = try buildOutputsRoot(ctx);
    defer ctx.allocator.free(output_root);

    const output_dir = try std.fs.path.join(allocator, &.{ output_root, build_subdir });
    defer allocator.free(output_dir);

    // Wipe and recreate so the subdir always reflects exactly this build
    std.fs.deleteTreeAbsolute(output_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return ctx.fail(
            if (err == error.OutOfMemory) BuildError.OutOfMemory else BuildError.FileSystem,
            output_dir,
            "failed to clean build output directory",
        ),
    };

    std.fs.cwd().makePath(output_dir) catch |err| {
        return ctx.fail(
            if (err == error.OutOfMemory) BuildError.OutOfMemory else BuildError.FileSystem,
            output_dir,
            "failed to create build output directory",
        );
    };

    var exported: std.ArrayList([]const u8) = .{};
    defer {
        for (exported.items) |p| allocator.free(p);
        exported.deinit(allocator);
    }

    for (packaged_archives.items) |archive_path| {
        const archive_name = std.fs.path.basename(archive_path);
        const exported_path = try std.fs.path.join(allocator, &.{ output_dir, archive_name });
        errdefer allocator.free(exported_path);

        path_mod.copyFile(archive_path, exported_path) catch |err| {
            allocator.free(exported_path);
            return ctx.fail(
                if (err == error.OutOfMemory) BuildError.OutOfMemory else BuildError.FileSystem,
                archive_path,
                "failed to export package archive from workspace",
            );
        };

        try exported.append(allocator, exported_path);
    }

    for (packaged_archives.items) |archive_path| {
        allocator.free(archive_path);
    }
    packaged_archives.clearRetainingCapacity();

    for (exported.items) |exported_path| {
        try packaged_archives.append(allocator, exported_path);
    }
    exported.clearRetainingCapacity();
}

fn finalizeResult(state: *BuildExecutionState, workspace: *const workspace_manager.Workspace, parsed_recipe: *const recipe.Recipe) !BuildResult {
    state.progress_recorder.completed_steps += 1;

    if (state.progress_cb) |cb| {
        if (cb.on_step) |on_step_fn| {
            const ud = cb.userdata orelse &state.progress_recorder;
            on_step_fn(ud);
        } else if (cb.userdata) |ud| {
            progress_on_step(ud);
        }
    }

    const encountered_error = state.split_staging_errors_encountered or state.packaging_errors_encountered;
    const final_status = if (encountered_error) BuildStatus.partial_failure else BuildStatus.success;

    const trace_summary = state.execution.formatSummaryAlloc(state.allocator) catch null;
    defer if (trace_summary) |summary| state.allocator.free(summary);
    if (trace_summary) |summary| {
        state.ctx.debug("execution trace: {s}", .{summary});
    }

    if (final_status == .success) {
        const r = parsed_recipe;
        const build_subdir = std.fmt.allocPrint(state.allocator, "{s}-{s}-{d}-{s}", .{
            r.name, r.version, r.release, r.arch orelse "unknown",
        }) catch return error.OutOfMemory;
        defer state.allocator.free(build_subdir);
        try exportPackagedArchives(state.allocator, state.ctx, &state.packaged_archives, build_subdir);
        for (state.packaged_archives.items) |exported_path| {
            const name = std.fs.path.basename(exported_path);
            const segments = [_]ui.Segment{
                .{ .text = "output", .kind = .normal },
                .{ .text = ": ", .kind = .normal },
                .{ .text = name, .kind = .detail },
            };
            emit.logSegmentsSeverity(state.ctx, .build, .info, &segments);
        }
    }

    const detail = std.fmt.allocPrint(state.allocator, "{d} packages", .{state.packaged_archives.items.len}) catch {
        return error.OutOfMemory;
    };
    defer state.allocator.free(detail);
    const finalize_kind: ui.SegmentKind = switch (final_status) {
        .success => .success,
        .partial_failure, .failure => .warn,
    };
    const finalize_severity: ui.Severity = switch (final_status) {
        .success => .info,
        .partial_failure, .failure => .warn,
    };
    const segments = [_]ui.Segment{
        .{ .text = "build", .kind = .normal },
        .{ .text = " finalized", .kind = finalize_kind },
        .{ .text = ": ", .kind = .normal },
        .{ .text = detail, .kind = .detail },
    };
    emitFinalBuildArtifactPaths(state.ctx, workspace);
    emit.logSegmentsSeverity(state.ctx, .build, finalize_severity, &segments);

    var result = BuildResult{
        .status = final_status,
        .packages_created = state.takePackagedArchives(),
        .allocator = state.allocator,
    };
    errdefer result.deinit();

    return result;
}

fn loadRecipe(state: *BuildExecutionState) BuildError!recipe.Recipe {
    const buf = state.recipe_buf orelse {
        state.ctx.setDiagnosticContext("recipe", "missing recipe buffer");
        return BuildError.InvalidInput;
    };
    const ctx = state.ctx;
    const parsed = recipe.parse(ctx, buf) catch |err| {
        // Preserve error-specific information in diagnostic context before mapping
        const existing = ctx.getDiagnosticContext();
        // If details not already set by recipe parsing, add fallback detail based on error type
        if (existing.details == null) {
            const detail = switch (err) {
                error.MissingKey => "variable not found in recipe or vars",
                error.UnclosedPlaceholder => "unclosed variable placeholder in script",
                error.MalformedPlaceholder => "malformed variable placeholder in script",
                error.ParseFailed => "syntax error in recipe file",
                error.KeyTooLong => "variable key exceeds maximum length",
                error.MissingVars => "vars block not defined in recipe",
                error.InvalidInput => "invalid recipe format",
                else => "recipe parsing failed",
            };
            ctx.setDiagnosticContext(existing.subject orelse "recipe", detail);
        }
        return switch (err) {
            error.OutOfMemory => BuildError.OutOfMemory,
            else => BuildError.InvalidInput,
        };
    };
    state.recipe_loaded = true;
    return parsed;
}

fn progress_on_step(userdata: *ProgressRecorder) void {
    userdata.completed_steps += 1;
}

fn recipeSubject(parsed_recipe: *const recipe.Recipe) ui.Subject {
    return .{ .name = parsed_recipe.name, .version = parsed_recipe.version };
}

const CaptureEmitter = struct {
    emitter: ui.Emitter,
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) CaptureEmitter {
        return .{
            .emitter = .{ .emitFn = onEmit },
            .allocator = allocator,
            .lines = .{},
        };
    }

    pub fn deinit(self: *CaptureEmitter) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit(self.allocator);
    }

    fn onEmit(emitter: *ui.Emitter, event: ui.Event) void {
        const self: *CaptureEmitter = @fieldParentPtr("emitter", emitter);
        switch (event.kind) {
            .log_line => {
                const msg = event.message orelse return;
                const dup = self.allocator.dupe(u8, msg) catch return;
                self.lines.append(self.allocator, dup) catch {
                    self.allocator.free(dup);
                };
            },
            .log_segments => {
                const segments = event.data.log_segments;
                var buf = std.ArrayList(u8){};
                defer buf.deinit(self.allocator);

                for (segments) |seg| {
                    buf.appendSlice(self.allocator, seg.text) catch return;
                }

                const owned = buf.toOwnedSlice(self.allocator) catch return;
                self.lines.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
            },
            else => {},
        }
    }

    pub fn contains(self: *const CaptureEmitter, needle: []const u8) bool {
        for (self.lines.items) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) return true;
        }
        return false;
    }
};

test "BuildExecutionState init captures orchestrator configuration" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var request = BuildRequest.init();
    const recipe_text = "recipe {\n    name \"state\"\n    version \"1.0\"\n    release 1\n}\nbuild {\n    script \"true\"\n}\npackage \"state\" {\n    files \"*\"\n}";
    request.recipe_text = recipe_text;
    request.cache_dir = "/tmp/test-cache/mere";
    request.failure_policy = FailurePolicy.ContinueOnError;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };
    request.download_client = client;

    var recorder = ProgressRecorder{ .completed_steps = 0 };
    var progress_cb = ProgressCallback{ .on_step = &progress_on_step, .userdata = &recorder };
    request.progress_callback = &progress_cb;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    try std.testing.expect(state.ctx == &test_env.ctx);
    try std.testing.expect(state.recipe_buf != null);
    try std.testing.expect(std.mem.eql(u8, state.recipe_buf.?, recipe_text));
    try std.testing.expect(state.download_client != null);
    try std.testing.expect(state.download_client.?.ptr == request.download_client.?.ptr);
    try std.testing.expect(state.cache_dir != null and std.mem.eql(u8, state.cache_dir.?, request.cache_dir.?));
    try std.testing.expect(state.progress_cb == &progress_cb);
    try std.testing.expect(state.failure_policy == FailurePolicy.ContinueOnError);
    try std.testing.expectEqual(@as(usize, 0), state.progress_recorder.completed_steps);
    try std.testing.expect(state.parsed_recipe == null);
    try std.testing.expect(state.src_working_dir == null);
    try std.testing.expect(state.src_working_dir_buffer == null);
    try std.testing.expect(!state.recipe_loaded);
    try std.testing.expectEqual(@as(usize, 0), state.staged_packages.items.len);
    try std.testing.expect(!state.split_staging_errors_encountered);
    try std.testing.expect(state.stage_package_files_fn == &package_staging.stagePackageFiles);
    try std.testing.expectEqual(@as(usize, 0), state.packaged_archives.items.len);
    try std.testing.expect(!state.packaging_errors_encountered);
    try std.testing.expect(state.create_package_artifact_fn == &defaultCreatePackageArtifact);
}

test "loadRecipe parses recipe buffer and marks state" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "sample"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "sample" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    try std.testing.expect(state.recipe_loaded);
    try std.testing.expect(state.recipe_buf != null);
    try std.testing.expectEqual(@as(usize, 6), parsed.name.len);
    try std.testing.expectEqual(@as(u8, 's'), parsed.name[0]);
    try std.testing.expectEqual(@as(u8, 'a'), parsed.name[1]);
    try std.testing.expectEqual(@as(u8, 'm'), parsed.name[2]);
    try std.testing.expectEqual(@as(u8, 'p'), parsed.name[3]);
    try std.testing.expectEqual(@as(u8, 'l'), parsed.name[4]);
    try std.testing.expectEqual(@as(u8, 'e'), parsed.name[5]);
    try std.testing.expectEqual(@as(usize, 1), parsed.packages.items.len);
}

test "loadRecipe errors when recipe buffer missing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const request = BuildRequest.init();

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    const err = loadRecipe(&state) catch |e| {
        try std.testing.expectEqual(BuildError.InvalidInput, e);
        try std.testing.expect(!state.recipe_loaded);
        return;
    };
    _ = err;
    try std.testing.expect(false);
}

test "createWorkspace initializes workspace and updates state" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "workspace"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "workspace" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();
    state.parsed_recipe = &parsed;

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    const workspace = workspace_stage.workspace;
    try std.testing.expect(state.src_working_dir != null);
    try std.testing.expect(std.mem.eql(u8, state.src_working_dir.?, workspace.src_dir));
    try std.fs.cwd().access(workspace.recipe_root, .{});
    try std.fs.cwd().access(workspace.sources_dir, .{});
    try std.fs.cwd().access(workspace.src_dir, .{});
    try std.fs.cwd().access(workspace.destdir, .{});
}

test "downloadSources errors when download client missing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\source "https://example.org/archive.tar.gz"
        \\recipe {
        \\    name "nosources"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "nosources" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    const err = downloadSources(&state, &parsed, &workspace_stage.workspace) catch |e| {
        try std.testing.expectEqual(BuildError.InvalidInput, e);
        return;
    };
    _ = err;
    try std.testing.expect(false);
}

test "downloadSources succeeds with empty sources" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "emptysources"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "emptysources" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };
    request.download_client = client;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    try downloadSources(&state, &parsed, &workspace_stage.workspace);
}

test "downloadSources resolves local source paths relative to recipe directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const local_name = "local.patch";
    const local_content = "dummy patch content\n";
    const local_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, local_name });
    defer test_env.ctx.allocator.free(local_path);
    {
        var file = try std.fs.createFileAbsolute(local_path, .{});
        defer file.close();
        try file.writeAll(local_content);
    }

    const kdl_text =
        \\source "local.patch"
        \\recipe {
        \\    name "localsource"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "localsource" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;
    request.recipe_dir = test_env.path;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };
    request.download_client = client;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    try downloadSources(&state, &parsed, &workspace_stage.workspace);

    const copied_path = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_stage.workspace.sources_dir, local_name });
    defer test_env.ctx.allocator.free(copied_path);
    const copied = try std.fs.cwd().readFileAlloc(test_env.ctx.allocator, copied_path, 1024);
    defer test_env.ctx.allocator.free(copied);
    try std.testing.expectEqualStrings(local_content, copied);
}

test "downloadSources stages recipe directory companion files without source entries" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const companion_name = "service.conf";
    const companion_content = "listen=127.0.0.1\n";
    const companion_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, companion_name });
    defer test_env.ctx.allocator.free(companion_path);
    {
        var file = try std.fs.createFileAbsolute(companion_path, .{});
        defer file.close();
        try file.writeAll(companion_content);
    }

    const kdl_text =
        \\recipe {
        \\    name "companions"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "companions" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;
    request.recipe_dir = test_env.path;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    try downloadSources(&state, &parsed, &workspace_stage.workspace);

    const staged_path = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_stage.workspace.sources_dir, companion_name });
    defer test_env.ctx.allocator.free(staged_path);
    const staged = try std.fs.cwd().readFileAlloc(test_env.ctx.allocator, staged_path, 1024);
    defer test_env.ctx.allocator.free(staged);
    try std.testing.expectEqualStrings(companion_content, staged);
}

test "unpackSources leaves state unchanged when recipe has no sources" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "nosources"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "nosources" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    const before = state.src_working_dir.?;
    try unpackSources(&state, &parsed, &workspace_stage.workspace);

    try std.testing.expect(state.src_working_dir_buffer == null);
    try std.testing.expect(std.mem.eql(u8, before, state.src_working_dir.?));
    try std.testing.expect(std.mem.eql(u8, workspace_stage.workspace.src_dir, state.src_working_dir.?));
}

test "unpackSources sets actual source dir when source present" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\source "dummy.txt"
        \\recipe {
        \\    name "withsource"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "withsource" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    const src_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_stage.workspace.sources_dir, "dummy.txt" });
    defer test_env.ctx.allocator.free(src_file_path);
    var src_file = try std.fs.createFileAbsolute(src_file_path, .{});
    try src_file.writeAll("dummy");
    src_file.close();

    try unpackSources(&state, &parsed, &workspace_stage.workspace);

    try std.testing.expect(state.src_working_dir_buffer != null);
    try std.testing.expect(std.mem.eql(u8, workspace_stage.workspace.src_dir, state.src_working_dir.?));
    try std.testing.expect(std.mem.eql(u8, state.src_working_dir_buffer.?, state.src_working_dir.?));

    const dest_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ state.src_working_dir.?, "dummy.txt" });
    defer test_env.ctx.allocator.free(dest_file_path);
    var dest_file = try std.fs.openFileAbsolute(dest_file_path, .{});
    dest_file.close();
}

test "prepareEnvironment populates workspace variables and pkg install dir" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "envtest"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    env PATH="/bin"
        \\    script "true"
        \\}
        \\package "envtest" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    const env_map = try prepareEnvironment(&state, &parsed, &workspace_stage.workspace);

    try std.testing.expect(state.host_env != null);
    try std.testing.expect(state.pkg_install_dir != null);

    const build_dir_val = env_map.get("MERE_BUILD_DIR");
    try std.testing.expect(build_dir_val != null);
    try std.testing.expectEqualStrings(workspace_stage.workspace.src_dir, build_dir_val.?);

    const sources_dir_val = env_map.get("MERE_SOURCES_DIR");
    try std.testing.expect(sources_dir_val != null);
    try std.testing.expectEqualStrings(workspace_stage.workspace.sources_dir, sources_dir_val.?);

    const mere_destdir_val = env_map.get("MERE_DESTDIR");
    try std.testing.expect(mere_destdir_val != null);
    try std.testing.expectEqualStrings(workspace_stage.workspace.destdir, mere_destdir_val.?);

    const destdir_val = env_map.get("DESTDIR");
    try std.testing.expect(destdir_val != null);
    try std.testing.expectEqualStrings(workspace_stage.workspace.destdir, destdir_val.?);

    const expected_pkg_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_stage.workspace.recipe_root, "pkg", "install" });
    defer test_env.ctx.allocator.free(expected_pkg_dir);

    try std.testing.expectEqualStrings(expected_pkg_dir, state.pkg_install_dir.?);
}

test "prepareEnvironment respects overridden src working dir" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "customsrc"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "customsrc" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();

    const custom_src = try test_env.ctx.allocator.dupe(u8, "/tmp/custom/src");
    state.src_working_dir_buffer = custom_src;
    state.src_working_dir = custom_src;

    const env_map = try prepareEnvironment(&state, &parsed, &workspace_stage.workspace);

    const build_dir_val2 = env_map.get("MERE_BUILD_DIR");
    try std.testing.expect(build_dir_val2 != null);
    try std.testing.expectEqualStrings(custom_src, build_dir_val2.?);
}

test "installDependencies no-ops when recipe has no dependencies" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "nodeps"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "nodeps" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    try installDependencies(&state, &parsed);
}

test "installDependencies errors when download client missing" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "missingclient"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\    depends "dep-a"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "missingclient" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    const err = installDependencies(&state, &parsed) catch |e| {
        try std.testing.expectEqual(BuildError.InvalidInput, e);
        return;
    };
    _ = err;
    try std.testing.expect(false);
}

test "emitPackageMetadataReport logs dependencies and provisions" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer capture.deinit();
    test_env.ctx.setEmitter(&capture.emitter);

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "report-staging" });
    defer test_env.ctx.allocator.free(staging_dir);
    try std.fs.cwd().makePath(staging_dir);

    var pkg_meta = meta.Data.init(test_env.ctx.allocator);
    defer pkg_meta.deinit();
    try pkg_meta.addDependency(.elf_needed, "libc.so.6");
    try pkg_meta.addProvision(.bin, "report-tool");
    try meta.writeFile(test_env.ctx.allocator, staging_dir, &pkg_meta);

    emitPackageMetadataReport(test_env.ctx.allocator, &test_env.ctx, "report-pkg", 2, staging_dir);

    try std.testing.expect(capture.contains("report report-pkg: files=2 deps=1 provides=1"));
    try std.testing.expect(capture.contains("dep elf-needed: libc.so.6"));
    try std.testing.expect(capture.contains("provide bin: report-tool"));
}

test "finalizeResult assembles success BuildResult" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer capture.deinit();
    test_env.ctx.setEmitter(&capture.emitter);

    const kdl_text =
        \\recipe {
        \\    name "finalize"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "finalize" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();
    const workspace = workspace_stage.workspace;

    const workspace_archive_path = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace.recipe_root, "pkg", "finalize.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(workspace_archive_path);
    {
        var f = try path_mod.makePathAndOpenFile(workspace_archive_path);
        defer f.close();
        try f.writeAll("pkg");
    }

    const outputs_root = try buildOutputsRoot(&test_env.ctx);
    defer test_env.ctx.allocator.free(outputs_root);
    const expected_path = try std.fs.path.join(test_env.ctx.allocator, &.{ outputs_root, "finalize-1.0-1-x86_64", "finalize.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(expected_path);

    const dup_path = try state.allocator.dupe(u8, workspace_archive_path);
    try state.packaged_archives.append(state.allocator, dup_path);

    const log_path = try buildLogPath(test_env.ctx.allocator, workspace.recipe_root);
    defer test_env.ctx.allocator.free(log_path);
    {
        const file = try std.fs.createFileAbsolute(log_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("build log");
    }

    const report_path = try buildReportPath(test_env.ctx.allocator, workspace.recipe_root);
    defer test_env.ctx.allocator.free(report_path);
    {
        const file = try std.fs.createFileAbsolute(report_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("build-report");
    }

    var result = try finalizeResult(&state, &workspace, &parsed);
    defer result.deinit();

    try std.testing.expectEqual(BuildStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.packages_created.items.len);
    try std.testing.expectEqualStrings(expected_path, result.packages_created.items[0]);
    try std.testing.expectEqual(@as(usize, 0), state.packaged_archives.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.progress_recorder.completed_steps);
    try std.fs.accessAbsolute(expected_path, .{});
    try std.fs.accessAbsolute(workspace.recipe_root, .{});
    try std.testing.expect(capture.contains("workspace: "));
    try std.testing.expect(capture.contains("build log: "));
    try std.testing.expect(capture.contains("build report: "));
}

test "clearBuildOutputs removes exported package files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const outputs_root = try buildOutputsRoot(&test_env.ctx);
    defer test_env.ctx.allocator.free(outputs_root);

    // Create a per-build subdir with a package file
    const subdir = try std.fs.path.join(test_env.ctx.allocator, &.{ outputs_root, "foo-1.0-1-x86_64" });
    defer test_env.ctx.allocator.free(subdir);
    try std.fs.cwd().makePath(subdir);

    const pkg_path = try std.fs.path.join(test_env.ctx.allocator, &.{ subdir, "cleanup.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(pkg_path);
    {
        var f = try path_mod.makePathAndOpenFile(pkg_path);
        defer f.close();
        try f.writeAll("pkg");
    }

    const removed = try clearBuildOutputs(&test_env.ctx);
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(subdir, .{}));
}

test "collectBuildOutputPackageArchives returns sorted package outputs" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const outputs_dir = try buildOutputsRoot(&test_env.ctx);
    defer test_env.ctx.allocator.free(outputs_dir);

    // Create a per-build subdir with package files
    const subdir = try std.fs.path.join(test_env.ctx.allocator, &.{ outputs_dir, "test-1.0-1-x86_64" });
    defer test_env.ctx.allocator.free(subdir);
    try std.fs.cwd().makePath(subdir);

    const pkg_b = try std.fs.path.join(test_env.ctx.allocator, &.{ subdir, "b.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(pkg_b);
    try std.fs.cwd().writeFile(.{ .sub_path = pkg_b, .data = "b" });

    const note = try std.fs.path.join(test_env.ctx.allocator, &.{ subdir, "note.txt" });
    defer test_env.ctx.allocator.free(note);
    try std.fs.cwd().writeFile(.{ .sub_path = note, .data = "note" });

    const pkg_a = try std.fs.path.join(test_env.ctx.allocator, &.{ subdir, "a.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(pkg_a);
    try std.fs.cwd().writeFile(.{ .sub_path = pkg_a, .data = "a" });

    var package_paths = std.ArrayList([]const u8){};
    defer {
        for (package_paths.items) |pkg_path| test_env.ctx.allocator.free(pkg_path);
        package_paths.deinit(test_env.ctx.allocator);
    }

    try collectBuildOutputPackageArchives(&test_env.ctx, &package_paths);

    try std.testing.expectEqual(@as(usize, 2), package_paths.items.len);
    try std.testing.expectStringEndsWith(package_paths.items[0], "a.pkg.tar.zst");
    try std.testing.expectStringEndsWith(package_paths.items[1], "b.pkg.tar.zst");
}

test "finalizeResult reports partial failure and fires progress callback" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "finalize-partial"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "finalize-partial" {
        \\    files "usr/bin/*"
        \\}
    ;

    var request = BuildRequest.init();
    request.recipe_text = kdl_text;

    var state = BuildExecutionState.init(test_env.ctx.allocator, &test_env.ctx, request);
    defer state.deinit();

    var parsed = try loadRecipe(&state);
    defer parsed.deinit();

    var workspace_stage = try createWorkspace(&state, &parsed);
    defer workspace_stage.deinit();
    const workspace = workspace_stage.workspace;

    const expected_path = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace.recipe_root, "pkg", "finalize-partial.pkg.tar.zst" });
    defer test_env.ctx.allocator.free(expected_path);
    {
        var f = try path_mod.makePathAndOpenFile(expected_path);
        defer f.close();
        try f.writeAll("pkg");
    }
    const dup_path = try state.allocator.dupe(u8, expected_path);
    try state.packaged_archives.append(state.allocator, dup_path);

    state.split_staging_errors_encountered = true;

    var recorder = ProgressRecorder{ .completed_steps = 0 };
    var progress_cb = ProgressCallback{ .on_step = &progress_on_step, .userdata = &recorder };
    state.progress_cb = &progress_cb;

    var result = try finalizeResult(&state, &workspace, &parsed);
    defer result.deinit();

    try std.testing.expectEqual(BuildStatus.partial_failure, result.status);
    try std.testing.expectEqual(@as(usize, 1), state.progress_recorder.completed_steps);
    try std.testing.expectEqual(@as(usize, 1), recorder.completed_steps);
    try std.testing.expectEqualStrings(expected_path, result.packages_created.items[0]);
    try std.fs.accessAbsolute(workspace.recipe_root, .{});
}

test "envMapToCArray formats key-value entries" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    try env.put("FOO", "bar");
    try env.put("HOME", "/tmp/home");

    const envp = try envMapToCArray(allocator, &env);
    defer freeCEnvArray(allocator, envp);

    try std.testing.expectEqual(@as(usize, 2), envp.len);

    var found_foo = false;
    var found_home = false;
    for (envp) |entry| {
        const s = std.mem.span(entry);
        if (std.mem.eql(u8, s, "FOO=bar")) found_foo = true;
        if (std.mem.eql(u8, s, "HOME=/tmp/home")) found_home = true;
    }
    try std.testing.expect(found_foo);
    try std.testing.expect(found_home);
}

test "build step emit helpers publish expected events" {
    var ctx = mere.Context.init(std.testing.allocator, "/tmp");
    defer ctx.deinit();

    const StepCaptureEmitter = struct {
        emitter: ui.Emitter,
        allocator: std.mem.Allocator,
        events: std.ArrayList(ui.Event),

        fn init(allocator: std.mem.Allocator) @This() {
            var self = @This(){
                .emitter = undefined,
                .allocator = allocator,
                .events = .{},
            };
            self.emitter = .{ .emitFn = onEmit };
            return self;
        }

        fn deinit(self: *@This()) void {
            self.events.deinit(self.allocator);
        }

        fn onEmit(emitter_inner: *ui.Emitter, event: ui.Event) void {
            const self: *@This() = @fieldParentPtr("emitter", emitter_inner);
            self.events.append(self.allocator, event) catch {};
        }
    };

    var capture = StepCaptureEmitter.init(std.testing.allocator);
    defer capture.deinit();
    ctx.setEmitter(&capture.emitter);

    emitBuildStepStart(&ctx, "stage packages", false);
    emitBuildStepSuccess(&ctx, "stage packages");

    try std.testing.expectEqual(@as(usize, 2), capture.events.items.len);
    try std.testing.expectEqual(ui.EventKind.step_start, capture.events.items[0].kind);
    try std.testing.expectEqual(ui.Phase.build, capture.events.items[0].phase.?);
    try std.testing.expectEqualStrings("stage packages", capture.events.items[0].message.?);
    try std.testing.expectEqual(ui.EventKind.step_end, capture.events.items[1].kind);
    try std.testing.expect(capture.events.items[1].data.step_end.status_ok);
}

test "emitBuildStepFailure emits only step_end failure" {
    var ctx = mere.Context.init(std.testing.allocator, "/tmp");
    defer ctx.deinit();

    const FailureCaptureEmitter = struct {
        emitter: ui.Emitter,
        allocator: std.mem.Allocator,
        events: std.ArrayList(ui.Event),

        fn init(allocator: std.mem.Allocator) @This() {
            var self = @This(){
                .emitter = undefined,
                .allocator = allocator,
                .events = .{},
            };
            self.emitter = .{ .emitFn = onEmit };
            return self;
        }

        fn deinit(self: *@This()) void {
            self.events.deinit(self.allocator);
        }

        fn onEmit(emitter_inner: *ui.Emitter, event: ui.Event) void {
            const self: *@This() = @fieldParentPtr("emitter", emitter_inner);
            self.events.append(self.allocator, event) catch {};
        }
    };

    var capture = FailureCaptureEmitter.init(std.testing.allocator);
    defer capture.deinit();
    ctx.setEmitter(&capture.emitter);

    emitBuildStepFailure(&ctx, "package artifacts");

    try std.testing.expectEqual(@as(usize, 1), capture.events.items.len);
    try std.testing.expectEqual(ui.EventKind.step_end, capture.events.items[0].kind);
    try std.testing.expect(!capture.events.items[0].data.step_end.status_ok);
    try std.testing.expectEqual(ui.Severity.err, capture.events.items[0].severity);
}

test "emitSplitStagingReport logs conflicts and unassigned files" {
    const th = @import("test_helpers.zig");

    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer capture.deinit();
    test_env.ctx.setEmitter(&capture.emitter);

    const kdl_text =
        \\recipe {
        \\    name "split"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build { script "true" }
        \\package "split-a" { files "usr/bin/*" }
        \\package "split-b" { files "usr/bin/*" }
    ;

    var parsed = try recipe.parse(&test_env.ctx, kdl_text);
    defer parsed.deinit();

    const workspace_destdir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "split-dest" });
    defer test_env.ctx.allocator.free(workspace_destdir);
    try std.fs.cwd().makePath(workspace_destdir);

    const shared_file = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_destdir, "usr", "bin", "shared" });
    defer test_env.ctx.allocator.free(shared_file);
    try std.fs.cwd().makePath(std.fs.path.dirname(shared_file) orelse workspace_destdir);
    var sf = try std.fs.createFileAbsolute(shared_file, .{});
    defer sf.close();
    try sf.writeAll("shared");

    const orphan_file = try std.fs.path.join(test_env.ctx.allocator, &.{ workspace_destdir, "usr", "bin", "orphan" });
    defer test_env.ctx.allocator.free(orphan_file);
    var of = try std.fs.createFileAbsolute(orphan_file, .{});
    defer of.close();
    try of.writeAll("orphan");

    var staged_packages = std.ArrayList(StagedPackage){};
    defer {
        split_staging_stage.clearStagedPackages(test_env.ctx.allocator, &staged_packages);
        staged_packages.deinit(test_env.ctx.allocator);
    }

    const copied_a = try test_env.ctx.allocator.alloc([]const u8, 1);
    copied_a[0] = try test_env.ctx.allocator.dupe(u8, "usr/bin/shared");
    const staging_a = try test_env.ctx.allocator.dupe(u8, "staging-a");
    try staged_packages.append(test_env.ctx.allocator, .{
        .pkg_index = 0,
        .staging_dir = staging_a,
        .copied_files = copied_a,
    });

    const copied_b = try test_env.ctx.allocator.alloc([]const u8, 1);
    copied_b[0] = try test_env.ctx.allocator.dupe(u8, "usr/bin/shared");
    const staging_b = try test_env.ctx.allocator.dupe(u8, "staging-b");
    try staged_packages.append(test_env.ctx.allocator, .{
        .pkg_index = 1,
        .staging_dir = staging_b,
        .copied_files = copied_b,
    });

    var report = try collectSplitStagingReport(&test_env.ctx, staged_packages.items, workspace_destdir);
    defer report.deinit(test_env.ctx.allocator);

    emitSplitStagingReport(&test_env.ctx, &parsed, &report);

    const workspace_root = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "split-workspace" });
    defer test_env.ctx.allocator.free(workspace_root);
    try std.fs.cwd().makePath(workspace_root);

    var workspace = workspace_manager.Workspace{
        .recipe_root = try test_env.ctx.allocator.dupe(u8, workspace_root),
        .sources_dir = try test_env.ctx.allocator.dupe(u8, workspace_root),
        .src_dir = try test_env.ctx.allocator.dupe(u8, workspace_root),
        .destdir = try test_env.ctx.allocator.dupe(u8, workspace_destdir),
        .profile_dir = try test_env.ctx.allocator.dupe(u8, workspace_root),
        .allocator = test_env.ctx.allocator,
    };
    defer workspace.deinit();

    try writeBuildReport(test_env.ctx.allocator, &parsed, &workspace, &report);

    const report_path = try buildReportPath(test_env.ctx.allocator, workspace.recipe_root);
    defer test_env.ctx.allocator.free(report_path);
    const report_text = try std.fs.cwd().readFileAlloc(test_env.ctx.allocator, report_path, 128 * 1024);
    defer test_env.ctx.allocator.free(report_text);

    try std.testing.expect(capture.contains("split report: assigned=2 unique=1 conflicts=1 unassigned=1"));
    try std.testing.expect(capture.contains("conflict: usr/bin/shared in split-a and split-b"));
    try std.testing.expect(capture.contains("unassigned: usr/bin/orphan"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report_text, 1, "split-staging assigned=2 unique=1 conflicts=1 unassigned=1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, report_text, 1, "conflict path=\"usr/bin/shared\" first-package=\"split-a\" second-package=\"split-b\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, report_text, 1, "unassigned \"usr/bin/orphan\""));
}

fn executeBuildPlanWithTestRunner(
    ctx: *mere.Context,
    request: BuildRequest,
) !BuildResult {
    const th = @import("test_helpers.zig");

    var plan = try planBuild(ctx, request);
    errdefer plan.deinit();
    plan.state.namespace_runner = &th.hostNamespaceRunner;

    const result = try plan.execute();
    plan.deinit();
    return result;
}

fn makeHermeticTestBuildRequest(
    test_env: *@import("test_helpers.zig").TestEnv,
    recipe_text: []const u8,
    client: download.TransferClient,
) !BuildRequest {
    var request = BuildRequest.init();
    request.recipe_text = recipe_text;
    request.recipe_dir = test_env.path;
    request.download_client = client;
    request.cache_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source-cache" });
    return request;
}

fn expectAllPathsWithinRoot(root: []const u8, paths: []const []const u8) !void {
    for (paths) |path_item| {
        try std.testing.expect(std.mem.startsWith(u8, path_item, root));
    }
}

test "executeBuild restores profile phases split staging and package archive on unchanged rebuild" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var repo_setup = try th.setupBusyboxRepo(test_env);
    defer repo_setup.deinit();

    const kdl_text =
        \\recipe {
        \\    name "cache-hit"
        \\    version "1.0"
        \\    release 1
        \\    depends "busybox"
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "mkdir -p dummy && printf built > dummy/hello.txt"
        \\}
        \\check {
        \\    script "test -f dummy/hello.txt"
        \\}
        \\install {
        \\    script "mkdir -p $DESTDIR/dummy && cp dummy/hello.txt $DESTDIR/dummy/"
        \\}
        \\package "cache-hit" {
        \\    files "dummy/hello.txt"
        \\}
    ;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };

    var warm_capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer warm_capture.deinit();
    test_env.ctx.setEmitter(&warm_capture.emitter);
    {
        const request = try makeHermeticTestBuildRequest(test_env, kdl_text, client);
        defer test_env.ctx.allocator.free(request.cache_dir.?);
        var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
        defer result.deinit();
        try std.testing.expectEqual(BuildStatus.success, result.status);
        try expectAllPathsWithinRoot(test_env.path, result.packages_created.items);
    }

    var hit_capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer hit_capture.deinit();
    test_env.ctx.setEmitter(&hit_capture.emitter);
    {
        const request = try makeHermeticTestBuildRequest(test_env, kdl_text, client);
        defer test_env.ctx.allocator.free(request.cache_dir.?);
        var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
        defer result.deinit();
        try std.testing.expectEqual(BuildStatus.success, result.status);
        try expectAllPathsWithinRoot(test_env.path, result.packages_created.items);
    }

    try std.testing.expect(hit_capture.contains("dependency profile restored from cache"));
    try std.testing.expect(hit_capture.contains("phase restored from cache: build"));
    try std.testing.expect(hit_capture.contains("phase restored from cache: check"));
    try std.testing.expect(hit_capture.contains("phase restored from cache: install"));
    try std.testing.expect(hit_capture.contains("split staging restored from cache"));
    try std.testing.expect(hit_capture.contains("packaged from cache:"));
}

test "executeBuild restores unpacked source tree from cache on unchanged rebuild" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_name = "dummy.txt";
    const source_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, source_name });
    defer test_env.ctx.allocator.free(source_path);
    {
        var file = try std.fs.createFileAbsolute(source_path, .{});
        defer file.close();
        try file.writeAll("hello from source\n");
    }

    const kdl_text =
        \\source "dummy.txt"
        \\recipe {
        \\    name "source-cache-hit"
        \\    version "1.0"
        \\    release 1
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "test -f dummy.txt"
        \\}
        \\install {
        \\    script "mkdir -p $DESTDIR/share && cp dummy.txt $DESTDIR/share/"
        \\}
        \\package "source-cache-hit" {
        \\    files "share/dummy.txt"
        \\}
    ;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };

    var warm_capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer warm_capture.deinit();
    test_env.ctx.setEmitter(&warm_capture.emitter);
    {
        const request = try makeHermeticTestBuildRequest(test_env, kdl_text, client);
        defer test_env.ctx.allocator.free(request.cache_dir.?);
        var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
        defer result.deinit();
        try std.testing.expectEqual(BuildStatus.success, result.status);
        try expectAllPathsWithinRoot(test_env.path, result.packages_created.items);
    }

    var hit_capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer hit_capture.deinit();
    test_env.ctx.setEmitter(&hit_capture.emitter);
    {
        const request = try makeHermeticTestBuildRequest(test_env, kdl_text, client);
        defer test_env.ctx.allocator.free(request.cache_dir.?);
        var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
        defer result.deinit();
        try std.testing.expectEqual(BuildStatus.success, result.status);
        try expectAllPathsWithinRoot(test_env.path, result.packages_created.items);
    }

    try std.testing.expect(hit_capture.contains("sources restored from cache"));
    try std.testing.expect(hit_capture.contains("source tree restored from cache"));
}

test "executeBuild applies global env to every phase and overlays per-phase env" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var repo_setup = try th.setupBusyboxRepo(test_env);
    defer repo_setup.deinit();

    const kdl_text =
        \\recipe {
        \\    name "phase-env"
        \\    version "1.0"
        \\    release 1
        \\    depends "busybox"
        \\    archs "x86_64"
        \\    env GLOBAL_FLAG="global" SHARED_FLAG="base"
        \\}
        \\prepare {
        \\    env SHARED_FLAG="prepare-override"
        \\    script "test \"$GLOBAL_FLAG\" = \"global\" && test \"$SHARED_FLAG\" = \"prepare-override\" && mkdir -p dummy && printf built > dummy/hello.txt"
        \\}
        \\build {
        \\    env SHARED_FLAG="build-override"
        \\    script "test \"$GLOBAL_FLAG\" = \"global\" && test \"$SHARED_FLAG\" = \"build-override\" && test -f dummy/hello.txt"
        \\}
        \\check {
        \\    script "test \"$GLOBAL_FLAG\" = \"global\" && test \"$SHARED_FLAG\" = \"base\" && test -f dummy/hello.txt"
        \\}
        \\install {
        \\    env SHARED_FLAG="install-override"
        \\    script "test \"$GLOBAL_FLAG\" = \"global\" && test \"$SHARED_FLAG\" = \"install-override\" && mkdir -p $DESTDIR/dummy && cp dummy/hello.txt $DESTDIR/dummy/"
        \\}
        \\package "phase-env" {
        \\    files "dummy/hello.txt"
        \\}
    ;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };

    const request = try makeHermeticTestBuildRequest(test_env, kdl_text, client);
    defer test_env.ctx.allocator.free(request.cache_dir.?);

    var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
    defer result.deinit();

    try std.testing.expectEqual(BuildStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.packages_created.items.len);
}

test "executeBuild reruns changed check phase while restoring build" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var repo_setup = try th.setupBusyboxRepo(test_env);
    defer repo_setup.deinit();

    const kdl_v1 =
        \\recipe {
        \\    name "cache-check"
        \\    version "1.0"
        \\    release 1
        \\    depends "busybox"
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "mkdir -p dummy && printf built > dummy/hello.txt"
        \\}
        \\check {
        \\    script "test -f dummy/hello.txt"
        \\}
        \\install {
        \\    script "mkdir -p $DESTDIR/dummy && cp dummy/hello.txt $DESTDIR/dummy/"
        \\}
        \\package "cache-check" {
        \\    files "dummy/hello.txt"
        \\}
    ;

    const kdl_v2 =
        \\recipe {
        \\    name "cache-check"
        \\    version "1.0"
        \\    release 1
        \\    depends "busybox"
        \\    archs "x86_64"
        \\}
        \\build {
        \\    script "mkdir -p dummy && printf built > dummy/hello.txt"
        \\}
        \\check {
        \\    script "test -f dummy/hello.txt && test -n \"second-check\""
        \\}
        \\install {
        \\    script "mkdir -p $DESTDIR/dummy && cp dummy/hello.txt $DESTDIR/dummy/"
        \\}
        \\package "cache-check" {
        \\    files "dummy/hello.txt"
        \\}
    ;

    var dummy = th.DummyClient.init(test_env.ctx.allocator);
    defer dummy.deinit();
    var vt: download.TransferClient.VTable = .{ .download_file = th.dummy_download_file };
    const client = download.TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vt };

    {
        var warm_capture = CaptureEmitter.init(test_env.ctx.allocator);
        defer warm_capture.deinit();
        test_env.ctx.setEmitter(&warm_capture.emitter);

        const request = try makeHermeticTestBuildRequest(test_env, kdl_v1, client);
        defer test_env.ctx.allocator.free(request.cache_dir.?);
        var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
        defer result.deinit();
        try std.testing.expectEqual(BuildStatus.success, result.status);
        try expectAllPathsWithinRoot(test_env.path, result.packages_created.items);
    }

    var second_capture = CaptureEmitter.init(test_env.ctx.allocator);
    defer second_capture.deinit();
    test_env.ctx.setEmitter(&second_capture.emitter);
    {
        const request = try makeHermeticTestBuildRequest(test_env, kdl_v2, client);
        defer test_env.ctx.allocator.free(request.cache_dir.?);
        var result = try executeBuildPlanWithTestRunner(&test_env.ctx, request);
        defer result.deinit();
        try std.testing.expectEqual(BuildStatus.success, result.status);
        try expectAllPathsWithinRoot(test_env.path, result.packages_created.items);
    }

    try std.testing.expect(second_capture.contains("dependency profile restored from cache"));
    try std.testing.expect(second_capture.contains("phase restored from cache: build"));
    try std.testing.expect(!second_capture.contains("phase restored from cache: check"));
}
