const std = @import("std");
const mere = @import("mere.zig");
const kdl = @import("kdl.zig");
const path = @import("path.zig");
const ns = @import("namespace.zig");
const package = @import("package.zig");
const errors = @import("errors.zig");
const kdl_schema = @import("kdl_schema.zig");

const Std = errors.StandardErrors;
pub const RecipeError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput || Std.CorruptData || error{
    ParseFailed,
    NamespaceFailed,
    MissingVars,
    MissingKey,
    UnclosedPlaceholder,
    NonStringValue,
    KeyTooLong,
    MalformedPlaceholder,
};

pub const LoadedRecipeFile = struct {
    abs_path: []const u8,
    content: []u8,

    pub fn deinit(self: *LoadedRecipeFile, allocator: std.mem.Allocator) void {
        allocator.free(self.abs_path);
        allocator.free(self.content);
    }
};

pub fn parse(ctx: *mere.Context, recipe_buf: []const u8) !Recipe {
    const allocator = ctx.allocator;
    // Parse KDL document
    var parse_error_message: ?[]const u8 = null;
    var nodes = kdl.parseDocumentDetailed(allocator, recipe_buf, &parse_error_message) catch {
        const detail = parse_error_message orelse "syntax error in recipe file";
        return ctx.fail(RecipeError.ParseFailed, "recipe KDL", detail);
    };
    defer {
        for (nodes.items) |*n| n.deinit();
        nodes.deinit(allocator);
    }

    try kdl_schema.validateRecipe(ctx, nodes.items);

    // Initialize recipe
    var recipe = try Recipe.init(allocator, ctx);
    errdefer recipe.deinit();

    // Parse recipe + vars first so interpolation in later sections can
    // reliably use resolved recipe fields (including recipe.arch) and vars.
    var found_recipe = false;
    for (nodes.items) |*node| {
        if (std.mem.eql(u8, node.name, "recipe")) {
            try parseKdlRecipeNode(allocator, node, &recipe);
            found_recipe = true;
        } else if (std.mem.eql(u8, node.name, "vars")) {
            try parseKdlVarsNode(allocator, node, &recipe.vars);
        }
    }

    if (!found_recipe) {
        return ctx.fail(RecipeError.InvalidInput, "recipe node", "missing required 'recipe' node in recipe file");
    }

    // Resolve architecture
    if (recipe.supported_archs.items.len > 0) {
        const builtin = @import("builtin");
        const host_arch = @tagName(builtin.cpu.arch);
        recipe.arch = selectArchitecture(recipe.supported_archs.items, host_arch) catch |err| {
            recipe.deinit();
            // Enrich error with recipe identity for easier debugging
            return ctx.fail(err, recipe.name, "failed to select/validate architecture");
        };
    }

    // Parse remaining sections that can use interpolation.
    var found_package = false;
    for (nodes.items) |*node| {
        if (std.mem.eql(u8, node.name, "source")) {
            try parseKdlSourceNode(allocator, node, &recipe.sources);
        } else if (std.mem.eql(u8, node.name, "prepare")) {
            try parseKdlPhaseNode(ctx, node, &recipe.prepare, &recipe.prepare_env, &recipe, &recipe.vars);
        } else if (std.mem.eql(u8, node.name, "build")) {
            try parseKdlPhaseNode(ctx, node, &recipe.build_phase, &recipe.build_env, &recipe, &recipe.vars);
        } else if (std.mem.eql(u8, node.name, "check")) {
            try parseKdlPhaseNode(ctx, node, &recipe.check, &recipe.check_env, &recipe, &recipe.vars);
        } else if (std.mem.eql(u8, node.name, "install")) {
            try parseKdlPhaseNode(ctx, node, &recipe.install_phase, &recipe.install_env, &recipe, &recipe.vars);
        } else if (std.mem.eql(u8, node.name, "package")) {
            try parseKdlPackageNode(ctx, node, &recipe.packages, &recipe, &recipe.vars);
            found_package = true;
        }
    }

    if (!found_package) {
        return ctx.fail(RecipeError.InvalidInput, "package node", "missing required 'package' node in recipe file");
    }

    // Validate the recipe has actionable content
    try validateRecipeActionable(&recipe);

    return recipe;
}

pub fn validateFile(ctx: *mere.Context, file_path: []const u8) !void {
    var loaded = try loadFile(ctx, file_path);
    defer loaded.deinit(ctx.allocator);

    var parsed = parse(ctx, loaded.content) catch |err| {
        rewriteParseDiagnosticSubject(ctx, loaded.abs_path);
        return err;
    };
    defer parsed.deinit();
}

fn loadFile(ctx: *mere.Context, file_path: []const u8) !LoadedRecipeFile {
    if (!path.isValidInputPath(file_path)) {
        return ctx.fail(RecipeError.InvalidInput, file_path, "invalid recipe path");
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path_slice = path.resolveToAbsolutePath(file_path, &buf) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PathTooLong => return ctx.fail(RecipeError.InvalidInput, file_path, "recipe path too long"),
        else => return ctx.fail(RecipeError.FileSystem, file_path, "failed to resolve recipe path"),
    };

    const abs_path = try ctx.allocator.dupe(u8, abs_path_slice);
    errdefer ctx.allocator.free(abs_path);

    var recipe_file = path.openExistingFile(abs_path) catch {
        return ctx.fail(RecipeError.FileSystem, abs_path, "failed to open recipe file");
    };
    defer recipe_file.close(path.currentIo());

    const file_size = (recipe_file.stat(path.currentIo()) catch {
        return ctx.fail(RecipeError.FileSystem, abs_path, "failed to stat recipe file");
    }).size;

    if (file_size > 1024 * 1024 * 10) {
        return ctx.fail(RecipeError.InvalidInput, abs_path, "recipe file too large");
    }

    const recipe_buf = try ctx.allocator.alloc(u8, file_size);
    errdefer ctx.allocator.free(recipe_buf);

    const bytes_read = recipe_file.readPositionalAll(path.currentIo(), recipe_buf, 0) catch {
        return ctx.fail(RecipeError.FileSystem, abs_path, "failed to read recipe file");
    };

    if (bytes_read != file_size) {
        return ctx.fail(RecipeError.FileSystem, abs_path, "short read while reading recipe file");
    }

    return LoadedRecipeFile{
        .abs_path = abs_path,
        .content = recipe_buf,
    };
}

fn rewriteParseDiagnosticSubject(ctx: *mere.Context, abs_path: []const u8) void {
    const diag = ctx.getDiagnosticContext();
    if (diag.subject) |subject| {
        if (std.mem.eql(u8, subject, "recipe KDL") or
            std.mem.eql(u8, subject, "recipe.kdl") or
            std.mem.eql(u8, subject, "recipe node") or
            std.mem.eql(u8, subject, "package node"))
        {
            ctx.setDiagnosticContext(abs_path, diag.details);
        }
    }
}

/// Parse the recipe {} node for metadata
fn parseKdlRecipeNode(allocator: std.mem.Allocator, node: *const kdl.Node, recipe: *Recipe) !void {
    // Required fields
    const name = node.getChildString("name") orelse return RecipeError.MissingKey;
    recipe.name = try allocator.dupe(u8, name);

    const version = node.getChildString("version") orelse return RecipeError.MissingKey;
    recipe.version = try allocator.dupe(u8, version);

    const release = node.getChildInt("release") orelse return RecipeError.MissingKey;
    if (release < 0 or release > 0xFFFFFFFF) return RecipeError.InvalidInput;
    recipe.release = @intCast(release);

    // Optional fields
    if (node.getChildString("description")) |desc| {
        if (recipe.description.len > 0) allocator.free(recipe.description);
        recipe.description = try allocator.dupe(u8, desc);
    }

    if (node.getChildString("url")) |url| {
        if (recipe.url) |existing| allocator.free(existing);
        recipe.url = try allocator.dupe(u8, url);
    }

    if (node.getChildBool("needs-root")) |needs_root| {
        recipe.needs_root = needs_root;
    }

    // Array fields from child nodes with multiple arguments
    // licenses "MIT" "Apache-2.0" or multiple license nodes
    if (node.findChild("licenses")) |licenses_node| {
        for (licenses_node.arguments.items) |arg| {
            if (arg.getString()) |s| {
                const dup = try allocator.dupe(u8, s);
                try recipe.licenses.append(allocator, dup);
            }
        }
    }

    // archs "x86_64" "aarch64"
    if (node.findChild("archs")) |archs_node| {
        for (archs_node.arguments.items) |arg| {
            if (arg.getString()) |s| {
                const dup = try allocator.dupe(u8, s);
                try recipe.supported_archs.append(allocator, dup);
            }
        }
    }

    // depends "cmake" "ninja"
    if (node.findChild("depends")) |depends_node| {
        for (depends_node.arguments.items) |arg| {
            if (arg.getString()) |s| {
                const dup = try allocator.dupe(u8, s);
                try recipe.depends.append(allocator, dup);
            }
        }
    }

    // env CC="clang" CXX="clang++" (properties on an env child node)
    if (node.findChild("env")) |env_node| {
        try parseKdlEnvProperties(allocator, env_node, &recipe.env);
    }
}

/// Parse a vars {} node
fn parseKdlVarsNode(allocator: std.mem.Allocator, node: *const kdl.Node, vars: *std.ArrayList(KV)) !void {
    // Each child node is a var: major "20"
    for (node.children.items) |child| {
        const key = child.name;
        const value = child.getFirstArgString() orelse continue;
        const kv = try KV.init(allocator, key, value);
        try vars.append(allocator, kv);
    }
}

/// Parse a source node
fn parseKdlSourceNode(allocator: std.mem.Allocator, node: *const kdl.Node, sources: *std.ArrayList(Source)) !void {
    var source = Source.init();
    errdefer source.deinit(allocator);

    // URL is the first argument
    const url = node.getFirstArgString() orelse return RecipeError.MissingKey;
    source.url = try allocator.dupe(u8, url);

    // blake3 and save-as are child nodes
    if (node.getChildString("blake3")) |hash| {
        source.blake3 = try allocator.dupe(u8, hash);
    }
    if (node.getChildString("save-as")) |save_as| {
        source.save_as = try allocator.dupe(u8, save_as);
    }

    try sources.append(allocator, source);
}

/// Parse a phase node (prepare, build, check, install)
fn parseKdlPhaseNode(
    ctx: *mere.Context,
    node: *const kdl.Node,
    script: *?[]const u8,
    env: *std.ArrayList(KV),
    recipe_ref: *const Recipe,
    vars: ?*const std.ArrayList(KV),
) !void {
    const allocator = ctx.allocator;
    // Script is in a 'script' child node
    if (node.getChildString("script")) |s| {
        if (script.*) |existing| allocator.free(existing);
        script.* = try interpolate(allocator, ctx, s, recipe_ref, vars);
    }

    // Env is in an 'env' child node with properties
    if (node.findChild("env")) |env_node| {
        try parseKdlEnvProperties(allocator, env_node, env);
    }
}

/// Parse a package node
fn parseKdlPackageNode(
    ctx: *mere.Context,
    node: *const kdl.Node,
    packages: *std.ArrayList(BuildArtifact),
    recipe_ref: *const Recipe,
    vars: ?*const std.ArrayList(KV),
) !void {
    const allocator = ctx.allocator;
    var artifact = try BuildArtifact.init(allocator);
    errdefer BuildArtifact.deinit(&artifact, allocator);

    // Name is the first argument
    const name = node.getFirstArgString() orelse return RecipeError.MissingKey;
    artifact.name = try allocator.dupe(u8, name);

    // files are arguments in a 'files' child node
    if (node.findChild("files")) |files_node| {
        for (files_node.arguments.items) |arg| {
            if (arg.getString()) |s| {
                const expanded = try interpolate(allocator, ctx, s, recipe_ref, vars);
                errdefer allocator.free(expanded);
                try artifact.pkgfiles.append(allocator, expanded);
            }
        }
    }

    // strip controls automatic binary stripping for this package (default: true)
    if (node.getChildBool("strip")) |val| {
        artifact.strip = val;
    }
    // compress-manpages controls zstd compression of usr/share/man pages (default: true)
    if (node.getChildBool("compress-manpages")) |val| {
        artifact.compress_manpages = val;
    }

    try packages.append(allocator, artifact);
}

/// Parse environment properties from a node
/// Format: env CC="clang" CXX="clang++"
fn parseKdlEnvProperties(allocator: std.mem.Allocator, node: *const kdl.Node, env: *std.ArrayList(KV)) !void {
    var iter = node.properties.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (entry.value_ptr.getString()) |value| {
            const kv = try KV.init(allocator, key, value);
            try env.append(allocator, kv);
        }
    }
}

/// Validate that the recipe has actionable content
fn validateRecipeActionable(recipe: *const Recipe) RecipeError!void {
    var actionable = false;

    if (recipe.prepare) |s| {
        if (s.len > 0) actionable = true;
    }
    if (!actionable) {
        if (recipe.build_phase) |s| {
            if (s.len > 0) actionable = true;
        }
    }
    if (!actionable) {
        if (recipe.check) |s| {
            if (s.len > 0) actionable = true;
        }
    }
    if (!actionable) {
        if (recipe.install_phase) |s| {
            if (s.len > 0) actionable = true;
        }
    }
    if (!actionable) {
        if (recipe.sources.items.len > 0) {
            for (recipe.packages.items) |pa| {
                if (pa.pkgfiles.items.len > 0) {
                    actionable = true;
                    break;
                }
            }
        }
    }

    if (!actionable) {
        return RecipeError.InvalidInput;
    }
}

pub const KV = struct {
    key: []const u8,
    value: []const u8,

    pub fn init(allocator: std.mem.Allocator, k: []const u8, v: []const u8) !KV {
        const key_dup = try allocator.dupe(u8, k);
        errdefer allocator.free(key_dup);
        const value_dup = try allocator.dupe(u8, v);
        return KV{
            .key = key_dup,
            .value = value_dup,
        };
    }

    pub fn deinit(self: *KV, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};
pub const Source = struct {
    url: []const u8,
    blake3: ?[]const u8,
    // Optional saved filename to use when storing the source in the cache/workspace.
    // If present, this exact string will be used as the cached filename instead of
    // deriving from the URL basename.
    save_as: ?[]const u8,

    pub fn init() Source {
        return Source{
            .url = "",
            .blake3 = null,
            .save_as = null,
        };
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        if (self.url.len > 0) allocator.free(self.url);
        if (self.blake3) |b| allocator.free(b);
        if (self.save_as) |s| allocator.free(s);
    }
};

pub const BuildState = enum { Planned, Built, Scanned, Archived, Published };

pub const BuildArtifact = struct {
    name: []const u8,
    pkgfiles: std.ArrayList([]const u8),
    archive_path: ?[]const u8,
    content_hash: ?[]const u8,
    archive_hash: ?[]const u8,
    signature: ?[]const u8,
    state: BuildState,
    logs: std.ArrayList([]const u8),
    strip: bool,
    compress_manpages: bool,

    pub fn init(allocator: std.mem.Allocator) !BuildArtifact {
        return BuildArtifact{
            .name = "",
            .pkgfiles = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .archive_path = null,
            .content_hash = null,
            .archive_hash = null,
            .signature = null,
            .state = .Planned,
            .logs = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .strip = true,
            .compress_manpages = true,
        };
    }

    pub fn deinit(self: *BuildArtifact, gpa: std.mem.Allocator) void {
        if (self.name.len > 0) gpa.free(self.name);
        for (self.pkgfiles.items) |s| {
            gpa.free(s);
        }
        self.pkgfiles.deinit(gpa);

        if (self.archive_path) |ap| gpa.free(ap);
        if (self.content_hash) |ch| gpa.free(ch);
        if (self.archive_hash) |ah| gpa.free(ah);
        if (self.signature) |sig| gpa.free(sig);

        for (self.logs.items) |l| {
            gpa.free(l);
        }
        self.logs.deinit(gpa);
    }

    pub fn markBuilt(self: *BuildArtifact, allocator: std.mem.Allocator, archive_path: []const u8, content_hash: []const u8, archive_hash: []const u8, signature: []const u8) !void {
        // Builder signatures are required for published artifacts. Reject empty signatures.
        if (signature.len == 0) return RecipeError.InvalidInput;

        if (self.archive_path) |old| allocator.free(old);
        self.archive_path = try allocator.dupe(u8, archive_path);

        if (self.content_hash) |old| allocator.free(old);
        self.content_hash = try allocator.dupe(u8, content_hash);

        if (self.archive_hash) |old| allocator.free(old);
        self.archive_hash = try allocator.dupe(u8, archive_hash);

        if (self.signature) |old| allocator.free(old);
        self.signature = try allocator.dupe(u8, signature);

        self.state = .Built;
    }
};

pub const Recipe = struct {
    allocator: std.mem.Allocator,
    ctx: ?*mere.Context,
    name: []const u8,
    version: []const u8,
    release: u32,
    supported_archs: std.ArrayList([]const u8),
    arch: ?[]const u8, // Resolved architecture for interpolation
    description: []const u8,
    url: ?[]const u8,
    licenses: std.ArrayList([]const u8),
    depends: std.ArrayList([]const u8),
    vars: std.ArrayList(KV),
    sources: std.ArrayList(Source),
    packages: std.ArrayList(BuildArtifact),
    env: std.ArrayList(KV),
    prepare_env: std.ArrayList(KV),
    build_env: std.ArrayList(KV),
    check_env: std.ArrayList(KV),
    install_env: std.ArrayList(KV),
    // Optional global phase script strings (duplicated into allocator)
    prepare: ?[]const u8,
    build_phase: ?[]const u8,
    check: ?[]const u8,
    install_phase: ?[]const u8,
    needs_root: bool,

    pub fn init(allocator: std.mem.Allocator, ctx: ?*mere.Context) !Recipe {
        const supported_archs = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        const licenses = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        const depends = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        const vars = try std.ArrayList(KV).initCapacity(allocator, 0);
        const sources = try std.ArrayList(Source).initCapacity(allocator, 0);
        const packages = try std.ArrayList(BuildArtifact).initCapacity(allocator, 0);

        return Recipe{
            .allocator = allocator,
            .ctx = ctx,
            .name = "",
            .version = "",
            .release = 0,
            .supported_archs = supported_archs,
            .arch = null,
            .description = "",
            .url = null,
            .licenses = licenses,
            .depends = depends,
            .vars = vars,
            .sources = sources,
            .packages = packages,
            .env = try std.ArrayList(KV).initCapacity(allocator, 0),
            .prepare_env = try std.ArrayList(KV).initCapacity(allocator, 0),
            .build_env = try std.ArrayList(KV).initCapacity(allocator, 0),
            .check_env = try std.ArrayList(KV).initCapacity(allocator, 0),
            .install_env = try std.ArrayList(KV).initCapacity(allocator, 0),
            .prepare = null,
            .build_phase = null,
            .check = null,
            .install_phase = null,
            .needs_root = false,
        };
    }

    pub fn deinit(self: *Recipe) void {
        const allocator = self.allocator;
        if (self.name.len > 0) allocator.free(self.name);
        if (self.version.len > 0) allocator.free(self.version);
        // release is numeric; no free
        if (self.description.len > 0) allocator.free(self.description);
        if (self.url) |u| allocator.free(u);

        for (self.supported_archs.items) |s| allocator.free(s);
        self.supported_archs.deinit(allocator);

        // arch is now a string literal, no need to free

        for (self.licenses.items) |s| allocator.free(s);
        self.licenses.deinit(allocator);

        for (self.depends.items) |s| allocator.free(s);
        self.depends.deinit(allocator);

        // Free vars KV entries
        var vi: usize = 0;
        while (vi < self.vars.items.len) : (vi += 1) {
            KV.deinit(&self.vars.items[vi], self.allocator);
        }
        self.vars.deinit(self.allocator);

        // Free recipe/phase env lists
        var ei: usize = 0;
        while (ei < self.env.items.len) : (ei += 1) {
            KV.deinit(&self.env.items[ei], self.allocator);
        }
        self.env.deinit(self.allocator);
        ei = 0;
        while (ei < self.prepare_env.items.len) : (ei += 1) {
            KV.deinit(&self.prepare_env.items[ei], self.allocator);
        }
        self.prepare_env.deinit(self.allocator);
        ei = 0;
        while (ei < self.build_env.items.len) : (ei += 1) {
            KV.deinit(&self.build_env.items[ei], self.allocator);
        }
        self.build_env.deinit(self.allocator);
        ei = 0;
        while (ei < self.check_env.items.len) : (ei += 1) {
            KV.deinit(&self.check_env.items[ei], self.allocator);
        }
        self.check_env.deinit(self.allocator);
        ei = 0;
        while (ei < self.install_env.items.len) : (ei += 1) {
            KV.deinit(&self.install_env.items[ei], self.allocator);
        }
        self.install_env.deinit(self.allocator);
        // Free sources
        var si: usize = 0;
        while (si < self.sources.items.len) : (si += 1) {
            self.sources.items[si].deinit(allocator);
        }
        self.sources.deinit(allocator);

        // Free build artifacts
        var pi: usize = 0;
        while (pi < self.packages.items.len) : (pi += 1) {
            BuildArtifact.deinit(&self.packages.items[pi], allocator);
        }
        self.packages.deinit(allocator);
        if (self.prepare) |p| allocator.free(p);
        if (self.build_phase) |b| allocator.free(b);
        if (self.check) |c| allocator.free(c);
        if (self.install_phase) |i| allocator.free(i);
    }

    /// Emit KDL representation of this Recipe
    pub fn toKdl(self: *const Recipe) ![]const u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        // recipe node
        try writer.writeAll("recipe {\n");
        try writer.print("    name \"{s}\"\n", .{self.name});
        try writer.print("    version \"{s}\"\n", .{self.version});
        try writer.print("    release {d}\n", .{self.release});
        try writer.print("    description \"{s}\"\n", .{self.description});
        if (self.url) |u| {
            try writer.print("    url \"{s}\"\n", .{u});
        }
        if (self.licenses.items.len > 0) {
            try writer.writeAll("    licenses");
            for (self.licenses.items) |lic| {
                try writer.print(" \"{s}\"", .{lic});
            }
            try writer.writeAll("\n");
        }
        if (self.supported_archs.items.len > 0) {
            try writer.writeAll("    archs");
            for (self.supported_archs.items) |arch| {
                try writer.print(" \"{s}\"", .{arch});
            }
            try writer.writeAll("\n");
        }
        if (self.depends.items.len > 0) {
            try writer.writeAll("    depends");
            for (self.depends.items) |dep| {
                try writer.print(" \"{s}\"", .{dep});
            }
            try writer.writeAll("\n");
        }
        if (self.env.items.len > 0) {
            try writer.writeAll("    env");
            for (self.env.items) |kv| {
                try writer.print(" {s}=\"{s}\"", .{ kv.key, kv.value });
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll("}\n\n");

        // vars node
        if (self.vars.items.len > 0) {
            try writer.writeAll("vars {\n");
            for (self.vars.items) |kv| {
                try writer.print("    {s} \"{s}\"\n", .{ kv.key, kv.value });
            }
            try writer.writeAll("}\n\n");
        }

        // source nodes
        for (self.sources.items) |src| {
            try writer.print("source \"{s}\"", .{src.url});
            if (src.blake3 != null or src.save_as != null) {
                try writer.writeAll(" {\n");
                if (src.blake3) |b| {
                    try writer.print("    blake3 \"{s}\"\n", .{b});
                }
                if (src.save_as) |sa| {
                    try writer.print("    save-as \"{s}\"\n", .{sa});
                }
                try writer.writeAll("}\n");
            } else {
                try writer.writeAll("\n");
            }
        }

        // build node
        try writer.writeAll("build {\n");
        if (self.build_env.items.len > 0) {
            try writer.writeAll("    env");
            for (self.build_env.items) |kv| {
                try writer.print(" {s}=\"{s}\"", .{ kv.key, kv.value });
            }
            try writer.writeAll("\n");
        }
        if (self.build_phase) |bp| {
            try writer.print("    script r#\"{s}\"#\n", .{bp});
        }
        try writer.writeAll("}\n\n");

        // package nodes
        for (self.packages.items) |pkg| {
            if (pkg.name.len > 0) {
                try writer.print("package \"{s}\" {{\n", .{pkg.name});
            } else {
                try writer.writeAll("package {\n");
            }
            if (pkg.pkgfiles.items.len > 0) {
                try writer.writeAll("    files");
                for (pkg.pkgfiles.items) |pf| {
                    try writer.print(" \"{s}\"", .{pf});
                }
                try writer.writeAll("\n");
            }
            try writer.writeAll("}\n\n");
        }

        return buf.toOwnedSlice(self.allocator);
    }
};

// Architecture validation and selection
pub const ArchError = Std.InvalidInput || error{
    UnsupportedArchitecture,
    EmptyArchitectureList,
};

pub fn selectArchitecture(
    supported_archs: []const []const u8,
    host_arch: []const u8,
) ArchError![]const u8 {
    if (supported_archs.len == 0) {
        return ArchError.EmptyArchitectureList;
    }

    // Check for "any" architecture first
    for (supported_archs) |arch| {
        if (std.mem.eql(u8, arch, "any")) {
            return "any";
        }
    }

    // Check if host architecture is supported
    for (supported_archs) |arch| {
        if (std.mem.eql(u8, arch, host_arch)) {
            return host_arch;
        }
    }

    // Host architecture not supported
    return ArchError.UnsupportedArchitecture;
}

pub fn interpolate(
    allocator: std.mem.Allocator,
    ctx: ?*mere.Context,
    input: []const u8,
    recipe: *const Recipe,
    vars: ?*const std.ArrayList(KV),
) ![]u8 {
    // Only expands ${recipe.*} and ${vars.*} patterns.
    const initial_alloc = input.len * 2;
    var result = try allocator.alloc(u8, initial_alloc); // Over-allocate for simplicity
    var ri: usize = 0;
    var pos: usize = 0;

    while (pos < input.len) {
        // Find next "${"
        const start_rel = std.mem.indexOf(u8, input[pos..], "${");
        if (start_rel == null) {
            // No more placeholders; copy rest
            const rem = input[pos..];
            const rem_len = rem.len;
            if (ri + rem_len > result.len) {
                var new_size = result.len * 2;
                if (new_size < ri + rem_len) new_size = ri + rem_len;
                result = try allocator.realloc(result, new_size);
            }
            std.mem.copyForwards(u8, result[ri .. ri + rem_len], rem);
            ri += rem_len;
            break;
        }
        const start = pos + start_rel.?;
        // Copy prefix up to start
        const prefix = input[pos..start];
        const prefix_len = prefix.len;
        if (prefix_len > 0) {
            if (ri + prefix_len > result.len) {
                var new_size = result.len * 2;
                if (new_size < ri + prefix_len) new_size = ri + prefix_len;
                result = try allocator.realloc(result, new_size);
            }
            std.mem.copyForwards(u8, result[ri .. ri + prefix_len], prefix);
            ri += prefix_len;
        }

        // Find closing '}' after "${"
        if (start + 2 > input.len) {
            // "${" at end of input; copy it literally and finish
            if (ri + 2 > result.len) result = try allocator.realloc(result, @max(result.len * 2, ri + 2));
            result[ri] = '$';
            result[ri + 1] = '{';
            ri += 2;
            pos = start + 2;
            continue;
        }
        const expr_rel = std.mem.indexOf(u8, input[start + 2 ..], "}");
        if (expr_rel == null) {
            // No closing brace; treat as malformed placeholder and return a clear error.
            allocator.free(result);
            if (ctx) |c| {
                c.setDiagnosticContext("variable placeholder", "unclosed ${...} in script");
            }
            return RecipeError.UnclosedPlaceholder;
        }
        const expr_start = start + 2;
        const expr_end = expr_start + expr_rel.?; // index of '}'
        const expr = input[expr_start..expr_end];

        // Expect "prefix.key" form
        const dot_rel = std.mem.indexOf(u8, expr, ".");
        if (dot_rel == null) {
            // No separator: leave placeholder intact so shell/runtime can expand (e.g. ${DESTDIR}).
            if (expr.len == 0) {
                allocator.free(result);
                if (ctx) |c| {
                    c.setDiagnosticContext("variable placeholder", "empty ${} placeholder");
                }
                return RecipeError.MalformedPlaceholder;
            }
            const ph_len = expr_end + 1 - start;
            if (ri + ph_len > result.len) {
                var new_size = result.len * 2;
                if (new_size < ri + ph_len) new_size = ri + ph_len;
                result = try allocator.realloc(result, new_size);
            }
            std.mem.copyForwards(u8, result[ri .. ri + ph_len], input[start .. expr_end + 1]);
            ri += ph_len;
            pos = expr_end + 1;
            continue;
        }

        const prefix_slice = expr[0..dot_rel.?];
        const key = expr[dot_rel.? + 1 ..];

        // Reject empty prefix or empty key as malformed (e.g. `${.name}` or `${recipe.}`)
        if (prefix_slice.len == 0 or key.len == 0) {
            allocator.free(result);
            if (ctx) |c| {
                const placeholder = try std.fmt.allocPrint(c.getDiagArena(), "${{{s}}}", .{expr});
                c.setDiagnosticContext(placeholder, "empty prefix or key in variable placeholder");
            }
            return RecipeError.MalformedPlaceholder;
        }

        // Only support recipe and vars. Preserve unknown prefixes literally so
        // runtime placeholders (e.g. ${env.PATH}, ${color.green}) are not treated
        // as errors and are left for the runtime to expand.
        var table_recipe: bool = false;
        var table_vars: bool = false;
        if (std.mem.eql(u8, prefix_slice, "recipe")) {
            table_recipe = true;
        } else if (std.mem.eql(u8, prefix_slice, "vars")) {
            if (vars == null) {
                allocator.free(result);
                if (ctx) |c| {
                    const placeholder = try std.fmt.allocPrint(c.getDiagArena(), "${{{s}}}", .{expr});
                    c.setDiagnosticContext(placeholder, "vars block not defined in recipe");
                }
                return RecipeError.MissingVars;
            }
            table_vars = true;
        } else {
            // Unknown prefix: copy the whole placeholder verbatim into the output.
            const ph_len = expr_end + 1 - start; // includes the closing '}'
            if (ri + ph_len > result.len) {
                var new_size = result.len * 2;
                if (new_size < ri + ph_len) new_size = ri + ph_len;
                result = try allocator.realloc(result, new_size);
            }
            std.mem.copyForwards(u8, result[ri .. ri + ph_len], input[start .. expr_end + 1]);
            ri += ph_len;
            pos = expr_end + 1;
            continue;
        }

        // Enforce reasonable key length for stack buffer
        if (key.len >= 64) {
            // Key too long to safely copy into the fixed stack buffer.
            allocator.free(result);
            if (ctx) |c| {
                const placeholder = try std.fmt.allocPrint(c.getDiagArena(), "${{{s}.{s}}}", .{ prefix_slice, key });
                c.setDiagnosticContext(placeholder, "variable key exceeds maximum length (64 characters)");
            }
            return RecipeError.KeyTooLong;
        }

        // Lookup key in either recipe fields or vars list
        var found: ?[]const u8 = null;
        // Use a small stack buffer to create a NUL-terminated key for comparison
        var key_buf: [64]u8 = undefined;
        if (key.len >= key_buf.len) {
            allocator.free(result);
            if (ctx) |c| {
                const placeholder = try std.fmt.allocPrint(c.getDiagArena(), "${{{s}.{s}}}", .{ prefix_slice, key });
                c.setDiagnosticContext(placeholder, "variable key exceeds maximum length (64 characters)");
            }
            return RecipeError.KeyTooLong;
        }
        std.mem.copyForwards(u8, key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const key_str = key_buf[0..key.len];

        if (table_recipe) {
            // Support a few top-level recipe keys: name, version, release, url, description, arch
            if (std.mem.eql(u8, key_str, "name")) {
                found = recipe.name;
            } else if (std.mem.eql(u8, key_str, "version")) {
                found = recipe.version;
            } else if (std.mem.eql(u8, key_str, "url") and recipe.url != null) {
                found = recipe.url.?;
            } else if (std.mem.eql(u8, key_str, "description")) {
                found = recipe.description;
            } else if (std.mem.eql(u8, key_str, "release")) {
                // format release as decimal into stack buffer
                var buf: [20]u8 = undefined;
                const printed = try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, recipe.release)});
                found = printed;
            } else if (std.mem.eql(u8, key_str, "arch") and recipe.arch != null) {
                found = recipe.arch.?;
            }
        } else if (table_vars) {
            if (vars) |v| {
                var i: usize = 0;
                while (i < v.*.items.len) : (i += 1) {
                    const kv = v.*.items[i];
                    if (std.mem.eql(u8, kv.key, key_str)) {
                        found = kv.value;
                        break;
                    }
                }
            } else {
                allocator.free(result);
                if (ctx) |c| {
                    const placeholder = try std.fmt.allocPrint(c.getDiagArena(), "${{{s}.{s}}}", .{ prefix_slice, key_str });
                    c.setDiagnosticContext(placeholder, "vars block not defined in recipe");
                }
                return RecipeError.MissingVars;
            }
        }

        if (found) |s| {
            const str_len = s.len;
            if (ri + str_len > result.len) {
                var new_size = result.len * 2;
                if (new_size < ri + str_len) new_size = ri + str_len;
                result = try allocator.realloc(result, new_size);
            }
            std.mem.copyForwards(u8, result[ri .. ri + str_len], s);
            ri += str_len;
        } else {
            // Not found -> MissingKey
            allocator.free(result);
            if (ctx) |c| {
                const placeholder = try std.fmt.allocPrint(c.getDiagArena(), "${{{s}.{s}}}", .{ prefix_slice, key_str });
                const detail = if (table_recipe)
                    try std.fmt.allocPrint(c.getDiagArena(), "'{s}' not found in recipe fields", .{key_str})
                else
                    try std.fmt.allocPrint(c.getDiagArena(), "'{s}' not found in vars block", .{key_str});
                c.setDiagnosticContext(placeholder, detail);
            }
            return RecipeError.MissingKey;
        }

        pos = expr_end + 1;
    }

    // Shrink allocation to the used size so callers can free the returned slice safely.
    if (ri != result.len) {
        result = try allocator.realloc(result, ri);
    }
    return result;
}

test "interpolate expands recipe and vars patterns" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "foo"
        \\    version "1.2.3"
        \\    release 1
        \\    archs "x86_64"
        \\    description "desc"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\    depends "bar"
        \\}
        \\vars {
        \\    bar "baz"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "foo" {
        \\    files "usr/bin/*"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    const input = "${recipe.name}${vars.bar}${recipe.version}${recipe.release}";
    const out = try interpolate(test_env.ctx.allocator, &test_env.ctx, input, &r, &r.vars);
    defer test_env.ctx.allocator.free(out);

    try std.testing.expect(std.mem.eql(u8, out, "foobaz1.2.31"));
}

test "interpolate leaves shell placeholders intact" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "foo"
        \\    version "1.2.3"
        \\    release 1
        \\    archs "x86_64"
        \\    description "desc"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\    depends "bar"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "foo" {
        \\    files "usr/bin/*"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    const input = "DEST=${DESTDIR}/usr";
    const out = try interpolate(test_env.ctx.allocator, &test_env.ctx, input, &r, &r.vars);
    defer test_env.ctx.allocator.free(out);

    try std.testing.expect(std.mem.eql(u8, out, "DEST=${DESTDIR}/usr"));
}

test "architecture validation and selection" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Test valid architecture selection
    const supported_archs = [_][]const u8{ "x86_64", "aarch64" };
    const host_arch = "x86_64";

    const selected = try selectArchitecture(
        &supported_archs,
        host_arch,
    );
    try std.testing.expect(std.mem.eql(u8, selected, "x86_64"));

    // Test "any" architecture
    const any_archs = [_][]const u8{"any"};
    const selected_any = try selectArchitecture(
        &any_archs,
        host_arch,
    );
    try std.testing.expect(std.mem.eql(u8, selected_any, "any"));

    // Test unsupported architecture
    const limited_archs = [_][]const u8{"aarch64"};
    const unsupported_result = selectArchitecture(
        &limited_archs,
        "x86_64",
    );
    try std.testing.expectError(ArchError.UnsupportedArchitecture, unsupported_result);

    // Test empty architecture list
    const empty_archs = [_][]const u8{};
    const empty_result = selectArchitecture(
        &empty_archs,
        host_arch,
    );
    try std.testing.expectError(ArchError.EmptyArchitectureList, empty_result);
}

test "recipe arch interpolation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "foo"
        \\    version "1.2.3"
        \\    release 1
        \\    archs "x86_64"
        \\    description "desc"
        \\    url "http://example.com"
        \\    licenses "MIT"
        \\    depends "bar"
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "foo" {
        \\    files "usr/bin/*"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    const input = "Package for ${recipe.arch} architecture: ${recipe.name}";
    const out = try interpolate(test_env.ctx.allocator, &test_env.ctx, input, &r, &r.vars);
    defer test_env.ctx.allocator.free(out);

    try std.testing.expect(std.mem.eql(u8, out, "Package for x86_64 architecture: foo"));
}

test "KV.init OutOfMemory error on key allocation failure" {
    // Test that KV.init properly returns OutOfMemory when key allocation fails
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_allocator.allocator();

    const result = KV.init(allocator, "test-key", "test-value");
    try std.testing.expectError(RecipeError.OutOfMemory, result);
}

test "KV.init OutOfMemory error on value allocation failure" {
    // Test that KV.init properly cleans up key when value allocation fails (tests errdefer)
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing_allocator.allocator();

    const result = KV.init(allocator, "test-key", "test-value");
    try std.testing.expectError(RecipeError.OutOfMemory, result);
    // If errdefer is working correctly, the key should have been freed and no leak occurs
}

test "parse: simple recipe with required fields" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "hello"
        \\    version "1.2.3"
        \\    release 1
        \\}
        \\
        \\build {
        \\    script "make"
        \\}
        \\
        \\package "hello" {
        \\    files "usr/bin/*"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    try std.testing.expectEqualStrings("hello", r.name);
    try std.testing.expectEqualStrings("1.2.3", r.version);
    try std.testing.expectEqual(@as(u32, 1), r.release);
    try std.testing.expectEqual(false, r.needs_root);
    try std.testing.expectEqual(@as(usize, 1), r.packages.items.len);
    try std.testing.expectEqualStrings("hello", r.packages.items[0].name);
}

test "parse: full recipe with all fields" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "llvm"
        \\    version "20.1.8"
        \\    release 1
        \\    description "LLVM compiler infrastructure"
        \\    url "https://llvm.org"
        \\    licenses "Apache-2.0"
        \\    archs "x86_64" "aarch64"
        \\    depends "cmake" "ninja"
        \\    needs-root true
        \\}
        \\
        \\vars {
        \\    major "20"
        \\}
        \\
        \\source "https://example.org/llvm-20.1.8.tar.xz" {
        \\    blake3 "abc123def456"
        \\}
        \\
        \\prepare {
        \\    script "mkdir -p build"
        \\}
        \\
        \\build {
        \\    script "cmake && make"
        \\}
        \\
        \\check {
        \\    script "make test"
        \\}
        \\
        \\install {
        \\    script "make install"
        \\}
        \\
        \\package "llvm" {
        \\    files "usr/bin/*" "usr/lib/*.so"
        \\}
        \\
        \\package "llvm-dev" {
        \\    files "usr/include/*" "usr/lib/*.a"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    // Metadata
    try std.testing.expectEqualStrings("llvm", r.name);
    try std.testing.expectEqualStrings("20.1.8", r.version);
    try std.testing.expectEqual(@as(u32, 1), r.release);
    try std.testing.expectEqualStrings("LLVM compiler infrastructure", r.description);
    try std.testing.expectEqualStrings("https://llvm.org", r.url.?);
    try std.testing.expectEqual(true, r.needs_root);

    // Arrays
    try std.testing.expectEqual(@as(usize, 1), r.licenses.items.len);
    try std.testing.expectEqualStrings("Apache-2.0", r.licenses.items[0]);

    try std.testing.expectEqual(@as(usize, 2), r.supported_archs.items.len);
    try std.testing.expectEqualStrings("x86_64", r.supported_archs.items[0]);
    try std.testing.expectEqualStrings("aarch64", r.supported_archs.items[1]);

    try std.testing.expectEqual(@as(usize, 2), r.depends.items.len);
    try std.testing.expectEqualStrings("cmake", r.depends.items[0]);
    try std.testing.expectEqualStrings("ninja", r.depends.items[1]);

    // Vars
    try std.testing.expectEqual(@as(usize, 1), r.vars.items.len);
    try std.testing.expectEqualStrings("major", r.vars.items[0].key);
    try std.testing.expectEqualStrings("20", r.vars.items[0].value);

    // Sources
    try std.testing.expectEqual(@as(usize, 1), r.sources.items.len);
    try std.testing.expectEqualStrings("https://example.org/llvm-20.1.8.tar.xz", r.sources.items[0].url);
    try std.testing.expectEqualStrings("abc123def456", r.sources.items[0].blake3.?);

    // Phases
    try std.testing.expectEqualStrings("mkdir -p build", r.prepare.?);
    try std.testing.expectEqualStrings("cmake && make", r.build_phase.?);
    try std.testing.expectEqualStrings("make test", r.check.?);
    try std.testing.expectEqualStrings("make install", r.install_phase.?);

    // Packages
    try std.testing.expectEqual(@as(usize, 2), r.packages.items.len);
    try std.testing.expectEqualStrings("llvm", r.packages.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), r.packages.items[0].pkgfiles.items.len);
    try std.testing.expectEqualStrings("usr/bin/*", r.packages.items[0].pkgfiles.items[0]);

    try std.testing.expectEqualStrings("llvm-dev", r.packages.items[1].name);
    try std.testing.expectEqual(@as(usize, 2), r.packages.items[1].pkgfiles.items.len);
}

test "parse expands recipe and vars placeholders in package files patterns" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "libfoo"
        \\    version "2.4.0"
        \\    release 1
        \\}
        \\
        \\vars {
        \\    soname "2"
        \\}
        \\
        \\build {
        \\    script "true"
        \\}
        \\
        \\package "libfoo" {
        \\    files "usr/lib/libfoo.so.${vars.soname}" "usr/share/doc/libfoo-${recipe.version}/"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.packages.items.len);
    try std.testing.expectEqual(@as(usize, 2), r.packages.items[0].pkgfiles.items.len);
    try std.testing.expectEqualStrings("usr/lib/libfoo.so.2", r.packages.items[0].pkgfiles.items[0]);
    try std.testing.expectEqualStrings("usr/share/doc/libfoo-2.4.0/", r.packages.items[0].pkgfiles.items[1]);
}

test "parse: missing recipe node returns error" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\build {
        \\    script "make"
        \\}
        \\package "foo" {
        \\    files "*"
        \\}
    ;

    const result = parse(&test_env.ctx, kdl_text);
    try std.testing.expectError(RecipeError.InvalidInput, result);
}

test "parse: missing package node returns error" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const kdl_text =
        \\recipe {
        \\    name "foo"
        \\    version "1.0"
        \\    release 1
        \\}
        \\build {
        \\    script "make"
        \\}
    ;

    const result = parse(&test_env.ctx, kdl_text);
    try std.testing.expectError(RecipeError.InvalidInput, result);
}

test "parse: env properties parsed" {
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
        \\    env CC="clang" CXX="clang++"
        \\}
        \\
        \\build {
        \\    env CFLAGS="-O2"
        \\    script "make"
        \\}
        \\
        \\package "envtest" {
        \\    files "*"
        \\}
    ;

    var r = try parse(&test_env.ctx, kdl_text);
    defer r.deinit();

    // Check recipe env
    try std.testing.expectEqual(@as(usize, 2), r.env.items.len);

    // Check build env
    try std.testing.expectEqual(@as(usize, 1), r.build_env.items.len);
    try std.testing.expectEqualStrings("CFLAGS", r.build_env.items[0].key);
    try std.testing.expectEqualStrings("-O2", r.build_env.items[0].value);
}

test "validateFile accepts a valid recipe file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const recipe_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "recipe.kdl" });
    defer test_env.ctx.allocator.free(recipe_path);

    var recipe_file = try path.makePathAndOpenFile(recipe_path);
    defer recipe_file.close(path.currentIo());

    try recipe_file.writeStreamingAll(path.currentIo(),
        \\recipe {
        \\    name "demo"
        \\    version "1.0.0"
        \\    release 1
        \\}
        \\build {
        \\    script "true"
        \\}
        \\package "demo" {
        \\    files "usr/bin/demo"
        \\}
    );

    try validateFile(&test_env.ctx, recipe_path);
}

test "validateFile rewrites parse diagnostics to the recipe path" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const recipe_path = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "bad-recipe.kdl" });
    defer test_env.ctx.allocator.free(recipe_path);

    var recipe_file = try path.makePathAndOpenFile(recipe_path);
    defer recipe_file.close(path.currentIo());

    try recipe_file.writeStreamingAll(path.currentIo(),
        \\recipe {
        \\    name "demo"
        \\    version "1.0.0"
        \\    release 1
        \\    bogus "nope"
        \\}
        \\package "demo" {
        \\    files "usr/bin/demo"
        \\}
    );

    try std.testing.expectError(RecipeError.InvalidInput, validateFile(&test_env.ctx, recipe_path));
    const diag = test_env.ctx.getDiagnosticContext();
    try std.testing.expect(diag.subject != null);
    try std.testing.expectEqualStrings(recipe_path, diag.subject.?);
}
