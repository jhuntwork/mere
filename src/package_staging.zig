/// Package staging module: copies matched files from a build DESTDIR into per-package staging.
const std = @import("std");
const mere = @import("mere.zig");
const errors = @import("errors.zig");
const path_safety = @import("path_safety.zig");
const c = @cImport({
    @cInclude("fnmatch.h");
});

/// Package staging error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during staging operations
/// - FileSystem: File operations failed (reading, writing, creating directories)
/// - InvalidInput: Invalid staging parameters or configuration
const Std = errors.StandardErrors;
pub const PackageStagingError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput;

pub const PackageStagingResult = struct {
    files_copied: usize,
    copied_files: [][]const u8,
    allocator: std.mem.Allocator,

    /// Free duplicated staged-path strings owned by this result.
    pub fn deinit(self: *PackageStagingResult) void {
        if (self.files_copied > 0) {
            for (self.copied_files) |file_path| {
                self.allocator.free(file_path);
            }
            self.allocator.free(self.copied_files);
        }
    }
};

pub const PackageStagingConfig = struct {
    source_dir: []const u8,
    patterns: []const []const u8,
    destination: []const u8,
};

const MatchedEntryKind = enum {
    file,
    sym_link,
    directory,
};

const MatchedEntry = struct {
    rel_path: []const u8,
    kind: MatchedEntryKind,
};

const PackageStagingPlan = struct {
    allocator: std.mem.Allocator,
    matched_entries: []MatchedEntry,

    fn deinit(self: *PackageStagingPlan) void {
        for (self.matched_entries) |entry| {
            self.allocator.free(entry.rel_path);
        }
        self.allocator.free(self.matched_entries);
    }
};

fn isRecursiveDirPattern(pattern: []const u8) bool {
    return pattern.len > 0 and pattern[pattern.len - 1] == '/';
}

fn isExclusionPattern(pattern: []const u8) bool {
    return pattern.len > 0 and pattern[0] == '!';
}

fn basePattern(pattern: []const u8) []const u8 {
    if (isExclusionPattern(pattern)) return pattern[1..];
    return pattern;
}

fn isUsrLocalPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "usr/local") or std.mem.startsWith(u8, path, "usr/local/");
}

fn matchesRecursiveDirPattern(path: []const u8, pattern: []const u8) bool {
    if (!isRecursiveDirPattern(pattern)) return false;
    const root = pattern[0 .. pattern.len - 1];
    return std.mem.eql(u8, path, root) or std.mem.startsWith(u8, path, pattern);
}

/// Convert an absolute symlink target to a relative path if it points within source_dir.
/// If the target points outside source_dir, return an error.
///
/// Example: symlink at /build/dest/lib/ld-musl.so.1 pointing to /lib/libc.so
///          where source_dir is /build/dest
///          should be converted to: libc.so (same directory)
fn convertAbsoluteSymlinkToRelative(
    allocator: std.mem.Allocator,
    ctx: *mere.Context,
    absolute_target: []const u8,
    symlink_path: []const u8,
    source_dir: []const u8,
) PackageStagingError![]const u8 {
    const normalized_source_dir = std.fs.path.resolve(allocator, &[_][]const u8{source_dir}) catch {
        return ctx.fail(PackageStagingError.OutOfMemory, source_dir, "failed to resolve source directory");
    };
    defer allocator.free(normalized_source_dir);

    const normalized_symlink_path = std.fs.path.resolve(allocator, &[_][]const u8{symlink_path}) catch {
        return ctx.fail(PackageStagingError.OutOfMemory, symlink_path, "failed to resolve symlink path");
    };
    defer allocator.free(normalized_symlink_path);

    if (!path_safety.isWithinBoundary(normalized_symlink_path, normalized_source_dir)) {
        return ctx.fail(PackageStagingError.InvalidInput, symlink_path, "symlink path escapes source boundary");
    }

    const target_relative_to_source = std.mem.trimLeft(u8, absolute_target, "/");
    const candidate_target = std.fs.path.resolve(allocator, &[_][]const u8{ normalized_source_dir, target_relative_to_source }) catch {
        return ctx.fail(PackageStagingError.OutOfMemory, absolute_target, "failed to resolve symlink target");
    };
    defer allocator.free(candidate_target);

    if (!path_safety.isWithinBoundary(candidate_target, normalized_source_dir)) {
        return ctx.fail(PackageStagingError.InvalidInput, symlink_path, "symlink target escapes boundary");
    }

    std.fs.accessAbsolute(candidate_target, .{}) catch {
        return ctx.fail(PackageStagingError.InvalidInput, symlink_path, "symlink target does not exist within source boundary");
    };

    const symlink_dir = std.fs.path.dirname(normalized_symlink_path) orelse normalized_source_dir;
    return std.fs.path.relative(allocator, symlink_dir, candidate_target) catch {
        return ctx.fail(PackageStagingError.OutOfMemory, symlink_path, "failed to compute relative symlink target");
    };
}

/// Stage package files based on split-package patterns.
pub fn stagePackageFiles(ctx: *mere.Context, config: PackageStagingConfig) !PackageStagingResult {
    var plan = analyzePackageMatches(ctx, config.source_dir, config.patterns) catch |err| {
        ensureEmptyDestination(ctx, config.destination);
        return err;
    };
    defer plan.deinit();
    return materializePackagePlan(ctx, config, &plan) catch |err| {
        ensureEmptyDestination(ctx, config.destination);
        return err;
    };
}

fn ensureEmptyDestination(ctx: *mere.Context, destination: []const u8) void {
    std.fs.deleteTreeAbsolute(destination) catch |err| {
        if (err != error.FileNotFound) {
            ctx.debug("failed to clean staging directory after error: {s}", .{@errorName(err)});
        }
    };
    std.fs.cwd().makePath(destination) catch |err| {
        ctx.debug("failed to recreate staging directory after cleanup: {s}", .{@errorName(err)});
    };
}

fn analyzePackageMatches(ctx: *mere.Context, source_dir_path: []const u8, patterns: []const []const u8) !PackageStagingPlan {
    const allocator = ctx.allocator;
    var matched_entries = std.ArrayList(MatchedEntry){};
    defer {
        for (matched_entries.items) |entry| allocator.free(entry.rel_path);
        matched_entries.deinit(allocator);
    }
    var pattern_matched = try allocator.alloc(bool, patterns.len);
    defer allocator.free(pattern_matched);
    @memset(pattern_matched, false);
    var pattern_matched_directory = try allocator.alloc(bool, patterns.len);
    defer allocator.free(pattern_matched_directory);
    @memset(pattern_matched_directory, false);
    var patterns_z = std.ArrayList([:0]u8){};
    defer {
        for (patterns_z.items) |pattern_z| {
            allocator.free(pattern_z);
        }
        patterns_z.deinit(allocator);
    }
    var rel_path_z_buf = std.ArrayList(u8){};
    defer rel_path_z_buf.deinit(allocator);

    const fail = struct {
        fn with(ctx_inner: *mere.Context, subject: []const u8, details: []const u8, err: PackageStagingError) PackageStagingError {
            return ctx_inner.fail(err, subject, details);
        }
    }.with;

    for (patterns) |pattern| {
        const raw_pattern = basePattern(pattern);
        if (raw_pattern.len == 0) {
            return fail(ctx, pattern, "invalid empty pattern", PackageStagingError.InvalidInput);
        }
        const pattern_z = allocator.dupeZ(u8, raw_pattern) catch {
            return fail(ctx, pattern, "failed to copy fnmatch pattern", PackageStagingError.OutOfMemory);
        };
        patterns_z.append(allocator, pattern_z) catch {
            return fail(ctx, pattern, "failed to store fnmatch pattern", PackageStagingError.OutOfMemory);
        };
    }

    // Open source directory
    var source_dir = std.fs.openDirAbsolute(source_dir_path, .{ .iterate = true }) catch {
        return fail(ctx, source_dir_path, "failed to open source directory", PackageStagingError.FileSystem);
    };
    defer source_dir.close();

    // Walk through source directory
    var walker = source_dir.walk(allocator) catch {
        return fail(ctx, source_dir_path, "failed to walk source directory", PackageStagingError.FileSystem);
    };
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch {
            return fail(ctx, source_dir_path, "failed to read directory entry", PackageStagingError.FileSystem);
        };
        if (entry == null) break;
        const entry_val = entry.?;

        if (entry_val.kind != .file and entry_val.kind != .sym_link and entry_val.kind != .directory) continue;

        const rel_path = entry_val.path;
        var include_matched = false;
        var exclude_matched = false;
        var recursive_include_matched = false;

        rel_path_z_buf.clearRetainingCapacity();
        rel_path_z_buf.appendSlice(allocator, rel_path) catch {
            return fail(ctx, rel_path, "failed to append path for fnmatch", PackageStagingError.OutOfMemory);
        };
        rel_path_z_buf.append(allocator, 0) catch {
            return fail(ctx, rel_path, "failed to terminate path for fnmatch", PackageStagingError.OutOfMemory);
        };

        // Check if the entry matches any pattern.
        // - Trailing "/" is a shorthand for recursive directory inclusion.
        // - Otherwise use POSIX fnmatch with pathname-aware semantics.
        for (patterns, patterns_z.items) |pattern, pattern_z| {
            const pat = basePattern(pattern);
            const is_exclude = isExclusionPattern(pattern);

            if (isRecursiveDirPattern(pat)) {
                if (matchesRecursiveDirPattern(rel_path, pat)) {
                    if (is_exclude) {
                        exclude_matched = true;
                    } else {
                        include_matched = true;
                        recursive_include_matched = true;
                    }
                }
                continue;
            }

            const match_code = c.fnmatch(pattern_z.ptr, rel_path_z_buf.items.ptr, c.FNM_PATHNAME);
            if (match_code == 0) {
                if (is_exclude) {
                    exclude_matched = true;
                } else {
                    include_matched = true;
                }
            } else if (match_code != c.FNM_NOMATCH) {
                return fail(ctx, pattern, "invalid fnmatch pattern", PackageStagingError.InvalidInput);
            }
        }

        const matches = include_matched and !exclude_matched;
        if (matches) {
            // /usr/local is reserved for administrator-managed files and must never be staged
            // by package builds. Enforce this only for matched paths.
            if (isUsrLocalPath(rel_path)) {
                return fail(ctx, rel_path, "path under /usr/local is forbidden", PackageStagingError.InvalidInput);
            }

            // Mark only inclusion patterns that matched an entry that survived exclusion.
            for (patterns, patterns_z.items, 0..) |pattern, pattern_z, pattern_idx| {
                if (isExclusionPattern(pattern)) continue;
                const pat = basePattern(pattern);
                if (isRecursiveDirPattern(pat)) {
                    if (matchesRecursiveDirPattern(rel_path, pat)) {
                        pattern_matched[pattern_idx] = true;
                    }
                    continue;
                }

                const match_code = c.fnmatch(pattern_z.ptr, rel_path_z_buf.items.ptr, c.FNM_PATHNAME);
                if (match_code == 0) {
                    if (entry_val.kind == .directory) {
                        pattern_matched_directory[pattern_idx] = true;
                    } else {
                        pattern_matched[pattern_idx] = true;
                    }
                } else if (match_code != c.FNM_NOMATCH) {
                    return fail(ctx, pattern, "invalid fnmatch pattern", PackageStagingError.InvalidInput);
                }
            }

            if (entry_val.kind == .directory and !recursive_include_matched) continue;

            const kind: MatchedEntryKind = switch (entry_val.kind) {
                .directory => .directory,
                .sym_link => .sym_link,
                else => .file,
            };

            matched_entries.append(allocator, .{
                .rel_path = allocator.dupe(u8, rel_path) catch {
                    return fail(ctx, rel_path, "failed to copy matched path", PackageStagingError.OutOfMemory);
                },
                .kind = kind,
            }) catch {
                return fail(ctx, rel_path, "failed to record matched path", PackageStagingError.OutOfMemory);
            };
        }
    }

    for (patterns, 0..) |pattern, idx| {
        if (isExclusionPattern(pattern)) continue;
        if (!pattern_matched[idx]) {
            if (pattern_matched_directory[idx]) {
                return fail(ctx, pattern, "pattern matched only directories; use a trailing '/' for recursive directory inclusion", PackageStagingError.InvalidInput);
            }
            return fail(ctx, pattern, "pattern matched no files", PackageStagingError.InvalidInput);
        }
    }

    return PackageStagingPlan{
        .allocator = allocator,
        .matched_entries = matched_entries.toOwnedSlice(allocator) catch {
            return fail(ctx, source_dir_path, "failed to finalize matched file plan", PackageStagingError.OutOfMemory);
        },
    };
}

fn materializePackagePlan(ctx: *mere.Context, config: PackageStagingConfig, plan: *const PackageStagingPlan) !PackageStagingResult {
    const allocator = ctx.allocator;
    var files_copied: usize = 0;
    var destination_touched = false;
    var copied_files = std.ArrayList([]const u8){};
    defer copied_files.deinit(allocator);
    errdefer {
        for (copied_files.items) |file_path| {
            allocator.free(file_path);
        }
        if (destination_touched) ensureEmptyDestination(ctx, config.destination);
    }

    const fail = struct {
        fn with(ctx_inner: *mere.Context, subject: []const u8, details: []const u8, err: PackageStagingError) PackageStagingError {
            return ctx_inner.fail(err, subject, details);
        }
    }.with;

    for (plan.matched_entries) |entry| {
        const src_file_path = std.fs.path.join(allocator, &.{ config.source_dir, entry.rel_path }) catch {
            return fail(ctx, entry.rel_path, "failed to build source path", PackageStagingError.OutOfMemory);
        };
        defer allocator.free(src_file_path);

        const dest_file_path = std.fs.path.join(allocator, &.{ config.destination, entry.rel_path }) catch {
            return fail(ctx, entry.rel_path, "failed to build destination path", PackageStagingError.OutOfMemory);
        };
        defer allocator.free(dest_file_path);

        if (entry.kind == .directory) {
            destination_touched = true;
            std.fs.cwd().makePath(dest_file_path) catch {
                return fail(ctx, dest_file_path, "failed to create destination directory", PackageStagingError.FileSystem);
            };
            continue;
        }

        const dest_parent = std.fs.path.dirname(dest_file_path) orelse "";
        destination_touched = true;
        std.fs.cwd().makePath(dest_parent) catch {
            return fail(ctx, dest_parent, "failed to create destination directory", PackageStagingError.FileSystem);
        };

        if (entry.kind == .sym_link) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fs.readLinkAbsolute(src_file_path, &buf) catch {
                return fail(ctx, src_file_path, "failed to read symlink", PackageStagingError.FileSystem);
            };

            const final_target = if (std.fs.path.isAbsolute(target))
                try convertAbsoluteSymlinkToRelative(allocator, ctx, target, src_file_path, config.source_dir)
            else
                allocator.dupe(u8, target) catch {
                    return fail(ctx, src_file_path, "failed to copy symlink target", PackageStagingError.OutOfMemory);
                };
            defer allocator.free(final_target);

            const dest_dir = std.fs.path.dirname(dest_file_path) orelse "";
            var dir = std.fs.openDirAbsolute(dest_dir, .{}) catch {
                return fail(ctx, dest_dir, "failed to open destination directory", PackageStagingError.FileSystem);
            };
            defer dir.close();

            const dest_basename = std.fs.path.basename(dest_file_path);
            dir.symLink(final_target, dest_basename, .{}) catch |link_err| {
                ctx.setDiagnosticContextFmt(
                    dest_file_path,
                    "failed to create symlink ({s}); link_name={s}; target={s}; source={s}",
                    .{ @errorName(link_err), dest_basename, final_target, src_file_path },
                );
                return PackageStagingError.FileSystem;
            };

            files_copied += 1;
            const copied_path = allocator.dupe(u8, entry.rel_path) catch {
                return fail(ctx, entry.rel_path, "failed to copy collected path", PackageStagingError.OutOfMemory);
            };
            copied_files.append(allocator, copied_path) catch {
                return fail(ctx, entry.rel_path, "failed to record collected path", PackageStagingError.OutOfMemory);
            };
            ctx.debug("collected symlink: {s} -> {s}", .{ entry.rel_path, final_target });
            continue;
        }

        var src_file = std.fs.openFileAbsolute(src_file_path, .{}) catch {
            return fail(ctx, src_file_path, "failed to open source file", PackageStagingError.FileSystem);
        };
        defer src_file.close();

        var dest_file = std.fs.createFileAbsolute(dest_file_path, .{}) catch {
            return fail(ctx, dest_file_path, "failed to create destination file", PackageStagingError.FileSystem);
        };
        defer dest_file.close();

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = src_file.read(&buf) catch {
                return fail(ctx, src_file_path, "failed to read source file", PackageStagingError.FileSystem);
            };
            if (n == 0) break;
            dest_file.writeAll(buf[0..n]) catch {
                return fail(ctx, dest_file_path, "failed to write destination file", PackageStagingError.FileSystem);
            };
        }

        const file_stat = src_file.stat() catch {
            return fail(ctx, src_file_path, "failed to stat source file", PackageStagingError.FileSystem);
        };
        dest_file.chmod(file_stat.mode) catch {
            return fail(ctx, dest_file_path, "failed to set destination permissions", PackageStagingError.FileSystem);
        };

        files_copied += 1;
        const copied_path = allocator.dupe(u8, entry.rel_path) catch {
            return fail(ctx, entry.rel_path, "failed to copy collected path", PackageStagingError.OutOfMemory);
        };
        copied_files.append(allocator, copied_path) catch {
            return fail(ctx, entry.rel_path, "failed to record collected path", PackageStagingError.OutOfMemory);
        };
        ctx.debug("collected file: {s}", .{entry.rel_path});
    }

    const result_files = copied_files.toOwnedSlice(allocator) catch {
        return fail(ctx, config.source_dir, "failed to finalize collected file list", PackageStagingError.OutOfMemory);
    };

    return PackageStagingResult{
        .files_copied = files_copied,
        .copied_files = result_files,
        .allocator = allocator,
    };
}

test "PackageStaging copies files based on patterns" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create source directory with test files
    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    try std.fs.cwd().makePath(source_dir);

    // Create subdirectories and files to match patterns
    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "lib" });
    defer test_env.ctx.allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    // Create test files
    const app_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "myapp" });
    defer test_env.ctx.allocator.free(app_path);
    var app_file = try std.fs.createFileAbsolute(app_path, .{});
    defer app_file.close();
    try app_file.writeAll("#!/bin/bash\necho hello");

    const lib_path = try std.fs.path.join(test_env.ctx.allocator, &.{ lib_dir, "libtest.so" });
    defer test_env.ctx.allocator.free(lib_path);
    var lib_file = try std.fs.createFileAbsolute(lib_path, .{});
    defer lib_file.close();
    try lib_file.writeAll("binary content");

    // Create destination directory
    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    // Integration test: exercise collectFiles behavior (migration/integration test)
    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{ "usr/bin/*", "usr/lib/*.so" },
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.files_copied);
    // Should contain both myapp and libtest.so
    try std.testing.expect(result.copied_files.len >= 1);
}

test "PackageStaging handles exact pattern matches" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create source with specific file
    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    try std.fs.cwd().makePath(source_dir);

    const config_path = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "config.txt" });
    defer test_env.ctx.allocator.free(config_path);
    var config_file = try std.fs.createFileAbsolute(config_path, .{});
    defer config_file.close();
    try config_file.writeAll("key=value");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    // Integration test: exact pattern matching behavior
    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"config.txt"},
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);
}

test "PackageStaging preserves file permissions" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create source directory with executable file
    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    // Create an executable file
    const exec_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "myapp" });
    defer test_env.ctx.allocator.free(exec_path);
    var exec_file = try std.fs.createFileAbsolute(exec_path, .{});
    try exec_file.writeAll("#!/bin/sh\necho hello");
    // Set executable permissions (0755)
    try exec_file.chmod(0o755);
    exec_file.close();

    // Create destination directory
    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    // Collect files
    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"bin/*"},
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);

    // Verify permissions were preserved
    const dest_exec_path = try std.fs.path.join(test_env.ctx.allocator, &.{ dest_dir, "bin", "myapp" });
    defer test_env.ctx.allocator.free(dest_exec_path);

    const dest_file = try std.fs.openFileAbsolute(dest_exec_path, .{});
    defer dest_file.close();

    const stat = try dest_file.stat();
    // Check that executable bits are set (owner, group, other)
    try std.testing.expect((stat.mode & 0o111) != 0);
    // Check that the full mode matches (0755)
    try std.testing.expectEqual(@as(u32, 0o755), stat.mode & 0o777);
}

test "PackageStaging rejects non-recursive patterns that match only directories" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const bin_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "perl" });
    defer test_env.ctx.allocator.free(bin_path);
    var bin = try std.fs.createFileAbsolute(bin_path, .{});
    defer bin.close();
    try bin.writeAll("binary");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/*"},
        .destination = dest_dir,
    });
    try std.testing.expectError(error.InvalidInput, result);
}

test "PackageStaging rejects exact non-recursive directory paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const bin_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "perl" });
    defer test_env.ctx.allocator.free(bin_path);
    var bin = try std.fs.createFileAbsolute(bin_path, .{});
    defer bin.close();
    try bin.writeAll("binary");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/bin"},
        .destination = dest_dir,
    });
    try std.testing.expectError(error.InvalidInput, result);
}

test "PackageStaging supports fnmatch bracket expressions" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const app_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "perl1" });
    defer test_env.ctx.allocator.free(app_path);
    var app = try std.fs.createFileAbsolute(app_path, .{});
    defer app.close();
    try app.writeAll("binary");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/bin/perl[0-9]"},
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);
    try std.testing.expectEqualStrings("usr/bin/perl1", result.copied_files[0]);
}

test "PackageStaging supports trailing slash recursive directory shorthand" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const doc_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "share", "doc", "pkg", "nested" });
    defer test_env.ctx.allocator.free(doc_dir);
    try std.fs.cwd().makePath(doc_dir);

    const readme_path = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "share", "doc", "pkg", "README" });
    defer test_env.ctx.allocator.free(readme_path);
    var readme = try std.fs.createFileAbsolute(readme_path, .{});
    defer readme.close();
    try readme.writeAll("readme");

    const nested_path = try std.fs.path.join(test_env.ctx.allocator, &.{ doc_dir, "guide.txt" });
    defer test_env.ctx.allocator.free(nested_path);
    var nested = try std.fs.createFileAbsolute(nested_path, .{});
    defer nested.close();
    try nested.writeAll("guide");

    const outside_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(outside_dir);
    try std.fs.cwd().makePath(outside_dir);
    const outside_path = try std.fs.path.join(test_env.ctx.allocator, &.{ outside_dir, "tool" });
    defer test_env.ctx.allocator.free(outside_path);
    var outside = try std.fs.createFileAbsolute(outside_path, .{});
    defer outside.close();
    try outside.writeAll("tool");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/share/doc/"},
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.files_copied);

    var saw_readme = false;
    var saw_nested = false;
    for (result.copied_files) |p| {
        if (std.mem.eql(u8, p, "usr/share/doc/pkg/README")) saw_readme = true;
        if (std.mem.eql(u8, p, "usr/share/doc/pkg/nested/guide.txt")) saw_nested = true;
    }
    try std.testing.expect(saw_readme);
    try std.testing.expect(saw_nested);
}

test "PackageStaging supports exclusion patterns with ! prefix" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const keep_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "keep" });
    defer test_env.ctx.allocator.free(keep_path);
    var keep_file = try std.fs.createFileAbsolute(keep_path, .{});
    defer keep_file.close();
    try keep_file.writeAll("keep");

    const skip_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "skip" });
    defer test_env.ctx.allocator.free(skip_path);
    var skip_file = try std.fs.createFileAbsolute(skip_path, .{});
    defer skip_file.close();
    try skip_file.writeAll("skip");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{ "usr/bin/*", "!usr/bin/skip" },
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);
    try std.testing.expectEqualStrings("usr/bin/keep", result.copied_files[0]);
}

test "PackageStaging exclusion patterns are not required to match" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const app_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "ok" });
    defer test_env.ctx.allocator.free(app_path);
    var app = try std.fs.createFileAbsolute(app_path, .{});
    defer app.close();
    try app.writeAll("ok");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{ "usr/bin/*", "!usr/bin/does-not-exist" },
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);
    try std.testing.expectEqualStrings("usr/bin/ok", result.copied_files[0]);
}

test "PackageStaging supports recursive exclusion with trailing slash" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const root_doc_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "share", "doc" });
    defer test_env.ctx.allocator.free(root_doc_dir);
    try std.fs.cwd().makePath(root_doc_dir);

    const keep_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ root_doc_dir, "pkg" });
    defer test_env.ctx.allocator.free(keep_dir);
    try std.fs.cwd().makePath(keep_dir);

    const exclude_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ keep_dir, "private" });
    defer test_env.ctx.allocator.free(exclude_dir);
    try std.fs.cwd().makePath(exclude_dir);

    const keep_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ keep_dir, "README" });
    defer test_env.ctx.allocator.free(keep_file_path);
    var keep_file = try std.fs.createFileAbsolute(keep_file_path, .{});
    defer keep_file.close();
    try keep_file.writeAll("readme");

    const excluded_file_path = try std.fs.path.join(test_env.ctx.allocator, &.{ exclude_dir, "secret.txt" });
    defer test_env.ctx.allocator.free(excluded_file_path);
    var excluded_file = try std.fs.createFileAbsolute(excluded_file_path, .{});
    defer excluded_file.close();
    try excluded_file.writeAll("secret");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{ "usr/share/doc/", "!usr/share/doc/pkg/private/" },
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);
    try std.testing.expectEqualStrings("usr/share/doc/pkg/README", result.copied_files[0]);
}

test "PackageStaging errors when any pattern matches no files" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const app_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "ok" });
    defer test_env.ctx.allocator.free(app_path);
    var app = try std.fs.createFileAbsolute(app_path, .{});
    defer app.close();
    try app.writeAll("ok");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{ "usr/bin/*", "usr/lib/*.so" },
        .destination = dest_dir,
    });
    try std.testing.expectError(error.InvalidInput, result);
}

test "PackageStaging ignores unmatched usr/local paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const good_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(good_dir);
    try std.fs.cwd().makePath(good_dir);

    const good_path = try std.fs.path.join(test_env.ctx.allocator, &.{ good_dir, "ok" });
    defer test_env.ctx.allocator.free(good_path);
    var good_file = try std.fs.createFileAbsolute(good_path, .{});
    defer good_file.close();
    try good_file.writeAll("ok");

    const bad_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "local", "bin" });
    defer test_env.ctx.allocator.free(bad_dir);
    try std.fs.cwd().makePath(bad_dir);

    const bad_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bad_dir, "bad" });
    defer test_env.ctx.allocator.free(bad_path);
    var bad_file = try std.fs.createFileAbsolute(bad_path, .{});
    defer bad_file.close();
    try bad_file.writeAll("bad");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/bin/*"},
        .destination = dest_dir,
    });
    var staged = try result;
    defer staged.deinit();

    try std.testing.expectEqual(@as(usize, 1), staged.files_copied);
    try std.testing.expectEqualStrings("usr/bin/ok", staged.copied_files[0]);
}

test "PackageStaging rejects matched usr/local paths" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const bad_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "local", "bin" });
    defer test_env.ctx.allocator.free(bad_dir);
    try std.fs.cwd().makePath(bad_dir);

    const bad_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bad_dir, "bad" });
    defer test_env.ctx.allocator.free(bad_path);
    var bad_file = try std.fs.createFileAbsolute(bad_path, .{});
    defer bad_file.close();
    try bad_file.writeAll("bad");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/local/"},
        .destination = dest_dir,
    });
    try std.testing.expectError(error.InvalidInput, result);
}

test "PackageStaging preserves empty directories matched by recursive patterns" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const root_doc_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "share", "doc" });
    defer test_env.ctx.allocator.free(root_doc_dir);
    try std.fs.cwd().makePath(root_doc_dir);

    const empty_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ root_doc_dir, "pkg", "empty" });
    defer test_env.ctx.allocator.free(empty_dir);
    try std.fs.cwd().makePath(empty_dir);

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"usr/share/doc/"},
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.files_copied);

    const staged_empty_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ dest_dir, "usr", "share", "doc", "pkg", "empty" });
    defer test_env.ctx.allocator.free(staged_empty_dir);
    var dir = try std.fs.openDirAbsolute(staged_empty_dir, .{});
    dir.close();
}

test "PackageStaging cleans partial output on late failure" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);
    const bin_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "bin" });
    defer test_env.ctx.allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const app_path = try std.fs.path.join(test_env.ctx.allocator, &.{ bin_dir, "ok" });
    defer test_env.ctx.allocator.free(app_path);
    var app = try std.fs.createFileAbsolute(app_path, .{});
    defer app.close();
    try app.writeAll("ok");

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{ "usr/bin/*", "usr/lib/*.so" },
        .destination = dest_dir,
    });
    try std.testing.expectError(error.InvalidInput, result);

    var dest_handle = try std.fs.openDirAbsolute(dest_dir, .{ .iterate = true });
    defer dest_handle.close();
    var iter = dest_handle.iterate();
    try std.testing.expect((try iter.next()) == null);
}

test "PackageStaging converts absolute symlink target within source boundary" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "lib" });
    defer test_env.ctx.allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    const usr_lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "usr", "lib" });
    defer test_env.ctx.allocator.free(usr_lib_dir);
    try std.fs.cwd().makePath(usr_lib_dir);

    const target_path = try std.fs.path.join(test_env.ctx.allocator, &.{ usr_lib_dir, "libfoo.so.1" });
    defer test_env.ctx.allocator.free(target_path);
    var target_file = try std.fs.createFileAbsolute(target_path, .{});
    defer target_file.close();
    try target_file.writeAll("libfoo");

    const symlink_path = try std.fs.path.join(test_env.ctx.allocator, &.{ lib_dir, "ld-musl-x86_64.so.1" });
    defer test_env.ctx.allocator.free(symlink_path);
    try std.posix.symlinkat("/usr/lib/libfoo.so.1", std.fs.cwd().fd, symlink_path);

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    var result = try stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"lib/*"},
        .destination = dest_dir,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.files_copied);

    const staged_symlink = try std.fs.path.join(test_env.ctx.allocator, &.{ dest_dir, "lib", "ld-musl-x86_64.so.1" });
    defer test_env.ctx.allocator.free(staged_symlink);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staged_target = try std.fs.readLinkAbsolute(staged_symlink, &link_buf);
    try std.testing.expectEqualStrings("../usr/lib/libfoo.so.1", staged_target);
}

test "PackageStaging rejects absolute symlink target outside source boundary" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const source_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "source" });
    defer test_env.ctx.allocator.free(source_dir);

    const lib_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ source_dir, "lib" });
    defer test_env.ctx.allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    const symlink_path = try std.fs.path.join(test_env.ctx.allocator, &.{ lib_dir, "bad-link" });
    defer test_env.ctx.allocator.free(symlink_path);
    try std.posix.symlinkat("/etc/passwd", std.fs.cwd().fd, symlink_path);

    const dest_dir = try std.fs.path.join(test_env.ctx.allocator, &.{ test_env.path, "dest" });
    defer test_env.ctx.allocator.free(dest_dir);

    const result = stagePackageFiles(&test_env.ctx, .{
        .source_dir = source_dir,
        .patterns = &[_][]const u8{"lib/*"},
        .destination = dest_dir,
    });
    try std.testing.expectError(error.InvalidInput, result);
}
