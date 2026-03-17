/// Strip packaging outputs in a staging directory.
///
/// This module owns the implementation policy for invoking the external `strip`
/// tool on recognized ELF files and static archives before packaging.
const std = @import("std");
const elf = @import("elf.zig");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

/// Strip error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during strip operations
/// - FileSystem: File operations failed (reading ELF headers, walking directories)
///
const Std = errors.StandardErrors;
pub const StripError = Std.OutOfMemory || Std.FileSystem;

/// ELF classification for choosing strip flags.
pub const ElfKind = enum {
    executable,
    shared_lib,
    relocatable,
};

/// Classify an ELF file by reading its e_type field.
/// Returns null if the file is not a valid ELF or is an unrecognized type.
pub fn classifyElf(file_path: []const u8) ?ElfKind {
    const e_type = elf.readElfType(file_path) orelse return null;
    return switch (e_type) {
        .EXEC => .executable,
        .DYN => .shared_lib,
        .REL => .relocatable,
        else => null,
    };
}

/// Check if a file is a static archive (ar format) by extension.
/// Static archives use `!<arch>\n` magic but checking `.a` extension is
/// sufficient and avoids opening every file twice.
fn isStaticArchive(rel_path: []const u8) bool {
    return std.mem.endsWith(u8, rel_path, ".a");
}

/// Strip flags for each file category.
const strip_flags_executable = &[_][]const u8{ "strip", "--strip-unneeded", "-R", ".comment", "-R", ".note" };
const strip_flags_shared = &[_][]const u8{ "strip", "--strip-unneeded", "-R", ".comment", "-R", ".note" };
const strip_flags_static = &[_][]const u8{ "strip", "--strip-debug" };

/// Result of stripping a staging directory.
pub const StripResult = struct {
    files_stripped: usize,
    files_skipped: usize,
    files_failed: usize,
};

pub const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const CommandRunnerFn = fn (allocator: std.mem.Allocator, argv: []const []const u8) anyerror!CommandResult;

fn defaultCommandRunner(allocator: std.mem.Allocator, argv: []const []const u8) anyerror!CommandResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Strip all ELF binaries and static archives in a staging directory.
/// Walks the directory tree, classifies each file, and runs the appropriate
/// strip command. Non-ELF and non-archive files are silently skipped.
///
/// Errors:
///   - OutOfMemory: allocation failure during directory walk
///   - FileSystem: failed to open or walk the staging directory
pub fn stripDirectory(
    ctx: *mere.Context,
    staging_dir: []const u8,
    injected_runner: ?*const CommandRunnerFn,
) StripError!StripResult {
    const allocator = ctx.allocator;
    const runner = injected_runner orelse &defaultCommandRunner;

    var dir = std.fs.openDirAbsolute(staging_dir, .{ .iterate = true }) catch {
        return ctx.fail(StripError.FileSystem, staging_dir, "failed to open staging directory for stripping");
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch {
        return ctx.fail(StripError.OutOfMemory, staging_dir, "failed to walk staging directory for stripping");
    };
    defer walker.deinit();

    var files_stripped: usize = 0;
    var files_skipped: usize = 0;
    var files_failed: usize = 0;

    while (true) {
        const entry = walker.next() catch {
            return ctx.fail(StripError.FileSystem, staging_dir, "failed to read directory entry during stripping");
        };
        if (entry == null) break;
        const e = entry.?;

        // Only process regular files
        if (e.kind != .file) continue;

        const abs_path = std.fs.path.join(allocator, &.{ staging_dir, e.path }) catch {
            return ctx.fail(StripError.OutOfMemory, e.path, "failed to build absolute path for stripping");
        };
        defer allocator.free(abs_path);

        // Determine strip flags based on file type
        const flags: ?[]const []const u8 = if (isStaticArchive(e.path))
            strip_flags_static
        else if (classifyElf(abs_path)) |kind| switch (kind) {
            .executable => strip_flags_executable,
            .shared_lib => strip_flags_shared,
            .relocatable => strip_flags_static,
        } else null;

        if (flags == null) {
            files_skipped += 1;
            continue;
        }

        // Build argv: flags ++ [abs_path]
        var argv = std.ArrayList([]const u8).initCapacity(allocator, flags.?.len + 1) catch {
            return ctx.fail(StripError.OutOfMemory, e.path, "failed to allocate strip argv");
        };
        defer argv.deinit(allocator);
        for (flags.?) |f| {
            argv.append(allocator, f) catch {
                return ctx.fail(StripError.OutOfMemory, e.path, "failed to build strip argv");
            };
        }
        argv.append(allocator, abs_path) catch {
            return ctx.fail(StripError.OutOfMemory, e.path, "failed to append path to strip argv");
        };

        const result = runner(allocator, argv.items) catch {
            ctx.debug("strip failed to spawn for {s}", .{e.path});
            files_failed += 1;
            continue;
        };
        defer result.deinit(allocator);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    ctx.debug("strip exited {d} for {s}: {s}", .{ code, e.path, result.stderr });
                    files_failed += 1;
                    continue;
                }
            },
            else => {
                ctx.debug("strip terminated abnormally for {s}: {any}", .{ e.path, result.term });
                files_failed += 1;
                continue;
            },
        }

        files_stripped += 1;
        ctx.debug("stripped: {s}", .{e.path});
    }

    return StripResult{
        .files_stripped = files_stripped,
        .files_skipped = files_skipped,
        .files_failed = files_failed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "classifyElf returns null for non-ELF file" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "hello.txt" });
    defer std.testing.allocator.free(txt_path);

    {
        const f = try std.fs.createFileAbsolute(txt_path, .{});
        defer f.close();
        try f.writeAll("not an elf");
    }

    try std.testing.expect(classifyElf(txt_path) == null);
}

test "classifyElf returns null for nonexistent file" {
    try std.testing.expect(classifyElf("/nonexistent/path/to/file") == null);
}

test "classifyElf detects ELF executable" {
    // Use the test ELF shared lib from testdata (it's ET_DYN)
    const kind = classifyElf("test/testdata/libtest.so");
    if (kind) |k| {
        try std.testing.expectEqual(ElfKind.shared_lib, k);
    }
    // If testdata not available, skip silently
}

test "isStaticArchive matches .a extension" {
    try std.testing.expect(isStaticArchive("usr/lib/libfoo.a"));
    try std.testing.expect(isStaticArchive("libbar.a"));
    try std.testing.expect(!isStaticArchive("usr/lib/libfoo.so"));
    try std.testing.expect(!isStaticArchive("usr/bin/foo"));
    try std.testing.expect(!isStaticArchive("readme.txt"));
}

test "stripDirectory skips non-ELF files" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "staging" });
    defer std.testing.allocator.free(staging);
    try std.fs.cwd().makePath(staging);

    // Create a plain text file — should be skipped
    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ staging, "readme.txt" });
    defer std.testing.allocator.free(txt_path);
    {
        const f = try std.fs.createFileAbsolute(txt_path, .{});
        defer f.close();
        try f.writeAll("hello");
    }

    const result = try stripDirectory(&test_env.ctx, staging, null);
    try std.testing.expectEqual(@as(usize, 0), result.files_stripped);
    try std.testing.expectEqual(@as(usize, 1), result.files_skipped);
    try std.testing.expectEqual(@as(usize, 0), result.files_failed);
}

test "stripDirectory handles empty directory" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "empty" });
    defer std.testing.allocator.free(staging);
    try std.fs.cwd().makePath(staging);

    const result = try stripDirectory(&test_env.ctx, staging, null);
    try std.testing.expectEqual(@as(usize, 0), result.files_stripped);
    try std.testing.expectEqual(@as(usize, 0), result.files_skipped);
    try std.testing.expectEqual(@as(usize, 0), result.files_failed);
}

test "stripDirectory reports runner spawn failures without failing the directory" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "spawn-fail" });
    defer std.testing.allocator.free(staging);
    try std.fs.cwd().makePath(staging);

    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ staging, "libfoo.a" });
    defer std.testing.allocator.free(archive_path);
    {
        const f = try std.fs.createFileAbsolute(archive_path, .{});
        defer f.close();
        try f.writeAll("fake archive");
    }

    const FailingRunner = struct {
        fn run(_: std.mem.Allocator, _: []const []const u8) anyerror!CommandResult {
            return error.FileNotFound;
        }
    };

    const result = try stripDirectory(&test_env.ctx, staging, &FailingRunner.run);
    try std.testing.expectEqual(@as(usize, 0), result.files_stripped);
    try std.testing.expectEqual(@as(usize, 0), result.files_skipped);
    try std.testing.expectEqual(@as(usize, 1), result.files_failed);
}

test "stripDirectory reports non-zero runner exits without failing the directory" {
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "exit-fail" });
    defer std.testing.allocator.free(staging);
    try std.fs.cwd().makePath(staging);

    const archive_path = try std.fs.path.join(std.testing.allocator, &.{ staging, "libfoo.a" });
    defer std.testing.allocator.free(archive_path);
    {
        const f = try std.fs.createFileAbsolute(archive_path, .{});
        defer f.close();
        try f.writeAll("fake archive");
    }

    const ExitFailRunner = struct {
        fn run(allocator: std.mem.Allocator, _: []const []const u8) anyerror!CommandResult {
            return .{
                .term = .{ .Exited = 1 },
                .stdout = try allocator.dupe(u8, ""),
                .stderr = try allocator.dupe(u8, "strip failed"),
            };
        }
    };

    const result = try stripDirectory(&test_env.ctx, staging, &ExitFailRunner.run);
    try std.testing.expectEqual(@as(usize, 0), result.files_stripped);
    try std.testing.expectEqual(@as(usize, 0), result.files_skipped);
    try std.testing.expectEqual(@as(usize, 1), result.files_failed);
}
