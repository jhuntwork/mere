/// Fix cmake export files that resolve symlinks into the mere store.
///
/// cmake's generated export files (`*Exports.cmake`, `*Target.cmake`, `*Config.cmake`)
/// compute their install prefix by resolving the real path of the cmake file and
/// walking up parent directories. In mere's content-addressed store, this resolves
/// to a store path rather than `/usr`, breaking cross-package references.
///
/// This module rewrites the prefix detection blocks to use a hardcoded `/usr` prefix.
///
/// Two patterns are handled:
///
/// Pattern 1 — `_IMPORT_PREFIX` (in *Exports.cmake / *Target.cmake):
///   get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
///   ... REALPATH comparison ...
///   get_filename_component(_IMPORT_PREFIX ... PATH)  (walk-ups)
///   if(_IMPORT_PREFIX STREQUAL "/")
///   ...
///   endif()
///
/// Pattern 2 — `*_INSTALL_PREFIX` (in *Config.cmake):
///   get_filename_component(FOO_INSTALL_PREFIX "${CMAKE_CURRENT_LIST_FILE}" REALPATH)
///   get_filename_component(FOO_INSTALL_PREFIX ... PATH)  (walk-ups)
const std = @import("std");
const path_mod = @import("path.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const CmakeFixupError = Std.OutOfMemory || Std.FileSystem;

pub const FixupResult = struct {
    files_fixed: usize = 0,
};

/// Scan a staging directory for cmake files and fix store path resolution.
pub fn fixupStagingDir(allocator: std.mem.Allocator, staging_dir: []const u8) CmakeFixupError!FixupResult {
    const cmake_dir = std.fs.path.join(allocator, &.{ staging_dir, "usr", "lib", "cmake" }) catch {
        return CmakeFixupError.OutOfMemory;
    };
    defer allocator.free(cmake_dir);

    const io = path_mod.currentIo();
    std.Io.Dir.accessAbsolute(io, cmake_dir, .{}) catch {
        return .{};
    };

    var dir = std.Io.Dir.openDirAbsolute(io, cmake_dir, .{ .iterate = true }) catch {
        return CmakeFixupError.FileSystem;
    };
    defer dir.close(io);

    var result = FixupResult{};

    var walker = dir.walk(allocator) catch {
        return CmakeFixupError.OutOfMemory;
    };
    defer walker.deinit();

    while (walker.next(io) catch {
        return CmakeFixupError.FileSystem;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".cmake")) continue;

        const full_path = std.fs.path.join(allocator, &.{ cmake_dir, entry.path }) catch {
            return CmakeFixupError.OutOfMemory;
        };
        defer allocator.free(full_path);

        const fixed = fixupFile(allocator, full_path) catch |err| switch (err) {
            CmakeFixupError.OutOfMemory => return CmakeFixupError.OutOfMemory,
            CmakeFixupError.FileSystem => return CmakeFixupError.FileSystem,
        };
        if (fixed) result.files_fixed += 1;
    }

    return result;
}

/// Fix a single cmake file. Returns true if the file was modified.
pub fn fixupFile(allocator: std.mem.Allocator, file_path: []const u8) CmakeFixupError!bool {
    const content = readFile(allocator, file_path) catch {
        return CmakeFixupError.FileSystem;
    };
    defer allocator.free(content);

    // Only process files that use REALPATH — others don't need fixing.
    if (std.mem.indexOf(u8, content, "REALPATH") == null) return false;

    var modified = false;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Collect all lines for indexed access (needed for lookahead in pattern 2).
    var line_list: std.ArrayList([]const u8) = .empty;
    defer line_list.deinit(allocator);
    {
        var splitter = std.mem.splitScalar(u8, content, '\n');
        while (splitter.next()) |line| {
            line_list.append(allocator, line) catch return CmakeFixupError.OutOfMemory;
        }
    }

    const all_lines = line_list.items;
    var i: usize = 0;
    while (i < all_lines.len) {
        const line = all_lines[i];

        if (matchImportPrefixStart(line)) {
            const end_idx = findImportPrefixBlockEnd(all_lines, i + 1) orelse {
                appendLine(&output, allocator, line) catch return CmakeFixupError.OutOfMemory;
                i += 1;
                continue;
            };
            // Pattern 1: _IMPORT_PREFIX block
            appendLine(&output, allocator, "set(_IMPORT_PREFIX \"/usr\")") catch return CmakeFixupError.OutOfMemory;
            i = end_idx;
            modified = true;
        } else if (matchInstallPrefixStart(line)) |var_name| {
            const end_idx = findInstallPrefixBlockEnd(all_lines, i + 1, var_name) orelse {
                appendLine(&output, allocator, line) catch return CmakeFixupError.OutOfMemory;
                i += 1;
                continue;
            };
            // Pattern 2: *_INSTALL_PREFIX block
            const replacement = std.fmt.allocPrint(allocator, "set({s} \"/usr\")", .{var_name}) catch {
                return CmakeFixupError.OutOfMemory;
            };
            defer allocator.free(replacement);
            appendLine(&output, allocator, replacement) catch return CmakeFixupError.OutOfMemory;
            i = end_idx;
            modified = true;
        } else {
            appendLine(&output, allocator, line) catch return CmakeFixupError.OutOfMemory;
            i += 1;
        }
    }

    if (!modified) return false;

    // Remove trailing newline added by appendLine if original didn't have one.
    if (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        if (content.len == 0 or content[content.len - 1] != '\n') {
            _ = output.pop();
        }
    }

    writeFile(file_path, output.items) catch {
        return CmakeFixupError.FileSystem;
    };
    return true;
}

/// Check if a line starts the _IMPORT_PREFIX detection block.
fn matchImportPrefixStart(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "get_filename_component(_IMPORT_PREFIX") and
        std.mem.indexOf(u8, trimmed, "CMAKE_CURRENT_LIST_FILE") != null;
}

/// Check if a line starts an *_INSTALL_PREFIX detection block.
/// Returns the variable name or null.
fn matchInstallPrefixStart(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    const prefix = "get_filename_component(";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    if (std.mem.indexOf(u8, trimmed, "CMAKE_CURRENT_LIST_FILE") == null) return null;
    if (std.mem.indexOf(u8, trimmed, "REALPATH") == null) return null;

    const after_paren = trimmed[prefix.len..];
    const space_idx = std.mem.indexOfScalar(u8, after_paren, ' ') orelse return null;
    const var_name = after_paren[0..space_idx];

    if (!std.mem.endsWith(u8, var_name, "_INSTALL_PREFIX")) return null;
    if (std.mem.eql(u8, var_name, "_IMPORT_PREFIX")) return null;

    return var_name;
}

/// Find the end of an _IMPORT_PREFIX block. Returns the first line after the block.
fn findImportPrefixBlockEnd(lines: []const []const u8, start: usize) ?usize {
    var i = start;
    var found_strequal = false;
    var saw_realpath = false;
    while (i < lines.len) : (i += 1) {
        const trimmed = std.mem.trim(u8, lines[i], " \t");
        if (std.mem.indexOf(u8, trimmed, "REALPATH") != null) {
            saw_realpath = true;
        }
        if (!found_strequal) {
            if (std.mem.startsWith(u8, trimmed, "if(_IMPORT_PREFIX STREQUAL")) {
                found_strequal = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "endif()")) {
            return if (saw_realpath) i + 1 else null;
        }
    }
    return null;
}

/// Find the end of consecutive get_filename_component lines for the same variable.
fn findInstallPrefixBlockEnd(lines: []const []const u8, start: usize, var_name: []const u8) ?usize {
    var i = start;
    var count: usize = 0;
    while (i < lines.len) : (i += 1) {
        const trimmed = std.mem.trim(u8, lines[i], " \t");
        if (installPrefixLineMatches(trimmed, var_name)) {
            count += 1;
            continue;
        }
        break;
    }
    return if (count > 0) i else null;
}

fn installPrefixLineMatches(trimmed: []const u8, var_name: []const u8) bool {
    const prefix = "get_filename_component(";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;

    const after_paren = trimmed[prefix.len..];
    const space_idx = std.mem.indexOfScalar(u8, after_paren, ' ') orelse return false;
    const current_var = after_paren[0..space_idx];
    return std.mem.eql(u8, current_var, var_name);
}

fn appendLine(output: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    try output.appendSlice(allocator, line);
    try output.append(allocator, '\n');
}

fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const io = path_mod.currentIo();
    var file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > 4 * 1024 * 1024) return error.FileTooBig;

    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);

    const read = try file.readPositionalAll(io, buf, 0);
    if (read != stat.size) return error.UnexpectedEof;
    return buf;
}

fn writeFile(file_path: []const u8, content: []const u8) !void {
    const io = path_mod.currentIo();
    var file = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "fixupFile rewrites _IMPORT_PREFIX block" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cmake_file = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "TestExports.cmake" });
    defer std.testing.allocator.free(cmake_file);

    const input =
        \\# Generated by CMake
        \\set(CMAKE_IMPORT_FILE_VERSION 1)
        \\
        \\# Compute the installation prefix relative to this file.
        \\get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
        \\# Use original install prefix when loaded through a
        \\# cross-prefix symbolic link such as /lib -> /usr/lib.
        \\get_filename_component(_realCurr "${_IMPORT_PREFIX}" REALPATH)
        \\get_filename_component(_realOrig "/usr/lib/cmake/foo" REALPATH)
        \\if(_realCurr STREQUAL _realOrig)
        \\  set(_IMPORT_PREFIX "/usr/lib/cmake/foo")
        \\endif()
        \\unset(_realOrig)
        \\unset(_realCurr)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\if(_IMPORT_PREFIX STREQUAL "/")
        \\  set(_IMPORT_PREFIX "")
        \\endif()
        \\
        \\# Create imported target Foo::Bar
        \\add_library(Foo::Bar SHARED IMPORTED)
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cmake_file, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    const fixed = try fixupFile(std.testing.allocator, cmake_file);
    try std.testing.expect(fixed);

    const result = try readFile(std.testing.allocator, cmake_file);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "set(_IMPORT_PREFIX \"/usr\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "REALPATH") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "get_filename_component(_IMPORT_PREFIX") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "add_library(Foo::Bar SHARED IMPORTED)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "set(CMAKE_IMPORT_FILE_VERSION 1)") != null);
}

test "fixupFile rewrites INSTALL_PREFIX block" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cmake_file = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "FooConfig.cmake" });
    defer std.testing.allocator.free(cmake_file);

    const input =
        \\# This file provides information and services to the final user.
        \\
        \\# Compute the installation prefix from this FooConfig.cmake file location.
        \\get_filename_component(FOO_INSTALL_PREFIX "${CMAKE_CURRENT_LIST_FILE}" REALPATH)
        \\get_filename_component(FOO_INSTALL_PREFIX "${FOO_INSTALL_PREFIX}" PATH)
        \\get_filename_component(FOO_INSTALL_PREFIX "${FOO_INSTALL_PREFIX}" PATH)
        \\get_filename_component(FOO_INSTALL_PREFIX "${FOO_INSTALL_PREFIX}" PATH)
        \\get_filename_component(FOO_INSTALL_PREFIX "${FOO_INSTALL_PREFIX}" PATH)
        \\
        \\# For finding self-installed Find*.cmake packages.
        \\list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}")
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cmake_file, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    const fixed = try fixupFile(std.testing.allocator, cmake_file);
    try std.testing.expect(fixed);

    const result = try readFile(std.testing.allocator, cmake_file);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "set(FOO_INSTALL_PREFIX \"/usr\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "REALPATH") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "get_filename_component(FOO_INSTALL_PREFIX") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "list(APPEND CMAKE_MODULE_PATH") != null);
}

test "fixupFile skips files without REALPATH" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cmake_file = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "Normal.cmake" });
    defer std.testing.allocator.free(cmake_file);

    const input =
        \\# A normal cmake file with no REALPATH usage
        \\set(FOO_VERSION "1.0.0")
        \\set(FOO_INCLUDE_DIR "/usr/include/foo")
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cmake_file, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    const fixed = try fixupFile(std.testing.allocator, cmake_file);
    try std.testing.expect(!fixed);
}

test "fixupStagingDir processes cmake directory" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = test_env.path;
    const cmake_dir = try std.fs.path.join(std.testing.allocator, &.{ staging, "usr", "lib", "cmake", "foo" });
    defer std.testing.allocator.free(cmake_dir);
    try path_mod.ensureDirExists(cmake_dir);

    const exports_path = try std.fs.path.join(std.testing.allocator, &.{ cmake_dir, "FooExports.cmake" });
    defer std.testing.allocator.free(exports_path);

    const input =
        \\get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
        \\get_filename_component(_realCurr "${_IMPORT_PREFIX}" REALPATH)
        \\get_filename_component(_realOrig "/usr/lib/cmake/foo" REALPATH)
        \\if(_realCurr STREQUAL _realOrig)
        \\  set(_IMPORT_PREFIX "/usr/lib/cmake/foo")
        \\endif()
        \\unset(_realOrig)
        \\unset(_realCurr)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\if(_IMPORT_PREFIX STREQUAL "/")
        \\  set(_IMPORT_PREFIX "")
        \\endif()
        \\add_library(Foo SHARED IMPORTED)
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), exports_path, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    // Also create a non-cmake file that should be ignored
    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ cmake_dir, "readme.txt" });
    defer std.testing.allocator.free(txt_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), txt_path, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), "not a cmake file");
    }

    const result = try fixupStagingDir(std.testing.allocator, staging);
    try std.testing.expectEqual(@as(usize, 1), result.files_fixed);

    const fixed_content = try readFile(std.testing.allocator, exports_path);
    defer std.testing.allocator.free(fixed_content);
    try std.testing.expect(std.mem.indexOf(u8, fixed_content, "set(_IMPORT_PREFIX \"/usr\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed_content, "add_library(Foo SHARED IMPORTED)") != null);
}

test "fixupStagingDir returns zero when no cmake directory exists" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const result = try fixupStagingDir(std.testing.allocator, test_env.path);
    try std.testing.expectEqual(@as(usize, 0), result.files_fixed);
}

test "fixupFile handles both patterns in one file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cmake_file = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "Combined.cmake" });
    defer std.testing.allocator.free(cmake_file);

    const input =
        \\get_filename_component(BAR_INSTALL_PREFIX "${CMAKE_CURRENT_LIST_FILE}" REALPATH)
        \\get_filename_component(BAR_INSTALL_PREFIX "${BAR_INSTALL_PREFIX}" PATH)
        \\get_filename_component(BAR_INSTALL_PREFIX "${BAR_INSTALL_PREFIX}" PATH)
        \\get_filename_component(BAR_INSTALL_PREFIX "${BAR_INSTALL_PREFIX}" PATH)
        \\
        \\set(BAR_VERSION "2.0")
        \\
        \\get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
        \\get_filename_component(_realCurr "${_IMPORT_PREFIX}" REALPATH)
        \\get_filename_component(_realOrig "/usr/lib/cmake/bar" REALPATH)
        \\if(_realCurr STREQUAL _realOrig)
        \\  set(_IMPORT_PREFIX "/usr/lib/cmake/bar")
        \\endif()
        \\unset(_realOrig)
        \\unset(_realCurr)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\get_filename_component(_IMPORT_PREFIX "${_IMPORT_PREFIX}" PATH)
        \\if(_IMPORT_PREFIX STREQUAL "/")
        \\  set(_IMPORT_PREFIX "")
        \\endif()
        \\add_library(Bar STATIC IMPORTED)
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cmake_file, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    const fixed = try fixupFile(std.testing.allocator, cmake_file);
    try std.testing.expect(fixed);

    const result = try readFile(std.testing.allocator, cmake_file);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "set(BAR_INSTALL_PREFIX \"/usr\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "set(_IMPORT_PREFIX \"/usr\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "set(BAR_VERSION \"2.0\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "add_library(Bar STATIC IMPORTED)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "REALPATH") == null);
}

test "fixupFile leaves incomplete import prefix logic unchanged" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cmake_file = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "Odd.cmake" });
    defer std.testing.allocator.free(cmake_file);

    const input =
        \\get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
        \\message(STATUS "REALPATH appears elsewhere but not in prefix logic")
        \\set(SOMETHING_REALPATH "REALPATH")
        \\add_library(Odd SHARED IMPORTED)
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cmake_file, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    const fixed = try fixupFile(std.testing.allocator, cmake_file);
    try std.testing.expect(!fixed);

    const result = try readFile(std.testing.allocator, cmake_file);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "fixupFile leaves install prefix without walk-up lines unchanged" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const cmake_file = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "BrokenConfig.cmake" });
    defer std.testing.allocator.free(cmake_file);

    const input =
        \\get_filename_component(FOO_INSTALL_PREFIX "${CMAKE_CURRENT_LIST_FILE}" REALPATH)
        \\set(FOO_OTHER_INSTALL_PREFIX "/tmp")
        \\
    ;

    {
        var f = try std.Io.Dir.createFileAbsolute(path_mod.currentIo(), cmake_file, .{});
        defer f.close(path_mod.currentIo());
        try f.writeStreamingAll(path_mod.currentIo(), input);
    }

    const fixed = try fixupFile(std.testing.allocator, cmake_file);
    try std.testing.expect(!fixed);
}
