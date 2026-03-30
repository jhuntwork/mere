const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const filetype = @import("filetype.zig");
const elf = @import("elf.zig");
const scanElfMetadata = elf.scanElfMetadata;
const ElfScanResult = elf.ElfScanResult;
const p = @import("path.zig");
const errors = @import("errors.zig");

/// Package operations error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during package operations
/// - FileSystem: Package file operations failed
/// - PermissionDenied: Insufficient permissions for package operations
/// - InvalidInput: Invalid package input or configuration
/// - CorruptData: Package data is corrupted or invalid
const Std = errors.StandardErrors;
pub const PackageError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.CorruptData;

/// Types of dependencies that can be tracked
pub const DependencyType = enum {
    /// ELF shared object dependency (DT_NEEDED)
    elf_needed,
    /// ELF interpreter dependency (PT_INTERP)
    elf_interpreter,
    /// Script interpreter detected from shebang (e.g. /usr/bin/python3 or via /usr/bin/env)
    script_interpreter,
    /// Split-package build interface requires the sibling runtime package that owns the shared library
    split_runtime,

    const TypeInfo = struct {
        enum_val: DependencyType,
        string_val: []const u8,
    };

    const type_info = [_]TypeInfo{
        .{ .enum_val = .elf_needed, .string_val = "elf-needed" },
        .{ .enum_val = .elf_interpreter, .string_val = "elf-interpreter" },
        .{ .enum_val = .script_interpreter, .string_val = "script-interpreter" },
        .{ .enum_val = .split_runtime, .string_val = "split-runtime" },
    };

    /// Convert the enum to a string representation
    pub fn toString(self: DependencyType) []const u8 {
        for (type_info) |info| {
            if (info.enum_val == self) {
                return info.string_val;
            }
        }
        unreachable; // All enum values should be in the table
    }

    /// Parse a string into a DependencyType
    /// Errors:
    ///   - InvalidArgument: When string doesn't match a known type
    pub fn fromString(str: []const u8) !DependencyType {
        for (type_info) |info| {
            if (std.mem.eql(u8, str, info.string_val)) {
                return info.enum_val;
            }
        }
        return error.InvalidArgument;
    }
};

/// Types of provisions that can be tracked
pub const ProvisionType = enum {
    /// ELF shared object name (SONAME)
    elf_soname,
    /// Executable binary in bin, usr/bin, sbin, or usr/sbin
    bin,

    const TypeInfo = struct {
        enum_val: ProvisionType,
        string_val: []const u8,
    };

    const type_info = [_]TypeInfo{
        .{ .enum_val = .elf_soname, .string_val = "elf-soname" },
        .{ .enum_val = .bin, .string_val = "bin" },
    };

    /// Convert the enum to a string representation
    pub fn toString(self: ProvisionType) []const u8 {
        for (type_info) |info| {
            if (info.enum_val == self) {
                return info.string_val;
            }
        }
        unreachable; // All enum values should be in the table
    }

    /// Parse a string into a ProvisionType
    /// Errors:
    ///   - InvalidArgument: When string doesn't match a known type
    pub fn fromString(str: []const u8) !ProvisionType {
        for (type_info) |info| {
            if (std.mem.eql(u8, str, info.string_val)) {
                return info.enum_val;
            }
        }
        return error.InvalidArgument;
    }
};

/// Represents a dependency with its type
pub const Dependency = struct {
    /// The resource name (e.g., "libc.so", "/lib/ld-musl-x86_64.so.1")
    resource: []const u8,
    /// The type of dependency
    dep_type: DependencyType,
    /// Optional version constraint expression
    version_constraint: ?[]const u8 = null,

    /// Create a new dependency
    /// Errors:
    ///   - OutOfMemory: When memory allocation fails
    pub fn init(allocator: std.mem.Allocator, resource: []const u8, dep_type: DependencyType) PackageError!Dependency {
        return initWithConstraint(allocator, resource, dep_type, null);
    }

    pub fn initWithConstraint(
        allocator: std.mem.Allocator,
        resource: []const u8,
        dep_type: DependencyType,
        version_constraint: ?[]const u8,
    ) PackageError!Dependency {
        const resource_copy = allocator.dupe(u8, resource) catch {
            return PackageError.OutOfMemory;
        };
        errdefer allocator.free(resource_copy);

        const version_constraint_copy = if (version_constraint) |expr|
            allocator.dupe(u8, expr) catch {
                return PackageError.OutOfMemory;
            }
        else
            null;

        return Dependency{
            .resource = resource_copy,
            .dep_type = dep_type,
            .version_constraint = version_constraint_copy,
        };
    }

    /// Free resources
    pub fn deinit(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        if (self.version_constraint) |expr| allocator.free(expr);
    }

    pub fn getType(self: Dependency) DependencyType {
        return self.dep_type;
    }
};

/// Represents a provision with its type
pub const Provision = struct {
    /// The resource name (e.g., "libcustom.so.1", "ls")
    resource: []const u8,
    /// The type of provision
    prov_type: ProvisionType,

    /// Create a new provision
    /// Errors:
    ///   - OutOfMemory: When memory allocation fails
    pub fn init(allocator: std.mem.Allocator, resource: []const u8, prov_type: ProvisionType) PackageError!Provision {
        const resource_copy = allocator.dupe(u8, resource) catch {
            return PackageError.OutOfMemory;
        };
        errdefer allocator.free(resource_copy);

        return Provision{
            .resource = resource_copy,
            .prov_type = prov_type,
        };
    }

    /// Free resources
    pub fn deinit(self: *Provision, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
    }

    pub fn getType(self: Provision) ProvisionType {
        return self.prov_type;
    }
};

pub const Package = struct {
    ctx: *Context,
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    release: ?u32 = null,
    arch: ?[]const u8 = null,
    dependencies: std.array_list.Managed(Dependency),
    provisions: std.array_list.Managed(Provision),
    signature: ?[]const u8 = null,
    content_hash: []const u8,
    archive_hash: []const u8 = "",

    pub fn init(ctx: *Context) Package {
        return .{
            .ctx = ctx,
            .dependencies = std.array_list.Managed(Dependency).init(ctx.allocator),
            .provisions = std.array_list.Managed(Provision).init(ctx.allocator),
            .content_hash = "",
            .archive_hash = "",
        };
    }

    pub fn deinit(self: *Package) void {
        if (self.name) |n| self.ctx.allocator.free(n);
        if (self.version) |v| self.ctx.allocator.free(v);
        if (self.arch) |a| self.ctx.allocator.free(a);
        if (self.signature) |s| self.ctx.allocator.free(s);

        if (self.content_hash.len > 0 and self.content_hash.ptr != "".ptr) {
            self.ctx.allocator.free(self.content_hash);
        }
        if (self.archive_hash.len > 0 and self.archive_hash.ptr != "".ptr) {
            self.ctx.allocator.free(self.archive_hash);
        }

        for (self.dependencies.items) |*dep| {
            dep.deinit(self.ctx.allocator);
        }
        self.dependencies.deinit();

        for (self.provisions.items) |*prov| {
            prov.deinit(self.ctx.allocator);
        }
        self.provisions.deinit();

        self.name = null;
        self.version = null;
        self.arch = null;
        self.signature = null;
        self.release = null;
        self.content_hash = "";
        self.archive_hash = "";
    }

    pub fn addDependency(self: *Package, resource: []const u8, dep_type: DependencyType) !void {
        return self.addDependencyWithConstraint(resource, dep_type, null);
    }

    pub fn addDependencyWithConstraint(
        self: *Package,
        resource: []const u8,
        dep_type: DependencyType,
        version_constraint: ?[]const u8,
    ) !void {
        for (self.dependencies.items) |*dep| {
            if (std.mem.eql(u8, dep.resource, resource)) {
                if (version_constraint) |new_expr| {
                    if (dep.version_constraint) |old_expr| {
                        if (!std.mem.eql(u8, old_expr, new_expr)) {
                            self.ctx.allocator.free(old_expr);
                            dep.version_constraint = try self.ctx.allocator.dupe(u8, new_expr);
                        }
                    } else {
                        dep.version_constraint = try self.ctx.allocator.dupe(u8, new_expr);
                    }
                }
                return;
            }
        }

        var new_dep = try Dependency.initWithConstraint(self.ctx.allocator, resource, dep_type, version_constraint);
        errdefer new_dep.deinit(self.ctx.allocator);
        try self.dependencies.append(new_dep);
    }

    pub fn addProvision(self: *Package, resource: []const u8, prov_type: ProvisionType) !void {
        for (self.provisions.items) |prov| {
            if (std.mem.eql(u8, prov.resource, resource)) {
                return;
            }
        }

        var new_prov = try Provision.init(self.ctx.allocator, resource, prov_type);
        errdefer new_prov.deinit(self.ctx.allocator);
        try self.provisions.append(new_prov);
    }

    pub fn scanDirectory(self: *Package, dir_path: []const u8) !void {
        const target_arch = self.arch orelse return self.ctx.fail(error.InvalidInput, dir_path, "package target architecture is not set");
        var res = try scanDir(self.ctx, dir_path, target_arch);
        for (res.dependencies.items) |dep| {
            try self.addDependency(dep.resource, dep.dep_type);
            var owned_dep = dep;
            owned_dep.deinit(res.dependencies.allocator);
        }
        res.dependencies.deinit();

        for (res.provisions.items) |prov| {
            try self.addProvision(prov.resource, prov.prov_type);
            var owned_prov = prov;
            owned_prov.deinit(res.provisions.allocator);
        }
        res.provisions.deinit();
    }

    pub fn canonicalArchiveName(self: *const Package) ![]const u8 {
        if (self.archive_hash.len != 64) {
            return PackageError.InvalidInput;
        }
        for (self.archive_hash) |c| {
            const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
            if (!is_hex) return PackageError.InvalidInput;
        }

        return std.fmt.allocPrint(
            self.ctx.allocator,
            "{s}-{s}-{d}-{s}-{s}.pkg.tar.zst",
            .{
                self.name orelse "unknown",
                self.version orelse "unknown",
                self.release orelse 0,
                self.arch orelse "unknown",
                self.archive_hash,
            },
        );
    }
};

/// Result of scanning a package directory (pure, allocator-owned data)
pub const DirScanResult = struct {
    dependencies: std.array_list.Managed(Dependency),
    provisions: std.array_list.Managed(Provision),

    pub fn init(allocator: std.mem.Allocator) DirScanResult {
        return DirScanResult{
            .dependencies = std.array_list.Managed(Dependency).init(allocator),
            .provisions = std.array_list.Managed(Provision).init(allocator),
        };
    }

    pub fn deinit(self: *DirScanResult) void {
        for (self.dependencies.items) |*d| d.deinit(self.dependencies.allocator);
        self.dependencies.deinit();

        for (self.provisions.items) |*prov| prov.deinit(self.provisions.allocator);
        self.provisions.deinit();
    }
};

fn setScanDiagnosticContext(
    ctx: *Context,
    dir_path: []const u8,
    entry_path: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const arena = ctx.getDiagArena();
    const subject = if (entry_path) |entry|
        std.fs.path.join(arena, &.{ dir_path, entry }) catch return
    else
        arena.dupe(u8, dir_path) catch return;
    const details = std.fmt.allocPrint(arena, fmt, args) catch {
        ctx.withDiagnosticContext(errors.DiagnosticContext.init().withSubject(subject));
        return;
    };
    ctx.withDiagnosticContext(
        errors.DiagnosticContext.init()
            .withSubject(subject)
            .withDetails(details),
    );
}

/// Scan a directory for ELF dependencies/provisions.
/// Returns a DirScanResult allocated with ctx.allocator.
/// Caller owns returned memory and must call deinit() on the result.
pub fn scanDir(ctx: *Context, dir_path: []const u8, target_arch: []const u8) !DirScanResult {
    const io = p.currentIo();
    var result = DirScanResult.init(ctx.allocator);
    errdefer result.deinit();
    // Open the directory
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        setScanDiagnosticContext(ctx, dir_path, null, "package scan root open failed ({s})", .{@errorName(err)});
        return err;
    };
    defer dir.close(io);

    var walker = dir.walk(ctx.allocator) catch |err| {
        setScanDiagnosticContext(ctx, dir_path, null, "package scan ELF walker creation failed ({s})", .{@errorName(err)});
        return err;
    };
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next(io) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, null, "package scan ELF walk failed ({s})", .{@errorName(err)});
            return err;
        };
        if (maybe_entry == null) break;
        const entry = maybe_entry.?;
        if (entry.kind != .file) continue;

        const file = dir.openFile(io, entry.path, .{}) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to open file ({s})", .{@errorName(err)});
            return err;
        };
        defer file.close(io);

        const abs_path = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.path }) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to build absolute path ({s})", .{@errorName(err)});
            return err;
        };
        defer ctx.allocator.free(abs_path);

        if (filetype.detect(&file)) |kind| {
            if (kind == .elf) {
                const header = elf.readElfHeaderInfo(abs_path) catch |err| {
                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to classify ELF header ({s})", .{@errorName(err)});
                    return err;
                };
                switch (elf.runtimeMetadataScanDisposition(target_arch, header)) {
                    .scan => {},
                    .skip_non_runtime_type => {
                        ctx.debug("package scan: skipping non-runtime ELF metadata for {s} (type={d})", .{ abs_path, header.elf_type });
                        continue;
                    },
                    .skip_foreign_target => {
                        ctx.debug("package scan: skipping foreign-target ELF metadata for {s} (target={s} machine={d})", .{ abs_path, target_arch, header.machine });
                        continue;
                    },
                    .skip_unknown_target => {
                        ctx.debug("package scan: skipping ELF metadata for {s}; no ELF target mapping for arch {s}", .{ abs_path, target_arch });
                        continue;
                    },
                    .skip_unsupported_layout => {
                        ctx.debug("package scan: skipping unsupported ELF runtime metadata for {s} (class={s} endian={s})", .{ abs_path, @tagName(header.class), @tagName(header.endian) });
                        continue;
                    },
                }
                // Get ELF dependencies and provisions
                var result_deps: ElfScanResult = scanElfMetadata(ctx, abs_path) catch |err| {
                    const diag = ctx.getDiagnosticContext();
                    if (diag.subject == null and diag.details == null) {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to read ELF metadata ({s})", .{@errorName(err)});
                    }
                    return err;
                };
                defer {
                    result_deps.deps.deinit();
                    result_deps.provisions.deinit();
                }

                // Collect dependencies
                for (result_deps.deps.items) |dep| {
                    var new_dep = Dependency.init(ctx.allocator, dep.resource, dep.dep_type) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to record dependency '{s}' ({s})", .{ dep.resource, @errorName(err) });
                        return err;
                    };
                    errdefer new_dep.deinit(ctx.allocator);
                    result.dependencies.append(new_dep) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to append dependency '{s}' ({s})", .{ dep.resource, @errorName(err) });
                        return err;
                    };
                    var owned_dep = dep;
                    owned_dep.deinit(ctx.allocator);
                }

                // Collect provisions
                for (result_deps.provisions.items) |prov| {
                    var new_prov = Provision.init(ctx.allocator, prov.resource, prov.prov_type) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to record provision '{s}' ({s})", .{ prov.resource, @errorName(err) });
                        return err;
                    };
                    errdefer new_prov.deinit(ctx.allocator);
                    result.provisions.append(new_prov) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan ELF pass failed to append provision '{s}' ({s})", .{ prov.resource, @errorName(err) });
                        return err;
                    };
                    var owned_prov = prov;
                    owned_prov.deinit(ctx.allocator);
                }
            }
        } else |err| {
            ctx.debug("package scan: skipping filetype detection for {s}: {s}", .{ abs_path, @errorName(err) });
        }
    }

    // Second pass: symlinks, script interpreter detection and bin discovery.
    {
        var dir2 = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, null, "package scan secondary root open failed ({s})", .{@errorName(err)});
            return err;
        };
        defer dir2.close(io);
        var walker2 = dir2.walk(ctx.allocator) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, null, "package scan secondary walker creation failed ({s})", .{@errorName(err)});
            return err;
        };
        defer walker2.deinit();
        while (true) {
            const maybe_entry = walker2.next(io) catch |err| {
                setScanDiagnosticContext(ctx, dir_path, null, "package scan secondary walk failed ({s})", .{@errorName(err)});
                return err;
            };
            if (maybe_entry == null) break;
            const entry = maybe_entry.?;
            if (entry.kind == .sym_link) {
                const symlink_name = std.fs.path.basename(entry.path);
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_len = dir2.readLink(io, entry.path, &target_buf) catch |err| {
                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to read link ({s})", .{@errorName(err)});
                    return err;
                };
                const target_path = target_buf[0..target_len];
                // For relative symlinks, resolve relative to the symlink's directory
                const abs_target = if (std.fs.path.isAbsolute(target_path))
                    target_path
                else blk: {
                    const symlink_dir = std.fs.path.dirname(entry.path) orelse "";
                    const joined = std.fs.path.join(ctx.allocator, &.{ dir_path, symlink_dir, target_path }) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to resolve target path ({s})", .{@errorName(err)});
                        return err;
                    };
                    break :blk joined;
                };
                const owns_abs_target = !std.fs.path.isAbsolute(target_path);
                defer if (owns_abs_target) ctx.allocator.free(abs_target);

                var target_exists = true;
                std.Io.Dir.accessAbsolute(io, abs_target, .{}) catch |e| {
                    if (e == error.FileNotFound) {
                        target_exists = false;
                        ctx.debug("package scan: symlink target missing for {s} -> {s}", .{ entry.path, target_path });
                    } else {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to access target '{s}' ({s})", .{ target_path, @errorName(e) });
                        return e;
                    }
                };
                if (target_exists) {
                    const file = std.Io.Dir.openFileAbsolute(io, abs_target, .{}) catch |err| {
                        ctx.debug("package scan: skipping symlink target open for {s} -> {s}: {s}", .{ entry.path, target_path, @errorName(err) });
                        continue;
                    };
                    defer file.close(io);
                    if (filetype.detect(&file)) |kind| {
                        if (kind == .elf) {
                            const norm_path = if (entry.path[0] == '.' and entry.path.len > 1 and entry.path[1] == '/')
                                entry.path[2..]
                            else if (entry.path[0] == '.')
                                entry.path[1..]
                            else
                                entry.path;

                            if (isSharedObjectBasename(symlink_name)) {
                                var soname_prov = Provision.init(ctx.allocator, symlink_name, .elf_soname) catch |err| {
                                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to record SONAME provision '{s}' ({s})", .{ symlink_name, @errorName(err) });
                                    return err;
                                };
                                errdefer soname_prov.deinit(ctx.allocator);
                                result.provisions.append(soname_prov) catch |err| {
                                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to append SONAME provision '{s}' ({s})", .{ symlink_name, @errorName(err) });
                                    return err;
                                };
                            }

                            if (std.mem.startsWith(u8, symlink_name, "ld-musl-") and
                                std.mem.endsWith(u8, symlink_name, ".so.1") and
                                std.mem.startsWith(u8, norm_path, "lib/"))
                            {
                                const interp_path = std.fs.path.join(ctx.allocator, &.{ "/", norm_path }) catch |err| {
                                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to build interpreter provision path ({s})", .{@errorName(err)});
                                    return err;
                                };
                                defer ctx.allocator.free(interp_path);
                                var interp_prov = Provision.init(ctx.allocator, interp_path, .elf_soname) catch |err| {
                                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to record interpreter provision '{s}' ({s})", .{ interp_path, @errorName(err) });
                                    return err;
                                };
                                errdefer interp_prov.deinit(ctx.allocator);
                                result.provisions.append(interp_prov) catch |err| {
                                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to append interpreter provision '{s}' ({s})", .{ interp_path, @errorName(err) });
                                    return err;
                                };
                            }
                        }
                    } else |err| {
                        ctx.debug("package scan: skipping symlink target filetype detection for {s} -> {s}: {s}", .{ entry.path, target_path, @errorName(err) });
                    }
                }

                // Handle symlinks in bin directories for essential interpreters
                const norm_path = if (entry.path[0] == '.' and entry.path.len > 1 and entry.path[1] == '/')
                    entry.path[2..]
                else
                    entry.path;

                if (std.mem.startsWith(u8, norm_path, "bin/") or
                    std.mem.startsWith(u8, norm_path, "sbin/") or
                    std.mem.startsWith(u8, norm_path, "usr/bin/") or
                    std.mem.startsWith(u8, norm_path, "usr/sbin/"))
                {
                    const full_path = std.fs.path.join(ctx.allocator, &.{ "/", norm_path }) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to build bin provision path ({s})", .{@errorName(err)});
                        return err;
                    };
                    defer ctx.allocator.free(full_path);
                    var new_prov = Provision.init(ctx.allocator, full_path, .bin) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to record bin provision '{s}' ({s})", .{ full_path, @errorName(err) });
                        return err;
                    };
                    errdefer new_prov.deinit(ctx.allocator);
                    result.provisions.append(new_prov) catch |err| {
                        setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan symlink pass failed to append bin provision '{s}' ({s})", .{ full_path, @errorName(err) });
                        return err;
                    };
                }
            }

            // For regular files, detect script interpreters (shebang) deterministically
            // and discover provided binaries placed under bin directories.
            if (entry.kind == .file) {
                // Compose absolute path for file operations
                const abs = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.path }) catch |err| {
                    setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan script/bin pass failed to build absolute path ({s})", .{@errorName(err)});
                    return err;
                };
                defer ctx.allocator.free(abs);

                const f = std.Io.Dir.openFileAbsolute(io, abs, .{}) catch |err| {
                    ctx.debug("package scan: skipping file open for {s}: {s}", .{ abs, @errorName(err) });
                    continue;
                };
                defer f.close(io);
                const stat = f.stat(io) catch |err| {
                    ctx.debug("package scan: skipping stat for {s}: {s}", .{ abs, @errorName(err) });
                    continue;
                };
                const is_executable = (stat.permissions.toMode() & 0o111) != 0;

                // Read a small header to detect shebangs
                var header_buf: [256]u8 = undefined;
                const read_len = f.readPositionalAll(io, header_buf[0..], 0) catch 0;
                if (is_executable and read_len >= 2 and header_buf[0] == '#' and header_buf[1] == '!') {
                    // Parse first line up to newline
                    var nl_index: usize = read_len;
                    var i: usize = 0;
                    while (i < read_len) {
                        const c = header_buf[i];
                        if (c == '\n' or c == '\r') {
                            nl_index = i;
                            break;
                        }
                        i += 1;
                    }
                    const shebang_slice = header_buf[2..nl_index];
                    const shebang = std.mem.trim(u8, shebang_slice, " \t");

                    // Split shebang by whitespace to handle "/usr/bin/env python3"
                    var tokens = std.array_list.Managed([]const u8).init(ctx.allocator);
                    defer tokens.deinit();
                    // Manual tokenization because std.mem.splitWhitespace is not available.
                    const s = shebang;
                    var idx: usize = 0;
                    while (idx < s.len) {
                        // skip leading whitespace
                        while (idx < s.len and (s[idx] == ' ' or s[idx] == '\t')) {
                            idx += 1;
                        }
                        if (idx >= s.len) break;
                        var j: usize = idx;
                        while (j < s.len and (s[j] != ' ' and s[j] != '\t')) {
                            j += 1;
                        }
                        tokens.append(s[idx..j]) catch |err| {
                            setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan script pass failed to tokenize shebang ({s})", .{@errorName(err)});
                            return err;
                        };
                        idx = j;
                    }

                    if (tokens.items.len > 0) {
                        if (normalizeShebangInterpreter(tokens.items)) |interpreter_resource| {
                            // Record dependency on the script interpreter
                            var new_dep = Dependency.init(ctx.allocator, interpreter_resource, DependencyType.script_interpreter) catch |err| {
                                setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan script pass failed to record interpreter dependency '{s}' ({s})", .{ interpreter_resource, @errorName(err) });
                                return err;
                            };
                            errdefer new_dep.deinit(ctx.allocator);
                            result.dependencies.append(new_dep) catch |err| {
                                setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan script pass failed to append interpreter dependency '{s}' ({s})", .{ interpreter_resource, @errorName(err) });
                                return err;
                            };
                        }
                    }

                    // Rewind file position for possible further checks (stat already used below)
                }

                // Check if this is an executable file in a bin directory (regardless of shebang)
                const norm_path = if (entry.path[0] == '.' and entry.path.len > 1 and entry.path[1] == '/')
                    entry.path[2..]
                else
                    entry.path;

                if (std.mem.startsWith(u8, norm_path, "bin/") or
                    std.mem.startsWith(u8, norm_path, "sbin/") or
                    std.mem.startsWith(u8, norm_path, "usr/bin/") or
                    std.mem.startsWith(u8, norm_path, "usr/sbin/"))
                {
                    // Check if file is executable
                    if (is_executable) { // Check if any execute bit is set
                        const full_path = std.fs.path.join(ctx.allocator, &.{ "/", norm_path }) catch |err| {
                            setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan bin pass failed to build bin provision path ({s})", .{@errorName(err)});
                            return err;
                        };
                        defer ctx.allocator.free(full_path);
                        var new_prov = Provision.init(ctx.allocator, full_path, .bin) catch |err| {
                            setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan bin pass failed to record bin provision '{s}' ({s})", .{ full_path, @errorName(err) });
                            return err;
                        };
                        errdefer new_prov.deinit(ctx.allocator);
                        result.provisions.append(new_prov) catch |err| {
                            setScanDiagnosticContext(ctx, dir_path, entry.path, "package scan bin pass failed to append bin provision '{s}' ({s})", .{ full_path, @errorName(err) });
                            return err;
                        };
                    }
                }
            }
        }
    }

    return result;
}

/// Infer the package architecture by scanning all ELF files (including .a archives)
/// for their e_machine value.
///
/// Returns:
///   - The architecture string if all ELF content agrees on one machine type
///   - "any" if no ELF content is found
///   - Error if mixed architectures are detected
pub fn inferArch(ctx: *Context, dir_path: []const u8) ![]const u8 {
    const io = p.currentIo();
    var observed_machine: ?u16 = null;

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        setScanDiagnosticContext(ctx, dir_path, null, "arch inference: failed to open directory ({s})", .{@errorName(err)});
        return err;
    };
    defer dir.close(io);

    var walker = dir.walk(ctx.allocator) catch |err| {
        setScanDiagnosticContext(ctx, dir_path, null, "arch inference: failed to create walker ({s})", .{@errorName(err)});
        return err;
    };
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next(io) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, null, "arch inference: walk failed ({s})", .{@errorName(err)});
            return err;
        };
        if (maybe_entry == null) break;
        const entry = maybe_entry.?;
        if (entry.kind != .file) continue;

        const abs_path = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.path }) catch |err| {
            setScanDiagnosticContext(ctx, dir_path, entry.path, "arch inference: failed to build path ({s})", .{@errorName(err)});
            return err;
        };
        defer ctx.allocator.free(abs_path);

        const machine: ?u16 = if (std.mem.endsWith(u8, entry.path, ".a"))
            elf.readElfMachineFromArArchive(abs_path)
        else blk: {
            const header = elf.readElfHeaderInfo(abs_path) catch break :blk null;
            break :blk header.machine;
        };

        if (machine) |m| {
            // Skip unknown machine types (we can't map them to an arch string)
            if (elf.archFromMachine(m) == null) continue;

            if (observed_machine) |prev| {
                if (prev != m) {
                    return ctx.failFmt(
                        PackageError.InvalidInput,
                        dir_path,
                        "mixed ELF architectures detected: {s} and {s}",
                        .{ elf.archFromMachine(prev) orelse "unknown", elf.archFromMachine(m) orelse "unknown" },
                    );
                }
            } else {
                observed_machine = m;
            }
        }
    }

    if (observed_machine) |m| {
        return elf.archFromMachine(m) orelse "any";
    }
    return "any";
}

fn normalizeShebangInterpreter(tokens: []const []const u8) ?[]const u8 {
    if (tokens.len == 0) return null;

    var interpreter = tokens[0];
    if (std.mem.eql(u8, tokens[0], "/usr/bin/env")) {
        if (tokens.len < 2) return null;
        var i: usize = 1;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if (t.len == 0) continue;
            if (t[0] == '-') continue; // env flags like -S
            if (std.mem.indexOfScalar(u8, t, '=') != null) continue; // env assignments
            interpreter = t;
            break;
        }
        if (i >= tokens.len) return null;
    }

    if (interpreter.len == 0) return null;
    if (interpreter[0] == '-') return null;
    if (std.fs.path.isAbsolute(interpreter)) return interpreter;

    if (std.mem.indexOfScalar(u8, interpreter, '/')) |_| {
        const base = std.fs.path.basename(interpreter);
        if (base.len == 0) return null;
        return base;
    }

    return interpreter;
}

fn isSharedObjectBasename(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "lib")) return false;
    if (std.mem.endsWith(u8, name, ".so")) return true;
    return std.mem.indexOf(u8, name, ".so.") != null;
}

test "Package scanDirectory" {
    // Use createTestEnv to set up a test environment
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Use the context from the test environment
    var ctx = test_env.ctx;

    // Create a package
    var pkg = Package.init(&ctx);
    defer pkg.deinit();
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");

    // Copy test ELF library to temp dir
    const lib_name = "libtest.so";
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, lib_name });
    defer std.testing.allocator.free(lib_path);

    // Get absolute path to source test file and verify it
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path = try p.resolveToAbsolutePath("test/testdata/libtest.so", &src_buf);

    try p.copyFile(src_path, lib_path);

    // Scan the directory
    try pkg.scanDirectory(test_env.path);

    // Verify dependencies were found
    try std.testing.expect(pkg.dependencies.items.len > 0);

    // Helper function to check if a dependency exists
    const hasDependency = (struct {
        fn check(pkg_ptr: *Package, resource_name: []const u8) bool {
            for (pkg_ptr.dependencies.items) |dep| {
                if (std.mem.eql(u8, dep.resource, resource_name)) {
                    return true;
                }
            }
            return false;
        }
    }).check;

    try std.testing.expect(hasDependency(&pkg, "libc.so"));
    try std.testing.expect(hasDependency(&pkg, "libz.so.1"));
    try std.testing.expect(hasDependency(&pkg, "libssl.so.3"));

    // Copy dummy binary to temp dir to test interpreter detection
    const dummy_name = "dummy";
    const dummy_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, dummy_name });
    defer std.testing.allocator.free(dummy_path);

    // Get absolute path to source test file and verify it
    var dummy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dummy_src_path = try p.resolveToAbsolutePath("test/testdata/dummy", &dummy_buf);

    try p.copyFile(dummy_src_path, dummy_path);

    // Scan the directory again
    try pkg.scanDirectory(test_env.path);

    // Verify interpreter was found
    var found_interpreter = false;
    for (pkg.dependencies.items) |dep| {
        if (std.mem.eql(u8, dep.resource, "/lib/ld-musl-x86_64.so.1")) {
            found_interpreter = true;
            const dep_type = dep.getType();
            try std.testing.expectEqual(DependencyType.elf_interpreter, dep_type);
            break;
        }
    }
    try std.testing.expect(found_interpreter);

    // Create a bin directory and add an executable to test bin discovery
    const bin_dir_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "bin" });
    defer std.testing.allocator.free(bin_dir_path);

    ctx.debug("creating bin directory: {s}", .{bin_dir_path});
    try p.ensureDirExists(bin_dir_path);

    const test_bin_path = try std.fs.path.join(std.testing.allocator, &.{ bin_dir_path, "sh" });
    defer std.testing.allocator.free(test_bin_path);
    ctx.debug("creating test binary: {s}", .{test_bin_path});

    // Create a simple executable file
    {
        var bin_file = try std.Io.Dir.createFileAbsolute(p.currentIo(), test_bin_path, .{});
        try bin_file.writeStreamingAll(p.currentIo(), "#!/bin/sh\necho 'test'\n");
        bin_file.close(p.currentIo());
    }

    // Make it executable (0o755 = rwxr-xr-x)
    const file = try std.Io.Dir.openFileAbsolute(p.currentIo(), test_bin_path, .{});
    defer file.close(p.currentIo());
    try file.setPermissions(p.currentIo(), .executable_file);

    // Scan the directory again
    try pkg.scanDirectory(test_env.path);

    // Verify the binary was found as a provision
    var found_bin = false;
    for (pkg.provisions.items) |prov| {
        if (std.mem.eql(u8, prov.resource, "/bin/sh")) {
            found_bin = true;
            const prov_type = prov.getType();
            try std.testing.expectEqual(ProvisionType.bin, prov_type);
            break;
        }
    }
    try std.testing.expect(found_bin);

    // Non-executable files with shebangs should not produce script interpreter dependencies.
    const nonexec_shebang_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "usr", "lib", "test-nonexec.pm" });
    defer std.testing.allocator.free(nonexec_shebang_path);
    try p.ensureDirExists(std.fs.path.dirname(nonexec_shebang_path).?);
    {
        const nonexec_file = try std.Io.Dir.createFileAbsolute(p.currentIo(), nonexec_shebang_path, .{});
        defer nonexec_file.close(p.currentIo());
        try nonexec_file.writeStreamingAll(p.currentIo(), "#!./perl -w\npackage Test::NonExec;\n");
    }

    try pkg.scanDirectory(test_env.path);

    var found_relative_perl_dep = false;
    for (pkg.dependencies.items) |dep| {
        if (std.mem.eql(u8, dep.resource, "./perl")) {
            found_relative_perl_dep = true;
            break;
        }
    }
    try std.testing.expect(!found_relative_perl_dep);
}

test "scanDirectory sets diagnostic context for missing scan root" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var pkg = Package.init(&test_env.ctx);
    defer pkg.deinit();
    pkg.arch = try test_env.ctx.allocator.dupe(u8, "x86_64");

    const missing_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "missing-root" });
    defer std.testing.allocator.free(missing_dir);

    try std.testing.expectError(error.FileNotFound, pkg.scanDirectory(missing_dir));

    const diag = test_env.ctx.getDiagnosticContext();
    try std.testing.expect(diag.subject != null);
    try std.testing.expect(diag.details != null);
    try std.testing.expectEqualStrings(missing_dir, diag.subject.?);
    try std.testing.expect(std.mem.indexOf(u8, diag.details.?, "package scan root open failed") != null);
}

test "scanDirectory handles musl absolute symlink in package tree" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    // Create lib/ and place a test ELF as libc.so
    const lib_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "lib" });
    defer std.testing.allocator.free(lib_dir);
    try p.ensureDirExists(lib_dir);

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_lib = try p.resolveToAbsolutePath("test/testdata/libtest.so", &src_buf);
    const dest_lib = try std.fs.path.join(std.testing.allocator, &.{ lib_dir, "libc.so" });
    defer std.testing.allocator.free(dest_lib);
    try p.copyFile(src_lib, dest_lib);

    // Create an absolute symlink that points to /lib/libc.so (as found in some archives)
    const symlink_path = try std.fs.path.join(std.testing.allocator, &.{ lib_dir, "ld-musl-x86_64.so.1" });
    defer std.testing.allocator.free(symlink_path);
    {
        var lib_dir_handle = try p.openExistingDir(lib_dir);
        defer lib_dir_handle.close(p.currentIo());
        try lib_dir_handle.symLink(p.currentIo(), "/lib/libc.so", "ld-musl-x86_64.so.1", .{});
    }

    var pkg = Package.init(&ctx);
    defer pkg.deinit();
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    try pkg.scanDirectory(test_env.path);

    // Expect a provision for "/lib/ld-musl-x86_64.so.1"
    var found = false;
    for (pkg.provisions.items) |prov| {
        if (std.mem.eql(u8, prov.resource, "/lib/ld-musl-x86_64.so.1")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "scanDirectory treats shared-library symlink name as elf soname provide" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    var ctx = test_env.ctx;

    const lib_dir = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "lib" });
    defer std.testing.allocator.free(lib_dir);
    try p.ensureDirExists(lib_dir);

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_lib = try p.resolveToAbsolutePath("test/testdata/libtest.so", &src_buf);
    const dest_lib = try std.fs.path.join(std.testing.allocator, &.{ lib_dir, "libtest.so" });
    defer std.testing.allocator.free(dest_lib);
    try p.copyFile(src_lib, dest_lib);

    const symlink_path = try std.fs.path.join(std.testing.allocator, &.{ lib_dir, "libtest.so.1" });
    defer std.testing.allocator.free(symlink_path);
    {
        var lib_dir_handle = try p.openExistingDir(lib_dir);
        defer lib_dir_handle.close(p.currentIo());
        try lib_dir_handle.symLink(p.currentIo(), "libtest.so", "libtest.so.1", .{});
    }

    var pkg = Package.init(&ctx);
    defer pkg.deinit();
    pkg.arch = try ctx.allocator.dupe(u8, "x86_64");
    try pkg.scanDirectory(test_env.path);

    var found = false;
    for (pkg.provisions.items) |prov| {
        if (std.mem.eql(u8, prov.resource, "libtest.so.1")) {
            found = true;
            try std.testing.expectEqual(ProvisionType.elf_soname, prov.getType());
            break;
        }
    }
    try std.testing.expect(found);
}

test "DependencyType fromString accepts known tokens" {
    try std.testing.expectEqual(DependencyType.elf_needed, try DependencyType.fromString("elf-needed"));
    try std.testing.expectEqual(DependencyType.elf_interpreter, try DependencyType.fromString("elf-interpreter"));
    try std.testing.expectEqual(DependencyType.script_interpreter, try DependencyType.fromString("script-interpreter"));
    try std.testing.expectEqual(DependencyType.split_runtime, try DependencyType.fromString("split-runtime"));

    // Test that invalid strings still return the same error
    try std.testing.expectError(error.InvalidArgument, DependencyType.fromString("invalid-type"));
}

test "ProvisionType fromString accepts known tokens" {
    try std.testing.expectEqual(ProvisionType.elf_soname, try ProvisionType.fromString("elf-soname"));
    try std.testing.expectEqual(ProvisionType.bin, try ProvisionType.fromString("bin"));

    // Test that invalid strings still return the same error
    try std.testing.expectError(error.InvalidArgument, ProvisionType.fromString("invalid-type"));
}

test "Package error semantics remain consistent" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var ctx = test_env.ctx;
    var pkg = Package.init(&ctx);
    defer pkg.deinit();

    // Memory allocation failure should always produce OutOfMemory error
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_allocator.allocator();
    try std.testing.expectError(PackageError.OutOfMemory, Dependency.init(allocator, "test", .elf_needed));
}

test "scanDirectory requires package target arch" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    var pkg = Package.init(&test_env.ctx);
    defer pkg.deinit();

    try std.testing.expectError(error.InvalidInput, pkg.scanDirectory(test_env.path));
}

test "scanDirectory skips foreign-target ELF runtime metadata" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const foreign_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "libforeign.so" });
    defer std.testing.allocator.free(foreign_path);

    var file = try std.Io.Dir.createFileAbsolute(p.currentIo(), foreign_path, .{});
    defer file.close(p.currentIo());

    var header = [_]u8{0} ** 64;
    header[0] = 0x7f;
    header[1] = 'E';
    header[2] = 'L';
    header[3] = 'F';
    header[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    header[std.elf.EI_DATA] = std.elf.ELFDATA2MSB;
    header[std.elf.EI_VERSION] = 1;
    header[16] = 0;
    header[17] = @intCast(@intFromEnum(std.elf.ET.DYN));
    header[18] = 0;
    header[19] = @intCast(@intFromEnum(std.elf.EM.S390));
    try file.writeStreamingAll(p.currentIo(), &header);

    var pkg = Package.init(&test_env.ctx);
    defer pkg.deinit();
    pkg.arch = try test_env.ctx.allocator.dupe(u8, "x86_64");

    try pkg.scanDirectory(test_env.path);
    try std.testing.expectEqual(@as(usize, 0), pkg.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 0), pkg.provisions.items.len);
}

test "inferArch returns 'any' for directory with no ELF files" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "staging" });
    defer std.testing.allocator.free(staging);
    try p.ensureDirExists(staging);

    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ staging, "readme.txt" });
    defer std.testing.allocator.free(txt_path);
    {
        var f = try p.makePathAndOpenFile(txt_path);
        defer f.close(p.currentIo());
        try f.writeStreamingAll(p.currentIo(), "hello");
    }

    const arch = try inferArch(&test_env.ctx, staging);
    try std.testing.expectEqualStrings("any", arch);
}

test "inferArch returns 'any' for empty directory" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "empty" });
    defer std.testing.allocator.free(staging);
    try p.ensureDirExists(staging);

    const arch = try inferArch(&test_env.ctx, staging);
    try std.testing.expectEqualStrings("any", arch);
}

test "inferArch detects architecture from ELF binary" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const staging = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "staging" });
    defer std.testing.allocator.free(staging);
    const bin_dir = try std.fs.path.join(std.testing.allocator, &.{ staging, "usr/bin" });
    defer std.testing.allocator.free(bin_dir);
    try p.ensureDirExists(bin_dir);

    // Write a minimal ELF header (x86_64, ET_EXEC) into staging
    const dest = try std.fs.path.join(std.testing.allocator, &.{ bin_dir, "dummy" });
    defer std.testing.allocator.free(dest);
    {
        var f = try p.makePathAndOpenFile(dest);
        defer f.close(p.currentIo());
        // Minimal 20-byte ELF header: magic + class(64) + data(LSB) + version + padding + e_type(EXEC) + e_machine(X86_64)
        var hdr: [20]u8 = undefined;
        @memset(&hdr, 0);
        @memcpy(hdr[0..4], "\x7fELF");
        hdr[4] = std.elf.ELFCLASS64; // 64-bit
        hdr[5] = std.elf.ELFDATA2LSB; // little-endian
        hdr[6] = 1; // EV_CURRENT
        std.mem.writeInt(u16, hdr[16..18], @intFromEnum(std.elf.ET.EXEC), .little);
        std.mem.writeInt(u16, hdr[18..20], @intFromEnum(std.elf.EM.X86_64), .little);
        try f.writeStreamingAll(p.currentIo(), &hdr);
    }

    const arch = try inferArch(&test_env.ctx, staging);
    try std.testing.expectEqualStrings("x86_64", arch);
}
