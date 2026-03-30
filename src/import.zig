const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const repository = @import("repository.zig");
const Repository = repository.Repository;
const extract = @import("extract.zig");
const filetype = @import("filetype.zig");
const p = @import("path.zig");
const package = @import("package.zig");
const hash = @import("hash.zig");
const sign = @import("sign.zig");
const manifest = @import("manifest.zig");
const meta = @import("meta.zig");
const projection_index = @import("projection_index.zig");
const repodb = @import("repodb.zig");
const repo_history = @import("repo_history.zig");
const errors = @import("errors.zig");
const c = repodb.c;

const ResolveResult = struct {
    final_path: []const u8,
    allocated: ?[]const u8,
};

fn resolvePackagePath(ctx: *Context, file_path: []const u8) !ResolveResult {
    if (!p.isValidInputPath(file_path)) {
        return ImportError.InvalidInput;
    }
    if (std.fs.path.isAbsolute(file_path)) {
        return ResolveResult{ .final_path = file_path, .allocated = null };
    }
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try p.resolveToAbsolutePath(file_path, &abs_buf);
    const abs = try ctx.allocator.dupe(u8, resolved);
    return ResolveResult{ .final_path = abs, .allocated = abs };
}

const RepoSourceResult = struct {
    dir_path: []const u8,
    allocated: bool,
};

/// Returns true if the input looks like a filesystem path (absolute, relative
/// with ./ or ../, or contains a path separator).
fn looksLikePath(input: []const u8) bool {
    if (input.len == 0) return false;
    if (input[0] == '/') return true;
    if (std.mem.startsWith(u8, input, "./") or std.mem.startsWith(u8, input, "../")) return true;
    return false;
}

fn resolveRepoSource(ctx: *Context, repo_name_or_path: []const u8) !RepoSourceResult {
    ctx.debug("resolveRepoSource: input={s}", .{repo_name_or_path});

    if (looksLikePath(repo_name_or_path)) {
        // Treat as a direct repo directory path
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = p.resolveToAbsolutePath(repo_name_or_path, &abs_buf) catch {
            return ctx.fail(ImportError.InvalidInput, repo_name_or_path, "failed to resolve repo path");
        };
        const dir_path = ctx.allocator.dupe(u8, abs_path) catch {
            return ImportError.OutOfMemory;
        };
        return RepoSourceResult{ .dir_path = dir_path, .allocated = true };
    }

    // Legacy: treat as a repo name under /mere/dev/repo/<name>
    const repo_path = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo", repo_name_or_path }) catch {
        return ctx.fail(ImportError.OutOfMemory, repo_name_or_path, "failed to construct repo path");
    };
    ctx.debug("resolveRepoSource: repo_path={s}", .{repo_path});

    if (p.openExistingDir(repo_path)) |dir| {
        var d = dir;
        d.close(p.currentIo());
        return RepoSourceResult{ .dir_path = repo_path, .allocated = true };
    } else |_| {
        ctx.allocator.free(repo_path);
    }

    return ImportError.PackageNotFound; // Repo not found
}

fn getBootstrapPath(ctx: *Context, repo_name_or_path: []const u8) ![]const u8 {
    ctx.debug("getBootstrapPath: input={s}", .{repo_name_or_path});

    if (looksLikePath(repo_name_or_path)) {
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = p.resolveToAbsolutePath(repo_name_or_path, &abs_buf) catch {
            return ctx.fail(ImportError.InvalidInput, repo_name_or_path, "failed to resolve bootstrap path");
        };
        return ctx.allocator.dupe(u8, abs_path) catch ImportError.OutOfMemory;
    }

    const bp = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo", repo_name_or_path }) catch {
        return ctx.fail(ImportError.OutOfMemory, repo_name_or_path, "failed to construct bootstrap path");
    };
    ctx.debug("getBootstrapPath: bootstrap_path={s}", .{bp});
    return bp;
}

fn bootstrapRepoSource(ctx: *Context, repo_path: []const u8) !void {
    // Determine if this is a path-based repo (flat layout) or a legacy
    // dev repo name (state slot layout under /mere/dev/repo/).
    const dev_repo_prefix = std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo" }) catch {
        return ImportError.OutOfMemory;
    };
    defer ctx.allocator.free(dev_repo_prefix);

    const is_dev_repo = std.mem.startsWith(u8, repo_path, dev_repo_prefix) and
        repo_path.len > dev_repo_prefix.len and repo_path[dev_repo_prefix.len] == '/';

    if (is_dev_repo) {
        // Legacy dev repo: use state slot layout (current/previous)
        repository.setupStateLayout(ctx.allocator, repo_path) catch {
            return ctx.fail(ImportError.FileSystem, repo_path, "failed to create repo state layout");
        };
    } else {
        // Path-based repo: flat layout (repo.db + packages/ at root)
        p.ensureDirExists(repo_path) catch {
            return ctx.fail(ImportError.FileSystem, repo_path, "failed to create repo directory");
        };
        const packages_dir = std.fs.path.join(ctx.allocator, &.{ repo_path, "packages" }) catch {
            return ImportError.OutOfMemory;
        };
        defer ctx.allocator.free(packages_dir);
        p.ensureDirExists(packages_dir) catch {
            return ctx.fail(ImportError.FileSystem, packages_dir, "failed to create repo packages directory");
        };
    }

    var repo = Repository.init(ctx, repo_path, false) catch {
        const diag = ctx.getDiagnosticContext();
        if (diag.details == null) {
            ctx.setDiagnosticContext(repo_path, "failed to initialize repository");
        }
        if (std.fs.path.dirname(repo_path)) |parent_path| {
            if (p.openExistingDir(parent_path) catch null) |parent_dir| {
                var dir = parent_dir;
                defer dir.close(p.currentIo());
                dir.deleteTree(p.currentIo(), std.fs.path.basename(repo_path)) catch {};
            }
        }
        return ImportError.FileSystem;
    };
    repo.deinit();

    ctx.debug("bootstrapped new repository at {s}", .{repo_path});
}

const ExtractResult = struct {
    temp_dir: []const u8,
    temp: p.TempDir,
};

fn extractArchiveToTemp(ctx: *Context, archive_path: []const u8) !ExtractResult {
    var temp_dir_result = p.createTempDir("mere_import") catch {
        return ctx.fail(ImportError.FileSystem, archive_path, "failed to create temp dir");
    };

    const temp_dir = try std.fmt.allocPrint(ctx.allocator, "/tmp/{s}", .{temp_dir_result.sub_path});

    extract.into(ctx, archive_path, temp_dir) catch {
        const diag = ctx.getDiagnosticContext();
        if (diag.details == null) {
            ctx.setDiagnosticContext(archive_path, "failed to extract package");
        }
        ctx.allocator.free(temp_dir);
        temp_dir_result.cleanup();
        return ImportError.PackageExtractFailed;
    };

    return ExtractResult{ .temp_dir = temp_dir, .temp = temp_dir_result };
}

fn verifyManifestSignatureAndGetSigner(
    ctx: *Context,
    temp_dir: []const u8,
    trusted_fingerprints: []const []const u8,
    loaded_keys: []const sign.LoadedKey,
) ![]const u8 {
    const manifest_path = std.fs.path.join(ctx.allocator, &.{ temp_dir, manifest.MANIFEST_FILENAME }) catch {
        return ctx.fail(ImportError.OutOfMemory, temp_dir, "failed to construct manifest path");
    };
    defer ctx.allocator.free(manifest_path);

    const sig_path = std.fs.path.join(ctx.allocator, &.{ temp_dir, manifest.MANIFEST_SIG_FILENAME }) catch {
        return ctx.fail(ImportError.OutOfMemory, temp_dir, "failed to construct manifest sig path");
    };
    defer ctx.allocator.free(sig_path);

    const result = sign.verifyManifestWithTrustedFingerprints(ctx, manifest_path, sig_path, trusted_fingerprints, loaded_keys) catch |err| {
        ctx.debug("manifest signature verification failed: {}", .{err});
        ctx.setDiagnosticContextFmt(manifest_path, "manifest signature verification failed ({d} trusted key{s} tried)", .{
            trusted_fingerprints.len,
            if (trusted_fingerprints.len == 1) "" else "s",
        });
        return ImportError.SignatureInvalid;
    };

    ctx.debug("manifest signature verified successfully by key: {s}", .{result.verifying_fingerprint});
    return result.verifying_fingerprint;
}

const ManifestResult = struct {
    manifest_data: []const u8,
    pkg_manifest: manifest.PackageManifestV1,
    pkg: package.Package,
};

const PreparedImport = struct {
    extract: ExtractResult,
    manifest: ManifestResult,

    pub fn deinit(self: *PreparedImport, allocator: std.mem.Allocator) void {
        self.manifest.pkg.deinit();
        allocator.free(self.manifest.manifest_data);
        allocator.free(self.extract.temp_dir);
        self.extract.temp.cleanup();
    }
};

fn readManifestAndCreatePackage(ctx: *Context, temp_dir: []const u8) !ManifestResult {
    const manifest_path = std.fs.path.join(ctx.allocator, &.{ temp_dir, manifest.MANIFEST_FILENAME }) catch {
        return ctx.fail(ImportError.OutOfMemory, temp_dir, "failed to construct manifest path");
    };
    defer ctx.allocator.free(manifest_path);

    const io = p.currentIo();
    var manifest_file = p.openExistingFile(manifest_path) catch |err| {
        if (err == error.FileNotFound) {
            // Missing manifest means the package is invalid / not found as far as import
            return ImportError.PackageNotFound;
        }
        return ctx.fail(ImportError.FileSystem, manifest_path, "failed to open manifest");
    };
    defer manifest_file.close(io);

    const stat = manifest_file.stat(io) catch {
        return ctx.fail(ImportError.FileSystem, manifest_path, "failed to stat manifest");
    };

    if (stat.size > 1024 * 1024) {
        // Manifest should never be > 1MB
        return ctx.fail(ImportError.InvalidInput, manifest_path, "manifest exceeds size limit");
    }

    const manifest_data = ctx.allocator.alloc(u8, @intCast(stat.size)) catch {
        return ctx.fail(ImportError.OutOfMemory, manifest_path, "out of memory allocating manifest buffer");
    };
    errdefer ctx.allocator.free(manifest_data);

    const bytes_read = manifest_file.readPositionalAll(io, manifest_data, 0) catch {
        return ctx.fail(ImportError.FileSystem, manifest_path, "failed to read manifest");
    };

    if (bytes_read != stat.size) {
        return ctx.fail(ImportError.FileSystem, manifest_path, "short read while reading manifest");
    }

    // Decode the manifest
    const pkg_manifest = manifest.PackageManifestV1.decode(manifest_data) catch {
        return ctx.fail(ImportError.InvalidInput, manifest_path, "failed to decode manifest");
    };

    // Create a Package from the manifest
    var pkg = package.Package.init(ctx);
    errdefer pkg.deinit();

    pkg.name = ctx.allocator.dupe(u8, pkg_manifest.name) catch {
        return ctx.fail(ImportError.OutOfMemory, manifest_path, "out of memory allocating package name");
    };
    pkg.version = ctx.allocator.dupe(u8, pkg_manifest.version) catch {
        return ctx.fail(ImportError.OutOfMemory, manifest_path, "out of memory allocating package version");
    };
    pkg.arch = ctx.allocator.dupe(u8, pkg_manifest.arch) catch {
        return ctx.fail(ImportError.OutOfMemory, manifest_path, "out of memory allocating package arch");
    };
    pkg.release = pkg_manifest.release;

    // Format content_hash as hex string
    pkg.content_hash = pkg_manifest.contentHashHex(ctx.allocator) catch {
        return ctx.fail(ImportError.OutOfMemory, manifest_path, "failed to format content hash (allocation)");
    };

    return ManifestResult{ .manifest_data = manifest_data, .pkg_manifest = pkg_manifest, .pkg = pkg };
}

fn readMetaAndPopulatePackage(ctx: *Context, temp_dir: []const u8, pkg: *package.Package) !void {
    var pkg_meta = meta.readFile(ctx.allocator, temp_dir) catch |err| {
        switch (err) {
            meta.MetaError.OutOfMemory => {
                return ctx.fail(ImportError.OutOfMemory, temp_dir, "out of memory reading meta.kdl");
            },
            meta.MetaError.ParseError => {
                return ctx.fail(ImportError.InvalidInput, temp_dir, "failed to parse meta.kdl");
            },
            meta.MetaError.FileSystem => {
                ctx.debug("no meta.kdl found, package has no recorded dependencies", .{});
                return;
            },
            else => {
                return ctx.fail(ImportError.InvalidInput, temp_dir, "failed to read meta.kdl");
            },
        }
    };
    defer pkg_meta.deinit();

    for (pkg_meta.dependencies.items) |dep| {
        const dep_type: package.DependencyType = switch (dep.dep_type) {
            .elf_needed => .elf_needed,
            .elf_interpreter => .elf_interpreter,
            .script_interpreter => .script_interpreter,
            .split_runtime => .split_runtime,
        };

        pkg.addDependencyWithConstraint(dep.value, dep_type, dep.version_constraint) catch {
            return ImportError.OutOfMemory;
        };
    }

    for (pkg_meta.provisions.items) |prov| {
        const prov_type: package.ProvisionType = switch (prov.prov_type) {
            .elf_soname => .elf_soname,
            .bin => .bin,
        };

        pkg.addProvision(prov.value, prov_type) catch {
            return ImportError.OutOfMemory;
        };
    }

    ctx.debug("loaded {d} dependencies and {d} provisions from meta.kdl", .{
        pkg_meta.dependencies.items.len,
        pkg_meta.provisions.items.len,
    });
}

fn computeAndVerifyContentHash(ctx: *Context, temp_dir: []const u8, pkg_manifest: *const manifest.PackageManifestV1) !void {
    const computed_hash = try hash.calculateStoreContentHash(ctx.allocator, temp_dir, null);
    defer ctx.allocator.free(computed_hash);

    const declared_hash = try pkg_manifest.contentHashHex(ctx.allocator);
    defer ctx.allocator.free(declared_hash);

    if (!std.mem.eql(u8, declared_hash, computed_hash)) {
        ctx.debug("content_hash mismatch: declared={s}, computed={s}", .{ declared_hash, computed_hash });
        return ctx.fail(ImportError.InvalidInput, temp_dir, "content_hash mismatch between manifest and computed hash");
    }
    ctx.debug("declared content_hash matches computed hash", .{});
}

fn validateProjectionIndex(ctx: *Context, temp_dir: []const u8) !void {
    var stored = projection_index.readFile(ctx.allocator, temp_dir) catch |err| {
        return switch (err) {
            projection_index.ProjectionError.OutOfMemory => ctx.fail(ImportError.OutOfMemory, temp_dir, "out of memory reading projection.v1"),
            projection_index.ProjectionError.PermissionDenied => ctx.fail(ImportError.FileSystem, temp_dir, "permission denied reading projection.v1"),
            projection_index.ProjectionError.InvalidInput => ctx.fail(ImportError.InvalidInput, temp_dir, "projection.v1 missing or invalid"),
            projection_index.ProjectionError.FileSystem => ctx.fail(ImportError.FileSystem, temp_dir, "failed to read projection.v1"),
        };
    };
    defer stored.deinit();

    projection_index.validateAgainstPayload(ctx.allocator, temp_dir, &stored) catch |err| {
        return switch (err) {
            projection_index.ProjectionError.OutOfMemory => ctx.fail(ImportError.OutOfMemory, temp_dir, "out of memory validating projection.v1"),
            projection_index.ProjectionError.PermissionDenied => ctx.fail(ImportError.FileSystem, temp_dir, "permission denied validating projection.v1"),
            projection_index.ProjectionError.InvalidInput => ctx.fail(ImportError.InvalidInput, temp_dir, "projection.v1 does not match package payload"),
            projection_index.ProjectionError.FileSystem => ctx.fail(ImportError.FileSystem, temp_dir, "failed to validate projection.v1"),
        };
    };
}

fn storeArtifactAtomically(ctx: *Context, pkg: *const package.Package, final_pkg_path: []const u8, repo_dir: []const u8) ![]const u8 {
    const packages_dir = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "packages" });
    p.ensureDirExists(packages_dir) catch {
        ctx.setDiagnosticContext(packages_dir, "failed to create repo packages dir");
        ctx.allocator.free(packages_dir);
        return ImportError.FileSystem;
    };

    const canonical_name = pkg.canonicalArchiveName() catch {
        ctx.allocator.free(packages_dir);
        return ctx.fail(ImportError.OutOfMemory, pkg.name orelse "unknown", "failed to allocate canonical package filename");
    };

    const repo_pkg_path = try std.fs.path.join(ctx.allocator, &.{ packages_dir, canonical_name });

    // The repo packages dir is content-addressed by canonical archive name.
    // If the canonical file already exists as a regular file, the artifact is already present.
    if (p.openExistingFile(repo_pkg_path)) |existing_file| {
        const io = p.currentIo();
        defer existing_file.close(io);
        const stat = existing_file.stat(io) catch {
            ctx.allocator.free(packages_dir);
            ctx.allocator.free(canonical_name);
            defer ctx.allocator.free(repo_pkg_path);
            return ctx.fail(ImportError.PackageImportFailed, repo_pkg_path, "failed to inspect package pool destination");
        };
        if (stat.kind == .file) {
            ctx.allocator.free(packages_dir);
            ctx.allocator.free(canonical_name);
            return repo_pkg_path;
        }
        ctx.allocator.free(packages_dir);
        ctx.allocator.free(canonical_name);
        defer ctx.allocator.free(repo_pkg_path);
        return ctx.fail(ImportError.PackageImportFailed, repo_pkg_path, "package pool destination is not a file");
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            ctx.allocator.free(packages_dir);
            ctx.allocator.free(canonical_name);
            defer ctx.allocator.free(repo_pkg_path);
            return ctx.fail(ImportError.PackageImportFailed, repo_pkg_path, "failed to inspect package pool destination");
        },
    }

    const io = p.currentIo();
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const repo_pkg_temp_path = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}.tmp", .{ repo_pkg_path, random_hex[0..] });

    p.copyFile(final_pkg_path, repo_pkg_temp_path) catch {
        defer ctx.allocator.free(repo_pkg_path);
        ctx.allocator.free(packages_dir);
        ctx.allocator.free(canonical_name);
        ctx.allocator.free(repo_pkg_temp_path);
        return ctx.fail(ImportError.PackageImportFailed, repo_pkg_path, "failed to copy package file to package pool");
    };

    std.Io.Dir.renameAbsolute(repo_pkg_temp_path, repo_pkg_path, io) catch |err| {
        if (std.fs.path.dirname(repo_pkg_temp_path)) |parent| {
            if (p.openExistingDir(parent) catch null) |dir_ptr| {
                var dir = dir_ptr;
                const base = std.fs.path.basename(repo_pkg_temp_path);
                dir.deleteFile(io, base) catch {};
                dir.close(io);
            }
        }
        if (err == error.PathAlreadyExists) {
            if (p.openExistingFile(repo_pkg_path)) |existing_file| {
                defer existing_file.close(io);
                const maybe_stat = existing_file.stat(io) catch null;
                if (maybe_stat) |stat| {
                    if (stat.kind == .file) {
                        ctx.allocator.free(packages_dir);
                        ctx.allocator.free(canonical_name);
                        ctx.allocator.free(repo_pkg_temp_path);
                        return repo_pkg_path;
                    }
                }
            } else |_| {}
        }
        defer ctx.allocator.free(repo_pkg_path);
        ctx.allocator.free(packages_dir);
        ctx.allocator.free(canonical_name);
        ctx.allocator.free(repo_pkg_temp_path);
        return ctx.fail(ImportError.PackageImportFailed, repo_pkg_path, "failed to atomically rename persisted package file in pool");
    };

    ctx.allocator.free(packages_dir);
    ctx.allocator.free(canonical_name);
    ctx.allocator.free(repo_pkg_temp_path);

    return repo_pkg_path;
}

fn packageTupleExists(db: *repodb.RepoDB, pkg: *const package.Package) !bool {
    const sql =
        "SELECT 1 FROM packages WHERE name = ? AND version = ? AND release = ? AND arch = ? LIMIT 1;";

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db.db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK or stmt == null) {
        return repodb.RepoDBError.CorruptData;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    _ = c.sqlite3_bind_text(stmt.?, 1, pkg.name.?.ptr, @intCast(pkg.name.?.len), null);
    _ = c.sqlite3_bind_text(stmt.?, 2, pkg.version.?.ptr, @intCast(pkg.version.?.len), null);
    _ = c.sqlite3_bind_int(stmt.?, 3, @intCast(pkg.release.?));
    _ = c.sqlite3_bind_text(stmt.?, 4, pkg.arch.?.ptr, @intCast(pkg.arch.?.len), null);

    const step = c.sqlite3_step(stmt.?);
    if (step == c.SQLITE_ROW) return true;
    if (step == c.SQLITE_DONE) return false;
    return repodb.RepoDBError.CorruptData;
}

fn attachManifestSignature(ctx: *Context, temp_dir: []const u8, pkg: *package.Package) !void {
    const sig_path = std.fs.path.join(ctx.allocator, &.{ temp_dir, manifest.MANIFEST_SIG_FILENAME }) catch {
        return ctx.fail(ImportError.OutOfMemory, temp_dir, "failed to construct signature path");
    };
    defer ctx.allocator.free(sig_path);

    const io = p.currentIo();
    var sig_file = p.openExistingFile(sig_path) catch |err| {
        if (err == error.FileNotFound) {
            ctx.debug("manifest signature file not found", .{});
            return ctx.fail(ImportError.SignatureInvalid, sig_path, "manifest signature file not found");
        }
        return ctx.fail(ImportError.FileSystem, sig_path, "failed to read manifest signature file");
    };
    defer sig_file.close(io);

    var sig_bytes: [sign.c.crypto_sign_BYTES]u8 = undefined;
    const n = sig_file.readPositionalAll(io, &sig_bytes, 0) catch {
        return ctx.fail(ImportError.FileSystem, sig_path, "failed to read manifest signature file");
    };
    if (n != sign.c.crypto_sign_BYTES) {
        return ctx.fail(ImportError.SignatureInvalid, sig_path, "manifest signature has unexpected length");
    }

    const sig_hex_array = std.fmt.bytesToHex(sig_bytes, .lower);
    const sig_hex = ctx.allocator.dupe(u8, &sig_hex_array) catch {
        return ImportError.OutOfMemory;
    };

    if (pkg.signature) |old_sig| {
        ctx.allocator.free(old_sig);
    }
    pkg.signature = sig_hex;
}

fn prepareVerifiedImport(ctx: *Context, final_pkg_path: []const u8) !PreparedImport {
    var extract_res = try extractArchiveToTemp(ctx, final_pkg_path);
    errdefer {
        ctx.allocator.free(extract_res.temp_dir);
        extract_res.temp.cleanup();
    }

    var manifest_res = try readManifestAndCreatePackage(ctx, extract_res.temp_dir);
    errdefer manifest_res.pkg.deinit();
    errdefer ctx.allocator.free(manifest_res.manifest_data);

    try readMetaAndPopulatePackage(ctx, extract_res.temp_dir, &manifest_res.pkg);

    var trusted_fingerprints = try collectTrustedFingerprintsForImport(ctx);
    defer {
        for (trusted_fingerprints.items) |fp| {
            ctx.allocator.free(fp);
        }
        trusted_fingerprints.deinit(ctx.allocator);
    }

    if (trusted_fingerprints.items.len == 0) {
        return ctx.fail(ImportError.SignatureInvalid, final_pkg_path, "no trusted keys available for manifest signature verification");
    }
    var loaded_keys = try sign.loadAllKeys(ctx);
    defer {
        for (loaded_keys.items) |*key| key.deinit(ctx.allocator);
        loaded_keys.deinit(ctx.allocator);
    }

    const signer_fingerprint = try verifyManifestSignatureAndGetSigner(ctx, extract_res.temp_dir, trusted_fingerprints.items, loaded_keys.items);
    defer ctx.allocator.free(signer_fingerprint);

    try computeAndVerifyContentHash(ctx, extract_res.temp_dir, &manifest_res.pkg_manifest);
    try validateProjectionIndex(ctx, extract_res.temp_dir);

    try attachManifestSignature(ctx, extract_res.temp_dir, &manifest_res.pkg);
    manifest_res.pkg.archive_hash = hash.calculateFileHash(ctx.allocator, final_pkg_path) catch |err| {
        return ctx.fail(err, final_pkg_path, "failed to compute package archive hash");
    };

    return .{
        .extract = extract_res,
        .manifest = manifest_res,
    };
}

fn validatePackageArchiveFormat(ctx: *Context, pkg_path: []const u8) !void {
    const io = p.currentIo();
    var file = p.openExistingFile(pkg_path) catch {
        return ctx.fail(ImportError.FileSystem, pkg_path, "failed to open package file for validation");
    };
    defer file.close(io);

    const kind = filetype.detect(&file) catch {
        return ctx.fail(ImportError.InvalidInput, pkg_path, "failed to detect package file type");
    };

    if (kind != filetype.Kind.zst and kind != filetype.Kind.tar) {
        return ctx.fail(ImportError.InvalidInput, pkg_path, "unsupported package archive format");
    }
}

fn collectTrustedFingerprintsForImport(ctx: *Context) !std.ArrayList([]const u8) {
    var trusted_fingerprints: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (trusted_fingerprints.items) |fp| {
            ctx.allocator.free(fp);
        }
        trusted_fingerprints.deinit(ctx.allocator);
    }

    if (ctx.signing_key_path) |key_path| {
        if (sign.SecretKey.loadFromFile(key_path)) |secret_key| {
            const pub_key = secret_key.derivePublicKey();
            if (pub_key.fingerprint(ctx.allocator)) |fp| {
                trusted_fingerprints.append(ctx.allocator, fp) catch {};
            } else |_| {}
        } else |_| {
            if (sign.PublicKey.loadFromFile(key_path)) |pub_key| {
                if (pub_key.fingerprint(ctx.allocator)) |fp| {
                    trusted_fingerprints.append(ctx.allocator, fp) catch {};
                } else |_| {}
            } else |_| {}
        }
    }

    var loaded_keys = sign.loadAllKeys(ctx) catch std.ArrayList(sign.LoadedKey).empty;
    defer {
        for (loaded_keys.items) |*key| {
            key.deinit(ctx.allocator);
        }
        loaded_keys.deinit(ctx.allocator);
    }
    for (loaded_keys.items) |loaded_key| {
        const fp_copy = ctx.allocator.dupe(u8, loaded_key.fingerprint) catch continue;
        trusted_fingerprints.append(ctx.allocator, fp_copy) catch {
            ctx.allocator.free(fp_copy);
        };
    }

    return trusted_fingerprints;
}

fn resolveOrBootstrapRepoDir(ctx: *Context, repo_name_or_path: []const u8) !RepoSourceResult {
    if (resolveRepoSource(ctx, repo_name_or_path)) |resolve_result| {
        return resolve_result;
    } else |err| {
        if (err != ImportError.PackageNotFound) return err;

        const resolved_key = sign.resolveSigningKey(ctx, null) catch {
            return ctx.fail(ImportError.PackageNotFound, repo_name_or_path, "signing key resolution failed");
        };
        defer ctx.allocator.free(resolved_key);

        std.Io.Dir.cwd().access(p.currentIo(), resolved_key, .{}) catch {
            return ctx.fail(ImportError.PackageNotFound, repo_name_or_path, resolved_key);
        };

        const bootstrap_path = try getBootstrapPath(ctx, repo_name_or_path);
        errdefer ctx.allocator.free(bootstrap_path);
        try bootstrapRepoSource(ctx, bootstrap_path);
        return .{ .dir_path = bootstrap_path, .allocated = true };
    }
}

fn insertPackageWithForce(
    ctx: *Context,
    db: *repodb.RepoDB,
    pkg_ptr: *package.Package,
    force: bool,
) !void {
    _ = db.insertPackageTransaction(pkg_ptr) catch |err| {
        if (err == repodb.RepoDBError.PackageAlreadyExists and force) {
            ctx.debug("package already exists, --force specified, replacing", .{});
            db.deletePackage(
                pkg_ptr.name.?,
                pkg_ptr.version.?,
                pkg_ptr.release.?,
                pkg_ptr.arch.?,
            ) catch |del_err| {
                ctx.debug("failed to delete existing package: {}", .{del_err});
                return ctx.fail(del_err, pkg_ptr.name.?, "failed to delete existing package from database");
            };
            _ = db.insertPackageTransaction(pkg_ptr) catch |retry_err| {
                const diag = ctx.getDiagnosticContext();
                if (diag.details == null) {
                    ctx.setDiagnosticContextFmt(pkg_ptr.name.?, "failed to insert package into database: {s}", .{@errorName(retry_err)});
                }
                return retry_err;
            };
        } else {
            return ctx.fail(err, pkg_ptr.name.?, "failed to insert package into database");
        }
    };
}

const NameArchPair = struct {
    name: []const u8,
    arch: []const u8,
};

fn appendUniqueNameArch(ctx: *Context, list: *std.ArrayList(NameArchPair), name: []const u8, arch: []const u8) !void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item.name, name) and std.mem.eql(u8, item.arch, arch)) return;
    }

    const name_copy = try ctx.allocator.dupe(u8, name);
    errdefer ctx.allocator.free(name_copy);
    const arch_copy = try ctx.allocator.dupe(u8, arch);
    errdefer ctx.allocator.free(arch_copy);
    try list.append(ctx.allocator, .{ .name = name_copy, .arch = arch_copy });
}

fn insertPruneAndCommit(
    ctx: *Context,
    repo_dir: []const u8,
    records: []PreparedImportRecord,
    force: bool,
) !void {
    var staged = repo_history.stageNext(ctx, repo_dir) catch |err| {
        return switch (err) {
            error.OutOfMemory => ctx.fail(ImportError.OutOfMemory, repo_dir, "failed to stage next state"),
            error.PermissionDenied => ctx.fail(ImportError.FileSystem, repo_dir, "permission denied staging next state"),
            error.InvalidInput => ctx.fail(ImportError.InvalidInput, repo_dir, "repository database schema is outdated or invalid"),
            else => ctx.fail(ImportError.FileSystem, repo_dir, "failed to stage next state"),
        };
    };
    defer staged.deinit();

    var touched_pairs: std.ArrayList(NameArchPair) = .empty;
    defer {
        for (touched_pairs.items) |pair| {
            ctx.allocator.free(pair.name);
            ctx.allocator.free(pair.arch);
        }
        touched_pairs.deinit(ctx.allocator);
    }

    for (records) |*record| {
        const pkg_ptr = &record.prepared.manifest.pkg;
        try insertPackageWithForce(ctx, staged.db, pkg_ptr, force);
        try appendUniqueNameArch(ctx, &touched_pairs, pkg_ptr.name.?, pkg_ptr.arch.?);
    }

    var pruned_total: u32 = 0;
    for (touched_pairs.items) |pair| {
        const pruned = repo_history.pruneOldVersions(
            staged.db,
            pair.name,
            pair.arch,
            repo_history.DEFAULT_KEEP_VERSIONS,
        ) catch |prune_err| {
            ctx.debug("auto-prune failed: {}", .{prune_err});
            return ctx.fail(ImportError.FileSystem, pair.name, "failed to auto-prune old package versions");
        };
        pruned_total += pruned;
        if (pruned > 0) {
            mere.ui.emit.logFmtSeverity(ctx, .import, .info, "auto-pruned {d} old version(s) of {s}/{s}", .{ pruned, pair.name, pair.arch });
        }
    }

    staged.commit() catch {
        return ImportError.SigningFailed;
    };
    if (pruned_total > 0) {
        mere.ui.emit.logFmtSeverity(ctx, .import, .info, "auto-pruned {d} old version(s) total", .{pruned_total});
    }
    return;
}

const PreparedImportRecord = struct {
    package_path: []const u8,
    package_path_allocated: ?[]const u8,
    prepared: PreparedImport,

    pub fn deinit(self: *PreparedImportRecord, allocator: std.mem.Allocator) void {
        self.prepared.deinit(allocator);
        if (self.package_path_allocated) |path_alloc| allocator.free(path_alloc);
    }
};

fn prepareImportRecord(ctx: *Context, file_path: []const u8) !PreparedImportRecord {
    var final_pkg_path: []const u8 = undefined;
    var allocated_path: ?[]const u8 = null;
    {
        const resolved = try resolvePackagePath(ctx, file_path);
        final_pkg_path = resolved.final_path;
        allocated_path = resolved.allocated;
    }
    errdefer if (allocated_path) |path_alloc| ctx.allocator.free(path_alloc);

    try validatePackageArchiveFormat(ctx, final_pkg_path);
    var prepared = try prepareVerifiedImport(ctx, final_pkg_path);
    errdefer prepared.deinit(ctx.allocator);

    return .{
        .package_path = final_pkg_path,
        .package_path_allocated = allocated_path,
        .prepared = prepared,
    };
}

fn packageTupleKey(ctx: *Context, pkg_ptr: *const package.Package) ![]const u8 {
    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}|{s}|{d}|{s}",
        .{ pkg_ptr.name.?, pkg_ptr.version.?, pkg_ptr.release.?, pkg_ptr.arch.? },
    );
}

fn preflightAndPersistArtifacts(
    ctx: *Context,
    repo_dir: []const u8,
    records: []PreparedImportRecord,
    force: bool,
) !void {
    // Open repository read-only for pre-flight checks (duplicate tuple, artifact storage)
    var repo = try Repository.init(ctx, repo_dir, true);
    defer repo.deinit();

    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer {
        var iter = seen.keyIterator();
        while (iter.next()) |key| {
            ctx.allocator.free(key.*);
        }
        seen.deinit();
    }

    // For non-force imports, duplicate package tuples should fail before touching package files.
    for (records) |record| {
        const pkg_ptr = &record.prepared.manifest.pkg;
        if (!force) {
            const exists = packageTupleExists(repo.db, pkg_ptr) catch |err| {
                return ctx.fail(err, pkg_ptr.name.?, "failed to check if package already exists");
            };
            if (exists) {
                ctx.setDiagnosticContextFmt(pkg_ptr.name.?, "{s}@{s}-{d}:{s} already exists in repository", .{
                    pkg_ptr.name.?,
                    pkg_ptr.version.?,
                    pkg_ptr.release.?,
                    pkg_ptr.arch.?,
                });
                return repodb.RepoDBError.PackageAlreadyExists;
            }

            const tuple_key = packageTupleKey(ctx, pkg_ptr) catch {
                return ctx.fail(ImportError.OutOfMemory, pkg_ptr.name.?, "out of memory allocating batch tuple key");
            };
            if (seen.contains(tuple_key)) {
                ctx.allocator.free(tuple_key);
                ctx.setDiagnosticContextFmt(pkg_ptr.name.?, "{s}@{s}-{d}:{s} appears more than once in import batch", .{
                    pkg_ptr.name.?,
                    pkg_ptr.version.?,
                    pkg_ptr.release.?,
                    pkg_ptr.arch.?,
                });
                return repodb.RepoDBError.PackageAlreadyExists;
            }
            seen.put(tuple_key, {}) catch {
                ctx.allocator.free(tuple_key);
                return ctx.fail(ImportError.OutOfMemory, pkg_ptr.name.?, "out of memory recording package tuple");
            };
        }

        // Atomically copy the package into the repo packages directory
        const repo_pkg_path = try storeArtifactAtomically(ctx, pkg_ptr, record.package_path, repo_dir);
        defer ctx.allocator.free(repo_pkg_path);
    }
}

const Std = errors.StandardErrors;
pub const ImportError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput || Std.SignatureInvalid || error{
    PackageImportFailed,
    PackageExtractFailed,
    SigningFailed,
    PackageNotFound,
};

pub fn packages(ctx: *Context, repo_name_or_path: []const u8, file_paths: []const []const u8, force: bool) !void {
    if (file_paths.len == 0) {
        return ctx.fail(ImportError.InvalidInput, repo_name_or_path, "no package archives provided");
    }

    const resolved_repo = try resolveOrBootstrapRepoDir(ctx, repo_name_or_path);
    defer if (resolved_repo.allocated) ctx.allocator.free(resolved_repo.dir_path);

    var records: std.ArrayList(PreparedImportRecord) = .empty;
    defer {
        for (records.items) |*record| {
            record.deinit(ctx.allocator);
        }
        records.deinit(ctx.allocator);
    }

    for (file_paths, 0..) |file_path, i| {
        const record = prepareImportRecord(ctx, file_path) catch |err| {
            // Enrich diagnostic context with which package failed
            const basename = std.fs.path.basename(file_path);
            if (file_paths.len > 1) {
                const existing = ctx.getDiagnosticContext();
                ctx.setDiagnosticContextFmt(basename, "package {d} of {d}: {s}", .{
                    i + 1,
                    file_paths.len,
                    existing.details orelse "preparation failed",
                });
            } else if (ctx.getDiagnosticContext().subject == null) {
                ctx.setDiagnosticContext(basename, "import preparation failed");
            }
            return err;
        };
        try records.append(ctx.allocator, record);
    }

    preflightAndPersistArtifacts(ctx, resolved_repo.dir_path, records.items, force) catch |err| {
        // If preflight set context with a package name, enrich with repo context
        const existing = ctx.getDiagnosticContext();
        if (existing.subject) |subject| {
            ctx.setDiagnosticContextFmt(subject, "repository '{s}': {s}", .{
                repo_name_or_path,
                existing.details orelse "preflight failed",
            });
        }
        return err;
    };

    insertPruneAndCommit(ctx, resolved_repo.dir_path, records.items, force) catch |err| {
        const existing = ctx.getDiagnosticContext();
        if (existing.subject) |subject| {
            ctx.setDiagnosticContextFmt(subject, "repository '{s}': {s}", .{
                repo_name_or_path,
                existing.details orelse "database commit failed",
            });
        }
        return err;
    };
}

test "packages with ELF library" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;
    ctx.debug("starting packages with ELF library test", .{});
    const pkg_name = "testpkg";
    var pkg = package.Package.init(&ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, pkg_name);
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    pkg.content_hash = try ctx.allocator.dupe(u8, "dummyhash");
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    // Note: Dependencies are not stored in manifest.v1 format - they are extracted
    // from ELF files during import. The setupTestImport creates a dummy tar without
    // ELF files, so no dependencies will be recorded. This test verifies basic import
    // and signature functionality.

    const result = try th.setupTestImport(&ctx, &pkg, test_env, "test-pkg.tar");
    defer ctx.allocator.free(result.db_path);
    defer ctx.allocator.free(result.pkg_path);
    defer ctx.allocator.free(result.secret_key_path);

    // Define repo_dir for this test (repo is at ${root}/mere/dev/repo/import/)
    const repo_name = "import";
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mere", "dev", "repo", repo_name });
    defer std.testing.allocator.free(repo_dir);
    var repo = try Repository.init(&ctx, repo_dir, false);
    defer repo.deinit();

    // Open RepoDB for queries
    const db = repo.db;

    // Check package exists with correct metadata
    const check_pkg_sql =
        \\SELECT name, version, release FROM packages
        \\WHERE name = ? AND version = ? AND release = ?;
    ;
    const stmt = try db.prepareStatement(check_pkg_sql);
    if (stmt != null) {
        defer _ = c.sqlite3_finalize(@ptrCast(stmt));
        _ = c.sqlite3_bind_text(@ptrCast(stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(@ptrCast(stmt), 2, "1.0.0", 5, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(@ptrCast(stmt), 3, 1);
        try std.testing.expect(c.sqlite3_step(@ptrCast(stmt)) == c.SQLITE_ROW);
    }

    // Verify signature was recorded
    const check_sig_sql = "SELECT signature FROM packages WHERE name = ?;";
    const sig_stmt = try db.prepareStatement(check_sig_sql);
    if (sig_stmt != null) {
        defer _ = c.sqlite3_finalize(@ptrCast(sig_stmt));
        _ = c.sqlite3_bind_text(@ptrCast(sig_stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);
        try std.testing.expect(c.sqlite3_step(@ptrCast(sig_stmt)) == c.SQLITE_ROW);
        const signature_value = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(sig_stmt), 0)));
        try std.testing.expect(signature_value.len > 0);
        try std.testing.expectEqual(@as(usize, 128), signature_value.len);
    }
}

test "packages with missing manifest.v1" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;
    ctx.debug("starting packages with missing manifest.v1 test", .{});

    // Create test package archive without manifest.v1
    const pkg_file = "missing-manifest.tar";
    const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, pkg_file });
    defer std.testing.allocator.free(pkg_path);

    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // deliberately creates a malformed archive (missing manifest.v1) to test error handling.
    // This test deliberately builds a malformed archive and needs raw tar control.
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };

    // Create a dummy file to make it a valid tar archive
    try tar_writer.writeFileBytes("dummy", "dummy", .{});

    const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
    defer std.testing.allocator.free(tar_contents);
    var pkg_file_handle = try std.Io.Dir.createFileAbsolute(p.currentIo(), pkg_path, .{});
    defer pkg_file_handle.close(p.currentIo());
    try pkg_file_handle.writeStreamingAll(p.currentIo(), tar_contents);

    // Generate a key pair for signing
    const key_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "keys" });
    defer std.testing.allocator.free(key_dir);
    try p.ensureDirExists(key_dir);

    const key_pair = try sign.generateKeyPair();
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ key_dir, "test.key" });
    defer std.testing.allocator.free(secret_key_path);
    try key_pair.secret_key.saveToFile(secret_key_path);

    // Set signing key in context (enables bootstrap)
    ctx.signing_key_path = secret_key_path;

    const repo_name = "test-repo";
    const single = [_][]const u8{pkg_path};
    const result = packages(&ctx, repo_name, single[0..], false);
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        ctx.resetDiagnostics();
        try std.testing.expect(err == ImportError.PackageNotFound);
    }
}

test "packages duplicate without force does not overwrite package artifact" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    const pkg_name = "dup-test-pkg";
    var pkg = package.Package.init(&ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, pkg_name);
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    pkg.content_hash = try ctx.allocator.dupe(u8, "dummyhash");
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);

    const result = try th.setupTestImport(&ctx, &pkg, test_env, "dup-test.tar");
    defer ctx.allocator.free(result.db_path);
    defer ctx.allocator.free(result.pkg_path);
    defer ctx.allocator.free(result.secret_key_path);

    const pool_dir = try std.fs.path.join(ctx.allocator, &.{
        test_env.path,
        "mere",
        "dev",
        "repo",
        "import",
        "packages",
    });
    defer ctx.allocator.free(pool_dir);

    const io = p.currentIo();
    var dir = try std.Io.Dir.openDirAbsolute(io, pool_dir, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    const first_entry = (try iter.next(io)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_entry.kind == .file);

    const repo_pkg_path = try std.fs.path.join(ctx.allocator, &.{ pool_dir, first_entry.name });
    defer ctx.allocator.free(repo_pkg_path);

    var before_file = try p.openExistingFile(repo_pkg_path);
    defer before_file.close(io);
    const before_stat = try before_file.stat(io);

    const dup_single = [_][]const u8{result.pkg_path};
    const dup_result = packages(&ctx, "import", dup_single[0..], false);
    try std.testing.expectError(repodb.RepoDBError.PackageAlreadyExists, dup_result);
    ctx.resetDiagnostics();

    var after_file = try p.openExistingFile(repo_pkg_path);
    defer after_file.close(io);
    const after_stat = try after_file.stat(io);
    try std.testing.expectEqual(before_stat.inode, after_stat.inode);
}

test "storeArtifactAtomically cleans temp file when rename fails" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    var pkg = package.Package.init(&ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, "rename-fail-pkg");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    pkg.content_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    pkg.archive_hash = try ctx.allocator.dupe(u8, "b" ** 64);

    const src_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "rename-fail-src.tar" });
    defer ctx.allocator.free(src_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(p.currentIo(), src_path, .{});
        defer f.close(p.currentIo());
        try f.writeStreamingAll(p.currentIo(), "dummy archive content");
    }

    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "test-repo" });
    defer ctx.allocator.free(repo_dir);
    try p.ensureDirExists(repo_dir);
    const packages_dir = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "packages" });
    defer ctx.allocator.free(packages_dir);
    try p.ensureDirExists(packages_dir);

    const canonical_name = try pkg.canonicalArchiveName();
    defer ctx.allocator.free(canonical_name);
    const final_path = try std.fs.path.join(ctx.allocator, &.{ packages_dir, canonical_name });
    defer ctx.allocator.free(final_path);

    // Force rename failure by creating a directory at the destination path.
    try p.ensureDirExists(final_path);
    defer {
        if (std.fs.path.dirname(final_path)) |parent_path| {
            if (p.openExistingDir(parent_path) catch null) |parent_dir| {
                var dir = parent_dir;
                defer dir.close(p.currentIo());
                dir.deleteTree(p.currentIo(), std.fs.path.basename(final_path)) catch {};
            }
        }
    }

    try std.testing.expectError(
        ImportError.PackageImportFailed,
        storeArtifactAtomically(&ctx, &pkg, src_path, repo_dir),
    );
    ctx.resetDiagnostics();

    // Ensure no temp artifacts remain for this package.
    const io = p.currentIo();
    var dir = try std.Io.Dir.openDirAbsolute(io, packages_dir, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, canonical_name));
    }
}

test "storeArtifactAtomically treats existing canonical archive as success" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    var pkg = package.Package.init(&ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, "idempotent-pkg");
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    pkg.content_hash = try ctx.allocator.dupe(u8, "b" ** 64);
    pkg.archive_hash = try ctx.allocator.dupe(u8, "c" ** 64);

    const src_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "idempotent-src.tar" });
    defer ctx.allocator.free(src_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(p.currentIo(), src_path, .{});
        defer f.close(p.currentIo());
        try f.writeStreamingAll(p.currentIo(), "new archive content");
    }

    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "test-repo" });
    defer ctx.allocator.free(repo_dir);
    try p.ensureDirExists(repo_dir);
    const packages_dir = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "packages" });
    defer ctx.allocator.free(packages_dir);
    try p.ensureDirExists(packages_dir);

    const canonical_name = try pkg.canonicalArchiveName();
    defer ctx.allocator.free(canonical_name);
    const final_path = try std.fs.path.join(ctx.allocator, &.{ packages_dir, canonical_name });
    defer ctx.allocator.free(final_path);
    {
        var existing = try std.Io.Dir.createFileAbsolute(p.currentIo(), final_path, .{});
        defer existing.close(p.currentIo());
        try existing.writeStreamingAll(p.currentIo(), "existing archive content");
    }

    const stored_path = try storeArtifactAtomically(&ctx, &pkg, src_path, repo_dir);
    defer ctx.allocator.free(stored_path);

    try std.testing.expectEqualStrings(final_path, stored_path);

    const final_bytes = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), p.currentIo(), final_path, ctx.allocator, .limited(1024));
    defer ctx.allocator.free(final_bytes);
    try std.testing.expectEqualStrings("existing archive content", final_bytes);
}

test "packages with invalid manifest format" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;
    ctx.debug("starting packages with invalid manifest format test", .{});

    // Create test package archive with invalid manifest (not valid binary format)
    // Invalid manifest content - missing magic bytes
    const invalid_manifest_content = "not a valid manifest format - random bytes";

    // Create package archive
    const pkg_file = "invalid-manifest.tar";
    const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, pkg_file });
    defer std.testing.allocator.free(pkg_path);

    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // deliberately creates a malformed archive (invalid manifest content) to test error handling.
    // This test deliberately builds a malformed archive and needs raw tar control.
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };

    // Add .mere directory and manifest.v1 with invalid content to archive
    try tar_writer.writeDir(manifest.META_DIR, .{});
    try tar_writer.writeFileBytes(manifest.MANIFEST_FILENAME, invalid_manifest_content, .{});

    const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
    defer std.testing.allocator.free(tar_contents);
    var pkg_file_handle = try std.Io.Dir.createFileAbsolute(p.currentIo(), pkg_path, .{});
    defer pkg_file_handle.close(p.currentIo());
    try pkg_file_handle.writeStreamingAll(p.currentIo(), tar_contents);

    // Generate a key pair for signing
    const key_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "keys" });
    defer std.testing.allocator.free(key_dir);
    try p.ensureDirExists(key_dir);

    const key_pair = try sign.generateKeyPair();
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ key_dir, "test.key" });
    defer std.testing.allocator.free(secret_key_path);
    try key_pair.secret_key.saveToFile(secret_key_path);

    // Set signing key in context (enables bootstrap)
    ctx.signing_key_path = secret_key_path;

    const repo_name = "test-repo";
    const single = [_][]const u8{pkg_path};
    const result = packages(ctx, repo_name, single[0..], false);
    if (result) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err == ImportError.InvalidInput);
    }
}

test "packages with no ELF files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;
    const pkg_name = "no-elf-pkg";
    var pkg = package.Package.init(&ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, pkg_name);
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    pkg.content_hash = try ctx.allocator.dupe(u8, "dummyhash");
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);
    // No dependencies or provisions added

    const result = try th.setupTestImport(&ctx, &pkg, test_env, "no-elf.tar");
    defer ctx.allocator.free(result.db_path);
    defer ctx.allocator.free(result.pkg_path);
    defer ctx.allocator.free(result.secret_key_path);

    // Verify package was imported without any dependencies (repo is at ${root}/mere/dev/repo/import/)
    const repo_name = "import";
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mere", "dev", "repo", repo_name });
    defer std.testing.allocator.free(repo_dir);
    var repo = try Repository.init(&ctx, repo_dir, false);
    defer repo.deinit();

    const check_deps_sql = "SELECT COUNT(*) FROM dependencies WHERE source_package_id IN (SELECT id FROM packages WHERE name = ?);";
    const stmt = try repo.db.prepareStatement(check_deps_sql);
    if (stmt != null) {
        defer _ = c.sqlite3_finalize(@ptrCast(stmt));
        _ = c.sqlite3_bind_text(@ptrCast(stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);
        try std.testing.expect(c.sqlite3_step(@ptrCast(stmt)) == c.SQLITE_ROW);
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(@ptrCast(stmt), 0));
    }
}

test "packages with multiple ELF files" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    const archive_mod = @import("archive.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a test package archive
    const pkg_name = "multi-elf-pkg";

    // Create a content directory to compute hash from
    const content_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "pkg_content" });
    defer std.testing.allocator.free(content_dir);
    try p.ensureDirExists(content_dir);

    // Set up paths for two different ELF files
    const lib1_name = "usr/lib/libtest.so";
    const lib1_path = try std.fs.path.join(std.testing.allocator, &.{ content_dir, lib1_name });
    defer std.testing.allocator.free(lib1_path);

    const lib2_name = "usr/lib/libsoname.so";
    const lib2_path = try std.fs.path.join(std.testing.allocator, &.{ content_dir, lib2_name });
    defer std.testing.allocator.free(lib2_path);

    // Create directory structure in content dir
    const lib_dir_path = std.fs.path.dirname(lib1_path).?;
    var lib_dir = try p.makePathAndOpenDir(lib_dir_path);
    lib_dir.close(p.currentIo());

    // Copy test ELF libraries to content dir
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src1_path = try p.resolveToAbsolutePath("test/testdata/libtest.so", &src_buf);
    try p.copyFile(src1_path, lib1_path);

    const src2_path = try p.resolveToAbsolutePath("test/testdata/libsoname.so", &src_buf);
    try p.copyFile(src2_path, lib2_path);

    // Create .mere directory for meta.kdl (content hash is computed without .mere/)
    const mere_dir_path = try std.fs.path.join(std.testing.allocator, &.{ content_dir, manifest.META_DIR });
    defer std.testing.allocator.free(mere_dir_path);
    try p.ensureDirExists(mere_dir_path);

    // Create meta.kdl with test dependencies and provisions
    // These are the dependencies that the test expects to find
    const meta_path = try std.fs.path.join(std.testing.allocator, &.{ content_dir, manifest.META_KDL_FILENAME });
    defer std.testing.allocator.free(meta_path);
    const meta_content =
        \\dependencies {
        \\    elf-needed "libc.so"
        \\    elf-needed "libz.so.1"
        \\    elf-needed "libssl.so.3"
        \\}
        \\provisions {
        \\    elf-soname "libcustom.so.1"
        \\}
    ;
    var meta_file = try std.Io.Dir.createFileAbsolute(p.currentIo(), meta_path, .{});
    defer meta_file.close(p.currentIo());
    try meta_file.writeStreamingAll(p.currentIo(), meta_content);

    // Compute the content hash of the content directory (before adding manifest)
    const content_hash_hex = try hash.calculateStoreContentHash(ctx.allocator, content_dir, null);
    defer ctx.allocator.free(content_hash_hex);

    // Parse content hash hex to bytes
    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex) catch unreachable;

    // Use the default key created by createTestEnv() at ~/.mere/keys/mere.key
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys", "mere.key" });
    defer std.testing.allocator.free(secret_key_path);
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);

    // Create manifest
    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = @intCast(std.Io.Clock.real.now(p.currentIo()).toSeconds()),
        .release = 1,
        .arch = "x86_64",
        .name = pkg_name,
        .version = "1.0.0",
        .content_hash = content_hash_bytes,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    try manifest.writeManifest(&ctx, content_dir, &pkg_manifest, &secret_key.key);

    var projection = try projection_index.deriveFromPayload(ctx.allocator, content_dir);
    defer projection.deinit();
    try projection_index.writeFile(ctx.allocator, content_dir, &projection);

    // Create package archive using libarchive (preserves permissions and handles hardlinks)
    const pkg_file = "multi-elf.tar";
    const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, pkg_file });
    defer std.testing.allocator.free(pkg_path);

    try archive_mod.createPackageArchive(&ctx, content_dir, pkg_path);

    // Create test database
    // Repo will be created at ${root}/mere/dev/repo/import/ via bootstrap
    const repo_name = "import";

    // Set signing key in context to enable bootstrap
    ctx.signing_key_path = secret_key_path;

    const single = [_][]const u8{pkg_path};
    try packages(&ctx, repo_name, single[0..], false);

    // Verify package was imported with dependencies from both ELF files
    // Repo is at ${root}/mere/dev/repo/import/
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mere", "dev", "repo", repo_name });
    defer std.testing.allocator.free(repo_dir);
    var repo = try Repository.init(&ctx, repo_dir, false);
    defer repo.deinit();

    // Check dependencies were recorded from both files
    const check_deps_sql =
        \\SELECT d.dependency_type, d.target_resource, d.target_type
        \\FROM dependencies d
        \\JOIN packages p ON d.source_package_id = p.id
        \\WHERE p.name = ?;
    ;

    // Debug: Print raw SQL to verify
    ctx.debug("sql query for dependencies: {s}", .{check_deps_sql});
    var repo_db = repo.db;
    const dep_stmt = try repo_db.prepareStatement(check_deps_sql);
    if (dep_stmt != null) {
        defer _ = c.sqlite3_finalize(@ptrCast(dep_stmt));
        const bind_result = c.sqlite3_bind_text(@ptrCast(dep_stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);
        ctx.debug("sql bind result: {d}", .{bind_result});

        // Use a simple array to collect dependencies
        var deps_array: std.ArrayList([]u8) = .empty;
        defer {
            for (deps_array.items) |item| {
                std.testing.allocator.free(item);
            }
            deps_array.deinit(std.testing.allocator);
        }

        // Collect all dependencies
        var step_result: c_int = 0;
        var row_count: usize = 0;
        step_result = c.sqlite3_step(@ptrCast(dep_stmt));
        while (step_result == c.SQLITE_ROW) {
            row_count += 1;
            const dep_type = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(dep_stmt), 0)));
            const target = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(dep_stmt), 1)));
            const target_type = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(dep_stmt), 2)));

            try std.testing.expectEqualStrings("elf-needed", dep_type);
            try std.testing.expectEqualStrings("elf-needed", target_type);

            // Debug: Print each dependency as it's retrieved from the database
            ctx.debug("retrieved dependency from db: {s}", .{target});

            try deps_array.append(std.testing.allocator, try std.testing.allocator.dupe(u8, target));
            step_result = c.sqlite3_step(@ptrCast(dep_stmt));
        }

        // Helper function to check if a string is in the array
        const containsString = struct {
            fn contains(list: std.ArrayList([]u8), str: []const u8) bool {
                for (list.items) |item| {
                    if (std.mem.eql(u8, item, str)) return true;
                }
                return false;
            }
        }.contains;

        // Debug: Print all dependencies found
        ctx.debug("found {d} rows in dependencies query", .{row_count});
        ctx.debug("last step result: {d} (SQLITE_ROW={d}, SQLITE_DONE={d})", .{ step_result, c.SQLITE_ROW, c.SQLITE_DONE });

        ctx.debug("found dependencies in multi-elf test:", .{});
        for (deps_array.items) |dep| {
            ctx.debug("- {s}", .{dep});
        }

        // Debug: Directly query the database to check if libssl.so.3 exists
        const check_libssl_sql = "SELECT COUNT(*) FROM dependencies WHERE target_resource = 'libssl.so.3';";
        const libssl_stmt = try repo.db.prepareStatement(check_libssl_sql);
        if (libssl_stmt != null) {
            defer _ = c.sqlite3_finalize(@ptrCast(libssl_stmt));
            if (c.sqlite3_step(@ptrCast(libssl_stmt)) == c.SQLITE_ROW) {
                const count = c.sqlite3_column_int64(@ptrCast(libssl_stmt), 0);
                ctx.debug("direct query for libssl.so.3 found {d} rows", .{count});
            }
        }

        // Debug: Check package ID and dependency details
        const pkg_id_sql = "SELECT id FROM packages WHERE name = ?;";
        const pkg_id_stmt = try repo.db.prepareStatement(pkg_id_sql);
        if (pkg_id_stmt != null) {
            defer _ = c.sqlite3_finalize(@ptrCast(pkg_id_stmt));
            _ = c.sqlite3_bind_text(@ptrCast(pkg_id_stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);
            if (c.sqlite3_step(@ptrCast(pkg_id_stmt)) == c.SQLITE_ROW) {
                const pkg_id = c.sqlite3_column_int64(@ptrCast(pkg_id_stmt), 0);
                ctx.debug("package ID for '{s}': {d}", .{ pkg_name, pkg_id });

                // Now check all dependencies for this package ID
                const deps_by_id_sql = "SELECT target_resource FROM dependencies WHERE source_package_id = ?;";
                const deps_by_id_stmt = try repo.db.prepareStatement(deps_by_id_sql);
                if (deps_by_id_stmt != null) {
                    defer _ = c.sqlite3_finalize(@ptrCast(deps_by_id_stmt));
                    _ = c.sqlite3_bind_int64(@ptrCast(deps_by_id_stmt), 1, pkg_id);
                    ctx.debug("dependencies for package ID {d}:", .{pkg_id});
                    while (c.sqlite3_step(@ptrCast(deps_by_id_stmt)) == c.SQLITE_ROW) {
                        const dep = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(deps_by_id_stmt), 0)));
                        ctx.debug("- {s}", .{dep});
                    }
                }

                // Check all dependencies in the table
                const all_deps_sql = "SELECT source_package_id, target_resource FROM dependencies;";
                const all_deps_stmt = try repo.db.prepareStatement(all_deps_sql);
                if (all_deps_stmt) |ads| {
                    defer _ = c.sqlite3_finalize(@ptrCast(ads));
                    ctx.debug("all dependencies in the database:", .{});
                    while (c.sqlite3_step(@ptrCast(ads)) == c.SQLITE_ROW) {
                        const src_id = c.sqlite3_column_int64(@ptrCast(ads), 0);
                        const target = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(ads), 1)));
                        ctx.debug("- package ID {d}: {s}", .{ src_id, target });
                    }
                }
            }
        }

        // Add more debugging about array contents
        ctx.debug("checking dependencies array with {} items", .{deps_array.items.len});
        for (deps_array.items) |item| {
            ctx.debug("array contains: {s}", .{item});
        }

        // Verify all expected dependencies are found
        const has_libc = containsString(deps_array, "libc.so");
        const has_libz = containsString(deps_array, "libz.so.1");
        const has_libssl = containsString(deps_array, "libssl.so.3");

        ctx.debug("has libc.so: {}", .{has_libc});
        ctx.debug("has libz.so.1: {}", .{has_libz});
        ctx.debug("has libssl.so.3: {}", .{has_libssl});

        try std.testing.expect(has_libc);
        try std.testing.expect(has_libz);
        try std.testing.expect(has_libssl);

        // Check that the SONAME was recorded
        const check_soname_sql =
            \\SELECT resource FROM provisions
            \\WHERE package_id IN (SELECT id FROM packages WHERE name = ?)
            \\AND type = 'elf-soname';
        ;
        const soname_stmt = try repo.db.prepareStatement(check_soname_sql);
        if (soname_stmt != null) {
            defer _ = c.sqlite3_finalize(@ptrCast(soname_stmt));
            _ = c.sqlite3_bind_text(@ptrCast(soname_stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);

            try std.testing.expect(c.sqlite3_step(@ptrCast(soname_stmt)) == c.SQLITE_ROW);
            const soname = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(soname_stmt), 0)));
            try std.testing.expectEqualStrings("libcustom.so.1", soname);
        }
    }
}

test "signDb creates valid signature" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a test database file
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "test_sign.db" });
    defer std.testing.allocator.free(db_path);

    // Create a simple database file with some content
    var db_file = try std.Io.Dir.createFileAbsolute(p.currentIo(), db_path, .{});
    defer db_file.close(p.currentIo());
    try db_file.writeStreamingAll(p.currentIo(), "This is a test database file");

    // Generate a key pair for signing
    const key_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "keys" });
    defer std.testing.allocator.free(key_dir);

    // Create the key directory
    try p.ensureDirExists(key_dir);

    // Generate key pair
    const key_pair = try sign.generateKeyPair();

    // Save keys to files
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ key_dir, "test.key" });
    defer std.testing.allocator.free(secret_key_path);

    const public_key_path = try std.fs.path.join(std.testing.allocator, &.{ key_dir, "test.pub" });
    defer std.testing.allocator.free(public_key_path);

    try key_pair.secret_key.saveToFile(secret_key_path);
    try key_pair.public_key.saveToFile(public_key_path);

    // Sign the database file
    // Instead of using Repository.signDb, use sign.signFile directly
    // Compute signature path first
    const sig_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.sig", .{db_path});
    defer std.testing.allocator.free(sig_path);

    // Set the signing key path in the context
    ctx.signing_key_path = secret_key_path;
    _ = try sign.writeSignatureFileWithResolver(&ctx, db_path, sig_path, null, null);

    // Verify the signature file exists

    var sig_file = try p.openExistingFile(sig_path);
    sig_file.close(p.currentIo());

    // Verify the signature is valid
    try sign.verifySignature(&ctx, db_path, public_key_path, sig_path);
}

test "packages handles ./manifest.v1 path prefix" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;
    const pkg_name = "path-prefix-test";

    // Create a content directory to compute hash from (empty package, just manifest)
    const content_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "pkg_content" });
    defer std.testing.allocator.free(content_dir);
    try p.ensureDirExists(content_dir);

    // Compute the content hash of the empty content directory
    const content_hash_hex = try hash.calculateStoreContentHash(ctx.allocator, content_dir, null);
    defer ctx.allocator.free(content_hash_hex);

    // Parse content hash hex to bytes
    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex) catch unreachable;

    // Use the default key created by createTestEnv() at ~/.mere/keys/mere.key
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys", "mere.key" });
    defer std.testing.allocator.free(secret_key_path);
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);

    // Create signed manifest
    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = @intCast(std.Io.Clock.real.now(p.currentIo()).toSeconds()),
        .release = 1,
        .arch = "x86_64",
        .name = pkg_name,
        .version = "1.0.0",
        .content_hash = content_hash_bytes,
    };
    const manifest_data = try pkg_manifest.encode(std.testing.allocator);
    defer std.testing.allocator.free(manifest_data);

    // Sign the manifest
    var sig: [sign.c.crypto_sign_BYTES]u8 = undefined;
    _ = sign.c.crypto_sign_detached(&sig, null, manifest_data.ptr, manifest_data.len, &secret_key.key);

    // Create package archive with ./manifest.v1 (with ./ prefix like real packages)
    const pkg_file = "path-prefix-test.tar";
    const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, pkg_file });
    defer std.testing.allocator.free(pkg_path);

    // EXCEPTION: Using std.tar.Writer instead of archive.createTar because this test
    // needs precise control over path entry formats (specifically "./" prefixes) to test
    // path normalization. libarchive normalizes paths automatically, which would defeat
    // the purpose of this test.
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var tar_writer = std.tar.Writer{
        .underlying_writer = &buffer.writer,
    };

    // Create root directory entry and .mere directory
    try tar_writer.writeDir(".", .{});
    try tar_writer.writeDir("./" ++ manifest.META_DIR, .{});

    var projection = projection_index.Data.init(std.testing.allocator);
    defer projection.deinit();
    const projection_bytes = try projection.encode(std.testing.allocator);
    defer std.testing.allocator.free(projection_bytes);

    // Add manifest.v1 and manifest.v1.sig with ./ prefix (like real packages)
    try tar_writer.writeFileBytes("./" ++ manifest.MANIFEST_FILENAME, manifest_data, .{});
    try tar_writer.writeFileBytes("./" ++ manifest.MANIFEST_SIG_FILENAME, &sig, .{});
    try tar_writer.writeFileBytes("./" ++ manifest.PROJECTION_FILENAME, projection_bytes, .{});

    const tar_contents = try std.testing.allocator.dupe(u8, buffer.written());
    defer std.testing.allocator.free(tar_contents);
    var pkg_file_handle = try std.Io.Dir.createFileAbsolute(p.currentIo(), pkg_path, .{});
    defer pkg_file_handle.close(p.currentIo());
    try pkg_file_handle.writeStreamingAll(p.currentIo(), tar_contents);

    // Set signing key in context to enable bootstrap
    const repo_name = "import";
    ctx.signing_key_path = secret_key_path;

    // This should succeed (the code handles both "manifest.v1" and "./manifest.v1" paths)
    const single = [_][]const u8{pkg_path};
    try packages(&ctx, repo_name, single[0..], false);

    // Verify the package was imported (repo is at ${root}/mere/dev/repo/import/)
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mere", "dev", "repo", repo_name });
    defer std.testing.allocator.free(repo_dir);
    var repo = try Repository.init(&ctx, repo_dir, false);
    defer repo.deinit();

    const check_pkg_sql = "SELECT name FROM packages WHERE name = ?;";
    const stmt = try repo.db.prepareStatement(check_pkg_sql);
    if (stmt != null) {
        defer _ = c.sqlite3_finalize(@ptrCast(stmt));
        _ = c.sqlite3_bind_text(@ptrCast(stmt), 1, @ptrCast(pkg_name.ptr), @intCast(pkg_name.len), c.SQLITE_STATIC);
        try std.testing.expect(c.sqlite3_step(@ptrCast(stmt)) == c.SQLITE_ROW);
    }
}

test "packages prevents SQL injection" {
    const th = @import("test_helpers.zig");
    const archive_mod = @import("archive.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;

    // SQL injection payload in package name
    const inj_name = "test'); DROP TABLE packages; --";

    // Create a content directory to compute hash from (empty package, just manifest)
    const content_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "pkg_content" });
    defer std.testing.allocator.free(content_dir);
    try p.ensureDirExists(content_dir);

    // Compute the content hash of the empty content directory
    const content_hash_hex = try hash.calculateStoreContentHash(ctx.allocator, content_dir, null);
    defer ctx.allocator.free(content_hash_hex);

    // Parse content hash hex to bytes
    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex) catch unreachable;

    // Use the default key created by createTestEnv() at ~/.mere/keys/mere.key
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys", "mere.key" });
    defer std.testing.allocator.free(secret_key_path);
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);

    // Create manifest with SQL injection payload as package name
    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = @intCast(std.Io.Clock.real.now(p.currentIo()).toSeconds()),
        .release = 1,
        .arch = "x86_64",
        .name = inj_name,
        .version = "1.0.0",
        .content_hash = content_hash_bytes,
    };

    // Use writeManifest to create both manifest.v1 and manifest.v1.sig
    try manifest.writeManifest(&ctx, content_dir, &pkg_manifest, &secret_key.key);
    var projection = try projection_index.deriveFromPayload(ctx.allocator, content_dir);
    defer projection.deinit();
    try projection_index.writeFile(ctx.allocator, content_dir, &projection);

    // Create package archive using libarchive
    const pkg_file = "sql-inject.tar";
    const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, pkg_file });
    defer std.testing.allocator.free(pkg_path);

    try archive_mod.createPackageArchive(&ctx, content_dir, pkg_path);

    // Create test database
    // Repo will be created at ${root}/mere/dev/repo/import/ via bootstrap
    const repo_name = "import";

    // Set signing key in context to enable bootstrap
    ctx.signing_key_path = secret_key_path;

    // Import the package (should not execute injected SQL)
    const single = [_][]const u8{pkg_path};
    try packages(&ctx, repo_name, single[0..], false);

    // Verify the packages table still exists and the injected name is present as data
    // Repo is at ${root}/mere/dev/repo/import/
    const repo_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "mere", "dev", "repo", repo_name });
    defer std.testing.allocator.free(repo_dir);
    var repo = try Repository.init(&ctx, repo_dir, false);
    defer repo.deinit();

    // Open RepoDB for queries
    const db = repo.db;

    const check_sql = "SELECT name FROM packages WHERE name = ?;";
    const stmt = try db.prepareStatement(check_sql);
    if (stmt != null) {
        defer _ = c.sqlite3_finalize(@ptrCast(stmt));
        _ = c.sqlite3_bind_text(@ptrCast(stmt), 1, @ptrCast(inj_name.ptr), @intCast(inj_name.len), c.SQLITE_STATIC);
        try std.testing.expect(c.sqlite3_step(@ptrCast(stmt)) == c.SQLITE_ROW);
        const stored_name = std.mem.span(@as([*c]const u8, c.sqlite3_column_text(@ptrCast(stmt), 0)));
        try std.testing.expectEqualStrings(inj_name, stored_name);
    }
}

test "packages allows older created_at during dev import when force-replacing" {
    const th = @import("test_helpers.zig");
    const archive_mod = @import("archive.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;
    const pkg_name = "rollback-test-pkg";

    // Create secret key for signing
    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys", "mere.key" });
    defer std.testing.allocator.free(secret_key_path);
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);

    // Helper to create a package with a specific timestamp
    const createPackageWithTimestamp = struct {
        fn create(
            ctx_inner: *Context,
            env: *th.TestEnv,
            name: []const u8,
            version: []const u8,
            created_at: u64,
            key: *const sign.SecretKey,
        ) ![]const u8 {
            const content_dir = try std.fs.path.join(std.testing.allocator, &.{ env.path, "pkg_content_rollback" });
            defer std.testing.allocator.free(content_dir);
            try p.ensureDirExists(content_dir);
            defer {
                if (std.fs.path.dirname(content_dir)) |parent_path| {
                    if (p.openExistingDir(parent_path) catch null) |parent_dir| {
                        var dir = parent_dir;
                        defer dir.close(p.currentIo());
                        dir.deleteTree(p.currentIo(), std.fs.path.basename(content_dir)) catch {};
                    }
                }
            }

            // Compute content hash
            const content_hash_hex = try hash.calculateStoreContentHash(ctx_inner.allocator, content_dir, null);
            defer ctx_inner.allocator.free(content_hash_hex);

            var content_hash_bytes: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex) catch unreachable;

            // Create manifest
            const pkg_manifest = manifest.PackageManifestV1{
                .schema_version = 1,
                .created_at = created_at,
                .release = 1,
                .arch = "x86_64",
                .name = name,
                .version = version,
                .content_hash = content_hash_bytes,
            };

            try manifest.writeManifest(ctx_inner, content_dir, &pkg_manifest, &key.key);
            var projection = try projection_index.deriveFromPayload(ctx_inner.allocator, content_dir);
            defer projection.deinit();
            try projection_index.writeFile(ctx_inner.allocator, content_dir, &projection);

            // Create archive
            const pkg_file = try std.fmt.allocPrint(std.testing.allocator, "{s}.tar", .{name});
            defer std.testing.allocator.free(pkg_file);

            const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ env.path, pkg_file });
            errdefer std.testing.allocator.free(pkg_path);

            try archive_mod.createPackageArchive(ctx_inner, content_dir, pkg_path);
            return pkg_path;
        }
    }.create;

    const repo_name = "import";
    ctx.signing_key_path = secret_key_path;

    // Import v2 (newer timestamp)
    const v2_timestamp: u64 = 2000;
    const v2_path = try createPackageWithTimestamp(&ctx, test_env, pkg_name, "1.0.0", v2_timestamp, &secret_key);
    defer std.testing.allocator.free(v2_path);

    const v2_single = [_][]const u8{v2_path};
    try packages(&ctx, repo_name, v2_single[0..], false);
    ctx.debug("imported v2", .{});

    // Import v1 (older timestamp) with force replacement - should succeed
    const v1_timestamp: u64 = 1000;
    const v1_path = try createPackageWithTimestamp(&ctx, test_env, pkg_name, "1.0.0", v1_timestamp, &secret_key);
    defer std.testing.allocator.free(v1_path);

    const v1_single = [_][]const u8{v1_path};
    try packages(&ctx, repo_name, v1_single[0..], true);

    // Import v3 (even newer) - should succeed
    const v3_timestamp: u64 = 3000;
    const v3_path = try createPackageWithTimestamp(&ctx, test_env, pkg_name, "1.0.0", v3_timestamp, &secret_key);
    defer std.testing.allocator.free(v3_path);

    const v3_single = [_][]const u8{v3_path};
    try packages(&ctx, repo_name, v3_single[0..], true);
}

test "packages rejects missing projection.v1" {
    const th = @import("test_helpers.zig");
    const archive_mod = @import("archive.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const pkg_name = "missing-projection-test";

    const content_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "pkg_content_missing_projection" });
    defer std.testing.allocator.free(content_dir);
    try p.ensureDirExists(content_dir);

    const dummy_path = try std.fs.path.join(std.testing.allocator, &.{ content_dir, "dummy.txt" });
    defer std.testing.allocator.free(dummy_path);
    var dummy_file = try std.Io.Dir.createFileAbsolute(p.currentIo(), dummy_path, .{});
    defer dummy_file.close(p.currentIo());
    try dummy_file.writeStreamingAll(p.currentIo(), "content");

    const content_hash_hex = try hash.calculateStoreContentHash(test_env.ctx.allocator, content_dir, null);
    defer test_env.ctx.allocator.free(content_hash_hex);

    var content_hash_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash_hex) catch unreachable;

    const secret_key_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, ".mere", "keys", "mere.key" });
    defer std.testing.allocator.free(secret_key_path);
    const secret_key = try sign.SecretKey.loadFromFile(secret_key_path);

    const pkg_manifest = manifest.PackageManifestV1{
        .schema_version = 1,
        .created_at = @intCast(std.Io.Clock.real.now(p.currentIo()).toSeconds()),
        .release = 1,
        .arch = "x86_64",
        .name = pkg_name,
        .version = "1.0.0",
        .content_hash = content_hash_bytes,
    };
    try manifest.writeManifest(&test_env.ctx, content_dir, &pkg_manifest, &secret_key.key);

    const pkg_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "missing-projection.tar" });
    defer std.testing.allocator.free(pkg_path);
    try archive_mod.createPackageArchive(&test_env.ctx, content_dir, pkg_path);

    test_env.ctx.signing_key_path = secret_key_path;

    const repo_name = "import";
    const single = [_][]const u8{pkg_path};
    try std.testing.expectError(ImportError.InvalidInput, packages(&test_env.ctx, repo_name, single[0..], false));
}
