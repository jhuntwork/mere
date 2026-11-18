// Generation activation - atomic switching between profile generations
//
// Key properties:
// - Atomic switching via temp symlink + rename
// - Single symlink change (<profile_dir>/current)
// - Symlink is sole source of truth for current generation
// - Idempotent operation (cleans up stale temp symlinks)
// - GC roots updated after activation
//
// Layout:
//   /mere/profiles/<name>/
//   ├── current -> gen-N  (this is what we atomically switch)
//   ├── gen-1/
//   ├── gen-2/
//   └── ...

const std = @import("std");
const builtin = @import("builtin");
const generation = @import("generation.zig");
const gcroots = @import("gcroots.zig");
const etc = @import("etc.zig");
const mere = @import("mere.zig");
const meta = @import("meta.zig");
const errors = @import("errors.zig");
const hash = @import("hash.zig");
const package_manifest = @import("manifest.zig");
const path_mod = @import("path.zig");
const path_safety = @import("path_safety.zig");
const store = @import("store.zig");
const service_policy = @import("service_policy.zig");
const service_reconcile = @import("service_reconcile.zig");
const activation_lock = @import("activation_lock.zig");
const fault_injection = @import("fault_injection.zig");
const publish = @import("publish.zig");

/// Activation error set
const Std = errors.StandardErrors;
pub const ActivationError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData || error{
    GenerationNotFound, // Target generation doesn't exist
    ManifestNotFound, // Generation exists but manifest is missing/unreadable
    DuplicateEtcTemplate, // Two packages provide same /etc path
};

const CURRENT_SYMLINK = "current";
const CURRENT_SYMLINK_TEMP = ".current-new";

pub const VerificationMode = enum {
    fast,
    full_store,
};

pub const ActivationOutcome = enum {
    /// Preparation failed before the generation pointer changed.
    not_committed,
    /// The pointer changed and post-commit maintenance completed.
    committed,
    /// The pointer changed but post-commit maintenance must be retried.
    committed_needs_repair,
};

pub const SystemActivationResult = struct {
    outcome: ActivationOutcome,
    /// Set when activation did not commit or when post-commit maintenance
    /// failed. The pointer state is authoritative when outcome is not_committed
    /// or committed_needs_repair; callers must never infer it from the error
    /// alone.
    failure: ?ActivationError = null,
    etc_copied: usize = 0,
    etc_skipped: usize = 0,
    etc_differing: usize = 0,
    boot_artifacts_staged: usize = 0,
};

/// Deterministic fault points used by activation tests. The setter ignores
/// them in production builds.
pub const FailurePoint = enum {
    before_pointer_switch,
    after_pointer_switch,
    gc_root_update,
};

var failure_point_for_test: ?FailurePoint = null;

pub fn setFailurePointForTest(point: ?FailurePoint) void {
    if (builtin.is_test) failure_point_for_test = point;
}

fn failAt(point: FailurePoint) ActivationError!void {
    if (failure_point_for_test == point) {
        failure_point_for_test = null;
        return ActivationError.FileSystem;
    }
}

fn checkFault(ctx: *mere.Context, checkpoint: fault_injection.Checkpoint, subject: []const u8) ActivationError!void {
    fault_injection.hit(checkpoint) catch |err| switch (err) {
        error.InjectedFailure => return ctx.fail(ActivationError.FileSystem, subject, "fault injection checkpoint failed"),
    };
}

fn mapStoreLockError(err: anyerror) ActivationError {
    return switch (err) {
        error.OutOfMemory => ActivationError.OutOfMemory,
        error.PermissionDenied => ActivationError.PermissionDenied,
        else => ActivationError.FileSystem,
    };
}

/// Switch the active generation for a profile and update its GC roots.
/// The pointer switch is the commit point; a post-switch maintenance failure
/// is returned as `committed_needs_repair` rather than as an ambiguous error.
pub fn switchProfileGeneration(
    ctx: *mere.Context,
    profile_name: []const u8,
    gen_num: u32,
    verification: VerificationMode,
) SystemActivationResult {
    ctx.acquireStoreLockForMutation() catch |err| return .{
        .outcome = .not_committed,
        .failure = mapStoreLockError(err),
    };
    defer ctx.releaseStoreLock();

    return switchProfileGenerationInternal(ctx, profile_name, gen_num, verification) catch |err| .{
        .outcome = .not_committed,
        .failure = err,
    };
}

fn switchProfileGenerationInternal(
    ctx: *mere.Context,
    profile_name: []const u8,
    gen_num: u32,
    verification: VerificationMode,
) ActivationError!SystemActivationResult {
    activation_lock.mutex.lockUncancelable(path_mod.currentIo());
    defer activation_lock.mutex.unlock(path_mod.currentIo());

    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, profile_name);
    defer ctx.allocator.free(profile_dir);

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();

    // Prepare all paths before the pointer switch. Once it succeeds, only
    // maintenance operations represented by an explicit repair outcome remain.
    const gc_roots_dir = try getGCRootsDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(gc_roots_dir);
    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root);

    if (try switchProfileGenerationAtPath(ctx, profile_dir, gen_num) == .needs_repair) {
        return .{ .outcome = .committed_needs_repair, .failure = ActivationError.FileSystem };
    }

    failAt(.after_pointer_switch) catch |err| {
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        return .{ .outcome = .committed_needs_repair, .failure = err };
    };
    failAt(.gc_root_update) catch |err| {
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        return .{ .outcome = .committed_needs_repair, .failure = err };
    };

    checkFault(ctx, .gc_roots_before_update, gc_roots_dir) catch |err| {
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        return .{ .outcome = .committed_needs_repair, .failure = err };
    };
    gcroots.updateRoots(ctx, store_root, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
        const mapped = mapGCRootError(err);
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        return .{ .outcome = .committed_needs_repair, .failure = mapped };
    };
    fault_injection.hit(.gc_roots_after_update) catch |err| switch (err) {
        error.InjectedFailure => {
            ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
            return .{ .outcome = .committed_needs_repair, .failure = ActivationError.FileSystem };
        },
    };

    return .{ .outcome = .committed };
}

/// Preserve the failure class of a service-tree error so callers and exit
/// codes can tell a permission problem from a bad service definition.
fn mapReconcileError(err: service_reconcile.ReconcileError) ActivationError {
    return switch (err) {
        error.OutOfMemory => ActivationError.OutOfMemory,
        error.PermissionDenied => ActivationError.PermissionDenied,
        error.InvalidInput, error.DuplicateService => ActivationError.InvalidInput,
        error.FileSystem => ActivationError.FileSystem,
    };
}

/// Attempt activation and always return an explicit commit outcome.
///
/// Failures before the pointer switch are returned as `not_committed`. Once
/// the pointer switch succeeds, the function never reports an uncommitted
/// result, even when GC-root maintenance needs repair.
pub fn activateSystemGeneration(
    ctx: *mere.Context,
    gen_num: u32,
    verification: VerificationMode,
) SystemActivationResult {
    ctx.acquireStoreLockForMutation() catch |err| return .{
        .outcome = .not_committed,
        .failure = mapStoreLockError(err),
    };
    defer ctx.releaseStoreLock();

    return activateSystemGenerationInternal(ctx, gen_num, verification) catch |err| .{
        .outcome = .not_committed,
        .failure = err,
    };
}

/// Switch the active generation for the system profile and apply system activation policy.
fn activateSystemGenerationInternal(
    ctx: *mere.Context,
    gen_num: u32,
    verification: VerificationMode,
) ActivationError!SystemActivationResult {
    activation_lock.mutex.lockUncancelable(path_mod.currentIo());
    defer activation_lock.mutex.unlock(path_mod.currentIo());

    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, "system");
    defer ctx.allocator.free(profile_dir);

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();

    // Reading the current generation is only needed to compare live service
    // ownership, which applies solely to the host root under the dinit
    // provider. Skipping it elsewhere keeps rollback away from a damaged
    // generation, alternate-root activation and other providers working.
    if (service_policy.appliesTo(ctx)) {
        const previous_num = generation.getCurrentGeneration(profile_dir) catch return ActivationError.FileSystem;
        if (previous_num) |number| {
            const previous_path = generation.getGenerationPath(ctx.allocator, profile_dir, number) catch return ActivationError.InvalidInput;
            defer ctx.allocator.free(previous_path);
            const store_root = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" });
            defer ctx.allocator.free(store_root);
            var previous = generation.readManifest(ctx.allocator, store_root, previous_path) catch return ActivationError.CorruptData;
            defer previous.deinit();
            service_policy.checkTransition(ctx, previous.packages.items, manifest.packages.items) catch |err| {
                return switch (err) {
                    error.OutOfMemory => ActivationError.OutOfMemory,
                    else => ActivationError.InvalidInput,
                };
            };
        }
    }

    const provider = if (ctx.configuration) |*cfg| cfg.effectiveInitProvider() else .s6rc;
    var pointer_committed = false;
    var staged_dinit: ?service_reconcile.StagedDinit = null;
    defer if (staged_dinit) |*staged| {
        if (!pointer_committed) {
            staged.rollback() catch {
                ctx.setDiagnosticContext("dinit", "failed to restore the previous service tree before activation commit");
            };
        }
        staged.discard();
    };

    if (provider == .dinit) {
        const target_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch return ActivationError.InvalidInput;
        defer ctx.allocator.free(target_path);
        const current_num = generation.getCurrentGeneration(profile_dir) catch return ActivationError.FileSystem;
        if (current_num == gen_num) {
            service_reconcile.finalizeDinitBackup(ctx.allocator, target_path) catch |err| {
                return ctx.failFmt(mapReconcileError(err), "dinit", "cannot repair the previous service-tree backup: {s}", .{@errorName(err)});
            };
        }
        // The dinit tree is inside the target generation, not the provider's
        // live service root. Publishing it here is still preparation. The
        // rollback guard restores an existing tree when the target is already
        // current, and discarding a new generation removes its tree.
        staged_dinit = service_reconcile.stageDinit(ctx, target_path, manifest.packages.items, &.{}) catch |err| {
            return ctx.failFmt(mapReconcileError(err), "dinit", "cannot realize generation services: {s}", .{@errorName(err)});
        };
        if (staged_dinit) |*staged| {
            staged.commit() catch |err| return ctx.failFmt(mapReconcileError(err), "dinit", "cannot publish generation services: {s}", .{@errorName(err)});
        }
    }

    const etc_dir = try getEtcDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(etc_dir);

    var boot_artifacts_created: std.ArrayList([]const u8) = .empty;
    defer {
        for (boot_artifacts_created.items) |artifact| ctx.allocator.free(artifact);
        boot_artifacts_created.deinit(ctx.allocator);
    }

    try checkFault(ctx, .etc_before_changes, etc_dir);
    var etc_result = try applyEtcTemplatesForManifest(ctx, &manifest, etc_dir);
    errdefer if (!pointer_committed) {
        etc.rollbackCreatedFiles(ctx, &etc_result) catch {};
        rollbackBootArtifacts(&boot_artifacts_created);
        etc_result.deinit();
    };
    try checkFault(ctx, .etc_after_changes, etc_dir);

    // Allocate every post-commit path before the pointer switch. After the
    // switch, only operations whose result can be represented as
    // `committed_needs_repair` are allowed to fail.
    const gc_roots_dir = try getGCRootsDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(gc_roots_dir);
    const store_root_b = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root_b);

    // Boot artifacts are staged under unique names before the generation
    // pointer changes. Newly published artifacts are tracked so an ordinary
    // pre-commit failure can remove them again.
    try checkFault(ctx, .boot_before_staging, "boot");
    const boot_artifacts_staged = try stageBootArtifacts(ctx, &manifest, &boot_artifacts_created);
    try checkFault(ctx, .boot_after_staging, "boot");

    try failAt(.before_pointer_switch);
    const pointer_status = try switchProfileGenerationAtPath(ctx, profile_dir, gen_num);
    pointer_committed = true;
    if (pointer_status == .needs_repair) {
        const result: SystemActivationResult = .{
            .outcome = .committed_needs_repair,
            .failure = ActivationError.FileSystem,
            .etc_copied = etc_result.copied,
            .etc_skipped = etc_result.skipped,
            .etc_differing = etc_result.differing,
            .boot_artifacts_staged = boot_artifacts_staged,
        };
        etc_result.deinit();
        return result;
    }

    const committedResult = struct {
        fn make(
            outcome: ActivationOutcome,
            failure: ?ActivationError,
            copied: usize,
            skipped: usize,
            differing: usize,
            boot: usize,
        ) SystemActivationResult {
            return .{
                .outcome = outcome,
                .failure = failure,
                .etc_copied = copied,
                .etc_skipped = skipped,
                .etc_differing = differing,
                .boot_artifacts_staged = boot,
            };
        }
    }.make;

    if (staged_dinit) |*staged| {
        staged.finalize() catch |err| {
            const mapped = mapReconcileError(err);
            ctx.setDiagnosticContext("dinit", "generation committed; previous service tree cleanup needs repair");
            const result = committedResult(.committed_needs_repair, mapped, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
            etc_result.deinit();
            return result;
        };
    }

    // The pointer switch is the commit point. From here on, never run the
    // preparation rollback handler, even when maintenance fails.
    failAt(.after_pointer_switch) catch |err| {
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        const result = committedResult(.committed_needs_repair, err, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
        etc_result.deinit();
        return result;
    };

    failAt(.gc_root_update) catch |err| {
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        const result = committedResult(.committed_needs_repair, err, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
        etc_result.deinit();
        return result;
    };

    checkFault(ctx, .gc_roots_before_update, gc_roots_dir) catch |err| {
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        const result = committedResult(.committed_needs_repair, err, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
        etc_result.deinit();
        return result;
    };
    gcroots.updateRoots(ctx, store_root_b, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
        const mapped = mapGCRootError(err);
        ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
        const result = committedResult(.committed_needs_repair, mapped, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
        etc_result.deinit();
        return result;
    };
    fault_injection.hit(.gc_roots_after_update) catch |err| switch (err) {
        error.InjectedFailure => {
            ctx.setDiagnosticContext(gc_roots_dir, "generation committed; GC roots need repair");
            const result = committedResult(.committed_needs_repair, ActivationError.FileSystem, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
            etc_result.deinit();
            return result;
        },
    };

    const result = committedResult(.committed, null, etc_result.copied, etc_result.skipped, etc_result.differing, boot_artifacts_staged);
    etc_result.deinit();
    return result;
}

/// Repair post-commit activation maintenance without changing the generation
/// pointer or reapplying `/etc`. This is safe to retry after a process crash or
/// a failed GC-root update.
pub fn repairSystemGeneration(
    ctx: *mere.Context,
    verification: VerificationMode,
) ActivationError!void {
    ctx.acquireStoreLockForMutation() catch |err| return mapStoreLockError(err);
    defer ctx.releaseStoreLock();

    activation_lock.mutex.lockUncancelable(path_mod.currentIo());
    defer activation_lock.mutex.unlock(path_mod.currentIo());

    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, "system");
    defer ctx.allocator.free(profile_dir);

    const gen_num = generation.getCurrentGeneration(profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => ActivationError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ActivationError.PermissionDenied,
            generation.GenerationError.InvalidInput => ActivationError.InvalidInput,
            else => ActivationError.FileSystem,
        };
    } orelse return ActivationError.GenerationNotFound;

    var profile_handle = path_mod.openExistingDir(profile_dir) catch |err| {
        return ctx.failFmt(ActivationError.FileSystem, profile_dir, "failed to open profile during repair: {s}", .{@errorName(err)});
    };
    defer profile_handle.close(path_mod.currentIo());
    publish.syncDir(profile_handle) catch |err| {
        return ctx.failFmt(ActivationError.FileSystem, profile_dir, "failed to persist current pointer during repair: {s}", .{@errorName(err)});
    };

    const current_generation_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => ActivationError.OutOfMemory,
            generation.GenerationError.InvalidInput => ActivationError.InvalidInput,
            else => ActivationError.FileSystem,
        };
    };
    defer ctx.allocator.free(current_generation_path);

    const gc_roots_dir = try getGCRootsDir(ctx.allocator, ctx.root_path);
    defer ctx.allocator.free(gc_roots_dir);
    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(store_root);

    // Protect the generation selected by `current` before validating any
    // store object. If validation reports corruption, GC still sees the active
    // generation and cannot collect its reachable objects.
    gcroots.ensureCurrentRootForProfile(ctx, gc_roots_dir, profile_dir) catch |err| {
        return ctx.fail(mapGCRootError(err), gc_roots_dir, "failed to protect the active generation during repair");
    };
    service_reconcile.finalizeDinitBackup(ctx.allocator, current_generation_path) catch |err| {
        return ctx.failFmt(mapReconcileError(err), "dinit", "failed to repair the previous service-tree backup: {s}", .{@errorName(err)});
    };

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();

    try failAt(.gc_root_update);
    try checkFault(ctx, .gc_roots_before_update, gc_roots_dir);
    gcroots.updateRoots(ctx, store_root, gc_roots_dir, profile_dir, gcroots.DEFAULT_RETENTION_COUNT) catch |err| {
        return ctx.fail(mapGCRootError(err), gc_roots_dir, "failed to repair GC roots after activation");
    };
    try checkFault(ctx, .gc_roots_after_update, gc_roots_dir);
}

pub fn stageCurrentSystemBootArtifacts(
    ctx: *mere.Context,
    verification: VerificationMode,
) ActivationError!usize {
    ctx.acquireStoreLockForMutation() catch |err| return mapStoreLockError(err);
    defer ctx.releaseStoreLock();

    activation_lock.mutex.lockUncancelable(path_mod.currentIo());
    defer activation_lock.mutex.unlock(path_mod.currentIo());

    const profile_dir = try getProfileDir(ctx.allocator, ctx.root_path, "system");
    defer ctx.allocator.free(profile_dir);

    const gen_num = generation.getCurrentGeneration(profile_dir) catch |err| {
        return switch (err) {
            generation.GenerationError.OutOfMemory => ActivationError.OutOfMemory,
            generation.GenerationError.PermissionDenied => ActivationError.PermissionDenied,
            generation.GenerationError.ProfilesNotFound => ActivationError.GenerationNotFound,
            else => ActivationError.FileSystem,
        };
    } orelse return ActivationError.GenerationNotFound;

    var manifest = try loadValidatedTargetManifest(ctx, profile_dir, gen_num, verificationEnabled(verification));
    defer manifest.deinit();

    var created: std.ArrayList([]const u8) = .empty;
    defer {
        for (created.items) |artifact| ctx.allocator.free(artifact);
        created.deinit(ctx.allocator);
    }
    const staged = stageBootArtifacts(ctx, &manifest, &created) catch |err| {
        rollbackBootArtifacts(&created);
        return err;
    };
    return staged;
}

/// Durably switch current; a visible but unsynced pointer requires repair.
const PointerStatus = enum { durable, needs_repair };
fn switchProfileGenerationAtPath(
    ctx: *mere.Context,
    profile_dir: []const u8,
    gen_num: u32,
) ActivationError!PointerStatus {
    // Open profile directory for symlink operations
    var profile_dir_handle = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_dir, .{}) catch {
        return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to open profile directory for activation");
    };
    defer profile_dir_handle.close(path_mod.currentIo());

    // Remove stale temp symlink if it exists (idempotent)
    profile_dir_handle.deleteFile(path_mod.currentIo(), CURRENT_SYMLINK_TEMP) catch |err| {
        switch (err) {
            error.FileNotFound => {}, // OK, doesn't exist
            else => {
                return ctx.fail(ActivationError.FileSystem, profile_dir, "failed to remove stale temp symlink");
            },
        }
    };

    // Create the symlink target (relative path within profile_dir: gen-N)
    const target = generation.formatGenerationName(ctx.allocator, gen_num) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to allocate generation name");
    };
    defer ctx.allocator.free(target);

    publish.replaceSymlink(profile_dir_handle, target, CURRENT_SYMLINK, .{
        .guarantee = .durable,
        .checkpoints = .{ .before = .current_before_replace, .after = .current_after_replace },
    }) catch |err| {
        const mapped: ActivationError = switch (err) {
            error.OutOfMemory => ActivationError.OutOfMemory,
            error.AccessDenied => ActivationError.PermissionDenied,
            else => ActivationError.FileSystem,
        };
        if (err == error.PublishedNotDurable) {
            ctx.setDiagnosticContext(profile_dir, "generation committed; rerun activation to persist the current pointer and repair maintenance");
            return .needs_repair;
        }
        ctx.setDiagnosticContextFmt(profile_dir, "failed to publish current pointer: {s}", .{@errorName(err)});
        return mapped;
    };
    return .durable;
}

fn loadValidatedTargetManifest(
    ctx: *mere.Context,
    profile_dir: []const u8,
    gen_num: u32,
    verify_store: bool,
) ActivationError!generation.GenerationManifest {
    // Validate target generation exists (profile_dir/gen-N)
    const gen_path = generation.getGenerationPath(ctx.allocator, profile_dir, gen_num) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to construct generation path");
    };
    defer ctx.allocator.free(gen_path);

    // Check generation directory exists
    std.Io.Dir.accessAbsolute(path_mod.currentIo(), gen_path, .{}) catch {
        return ctx.fail(ActivationError.GenerationNotFound, gen_path, "generation not found");
    };

    // Check manifest exists and parses (completion marker)
    const manifest_path = std.fs.path.join(ctx.allocator, &.{ gen_path, generation.MANIFEST_FILENAME }) catch {
        return ctx.fail(ActivationError.OutOfMemory, gen_path, "failed to construct manifest path");
    };
    defer ctx.allocator.free(manifest_path);

    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(ActivationError.OutOfMemory, gen_path, "failed to construct store root path");
    };
    defer ctx.allocator.free(store_root);

    var manifest = generation.readManifest(ctx.allocator, store_root, gen_path) catch |err| {
        const detail = switch (err) {
            generation.GenerationError.GenerationNotFound,
            generation.GenerationError.InvalidManifest,
            generation.GenerationError.ParseError,
            => "profile.kdl missing or invalid",
            generation.GenerationError.NoCurrentGeneration,
            generation.GenerationError.NoPreviousGeneration,
            => "unexpected generation query error",
            generation.GenerationError.PermissionDenied => "permission denied reading profile.kdl",
            generation.GenerationError.FileSystem => "failed to read profile.kdl",
            generation.GenerationError.OutOfMemory => "out of memory",
            generation.GenerationError.InvalidInput => "invalid manifest path",
            generation.GenerationError.ProfilesNotFound => "profile directory missing",
        };
        return ctx.fail(switch (err) {
            generation.GenerationError.OutOfMemory => ActivationError.OutOfMemory,
            generation.GenerationError.InvalidManifest,
            generation.GenerationError.ParseError,
            => ActivationError.CorruptData,
            generation.GenerationError.GenerationNotFound => ActivationError.ManifestNotFound,
            else => ActivationError.FileSystem,
        }, manifest_path, detail);
    };
    errdefer manifest.deinit();

    try validateGenerationStorePaths(ctx, profile_dir, &manifest, verify_store);
    return manifest;
}

fn applyEtcTemplatesForManifest(
    ctx: *mere.Context,
    manifest: *const generation.GenerationManifest,
    etc_dir: []const u8,
) ActivationError!etc.TemplateResult {
    return etc.processTemplates(ctx, manifest, etc_dir) catch |err| {
        const detail = switch (err) {
            etc.EtcError.DuplicateTemplate => "duplicate /etc template",
            etc.EtcError.OutOfMemory => "out of memory",
            etc.EtcError.PermissionDenied => "permission denied",
            etc.EtcError.FileSystem => "file system error",
        };
        const mapped_err = mapEtcError(err);
        if (ctx.diagnostic_context == null) {
            return ctx.fail(mapped_err, etc_dir, detail);
        }
        return mapped_err;
    };
}

fn isSystemProfile(profile_dir: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(profile_dir), "system");
}

fn verificationEnabled(mode: VerificationMode) bool {
    return switch (mode) {
        .fast => false,
        .full_store => true,
    };
}

fn getProfileDir(allocator: std.mem.Allocator, root_path: []const u8, profile_name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, "mere", "profiles", profile_name });
}

fn getGCRootsDir(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, "mere", "gc-roots" });
}

fn getEtcDir(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root_path, "etc" });
}

const BOOT_ARTIFACT_HASH_PREFIX_LEN: usize = 16;

/// Stage the boot payload of the selected Linux package without changing the
/// bootloader selection. Names include the package content hash so a new
/// payload never overwrites an older same-version kernel.
fn stageBootArtifacts(
    ctx: *mere.Context,
    manifest: *const generation.GenerationManifest,
    created: ?*std.ArrayList([]const u8),
) ActivationError!usize {
    const boot_dir = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "boot" }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(boot_dir);

    if (created) |list| {
        var linux_packages: usize = 0;
        for (manifest.packages.items) |pkg| {
            if (std.mem.eql(u8, pkg.name, "linux")) linux_packages += 2;
        }
        list.ensureTotalCapacity(ctx.allocator, list.items.len + linux_packages) catch {
            return ActivationError.OutOfMemory;
        };
    }

    var staged: usize = 0;
    for (manifest.packages.items) |pkg| {
        // Boot projection is intentionally explicit. Other packages may carry
        // a boot/ directory for their own purposes, but only linux owns the
        // host kernel staging contract.
        if (!std.mem.eql(u8, pkg.name, "linux")) continue;
        if (pkg.version.len == 0 or pkg.content_hash.len < BOOT_ARTIFACT_HASH_PREFIX_LEN) {
            return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "invalid linux package identity for boot staging");
        }
        for (pkg.version) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and c != '+') {
                return ctx.fail(ActivationError.InvalidInput, pkg.version, "unsafe linux version for boot artifact name");
            }
        }
        for (pkg.content_hash[0..BOOT_ARTIFACT_HASH_PREFIX_LEN]) |c| {
            if (!std.ascii.isHex(c)) {
                return ctx.fail(ActivationError.InvalidInput, pkg.content_hash, "invalid linux content hash for boot artifact name");
            }
        }

        const source_vmlinux = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, "boot", "vmlinux" }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(source_vmlinux);
        const source_config = std.fs.path.join(ctx.allocator, &.{ pkg.store_path, "boot", "config" }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(source_config);

        for ([_][]const u8{ source_vmlinux, source_config }) |source| {
            std.Io.Dir.accessAbsolute(path_mod.currentIo(), source, .{}) catch {
                return ctx.fail(ActivationError.FileSystem, source, "linux package is missing a boot artifact");
            };
        }

        path_mod.ensureDirExists(boot_dir) catch |err| {
            return ctx.fail(switch (err) {
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, boot_dir, "failed to create boot directory");
        };

        const hash_prefix = pkg.content_hash[0..BOOT_ARTIFACT_HASH_PREFIX_LEN];
        const vmlinux_name = std.fmt.allocPrint(ctx.allocator, "vmlinux-{s}-{s}", .{ pkg.version, hash_prefix }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(vmlinux_name);
        const config_name = std.fmt.allocPrint(ctx.allocator, "config-{s}-{s}", .{ pkg.version, hash_prefix }) catch {
            return ActivationError.OutOfMemory;
        };
        defer ctx.allocator.free(config_name);

        const vmlinux_staged = try stageOneBootArtifact(ctx, boot_dir, source_vmlinux, vmlinux_name, created);
        staged += vmlinux_staged;

        const config_staged = try stageOneBootArtifact(ctx, boot_dir, source_config, config_name, created);
        staged += config_staged;
    }

    return staged;
}

fn rollbackBootArtifacts(created: *std.ArrayList([]const u8)) void {
    for (created.items) |artifact| {
        std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), artifact) catch {};
    }
}

fn stageOneBootArtifact(
    ctx: *mere.Context,
    boot_dir: []const u8,
    source: []const u8,
    name: []const u8,
    created: ?*std.ArrayList([]const u8),
) ActivationError!usize {
    const destination = std.fs.path.join(ctx.allocator, &.{ boot_dir, name }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(destination);

    // Content-addressed naming makes this idempotent and preserves all older
    // kernel payloads. Do not replace an existing artifact merely because a
    // same-version package was selected again.
    if (path_mod.fileExists(destination)) return 0;

    // Reserve the rollback record before publishing. Every later failure can
    // then safely remove this path, while a concurrent winner removes the
    // record before returning the idempotent success result.
    var recorded_list: ?*std.ArrayList([]const u8) = null;
    if (created) |list| {
        const owned = ctx.allocator.dupe(u8, destination) catch {
            return ActivationError.OutOfMemory;
        };
        list.appendAssumeCapacity(owned);
        recorded_list = list;
    }

    var random_bytes: [8]u8 = undefined;
    path_mod.currentIo().random(&random_bytes);
    const temp_name = std.fmt.allocPrint(ctx.allocator, ".mere-{s}-{s}", .{ name, std.fmt.bytesToHex(random_bytes, .lower) }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(temp_name);
    const temp_path = std.fs.path.join(ctx.allocator, &.{ boot_dir, temp_name }) catch {
        return ActivationError.OutOfMemory;
    };
    defer ctx.allocator.free(temp_path);

    path_mod.copyFile(source, temp_path) catch |err| {
        return ctx.fail(switch (err) {
            error.AccessDenied => ActivationError.PermissionDenied,
            else => ActivationError.FileSystem,
        }, source, "failed to copy boot artifact");
    };
    errdefer std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), temp_path) catch {};

    std.Io.Dir.renameAbsolute(temp_path, destination, path_mod.currentIo()) catch |err| {
        // Another activation may have staged the same content concurrently.
        // Preserve that winner and discard only our temporary file and record.
        if (err == error.PathAlreadyExists or err == error.AccessDenied) {
            if (path_mod.fileExists(destination)) {
                if (recorded_list) |list| {
                    const owned = list.pop() orelse unreachable;
                    ctx.allocator.free(owned);
                }
                return 0;
            }
        }
        return ctx.fail(switch (err) {
            error.AccessDenied => ActivationError.PermissionDenied,
            else => ActivationError.FileSystem,
        }, destination, "failed to publish boot artifact");
    };

    return 1;
}

// Stage boot artifacts for the selected Linux package. This deliberately
// leaves bootloader configuration and the currently selected entry alone.
test "stageBootArtifacts publishes versioned linux payloads idempotently" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789-linux-1.2.3" });
    defer allocator.free(store_path);
    const package_boot = try std.fs.path.join(allocator, &.{ store_path, "boot" });
    defer allocator.free(package_boot);
    try path_mod.ensureDirExists(package_boot);

    const source_vmlinux = try std.fs.path.join(allocator, &.{ package_boot, "vmlinux" });
    defer allocator.free(source_vmlinux);
    var vmlinux = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), source_vmlinux, .{});
    try vmlinux.writeStreamingAll(path_mod.currentIo(), "kernel");
    vmlinux.close(path_mod.currentIo());

    const source_config = try std.fs.path.join(allocator, &.{ package_boot, "config" });
    defer allocator.free(source_config);
    var config = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), source_config, .{});
    try config.writeStreamingAll(path_mod.currentIo(), "CONFIG_TUN=y\\n");
    config.close(path_mod.currentIo());

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "linux",
        "1.2.3",
        1,
        "x86_64",
        store_path,
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
    );

    try std.testing.expectEqual(@as(usize, 2), try stageBootArtifacts(&test_env.ctx, &manifest, null));
    try std.testing.expectEqual(@as(usize, 0), try stageBootArtifacts(&test_env.ctx, &manifest, null));

    const staged_vmlinux = try std.fs.path.join(allocator, &.{ test_env.path, "boot", "vmlinux-1.2.3-abcdef0123456789" });
    defer allocator.free(staged_vmlinux);
    const staged_config = try std.fs.path.join(allocator, &.{ test_env.path, "boot", "config-1.2.3-abcdef0123456789" });
    defer allocator.free(staged_config);
    try std.testing.expect(path_mod.fileExists(staged_vmlinux));
    try std.testing.expect(path_mod.fileExists(staged_config));

    // The activation transaction records newly published artifacts before
    // returning. A pre-commit rollback removes both files without touching
    // artifacts that already existed.
    try std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), staged_vmlinux);
    try std.Io.Dir.deleteFileAbsolute(path_mod.currentIo(), staged_config);
    var created: std.ArrayList([]const u8) = .empty;
    defer {
        for (created.items) |artifact| allocator.free(artifact);
        created.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), try stageBootArtifacts(&test_env.ctx, &manifest, &created));
    try std.testing.expectEqual(@as(usize, 2), created.items.len);
    rollbackBootArtifacts(&created);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), staged_vmlinux, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), staged_config, .{}));
}

fn mapEtcError(err: etc.EtcError) ActivationError {
    return switch (err) {
        etc.EtcError.DuplicateTemplate => ActivationError.DuplicateEtcTemplate,
        etc.EtcError.OutOfMemory => ActivationError.OutOfMemory,
        etc.EtcError.PermissionDenied => ActivationError.PermissionDenied,
        etc.EtcError.FileSystem => ActivationError.FileSystem,
    };
}

fn mapGCRootError(err: gcroots.GCRootsError) ActivationError {
    return switch (err) {
        gcroots.GCRootsError.OutOfMemory => ActivationError.OutOfMemory,
        gcroots.GCRootsError.PermissionDenied => ActivationError.PermissionDenied,
        gcroots.GCRootsError.InvalidInput => ActivationError.InvalidInput,
        gcroots.GCRootsError.GenerationNotFound => ActivationError.GenerationNotFound,
        else => ActivationError.FileSystem,
    };
}

fn validateGenerationStorePaths(
    ctx: *mere.Context,
    profile_dir: []const u8,
    manifest: *const generation.GenerationManifest,
    verify_store: bool,
) ActivationError!void {
    const store_root = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "store" }) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to construct store root path");
    };
    defer ctx.allocator.free(store_root);
    const normalized_store_root = std.fs.path.resolve(ctx.allocator, &.{store_root}) catch {
        return ctx.fail(ActivationError.OutOfMemory, profile_dir, "failed to normalize store root path");
    };
    defer ctx.allocator.free(normalized_store_root);

    const require_root_owned = isSystemProfile(profile_dir);

    for (manifest.packages.items) |pkg| {
        const normalized_store_path = std.fs.path.resolve(ctx.allocator, &.{pkg.store_path}) catch {
            return ctx.fail(ActivationError.OutOfMemory, pkg.store_path, "failed to normalize store path");
        };
        defer ctx.allocator.free(normalized_store_path);

        if (!path_safety.isWithinBoundary(normalized_store_path, normalized_store_root)) {
            return ctx.fail(ActivationError.CorruptData, pkg.store_path, "store path outside store root");
        }

        var store_dir = path_mod.openExistingDir(pkg.store_path) catch |err| {
            return ctx.fail(switch (err) {
                error.FileNotFound => ActivationError.FileSystem,
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, pkg.store_path, "failed to stat store path");
        };
        defer store_dir.close(path_mod.currentIo());
        const stat_buf = store_dir.stat(path_mod.currentIo()) catch |err| {
            return ctx.fail(switch (err) {
                error.AccessDenied => ActivationError.PermissionDenied,
                else => ActivationError.FileSystem,
            }, pkg.store_path, "failed to stat store path");
        };

        if (stat_buf.kind != .directory) {
            return ctx.fail(ActivationError.InvalidInput, pkg.store_path, "store path is not a directory");
        }

        // For system profiles, hash verification is mandatory for unhardened objects.
        // Already-hardened objects were verified when first admitted.
        const do_hash_verify = verify_store or (require_root_owned and store.needsContentVerification(pkg.store_path));

        if (do_hash_verify) {
            // store.verifyObjectContent owns the hash-compatibility policy and
            // records the diagnostic; only the error vocabulary maps here.
            _ = store.verifyObjectContent(ctx, pkg.store_path, pkg.content_hash) catch |err| {
                return switch (err) {
                    error.OutOfMemory => ActivationError.OutOfMemory,
                    error.PermissionDenied => ActivationError.PermissionDenied,
                    error.CorruptData => ActivationError.CorruptData,
                    error.InvalidInput => ActivationError.InvalidInput,
                    else => ActivationError.FileSystem,
                };
            };
        }
    }
}

test "switchProfileGeneration creates atomic symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Create a generation with manifest
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

    // Create a minimal manifest
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try generation.writeManifest(&test_env.ctx, gen_path, &manifest);

    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Verify symlink was created
    const current = try generation.getCurrentGeneration(profile_dir);
    try std.testing.expectEqual(@as(?u32, 1), current);
}

test "switchProfileGeneration fails for non-existent generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer test_env.ctx.allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const result = switchProfileGeneration(&test_env.ctx, "system", 999, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, result.outcome);
    try std.testing.expectEqual(ActivationError.GenerationNotFound, result.failure.?);
}

test "switchProfileGeneration cleans up stale temp symlink" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Create a stale temp symlink
    var profile_dir_handle = try std.Io.Dir.openDirAbsolute(io, profile_dir, .{});
    defer profile_dir_handle.close(io);
    try profile_dir_handle.symLink(io, "gen-old", CURRENT_SYMLINK_TEMP, .{});

    // Create a generation with manifest
    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try generation.writeManifest(&test_env.ctx, gen_path, &manifest);

    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Verify correct generation is active
    const current = try generation.getCurrentGeneration(profile_dir);
    try std.testing.expectEqual(@as(?u32, 1), current);
}

test "switchProfileGeneration can switch between generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Create two generations
    for ([_]u32{ 1, 2 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        {
            var dir = try path_mod.makePathAndOpenDir(gen_path);
            dir.close(io);
        }

        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(&test_env.ctx, gen_path, &manifest);
    }

    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);
    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));

    _ = switchProfileGeneration(&test_env.ctx, "system", 2, .fast);
    try std.testing.expectEqual(@as(?u32, 2), try generation.getCurrentGeneration(profile_dir));

    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);
    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));
}

test "switchProfileGeneration creates GC roots" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gc_roots_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "gc-roots" });
    defer allocator.free(gc_roots_dir);

    // Create generations 1-3 with manifests
    for ([_]u32{ 1, 2, 3 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        {
            var dir = try path_mod.makePathAndOpenDir(gen_path);
            dir.close(io);
        }

        var manifest = generation.GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try generation.writeManifest(&test_env.ctx, gen_path, &manifest);
    }

    _ = switchProfileGeneration(&test_env.ctx, "system", 3, .fast);

    // Check that current root was created in the nested structure (profiles/system/current)
    const profile_gc_dir = try std.fs.path.join(allocator, &.{ gc_roots_dir, "profiles", "system" });
    defer allocator.free(profile_gc_dir);

    const current_root = try std.fs.path.join(allocator, &.{ profile_gc_dir, "current" });
    defer allocator.free(current_root);
    std.Io.Dir.accessAbsolute(io, current_root, .{}) catch {
        return error.TestUnexpectedResult;
    };

    // Check that generation roots were created (should have gen-2 and gen-3 in kept/)
    const roots = try gcroots.listGenerationRoots(allocator, profile_gc_dir);
    defer allocator.free(roots);

    try std.testing.expectEqual(@as(usize, 2), roots.len);
}

test "switchProfileGeneration rejects store path that shares prefix but escapes store root" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

    // Store path escapes store root — can't happen via derived paths, but test
    // the validation layer directly by writing a manifest with the old format
    // fields still present in-memory.
    const escaped_store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store-evil", "badpkg" });
    defer allocator.free(escaped_store_path);

    // Build manifest in-memory with the bad store path (bypassing encode/parse)
    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "badpkg",
        "1.0.0",
        1,
        "x86_64",
        escaped_store_path,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );

    // Write a valid KDL so readManifest succeeds, but then swap the manifest
    // with our crafted one for validation testing.
    try generation.writeManifest(&test_env.ctx, gen_path, &manifest);

    const result = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
}

test "applyEtcTemplatesForManifest preserves PermissionDenied from etc template processing" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "user" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen_path);
        dir.close(io);
    }

    const content_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", content_hash ++ "-testpkg-1.0.0" });
    defer allocator.free(store_path);
    const template_subdir = try std.fs.path.join(allocator, &.{ store_path, "etc-defaults", "subdir" });
    defer allocator.free(template_subdir);
    {
        var dir = try path_mod.makePathAndOpenDir(template_subdir);
        dir.close(io);
    }

    const template_file = try std.fs.path.join(allocator, &.{ template_subdir, "service.conf" });
    defer allocator.free(template_file);
    var tf = try std.Io.Dir.createFileAbsolute(io, template_file, .{});
    defer tf.close(io);
    try tf.writeStreamingAll(io, "key=value\n");

    var manifest = generation.GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try manifest.addPackage(
        "testpkg",
        "1.0.0",
        1,
        "x86_64",
        store_path,
        content_hash,
    );
    try generation.writeManifest(&test_env.ctx, gen_path, &manifest);

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(etc_dir);
        dir.close(io);
    }
    var etc_handle = try path_mod.openExistingDir(etc_dir);
    defer etc_handle.close(io);
    try etc_handle.setPermissions(io, .fromMode(0o555));
    defer etc_handle.setPermissions(io, .fromMode(0o755)) catch {};

    var loaded_manifest = try loadValidatedTargetManifest(&test_env.ctx, profile_dir, 1, false);
    defer loaded_manifest.deinit();

    const result = applyEtcTemplatesForManifest(&test_env.ctx, &loaded_manifest, etc_dir);
    if (result) |success| {
        var owned = success;
        defer owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(ActivationError.PermissionDenied, err);
    }
}

test "activateSystemGeneration rolls back created /etc files and does not switch on failure" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen1_path);
        dir.close(io);
    }

    var manifest1 = generation.GenerationManifest.init(allocator, 1);
    defer manifest1.deinit();
    try generation.writeManifest(&test_env.ctx, gen1_path, &manifest1);

    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    const gen2_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2" });
    defer allocator.free(gen2_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen2_path);
        dir.close(io);
    }

    // Build store path contents first in a temp location, then compute the real
    // content hash so system profile activation's mandatory verification passes.
    const store_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store" });
    defer allocator.free(store_root);

    const tmp_store_path = try std.fs.path.join(allocator, &.{ store_root, "tmp-testpkg-2.0.0" });
    defer allocator.free(tmp_store_path);

    const defaults_root = try std.fs.path.join(allocator, &.{ tmp_store_path, "etc-defaults" });
    defer allocator.free(defaults_root);
    {
        var dir = try path_mod.makePathAndOpenDir(defaults_root);
        dir.close(io);
    }

    const copied_template = try std.fs.path.join(allocator, &.{ defaults_root, "copied.conf" });
    defer allocator.free(copied_template);
    {
        var copied = try std.Io.Dir.createFileAbsolute(io, copied_template, .{});
        defer copied.close(io);
        try copied.writeStreamingAll(io, "copied=true\n");
    }

    const conflict_dir = try std.fs.path.join(allocator, &.{ defaults_root, "service" });
    defer allocator.free(conflict_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(conflict_dir);
        dir.close(io);
    }

    const conflict_template = try std.fs.path.join(allocator, &.{ conflict_dir, "config.conf" });
    defer allocator.free(conflict_template);
    {
        var conflict = try std.Io.Dir.createFileAbsolute(io, conflict_template, .{});
        defer conflict.close(io);
        try conflict.writeStreamingAll(io, "new-value=true\n");
    }

    // Compute real content hash and rename to final store path
    const content_hash_2 = try hash.calculateStoreContentHash(allocator, tmp_store_path, null);
    defer allocator.free(content_hash_2);

    const final_dir_name = try std.fmt.allocPrint(allocator, "{s}-testpkg-2.0.0", .{content_hash_2});
    defer allocator.free(final_dir_name);

    const store_path = try std.fs.path.join(allocator, &.{ store_root, final_dir_name });
    defer allocator.free(store_path);

    try std.Io.Dir.renameAbsolute(tmp_store_path, store_path, io);

    var manifest2 = generation.GenerationManifest.init(allocator, 2);
    defer manifest2.deinit();
    try manifest2.addPackage(
        "testpkg",
        "2.0.0",
        1,
        "x86_64",
        store_path,
        content_hash_2,
    );
    try generation.writeManifest(&test_env.ctx, gen2_path, &manifest2);

    const etc_dir = try std.fs.path.join(allocator, &.{ test_env.path, "etc" });
    defer allocator.free(etc_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(etc_dir);
        dir.close(io);
    }

    const existing_dir = try std.fs.path.join(allocator, &.{ etc_dir, "service" });
    defer allocator.free(existing_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(existing_dir);
        dir.close(io);
    }

    const existing_file = try std.fs.path.join(allocator, &.{ existing_dir, "config.conf" });
    defer allocator.free(existing_file);
    {
        var existing = try std.Io.Dir.createFileAbsolute(io, existing_file, .{});
        defer existing.close(io);
        try existing.writeStreamingAll(io, "old-value=true\n");
    }

    const created_file = try std.fs.path.join(allocator, &.{ etc_dir, "copied.conf" });
    defer allocator.free(created_file);
    const new_file = try std.fmt.allocPrint(allocator, "{s}.new", .{existing_file});
    defer allocator.free(new_file);

    std.Io.Dir.accessAbsolute(io, created_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.Io.Dir.accessAbsolute(io, new_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };

    var etc_handle = try path_mod.openExistingDir(etc_dir);
    defer etc_handle.close(io);
    try etc_handle.setPermissions(io, .fromMode(0o555));
    defer etc_handle.setPermissions(io, .fromMode(0o755)) catch {};

    const activation_result = activateSystemGeneration(&test_env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, activation_result.outcome);
    try std.testing.expectEqual(ActivationError.PermissionDenied, activation_result.failure.?);

    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));

    std.Io.Dir.accessAbsolute(io, created_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
    std.Io.Dir.accessAbsolute(io, new_file, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    };
}

test "system profile activation rejects mismatched content hash without verify-store flag" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    // Gen 1: empty, just to have a current generation
    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen1_path);
        dir.close(io);
    }
    var manifest1 = generation.GenerationManifest.init(allocator, 1);
    defer manifest1.deinit();
    try generation.writeManifest(&test_env.ctx, gen1_path, &manifest1);
    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Gen 2: references a store path with a WRONG content hash
    const gen2_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2" });
    defer allocator.free(gen2_path);
    {
        var dir = try path_mod.makePathAndOpenDir(gen2_path);
        dir.close(io);
    }

    const fake_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const store_path = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "store", fake_hash ++ "-badpkg-1.0.0" });
    defer allocator.free(store_path);
    {
        var dir = try path_mod.makePathAndOpenDir(store_path);
        dir.close(io);
    }
    // Put a file in so the real hash differs from fake_hash
    const file_path = try std.fs.path.join(allocator, &.{ store_path, "data.txt" });
    defer allocator.free(file_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "this content does not match the hash\n");
    }

    var manifest2 = generation.GenerationManifest.init(allocator, 2);
    defer manifest2.deinit();
    try manifest2.addPackage("badpkg", "1.0.0", 1, "x86_64", store_path, fake_hash);
    try generation.writeManifest(&test_env.ctx, gen2_path, &manifest2);

    // Activate with .fast (no explicit verify-store) — should STILL fail
    // because system profile hash verification is now mandatory
    const activation_result = activateSystemGeneration(&test_env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, activation_result.outcome);
    try std.testing.expectEqual(ActivationError.CorruptData, activation_result.failure.?);

    // Should not have switched
    try std.testing.expectEqual(@as(?u32, 1), try generation.getCurrentGeneration(profile_dir));
}

// A damaged current generation must not block activation when the service
// policy cannot apply (alternate root or non-dinit provider). Rolling away from
// a damaged generation is the case where activation matters most.
test "system activation does not read the current generation when service policy cannot apply" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const io = path_mod.currentIo();

    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    {
        var dir = try path_mod.makePathAndOpenDir(profile_dir);
        dir.close(io);
    }

    var gens: [2][]const u8 = undefined;
    for (&gens, 1..) |*slot, n| {
        const name = try std.fmt.allocPrint(allocator, "gen-{d}", .{n});
        defer allocator.free(name);
        slot.* = try std.fs.path.join(allocator, &.{ profile_dir, name });
        var dir = try path_mod.makePathAndOpenDir(slot.*);
        dir.close(io);
        var manifest = generation.GenerationManifest.init(allocator, @intCast(n));
        defer manifest.deinit();
        try generation.writeManifest(&test_env.ctx, slot.*, &manifest);
    }
    defer for (gens) |g| allocator.free(g);

    _ = switchProfileGeneration(&test_env.ctx, "system", 1, .fast);

    // Damage the generation that is currently active.
    const damaged = try std.fs.path.join(allocator, &.{ gens[0], generation.MANIFEST_FILENAME });
    defer allocator.free(damaged);
    {
        var file = try std.Io.Dir.createFileAbsolute(io, damaged, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "this is not a valid profile {{{\n");
    }

    // The test root is not the host root, so the policy does not apply and the
    // damaged current generation must not be consulted.
    _ = activateSystemGeneration(&test_env.ctx, 2, .fast);
    try std.testing.expectEqual(@as(?u32, 2), try generation.getCurrentGeneration(profile_dir));
}

test "service tree failures keep their failure class" {
    try std.testing.expectEqual(ActivationError.PermissionDenied, mapReconcileError(error.PermissionDenied));
    try std.testing.expectEqual(ActivationError.FileSystem, mapReconcileError(error.FileSystem));
    try std.testing.expectEqual(ActivationError.OutOfMemory, mapReconcileError(error.OutOfMemory));
    try std.testing.expectEqual(ActivationError.InvalidInput, mapReconcileError(error.InvalidInput));
    try std.testing.expectEqual(ActivationError.InvalidInput, mapReconcileError(error.DuplicateService));
}

// ── Rollback and live-service policy at the activation boundary ───────────

/// Test fixture shared with the install tests. It is never referenced outside
/// tests, so it is not compiled into the binary.
pub const PolicyHost = struct {
    var host_root: bool = true;
    var live: bool = true;
    pub var list_text: []const u8 = "";
    pub var status_text: []const u8 = "    State: started\n";
    var list_calls: usize = 0;

    fn isHostRoot(_: []const u8) anyerror!bool {
        return host_root;
    }
    fn isLive(_: std.mem.Allocator) anyerror!bool {
        return live;
    }
    fn listServices(allocator: std.mem.Allocator) anyerror![]const u8 {
        list_calls += 1;
        return allocator.dupe(u8, list_text);
    }
    fn serviceStatus(allocator: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        return allocator.dupe(u8, status_text);
    }

    fn install() void {
        host_root = true;
        live = true;
        list_text = "";
        status_text = "    State: started\n";
        list_calls = 0;
        service_policy.setProbeForTest(.{
            .is_host_root = isHostRoot,
            .is_live_dinit = isLive,
            .list_services = listServices,
            .service_status = serviceStatus,
        });
    }
};

/// A two-generation system profile: generation 1 carries `before`, generation 2
/// carries `after`, and generation 1 is current. Each package declares one
/// daemon service named after itself and lives in the store with its real hash.
pub const RollbackFixture = struct {
    env: *@import("test_helpers.zig").TestEnv,
    arena: std.heap.ArenaAllocator,
    profile_dir: []const u8,
    services_dir: []const u8,

    pub fn init(before: []const []const u8, after: []const []const u8) !RollbackFixture {
        const th = @import("test_helpers.zig");
        const env = try th.createTestEnv();
        var fx: RollbackFixture = .{
            .env = env,
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .profile_dir = "",
            .services_dir = "",
        };
        errdefer fx.deinit();
        const a = fx.arena.allocator();
        var cfg = mere.config.Config.init(&env.ctx, env.ctx.allocator);
        cfg.init_provider = .dinit;
        env.ctx.configuration = cfg;

        fx.profile_dir = try std.fs.path.join(a, &.{ env.path, "mere", "profiles", "system" });
        fx.services_dir = try std.fs.path.join(a, &.{ env.path, "usr", "share", "dinit.d" });
        const store_root = try std.fs.path.join(a, &.{ env.path, "mere", "store" });
        try path_mod.ensureDirExists(fx.profile_dir);
        try path_mod.ensureDirExists(store_root);

        try fx.makeGeneration(a, store_root, 1, before);
        try fx.makeGeneration(a, store_root, 2, after);
        _ = switchProfileGeneration(&env.ctx, "system", 1, .fast);
        PolicyHost.install();
        return fx;
    }

    fn makeGeneration(self: *RollbackFixture, a: std.mem.Allocator, store_root: []const u8, number: u32, services: []const []const u8) !void {
        const env = self.env;
        const gen_name = try std.fmt.allocPrint(a, "gen-{d}", .{number});
        const gen_dir = try std.fs.path.join(a, &.{ self.profile_dir, gen_name });
        try path_mod.ensureDirExists(gen_dir);
        var manifest = generation.GenerationManifest.init(env.ctx.allocator, number);
        defer manifest.deinit();
        for (services) |service_name| {
            const staging = try std.fs.path.join(a, &.{ store_root, try std.fmt.allocPrint(a, "tmp-{s}-{d}", .{ service_name, number }) });
            try path_mod.ensureDirExists(staging);
            var data = meta.Data.init(env.ctx.allocator);
            defer data.deinit();
            var service = meta.Service.init(env.ctx.allocator);
            service.name = try env.ctx.allocator.dupe(u8, service_name);
            service.service_type = .daemon;
            try service.command.append(env.ctx.allocator, try env.ctx.allocator.dupe(u8, "/bin/true"));
            try data.services.append(env.ctx.allocator, service);
            try meta.writeFile(env.ctx.allocator, staging, &data);
            const digest = try hash.calculateStoreContentHash(env.ctx.allocator, staging, null);
            defer env.ctx.allocator.free(digest);
            const final = try std.fs.path.join(a, &.{ store_root, try std.fmt.allocPrint(a, "{s}-{s}-1.0", .{ digest, service_name }) });
            // The same package in two generations has one store path.
            if (std.Io.Dir.accessAbsolute(path_mod.currentIo(), final, .{})) |_| {
                try path_mod.deleteTreeAbsolute(staging);
            } else |_| {
                try std.Io.Dir.renameAbsolute(staging, final, path_mod.currentIo());
            }
            try manifest.addPackage(service_name, "1.0", 1, "x86_64", final, digest);
        }
        try generation.writeManifest(&env.ctx, gen_dir, &manifest);
        // A child generation reads its parent's realization, so a fixture
        // generation needs one. It owns no files.
        var realization = generation.RealizationData.init(env.ctx.allocator);
        defer realization.deinit();
        try realization.canonicalize();
        try generation.writeRealization(&env.ctx, gen_dir, &realization);
    }

    pub fn deinit(self: *RollbackFixture) void {
        service_policy.setProbeForTest(null);
        self.arena.deinit();
        self.env.cleanup();
        std.testing.allocator.destroy(self.env);
    }

    pub fn current(self: *RollbackFixture) !?u32 {
        return generation.getCurrentGeneration(self.profile_dir);
    }
};

test "crash-boundary child activates a shared root" {
    const child = std.c.getenv("MERE_CRASH_CHILD") orelse return;
    _ = child;
    const root = std.c.getenv("MERE_CRASH_ROOT") orelse return;
    fault_injection.configureFromEnvironment();
    var ctx = mere.Context.init(std.heap.page_allocator, std.mem.span(root));
    defer ctx.deinit();
    _ = activateSystemGeneration(&ctx, 2, .fast);
}

fn runCrashBoundaryChild(allocator: std.mem.Allocator, root: []const u8, checkpoint: []const u8) !u8 {
    const executable = try std.process.executablePathAlloc(path_mod.currentIo(), allocator);
    defer allocator.free(executable);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("MERE_CRASH_CHILD", "1");
    try env_map.put("MERE_CRASH_ROOT", root);
    try env_map.put("MERE_FAULT_CHECKPOINT", checkpoint);
    try env_map.put("MERE_FAULT_ACTION", "terminate");

    const result = try std.process.run(allocator, path_mod.currentIo(), .{
        .argv = &.{executable},
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| blk: {
            if (code != 86) std.debug.print("crash child exited {d}: {s}{s}", .{ code, result.stdout, result.stderr });
            break :blk code;
        },
        else => |term| blk: {
            std.debug.print("crash child terminated: {any}: {s}{s}", .{ term, result.stdout, result.stderr });
            break :blk 255;
        },
    };
}

test "subprocess termination at recoverable activation boundaries is repairable after restart" {
    if (std.c.getenv("MERE_CRASH_CHILD") != null) return;
    // `/etc` and boot staging are preparation mutations. Their durable
    // rollback journal belongs to #102; this subprocess test covers the
    // pointer and post-commit boundaries whose restart repair contract exists
    // in this change. The preparation checkpoints still have fail-mode
    // coverage through the normal activation rollback path.
    const Case = struct { checkpoint: []const u8, current: ?u32 };
    const cases = [_]Case{
        .{ .checkpoint = "current_before_replace", .current = 1 },
        .{ .checkpoint = "current_after_replace", .current = 2 },
        .{ .checkpoint = "gc_roots_before_update", .current = 2 },
        .{ .checkpoint = "gc_roots_after_update", .current = 2 },
    };
    for (cases) |case| {
        var fx = try RollbackFixture.init(&.{}, &.{});
        defer fx.deinit();
        const code = try runCrashBoundaryChild(fx.env.ctx.allocator, fx.env.path, case.checkpoint);
        try std.testing.expectEqual(@as(u8, 86), code);
        try std.testing.expectEqual(case.current, try fx.current());

        try repairSystemGeneration(&fx.env.ctx, .fast);
        try std.testing.expectEqual(case.current, try fx.current());
    }
}

test "in-process checkpoint after current preserves the committed outcome" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();
    defer fault_injection.clearForTest();

    fault_injection.setForTest(.current_after_replace, .fail);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    fault_injection.clearForTest();
    try repairSystemGeneration(&fx.env.ctx, .fast);
}

test "activation pointer fsync failure commits and repair retries its durability" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();

    publish.failNextDirectorySyncForTest();
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    publish.failNextDirectorySyncForTest();
    try std.testing.expectError(ActivationError.FileSystem, repairSystemGeneration(&fx.env.ctx, .fast));
    try repairSystemGeneration(&fx.env.ctx, .fast);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());
}

test "activation profile switch pointer fsync failure preserves commit status" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();

    publish.failNextDirectorySyncForTest();
    const result = switchProfileGeneration(&fx.env.ctx, "system", 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());
    try repairSystemGeneration(&fx.env.ctx, .fast);
}

test "in-process GC-root checkpoint preserves the committed outcome" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();
    defer fault_injection.clearForTest();

    fault_injection.setForTest(.gc_roots_before_update, .fail);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    fault_injection.clearForTest();
    try repairSystemGeneration(&fx.env.ctx, .fast);
}

test "etc checkpoint failure rolls back files copied before the pointer switch" {
    var fx = try RollbackFixture.init(&.{}, &.{"etc-test"});
    defer fx.deinit();
    defer fault_injection.clearForTest();

    const allocator = fx.env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ fx.env.path, "mere", "store" });
    defer allocator.free(store_root);
    const target_path = try generation.getGenerationPath(allocator, fx.profile_dir, 2);
    defer allocator.free(target_path);
    var manifest = try generation.readManifest(allocator, store_root, target_path);
    defer manifest.deinit();
    const package_path = manifest.packages.items[0].store_path;
    const template_dir = try std.fs.path.join(allocator, &.{ package_path, "etc-defaults", "restart-test" });
    defer allocator.free(template_dir);
    try path_mod.ensureDirExists(template_dir);
    const template_path = try std.fs.path.join(allocator, &.{ template_dir, "config" });
    defer allocator.free(template_path);
    var template = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), template_path, .{});
    try template.writeStreamingAll(path_mod.currentIo(), "target\n");
    template.close(path_mod.currentIo());

    const content_hash = try hash.calculateStoreContentHash(allocator, package_path, null);
    defer allocator.free(content_hash);
    allocator.free(manifest.packages.items[0].content_hash);
    manifest.packages.items[0].content_hash = try allocator.dupe(u8, content_hash);
    try generation.writeManifest(&fx.env.ctx, target_path, &manifest);

    fault_injection.setForTest(.etc_after_changes, .fail);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 1), try fx.current());

    const copied_path = try std.fs.path.join(allocator, &.{ fx.env.path, "etc", "restart-test", "config" });
    defer allocator.free(copied_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), copied_path, .{}));
}

test "boot checkpoint failure rolls back staged artifacts before the pointer switch" {
    var fx = try RollbackFixture.init(&.{}, &.{"linux"});
    defer fx.deinit();
    defer fault_injection.clearForTest();

    const allocator = fx.env.ctx.allocator;
    const store_root = try std.fs.path.join(allocator, &.{ fx.env.path, "mere", "store" });
    defer allocator.free(store_root);
    const target_path = try generation.getGenerationPath(allocator, fx.profile_dir, 2);
    defer allocator.free(target_path);
    var manifest = try generation.readManifest(allocator, store_root, target_path);
    defer manifest.deinit();
    const package_path = manifest.packages.items[0].store_path;
    const boot_source = try std.fs.path.join(allocator, &.{ package_path, "boot" });
    defer allocator.free(boot_source);
    try path_mod.ensureDirExists(boot_source);
    for ([_][]const u8{ "vmlinux", "config" }) |name| {
        const source = try std.fs.path.join(allocator, &.{ boot_source, name });
        defer allocator.free(source);
        var file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), source, .{});
        try file.writeStreamingAll(path_mod.currentIo(), name);
        file.close(path_mod.currentIo());
    }

    const content_hash = try hash.calculateStoreContentHash(allocator, package_path, null);
    defer allocator.free(content_hash);
    allocator.free(manifest.packages.items[0].content_hash);
    manifest.packages.items[0].content_hash = try allocator.dupe(u8, content_hash);
    try generation.writeManifest(&fx.env.ctx, target_path, &manifest);

    fault_injection.setForTest(.boot_after_staging, .fail);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 1), try fx.current());

    const hash_prefix = content_hash[0..16];
    for ([_][]const u8{ "vmlinux", "config" }) |name| {
        const staged_name = try std.fmt.allocPrint(allocator, "{s}-1.0-{s}", .{ name, hash_prefix });
        defer allocator.free(staged_name);
        const staged_path = try std.fs.path.join(allocator, &.{ fx.env.path, "boot", staged_name });
        defer allocator.free(staged_path);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), staged_path, .{}));
    }
}

test "activation failure before the pointer switch is explicitly uncommitted" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();
    defer setFailurePointForTest(null);

    setFailurePointForTest(.before_pointer_switch);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 1), try fx.current());
}

test "profile switch reports committed GC-root repair separately" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();
    defer setFailurePointForTest(null);

    setFailurePointForTest(.gc_root_update);
    const result = switchProfileGeneration(&fx.env.ctx, "system", 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    setFailurePointForTest(null);
    try repairSystemGeneration(&fx.env.ctx, .fast);
}

test "GC-root failure after commit leaves the new generation active" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();
    defer setFailurePointForTest(null);

    setFailurePointForTest(.gc_root_update);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    setFailurePointForTest(null);
    try repairSystemGeneration(&fx.env.ctx, .fast);
}

test "activation failure after the pointer switch is repairable and idempotent" {
    var fx = try RollbackFixture.init(&.{}, &.{});
    defer fx.deinit();
    defer setFailurePointForTest(null);

    setFailurePointForTest(.after_pointer_switch);
    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed_needs_repair, result.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    setFailurePointForTest(null);
    try repairSystemGeneration(&fx.env.ctx, .fast);
    try repairSystemGeneration(&fx.env.ctx, .fast);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());

    const gc_current = try std.fs.path.join(fx.arena.allocator(), &.{
        fx.env.path,
        "mere",
        "gc-roots",
        "profiles",
        "system",
        "current",
    });
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), gc_current, .{});
}

test "rollback to a generation without a running service is refused and leaves the profile unchanged" {
    var fx = try RollbackFixture.init(&.{"worker"}, &.{});
    defer fx.deinit();
    PolicyHost.list_text = "[[+]     ] worker (pid: 7)\n";
    PolicyHost.status_text = "    State: started\n";

    const result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, result.outcome);
    try std.testing.expectEqual(ActivationError.InvalidInput, result.failure.?);
    try std.testing.expectEqual(@as(?u32, 1), try fx.current());
    // Refusal comes before the service tree is rewritten.
    const published = try std.fs.path.join(fx.arena.allocator(), &.{ fx.profile_dir, "gen-2", "usr", "share", "dinit.d" });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), published, .{}));
}

test "rollback to a generation without a stopped service is allowed" {
    var fx = try RollbackFixture.init(&.{"worker"}, &.{});
    defer fx.deinit();
    PolicyHost.list_text = "[{ }     ] worker\n";
    PolicyHost.status_text = "    State: stopped\n";

    const activation_result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed, activation_result.outcome);
    try std.testing.expectEqual(@as(?ActivationError, null), activation_result.failure);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());
}

test "activation that removes no service succeeds even when live state cannot be read" {
    var fx = try RollbackFixture.init(&.{"worker"}, &.{"worker"});
    defer fx.deinit();
    PolicyHost.live = false;
    PolicyHost.list_text = "unreadable\n";

    const activation_result = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed, activation_result.outcome);
    try std.testing.expectEqual(@as(?ActivationError, null), activation_result.failure);
    try std.testing.expectEqual(@as(?u32, 2), try fx.current());
    try std.testing.expectEqual(@as(usize, 0), PolicyHost.list_calls);
}

test "dinit backup repair preserves the backup when the replacement tree is absent" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const generation_root = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system", "gen-1" });
    defer allocator.free(generation_root);
    const service_root = try std.fs.path.join(allocator, &.{ generation_root, "usr", "share", "dinit.d" });
    defer allocator.free(service_root);
    const backup_root = try std.fmt.allocPrint(allocator, "{s}.mere-old", .{service_root});
    defer allocator.free(backup_root);
    try path_mod.ensureDirExists(backup_root);

    try std.testing.expectError(
        service_reconcile.ReconcileError.FileSystem,
        service_reconcile.finalizeDinitBackup(allocator, generation_root),
    );
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), backup_root, .{});
}

test "activation realizes the target generation's service tree and its essential bundle" {
    var fx = try RollbackFixture.init(&.{}, &.{"worker"});
    defer fx.deinit();
    defer setFailurePointForTest(null);
    PolicyHost.live = false;

    const first = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.committed, first.outcome);
    const tree = try std.fs.path.join(fx.arena.allocator(), &.{ fx.profile_dir, "gen-2", "usr", "share", "dinit.d" });
    const worker = try std.fs.path.join(fx.arena.allocator(), &.{ tree, "worker" });
    const bundle = try std.fs.path.join(fx.arena.allocator(), &.{ tree, "mere-essential" });
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), worker, .{});
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), bundle, .{});

    // Repair also removes a retained backup from a previous successful
    // pointer commit whose cleanup failed.
    const retained_backup = try std.fmt.allocPrint(fx.arena.allocator(), "{s}.mere-old", .{tree});
    try path_mod.ensureDirExists(retained_backup);
    try repairSystemGeneration(&fx.env.ctx, .fast);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(path_mod.currentIo(), retained_backup, .{}));

    // Re-activating an already-current generation must restore its service
    // tree if preparation fails after dinit publication.
    setFailurePointForTest(.before_pointer_switch);
    const retry = activateSystemGeneration(&fx.env.ctx, 2, .fast);
    try std.testing.expectEqual(ActivationOutcome.not_committed, retry.outcome);
    try std.testing.expectEqual(ActivationError.FileSystem, retry.failure.?);
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), worker, .{});
    try std.Io.Dir.accessAbsolute(path_mod.currentIo(), bundle, .{});
}
