// Requested packages file management
//
// This module handles reading and writing requested.kdl files, which track
// user-requested packages for profiles. The requested.kdl file represents
// user intent - the packages explicitly requested, not the full dependency closure.
//
// Format:
// ```kdl
// package "vim"
// package "git"
// package "zig" version="0.12"
// ```

const std = @import("std");
const kdl = @import("kdl.zig");
const path = @import("path.zig");
const errors = @import("errors.zig");

/// Error type for requested.kdl operations
const Std = errors.StandardErrors;
pub const RequestedError = Std.OutOfMemory || Std.FileSystem || error{ParseError};

/// A single requested package entry
pub const RequestedPackage = struct {
    /// Package name
    name: []const u8,
    /// Optional version constraint (null means any version)
    version: ?[]const u8,

    /// Deep copy this entry using the given allocator
    pub fn dupe(self: *const RequestedPackage, allocator: std.mem.Allocator) !RequestedPackage {
        const name_copy = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name_copy);

        const version_copy = if (self.version) |v|
            try allocator.dupe(u8, v)
        else
            null;

        return RequestedPackage{
            .name = name_copy,
            .version = version_copy,
        };
    }

    /// Free memory owned by this entry
    pub fn deinit(self: *RequestedPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.version) |v| {
            allocator.free(v);
        }
    }
};

/// Load requested packages from a requested.kdl file.
/// Returns an ArrayList of RequestedPackage entries. Caller owns the memory.
pub fn loadRequested(allocator: std.mem.Allocator, file_path: []const u8) RequestedError!std.ArrayList(RequestedPackage) {
    var packages = std.ArrayList(RequestedPackage){};
    errdefer {
        for (packages.items) |*pkg| pkg.deinit(allocator);
        packages.deinit(allocator);
    }

    // Try to open the file
    const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return packages; // Return empty list if file doesn't exist
        }
        return RequestedError.FileSystem;
    };
    defer file.close();

    // Read file content
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return RequestedError.OutOfMemory;
    };
    defer allocator.free(content);

    // Handle empty file
    if (content.len == 0) {
        return packages;
    }

    // Parse KDL
    var nodes = kdl.parseDocument(allocator, content) catch {
        return RequestedError.ParseError;
    };
    defer {
        for (nodes.items) |*node| node.deinit();
        nodes.deinit(allocator);
    }

    // Look for package nodes
    for (nodes.items) |node| {
        if (std.mem.eql(u8, node.name, "package")) {
            // package nodes must have exactly one string argument (the package name).
            if (node.arguments.items.len != 1) {
                return RequestedError.ParseError;
            }
            const pkg_name = node.getFirstArgString() orelse return RequestedError.ParseError;
            const name_copy = try allocator.dupe(u8, pkg_name);
            errdefer allocator.free(name_copy);

            // If version is present it must be a string.
            var version: ?[]const u8 = null;
            if (node.getProperty("version") != null) {
                const version_string = node.getStringProperty("version") orelse return RequestedError.ParseError;
                version = try allocator.dupe(u8, version_string);
            }

            try packages.append(allocator, RequestedPackage{
                .name = name_copy,
                .version = version,
            });
        }
    }

    return packages;
}

/// Save requested packages to a requested.kdl file.
/// Creates parent directories if they don't exist.
pub fn saveRequested(allocator: std.mem.Allocator, file_path: []const u8, packages: []const RequestedPackage) RequestedError!void {
    // Build KDL content
    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);
    var writer = content.writer(allocator);

    // Write header comment
    writer.writeAll("// Requested packages for this profile\n") catch return RequestedError.OutOfMemory;
    writer.writeAll("// Edit this file to add or remove packages\n\n") catch return RequestedError.OutOfMemory;

    // Write each package
    for (packages) |pkg| {
        try writer.writeAll("package ");
        try writeKdlQuotedString(&writer, pkg.name);
        if (pkg.version) |version| {
            try writer.writeAll(" version=");
            try writeKdlQuotedString(&writer, version);
            try writer.writeByte('\n');
        } else {
            try writer.writeByte('\n');
        }
    }

    // Ensure parent directory exists
    path.ensureParent(file_path) catch return RequestedError.FileSystem;

    // Write file
    const file = std.fs.createFileAbsolute(file_path, .{ .truncate = true }) catch {
        return RequestedError.FileSystem;
    };
    defer file.close();

    file.writeAll(content.items) catch return RequestedError.FileSystem;
}

fn writeKdlQuotedString(writer: anytype, raw: []const u8) RequestedError!void {
    writer.writeByte('"') catch return RequestedError.OutOfMemory;
    for (raw) |ch| {
        switch (ch) {
            '"' => writer.writeAll("\\\"") catch return RequestedError.OutOfMemory,
            '\\' => writer.writeAll("\\\\") catch return RequestedError.OutOfMemory,
            '\n' => writer.writeAll("\\n") catch return RequestedError.OutOfMemory,
            '\r' => writer.writeAll("\\r") catch return RequestedError.OutOfMemory,
            '\t' => writer.writeAll("\\t") catch return RequestedError.OutOfMemory,
            else => {
                if (ch < 0x20) {
                    writer.print("\\u{{{x:0>2}}}", .{ch}) catch return RequestedError.OutOfMemory;
                } else {
                    writer.writeByte(ch) catch return RequestedError.OutOfMemory;
                }
            },
        }
    }
    writer.writeByte('"') catch return RequestedError.OutOfMemory;
}

/// Add a package to a requested.kdl file.
/// If the package already exists, updates its version constraint.
/// Creates the file if it doesn't exist.
pub fn addPackage(allocator: std.mem.Allocator, file_path: []const u8, name: []const u8, version: ?[]const u8) RequestedError!void {
    // Load existing packages
    var packages = try loadRequested(allocator, file_path);
    defer {
        for (packages.items) |*pkg| pkg.deinit(allocator);
        packages.deinit(allocator);
    }

    // Check if package already exists
    var found = false;
    for (packages.items) |*pkg| {
        if (std.mem.eql(u8, pkg.name, name)) {
            // Update version
            if (pkg.version) |old_version| {
                allocator.free(old_version);
            }
            pkg.version = if (version) |v|
                try allocator.dupe(u8, v)
            else
                null;
            found = true;
            break;
        }
    }

    // Add new package if not found
    if (!found) {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const version_copy = if (version) |v|
            try allocator.dupe(u8, v)
        else
            null;

        try packages.append(allocator, RequestedPackage{
            .name = name_copy,
            .version = version_copy,
        });
    }

    // Save updated list
    try saveRequested(allocator, file_path, packages.items);
}

/// Remove a package from a requested.kdl file.
/// Returns true if the package was found and removed, false if not found.
pub fn removePackage(allocator: std.mem.Allocator, file_path: []const u8, name: []const u8) RequestedError!bool {
    // Load existing packages
    var packages = try loadRequested(allocator, file_path);
    defer {
        for (packages.items) |*pkg| pkg.deinit(allocator);
        packages.deinit(allocator);
    }

    // Find and remove the package
    var found = false;
    var i: usize = 0;
    while (i < packages.items.len) {
        if (std.mem.eql(u8, packages.items[i].name, name)) {
            var removed = packages.orderedRemove(i);
            removed.deinit(allocator);
            found = true;
            // Don't increment i, check same index again
        } else {
            i += 1;
        }
    }

    if (found) {
        try saveRequested(allocator, file_path, packages.items);
    }

    return found;
}

/// Check if a package is in the requested list.
pub fn hasPackage(allocator: std.mem.Allocator, file_path: []const u8, name: []const u8) RequestedError!bool {
    var packages = try loadRequested(allocator, file_path);
    defer {
        for (packages.items) |*pkg| pkg.deinit(allocator);
        packages.deinit(allocator);
    }

    for (packages.items) |pkg| {
        if (std.mem.eql(u8, pkg.name, name)) {
            return true;
        }
    }
    return false;
}

/// Get the requested.kdl path for a profile.
/// Caller owns returned memory.
pub fn getRequestedPath(allocator: std.mem.Allocator, profile_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ profile_root, "requested.kdl" });
}

// Tests

test "loadRequested handles missing file" {
    const allocator = std.testing.allocator;
    var packages = try loadRequested(allocator, "/nonexistent/path/requested.kdl");
    defer packages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), packages.items.len);
}

test "saveRequested and loadRequested roundtrip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    // Create test packages
    var packages_to_save = [_]RequestedPackage{
        .{ .name = "vim", .version = null },
        .{ .name = "zig", .version = "0.12" },
    };

    try saveRequested(allocator, file_path, &packages_to_save);

    // Load and verify
    var loaded = try loadRequested(allocator, file_path);
    defer {
        for (loaded.items) |*pkg| pkg.deinit(allocator);
        loaded.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings("vim", loaded.items[0].name);
    try std.testing.expect(loaded.items[0].version == null);
    try std.testing.expectEqualStrings("zig", loaded.items[1].name);
    try std.testing.expectEqualStrings("0.12", loaded.items[1].version.?);
}

test "addPackage adds new package" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    // Add packages
    try addPackage(allocator, file_path, "vim", null);
    try addPackage(allocator, file_path, "git", "2.40");

    // Verify
    var loaded = try loadRequested(allocator, file_path);
    defer {
        for (loaded.items) |*pkg| pkg.deinit(allocator);
        loaded.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
}

test "addPackage updates existing package version" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    // Add package, then update it
    try addPackage(allocator, file_path, "zig", "0.11");
    try addPackage(allocator, file_path, "zig", "0.12");

    // Verify only one entry with updated version
    var loaded = try loadRequested(allocator, file_path);
    defer {
        for (loaded.items) |*pkg| pkg.deinit(allocator);
        loaded.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("zig", loaded.items[0].name);
    try std.testing.expectEqualStrings("0.12", loaded.items[0].version.?);
}

test "removePackage removes existing package" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    // Add packages
    try addPackage(allocator, file_path, "vim", null);
    try addPackage(allocator, file_path, "git", null);

    // Remove one
    const removed = try removePackage(allocator, file_path, "vim");
    try std.testing.expect(removed);

    // Verify
    var loaded = try loadRequested(allocator, file_path);
    defer {
        for (loaded.items) |*pkg| pkg.deinit(allocator);
        loaded.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("git", loaded.items[0].name);
}

test "removePackage returns false for missing package" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    // Create empty file
    try saveRequested(allocator, file_path, &[_]RequestedPackage{});

    // Try to remove nonexistent package
    const removed = try removePackage(allocator, file_path, "nonexistent");
    try std.testing.expect(!removed);
}

test "saveRequested escapes KDL strings and loadRequested roundtrips escaped values" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    var packages_to_save = [_]RequestedPackage{
        .{ .name = "pkg\"name\\x", .version = "1.0\\n\"beta\"" },
    };

    try saveRequested(allocator, file_path, &packages_to_save);

    var loaded = try loadRequested(allocator, file_path);
    defer {
        for (loaded.items) |*pkg| pkg.deinit(allocator);
        loaded.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("pkg\"name\\x", loaded.items[0].name);
    try std.testing.expectEqualStrings("1.0\\n\"beta\"", loaded.items[0].version.?);
}

test "loadRequested rejects package node missing required name argument" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("package version=\"1.2\"\n");

    try std.testing.expectError(RequestedError.ParseError, loadRequested(allocator, file_path));
}

test "loadRequested rejects non-string package version property" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "requested.kdl" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("package \"foo\" version=123\n");

    try std.testing.expectError(RequestedError.ParseError, loadRequested(allocator, file_path));
}
