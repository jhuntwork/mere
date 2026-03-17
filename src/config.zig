const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const path = @import("path.zig");
const download = @import("download.zig");
const kdl = @import("kdl.zig");
const kdl_schema = @import("kdl_schema.zig");

const default_sync_ttl_seconds: u64 = 15 * 60;
const default_sync_timeout_seconds: u32 = 30;

/// Repository configuration structure
pub const RepoConfig = struct {
    name: []const u8,
    url: []const u8,
    /// Allowlist of trusted key fingerprints (64-char BLAKE3 hashes of public keys).
    /// Signatures must be verified against keys matching one of these fingerprints.
    trusted_fingerprints: std.ArrayList([]const u8),
    priority: u8 = 100,
    /// Whether this repository is enabled (disabled repos are skipped during install/sync)
    enabled: bool = true,
    /// Sync TTL in seconds (remote repos only; local repos ignore)
    sync_ttl_seconds: u64 = default_sync_ttl_seconds,
    /// Sync timeout in seconds (remote repos only; local repos ignore)
    sync_timeout_seconds: u32 = default_sync_timeout_seconds,
    /// Whether package archives for this repo should be resolved from the
    /// shared local pool (/mere/cache/packages) instead of "<url>/packages".
    archives_from_shared_pool: bool = false,

    /// Free memory allocated for the RepoConfig using the provided allocator.
    pub fn deinit(self: *RepoConfig, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.url.len > 0) allocator.free(self.url);
        // Free each fingerprint string
        for (self.trusted_fingerprints.items) |fp| {
            allocator.free(fp);
        }
        self.trusted_fingerprints.deinit(allocator);
    }

    /// Deep copy this RepoConfig to the given allocator.
    /// Caller owns returned RepoConfig and must call deinit() when done.
    pub fn deepCopy(self: *const RepoConfig, allocator: std.mem.Allocator) !RepoConfig {
        const name_copy = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name_copy);
        const url_copy = try allocator.dupe(u8, self.url);
        errdefer allocator.free(url_copy);

        // Deep copy the fingerprints list
        var fingerprints_copy = std.ArrayList([]const u8){};
        errdefer {
            for (fingerprints_copy.items) |fp| allocator.free(fp);
            fingerprints_copy.deinit(allocator);
        }
        for (self.trusted_fingerprints.items) |fp| {
            const fp_copy = try allocator.dupe(u8, fp);
            try fingerprints_copy.append(allocator, fp_copy);
        }

        return RepoConfig{
            .name = name_copy,
            .url = url_copy,
            .priority = self.priority,
            .enabled = self.enabled,
            .sync_ttl_seconds = self.sync_ttl_seconds,
            .sync_timeout_seconds = self.sync_timeout_seconds,
            .archives_from_shared_pool = self.archives_from_shared_pool,
            .trusted_fingerprints = fingerprints_copy,
        };
    }

    /// Parse a KDL node into a RepoConfig.
    /// Expected format: repo "name" { url "..." trusted-fingerprints "fp1" "fp2" ... priority 100 }
    pub fn fromKdl(
        ctx: *Context,
        node: *const kdl.Node,
        allocator: std.mem.Allocator,
        default_ttl_seconds: u64,
        default_timeout_seconds: u32,
    ) !RepoConfig {
        ctx.debug("parsing repository from kdl", .{});

        // Get name from first argument
        const name = node.getFirstArgString() orelse {
            ctx.debug("missing repo name argument", .{});
            return ctx.fail(error.InvalidConfig, "repo", "missing repo name");
        };

        // Get url from child node (format: url "value")
        const url = node.getChildString("url") orelse {
            ctx.debug("missing 'url' child node", .{});
            return ctx.fail(error.InvalidConfig, name, "missing url");
        };

        // Get optional priority (default 100)
        const priority: u8 = blk: {
            if (node.getChildInt("priority")) |p| {
                if (p < 0 or p > 255) {
                    ctx.debug("priority out of range", .{});
                    return ctx.fail(error.InvalidConfig, name, "priority out of range (expected 0-255)");
                }
                break :blk @intCast(p);
            }
            break :blk 100;
        };

        // Get optional enabled flag (default true)
        const enabled = node.getChildBool("enabled") orelse true;

        // Get optional sync ttl (seconds)
        const sync_ttl_seconds: u64 = blk: {
            if (node.getChildInt("sync-ttl")) |ttl| {
                if (ttl < 0) {
                    return ctx.fail(error.InvalidConfig, name, "sync-ttl must be non-negative");
                }
                break :blk @intCast(ttl);
            }
            break :blk default_ttl_seconds;
        };

        // Get optional sync timeout (seconds)
        const sync_timeout_seconds: u32 = blk: {
            if (node.getChildInt("sync-timeout")) |timeout| {
                if (timeout < 0 or timeout > std.math.maxInt(u32)) {
                    return ctx.fail(error.InvalidConfig, name, "sync-timeout out of range");
                }
                break :blk @intCast(timeout);
            }
            break :blk default_timeout_seconds;
        };

        // Parse trusted fingerprints from child node
        // Format: trusted-fingerprints "fp1" "fp2" ...
        var fingerprints = std.ArrayList([]const u8){};
        errdefer {
            for (fingerprints.items) |fp| allocator.free(fp);
            fingerprints.deinit(allocator);
        }

        if (node.findChild("trusted-fingerprints")) |fp_node| {
            for (fp_node.arguments.items) |arg| {
                if (arg.getString()) |fp_str| {
                    // Validate fingerprint format (64 hex chars)
                    if (fp_str.len != 64) {
                        ctx.debug("invalid fingerprint length: {d} (expected 64)", .{fp_str.len});
                        return ctx.fail(error.InvalidConfig, name, "invalid trusted fingerprint length (expected 64 hex chars)");
                    }
                    for (fp_str) |ch| {
                        if (!std.ascii.isHex(ch)) {
                            ctx.debug("invalid fingerprint character: {c}", .{ch});
                            return ctx.fail(error.InvalidConfig, name, "invalid trusted fingerprint value (expected 64 hex chars)");
                        }
                    }
                    const fp_copy = try allocator.dupe(u8, fp_str);
                    _ = std.ascii.lowerString(fp_copy, fp_copy);
                    try fingerprints.append(allocator, fp_copy);
                }
            }
        }

        // Validate values
        ctx.debug("validating name and url values", .{});
        if (name.len == 0) {
            ctx.debug("name is null or empty", .{});
            return ctx.fail(error.InvalidConfig, "repo", "name is empty");
        }
        if (url.len == 0) {
            ctx.debug("url is null or empty", .{});
            return ctx.fail(error.InvalidConfig, name, "url is empty");
        }

        // Create the RepoConfig using the provided allocator
        ctx.debug("creating repo config with name={s} url={s} priority={d}", .{ name, url, priority });
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);

        const repo_config = RepoConfig{
            .name = name_copy,
            .url = url_copy,
            .priority = priority,
            .enabled = enabled,
            .sync_ttl_seconds = sync_ttl_seconds,
            .sync_timeout_seconds = sync_timeout_seconds,
            .trusted_fingerprints = fingerprints,
        };
        ctx.debug("successfully created repo config with name={s} enabled={}", .{ repo_config.name, repo_config.enabled });
        return repo_config;
    }
};

/// Configuration structure for Mere
///
/// This struct is stored as a value (not a pointer) in Context.configuration,
/// which simplifies memory management and reduces allocations.
///
/// Usage:
/// - Create using Config.init(ctx, alloc) to get an empty configuration.
///   `alloc` is the allocator that will own this Config's internal storage
///   (pass `ctx.allocator` for persistent configs or an arena allocator for
///   transient parsing and merging).
/// - Use loadConfig to populate from files
/// - Modify repos ArrayList directly to add/remove repositories
/// - Always call deinit() to free resources when done
pub const Config = struct {
    repos: std.ArrayList(RepoConfig),
    ctx: *Context,
    alloc: std.mem.Allocator,
    color: ?bool = null,
    /// Default sync TTL for remote repos (seconds)
    sync_ttl_seconds: u64 = default_sync_ttl_seconds,
    /// Default sync timeout for remote repos (seconds)
    sync_timeout_seconds: u32 = default_sync_timeout_seconds,

    /// Initialize a new empty Config.
    /// `alloc` is the allocator that owns this Config's internal storage.
    /// Pass `ctx.allocator` for persistent configs or an arena allocator for transient parsing.
    pub fn init(ctx: *Context, alloc: std.mem.Allocator) Config {
        return Config{
            .repos = std.ArrayList(RepoConfig){},
            .ctx = ctx,
            .alloc = alloc,
            .color = null,
            .sync_ttl_seconds = default_sync_ttl_seconds,
            .sync_timeout_seconds = default_sync_timeout_seconds,
        };
    }

    /// Get filtered and sorted repos
    /// Returns a new ArrayList containing pointers to enabled repos sorted by priority
    /// The caller MUST NOT free the RepoConfig items since they are owned by this Config
    pub fn getFilteredAndSortedRepos(self: *const Config, allocator: std.mem.Allocator) !std.ArrayList(*RepoConfig) {
        var filtered_repos = std.ArrayList(*RepoConfig){};
        errdefer filtered_repos.deinit(allocator); // Only free the list, not the RepoConfig items

        // Filter repos by enabled status
        for (self.repos.items) |*repo_cfg| {
            if (repo_cfg.enabled) {
                try filtered_repos.append(allocator, repo_cfg);
            }
        }

        // Sort by priority (lower values first)
        std.sort.insertion(*RepoConfig, filtered_repos.items, {}, struct {
            fn lessThan(_: void, a: *RepoConfig, b: *RepoConfig) bool {
                return a.priority < b.priority;
            }
        }.lessThan);

        return filtered_repos;
    }

    /// Free memory allocated for the Config
    pub fn deinit(self: *Config) void {
        for (self.repos.items) |*repo| {
            // Each RepoConfig's storage is owned by the Config's allocator.
            repo.deinit(self.alloc);
        }
        self.repos.deinit(self.alloc);
    }

    /// Parse a KDL string into a Config using a specified allocator.
    /// Expected format:
    ///   repo "name" { url "..." priority 100 }
    pub fn fromKdl(ctx: *Context, kdl_str: []const u8, allocator: std.mem.Allocator) !Config {
        var config = Config.init(ctx, allocator);
        errdefer config.deinit();

        var nodes = kdl.parseDocument(allocator, kdl_str) catch |err| {
            switch (err) {
                kdl.KdlError.ParseError => return error.ParseError,
                kdl.KdlError.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidConfig,
            }
        };
        defer {
            for (nodes.items) |*n| n.deinit();
            nodes.deinit(allocator);
        }

        try kdl_schema.validateConfig(ctx, nodes.items);

        // Process global settings first
        for (nodes.items) |*node| {
            if (std.mem.eql(u8, node.name, "settings")) {
                if (node.getChildBool("color")) |color| {
                    config.color = color;
                }
                if (node.getChildInt("sync-ttl")) |ttl| {
                    if (ttl < 0) {
                        return ctx.fail(error.InvalidConfig, "settings", "sync-ttl must be non-negative");
                    }
                    config.sync_ttl_seconds = @intCast(ttl);
                }
                if (node.getChildInt("sync-timeout")) |timeout| {
                    if (timeout < 0 or timeout > std.math.maxInt(u32)) {
                        return ctx.fail(error.InvalidConfig, "settings", "sync-timeout out of range");
                    }
                    config.sync_timeout_seconds = @intCast(timeout);
                }
            }
        }

        // Process all "repo" nodes
        for (nodes.items) |*node| {
            if (std.mem.eql(u8, node.name, "repo")) {
                const repo = try RepoConfig.fromKdl(
                    ctx,
                    node,
                    allocator,
                    config.sync_ttl_seconds,
                    config.sync_timeout_seconds,
                );
                try config.repos.append(allocator, repo);
            }
        }

        return config;
    }

    /// Convert a Config to a KDL string.
    /// Caller owns returned memory and must free with self.alloc.
    pub fn toKdl(self: *const Config) ![]const u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.alloc);
        const writer = buf.writer(self.alloc);

        try writer.writeAll("// Mere Linux configuration\n\n");

        if (self.color != null or self.sync_ttl_seconds != default_sync_ttl_seconds or self.sync_timeout_seconds != default_sync_timeout_seconds) {
            try writer.writeAll("settings {\n");
            if (self.color) |color| {
                try writer.print("    color {}\n", .{color});
            }
            if (self.sync_ttl_seconds != default_sync_ttl_seconds) {
                try writer.print("    sync-ttl {d}\n", .{self.sync_ttl_seconds});
            }
            if (self.sync_timeout_seconds != default_sync_timeout_seconds) {
                try writer.print("    sync-timeout {d}\n", .{self.sync_timeout_seconds});
            }
            try writer.writeAll("}\n\n");
        }

        for (self.repos.items) |repo| {
            try writer.print("repo \"{s}\" {{\n", .{repo.name});
            try writer.print("    url \"{s}\"\n", .{repo.url});
            // Write trusted fingerprints if any
            if (repo.trusted_fingerprints.items.len > 0) {
                try writer.writeAll("    trusted-fingerprints");
                for (repo.trusted_fingerprints.items) |fp| {
                    try writer.print(" \"{s}\"", .{fp});
                }
                try writer.writeAll("\n");
            }
            try writer.print("    priority {d}\n", .{repo.priority});
            if (repo.sync_ttl_seconds != self.sync_ttl_seconds) {
                try writer.print("    sync-ttl {d}\n", .{repo.sync_ttl_seconds});
            }
            if (repo.sync_timeout_seconds != self.sync_timeout_seconds) {
                try writer.print("    sync-timeout {d}\n", .{repo.sync_timeout_seconds});
            }
            // Only write enabled if false (true is the default)
            if (!repo.enabled) {
                try writer.writeAll("    enabled false\n");
            }
            try writer.writeAll("}\n\n");
        }

        return buf.toOwnedSlice(self.alloc);
    }

    /// Add a repository to the config
    pub fn addRepo(self: *Config, repo: RepoConfig) !void {
        // Check if a repo with the same name already exists
        for (self.repos.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.name, repo.name)) {
                // Replace the existing repo
                self.repos.items[i].deinit(self.alloc);
                self.repos.items[i] = repo;
                return;
            }
        }

        // Add the new repo. Use the Config's allocator to ensure ownership is consistent
        try self.repos.append(self.alloc, repo);
    }

    /// Remove a repository from the config by name
    pub fn removeRepo(self: *Config, name: []const u8) bool {
        for (self.repos.items, 0..) |repo, i| {
            if (std.mem.eql(u8, repo.name, name)) {
                var removed = self.repos.orderedRemove(i);
                removed.deinit(self.alloc);
                return true;
            }
        }
        return false;
    }

    /// Merge another config into this one
    /// Repositories in the other config with the same name will override this config's repos
    fn copyRepoToAllocator(_: *const Config, src: *const RepoConfig, allocator: std.mem.Allocator) !RepoConfig {
        const name_copy = try allocator.dupe(u8, src.name);
        errdefer allocator.free(name_copy);
        const url_copy = try allocator.dupe(u8, src.url);
        errdefer allocator.free(url_copy);

        // Deep copy the fingerprints list
        var fingerprints_copy = std.ArrayList([]const u8){};
        errdefer {
            for (fingerprints_copy.items) |fp| allocator.free(fp);
            fingerprints_copy.deinit(allocator);
        }
        for (src.trusted_fingerprints.items) |fp| {
            const fp_copy = try allocator.dupe(u8, fp);
            try fingerprints_copy.append(allocator, fp_copy);
        }

        return RepoConfig{
            .name = name_copy,
            .url = url_copy,
            .priority = src.priority,
            .enabled = src.enabled,
            .sync_ttl_seconds = src.sync_ttl_seconds,
            .sync_timeout_seconds = src.sync_timeout_seconds,
            .trusted_fingerprints = fingerprints_copy,
        };
    }

    pub fn merge(self: *Config, other: *const Config) !void {
        if (other.color) |color| {
            self.color = color;
        }
        // Use this Config's allocator for merge operations to keep ownership consistent.
        return self.mergeWithAllocator(other, self.alloc);
    }

    /// Merge another config into this one using a specified allocator for all allocations
    pub fn mergeWithAllocator(self: *Config, other: *const Config, allocator: std.mem.Allocator) !void {
        self.ctx.debug("merging {d} repos from other config", .{other.repos.items.len});
        for (other.repos.items) |other_repo| {
            self.ctx.debug("merging repo name={s}", .{other_repo.name});
            const repo = try self.copyRepoToAllocator(&other_repo, allocator);
            try self.addRepo(repo);
        }
    }

    /// Deep-copy this config and all its strings to the given allocator.
    /// Caller owns returned Config and must call deinit() when done.
    pub fn deepCopy(self: *const Config, allocator: std.mem.Allocator) !Config {
        var new_config = Config.init(self.ctx, allocator);
        new_config.color = self.color;
        new_config.sync_ttl_seconds = self.sync_ttl_seconds;
        new_config.sync_timeout_seconds = self.sync_timeout_seconds;
        errdefer new_config.deinit();
        for (self.repos.items) |repo| {
            const new_repo = try self.copyRepoToAllocator(&repo, allocator);
            errdefer {
                var r = new_repo;
                r.deinit(allocator);
            }
            try new_config.repos.append(allocator, new_repo);
        }
        return new_config;
    }

    /// Merge another config into this one and validate the result
    pub fn mergeAndValidate(self: *Config, other: *const Config) !void {
        try self.merge(other);
        try self.validate();
    }

    /// Validate the configuration for duplicates and invalid fields
    pub fn validate(self: *const Config) !void {
        self.ctx.debug("validating {d} repos", .{self.repos.items.len});
        var seen = std.StringHashMap(void).init(self.alloc);
        defer seen.deinit();

        for (self.repos.items, 0..) |repo, i| {
            self.ctx.debug("checking repo {d} name={s}", .{ i, repo.name });
            self.ctx.debug("validating unique name", .{});
            if (seen.contains(repo.name)) {
                return self.ctx.fail(error.InvalidConfig, repo.name, "duplicate repository name");
            }
            try seen.put(repo.name, {});
            self.ctx.debug("validating name length", .{});
            if (repo.name.len == 0) {
                return self.ctx.fail(error.InvalidConfig, "", "repository name is empty");
            }
            self.ctx.debug("validating url length", .{});
            if (repo.url.len == 0) {
                return self.ctx.fail(error.InvalidConfig, repo.name, "repository url is empty");
            }
            self.ctx.debug("validating url", .{});
            if (!download.isValidUrl(repo.url)) {
                return self.ctx.fail(error.InvalidConfig, repo.url, "invalid repository url");
            }
            // Fingerprints are validated during parsing (must be 64 hex chars)
        }
        self.ctx.debug("done validating {d} repos", .{self.repos.items.len});
    }
};

/// Get the system config path (/mere/config.kdl).
/// This is the only location for remote repository definitions.
/// Caller owns returned memory and must free with ctx.allocator.
pub fn getSystemConfigPath(ctx: *Context) ![]const u8 {
    return try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "mere", "config.kdl" });
}

/// Get the user preferences config path (~/.config/mere/config.kdl).
/// This file is for user preferences only.
/// It does NOT contain repository definitions - those go in /mere/config.kdl.
/// Caller owns returned memory and must free with ctx.allocator.
pub fn getUserPreferencesPath(ctx: *Context) ![]const u8 {
    const config_dir = path.getDefaultMereConfigDirectory(ctx) catch |err| {
        ctx.debug("failed to get default config directory: {}", .{err});
        return try std.fs.path.join(ctx.allocator, &.{ ctx.root_path, "home", ".config", "mere", "config.kdl" });
    };
    defer ctx.allocator.free(config_dir);

    return try std.fs.path.join(ctx.allocator, &.{ config_dir, "config.kdl" });
}

/// Read a config file.
/// Caller owns returned Config and must call deinit() when done.
pub fn readConfigFile(ctx: *Context, file_path: []const u8) !Config {
    return readConfigFileWithAllocator(ctx, file_path, ctx.allocator);
}

/// Read a config file using a specified allocator for all allocations.
/// Caller owns returned Config and must call deinit() when done.
pub fn readConfigFileWithAllocator(ctx: *Context, file_path: []const u8, allocator: std.mem.Allocator) !Config {
    ctx.debug("reading config file: {s}", .{file_path});

    // Resolve relative paths to an absolute path using path.resolveToAbsolutePath.
    // This preserves use of std.fs.openFileAbsolute while accepting relative input.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = path.resolveToAbsolutePath(file_path, &buf) catch |err| {
        ctx.debug("resolveToAbsolutePath failed: {}", .{err});
        return switch (err) {
            error.FileNotFound => Config.init(ctx, allocator),
            error.PathTooLong => ctx.fail(error.ReadError, file_path, "config path too long"),
            else => ctx.fail(error.ReadError, file_path, "failed to resolve config path"),
        };
    };

    // Try to open the file
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| {
        ctx.debug("failed to open config file: {}", .{err});
        return switch (err) {
            error.FileNotFound => Config.init(ctx, allocator),
            else => ctx.fail(error.ReadError, file_path, "failed to open config file"),
        };
    };
    defer file.close();

    // Read the file content
    const file_size = try file.getEndPos();
    if (file_size > 1024 * 1024) { // 1MB limit
        return ctx.fail(error.ReadError, file_path, "config file too large (max 1MB)");
    }

    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);

    const bytes_read = file.readAll(content) catch {
        return ctx.fail(error.ReadError, file_path, "failed to read config file");
    };
    if (bytes_read != file_size) {
        return ctx.fail(error.ReadError, file_path, "short read while loading config file");
    }

    return Config.fromKdl(ctx, content, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => return ctx.fail(error.ParseError, file_path, "failed to parse config file"),
        error.InvalidConfig => return error.InvalidConfig,
    };
}

/// Write a config file
pub fn writeConfigFile(ctx: *Context, file_path: []const u8, config: *const Config) !void {
    ctx.debug("writing config file: {s}", .{file_path});

    if (!path.isValidInputPath(file_path)) {
        return ctx.fail(error.WriteError, file_path, "invalid config file path");
    }

    // Create parent directories if they don't exist
    const parent_dir = std.fs.path.dirname(file_path) orelse {
        return ctx.fail(error.WriteError, file_path, "missing parent directory");
    };

    var dir = path.makePathAndOpenDir(parent_dir) catch |err| {
        return ctx.fail(err, file_path, "failed to create config directory");
    };
    defer dir.close();

    // Convert config to KDL
    const kdl_str = config.toKdl() catch |err| {
        return ctx.fail(err, file_path, "failed to serialize config");
    };
    defer ctx.allocator.free(kdl_str);

    // Write to file
    const file = path.makePathAndOpenFile(file_path) catch |err| {
        return ctx.fail(err, file_path, "failed to open config file for writing");
    };
    defer file.close();

    file.writeAll(kdl_str) catch |err| {
        return ctx.fail(err, file_path, "failed to write config file");
    };
}

/// Load the configuration from the system config file (/mere/config.kdl).
/// This loads remote repository definitions only.
/// Caller owns returned Config and must call deinit() when done.
pub fn loadConfig(ctx: *Context) !Config {
    // Get system config path
    const system_path = try getSystemConfigPath(ctx);
    defer ctx.allocator.free(system_path);

    // Read system config
    ctx.debug("loading system config from: {s}", .{system_path});
    var config = try readConfigFile(ctx, system_path);
    errdefer config.deinit();

    // Validate the configuration
    try config.validate();

    return config;
}

pub fn loadSystemColorSetting(ctx: *Context) !?bool {
    const system_path = try getSystemConfigPath(ctx);
    defer ctx.allocator.free(system_path);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const cfg = try readConfigFileWithAllocator(ctx, system_path, arena.allocator());
    return cfg.color;
}

/// Save the system configuration to /mere/config.kdl.
/// This is the only location for remote repository definitions.
pub fn saveSystemConfig(ctx: *Context, cfg: *const Config) !void {
    const system_path = try getSystemConfigPath(ctx);
    defer ctx.allocator.free(system_path);

    try writeConfigFile(ctx, system_path, cfg);
}

test "Config initialization and deinitialization" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var config = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.repos.items.len);
}

test "Config to KDL roundtrip" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var config = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config.deinit();
    config.color = false;

    // Add some repos
    try config.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core"),
        .priority = 100,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    try config.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "extra"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/extra"),
        .priority = 200,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    // Convert to KDL
    const kdl_str = try config.toKdl();
    defer test_env.ctx.allocator.free(kdl_str);

    // Parse it back
    var parsed_config = try Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator);
    defer parsed_config.deinit();

    // Verify
    try std.testing.expectEqual(@as(?bool, false), parsed_config.color);
    try std.testing.expectEqual(@as(usize, 2), parsed_config.repos.items.len);
    try std.testing.expectEqualStrings("core", parsed_config.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com/repo/core", parsed_config.repos.items[0].url);
    try std.testing.expectEqual(@as(u8, 100), parsed_config.repos.items[0].priority);

    try std.testing.expectEqualStrings("extra", parsed_config.repos.items[1].name);
    try std.testing.expectEqualStrings("https://example.com/repo/extra", parsed_config.repos.items[1].url);
    try std.testing.expectEqual(@as(u8, 200), parsed_config.repos.items[1].priority);
}

test "Config merge" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var config1 = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config1.deinit();

    var config2 = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config2.deinit();

    // Add repos to config1
    try config1.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core"),
        .priority = 100,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    // Add repos to config2 (including one with the same name)
    try config2.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core-override"),
        .priority = 150,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    try config2.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "extra"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/extra"),
        .priority = 200,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    // Merge config2 into config1
    try config1.merge(&config2);

    // Verify
    try std.testing.expectEqual(@as(usize, 2), config1.repos.items.len);

    // The "core" repo should be overridden
    try std.testing.expectEqualStrings("core", config1.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com/repo/core-override", config1.repos.items[0].url);
    try std.testing.expectEqual(@as(u8, 150), config1.repos.items[0].priority);

    // The "extra" repo should be added
    try std.testing.expectEqualStrings("extra", config1.repos.items[1].name);
    try std.testing.expectEqualStrings("https://example.com/repo/extra", config1.repos.items[1].url);
    try std.testing.expectEqual(@as(u8, 200), config1.repos.items[1].priority);
}

test "Config file read/write" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a test configuration
    var test_config = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer test_config.deinit();

    // Add some repositories
    try test_config.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core"),
        .priority = 100,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    try test_config.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "extra"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/extra"),
        .priority = 200,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    // Get the system config path
    const system_path = try getSystemConfigPath(&test_env.ctx);
    defer test_env.ctx.allocator.free(system_path);

    // Write the configuration to the system config file
    try writeConfigFile(&test_env.ctx, system_path, &test_config);

    // Read the configuration back
    var read_config = try readConfigFile(&test_env.ctx, system_path);
    defer read_config.deinit();

    // Verify the configuration
    try std.testing.expectEqual(@as(usize, 2), read_config.repos.items.len);
    try std.testing.expectEqualStrings("core", read_config.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com/repo/core", read_config.repos.items[0].url);
    try std.testing.expectEqual(@as(u8, 100), read_config.repos.items[0].priority);

    try std.testing.expectEqualStrings("extra", read_config.repos.items[1].name);
    try std.testing.expectEqualStrings("https://example.com/repo/extra", read_config.repos.items[1].url);
    try std.testing.expectEqual(@as(u8, 200), read_config.repos.items[1].priority);
}

test "Add and remove repositories" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var test_config = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer test_config.deinit();

    // Add a repository
    const repo1 = RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core"),
        .priority = 100,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    };
    try test_config.addRepo(repo1);

    // Verify the repository was added
    try std.testing.expectEqual(@as(usize, 1), test_config.repos.items.len);
    try std.testing.expectEqualStrings("core", test_config.repos.items[0].name);

    // Add another repository
    const repo2 = RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "extra"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/extra"),
        .priority = 200,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    };
    try test_config.addRepo(repo2);

    // Verify both repositories are present
    try std.testing.expectEqual(@as(usize, 2), test_config.repos.items.len);

    // Add a repository with the same name (should replace)
    const repo3 = RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core-new"),
        .priority = 150,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    };
    try test_config.addRepo(repo3);

    // Verify the repository was replaced
    try std.testing.expectEqual(@as(usize, 2), test_config.repos.items.len);

    // Find the core repo
    var found_core = false;
    for (test_config.repos.items) |repo| {
        if (std.mem.eql(u8, repo.name, "core")) {
            found_core = true;
            try std.testing.expectEqualStrings("https://example.com/repo/core-new", repo.url);
            try std.testing.expectEqual(@as(u8, 150), repo.priority);
        }
    }
    try std.testing.expect(found_core);

    // Remove a repository
    const removed = test_config.removeRepo("extra");
    try std.testing.expect(removed);

    // Verify the repository was removed
    try std.testing.expectEqual(@as(usize, 1), test_config.repos.items.len);
    try std.testing.expectEqualStrings("core", test_config.repos.items[0].name);

    // Try to remove a non-existent repository
    const not_removed = test_config.removeRepo("nonexistent");
    try std.testing.expect(!not_removed);

    // Verify the configuration is unchanged
    try std.testing.expectEqual(@as(usize, 1), test_config.repos.items.len);
}

test "Config KDL after removing last repo has no repo blocks" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var config = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config.deinit();

    // Add and then remove a repo
    try config.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "core"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/repo/core"),
        .priority = 100,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });
    const removed = config.removeRepo("core");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), config.repos.items.len);

    // Serialize to KDL and check output
    const kdl_str = try config.toKdl();
    defer test_env.ctx.allocator.free(kdl_str);

    test_env.ctx.debug("KDL output after removing last repo:\n{s}\n", .{kdl_str});
    // With header comment, empty config has some content but no repo blocks
    try std.testing.expect(std.mem.indexOf(u8, kdl_str, "repo ") == null);
}

test "Config merge replaces repo with same name and validates" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var config1 = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config1.deinit();

    var config2 = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer config2.deinit();

    try config1.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "repo"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/one"),
        .priority = 1,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    try config2.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "repo"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com/two"),
        .trusted_fingerprints = std.ArrayList([]const u8){},
        .priority = 2,
    });

    try config1.merge(&config2);

    try config1.validate();

    // Only one "repo" should exist, with config2's values
    try std.testing.expectEqual(@as(usize, 1), config1.repos.items.len);
    try std.testing.expectEqualStrings("repo", config1.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com/two", config1.repos.items[0].url);
    try std.testing.expectEqual(@as(u8, 2), config1.repos.items[0].priority);
}

test "Config deepCopy preserves data after original deinit" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use an arena allocator to simulate transient parsing
    var arena = std.heap.ArenaAllocator.init(test_env.ctx.allocator);
    const arena_alloc = arena.allocator();

    const kdl_str =
        \\repo "foo" {
        \\    url "https://example.com"
        \\}
    ;

    // Parse into arena-backed config
    var parsed = try Config.fromKdl(&test_env.ctx, kdl_str, arena_alloc);

    // Deep-copy into the persistent ctx.allocator
    var persistent = try parsed.deepCopy(test_env.ctx.allocator);

    // Now free the transient parsed config and its arena
    parsed.deinit();
    arena.deinit();

    // Persistent copy must be valid even after the original is gone
    try std.testing.expectEqual(@as(usize, 1), persistent.repos.items.len);
    try std.testing.expectEqualStrings("foo", persistent.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com", persistent.repos.items[0].url);
    // trusted_fingerprints is empty in test config

    defer persistent.deinit();
}

test "Allocator mismatch avoided when merging with arena allocator" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use an arena allocator to simulate transient parsing/merging
    var arena = std.heap.ArenaAllocator.init(test_env.ctx.allocator);
    const arena_alloc = arena.allocator();

    // Source config allocated in arena
    var src = Config.init(&test_env.ctx, arena_alloc);
    // Do not call src.deinit() - arena allocations must be freed by destroying the arena.

    try src.repos.append(arena_alloc, RepoConfig{
        .name = try arena_alloc.dupe(u8, "arena_repo"),
        .url = try arena_alloc.dupe(u8, "https://example.com/arena"),
        .priority = 10,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    // Merged config also uses arena allocator (matching loadConfig behavior)
    var merged = Config.init(&test_env.ctx, arena_alloc);
    // Do not call merged.deinit() for the same reason.

    // Merge using the arena allocator -- previously this could produce allocator mismatches
    try merged.mergeWithAllocator(&src, arena_alloc);

    // Deep-copy merged result into persistent allocator (ctx.allocator)
    var persistent = try merged.deepCopy(test_env.ctx.allocator);

    // Reclaim transient arena allocations. Destroying the arena reclaims all arena memory.
    arena.deinit();

    // Persistent copy must be valid after the transient arena is gone
    try std.testing.expectEqual(@as(usize, 1), persistent.repos.items.len);
    try std.testing.expectEqualStrings("arena_repo", persistent.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com/arena", persistent.repos.items[0].url);
    // trusted_fingerprints is empty in test config

    defer persistent.deinit();
}

test "RepoConfig.fromKdl rejects missing required fields" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Missing name (repo argument)
    const kdl_str =
        \\repo {
        \\    url "https://example.com/repo/core"
        \\}
    ;

    try std.testing.expectError(error.InvalidConfig, Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator));
}

test "RepoConfig.fromKdl rejects out-of-range priority" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str =
        \\repo "badprio" {
        \\    url "https://example.com/repo/bad"
        \\    priority 9999
        \\}
    ;

    try std.testing.expectError(error.InvalidConfig, Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator));
}

test "Config.fromKdl with empty input returns empty config" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str = "// empty config\n";
    var cfg = try Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.repos.items.len);
}

test "readConfigFileWithAllocator rejects files larger than 1MB" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const big_name = "big_config.kdl";
    const big_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, big_name });
    defer test_env.ctx.allocator.free(big_path);

    // Create file >1MB
    const size = 1024 * 1024 + 1;
    const buf = try test_env.ctx.allocator.alloc(u8, size);
    defer test_env.ctx.allocator.free(buf);
    // Fill with 'a'
    for (buf) |*b| b.* = 'a';

    {
        const f = try std.fs.createFileAbsolute(big_path, .{});
        try f.writeAll(buf);
        f.close();
    }

    try std.testing.expectError(error.ReadError, readConfigFileWithAllocator(&test_env.ctx, big_path, test_env.ctx.allocator));
    // cleanup file
    std.fs.deleteFileAbsolute(big_path) catch {};
}

test "readConfigFileWithAllocator returns empty config for FileNotFound" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const missing = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "missing-config.kdl" });
    defer test_env.ctx.allocator.free(missing);

    var cfg = try readConfigFileWithAllocator(&test_env.ctx, missing, test_env.ctx.allocator);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.repos.items.len);
}

test "readConfigFileWithAllocator reports ReadError on permission denied" {
    if (std.posix.geteuid() == 0) return error.SkipZigTest;

    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const blocked = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "blocked-config.kdl" });
    defer test_env.ctx.allocator.free(blocked);
    {
        const f = try std.fs.createFileAbsolute(blocked, .{ .truncate = true });
        try f.writeAll("repo \"x\" { url \"https://example.com/repo.db\" trusted-fingerprints \"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" }");
        f.close();
    }

    try std.posix.fchmodat(std.posix.AT.FDCWD, blocked, 0, 0);
    defer std.posix.fchmodat(std.posix.AT.FDCWD, blocked, 0o644, 0) catch {};

    try std.testing.expectError(error.ReadError, readConfigFileWithAllocator(&test_env.ctx, blocked, test_env.ctx.allocator));
}

test "Config.validate rejects invalid url" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Invalid URL should fail validation
    var cfg = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer cfg.deinit();

    try cfg.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "badurl"),
        .url = try test_env.ctx.allocator.dupe(u8, "not-a-url"),
        .priority = 1,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    try std.testing.expectError(error.InvalidConfig, cfg.validate());
}

test "Config.deepCopy OutOfMemory error on allocation failure" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a config with one repo to copy
    var cfg = Config.init(&test_env.ctx, test_env.ctx.allocator);
    defer cfg.deinit();

    try cfg.repos.append(test_env.ctx.allocator, RepoConfig{
        .name = try test_env.ctx.allocator.dupe(u8, "test-repo"),
        .url = try test_env.ctx.allocator.dupe(u8, "https://example.com"),
        .priority = 1,
        .trusted_fingerprints = std.ArrayList([]const u8){},
    });

    // Test that deepCopy properly returns OutOfMemory when allocation fails
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = cfg.deepCopy(failing_allocator.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
    // If errdefer is working correctly, no memory should leak
}

test "Parse valid KDL config" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str =
        \\repo "core" {
        \\    url "https://example.com/repo/core"
        \\    priority 100
        \\}
        \\
        \\repo "extra" {
        \\    url "https://example.com/repo/extra"
        \\    priority 200
        \\}
    ;

    var config = try Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.repos.items.len);
    try std.testing.expectEqualStrings("core", config.repos.items[0].name);
    try std.testing.expectEqualStrings("https://example.com/repo/core", config.repos.items[0].url);
    try std.testing.expectEqual(@as(u8, 100), config.repos.items[0].priority);

    try std.testing.expectEqualStrings("extra", config.repos.items[1].name);
    try std.testing.expectEqualStrings("https://example.com/repo/extra", config.repos.items[1].url);
    try std.testing.expectEqual(@as(u8, 200), config.repos.items[1].priority);
}

test "Parse KDL config with default priority" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str =
        \\repo "minimal" {
        \\    url "https://example.com/repo"
        \\}
    ;

    var config = try Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.repos.items.len);
    try std.testing.expectEqualStrings("minimal", config.repos.items[0].name);
    try std.testing.expectEqual(@as(u8, 100), config.repos.items[0].priority); // Default priority
}

test "KDL config supports trusted-fingerprints" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str =
        \\repo "test" {
        \\    url "https://example.com/repo"
        \\    trusted-fingerprints "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        \\}
    ;

    var config = try Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.repos.items.len);
    try std.testing.expectEqual(@as(usize, 2), config.repos.items[0].trusted_fingerprints.items.len);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", config.repos.items[0].trusted_fingerprints.items[0]);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", config.repos.items[0].trusted_fingerprints.items[1]);
}

test "KDL config rejects non-hex trusted-fingerprints" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str =
        \\repo "test" {
        \\    url "https://example.com/repo"
        \\    trusted-fingerprints "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"
        \\}
    ;

    try std.testing.expectError(error.InvalidConfig, Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator));
}

test "KDL config normalizes trusted-fingerprints to lowercase" {
    var test_env = try @import("test_helpers.zig").createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_str =
        \\repo "test" {
        \\    url "https://example.com/repo"
        \\    trusted-fingerprints "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
        \\}
    ;

    var config = try Config.fromKdl(&test_env.ctx, kdl_str, test_env.ctx.allocator);
    defer config.deinit();

    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        config.repos.items[0].trusted_fingerprints.items[0],
    );
}
