/// Packaging module: creates signed package artifacts from staged payloads.
const std = @import("std");
const mere = @import("mere.zig");
const recipe = @import("recipe.zig");
const package = @import("package.zig");
const hash = @import("hash.zig");
const archive = @import("archive.zig");
const extract = @import("extract.zig");
const sign = @import("sign.zig");
const manifest = @import("manifest.zig");
const meta = @import("meta.zig");
const projection_index = @import("projection_index.zig");
const path_mod = @import("path.zig");
const path_safety = @import("path_safety.zig");
const errors = @import("errors.zig");

/// Packaging error set.
const Std = errors.StandardErrors;
pub const PackagingError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput || Std.SignatureInvalid || error{
    CreationFailed,
    SigningFailed,
    SymlinkEscapesBoundary,
};

/// Configuration for creating a package artifact
pub const PackageArtifactConfig = struct {
    /// Directory containing the files to be packaged (staging directory)
    staging_dir: []const u8,
    /// Recipe information for metadata
    recipe: *recipe.Recipe,
    /// Build artifact being packaged
    artifact: *recipe.BuildArtifact,
    /// Output directory where archive files will be created
    output_dir: []const u8,
    /// Optional additional dependencies to inject into generated meta.kdl.
    injected_dependencies: []const InjectedDependency = &.{},
};

pub const InjectedDependency = struct {
    dep_type: meta.DependencyType,
    value: []const u8,
    version_constraint: ?[]const u8 = null,
};

/// Result of package artifact creation
pub const PackageArtifactResult = struct {
    /// Path to the created archive file
    archive_path: []const u8,
    /// Content hash of the package
    content_hash: []const u8,
    /// Hash of the full package archive bytes
    archive_hash: []const u8,
    /// Raw manifest signature for the package
    signature: []const u8,
    /// Package name used in archive filename
    package_name: []const u8,
    /// Deduplication work performed before hashing and archiving.
    deduplication: archive.DeduplicationStats = .{},

    const Self = @This();

    /// Free buffers owned by this result using the allocator that created them.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.archive_path);
        allocator.free(self.content_hash);
        allocator.free(self.archive_hash);
        allocator.free(self.signature);
        allocator.free(self.package_name);
    }
};

/// Packager for creating package artifacts with metadata and signing
pub const Packager = struct {
    ctx: *mere.Context,

    const Self = @This();

    fn fail(self: *Self, subject: []const u8, details: []const u8, err: PackagingError) PackagingError {
        return self.ctx.fail(err, subject, details);
    }

    /// Initialize packager
    pub fn init(ctx: *mere.Context) Self {
        return Self{
            .ctx = ctx,
        };
    }

    /// Create a complete package artifact with metadata and signing.
    pub fn createPackageArtifact(self: *Self, config: PackageArtifactConfig) !PackageArtifactResult {
        const io = path_mod.currentIo();
        if (config.staging_dir.len == 0 or config.output_dir.len == 0) {
            return self.fail("package_artifact_config", "staging_dir or output_dir is empty", PackagingError.InvalidInput);
        }

        // Reject payload symlinks that escape the package boundary.
        path_safety.validateStorePayload(self.ctx.allocator, config.staging_dir) catch |err| {
            self.ctx.debug("symlink validation failed in staging dir: {}", .{err});
            return self.ctx.fail(switch (err) {
                path_safety.PathSafetyError.EscapesBoundary => PackagingError.SymlinkEscapesBoundary,
                path_safety.PathSafetyError.SymlinkLoop => PackagingError.InvalidInput,
                path_safety.PathSafetyError.ChainTooDeep => PackagingError.InvalidInput,
                path_safety.PathSafetyError.InvalidSymlink => PackagingError.InvalidInput,
                path_safety.PathSafetyError.InvalidInput => PackagingError.InvalidInput,
                path_safety.PathSafetyError.FileSystem => PackagingError.FileSystem,
                path_safety.PathSafetyError.OutOfMemory => PackagingError.OutOfMemory,
            }, config.staging_dir, "symlink validation failed");
        };

        // Deduplicate before hashing so the manifest content_hash matches
        // what import will compute after extracting the archive.
        const deduplication = archive.deduplicate(self.ctx, config.staging_dir) catch {
            return self.fail(config.staging_dir, "failed to deduplicate staging directory", PackagingError.CreationFailed);
        };

        const content_hash = hash.calculateStoreContentHash(self.ctx.allocator, config.staging_dir, null) catch {
            return self.fail(config.staging_dir, "failed to compute content hash", PackagingError.CreationFailed);
        };

        var pkg = package.Package.init(self.ctx);
        defer pkg.deinit();
        // Set arch from recipe for the dependency scan (target_arch filtering).
        // This will be replaced by the inferred arch after scanning.
        if (config.recipe.arch) |arch| {
            pkg.arch = self.ctx.allocator.dupe(u8, arch) catch |err| {
                self.ctx.allocator.free(content_hash);
                return self.fail(arch, "failed to copy architecture", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
            };
        } else {
            pkg.arch = self.ctx.allocator.dupe(u8, "any") catch |err| {
                self.ctx.allocator.free(content_hash);
                return self.fail("any", "failed to copy architecture", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
            };
        }
        pkg.scanDirectory(config.staging_dir) catch |err| {
            self.ctx.allocator.free(content_hash);
            const diag = self.ctx.getDiagnosticContext();
            if (diag.subject != null or diag.details != null) {
                return PackagingError.CreationFailed;
            }
            return self.ctx.failFmt(
                PackagingError.CreationFailed,
                config.staging_dir,
                "failed to scan staging directory ({s})",
                .{@errorName(err)},
            );
        };

        // Determine final package arch: explicit override > ELF inference > "any"
        {
            const final_arch = if (config.artifact.arch) |override|
                override
            else
                package.inferArch(self.ctx, config.staging_dir) catch |err| {
                    self.ctx.allocator.free(content_hash);
                    const diag = self.ctx.getDiagnosticContext();
                    if (diag.subject != null or diag.details != null) {
                        return PackagingError.CreationFailed;
                    }
                    return self.ctx.failFmt(
                        PackagingError.CreationFailed,
                        config.staging_dir,
                        "failed to infer package architecture ({s})",
                        .{@errorName(err)},
                    );
                };
            if (pkg.arch) |old| self.ctx.allocator.free(old);
            pkg.arch = self.ctx.allocator.dupe(u8, final_arch) catch |err| {
                self.ctx.allocator.free(content_hash);
                return self.fail(final_arch, "failed to copy inferred architecture", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
            };
        }

        if (pkg.content_hash.len == 0) {
            pkg.content_hash = self.ctx.allocator.dupe(u8, content_hash) catch |err| {
                self.ctx.allocator.free(content_hash);
                return self.fail(config.staging_dir, "failed to copy content hash", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
            };
        }

        const pkg_name = if (config.artifact.name.len > 0) config.artifact.name else config.recipe.name;
        if (pkg.name == null) {
            pkg.name = self.ctx.allocator.dupe(u8, pkg_name) catch |err| {
                self.ctx.allocator.free(content_hash);
                return self.fail(pkg_name, "failed to copy package name", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
            };
        }
        if (pkg.version == null) {
            pkg.version = self.ctx.allocator.dupe(u8, config.recipe.version) catch |err| {
                self.ctx.allocator.free(content_hash);
                return self.fail(config.recipe.version, "failed to copy package version", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
            };
        }
        if (pkg.release == null) {
            pkg.release = config.recipe.release;
        }

        const mere_dir = std.fmt.allocPrint(self.ctx.allocator, "{s}/{s}", .{ config.staging_dir, manifest.META_DIR }) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.staging_dir, "failed to build .mere directory path", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        defer self.ctx.allocator.free(mere_dir);
        path_mod.ensureDirExists(mere_dir) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(mere_dir, "failed to create .mere directory", PackagingError.FileSystem);
        };

        var content_hash_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&content_hash_bytes, content_hash) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(content_hash, "invalid content hash hex", PackagingError.InvalidInput);
        };

        const pkg_manifest = manifest.PackageManifestV1{
            .schema_version = manifest.SCHEMA_VERSION,
            .created_at = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds()),
            .release = pkg.release orelse 1,
            .arch = pkg.arch orelse "any",
            .name = pkg.name orelse pkg_name,
            .version = pkg.version orelse config.recipe.version,
            .content_hash = content_hash_bytes,
        };

        const manifest_data = pkg_manifest.encode(self.ctx.allocator) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(mere_dir, "failed to encode manifest", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        defer self.ctx.allocator.free(manifest_data);

        const manifest_path = std.fmt.allocPrint(self.ctx.allocator, "{s}/{s}", .{ config.staging_dir, manifest.MANIFEST_FILENAME }) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.staging_dir, "failed to build manifest path", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        defer self.ctx.allocator.free(manifest_path);

        var manifest_file = std.Io.Dir.createFileAbsolute(io, manifest_path, .{}) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(manifest_path, "failed to create manifest file", PackagingError.FileSystem);
        };
        defer manifest_file.close(io);
        manifest_file.writeStreamingAll(io, manifest_data) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(manifest_path, "failed to write manifest", PackagingError.FileSystem);
        };

        const secret_key_path = self.ctx.signing_key_path orelse blk: {
            if (self.ctx.home_dir) |home| {
                break :blk std.fmt.allocPrint(self.ctx.allocator, "{s}/.mere/keys/mere.key", .{home}) catch |err| {
                    self.ctx.allocator.free(content_hash);
                    return self.fail(home, "failed to build default signing key path", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
                };
            } else {
                self.ctx.allocator.free(content_hash);
                return self.fail("signing_key_path", "no home_dir configured", PackagingError.SigningFailed);
            }
        };
        const owns_key_path = self.ctx.signing_key_path == null;
        defer if (owns_key_path) self.ctx.allocator.free(secret_key_path);

        const secret_key = sign.SecretKey.loadFromFile(secret_key_path) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(secret_key_path, "failed to load secret key", PackagingError.SigningFailed);
        };

        const signature = sign.signBytes(secret_key.key[0..], manifest_data) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(secret_key_path, "failed to sign manifest", PackagingError.SigningFailed);
        };

        const manifest_sig_path = std.fmt.allocPrint(self.ctx.allocator, "{s}/{s}", .{ config.staging_dir, manifest.MANIFEST_SIG_FILENAME }) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.staging_dir, "failed to build manifest signature path", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        defer self.ctx.allocator.free(manifest_sig_path);

        var sig_file = std.Io.Dir.createFileAbsolute(io, manifest_sig_path, .{}) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(manifest_sig_path, "failed to create manifest sig file", PackagingError.FileSystem);
        };
        defer sig_file.close(io);
        sig_file.writeStreamingAll(io, &signature) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(manifest_sig_path, "failed to write manifest signature", PackagingError.FileSystem);
        };

        var pkg_meta = meta.Data.init(self.ctx.allocator);
        defer pkg_meta.deinit();

        pkg_meta.populateFromPackage(pkg) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.staging_dir, "failed to populate meta from package", PackagingError.CreationFailed);
        };
        for (config.injected_dependencies) |dep| {
            pkg_meta.addDependencyWithConstraint(dep.dep_type, dep.value, dep.version_constraint) catch {
                self.ctx.allocator.free(content_hash);
                return self.fail(config.staging_dir, "failed to inject package dependency metadata", PackagingError.CreationFailed);
            };
        }

        meta.writeFile(self.ctx.allocator, config.staging_dir, &pkg_meta) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.staging_dir, "failed to write meta.kdl", PackagingError.FileSystem);
        };

        var projection = projection_index.deriveFromPayload(self.ctx.allocator, config.staging_dir) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(
                config.staging_dir,
                "failed to derive projection.v1",
                switch (err) {
                    projection_index.ProjectionError.OutOfMemory => PackagingError.OutOfMemory,
                    projection_index.ProjectionError.PermissionDenied => PackagingError.FileSystem,
                    projection_index.ProjectionError.InvalidInput => PackagingError.InvalidInput,
                    projection_index.ProjectionError.FileSystem => PackagingError.FileSystem,
                },
            );
        };
        defer projection.deinit();

        projection_index.writeFile(self.ctx.allocator, config.staging_dir, &projection) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(
                config.staging_dir,
                "failed to write projection.v1",
                switch (err) {
                    projection_index.ProjectionError.OutOfMemory => PackagingError.OutOfMemory,
                    projection_index.ProjectionError.PermissionDenied => PackagingError.FileSystem,
                    projection_index.ProjectionError.InvalidInput => PackagingError.InvalidInput,
                    projection_index.ProjectionError.FileSystem => PackagingError.FileSystem,
                },
            );
        };

        projection_index.validateAgainstPayload(self.ctx.allocator, config.staging_dir, &projection) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(
                config.staging_dir,
                "projection.v1 does not match staged payload",
                switch (err) {
                    projection_index.ProjectionError.OutOfMemory => PackagingError.OutOfMemory,
                    projection_index.ProjectionError.PermissionDenied => PackagingError.FileSystem,
                    projection_index.ProjectionError.InvalidInput => PackagingError.InvalidInput,
                    projection_index.ProjectionError.FileSystem => PackagingError.FileSystem,
                },
            );
        };

        const archive_temp = std.fmt.allocPrint(self.ctx.allocator, "{s}/{s}-{s}-{d}-{s}.pkg.tmp.tar.zst", .{
            config.output_dir,
            pkg.name orelse pkg_name,
            pkg.version orelse config.recipe.version,
            pkg.release orelse 1,
            pkg.arch orelse "any",
        }) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.output_dir, "failed to build temporary archive path", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        defer self.ctx.allocator.free(archive_temp);

        archive.createPackageArchive(self.ctx, config.staging_dir, archive_temp) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.staging_dir, "failed to create package artifact", PackagingError.CreationFailed);
        };

        const archive_hash = hash.calculateFileHash(self.ctx, archive_temp) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(archive_temp, "failed to compute archive hash", PackagingError.CreationFailed);
        };
        errdefer self.ctx.allocator.free(archive_hash);

        pkg.archive_hash = self.ctx.allocator.dupe(u8, archive_hash) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(archive_hash, "failed to copy archive hash", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };

        const archive_file_name = pkg.canonicalArchiveName() catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(pkg_name, "failed to build archive filename", PackagingError.InvalidInput);
        };
        defer self.ctx.allocator.free(archive_file_name);

        const archive_final = std.fmt.allocPrint(self.ctx.allocator, "{s}/{s}", .{ config.output_dir, archive_file_name }) catch |err| {
            self.ctx.allocator.free(content_hash);
            return self.fail(config.output_dir, "failed to build output archive path", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        errdefer self.ctx.allocator.free(archive_final);

        std.Io.Dir.renameAbsolute(archive_temp, archive_final, io) catch {
            self.ctx.allocator.free(content_hash);
            return self.fail(archive_final, "failed to finalize package archive path", PackagingError.FileSystem);
        };

        const result_package_name = self.ctx.allocator.dupe(u8, pkg_name) catch |err| {
            self.ctx.allocator.free(content_hash);
            self.ctx.allocator.free(archive_hash);
            return self.fail(pkg_name, "failed to copy package name", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        errdefer self.ctx.allocator.free(result_package_name);

        const result_signature = self.ctx.allocator.dupe(u8, &signature) catch |err| {
            self.ctx.allocator.free(content_hash);
            self.ctx.allocator.free(archive_hash);
            return self.fail("manifest signature", "failed to copy package signature", if (err == error.OutOfMemory) PackagingError.OutOfMemory else PackagingError.CreationFailed);
        };
        errdefer self.ctx.allocator.free(result_signature);

        return PackageArtifactResult{
            .archive_path = archive_final,
            .content_hash = content_hash,
            .archive_hash = archive_hash,
            .signature = result_signature,
            .package_name = result_package_name,
            .deduplication = deduplication,
        };
    }
};

// Tests
const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "Packager creates package artifacts with metadata independently" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Generate a test keypair and set the signing key path
    const keys_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ keys_dir, "mere.key" });
    defer test_env.ctx.allocator.free(key_path);

    const key_pair = try sign.generateKeyPair();
    try key_pair.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    // Create a Packager
    var packager = Packager{ .ctx = &test_env.ctx };

    // Create a staging directory with a test file
    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging" });
    defer test_env.ctx.allocator.free(staging_dir);
    try path_mod.ensureDirExists(staging_dir);

    const test_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "test_file.txt" });
    defer test_env.ctx.allocator.free(test_file_path);
    const test_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file_path, .{});
    defer test_file.close(path_mod.currentIo());
    try test_file.writeStreamingAll(path_mod.currentIo(), "test content");

    // Prepare a Recipe and BuildArtifact (createPackage expects pointers)
    var test_recipe = try recipe.Recipe.init(test_env.ctx.allocator, &test_env.ctx);
    defer test_recipe.deinit();
    test_recipe.name = try test_env.ctx.allocator.dupe(u8, "test-package");
    test_recipe.version = try test_env.ctx.allocator.dupe(u8, "1.0.0");
    test_recipe.release = 1;

    var test_artifact = try recipe.BuildArtifact.init(test_env.ctx.allocator);
    defer test_artifact.deinit(test_env.ctx.allocator);

    // Test creating a package
    var result = try packager.createPackageArtifact(.{
        .staging_dir = staging_dir,
        .recipe = &test_recipe,
        .artifact = &test_artifact,
        .output_dir = test_env.path,
    });
    // Use the result.deinit to free all owned buffers consistently
    defer result.deinit(test_env.ctx.allocator);

    // Verify the result
    try std.testing.expectStringEndsWith(result.archive_path, ".pkg.tar.zst");
    try std.testing.expect(result.content_hash.len > 0);

    // Verify archive exists
    var _f = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.archive_path, .{});
    defer _f.close(path_mod.currentIo());

    // Verify manifest.v1.sig exists in staging (was written before archiving)
    const manifest_sig_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, manifest.MANIFEST_SIG_FILENAME });
    defer test_env.ctx.allocator.free(manifest_sig_path);
    var _sigf = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), manifest_sig_path, .{});
    defer _sigf.close(path_mod.currentIo());

    const projection_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, manifest.PROJECTION_FILENAME });
    defer test_env.ctx.allocator.free(projection_path);
    var _projf = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), projection_path, .{});
    defer _projf.close(path_mod.currentIo());
}

test "Packager handles signing and metadata generation" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Generate a test keypair and set the signing key path
    const keys_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ keys_dir, "mere.key" });
    defer test_env.ctx.allocator.free(key_path);

    const key_pair = try sign.generateKeyPair();
    try key_pair.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    var packager = Packager{ .ctx = &test_env.ctx };

    // Create recipe with architecture
    var test_recipe = try recipe.Recipe.init(test_env.ctx.allocator, &test_env.ctx);
    defer test_recipe.deinit();

    // Properly allocate recipe fields since Recipe.deinit() will free them
    test_recipe.name = try test_env.ctx.allocator.dupe(u8, "arch-package");
    test_recipe.version = try test_env.ctx.allocator.dupe(u8, "2.1.0");
    test_recipe.release = 3;
    test_recipe.arch = "x86_64"; // This is a string literal reference, not allocated

    var test_artifact = try recipe.BuildArtifact.init(test_env.ctx.allocator);
    defer test_artifact.deinit(test_env.ctx.allocator);
    // Properly allocate the name since BuildArtifact.deinit() will free it
    test_artifact.name = try test_env.ctx.allocator.dupe(u8, "custom-name");

    // Create staging directory with content
    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging2" });
    defer test_env.ctx.allocator.free(staging_dir);
    try path_mod.ensureDirExists(staging_dir);

    const content_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "content.dat" });
    defer test_env.ctx.allocator.free(content_file_path);
    var content_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), content_file_path, .{});
    defer content_file.close(path_mod.currentIo());
    try content_file.writeStreamingAll(path_mod.currentIo(), "package content for signing");

    var result = try packager.createPackageArtifact(.{
        .staging_dir = staging_dir,
        .recipe = &test_recipe,
        .artifact = &test_artifact,
        .output_dir = test_env.path,
    });
    defer result.deinit(test_env.ctx.allocator);

    // Verify the archive filename format includes architecture + content hash
    // No ELF files in staging, so arch is inferred as "any"
    const expected_filename_prefix = try std.fmt.allocPrint(
        test_env.ctx.allocator,
        "custom-name-2.1.0-3-any-{s}.pkg.tar.zst",
        .{result.archive_hash},
    );
    defer test_env.ctx.allocator.free(expected_filename_prefix);
    const filename = std.fs.path.basename(result.archive_path);
    try testing.expectEqualStrings(expected_filename_prefix, filename);

    // Verify manifest.v1.sig exists in staging (was written before archiving)
    const manifest_sig_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, manifest.MANIFEST_SIG_FILENAME });
    defer test_env.ctx.allocator.free(manifest_sig_path);
    var _sigf = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), manifest_sig_path, .{});
    defer _sigf.close(path_mod.currentIo());
}

test "Packager writes manifest.v1 and final archive" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Generate a test keypair and set the signing key path
    const keys_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ keys_dir, "mere.key" });
    defer test_env.ctx.allocator.free(key_path);

    const key_pair = try sign.generateKeyPair();
    try key_pair.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    var packager = Packager{ .ctx = &test_env.ctx };

    // Create staging directory with a test file
    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging_atomic" });
    defer test_env.ctx.allocator.free(staging_dir);
    try path_mod.ensureDirExists(staging_dir);

    const test_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "file.txt" });
    defer test_env.ctx.allocator.free(test_file_path);
    const test_file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), test_file_path, .{});
    defer test_file.close(path_mod.currentIo());
    try test_file.writeStreamingAll(path_mod.currentIo(), "atomic content");

    // Prepare recipe and artifact
    var test_recipe = try recipe.Recipe.init(test_env.ctx.allocator, &test_env.ctx);
    defer test_recipe.deinit();
    test_recipe.name = try test_env.ctx.allocator.dupe(u8, "atomic-pkg");
    test_recipe.version = try test_env.ctx.allocator.dupe(u8, "0.0.1");
    test_recipe.release = 1;

    var test_artifact = try recipe.BuildArtifact.init(test_env.ctx.allocator);
    defer test_artifact.deinit(test_env.ctx.allocator);
    test_artifact.name = try test_env.ctx.allocator.dupe(u8, "atomic-pkg");

    // Create package (verifies atomic behavior and manifest)
    var result = try packager.createPackageArtifact(.{
        .staging_dir = staging_dir,
        .recipe = &test_recipe,
        .artifact = &test_artifact,
        .output_dir = test_env.path,
    });
    defer result.deinit(test_env.ctx.allocator);

    // Verify .mere/manifest.v1 exists in the staging dir
    const manifest_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/{s}", .{ staging_dir, manifest.MANIFEST_FILENAME });
    defer test_env.ctx.allocator.free(manifest_path);
    var manifest_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), manifest_path, .{});
    defer manifest_file.close(path_mod.currentIo());

    // Verify .mere/manifest.v1.sig exists
    const sig_path = try std.fmt.allocPrint(test_env.ctx.allocator, "{s}/{s}", .{ staging_dir, manifest.MANIFEST_SIG_FILENAME });
    defer test_env.ctx.allocator.free(sig_path);
    var sig_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), sig_path, .{});
    defer sig_file.close(path_mod.currentIo());

    // Verify final archive exists.
    var archive_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), result.archive_path, .{});
    archive_file.close(path_mod.currentIo());
}

test "Packager round-trips duplicate payload files as hard links" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const keys_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "keys" });
    defer test_env.ctx.allocator.free(keys_dir);
    try path_mod.ensureDirExists(keys_dir);

    const key_path = try std.fs.path.join(test_env.ctx.allocator, &.{ keys_dir, "mere.key" });
    defer test_env.ctx.allocator.free(key_path);

    const key_pair = try sign.generateKeyPair();
    try key_pair.secret_key.saveToFile(key_path);
    test_env.ctx.signing_key_path = key_path;

    var packager = Packager{ .ctx = &test_env.ctx };

    const staging_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "staging_hardlinks" });
    defer test_env.ctx.allocator.free(staging_dir);
    try path_mod.ensureDirExists(staging_dir);

    const nested_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "nested" });
    defer test_env.ctx.allocator.free(nested_dir);
    try path_mod.ensureDirExists(nested_dir);

    const duplicate_content = "shared duplicate payload";
    const alpha_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "alpha.txt" });
    defer test_env.ctx.allocator.free(alpha_path);
    const beta_path = try std.fs.path.join(test_env.ctx.allocator, &.{ staging_dir, "beta.txt" });
    defer test_env.ctx.allocator.free(beta_path);
    const gamma_path = try std.fs.path.join(test_env.ctx.allocator, &.{ nested_dir, "gamma.txt" });
    defer test_env.ctx.allocator.free(gamma_path);

    {
        const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), alpha_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), duplicate_content);
    }
    {
        const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), beta_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), duplicate_content);
    }
    {
        const file = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), gamma_path, .{});
        defer file.close(path_mod.currentIo());
        try file.writeStreamingAll(path_mod.currentIo(), duplicate_content);
    }

    var test_recipe = try recipe.Recipe.init(test_env.ctx.allocator, &test_env.ctx);
    defer test_recipe.deinit();
    test_recipe.name = try test_env.ctx.allocator.dupe(u8, "hardlink-pkg");
    test_recipe.version = try test_env.ctx.allocator.dupe(u8, "1.0.0");
    test_recipe.release = 1;

    var test_artifact = try recipe.BuildArtifact.init(test_env.ctx.allocator);
    defer test_artifact.deinit(test_env.ctx.allocator);
    test_artifact.name = try test_env.ctx.allocator.dupe(u8, "hardlink-pkg");

    var result = try packager.createPackageArtifact(.{
        .staging_dir = staging_dir,
        .recipe = &test_recipe,
        .artifact = &test_artifact,
        .output_dir = test_env.path,
    });
    defer result.deinit(test_env.ctx.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.deduplication.groups_deduplicated);
    try std.testing.expectEqual(@as(usize, 2), result.deduplication.files_deduplicated);
    try std.testing.expectEqual(@as(u64, @as(u64, duplicate_content.len) * 2), result.deduplication.bytes_saved);

    const extract_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "extracted_hardlinks" });
    defer test_env.ctx.allocator.free(extract_dir);
    try path_mod.ensureDirExists(extract_dir);

    try extract.into(&test_env.ctx, result.archive_path, extract_dir);

    const extracted_alpha = try std.fs.path.join(test_env.ctx.allocator, &.{ extract_dir, "alpha.txt" });
    defer test_env.ctx.allocator.free(extracted_alpha);
    const extracted_beta = try std.fs.path.join(test_env.ctx.allocator, &.{ extract_dir, "beta.txt" });
    defer test_env.ctx.allocator.free(extracted_beta);
    const extracted_gamma = try std.fs.path.join(test_env.ctx.allocator, &.{ extract_dir, "nested", "gamma.txt" });
    defer test_env.ctx.allocator.free(extracted_gamma);

    const alpha_stat = try std.Io.Dir.cwd().statFile(path_mod.currentIo(), extracted_alpha, .{});
    const beta_stat = try std.Io.Dir.cwd().statFile(path_mod.currentIo(), extracted_beta, .{});
    const gamma_stat = try std.Io.Dir.cwd().statFile(path_mod.currentIo(), extracted_gamma, .{});

    try std.testing.expectEqual(alpha_stat.inode, beta_stat.inode);
    try std.testing.expectEqual(alpha_stat.inode, gamma_stat.inode);

    const alpha_file = try std.Io.Dir.openFileAbsolute(path_mod.currentIo(), extracted_alpha, .{});
    defer alpha_file.close(path_mod.currentIo());
    var buf: [128]u8 = undefined;
    const len = try alpha_file.readPositionalAll(path_mod.currentIo(), &buf, 0);
    try std.testing.expectEqualStrings(duplicate_content, buf[0..len]);
}
