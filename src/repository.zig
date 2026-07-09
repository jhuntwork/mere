const std = @import("std");
const mere = @import("mere.zig");
const RepoDB = @import("repodb.zig").RepoDB;
const repo_history = @import("repo_history.zig");
const path = @import("path.zig");
const sign = @import("sign.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const Error = Std.OutOfMemory || Std.FileSystem || Std.Network || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData || Std.SignatureInvalid || error{
    PackageImportFailed,
};
pub const Repository = struct {
    ctx: *mere.Context,
    dir_path: []const u8,
    db_path: []const u8,
    sig_path: []const u8,
    db: *RepoDB,

    const ActiveRepoPaths = struct {
        db_path: []const u8,
        sig_path: []const u8,
    };

    fn resolveActiveRepoStatePaths(
        ctx: *mere.Context,
        dir_path: []const u8,
        read_only: bool,
    ) !ActiveRepoPaths {
        const db_path = std.fs.path.join(ctx.allocator, &.{ dir_path, repo_history.REPO_DB_FILENAME }) catch {
            return ctx.fail(Error.OutOfMemory, dir_path, "failed to construct repository db path");
        };
        errdefer ctx.allocator.free(db_path);

        if (read_only) {
            std.Io.Dir.accessAbsolute(path.currentIo(), db_path, .{}) catch {
                return ctx.fail(Error.InvalidInput, dir_path, "repository has no repo.db");
            };
        }

        const sig_path = std.fs.path.join(ctx.allocator, &.{ dir_path, repo_history.REPO_SIG_FILENAME }) catch {
            return ctx.fail(Error.OutOfMemory, dir_path, "failed to construct repository signature path");
        };
        errdefer ctx.allocator.free(sig_path);

        return ActiveRepoPaths{ .db_path = db_path, .sig_path = sig_path };
    }

    pub fn dbPath(self: Repository) []const u8 {
        return self.db_path;
    }

    pub fn sigPath(self: Repository) []const u8 {
        return self.sig_path;
    }

    pub fn signDb(self: Repository) !void {
        const db_path = self.db_path;
        const sig_path = self.sig_path;

        self.ctx.debug("signing DB: db_path={s} sig_path={s}", .{ db_path, sig_path });

        const key_path = sign.resolveSigningKey(self.ctx, null) catch |err| {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.PermissionDenied => Error.PermissionDenied,
                error.FileSystem => Error.FileSystem,
                error.InvalidInput => Error.InvalidInput,
                error.InvalidKey,
                error.VerifyFailed,
                error.SodiumInitFailed,
                => Error.SignatureInvalid,
            };
        };
        defer self.ctx.allocator.free(key_path);
        if (!path.fileExists(key_path)) {
            return Error.SignatureInvalid;
        }

        _ = sign.writeSignatureFileWithResolver(self.ctx, db_path, sig_path, null, null) catch |err| {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.PermissionDenied => Error.PermissionDenied,
                error.FileSystem => Error.FileSystem,
                error.InvalidInput => Error.InvalidInput,
                error.InvalidKey,
                error.VerifyFailed,
                error.SodiumInitFailed,
                => Error.SignatureInvalid,
            };
        };

        self.ctx.debug("database signed successfully: sig_path={s}", .{sig_path});
    }

    pub fn init(ctx: *mere.Context, dir_path: []const u8, read_only: bool) !Repository {
        {
            var dir = (if (read_only)
                path.openExistingDir(dir_path)
            else
                path.makePathAndOpenDir(dir_path)) catch |err| {
                ctx.setDiagnosticContext(dir_path, "failed to open repository directory");
                return switch (err) {
                    error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => Error.PermissionDenied,
                    else => Error.FileSystem,
                };
            };
            dir.close(path.currentIo());
        }
        const active_paths = try resolveActiveRepoStatePaths(ctx, dir_path, read_only);
        errdefer ctx.allocator.free(active_paths.db_path);
        errdefer ctx.allocator.free(active_paths.sig_path);

        // Open RepoDB
        const db = RepoDB.init(ctx, active_paths.db_path, read_only) catch |err| {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.PermissionDenied => Error.PermissionDenied,
                error.InvalidInput => Error.InvalidInput,
                error.CorruptData => Error.CorruptData,
                error.SignatureInvalid => Error.SignatureInvalid,
                else => ctx.fail(Error.FileSystem, active_paths.db_path, "failed to open repository database"),
            };
        };
        return Repository{
            .ctx = ctx,
            .dir_path = dir_path,
            .db_path = active_paths.db_path,
            .sig_path = active_paths.sig_path,
            .db = db,
        };
    }

    /// Opens a read-only Repository whose repo.db content has already been
    /// verified by the caller (bytes come from sign.verifyWithTrustedFingerprints),
    /// instead of reopening dir_path's repo.db from disk. See
    /// RepoDB.initFromVerifiedBytes for why this matters.
    pub fn initFromVerifiedBytes(ctx: *mere.Context, dir_path: []const u8, bytes: []const u8) !Repository {
        const active_paths = try resolveActiveRepoStatePaths(ctx, dir_path, true);
        errdefer ctx.allocator.free(active_paths.db_path);
        errdefer ctx.allocator.free(active_paths.sig_path);

        const db = RepoDB.initFromVerifiedBytes(ctx, active_paths.db_path, bytes) catch |err| {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.PermissionDenied => Error.PermissionDenied,
                error.InvalidInput => Error.InvalidInput,
                error.CorruptData => Error.CorruptData,
                error.SignatureInvalid => Error.SignatureInvalid,
                else => ctx.fail(Error.FileSystem, active_paths.db_path, "failed to open repository database from verified bytes"),
            };
        };
        return Repository{
            .ctx = ctx,
            .dir_path = dir_path,
            .db_path = active_paths.db_path,
            .sig_path = active_paths.sig_path,
            .db = db,
        };
    }

    pub fn deinit(self: *Repository) void {
        self.db.deinit();
        self.ctx.allocator.destroy(self.db);
        self.ctx.allocator.free(self.db_path);
        self.ctx.allocator.free(self.sig_path);
    }
};

test "Repository.dbPath and sigPath" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;
    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "repo" });
    defer ctx.allocator.free(repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    const db_path = repo.dbPath();
    try std.testing.expect(std.mem.endsWith(u8, db_path, ".db"));

    const sig_path = repo.sigPath();
    try std.testing.expect(std.mem.endsWith(u8, sig_path, ".db.sig"));
}

test "Repository.init resolves db and sig paths with flat layout" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;
    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "repo-gen" });
    defer ctx.allocator.free(repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    try std.testing.expect(std.mem.endsWith(u8, repo.dbPath(), "/repo.db"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, repo.dbPath(), 1, "/current/"));
}

test "Repository.signDb creates signature file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = &test_env.ctx;
    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "repo" });
    defer ctx.allocator.free(repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    // Create a dummy db file
    const db_path = repo.dbPath();
    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), db_path, .{});
        try f.writeStreamingAll(path.currentIo(), "dummy db");
        f.close(path.currentIo());
    }

    // Generate a keypair for signing
    const keypair = try sign.generateKeyPair();
    const secret_key_path = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "test.key" });
    defer ctx.allocator.free(secret_key_path);
    try keypair.secret_key.saveToFile(secret_key_path);

    // Ensure the repository signing uses the test key we just created.
    ctx.signing_key_path = secret_key_path;

    // Sign the DB
    try repo.signDb();

    // Check that the signature file exists
    const sig_path = repo.sigPath();
    const sig_file = try std.Io.Dir.openFileAbsolute(path.currentIo(), sig_path, .{});
    defer sig_file.close(path.currentIo());
    var sig_buf: [128]u8 = undefined;
    const sig_n = try sig_file.readPositionalAll(path.currentIo(), &sig_buf, 0);
    try std.testing.expect(sig_n > 0);
}

test "Repository error handling - SignatureInvalid errors" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "repo" });
    defer ctx.allocator.free(repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    // Create a dummy db file for signing
    const db_path = repo.dbPath();
    {
        const f = try std.Io.Dir.createFileAbsolute(path.currentIo(), db_path, .{});
        try f.writeStreamingAll(path.currentIo(), "dummy db");
        f.close(path.currentIo());
    }

    // Test SignatureInvalid error when signing fails (non-existent signing key)
    const nonexistent_key_path = try std.fs.path.join(ctx.allocator, &.{ repo_dir, "nonexistent.key" });
    defer ctx.allocator.free(nonexistent_key_path);
    ctx.signing_key_path = nonexistent_key_path; // Set to non-existent key to force failure

    const result = repo.signDb();
    try std.testing.expectError(Error.SignatureInvalid, result);
}

test "Repository.init uses flat layout for all repos" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    const repo_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "dev", "repo", "sample" });
    defer ctx.allocator.free(repo_dir);

    var repo = try Repository.init(ctx, repo_dir, false);
    defer repo.deinit();

    try std.testing.expect(std.mem.endsWith(u8, repo.dbPath(), repo_history.REPO_DB_FILENAME));
    try std.testing.expect(!std.mem.containsAtLeast(u8, repo.dbPath(), 1, "/current/"));
}

test "Repository.init read-only does not create missing directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;
    const missing_repo_dir = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "missing-repo-dir" });
    defer ctx.allocator.free(missing_repo_dir);

    try std.testing.expectError(Error.FileSystem, Repository.init(ctx, missing_repo_dir, true));
    try std.testing.expectError(error.FileNotFound, path.openExistingDir(missing_repo_dir));
}
