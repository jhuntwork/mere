// Single test root that imports all modules.
// This ensures each test runs exactly once, avoiding duplicate test runs
// from transitive imports.

test {
    _ = @import("activation.zig");
    _ = @import("archive.zig");
    _ = @import("build_orchestrator/artifact_model.zig");
    _ = @import("build_cache.zig");
    _ = @import("build_orchestrator/cache_solver.zig");
    _ = @import("package_staging.zig");
    _ = @import("build_orchestrator/environment.zig");
    _ = @import("build_orchestrator.zig");
    _ = @import("config.zig");
    _ = @import("download.zig");
    _ = @import("dev_cleanup.zig");
    _ = @import("dev_publish.zig");
    _ = @import("elf.zig");
    _ = @import("errors.zig");
    _ = @import("etc.zig");
    _ = @import("extract.zig");
    _ = @import("filetype.zig");
    _ = @import("gc.zig");
    _ = @import("generation.zig");
    _ = @import("gcroots.zig");
    _ = @import("hash.zig");
    _ = @import("import.zig");
    _ = @import("init.zig");
    _ = @import("install.zig");
    _ = @import("kdl.zig");
    _ = @import("manifest.zig");
    _ = @import("mere.zig");
    _ = @import("meta.zig");
    _ = @import("namespace.zig");
    _ = @import("package.zig");
    _ = @import("packaging.zig");
    _ = @import("path.zig");
    _ = @import("pin.zig");
    _ = @import("projection_index.zig");
    _ = @import("publish.zig");
    _ = @import("profile.zig");
    _ = @import("requested.zig");
    _ = @import("recipe.zig");
    _ = @import("repodb.zig");
    _ = @import("repo_history.zig");
    _ = @import("repo_sources.zig");
    _ = @import("repocache.zig");
    _ = @import("repository.zig");
    _ = @import("resolver.zig");
    _ = @import("sign.zig");
    _ = @import("sign_crypto.zig");
    _ = @import("sign_io.zig");
    _ = @import("source_manager.zig");
    _ = @import("source_unpacker.zig");
    _ = @import("store.zig");
    _ = @import("strip.zig");
    _ = @import("path_safety.zig");
    _ = @import("verify.zig");
    _ = @import("version.zig");
    _ = @import("workspace_manager.zig");
    _ = @import("zstd_c.zig");
    _ = @import("ui/events.zig");
    _ = @import("ui/emitter.zig");
    _ = @import("ui/render_default.zig");
    _ = @import("ui/render_progress.zig");
}
