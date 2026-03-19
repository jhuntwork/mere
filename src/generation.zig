const std = @import("std");
const errors = @import("errors.zig");
const path_mod = @import("path.zig");

const Std = errors.StandardErrors;
pub const GenerationError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    ParseError,
    InvalidManifest,
    GenerationNotFound,
    ProfilesNotFound,
    NoCurrentGeneration,
    NoPreviousGeneration,
};

pub const MANIFEST_SCHEMA_VERSION: u32 = 1;
pub const MANIFEST_FILENAME = "manifest.json";
pub const REALIZATION_FILENAME = "realization.v1";
pub const GENERATION_PREFIX = "gen-";
pub const CURRENT_SYMLINK = "current";
const REALIZATION_MAGIC: *const [8]u8 = "MERERLZ1";
const REALIZATION_SCHEMA_VERSION: u32 = 1;
const REALIZATION_HEADER_SIZE: usize = 8 + 4 + 4;
const MAX_REALIZATION_FILE_SIZE: u64 = 128 * 1024 * 1024;

pub const PackageEntry = struct {
    name: []const u8,
    version: []const u8,
    release: u32,
    arch: []const u8,
    store_path: []const u8,
    content_hash: []const u8, // 64 hex chars

    pub fn deinit(self: *PackageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.arch);
        allocator.free(self.store_path);
        allocator.free(self.content_hash);
    }
};

pub const RealizationEntry = struct {
    path: []const u8,
    owner_package_index: u32,

    pub fn deinit(self: *RealizationEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const RealizationData = struct {
    entries: std.ArrayList(RealizationEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RealizationData {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RealizationData) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addEntry(self: *RealizationData, path: []const u8, owner_package_index: u32) GenerationError!void {
        try validateRealizationPath(path);
        const path_copy = self.allocator.dupe(u8, path) catch return GenerationError.OutOfMemory;
        errdefer self.allocator.free(path_copy);
        self.entries.append(self.allocator, .{
            .path = path_copy,
            .owner_package_index = owner_package_index,
        }) catch return GenerationError.OutOfMemory;
    }

    pub fn canonicalize(self: *RealizationData) GenerationError!void {
        std.mem.sort(RealizationEntry, self.entries.items, {}, lessThanRealizationEntry);
        try self.validateCanonical();
    }

    pub fn validateCanonical(self: *const RealizationData) GenerationError!void {
        var prev: ?[]const u8 = null;
        for (self.entries.items) |entry| {
            try validateRealizationPath(entry.path);
            if (prev) |previous| {
                if (!std.mem.lessThan(u8, previous, entry.path)) return GenerationError.InvalidManifest;
            }
            prev = entry.path;
        }
    }

    pub fn encode(self: *const RealizationData, allocator: std.mem.Allocator) GenerationError![]u8 {
        try self.validateCanonical();

        var total_size: usize = REALIZATION_HEADER_SIZE;
        for (self.entries.items) |entry| {
            total_size = std.math.add(usize, total_size, 4) catch return GenerationError.OutOfMemory;
            total_size = std.math.add(usize, total_size, 4) catch return GenerationError.OutOfMemory;
            total_size = std.math.add(usize, total_size, entry.path.len) catch return GenerationError.OutOfMemory;
        }

        const buffer = allocator.alloc(u8, total_size) catch return GenerationError.OutOfMemory;
        errdefer allocator.free(buffer);

        var offset: usize = 0;
        @memcpy(buffer[offset..][0..8], REALIZATION_MAGIC);
        offset += 8;

        std.mem.writeInt(u32, buffer[offset..][0..4], REALIZATION_SCHEMA_VERSION, .little);
        offset += 4;

        const entry_count: u32 = @intCast(self.entries.items.len);
        std.mem.writeInt(u32, buffer[offset..][0..4], entry_count, .little);
        offset += 4;

        for (self.entries.items) |entry| {
            std.mem.writeInt(u32, buffer[offset..][0..4], entry.owner_package_index, .little);
            offset += 4;

            const path_len: u32 = @intCast(entry.path.len);
            std.mem.writeInt(u32, buffer[offset..][0..4], path_len, .little);
            offset += 4;

            @memcpy(buffer[offset..][0..entry.path.len], entry.path);
            offset += entry.path.len;
        }

        return buffer;
    }

    pub fn decode(allocator: std.mem.Allocator, input: []const u8) GenerationError!RealizationData {
        if (input.len < REALIZATION_HEADER_SIZE) return GenerationError.InvalidManifest;

        var offset: usize = 0;
        if (!std.mem.eql(u8, input[offset..][0..8], REALIZATION_MAGIC)) return GenerationError.InvalidManifest;
        offset += 8;

        const schema_version = std.mem.readInt(u32, input[offset..][0..4], .little);
        if (schema_version != REALIZATION_SCHEMA_VERSION) return GenerationError.InvalidManifest;
        offset += 4;

        const entry_count = std.mem.readInt(u32, input[offset..][0..4], .little);
        offset += 4;

        var data = RealizationData.init(allocator);
        errdefer data.deinit();

        try data.entries.ensureTotalCapacity(allocator, entry_count);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (offset + 8 > input.len) return GenerationError.InvalidManifest;

            const owner_package_index = std.mem.readInt(u32, input[offset..][0..4], .little);
            offset += 4;

            const path_len = std.mem.readInt(u32, input[offset..][0..4], .little);
            offset += 4;
            if (offset + path_len > input.len) return GenerationError.InvalidManifest;

            const path_copy = allocator.dupe(u8, input[offset .. offset + path_len]) catch {
                return GenerationError.OutOfMemory;
            };
            data.entries.append(allocator, .{
                .path = path_copy,
                .owner_package_index = owner_package_index,
            }) catch {
                allocator.free(path_copy);
                return GenerationError.OutOfMemory;
            };
            offset += path_len;
        }

        if (offset != input.len) return GenerationError.InvalidManifest;
        try data.validateCanonical();
        return data;
    }
};

pub const GenerationManifest = struct {
    schema_version: u32,
    generation: ?u32,
    created_at: u64, // Unix epoch seconds
    packages: std.ArrayList(PackageEntry),

    // Optional fields
    parent_generation: ?u32,
    notes: ?[]const u8,
    selected_profile: ?[]const u8,
    tool_version: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, generation_num: u32) GenerationManifest {
        return GenerationManifest{
            .schema_version = MANIFEST_SCHEMA_VERSION,
            .generation = generation_num,
            .created_at = @intCast(std.Io.Clock.real.now(path_mod.currentIo()).toSeconds()),
            .packages = .empty,
            .parent_generation = null,
            .notes = null,
            .selected_profile = null,
            .tool_version = null,
            .allocator = allocator,
        };
    }

    pub fn initRoot(allocator: std.mem.Allocator) GenerationManifest {
        return GenerationManifest{
            .schema_version = MANIFEST_SCHEMA_VERSION,
            .generation = null,
            .created_at = @intCast(std.Io.Clock.real.now(path_mod.currentIo()).toSeconds()),
            .packages = .empty,
            .parent_generation = null,
            .notes = null,
            .selected_profile = null,
            .tool_version = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GenerationManifest) void {
        for (self.packages.items) |*pkg| {
            pkg.deinit(self.allocator);
        }
        self.packages.deinit(self.allocator);

        if (self.notes) |n| self.allocator.free(n);
        if (self.selected_profile) |s| self.allocator.free(s);
        if (self.tool_version) |t| self.allocator.free(t);
    }

    pub fn addPackage(
        self: *GenerationManifest,
        name: []const u8,
        version: []const u8,
        release: u32,
        arch: []const u8,
        store_path: []const u8,
        content_hash: []const u8,
    ) GenerationError!void {
        const entry = PackageEntry{
            .name = self.allocator.dupe(u8, name) catch return GenerationError.OutOfMemory,
            .version = self.allocator.dupe(u8, version) catch return GenerationError.OutOfMemory,
            .release = release,
            .arch = self.allocator.dupe(u8, arch) catch return GenerationError.OutOfMemory,
            .store_path = self.allocator.dupe(u8, store_path) catch return GenerationError.OutOfMemory,
            .content_hash = self.allocator.dupe(u8, content_hash) catch return GenerationError.OutOfMemory,
        };

        self.packages.append(self.allocator, entry) catch return GenerationError.OutOfMemory;
    }

    pub fn encode(self: *const GenerationManifest, allocator: std.mem.Allocator) GenerationError![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        buffer.appendSlice(allocator, "{\n") catch return GenerationError.OutOfMemory;

        const schema_line = std.fmt.allocPrint(allocator, "  \"schema_version\": {d},\n", .{self.schema_version}) catch return GenerationError.OutOfMemory;
        defer allocator.free(schema_line);
        buffer.appendSlice(allocator, schema_line) catch return GenerationError.OutOfMemory;

        if (self.generation) |generation_num| {
            const gen_line = std.fmt.allocPrint(allocator, "  \"generation\": {d},\n", .{generation_num}) catch return GenerationError.OutOfMemory;
            defer allocator.free(gen_line);
            buffer.appendSlice(allocator, gen_line) catch return GenerationError.OutOfMemory;
        }

        const created_line = std.fmt.allocPrint(allocator, "  \"created_at\": {d},\n", .{self.created_at}) catch return GenerationError.OutOfMemory;
        defer allocator.free(created_line);
        buffer.appendSlice(allocator, created_line) catch return GenerationError.OutOfMemory;

        if (self.parent_generation) |parent| {
            const parent_line = std.fmt.allocPrint(allocator, "  \"parent_generation\": {d},\n", .{parent}) catch return GenerationError.OutOfMemory;
            defer allocator.free(parent_line);
            buffer.appendSlice(allocator, parent_line) catch return GenerationError.OutOfMemory;
        }

        if (self.notes) |notes| {
            buffer.appendSlice(allocator, "  \"notes\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, notes);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;
        }

        if (self.selected_profile) |profile| {
            buffer.appendSlice(allocator, "  \"selected_profile\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, profile);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;
        }

        if (self.tool_version) |ver| {
            buffer.appendSlice(allocator, "  \"tool_version\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, ver);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;
        }

        buffer.appendSlice(allocator, "  \"packages\": [\n") catch return GenerationError.OutOfMemory;

        for (self.packages.items, 0..) |pkg, i| {
            buffer.appendSlice(allocator, "    {\n") catch return GenerationError.OutOfMemory;

            buffer.appendSlice(allocator, "      \"name\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, pkg.name);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;

            buffer.appendSlice(allocator, "      \"version\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, pkg.version);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;

            const release_line = std.fmt.allocPrint(allocator, "      \"release\": {d},\n", .{pkg.release}) catch return GenerationError.OutOfMemory;
            defer allocator.free(release_line);
            buffer.appendSlice(allocator, release_line) catch return GenerationError.OutOfMemory;

            buffer.appendSlice(allocator, "      \"arch\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, pkg.arch);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;

            buffer.appendSlice(allocator, "      \"store_path\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, pkg.store_path);
            buffer.appendSlice(allocator, "\",\n") catch return GenerationError.OutOfMemory;

            buffer.appendSlice(allocator, "      \"content_hash\": \"") catch return GenerationError.OutOfMemory;
            try appendJsonEscaped(&buffer, allocator, pkg.content_hash);
            buffer.appendSlice(allocator, "\"\n") catch return GenerationError.OutOfMemory;

            if (i < self.packages.items.len - 1) {
                buffer.appendSlice(allocator, "    },\n") catch return GenerationError.OutOfMemory;
            } else {
                buffer.appendSlice(allocator, "    }\n") catch return GenerationError.OutOfMemory;
            }
        }

        buffer.appendSlice(allocator, "  ]\n") catch return GenerationError.OutOfMemory;
        buffer.appendSlice(allocator, "}\n") catch return GenerationError.OutOfMemory;

        return buffer.toOwnedSlice(allocator) catch return GenerationError.OutOfMemory;
    }

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) GenerationError!GenerationManifest {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
            return GenerationError.ParseError;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return GenerationError.InvalidManifest;
        }

        const obj = root.object;

        const schema_version = blk: {
            const v = obj.get("schema_version") orelse return GenerationError.InvalidManifest;
            if (v != .integer) return GenerationError.InvalidManifest;
            if (v.integer < 0 or v.integer > std.math.maxInt(u32)) {
                return GenerationError.InvalidManifest;
            }
            break :blk @as(u32, @intCast(v.integer));
        };

        if (schema_version != MANIFEST_SCHEMA_VERSION) {
            return GenerationError.InvalidManifest;
        }

        const generation = blk: {
            const v = obj.get("generation") orelse break :blk null;
            if (v != .integer) return GenerationError.InvalidManifest;
            if (v.integer < 0 or v.integer > std.math.maxInt(u32)) {
                return GenerationError.InvalidManifest;
            }
            break :blk @as(?u32, @intCast(v.integer));
        };

        const created_at = blk: {
            const v = obj.get("created_at") orelse return GenerationError.InvalidManifest;
            if (v != .integer) return GenerationError.InvalidManifest;
            if (v.integer < 0) {
                return GenerationError.InvalidManifest;
            }
            break :blk @as(u64, @intCast(v.integer));
        };

        var manifest = GenerationManifest{
            .schema_version = schema_version,
            .generation = generation,
            .created_at = created_at,
            .packages = .empty,
            .parent_generation = null,
            .notes = null,
            .selected_profile = null,
            .tool_version = null,
            .allocator = allocator,
        };
        errdefer manifest.deinit();

        if (obj.get("parent_generation")) |v| {
            if (v == .integer) {
                if (v.integer < 0 or v.integer > std.math.maxInt(u32)) {
                    return GenerationError.InvalidManifest;
                }
                manifest.parent_generation = @as(u32, @intCast(v.integer));
            }
        }

        if (obj.get("notes")) |v| {
            if (v == .string) {
                manifest.notes = allocator.dupe(u8, v.string) catch return GenerationError.OutOfMemory;
            }
        }

        if (obj.get("selected_profile")) |v| {
            if (v == .string) {
                manifest.selected_profile = allocator.dupe(u8, v.string) catch return GenerationError.OutOfMemory;
            }
        }

        if (obj.get("tool_version")) |v| {
            if (v == .string) {
                manifest.tool_version = allocator.dupe(u8, v.string) catch return GenerationError.OutOfMemory;
            }
        }

        const packages_val = obj.get("packages") orelse return GenerationError.InvalidManifest;
        if (packages_val != .array) return GenerationError.InvalidManifest;

        for (packages_val.array.items) |pkg_val| {
            if (pkg_val != .object) return GenerationError.InvalidManifest;
            const pkg_obj = pkg_val.object;

            const name = blk: {
                const v = pkg_obj.get("name") orelse return GenerationError.InvalidManifest;
                if (v != .string) return GenerationError.InvalidManifest;
                break :blk v.string;
            };

            const version = blk: {
                const v = pkg_obj.get("version") orelse return GenerationError.InvalidManifest;
                if (v != .string) return GenerationError.InvalidManifest;
                break :blk v.string;
            };

            const release = blk: {
                const v = pkg_obj.get("release") orelse return GenerationError.InvalidManifest;
                if (v != .integer) return GenerationError.InvalidManifest;
                if (v.integer < 0 or v.integer > std.math.maxInt(u32)) {
                    return GenerationError.InvalidManifest;
                }
                break :blk @as(u32, @intCast(v.integer));
            };

            const arch = blk: {
                const v = pkg_obj.get("arch") orelse return GenerationError.InvalidManifest;
                if (v != .string) return GenerationError.InvalidManifest;
                break :blk v.string;
            };

            const store_path = blk: {
                const v = pkg_obj.get("store_path") orelse return GenerationError.InvalidManifest;
                if (v != .string) return GenerationError.InvalidManifest;
                break :blk v.string;
            };

            const content_hash = blk: {
                const v = pkg_obj.get("content_hash") orelse return GenerationError.InvalidManifest;
                if (v != .string) return GenerationError.InvalidManifest;
                break :blk v.string;
            };

            try manifest.addPackage(name, version, release, arch, store_path, content_hash);
        }

        return manifest;
    }
};

fn appendJsonEscaped(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) GenerationError!void {
    for (s) |c| {
        switch (c) {
            '"' => buffer.appendSlice(allocator, "\\\"") catch return GenerationError.OutOfMemory,
            '\\' => buffer.appendSlice(allocator, "\\\\") catch return GenerationError.OutOfMemory,
            '\n' => buffer.appendSlice(allocator, "\\n") catch return GenerationError.OutOfMemory,
            '\r' => buffer.appendSlice(allocator, "\\r") catch return GenerationError.OutOfMemory,
            '\t' => buffer.appendSlice(allocator, "\\t") catch return GenerationError.OutOfMemory,
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const escaped = std.fmt.bufPrint(&buf, "\\u00{X:0>2}", .{c}) catch {
                        return GenerationError.OutOfMemory;
                    };
                    buffer.appendSlice(allocator, escaped) catch return GenerationError.OutOfMemory;
                } else {
                    buffer.append(allocator, c) catch return GenerationError.OutOfMemory;
                }
            },
        }
    }
}

fn lessThanRealizationEntry(_: void, left: RealizationEntry, right: RealizationEntry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

fn validateRealizationPath(path: []const u8) GenerationError!void {
    if (path.len == 0) return GenerationError.InvalidManifest;
    if (path[0] == '/' or path[path.len - 1] == '/') return GenerationError.InvalidManifest;

    var components = std.mem.tokenizeScalar(u8, path, '/');
    var count: usize = 0;
    while (components.next()) |component| {
        count += 1;
        if (component.len == 0) return GenerationError.InvalidManifest;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return GenerationError.InvalidManifest;
        }
    }
    if (count == 0) return GenerationError.InvalidManifest;
}

pub fn getNextGenerationNumber(profile_dir: []const u8) GenerationError!u32 {
    var dir = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => GenerationError.ProfilesNotFound,
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    defer dir.close(path_mod.currentIo());

    var max_gen: u32 = 0;

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(path_mod.currentIo()) catch |err| {
            return switch (err) {
                error.AccessDenied => GenerationError.PermissionDenied,
                else => GenerationError.FileSystem,
            };
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind != .directory) continue;

        if (std.mem.startsWith(u8, e.name, GENERATION_PREFIX)) {
            const num_str = e.name[GENERATION_PREFIX.len..];
            const num = std.fmt.parseInt(u32, num_str, 10) catch continue;
            if (num > max_gen) {
                max_gen = num;
            }
        }
    }
    return max_gen + 1;
}

pub fn getGenerationPath(allocator: std.mem.Allocator, profile_dir: []const u8, generation: u32) GenerationError![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/" ++ GENERATION_PREFIX ++ "{d}", .{ profile_dir, generation }) catch {
        return GenerationError.OutOfMemory;
    };
}

pub fn getProfilePath(allocator: std.mem.Allocator, profiles_dir: []const u8, profile_name: []const u8) GenerationError![]const u8 {
    return std.fs.path.join(allocator, &.{ profiles_dir, profile_name }) catch {
        return GenerationError.OutOfMemory;
    };
}

pub fn parseGenerationNumber(dir_name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, dir_name, GENERATION_PREFIX)) {
        return null;
    }
    const num_str = dir_name[GENERATION_PREFIX.len..];
    return std.fmt.parseInt(u32, num_str, 10) catch null;
}

pub fn getCurrentGeneration(profile_dir: []const u8) GenerationError!?u32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ profile_dir, CURRENT_SYMLINK }) catch {
        return GenerationError.InvalidInput;
    };

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = std.Io.Dir.readLinkAbsolute(path_mod.currentIo(), current_path, &target_buf) catch |err| {
        return switch (err) {
            error.FileNotFound => null,
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };

    return parseGenerationNumber(target_buf[0..target_len]);
}

pub fn listGenerations(
    allocator: std.mem.Allocator,
    profile_dir: []const u8,
) GenerationError![]u32 {
    var dir = std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound => GenerationError.ProfilesNotFound,
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    defer dir.close(path_mod.currentIo());

    var generations: std.ArrayList(u32) = .empty;
    errdefer generations.deinit(allocator);

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(path_mod.currentIo()) catch |err| {
            return switch (err) {
                error.AccessDenied => GenerationError.PermissionDenied,
                else => GenerationError.FileSystem,
            };
        };
        if (entry == null) break;
        const e = entry.?;

        if (e.kind != .directory) continue;

        if (parseGenerationNumber(e.name)) |num| {
            const gen_path = std.fs.path.join(allocator, &.{ profile_dir, e.name }) catch {
                return GenerationError.OutOfMemory;
            };
            defer allocator.free(gen_path);

            var manifest = readManifest(allocator, gen_path) catch |err| {
                switch (err) {
                    GenerationError.GenerationNotFound,
                    GenerationError.InvalidManifest,
                    GenerationError.ParseError,
                    => continue,
                    else => return err,
                }
            };
            manifest.deinit();

            generations.append(allocator, num) catch {
                return GenerationError.OutOfMemory;
            };
        }
    }

    const items = generations.toOwnedSlice(allocator) catch {
        return GenerationError.OutOfMemory;
    };
    std.mem.sort(u32, items, {}, std.sort.asc(u32));

    return items;
}

pub fn findPreviousGeneration(
    allocator: std.mem.Allocator,
    profile_dir: []const u8,
) GenerationError!u32 {
    const current = try getCurrentGeneration(profile_dir) orelse {
        return GenerationError.NoCurrentGeneration;
    };

    const all_gens = try listGenerations(allocator, profile_dir);
    defer allocator.free(all_gens);

    var previous: ?u32 = null;
    for (all_gens) |gen| {
        if (gen < current) {
            if (previous == null or gen > previous.?) {
                previous = gen;
            }
        }
    }

    return previous orelse GenerationError.NoPreviousGeneration;
}

test "listGenerations ignores generation without manifest.json" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    const gen1_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1_path);
    var gen1_dir = try path_mod.makePathAndOpenDir(gen1_path);
    gen1_dir.close(path_mod.currentIo());
    var manifest1 = GenerationManifest.init(allocator, 1);
    defer manifest1.deinit();
    try writeManifest(allocator, gen1_path, &manifest1);

    const gen2_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-2" });
    defer allocator.free(gen2_path);
    var gen2_dir = try path_mod.makePathAndOpenDir(gen2_path);
    gen2_dir.close(path_mod.currentIo());

    const gen3_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-3" });
    defer allocator.free(gen3_path);
    var gen3_dir = try path_mod.makePathAndOpenDir(gen3_path);
    gen3_dir.close(path_mod.currentIo());
    var manifest3 = GenerationManifest.init(allocator, 3);
    defer manifest3.deinit();
    try writeManifest(allocator, gen3_path, &manifest3);

    const gens = try listGenerations(allocator, profile_dir);
    defer allocator.free(gens);

    try std.testing.expectEqual(@as(usize, 2), gens.len);
    try std.testing.expectEqual(@as(u32, 1), gens[0]);
    try std.testing.expectEqual(@as(u32, 3), gens[1]);
}

test "listGenerations returns sorted list" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    for ([_]u32{ 3, 1, 5, 2 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        var gen_dir = try path_mod.makePathAndOpenDir(gen_path);
        gen_dir.close(path_mod.currentIo());

        var manifest = GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try writeManifest(allocator, gen_path, &manifest);
    }

    const gens = try listGenerations(allocator, profile_dir);
    defer allocator.free(gens);

    try std.testing.expectEqual(@as(usize, 4), gens.len);
    try std.testing.expectEqual(@as(u32, 1), gens[0]);
    try std.testing.expectEqual(@as(u32, 2), gens[1]);
    try std.testing.expectEqual(@as(u32, 3), gens[2]);
    try std.testing.expectEqual(@as(u32, 5), gens[3]);
}

test "getCurrentGeneration returns null when no active generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    const current = try getCurrentGeneration(profile_dir);
    try std.testing.expectEqual(@as(?u32, null), current);
}

test "findPreviousGeneration returns previous generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    for ([_]u32{ 1, 2, 3 }) |n| {
        const gen_path = try std.fmt.allocPrint(allocator, "{s}/gen-{d}", .{ profile_dir, n });
        defer allocator.free(gen_path);
        var gen_dir = try path_mod.makePathAndOpenDir(gen_path);
        gen_dir.close(path_mod.currentIo());

        var manifest = GenerationManifest.init(allocator, n);
        defer manifest.deinit();
        try writeManifest(allocator, gen_path, &manifest);
    }

    var current_handle = try std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_dir, .{});
    defer current_handle.close(path_mod.currentIo());
    current_handle.deleteFile(path_mod.currentIo(), CURRENT_SYMLINK) catch {};
    try current_handle.symLink(path_mod.currentIo(), "gen-3", CURRENT_SYMLINK, .{});

    const previous = try findPreviousGeneration(allocator, profile_dir);
    try std.testing.expectEqual(@as(u32, 2), previous);
}

test "findPreviousGeneration fails when no previous generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    const gen_path = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen_path);
    var gen_dir = try path_mod.makePathAndOpenDir(gen_path);
    gen_dir.close(path_mod.currentIo());

    var manifest = GenerationManifest.init(allocator, 1);
    defer manifest.deinit();
    try writeManifest(allocator, gen_path, &manifest);

    var current_handle = try std.Io.Dir.openDirAbsolute(path_mod.currentIo(), profile_dir, .{});
    defer current_handle.close(path_mod.currentIo());
    current_handle.deleteFile(path_mod.currentIo(), CURRENT_SYMLINK) catch {};
    try current_handle.symLink(path_mod.currentIo(), "gen-1", CURRENT_SYMLINK, .{});

    const result = findPreviousGeneration(allocator, profile_dir);
    try std.testing.expectError(GenerationError.NoPreviousGeneration, result);
}

test "findPreviousGeneration fails when no current generation" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "mere", "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    const result = findPreviousGeneration(allocator, profile_dir);
    try std.testing.expectError(GenerationError.NoCurrentGeneration, result);
}

pub fn formatGenerationName(allocator: std.mem.Allocator, generation: u32) GenerationError![]const u8 {
    return std.fmt.allocPrint(allocator, GENERATION_PREFIX ++ "{d}", .{generation}) catch {
        return GenerationError.OutOfMemory;
    };
}

pub fn readManifest(allocator: std.mem.Allocator, generation_dir: []const u8) GenerationError!GenerationManifest {
    const manifest_path = std.fs.path.join(allocator, &.{ generation_dir, MANIFEST_FILENAME }) catch {
        return GenerationError.OutOfMemory;
    };
    defer allocator.free(manifest_path);

    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(manifest_path) catch |err| {
        return switch (err) {
            error.FileNotFound => GenerationError.GenerationNotFound,
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };

    if (stat.size > 10 * 1024 * 1024) {
        return GenerationError.InvalidManifest;
    }

    const buffer = allocator.alloc(u8, @intCast(stat.size)) catch {
        return GenerationError.OutOfMemory;
    };
    defer allocator.free(buffer);

    const bytes_read = file.readPositionalAll(io, buffer, 0) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };

    if (bytes_read != stat.size) {
        return GenerationError.FileSystem;
    }

    return GenerationManifest.parse(allocator, buffer);
}

pub fn writeManifest(allocator: std.mem.Allocator, generation_dir: []const u8, manifest: *const GenerationManifest) GenerationError!void {
    const manifest_path = std.fs.path.join(allocator, &.{ generation_dir, MANIFEST_FILENAME }) catch {
        return GenerationError.OutOfMemory;
    };
    defer allocator.free(manifest_path);

    const content = try manifest.encode(allocator);
    defer allocator.free(content);

    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, manifest_path, .{}) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
}

pub fn readRealization(allocator: std.mem.Allocator, generation_dir: []const u8) GenerationError!RealizationData {
    const realization_path = std.fs.path.join(allocator, &.{ generation_dir, REALIZATION_FILENAME }) catch {
        return GenerationError.OutOfMemory;
    };
    defer allocator.free(realization_path);

    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(realization_path) catch |err| {
        return switch (err) {
            error.FileNotFound => GenerationError.GenerationNotFound,
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };

    if (stat.size > MAX_REALIZATION_FILE_SIZE) return GenerationError.InvalidManifest;

    const buffer = allocator.alloc(u8, @intCast(stat.size)) catch {
        return GenerationError.OutOfMemory;
    };
    defer allocator.free(buffer);

    const bytes_read = file.readPositionalAll(io, buffer, 0) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    if (bytes_read != @as(usize, @intCast(stat.size))) return GenerationError.FileSystem;

    return RealizationData.decode(allocator, buffer);
}

pub fn writeRealization(
    allocator: std.mem.Allocator,
    generation_dir: []const u8,
    realization: *const RealizationData,
) GenerationError!void {
    const realization_path = std.fs.path.join(allocator, &.{ generation_dir, REALIZATION_FILENAME }) catch {
        return GenerationError.OutOfMemory;
    };
    defer allocator.free(realization_path);

    const content = try realization.encode(allocator);
    defer allocator.free(content);

    const io = path_mod.currentIo();
    var file = std.Io.Dir.createFileAbsolute(io, realization_path, .{}) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
        return switch (err) {
            error.AccessDenied => GenerationError.PermissionDenied,
            else => GenerationError.FileSystem,
        };
    };
}

// Tests

test "GenerationManifest encode and parse roundtrip" {
    const allocator = std.testing.allocator;

    var manifest = GenerationManifest.init(allocator, 42);
    defer manifest.deinit();

    manifest.parent_generation = 41;
    manifest.notes = try allocator.dupe(u8, "test generation");
    manifest.tool_version = try allocator.dupe(u8, "test-version");

    try manifest.addPackage(
        "nginx",
        "1.24.0",
        1,
        "x86_64",
        "/mere/store/abc123-nginx-1.24.0/",
        "abc123def456789012345678901234567890123456789012345678901234",
    );

    try manifest.addPackage(
        "musl",
        "1.2.4",
        1,
        "x86_64",
        "/mere/store/def456-musl-1.2.4/",
        "def456abc123789012345678901234567890123456789012345678901234",
    );

    const json = try manifest.encode(allocator);
    defer allocator.free(json);

    var parsed = try GenerationManifest.parse(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.schema_version);
    try std.testing.expectEqual(@as(?u32, 42), parsed.generation);
    try std.testing.expectEqual(@as(?u32, 41), parsed.parent_generation);
    try std.testing.expectEqualStrings("test generation", parsed.notes.?);
    try std.testing.expectEqualStrings("test-version", parsed.tool_version.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.packages.items.len);

    try std.testing.expectEqualStrings("nginx", parsed.packages.items[0].name);
    try std.testing.expectEqualStrings("1.24.0", parsed.packages.items[0].version);
    try std.testing.expectEqual(@as(u32, 1), parsed.packages.items[0].release);
}

test "RealizationData encode and decode roundtrip" {
    const allocator = std.testing.allocator;

    var realization = RealizationData.init(allocator);
    defer realization.deinit();

    try realization.addEntry("usr/bin/tool", 1);
    try realization.addEntry("etc-defaults/myapp/config.conf", 0);
    try realization.canonicalize();

    const encoded = try realization.encode(allocator);
    defer allocator.free(encoded);

    var decoded = try RealizationData.decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.entries.items.len);
    try std.testing.expectEqualStrings("etc-defaults/myapp/config.conf", decoded.entries.items[0].path);
    try std.testing.expectEqual(@as(u32, 0), decoded.entries.items[0].owner_package_index);
    try std.testing.expectEqualStrings("usr/bin/tool", decoded.entries.items[1].path);
    try std.testing.expectEqual(@as(u32, 1), decoded.entries.items[1].owner_package_index);
}

test "GenerationManifest parse rejects wrong schema version" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "schema_version": 99,
        \\  "generation": 1,
        \\  "created_at": 1234567890,
        \\  "packages": []
        \\}
    ;

    const result = GenerationManifest.parse(allocator, json);
    try std.testing.expectError(GenerationError.InvalidManifest, result);
}

test "GenerationManifest parse accepts named profile root manifest without generation" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "schema_version": 1,
        \\  "created_at": 1234567890,
        \\  "packages": []
        \\}
    ;
    var parsed = try GenerationManifest.parse(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), parsed.generation);
}

test "GenerationManifest parse rejects missing required fields" {
    const allocator = std.testing.allocator;

    // Missing packages
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "generation": 1,
        \\  "created_at": 1234567890
        \\}
    ;
    try std.testing.expectError(GenerationError.InvalidManifest, GenerationManifest.parse(allocator, json));
}

test "GenerationManifest parse rejects negative integers" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "schema_version": 1,
        \\  "generation": -1,
        \\  "created_at": 1234567890,
        \\  "packages": []
        \\}
    ;

    const result = GenerationManifest.parse(allocator, json);
    try std.testing.expectError(GenerationError.InvalidManifest, result);
}

test "getNextGenerationNumber with existing generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory (simulating /mere/profiles/system/)
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    // Create some generation directories using new gen-N naming
    const gen1 = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1);
    var gen1_dir = try path_mod.makePathAndOpenDir(gen1);
    gen1_dir.close(path_mod.currentIo());

    const gen5 = try std.fs.path.join(allocator, &.{ profile_dir, "gen-5" });
    defer allocator.free(gen5);
    var gen5_dir = try path_mod.makePathAndOpenDir(gen5);
    gen5_dir.close(path_mod.currentIo());

    const gen3 = try std.fs.path.join(allocator, &.{ profile_dir, "gen-3" });
    defer allocator.free(gen3);
    var gen3_dir = try path_mod.makePathAndOpenDir(gen3);
    gen3_dir.close(path_mod.currentIo());

    // Also create a non-matching directory (should be ignored)
    const other = try std.fs.path.join(allocator, &.{ profile_dir, "other-dir" });
    defer allocator.free(other);
    var other_dir = try path_mod.makePathAndOpenDir(other);
    other_dir.close(path_mod.currentIo());

    const next = try getNextGenerationNumber(profile_dir);
    try std.testing.expectEqual(@as(u32, 6), next);
}

test "getNextGenerationNumber with no generations" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create empty profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    const next = try getNextGenerationNumber(profile_dir);
    try std.testing.expectEqual(@as(u32, 1), next);
}

test "getNextGenerationNumber with nonexistent profile dir" {
    const result = getNextGenerationNumber("/nonexistent/profiles/system");
    try std.testing.expectError(GenerationError.ProfilesNotFound, result);
}

test "writeManifest and readManifest" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create generation directory (new nested layout: profile/gen-N)
    const gen_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system", "gen-1" });
    defer allocator.free(gen_dir);
    var gen_dir_handle = try path_mod.makePathAndOpenDir(gen_dir);
    gen_dir_handle.close(path_mod.currentIo());

    // Create and write manifest
    var manifest = GenerationManifest.init(allocator, 1);
    defer manifest.deinit();

    try manifest.addPackage(
        "test-pkg",
        "1.0.0",
        1,
        "x86_64",
        "/mere/store/abc-test-pkg-1.0.0/",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    );

    try writeManifest(allocator, gen_dir, &manifest);

    // Read it back
    var read_manifest = try readManifest(allocator, gen_dir);
    defer read_manifest.deinit();

    try std.testing.expectEqual(@as(?u32, 1), read_manifest.generation);
    try std.testing.expectEqual(@as(usize, 1), read_manifest.packages.items.len);
    try std.testing.expectEqualStrings("test-pkg", read_manifest.packages.items[0].name);
}

test "writeRealization and readRealization" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;
    const gen_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system", "gen-1" });
    defer allocator.free(gen_dir);
    var gen_dir_handle = try path_mod.makePathAndOpenDir(gen_dir);
    gen_dir_handle.close(path_mod.currentIo());

    var realization = RealizationData.init(allocator);
    defer realization.deinit();
    try realization.addEntry("usr/bin/tool", 0);
    try realization.addEntry("usr/lib/libhello.so", 1);
    try realization.canonicalize();

    try writeRealization(allocator, gen_dir, &realization);

    var read_realization = try readRealization(allocator, gen_dir);
    defer read_realization.deinit();

    try std.testing.expectEqual(@as(usize, 2), read_realization.entries.items.len);
    try std.testing.expectEqualStrings("usr/bin/tool", read_realization.entries.items[0].path);
    try std.testing.expectEqual(@as(u32, 0), read_realization.entries.items[0].owner_package_index);
    try std.testing.expectEqualStrings("usr/lib/libhello.so", read_realization.entries.items[1].path);
    try std.testing.expectEqual(@as(u32, 1), read_realization.entries.items[1].owner_package_index);
}

test "getGenerationPath" {
    const allocator = std.testing.allocator;

    // getGenerationPath now takes profile_dir (not profiles_dir) and returns gen-N
    const path = try getGenerationPath(allocator, "/mere/profiles/system", 42);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/mere/profiles/system/gen-42", path);
}

test "getProfilePath" {
    const allocator = std.testing.allocator;

    const path = try getProfilePath(allocator, "/mere/profiles", "system");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/mere/profiles/system", path);

    const dev_path = try getProfilePath(allocator, "/mere/profiles", "dev");
    defer allocator.free(dev_path);

    try std.testing.expectEqualStrings("/mere/profiles/dev", dev_path);
}

test "parseGenerationNumber" {
    try std.testing.expectEqual(@as(?u32, 1), parseGenerationNumber("gen-1"));
    try std.testing.expectEqual(@as(?u32, 42), parseGenerationNumber("gen-42"));
    try std.testing.expectEqual(@as(?u32, 999), parseGenerationNumber("gen-999"));
    try std.testing.expectEqual(@as(?u32, null), parseGenerationNumber("system-1"));
    try std.testing.expectEqual(@as(?u32, null), parseGenerationNumber("gen-"));
    try std.testing.expectEqual(@as(?u32, null), parseGenerationNumber("gen-abc"));
    try std.testing.expectEqual(@as(?u32, null), parseGenerationNumber("other"));
}

test "formatGenerationName" {
    const allocator = std.testing.allocator;

    const name1 = try formatGenerationName(allocator, 1);
    defer allocator.free(name1);
    try std.testing.expectEqualStrings("gen-1", name1);

    const name42 = try formatGenerationName(allocator, 42);
    defer allocator.free(name42);
    try std.testing.expectEqualStrings("gen-42", name42);
}

// gen-1, gen-5 exist → next generation is gen-6 (max + 1, not gap-filling)
test "getNextGenerationNumber handles gaps in sequence" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const allocator = test_env.ctx.allocator;

    // Create profile directory
    const profile_dir = try std.fs.path.join(allocator, &.{ test_env.path, "profiles", "system" });
    defer allocator.free(profile_dir);
    var profile_dir_handle = try path_mod.makePathAndOpenDir(profile_dir);
    profile_dir_handle.close(path_mod.currentIo());

    // Create gen-1 and gen-5 (gap: 2, 3, 4 missing)
    const gen1 = try std.fs.path.join(allocator, &.{ profile_dir, "gen-1" });
    defer allocator.free(gen1);
    var gen1_dir = try path_mod.makePathAndOpenDir(gen1);
    gen1_dir.close(path_mod.currentIo());

    const gen5 = try std.fs.path.join(allocator, &.{ profile_dir, "gen-5" });
    defer allocator.free(gen5);
    var gen5_dir = try path_mod.makePathAndOpenDir(gen5);
    gen5_dir.close(path_mod.currentIo());

    // Next should be 6 (max(1,5) + 1), not 2 (gap-filling)
    const next = try getNextGenerationNumber(profile_dir);
    try std.testing.expectEqual(@as(u32, 6), next);
}
