const std = @import("std");
const Context = @import("mere.zig").Context;
const pkg = @import("package.zig");
const Dependency = pkg.Dependency;
const Provision = pkg.Provision;
const errors = @import("errors.zig");
const path_mod = @import("path.zig");
const native_endian = @import("builtin").target.cpu.arch.endian();

/// ELF operations error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during ELF operations
/// - FileSystem: File operations failed (reading ELF files, seeking, etc.)
/// - InvalidInput: Invalid ELF file or malformed input data
/// - CorruptData: ELF file structure is corrupted or invalid
///
/// ELF-Specific Errors:
/// - DynstrSectionNotFound: Dynamic string table section not found in ELF file
/// - SectionHeaderOverflow: Section or string-table offset exceeds file size
const Std = errors.StandardErrors;
pub const ElfError = Std.OutOfMemory || Std.FileSystem || Std.InvalidInput || Std.CorruptData || error{
    DynstrSectionNotFound,
    SectionHeaderOverflow,
};

pub const ElfScanResult = struct {
    deps: std.array_list.Managed(Dependency),
    provisions: std.array_list.Managed(Provision),
};

pub const ElfClass = enum {
    elf32,
    elf64,
};

pub const ElfHeaderInfo = struct {
    class: ElfClass,
    endian: std.builtin.Endian,
    elf_type: u16,
    machine: u16,
};

pub const RuntimeMetadataScanDisposition = enum {
    scan,
    skip_non_runtime_type,
    skip_foreign_target,
    skip_unknown_target,
    skip_unsupported_layout,
};

const TargetElfInfo = struct {
    class: ElfClass,
    endian: std.builtin.Endian,
    machine: u16,
};

pub fn readElfHeaderInfo(file_path: []const u8) !ElfHeaderInfo {
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(file_path) catch return error.FileSystem;
    defer file.close(io);

    var header_bytes: [20]u8 = undefined;
    const bytes_read = file.readPositionalAll(io, &header_bytes, 0) catch return error.FileSystem;
    if (bytes_read < header_bytes.len) return error.InvalidInput;
    if (!std.mem.eql(u8, header_bytes[0..4], "\x7fELF")) return error.InvalidInput;

    const elf_class = switch (header_bytes[std.elf.EI_CLASS]) {
        std.elf.ELFCLASS32 => ElfClass.elf32,
        std.elf.ELFCLASS64 => ElfClass.elf64,
        else => return error.InvalidInput,
    };
    const endian: std.builtin.Endian = switch (header_bytes[std.elf.EI_DATA]) {
        std.elf.ELFDATA2LSB => .little,
        std.elf.ELFDATA2MSB => .big,
        else => return error.InvalidInput,
    };
    const e_type_bytes: [2]u8 = .{ header_bytes[16], header_bytes[17] };
    const e_machine_bytes: [2]u8 = .{ header_bytes[18], header_bytes[19] };

    return .{
        .class = elf_class,
        .endian = endian,
        .elf_type = std.mem.readInt(u16, &e_type_bytes, endian),
        .machine = std.mem.readInt(u16, &e_machine_bytes, endian),
    };
}

pub fn runtimeMetadataScanDisposition(target_arch: []const u8, header: ElfHeaderInfo) RuntimeMetadataScanDisposition {
    const et_exec = @intFromEnum(std.elf.ET.EXEC);
    const et_dyn = @intFromEnum(std.elf.ET.DYN);
    if (header.elf_type != et_exec and header.elf_type != et_dyn) return .skip_non_runtime_type;

    const target = targetElfInfoForArch(target_arch) orelse return .skip_unknown_target;
    if (header.class != target.class or header.endian != target.endian or header.machine != target.machine) {
        return .skip_foreign_target;
    }

    if (header.class != .elf64 or header.endian != native_endian) return .skip_unsupported_layout;
    return .scan;
}

fn targetElfInfoForArch(arch: []const u8) ?TargetElfInfo {
    if (std.mem.eql(u8, arch, "any")) return null;
    if (std.mem.eql(u8, arch, "x86_64")) {
        return .{
            .class = .elf64,
            .endian = .little,
            .machine = @intFromEnum(std.elf.EM.X86_64),
        };
    }
    if (std.mem.eql(u8, arch, "aarch64")) {
        return .{
            .class = .elf64,
            .endian = .little,
            .machine = @intFromEnum(std.elf.EM.AARCH64),
        };
    }
    return null;
}

/// Read ELF object type (`e_type`) from file header.
/// Returns null for non-ELF files, unsupported endianness, or unreadable inputs.
pub fn readElfType(file_path: []const u8) ?std.elf.ET {
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(file_path) catch return null;
    defer file.close(io);

    var ident: [16]u8 = undefined;
    const ident_read = file.readPositionalAll(io, &ident, 0) catch return null;
    if (ident_read < 16) return null;
    if (!std.mem.eql(u8, ident[0..4], "\x7fELF")) return null;

    const ei_data = ident[std.elf.EI_DATA];
    const endian: std.builtin.Endian = switch (ei_data) {
        std.elf.ELFDATA2LSB => .little,
        std.elf.ELFDATA2MSB => .big,
        else => return null,
    };

    var e_type_bytes: [2]u8 = undefined;
    const e_type_read = file.readPositionalAll(io, &e_type_bytes, 16) catch return null;
    if (e_type_read < 2) return null;
    return @enumFromInt(std.mem.readInt(u16, &e_type_bytes, endian));
}

/// Scan an ELF file for dependencies, SONAME provisions, and interpreter metadata.
pub fn scanElfMetadata(ctx: *Context, path: []const u8) !ElfScanResult {
    const allocator = ctx.allocator;
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(path) catch |err| {
        return ctx.fail(err, path, "failed to open ELF file");
    };
    defer file.close(io);

    const file_size = (file.stat(io) catch |err| {
        return ctx.fail(err, path, "failed to read ELF file size");
    }).size;
    if (file_size < @sizeOf(std.elf.Elf64_Ehdr)) {
        ctx.debug("file too small to be a valid elf file: {d} bytes", .{file_size});
        return ctx.fail(ElfError.InvalidInput, path, "file too small to be a valid ELF");
    }

    var elf_header: std.elf.Elf64_Ehdr = undefined;
    _ = file.readPositionalAll(io, std.mem.asBytes(&elf_header), 0) catch |err| {
        return ctx.fail(err, path, "failed to read ELF header");
    };

    if (!std.mem.eql(u8, elf_header.e_ident[0..4], "\x7fELF")) {
        ctx.debug("not a valid elf file (invalid magic number)", .{});
        return ctx.fail(ElfError.InvalidInput, path, "invalid ELF magic");
    }

    const shoff = elf_header.e_shoff;
    const shentsize = elf_header.e_shentsize;
    const shnum = elf_header.e_shnum;
    const shstrndx = elf_header.e_shstrndx;

    var dynamic_section_offset: u64 = 0;
    var dynamic_section_size: u64 = 0;
    var dynstr_section_offset: u64 = 0;
    var dynstr_section_size: u64 = 0;

    if (shnum > 0 and shentsize > 0 and shstrndx < shnum) {
        const shstr_offset = std.math.mul(u64, shstrndx, shentsize) catch return .{
            .deps = std.array_list.Managed(Dependency).init(ctx.allocator),
            .provisions = std.array_list.Managed(Provision).init(ctx.allocator),
        };
        const final_shstr_offset = std.math.add(u64, shoff, shstr_offset) catch return .{
            .deps = std.array_list.Managed(Dependency).init(ctx.allocator),
            .provisions = std.array_list.Managed(Provision).init(ctx.allocator),
        };

        if (final_shstr_offset + @sizeOf(std.elf.Elf64_Shdr) > file_size) {
            ctx.debug("string table header offset exceeds file size", .{});
            return ctx.fail(ElfError.SectionHeaderOverflow, path, "section header offset exceeds file size");
        }

        var shstr_header: std.elf.Elf64_Shdr = undefined;
        _ = try file.readPositionalAll(io, std.mem.asBytes(&shstr_header), final_shstr_offset);

        var i: usize = 0;
        while (i < shnum) : (i += 1) {
            const section_offset = std.math.mul(u64, i, shentsize) catch break;
            const total_offset = std.math.add(u64, shoff, section_offset) catch break;

            if (total_offset + @sizeOf(std.elf.Elf64_Shdr) > file_size) break;

            var section_header: std.elf.Elf64_Shdr = undefined;
            _ = try file.readPositionalAll(io, std.mem.asBytes(&section_header), total_offset);

            const section_name = readSectionName(allocator, &file, file_size, shstr_header.sh_offset, section_header.sh_name) catch |err| switch (err) {
                ElfError.SectionHeaderOverflow, ElfError.CorruptData => continue,
                else => return ctx.fail(err, path, "failed to read section name"),
            };
            defer allocator.free(section_name);
            if (std.mem.eql(u8, section_name, ".dynamic")) {
                ctx.debug(".dynamic section at offset {d} size {d}", .{ section_header.sh_offset, section_header.sh_size });
                dynamic_section_offset = section_header.sh_offset;
                dynamic_section_size = section_header.sh_size;
            } else if (std.mem.eql(u8, section_name, ".dynstr")) {
                ctx.debug(".dynstr section at offset {d} size {d}", .{ section_header.sh_offset, section_header.sh_size });
                dynstr_section_offset = section_header.sh_offset;
                dynstr_section_size = section_header.sh_size;
            }
        }
    }

    if (dynamic_section_offset == 0) {
        ctx.debug("no dynamic section found in elf file", .{});
        return .{
            .deps = std.array_list.Managed(Dependency).init(ctx.allocator),
            .provisions = std.array_list.Managed(Provision).init(ctx.allocator),
        };
    }

    if (dynstr_section_offset == 0) {
        return ctx.fail(ElfError.DynstrSectionNotFound, path, "missing .dynstr section");
    }

    const dynamic_section = loadElfStringTable(&file, allocator, dynamic_section_offset, dynamic_section_size, file_size) catch |err| {
        return ctx.fail(err, path, "failed to read .dynamic section");
    };
    defer allocator.free(dynamic_section);

    const dynstr = loadElfStringTable(&file, allocator, dynstr_section_offset, dynstr_section_size, file_size) catch |err| {
        return ctx.fail(err, path, "failed to read .dynstr section");
    };
    defer allocator.free(dynstr);

    var deps = std.array_list.Managed(Dependency).init(ctx.allocator);
    errdefer {
        for (deps.items) |item| {
            var owned = item;
            owned.deinit(allocator);
        }
        deps.deinit();
    }

    var provisions = std.array_list.Managed(Provision).init(ctx.allocator);
    errdefer {
        for (provisions.items) |item| {
            var owned = item;
            owned.deinit(allocator);
        }
        provisions.deinit();
    }

    var saw_soname = false;
    var entry_offset: usize = 0;
    while (entry_offset + @sizeOf(std.elf.Elf64_Dyn) <= dynamic_section.len) : (entry_offset += @sizeOf(std.elf.Elf64_Dyn)) {
        // Read fields by offset rather than pointer-casting: dynamic_section is a
        // byte buffer from allocator.alloc (1-byte aligned), so @alignCast to
        // *Elf64_Dyn panics in safe builds when the buffer base isn't 8-byte
        // aligned. The .dynamic entry is { d_tag: i64, d_val/d_ptr: u64 }.
        // Endianness matches native_endian (guaranteed by the scan's earlier guard).
        const d_tag = std.mem.readInt(i64, dynamic_section[entry_offset..][0..8], native_endian);
        const d_val = std.mem.readInt(u64, dynamic_section[entry_offset + 8 ..][0..8], native_endian);
        if (d_tag == std.elf.DT_NEEDED or d_tag == std.elf.DT_SONAME) {
            const str_offset = @as(usize, @intCast(d_val));
            if (str_offset >= dynstr.len) continue;

            var end = str_offset;
            while (end < dynstr.len and dynstr[end] != 0) : (end += 1) {}
            if (end > str_offset) {
                const str = dynstr[str_offset..end];
                const resource = try allocator.dupe(u8, str);
                if (d_tag == std.elf.DT_NEEDED) {
                    ctx.debug("dependency: {s} (type: {s})", .{ resource, pkg.DependencyType.elf_needed.toString() });
                    errdefer allocator.free(resource);
                    try deps.append(.{ .resource = resource, .dep_type = .elf_needed });
                } else {
                    saw_soname = true;
                    ctx.debug("soname: {s} (type: {s})", .{ resource, pkg.ProvisionType.elf_soname.toString() });
                    errdefer allocator.free(resource);
                    try provisions.append(.{ .resource = resource, .prov_type = .elf_soname });
                }
            }
        }
    }

    ctx.debug("{d} dependencies and {d} sonames before processing interpreter", .{ deps.items.len, provisions.items.len });

    // Special case: if this is libc.so, ensure it provides libc.so
    // This handles musl libc which doesn't have a DT_SONAME entry
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, "libc.so")) {
        ctx.debug("creating libc.so provision for musl libc", .{});
        const resource = try ctx.allocator.dupe(u8, "libc.so");
        errdefer ctx.allocator.free(resource);
        try provisions.append(.{ .resource = resource, .prov_type = .elf_soname });
    }

    // Fallback for shared objects without DT_SONAME (e.g. libperl.so):
    // provide the library filename so DT_NEEDED entries can resolve.
    if (!saw_soname and isSharedObjectBasename(basename)) {
        ctx.debug("no soname found, using basename fallback provision: {s}", .{basename});
        const resource = try ctx.allocator.dupe(u8, basename);
        errdefer ctx.allocator.free(resource);
        try provisions.append(.{ .resource = resource, .prov_type = .elf_soname });
    }

    var elf_header_for_phdr: std.elf.Elf64_Ehdr = undefined;
    _ = file.readPositionalAll(io, std.mem.asBytes(&elf_header_for_phdr), 0) catch |err| {
        return ctx.fail(err, path, "failed to read ELF header for program headers");
    };

    const phoff = elf_header_for_phdr.e_phoff;
    const phentsize = elf_header_for_phdr.e_phentsize;
    const phnum = elf_header_for_phdr.e_phnum;

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph_offset = std.math.mul(u64, i, phentsize) catch continue;
        const total_ph_offset = std.math.add(u64, phoff, ph_offset) catch continue;

        if (total_ph_offset + @sizeOf(std.elf.Elf64_Phdr) > file_size) continue;

        var phdr: std.elf.Elf64_Phdr = undefined;
        _ = try file.readPositionalAll(io, std.mem.asBytes(&phdr), total_ph_offset);

        if (phdr.p_type == std.elf.PT_INTERP) {
            ctx.debug("pt_interp section at offset {d} size {d}", .{ phdr.p_offset, phdr.p_filesz });

            if (phdr.p_filesz > 0 and phdr.p_filesz < 256) { // Reasonable size limit
                var interp_buf: [256]u8 = undefined;
                const bytes_read = file.readPositionalAll(io, interp_buf[0..@intCast(phdr.p_filesz)], phdr.p_offset) catch |err| {
                    return ctx.fail(err, path, "failed to read ELF interpreter");
                };

                var end: usize = 0;
                while (end < bytes_read and interp_buf[end] != 0) : (end += 1) {}

                if (end > 0) {
                    const resource = try allocator.dupe(u8, interp_buf[0..end]);
                    ctx.debug("interpreter: {s} (type: {s})", .{ resource, pkg.DependencyType.elf_interpreter.toString() });
                    errdefer allocator.free(resource);
                    try deps.append(.{ .resource = resource, .dep_type = .elf_interpreter });
                }
            }
            break;
        }
    }

    return .{ .deps = deps, .provisions = provisions };
}

fn isSharedObjectBasename(name: []const u8) bool {
    // Accept lib*.so and lib*.so.<version...>
    if (!std.mem.startsWith(u8, name, "lib")) return false;
    if (std.mem.endsWith(u8, name, ".so")) return true;
    return std.mem.indexOf(u8, name, ".so.") != null;
}

fn readSectionName(
    allocator: std.mem.Allocator,
    file: *const std.Io.File,
    file_size: u64,
    shstr_offset: u64,
    name_offset: u32,
) ![]u8 {
    if (shstr_offset >= file_size or name_offset >= file_size) {
        return ElfError.SectionHeaderOverflow;
    }

    const total_offset = std.math.add(u64, shstr_offset, name_offset) catch return ElfError.CorruptData;
    if (total_offset >= file_size) {
        return ElfError.SectionHeaderOverflow;
    }

    var name_buf: [256]u8 = undefined;
    const bytes_read = try file.readPositionalAll(path_mod.currentIo(), &name_buf, total_offset);
    if (bytes_read == 0) return ElfError.FileSystem;

    var end: usize = 0;
    while (end < bytes_read and name_buf[end] != 0) : (end += 1) {}

    if (end == bytes_read) return ElfError.CorruptData;

    return allocator.dupe(u8, name_buf[0..end]);
}

/// Load an ELF string table safely from file
fn loadElfStringTable(file: *const std.Io.File, allocator: std.mem.Allocator, offset: u64, size: u64, file_size: u64) ![]u8 {
    if (offset > file_size) {
        return ElfError.SectionHeaderOverflow;
    }
    const remaining = file_size - offset;
    if (size > remaining) {
        return ElfError.SectionHeaderOverflow;
    }
    const buf = try allocator.alloc(u8, @intCast(size));
    const read_size = @min(size, file_size - offset);
    if (read_size < size) @memset(buf, 0);
    _ = try file.readPositionalAll(path_mod.currentIo(), buf[0..@intCast(read_size)], offset);
    return buf;
}

/// Read the ELF e_machine field from a file at a given byte offset.
/// Returns null if the data at that offset is not a valid ELF header.
pub fn readElfMachineAt(file: *const std.Io.File, offset: u64) ?u16 {
    const io = path_mod.currentIo();
    var header_bytes: [20]u8 = undefined;
    const n = file.readPositionalAll(io, &header_bytes, offset) catch return null;
    if (n < 20) return null;
    if (!std.mem.eql(u8, header_bytes[0..4], "\x7fELF")) return null;

    const endian: std.builtin.Endian = switch (header_bytes[std.elf.EI_DATA]) {
        std.elf.ELFDATA2LSB => .little,
        std.elf.ELFDATA2MSB => .big,
        else => return null,
    };
    const e_machine_bytes: [2]u8 = .{ header_bytes[18], header_bytes[19] };
    return std.mem.readInt(u16, &e_machine_bytes, endian);
}

/// Read the e_machine from the first ELF object inside an ar archive.
/// Returns null if the file is not an ar archive or contains no ELF members.
pub fn readElfMachineFromArArchive(file_path: []const u8) ?u16 {
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(file_path) catch return null;
    defer file.close(io);

    // ar global magic: "!<arch>\n" (8 bytes)
    var magic: [8]u8 = undefined;
    const magic_n = file.readPositionalAll(io, &magic, 0) catch return null;
    if (magic_n < 8 or !std.mem.eql(u8, &magic, "!<arch>\n")) return null;

    // Walk ar members looking for the first ELF object.
    // Each member header is 60 bytes: name[16] mtime[12] uid[6] gid[6] mode[8] size[10] fmag[2]
    var pos: u64 = 8;
    while (true) {
        var hdr: [60]u8 = undefined;
        const hdr_n = file.readPositionalAll(io, &hdr, pos) catch return null;
        if (hdr_n < 60) return null;
        // Validate fmag
        if (!std.mem.eql(u8, hdr[58..60], "`\n")) return null;

        // Parse size (bytes 48..58, ASCII decimal, space-padded)
        const size = parseArSize(hdr[48..58]) orelse return null;
        const data_offset = pos + 60;

        // Check if this member starts with ELF magic
        if (readElfMachineAt(&file, data_offset)) |machine| return machine;

        // Advance to next member (sizes are 2-byte aligned)
        pos = data_offset + size;
        if (size % 2 != 0) pos += 1;
    }
}

fn parseArSize(raw: *const [10]u8) ?u64 {
    // Trim trailing spaces
    var len: usize = 10;
    while (len > 0 and raw[len - 1] == ' ') len -= 1;
    if (len == 0) return null;
    return std.fmt.parseInt(u64, raw[0..len], 10) catch return null;
}

/// Map an ELF e_machine value to a Mere architecture string.
/// Returns null for unrecognized machine types.
pub fn archFromMachine(machine: u16) ?[]const u8 {
    return switch (@as(std.elf.EM, @enumFromInt(machine))) {
        .X86_64 => "x86_64",
        .AARCH64 => "aarch64",
        else => null,
    };
}

/// Deduplicate and sort a string slice
pub fn dedupAndSort(arena: std.mem.Allocator, items: []const []const u8) ![][]const u8 {
    if (items.len == 0) return &.{};

    // Track unique items
    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();

    for (items) |item| {
        try seen.put(item, {});
    }

    // Allocate array for unique items
    const unique = try arena.alloc([]const u8, seen.count());

    var i: usize = 0;
    var it = seen.keyIterator();
    while (it.next()) |key| {
        unique[i] = try arena.dupe(u8, key.*);
        i += 1;
    }

    // Sort the array
    std.mem.sort([]const u8, unique, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return unique;
}

// Test the dedupAndSort function with various input cases
test "dedupAndSort function" {
    // Empty array
    {
        const empty_array = [_][]const u8{};
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try dedupAndSort(arena.allocator(), &empty_array);
        try std.testing.expectEqual(@as(usize, 0), result.len);
    }
    // Single element
    {
        const single_element = [_][]const u8{"libz.so.1"};
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try dedupAndSort(arena.allocator(), &single_element);
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqualStrings("libz.so.1", result[0]);
    }
    // Multiple elements with duplicates
    {
        const multiple_elements = [_][]const u8{ "libz.so.1", "libc.so.6", "libz.so.1" };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try dedupAndSort(arena.allocator(), &multiple_elements);
        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqualStrings("libc.so.6", result[0]);
        try std.testing.expectEqualStrings("libz.so.1", result[1]);
    }
    // All unique elements
    {
        const all_unique = [_][]const u8{ "libc.so.6", "libz.so.1", "libm.so.6" };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try dedupAndSort(arena.allocator(), &all_unique);
        try std.testing.expectEqual(@as(usize, 3), result.len);
        try std.testing.expectEqualStrings("libc.so.6", result[0]);
        try std.testing.expectEqualStrings("libm.so.6", result[1]);
        try std.testing.expectEqualStrings("libz.so.1", result[2]);
    }
    // All duplicates
    {
        const all_duplicates = [_][]const u8{ "libz.so.1", "libz.so.1", "libz.so.1" };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try dedupAndSort(arena.allocator(), &all_duplicates);
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqualStrings("libz.so.1", result[0]);
    }
    // Mixed empty and non-empty strings
    {
        const mixed_empty = [_][]const u8{ "libc.so.6", "", "libz.so.1", "" };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try dedupAndSort(arena.allocator(), &mixed_empty);
        try std.testing.expectEqual(@as(usize, 3), result.len);
        try std.testing.expectEqualStrings("", result[0]);
        try std.testing.expectEqualStrings("libc.so.6", result[1]);
        try std.testing.expectEqualStrings("libz.so.1", result[2]);
    }
}

test "scanElfMetadata returns ElfError.FileTooSmall for tiny file" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a tiny file in the test environment
    const tiny_file = try test_env.tmp.dir.createFile(path_mod.currentIo(), "tiny", .{});
    defer tiny_file.close(path_mod.currentIo());
    try tiny_file.writeStreamingAll(path_mod.currentIo(), &[_]u8{ 0x7f, 0x45 }); // Not enough for ELF header

    const real_path = try test_env.tmp.dir.realPathFileAlloc(path_mod.currentIo(), "tiny", std.testing.allocator);
    defer std.testing.allocator.free(real_path);
    const result = scanElfMetadata(&test_env.ctx, real_path);
    try std.testing.expectError(ElfError.InvalidInput, result);
}

test "readElfType handles little-endian ELF headers" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const elf_file = try test_env.tmp.dir.createFile(path_mod.currentIo(), "tiny-le.elf", .{});
    defer elf_file.close(path_mod.currentIo());

    var header: [18]u8 = [_]u8{0} ** 18;
    header[0] = 0x7f;
    header[1] = 'E';
    header[2] = 'L';
    header[3] = 'F';
    header[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    header[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    header[16] = 0x02; // ET_EXEC, little-endian
    header[17] = 0x00;
    try elf_file.writeStreamingAll(path_mod.currentIo(), &header);

    const real_path = try test_env.tmp.dir.realPathFileAlloc(path_mod.currentIo(), "tiny-le.elf", std.testing.allocator);
    defer std.testing.allocator.free(real_path);

    try std.testing.expectEqual(std.elf.ET.EXEC, readElfType(real_path).?);
}

test "readElfType handles big-endian ELF headers" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const elf_file = try test_env.tmp.dir.createFile(path_mod.currentIo(), "tiny-be.elf", .{});
    defer elf_file.close(path_mod.currentIo());

    var header: [18]u8 = [_]u8{0} ** 18;
    header[0] = 0x7f;
    header[1] = 'E';
    header[2] = 'L';
    header[3] = 'F';
    header[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    header[std.elf.EI_DATA] = std.elf.ELFDATA2MSB;
    header[16] = 0x00;
    header[17] = 0x03; // ET_DYN, big-endian
    try elf_file.writeStreamingAll(path_mod.currentIo(), &header);

    const real_path = try test_env.tmp.dir.realPathFileAlloc(path_mod.currentIo(), "tiny-be.elf", std.testing.allocator);
    defer std.testing.allocator.free(real_path);

    try std.testing.expectEqual(std.elf.ET.DYN, readElfType(real_path).?);
}

test "scanElfMetadata returns ElfError.InvalidMagic for non-ELF file" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    // Create a file with enough size but invalid magic in the test environment
    const bad_file = try test_env.tmp.dir.createFile(path_mod.currentIo(), "bad", .{});
    defer bad_file.close(path_mod.currentIo());
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    try bad_file.writeStreamingAll(path_mod.currentIo(), &buf);

    const real_path = try test_env.tmp.dir.realPathFileAlloc(path_mod.currentIo(), "bad", std.testing.allocator);
    defer std.testing.allocator.free(real_path);
    const result = scanElfMetadata(&test_env.ctx, real_path);
    try std.testing.expectError(ElfError.InvalidInput, result);
}

test "scanElfMetadata with actual dependencies and sonames" {
    const test_helpers = @import("test_helpers.zig");
    var test_env = try test_helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    // Test case 1: Library with multiple dependencies (libtest.so)
    {
        const libtest_path = test_helpers.elfFixture("libtest.so");
        var result = try scanElfMetadata(&test_env.ctx, libtest_path);
        defer {
            for (result.deps.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.deps.deinit();

            for (result.provisions.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.provisions.deinit();
        }

        // Check dependencies - libtest.so depends on libz.so.1, libssl.so.3, and libc.so
        try std.testing.expectEqual(@as(usize, 3), result.deps.items.len);

        // Check that all dependencies have the correct type
        for (result.deps.items) |dep| {
            try std.testing.expectEqual(pkg.DependencyType.elf_needed, dep.dep_type);
            try std.testing.expect(std.mem.eql(u8, dep.resource, "libc.so") or
                std.mem.eql(u8, dep.resource, "libssl.so.3") or
                std.mem.eql(u8, dep.resource, "libz.so.1"));
        }

        // libtest.so doesn't have a SONAME, so basename fallback is used
        try std.testing.expectEqual(@as(usize, 1), result.provisions.items.len);
        try std.testing.expectEqualStrings("libtest.so", result.provisions.items[0].resource);
        try std.testing.expectEqual(pkg.ProvisionType.elf_soname, result.provisions.items[0].prov_type);
    }

    // Test case 2: Library with a SONAME (libsoname.so)
    {
        const libsoname_path = test_helpers.elfFixture("libsoname.so");
        var result = try scanElfMetadata(&test_env.ctx, libsoname_path);
        defer {
            for (result.deps.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.deps.deinit();

            for (result.provisions.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.provisions.deinit();
        }

        // Check dependencies - libsoname.so depends only on libc.so
        try std.testing.expectEqual(@as(usize, 1), result.deps.items.len);
        try std.testing.expectEqualStrings("libc.so", result.deps.items[0].resource);
        try std.testing.expectEqual(pkg.DependencyType.elf_needed, result.deps.items[0].dep_type);

        // Check SONAME - libsoname.so has SONAME "libcustom.so.1"
        try std.testing.expectEqual(@as(usize, 1), result.provisions.items.len);
        try std.testing.expectEqualStrings("libcustom.so.1", result.provisions.items[0].resource);
        try std.testing.expectEqual(pkg.ProvisionType.elf_soname, result.provisions.items[0].prov_type);
    }

    // Test case 3: Library with minimal dependencies (libempty.so)
    {
        const libempty_path = test_helpers.elfFixture("libempty.so");
        var result = try scanElfMetadata(&test_env.ctx, libempty_path);
        defer {
            for (result.deps.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.deps.deinit();

            for (result.provisions.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.provisions.deinit();
        }

        // Check dependencies - libempty.so depends only on libc.so
        try std.testing.expectEqual(@as(usize, 1), result.deps.items.len);
        try std.testing.expectEqualStrings("libc.so", result.deps.items[0].resource);
        try std.testing.expectEqual(pkg.DependencyType.elf_needed, result.deps.items[0].dep_type);

        // libempty.so doesn't have a SONAME, so basename fallback is used
        try std.testing.expectEqual(@as(usize, 1), result.provisions.items.len);
        try std.testing.expectEqualStrings("libempty.so", result.provisions.items[0].resource);
        try std.testing.expectEqual(pkg.ProvisionType.elf_soname, result.provisions.items[0].prov_type);
    }

    // Test case 4: Binary with interpreter (dummy)
    {
        const dummy_path = test_helpers.elfFixture("dummy");
        var result = try scanElfMetadata(&test_env.ctx, dummy_path);
        defer {
            for (result.deps.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.deps.deinit();

            for (result.provisions.items) |item| {
                var owned = item;
                owned.deinit(test_env.ctx.allocator);
            }
            result.provisions.deinit();
        }

        // Check dependencies - dummy depends on libc.so and has an interpreter
        try std.testing.expectEqual(@as(usize, 2), result.deps.items.len);

        // Find the regular dependency and interpreter
        var found_libc = false;
        var found_interpreter = false;

        for (result.deps.items) |dep| {
            if (std.mem.eql(u8, dep.resource, "libc.so")) {
                found_libc = true;
                try std.testing.expectEqual(pkg.DependencyType.elf_needed, dep.dep_type);
            } else if (std.mem.eql(u8, dep.resource, test_helpers.fixture_interpreter)) {
                found_interpreter = true;
                try std.testing.expectEqual(pkg.DependencyType.elf_interpreter, dep.dep_type);
            }
        }

        try std.testing.expect(found_libc);
        try std.testing.expect(found_interpreter);
    }
}

test "readElfMachineAt returns machine for valid ELF" {
    const test_helpers = @import("test_helpers.zig");
    const io = path_mod.currentIo();
    var file = path_mod.openExistingFile(test_helpers.elfFixture("dummy")) catch return;
    defer file.close(io);
    const machine = readElfMachineAt(&file, 0);
    try std.testing.expect(machine != null);
    const expected_machine = if (@import("builtin").cpu.arch == .aarch64)
        std.elf.EM.AARCH64
    else
        std.elf.EM.X86_64;
    try std.testing.expectEqual(@intFromEnum(expected_machine), machine.?);
}

test "readElfMachineAt returns null for non-ELF offset" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();
    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "plain.txt" });
    defer std.testing.allocator.free(txt_path);
    {
        var f = try path_mod.makePathAndOpenFile(txt_path);
        defer f.close(io);
        try f.writeStreamingAll(io, "not an elf file");
    }
    var f = path_mod.openExistingFile(txt_path) catch return;
    defer f.close(io);
    try std.testing.expect(readElfMachineAt(&f, 0) == null);
}

test "archFromMachine maps known architectures" {
    try std.testing.expectEqualStrings("x86_64", archFromMachine(@intFromEnum(std.elf.EM.X86_64)).?);
    try std.testing.expectEqualStrings("aarch64", archFromMachine(@intFromEnum(std.elf.EM.AARCH64)).?);
    try std.testing.expect(archFromMachine(0) == null);
    try std.testing.expect(archFromMachine(999) == null);
}

test "readElfMachineFromArArchive returns null for non-ar file" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const io = path_mod.currentIo();
    const txt_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, "fake.a" });
    defer std.testing.allocator.free(txt_path);
    {
        var f = try path_mod.makePathAndOpenFile(txt_path);
        defer f.close(io);
        try f.writeStreamingAll(io, "not an archive");
    }
    try std.testing.expect(readElfMachineFromArArchive(txt_path) == null);
}

test "readElfMachineFromArArchive returns null for nonexistent file" {
    try std.testing.expect(readElfMachineFromArArchive("/nonexistent/path/to/file.a") == null);
}

test "parseArSize parses valid sizes" {
    const s1: [10]u8 = "1234      ".*;
    try std.testing.expectEqual(@as(u64, 1234), parseArSize(&s1).?);
    const s2: [10]u8 = "0         ".*;
    try std.testing.expectEqual(@as(u64, 0), parseArSize(&s2).?);
    const s3: [10]u8 = "          ".*;
    try std.testing.expect(parseArSize(&s3) == null);
}
