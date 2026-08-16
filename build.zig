const std = @import("std");

const VendorDep = enum {
    zlib,
    mbedtls,
    libsodium,
    zstd,
    lzma,
    bzip2,
    libarchive,
    curl,
    sqlite,
    ckdl,

    /// Name of the corresponding entry in build.zig.zon's .dependencies.
    /// mbedtls and libsodium have no entry: see bootstrapMbedTls and
    /// bootstrapLibsodium for why.
    fn zonName(self: VendorDep) []const u8 {
        return switch (self) {
            .zlib => "zlib_ng",
            .mbedtls => unreachable,
            .libsodium => unreachable,
            .zstd => "zstd",
            .lzma => "xz",
            .bzip2 => "bzip2",
            .libarchive => "libarchive",
            .curl => "curl",
            .sqlite => "sqlite",
            .ckdl => "ckdl",
        };
    }
};

/// Source tree for a vendored C dependency, fetched and verified by Zig's
/// package manager (see build.zig.zon) rather than a hand-rolled
/// curl+sha256sum shell script. This participates in Zig's global package
/// cache and `--fetch` offline-build support.
fn vendorSourceDir(b: *std.Build, dep: VendorDep) std.Build.LazyPath {
    return b.dependency(dep.zonName(), .{}).path("");
}

const BootstrappedPrefix = struct {
    prefix: std.Build.LazyPath,
    include_dir: std.Build.LazyPath,

    fn staticLib(self: BootstrappedPrefix, b: *std.Build, name: []const u8) std.Build.LazyPath {
        return self.prefix.path(b, b.fmt("lib/lib{s}.a", .{name}));
    }
};

const SourceTree = struct {
    root: std.Build.LazyPath,

    fn path(self: SourceTree, b: *std.Build, subpath: []const u8) std.Build.LazyPath {
        return self.root.path(b, subpath);
    }
};

const CrossToolchain = struct {
    triple: []const u8,
    cc: []const u8,
    ar: []const u8,
    ranlib: []const u8,
    cmake_setup_step: *std.Build.Step,
    cmake_wrapper_dir: std.Build.LazyPath,
    cmake_system_name: []const u8,
    cmake_system_processor: []const u8,
};

fn detectCrossToolchain(b: *std.Build, target: std.Build.ResolvedTarget) ?CrossToolchain {
    const target_query = target.query;
    const host = @import("builtin");

    const target_arch = target_query.cpu_arch orelse host.cpu.arch;
    const target_os: std.Target.Os.Tag = target_query.os_tag orelse host.os.tag;
    const target_abi: std.Target.Abi = target_query.abi orelse host.abi;

    const is_cross = target_arch != host.cpu.arch or
        target_os != host.os.tag or
        target_abi != host.abi;

    if (!is_cross) return null;

    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");

    // Cmake needs CMAKE_C_COMPILER to be a single executable path, so we
    // create wrapper scripts. Autotools/make are fine with spaces in CC.
    const setup = b.addSystemCommand(&.{
        "sh",             "-ceu",
        b.fmt(
            \\dir="$1"
            \\mkdir -p "$dir"
            \\printf '%s\n' '#!/bin/sh' 'exec zig cc --target={0s} "$@"' > "$dir/zig-cc"
            \\printf '%s\n' '#!/bin/sh' 'exec zig c++ --target={0s} "$@"' > "$dir/zig-c++"
            \\printf '%s\n' '#!/bin/sh' 'exec zig ar "$@"' > "$dir/zig-ar"
            \\printf '%s\n' '#!/bin/sh' 'exec zig ranlib "$@"' > "$dir/zig-ranlib"
            \\chmod +x "$dir"/zig-*
        , .{triple}),
        "cross-wrappers",
    });
    const wrapper_dir = setup.addOutputDirectoryArg("cross-wrappers");

    return .{
        .triple = triple,
        .cc = b.fmt("zig cc --target={s}", .{triple}),
        .ar = "zig ar",
        .ranlib = "zig ranlib",
        .cmake_setup_step = &setup.step,
        .cmake_wrapper_dir = wrapper_dir,
        .cmake_system_name = switch (target_os) {
            .linux => "Linux",
            else => "Generic",
        },
        .cmake_system_processor = @tagName(target_arch),
    };
}

const CMakeBootstrap = struct {
    step_name: []const u8,
    output_dirname: []const u8,
    dep: VendorDep,
    cmake_source_subdir: ?[]const u8 = null,
    cmake_flags: []const []const u8,
    cross: ?CrossToolchain = null,
};

const AutotoolsBootstrap = struct {
    step_name: []const u8,
    output_dirname: []const u8,
    dep: VendorDep,
    configure_args: []const []const u8,
    cross: ?CrossToolchain = null,
};

const VendoredDeps = struct {
    zlib: BootstrappedPrefix,
    mbedtls: BootstrappedPrefix,
    libsodium: BootstrappedPrefix,
    zstd: BootstrappedPrefix,
    lzma: BootstrappedPrefix,
    bzip2: BootstrappedPrefix,
    libarchive: BootstrappedPrefix,
    curl: BootstrappedPrefix,
    sqlite: SourceTree,
    ckdl: SourceTree,
};

const sqlite_flags = &.{
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_JSON",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_OMIT_TRACE",
    "-DSQLITE_THREADSAFE=0",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_OMIT_DECLTYPE",
    "-DSQLITE_OMIT_COMPLETE",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_UTF16",
    "-DSQLITE_OMIT_AUTHORIZATION",
    "-DSQLITE_OMIT_GET_TABLE",
};

const ckdl_flags = &[_][]const u8{
    "-DKDL_STATIC_LIB",
    "-std=c11",
};

const ckdl_source_files = &[_][]const u8{
    "src/bigint.c",
    "src/compat.c",
    "src/emitter.c",
    "src/parser.c",
    "src/str.c",
    "src/tokenizer.c",
    "src/utf8.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cross = detectCrossToolchain(b, target);
    const deps = VendoredDeps{
        .zlib = bootstrapZlib(b, cross),
        .mbedtls = bootstrapMbedTls(b, cross),
        .libsodium = bootstrapLibsodium(b, cross),
        .zstd = bootstrapZstd(b, cross),
        .lzma = bootstrapLzma(b, cross),
        .bzip2 = bootstrapBzip2(b, cross),
        .libarchive = undefined,
        .curl = undefined,
        .sqlite = .{ .root = vendorSourceDir(b, .sqlite) },
        .ckdl = .{ .root = vendorSourceDir(b, .ckdl) },
    };
    var vendored = deps;
    vendored.libarchive = bootstrapLibarchive(b, vendored.zlib, vendored.bzip2, vendored.zstd, vendored.lzma, cross);
    vendored.curl = bootstrapCurl(b, vendored.zlib, vendored.mbedtls, vendored.zstd, cross);

    // Create mere module (Zig code only - no C sources here)
    const mere_module = b.addModule("mere", .{
        .root_source_file = b.path("src/mere.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendoredIncludePaths(mere_module, b, vendored);
    mere_module.addCMacro("_GNU_SOURCE", "1");

    const sqlite_lib = createSqliteLibrary(b, target, optimize, vendored.sqlite);
    const ckdl_lib = createCkdlLibrary(b, target, optimize, vendored.ckdl);

    // Build main executable
    const mere = b.addExecutable(.{
        .name = "mere",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = if (optimize != .Debug) true else null,
            .unwind_tables = if (optimize != .Debug) .none else null,
            .strip = if (optimize != .Debug) true else null,
        }),
    });
    linkSystemLibraries(mere);
    mere.root_module.linkLibrary(sqlite_lib);
    mere.root_module.linkLibrary(ckdl_lib);
    addVendoredObjectFiles(mere.root_module, b, vendored);
    mere.root_module.addImport("mere", mere_module);

    // Import build.zig.zon for version access
    const zon_module = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });
    mere.root_module.addImport("build_zon", zon_module);

    b.installArtifact(mere);

    // Build namespace_test_shell - probe binary for namespace integration tests
    const namespace_test_shell = b.addExecutable(.{
        .name = "namespace_test_shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/namespace_test_shell.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(namespace_test_shell);

    // Test modules configuration (for individual test steps)
    const test_modules = [_]TestModule{
        .{ .name = "activation", .path = "src/activation.zig" },
        .{ .name = "archive", .path = "src/archive.zig" },
        .{ .name = "build_cache", .path = "src/build_cache.zig" },
        .{ .name = "build_orchestrator", .path = "src/build_orchestrator.zig" },
        .{ .name = "artifact_model", .path = "src/build_orchestrator/artifact_model.zig" },
        .{ .name = "cache_solver", .path = "src/build_orchestrator/cache_solver.zig" },
        .{ .name = "command", .path = "src/cli/command.zig" },
        .{ .name = "commands_test", .path = "src/cli/commands_test.zig" },
        .{ .name = "config", .path = "src/config.zig" },
        .{ .name = "download", .path = "src/download.zig" },
        .{ .name = "elf", .path = "src/elf.zig" },
        .{ .name = "errors", .path = "src/errors.zig" },
        .{ .name = "etc", .path = "src/etc.zig" },
        .{ .name = "extract", .path = "src/extract.zig" },
        .{ .name = "filetype", .path = "src/filetype.zig" },
        .{ .name = "gc", .path = "src/gc.zig" },
        .{ .name = "gcroots", .path = "src/gcroots.zig" },
        .{ .name = "generation", .path = "src/generation.zig" },
        .{ .name = "hash", .path = "src/hash.zig" },
        .{ .name = "import", .path = "src/import.zig" },
        .{ .name = "init", .path = "src/init.zig" },
        .{ .name = "install", .path = "src/install.zig" },
        .{ .name = "kdl", .path = "src/kdl.zig" },
        .{ .name = "manifest", .path = "src/manifest.zig" },
        .{ .name = "mere", .path = "src/mere.zig" },
        .{ .name = "meta", .path = "src/meta.zig" },
        .{ .name = "namespace", .path = "src/namespace.zig" },
        .{ .name = "package", .path = "src/package.zig" },
        .{ .name = "package_staging", .path = "src/package_staging.zig" },
        .{ .name = "packaging", .path = "src/packaging.zig" },
        .{ .name = "parser", .path = "src/cli/parser.zig" },
        .{ .name = "path", .path = "src/path.zig" },
        .{ .name = "pin", .path = "src/pin.zig" },
        .{ .name = "publish", .path = "src/publish.zig" },
        .{ .name = "profile", .path = "src/profile.zig" },
        .{ .name = "recipe", .path = "src/recipe.zig" },
        .{ .name = "repodb", .path = "src/repodb.zig" },
        .{ .name = "repo_generation", .path = "src/repo_generation.zig" },
        .{ .name = "repocache", .path = "src/repocache.zig" },
        .{ .name = "repo_sources", .path = "src/repo_sources.zig" },
        .{ .name = "repository", .path = "src/repository.zig" },
        .{ .name = "requested", .path = "src/requested.zig" },
        .{ .name = "resolver", .path = "src/resolver.zig" },
        .{ .name = "sign", .path = "src/sign.zig" },
        .{ .name = "sign_crypto", .path = "src/sign_crypto.zig" },
        .{ .name = "sign_io", .path = "src/sign_io.zig" },
        .{ .name = "source_manager", .path = "src/source_manager.zig" },
        .{ .name = "source_unpacker", .path = "src/source_unpacker.zig" },
        .{ .name = "store", .path = "src/store.zig" },
        .{ .name = "strip", .path = "src/strip.zig" },
        .{ .name = "path_safety", .path = "src/path_safety.zig" },
        .{ .name = "scratch", .path = "src/scratch.zig" },
        .{ .name = "verify", .path = "src/verify.zig" },
        .{ .name = "version", .path = "src/version.zig" },
        .{ .name = "workspace_manager", .path = "src/workspace_manager.zig" },
        .{ .name = "zstd_c", .path = "src/zstd_c.zig" },
    };

    // Main test step uses all_tests.zig to run each test exactly once
    const test_step = b.step("test", "Run all tests");
    const all_tests_run = createTestStep(b, .{ .name = "all", .path = "src/all_tests.zig" }, target, optimize, sqlite_lib, ckdl_lib, vendored, mere_module, zon_module);
    test_step.dependOn(&all_tests_run.step);

    // Individual test steps for running specific module tests
    for (test_modules) |test_module| {
        _ = createTestStep(b, test_module, target, optimize, sqlite_lib, ckdl_lib, vendored, mere_module, zon_module);
    }
}

const TestModule = struct {
    name: []const u8,
    path: []const u8,
};

fn linkSystemLibraries(artifact: *std.Build.Step.Compile) void {
    artifact.root_module.linkSystemLibrary("c", .{});
}

fn createTestStep(
    b: *std.Build,
    test_module: TestModule,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite_lib: *std.Build.Step.Compile,
    ckdl_lib: *std.Build.Step.Compile,
    deps: VendoredDeps,
    mere_module: *std.Build.Module,
    zon_module: *std.Build.Module,
) *std.Build.Step.Run {
    // Create test executable
    const test_exe = b.addTest(.{
        .root_module = blk: {
            const mod = b.createModule(.{
                .root_source_file = b.path(test_module.path),
                .target = target,
                .optimize = optimize,
            });
            mod.addCMacro("_GNU_SOURCE", "1");
            // Files under src/cli/ import "mere" and "build_zon" as named
            // modules rather than by relative filename - wire both edges
            // so those files can be used as test roots too (only files
            // whose relative imports stay within src/cli/ actually work
            // this way; Zig rejects a standalone module reaching outside
            // its own root's directory, e.g. src/cli/commands/*.zig's
            // "../types.zig").
            mod.addImport("mere", mere_module);
            mod.addImport("build_zon", zon_module);
            break :blk mod;
        },
    });
    addVendoredIncludePaths(test_exe.root_module, b, deps);
    linkSystemLibraries(test_exe);
    test_exe.root_module.linkLibrary(sqlite_lib);
    test_exe.root_module.linkLibrary(ckdl_lib);
    addVendoredObjectFiles(test_exe.root_module, b, deps);

    // Create run artifact
    const run_test = b.addRunArtifact(test_exe);

    // Set working directory to project root so tests can find test/testdata/
    run_test.setCwd(b.path("."));

    // Create individual test step
    const step_name = b.fmt("test-{s}", .{test_module.name});
    const step_desc = b.fmt("Run {s} tests", .{test_module.name});
    const test_step = b.step(step_name, step_desc);
    test_step.dependOn(&run_test.step);

    return run_test;
}

fn addVendoredIncludePaths(target: *std.Build.Module, b: *std.Build, deps: VendoredDeps) void {
    target.addIncludePath(deps.zlib.include_dir);
    target.addIncludePath(deps.curl.include_dir);
    target.addIncludePath(deps.libsodium.include_dir);
    target.addIncludePath(deps.zstd.include_dir);
    target.addIncludePath(deps.lzma.include_dir);
    target.addIncludePath(deps.bzip2.include_dir);
    target.addIncludePath(deps.libarchive.include_dir);
    target.addIncludePath(deps.sqlite.root);
    target.addIncludePath(deps.ckdl.path(b, "include"));
    target.addIncludePath(deps.ckdl.path(b, "src"));
}

fn addVendoredObjectFiles(
    artifact: *std.Build.Module,
    b: *std.Build,
    deps: VendoredDeps,
) void {
    artifact.addObjectFile(deps.mbedtls.staticLib(b, "mbedcrypto"));
    artifact.addObjectFile(deps.mbedtls.staticLib(b, "mbedx509"));
    artifact.addObjectFile(deps.mbedtls.staticLib(b, "mbedtls"));
    artifact.addObjectFile(deps.zlib.staticLib(b, "z"));
    artifact.addObjectFile(deps.zstd.staticLib(b, "zstd"));
    artifact.addObjectFile(deps.lzma.staticLib(b, "lzma"));
    artifact.addObjectFile(deps.curl.staticLib(b, "curl"));
    artifact.addObjectFile(deps.libsodium.staticLib(b, "sodium"));
    artifact.addObjectFile(deps.libarchive.staticLib(b, "archive"));
    artifact.addObjectFile(deps.bzip2.prefix.path(b, "lib/libbz2.a"));
}

fn createSqliteLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite: SourceTree,
) *std.Build.Step.Compile {
    const sqlite_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    sqlite_module.addIncludePath(sqlite.root);
    sqlite_module.addCSourceFile(.{
        .file = sqlite.path(b, "sqlite3.c"),
        .flags = sqlite_flags,
    });

    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_module,
        .linkage = .static,
    });
    sqlite_lib.root_module.linkSystemLibrary("c", .{});
    return sqlite_lib;
}

fn createCkdlLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ckdl: SourceTree,
) *std.Build.Step.Compile {
    const ckdl_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    ckdl_module.addIncludePath(ckdl.path(b, "include"));
    ckdl_module.addIncludePath(ckdl.path(b, "src"));
    for (ckdl_source_files) |source_file| {
        ckdl_module.addCSourceFile(.{
            .file = ckdl.path(b, source_file),
            .flags = ckdl_flags,
        });
    }

    const ckdl_lib = b.addLibrary(.{
        .name = "ckdl",
        .root_module = ckdl_module,
        .linkage = .static,
    });
    ckdl_lib.root_module.linkSystemLibrary("c", .{});
    return ckdl_lib;
}

fn appendCMakeFlags(b: *std.Build, flags: []const []const u8) []const u8 {
    var script: std.ArrayList(u8) = .empty;
    for (flags) |flag| {
        script.appendSlice(b.allocator, " \\\n  ") catch @panic("OOM");
        script.appendSlice(b.allocator, flag) catch @panic("OOM");
    }
    return script.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn appendShellQuotedArg(list: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: []const u8) void {
    list.append(allocator, '\'') catch @panic("OOM");
    for (arg) |byte| {
        if (byte == '\'') {
            list.appendSlice(allocator, "'\\''") catch @panic("OOM");
        } else {
            list.append(allocator, byte) catch @panic("OOM");
        }
    }
    list.append(allocator, '\'') catch @panic("OOM");
}

fn appendShellSetArgs(b: *std.Build, args: []const []const u8) []const u8 {
    var script: std.ArrayList(u8) = .empty;
    for (args) |arg| {
        script.appendSlice(b.allocator, "\nset -- \"$@\" ") catch @panic("OOM");
        appendShellQuotedArg(&script, b.allocator, arg);
    }
    return script.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn bootstrapCMakePrefix(b: *std.Build, spec: CMakeBootstrap) BootstrappedPrefix {
    const source_dir = vendorSourceDir(b, spec.dep);
    const cross_env_setup = if (spec.cross) |cross|
        b.fmt(
            \\cross_dir="$(realpath "$3")"
            \\cross_flags="-DCMAKE_SYSTEM_NAME={s} -DCMAKE_SYSTEM_PROCESSOR={s}"
            \\cross_flags="$cross_flags -DCMAKE_C_COMPILER=$cross_dir/zig-cc"
            \\cross_flags="$cross_flags -DCMAKE_CXX_COMPILER=$cross_dir/zig-c++"
            \\cross_flags="$cross_flags -DCMAKE_ASM_COMPILER=$cross_dir/zig-cc"
            \\cross_flags="$cross_flags -DCMAKE_AR=$cross_dir/zig-ar"
            \\cross_flags="$cross_flags -DCMAKE_RANLIB=$cross_dir/zig-ranlib"
            \\cross_flags="$cross_flags -DCMAKE_CROSSCOMPILING=ON"
            \\
        , .{ cross.cmake_system_name, cross.cmake_system_processor })
    else
        "cross_flags=\n";
    const cmake_flags = appendCMakeFlags(b, spec.cmake_flags);
    const source_subdir = spec.cmake_source_subdir orelse "";
    const source_suffix = if (source_subdir.len == 0)
        ""
    else
        b.fmt("/{s}", .{source_subdir});
    const bootstrap_script = b.fmt(
        \\srcdir="$1"
        \\prefix="$2"
        \\{s}
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\
        \\mkdir -p "$tmpdir/src"
        \\run_logged cp -Rp "$srcdir/." "$tmpdir/src"
        \\run_logged find "$tmpdir/src" -exec touch -r "$tmpdir/src" {{}} +
        \\src="$tmpdir/src{s}"
        \\build="$tmpdir/build"
        \\
        \\# shellcheck disable=SC2086
        \\run_logged cmake -Wno-dev -S "$src" -B "$build" $cross_flags{s}
        \\run_logged cmake --build "$build"
        \\run_logged cmake --install "$build" --prefix "$prefix"
    ,
        .{
            cross_env_setup,
            source_suffix,
            cmake_flags,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, spec.step_name });
    bootstrap.addDirectoryArg(source_dir);
    const prefix = bootstrap.addOutputDirectoryArg(spec.output_dirname);
    if (spec.cross) |cross| {
        bootstrap.step.dependOn(cross.cmake_setup_step);
        bootstrap.addDirectoryArg(cross.cmake_wrapper_dir);
    }

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapAutotoolsPrefix(b: *std.Build, spec: AutotoolsBootstrap) BootstrappedPrefix {
    const source_dir = vendorSourceDir(b, spec.dep);
    const configure_args = appendShellSetArgs(b, spec.configure_args);
    const cross_env = if (spec.cross) |cross|
        b.fmt(
            \\export CC="{s}"
            \\export AR="{s}"
            \\export RANLIB="{s}"
            \\
        , .{ cross.cc, cross.ar, cross.ranlib })
    else
        "";
    const cross_host = if (spec.cross) |cross|
        b.fmt(" --host={s}", .{cross.triple})
    else
        "";
    const bootstrap_script = b.fmt(
        \\srcdir="$1"
        \\prefix="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\{s}
        \\mkdir -p "$tmpdir/src"
        \\run_logged cp -Rp "$srcdir/." "$tmpdir/src"
        \\run_logged find "$tmpdir/src" -exec touch -r "$tmpdir/src" {{}} +
        \\src="$tmpdir/src"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" --prefix="$prefix" --libdir="$prefix/lib"{s}{s}
        \\run_logged "$@"
        \\run_logged make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\run_logged make install
    ,
        .{
            cross_env,
            cross_host,
            configure_args,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, spec.step_name });
    bootstrap.addDirectoryArg(source_dir);
    const prefix = bootstrap.addOutputDirectoryArg(spec.output_dirname);

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapZlib(b: *std.Build, cross: ?CrossToolchain) BootstrappedPrefix {
    return bootstrapCMakePrefix(b, .{
        .step_name = "vendor-bootstrap-zlib",
        .output_dirname = "zlib-ng",
        .dep = .zlib,
        .cmake_flags = &.{
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DZLIB_COMPAT=ON",
            "-DZLIB_ENABLE_TESTS=OFF",
            "-DZLIBNG_ENABLE_TESTS=OFF",
        },
        .cross = cross,
    });
}

/// mbedtls is the other vendored dependency NOT fetched via build.zig.zon:
/// its CMakeLists.txt requires a git submodule (framework/) that a plain
/// GitHub tag-archive tarball never includes (git archives never contain
/// submodule content); only its official release asset bundles it, and
/// that host sends Content-Type/Content-Disposition headers Zig's fetcher
/// rejects. So this keeps the old curl+sha256sum fetch, inlined here
/// rather than as a shared helper since it's a one-off.
fn bootstrapMbedTls(b: *std.Build, cross: ?CrossToolchain) BootstrappedPrefix {
    const url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2";
    const sha256 = "4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8";
    const source_dirname = "mbedtls-3.6.5";

    const download = b.addSystemCommand(&.{
        "sh",
        "-ceu",
        \\url="$1"
        \\expected="$2"
        \\out="$3"
        \\log="$out.log"
        \\
        \\: > "$log"
        \\curl -fsSL --retry 3 -o "$out" "$url" 2>>"$log" || {
        \\  status="$?"
        \\  echo "vendor fetch failed, see $log" >&2
        \\  tail -n 50 "$log" >&2 || true
        \\  exit "$status"
        \\}
        \\
        \\checksum_line="$(sha256sum "$out" 2>>"$log")" || {
        \\  status="$?"
        \\  echo "vendor fetch failed, see $log" >&2
        \\  tail -n 50 "$log" >&2 || true
        \\  exit "$status"
        \\}
        \\set -- $checksum_line
        \\actual="$1"
        \\if [ "$actual" != "$expected" ]; then
        \\  {
        \\    echo "sha256 mismatch for $out"
        \\    echo "expected: $expected"
        \\    echo "actual:   $actual"
        \\  } >>"$log"
        \\  echo "vendor fetch failed, see $log" >&2
        \\  tail -n 50 "$log" >&2 || true
        \\  rm -f "$out"
        \\  exit 1
        \\fi
        ,
        "vendor-fetch-mbedtls",
    });
    download.addArg(url);
    download.addArg(sha256);
    const tarball = download.addOutputFileArg("mbedtls-3.6.5.tar.bz2");

    const cross_env_setup = if (cross) |c|
        b.fmt(
            \\cross_dir="$(realpath "$3")"
            \\cross_flags="-DCMAKE_SYSTEM_NAME={s} -DCMAKE_SYSTEM_PROCESSOR={s}"
            \\cross_flags="$cross_flags -DCMAKE_C_COMPILER=$cross_dir/zig-cc"
            \\cross_flags="$cross_flags -DCMAKE_CXX_COMPILER=$cross_dir/zig-c++"
            \\cross_flags="$cross_flags -DCMAKE_ASM_COMPILER=$cross_dir/zig-cc"
            \\cross_flags="$cross_flags -DCMAKE_AR=$cross_dir/zig-ar"
            \\cross_flags="$cross_flags -DCMAKE_RANLIB=$cross_dir/zig-ranlib"
            \\cross_flags="$cross_flags -DCMAKE_CROSSCOMPILING=ON"
            \\
        , .{ c.cmake_system_name, c.cmake_system_processor })
    else
        "cross_flags=\n";
    const cmake_flags = appendCMakeFlags(b, &.{
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_INSTALL_LIBDIR=lib",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DENABLE_PROGRAMS=OFF",
        "-DENABLE_TESTING=OFF",
        "-DUSE_STATIC_MBEDTLS_LIBRARY=ON",
        "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
    });
    const bootstrap_script = b.fmt(
        \\tarball="$1"
        \\prefix="$2"
        \\{s}
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\
        \\run_logged tar -xjf "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\build="$tmpdir/build"
        \\
        \\# shellcheck disable=SC2086
        \\run_logged cmake -Wno-dev -S "$src" -B "$build" $cross_flags{s}
        \\run_logged cmake --build "$build"
        \\run_logged cmake --install "$build" --prefix "$prefix"
    ,
        .{
            cross_env_setup,
            source_dirname,
            cmake_flags,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-mbedtls" });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg("mbedtls");
    if (cross) |c| {
        bootstrap.step.dependOn(c.cmake_setup_step);
        bootstrap.addDirectoryArg(c.cmake_wrapper_dir);
    }

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

/// libsodium is the one vendored dependency NOT fetched via build.zig.zon:
/// its source (official release tarball and GitHub tag archive alike)
/// ships its own build.zig, and Zig's package manager unconditionally
/// tries to run a fetched dependency's build.zig while resolving it —
/// which fails here, since that build.zig targets a different Zig version
/// than this project's. So this keeps the old curl+sha256sum fetch,
/// inlined here rather than as a shared helper since it's a one-off.
fn bootstrapLibsodium(b: *std.Build, cross: ?CrossToolchain) BootstrappedPrefix {
    const url = "https://github.com/jedisct1/libsodium/archive/refs/tags/1.0.21-RELEASE.tar.gz";
    const sha256 = "42e0ca94faaec901f4fbeda84b1b94b18f5309c360c66345cf52a7ab515b245b";
    const source_dirname = "libsodium-1.0.21-RELEASE";

    const download = b.addSystemCommand(&.{
        "sh",
        "-ceu",
        \\url="$1"
        \\expected="$2"
        \\out="$3"
        \\log="$out.log"
        \\
        \\: > "$log"
        \\curl -fsSL --retry 3 -o "$out" "$url" 2>>"$log" || {
        \\  status="$?"
        \\  echo "vendor fetch failed, see $log" >&2
        \\  tail -n 50 "$log" >&2 || true
        \\  exit "$status"
        \\}
        \\
        \\checksum_line="$(sha256sum "$out" 2>>"$log")" || {
        \\  status="$?"
        \\  echo "vendor fetch failed, see $log" >&2
        \\  tail -n 50 "$log" >&2 || true
        \\  exit "$status"
        \\}
        \\set -- $checksum_line
        \\actual="$1"
        \\if [ "$actual" != "$expected" ]; then
        \\  {
        \\    echo "sha256 mismatch for $out"
        \\    echo "expected: $expected"
        \\    echo "actual:   $actual"
        \\  } >>"$log"
        \\  echo "vendor fetch failed, see $log" >&2
        \\  tail -n 50 "$log" >&2 || true
        \\  rm -f "$out"
        \\  exit 1
        \\fi
        ,
        "vendor-fetch-libsodium",
    });
    download.addArg(url);
    download.addArg(sha256);
    const tarball = download.addOutputFileArg("libsodium-1.0.21-RELEASE.tar.gz");

    const configure_args = appendShellSetArgs(b, &.{
        "--disable-shared",
        "--enable-static",
        "--enable-minimal",
    });
    const cross_env = if (cross) |c|
        b.fmt(
            \\export CC="{s}"
            \\export AR="{s}"
            \\export RANLIB="{s}"
            \\
        , .{ c.cc, c.ar, c.ranlib })
    else
        "";
    const cross_host = if (cross) |c|
        b.fmt(" --host={s}", .{c.triple})
    else
        "";
    const bootstrap_script = b.fmt(
        \\tarball="$1"
        \\prefix="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\{s}
        \\run_logged tar -xzf "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" --prefix="$prefix" --libdir="$prefix/lib"{s}{s}
        \\run_logged "$@"
        \\run_logged make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\run_logged make install
    ,
        .{
            cross_env,
            source_dirname,
            cross_host,
            configure_args,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-libsodium" });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg("libsodium");

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapZstd(b: *std.Build, cross: ?CrossToolchain) BootstrappedPrefix {
    return bootstrapCMakePrefix(b, .{
        .step_name = "vendor-bootstrap-zstd",
        .output_dirname = "zstd",
        .dep = .zstd,
        .cmake_source_subdir = "build/cmake",
        .cmake_flags = &.{
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DZSTD_BUILD_PROGRAMS=OFF",
            "-DZSTD_BUILD_SHARED=OFF",
            "-DZSTD_BUILD_STATIC=ON",
            "-DZSTD_BUILD_TESTS=OFF",
        },
        .cross = cross,
    });
}

fn bootstrapLzma(b: *std.Build, cross: ?CrossToolchain) BootstrappedPrefix {
    return bootstrapAutotoolsPrefix(b, .{
        .step_name = "vendor-bootstrap-lzma",
        .output_dirname = "lzma",
        .dep = .lzma,
        .configure_args = &.{
            "--disable-shared",
            "--enable-static",
            "--disable-xz",
            "--disable-xzdec",
            "--disable-lzmadec",
            "--disable-lzmainfo",
            "--disable-scripts",
            "--disable-doc",
            "--disable-nls",
        },
        .cross = cross,
    });
}

fn bootstrapBzip2(b: *std.Build, cross: ?CrossToolchain) BootstrappedPrefix {
    const source_dir = vendorSourceDir(b, .bzip2);
    const cc = if (cross) |c| c.cc else "cc";
    const ar = if (cross) |c| c.ar else "ar";
    const ranlib = if (cross) |c| c.ranlib else "ranlib";
    const bootstrap_script = b.fmt(
        \\srcdir="$1"
        \\prefix="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\
        \\mkdir -p "$tmpdir/src"
        \\run_logged cp -Rp "$srcdir/." "$tmpdir/src"
        \\run_logged find "$tmpdir/src" -exec touch -r "$tmpdir/src" {{}} +
        \\src="$tmpdir/src"
        \\cd "$src"
        \\make -f Makefile-libbz2_so clean >>"$log" 2>&1 || true
        \\run_logged make \
        \\  CC="{s}" \
        \\  AR="{s}" \
        \\  RANLIB="{s}" \
        \\  CFLAGS=-O2\ -fPIC \
        \\  libbz2.a
        \\mkdir -p "$prefix/lib" "$prefix/include" >>"$log" 2>&1
        \\run_logged cp libbz2.a "$prefix/lib/libbz2.a"
        \\run_logged cp bzlib.h "$prefix/include/bzlib.h"
    ,
        .{
            cc,
            ar,
            ranlib,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-bzip2" });
    bootstrap.addDirectoryArg(source_dir);
    const prefix = bootstrap.addOutputDirectoryArg("bzip2");

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapLibarchive(
    b: *std.Build,
    zlib: BootstrappedPrefix,
    bzip2: BootstrappedPrefix,
    zstd: BootstrappedPrefix,
    lzma: BootstrappedPrefix,
    cross: ?CrossToolchain,
) BootstrappedPrefix {
    const source_dir = vendorSourceDir(b, .libarchive);
    const cross_env = if (cross) |c|
        b.fmt(
            \\export CC="{s}"
            \\export AR="{s}"
            \\export RANLIB="{s}"
            \\
        , .{ c.cc, c.ar, c.ranlib })
    else
        "";
    const cross_host = if (cross) |c|
        b.fmt(" --host={s}", .{c.triple})
    else
        "";
    const bootstrap_script = b.fmt(
        \\srcdir="$1"
        \\prefix="$2"
        \\zlib_prefix="$(realpath "$3")"
        \\bzip2_prefix="$(realpath "$4")"
        \\zstd_prefix="$(realpath "$5")"
        \\lzma_prefix="$(realpath "$6")"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\{s}
        \\mkdir -p "$tmpdir/src"
        \\run_logged cp -Rp "$srcdir/." "$tmpdir/src"
        \\run_logged find "$tmpdir/src" -exec touch -r "$tmpdir/src" {{}} +
        \\src="$tmpdir/src"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" \
        \\  --prefix="$prefix" \
        \\  --libdir="$prefix/lib"{s} \
        \\  --enable-static \
        \\  --disable-shared \
        \\  --disable-bsdtar \
        \\  --disable-bsdcat \
        \\  --disable-bsdcpio \
        \\  --disable-bsdunzip \
        \\  --disable-xattr \
        \\  --disable-acl \
        \\  --without-libb2 \
        \\  --without-iconv \
        \\  --without-lz4 \
        \\  --without-openssl \
        \\  --without-xml2 \
        \\  --without-expat \
        \\  CFLAGS=-Os\ -fPIC \
        \\  CPPFLAGS=-I"$zlib_prefix/include"\ -I"$bzip2_prefix/include"\ -I"$zstd_prefix/include"\ -I"$lzma_prefix/include" \
        \\  LDFLAGS=-L"$zlib_prefix/lib"\ -L"$bzip2_prefix/lib"\ -L"$zstd_prefix/lib"\ -L"$lzma_prefix/lib" \
        \\  ac_cv_header_md5_h=no \
        \\  ac_cv_header_ripemd_h=no \
        \\  ac_cv_header_sha_h=no \
        \\  ac_cv_header_sha256_h=no \
        \\  ac_cv_header_sha512_h=no \
        \\  ac_cv_lib_md_MD5Init=no
        \\run_logged "$@"
        \\run_logged make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\run_logged make install
    ,
        .{
            cross_env,
            cross_host,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-libarchive" });
    bootstrap.addDirectoryArg(source_dir);
    const prefix = bootstrap.addOutputDirectoryArg("libarchive");
    bootstrap.addDirectoryArg(zlib.prefix);
    bootstrap.addDirectoryArg(bzip2.prefix);
    bootstrap.addDirectoryArg(zstd.prefix);
    bootstrap.addDirectoryArg(lzma.prefix);

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapCurl(
    b: *std.Build,
    zlib: BootstrappedPrefix,
    mbedtls: BootstrappedPrefix,
    zstd: BootstrappedPrefix,
    cross: ?CrossToolchain,
) BootstrappedPrefix {
    const source_dir = vendorSourceDir(b, .curl);
    const cross_env = if (cross) |c|
        b.fmt(
            \\export CC="{s}"
            \\export AR="{s}"
            \\export RANLIB="{s}"
            \\
        , .{ c.cc, c.ar, c.ranlib })
    else
        "";
    const cross_host = if (cross) |c|
        b.fmt(" --host={s}", .{c.triple})
    else
        "";
    const bootstrap_script = b.fmt(
        \\srcdir="$1"
        \\prefix="$2"
        \\zlib_prefix="$(realpath "$3")"
        \\mbedtls_prefix="$(realpath "$4")"
        \\zstd_prefix="$(realpath "$5")"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\mkdir -p "$prefix"
        \\log="$prefix/.mere-build.log"
        \\: > "$log"
        \\run_logged() {{
        \\  "$@" >>"$log" 2>&1 || {{
        \\    status="$?"
        \\    echo "vendor bootstrap failed, see $log" >&2
        \\    tail -n 50 "$log" >&2 || true
        \\    exit "$status"
        \\  }}
        \\}}
        \\{s}
        \\mkdir -p "$tmpdir/src"
        \\run_logged cp -Rp "$srcdir/." "$tmpdir/src"
        \\run_logged find "$tmpdir/src" -exec touch -r "$tmpdir/src" {{}} +
        \\src="$tmpdir/src"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" \
        \\  --prefix="$prefix" \
        \\  --libdir="$prefix/lib"{s} \
        \\  --disable-shared \
        \\  --enable-static \
        \\  --disable-ftp \
        \\  --disable-ipfs \
        \\  --disable-rtsp \
        \\  --disable-alt-svc \
        \\  --disable-hsts \
        \\  --disable-ntlm \
        \\  --disable-netrc \
        \\  --disable-unix-sockets \
        \\  --disable-websockets \
        \\  --disable-cookies \
        \\  --disable-dateparse \
        \\  --disable-doh \
        \\  --disable-dict \
        \\  --disable-telnet \
        \\  --disable-tftp \
        \\  --disable-pop3 \
        \\  --disable-imap \
        \\  --disable-smb \
        \\  --disable-smtp \
        \\  --disable-gopher \
        \\  --disable-mqtt \
        \\  --disable-manual \
        \\  --disable-docs \
        \\  --without-libpsl \
        \\  --without-nghttp2 \
        \\  --without-nghttp3 \
        \\  --without-ngtcp2 \
        \\  --without-brotli \
        \\  --without-libidn2 \
        \\  --without-librtmp \
        \\  --disable-ldap \
        \\  --disable-ldaps \
        \\  --with-mbedtls="$mbedtls_prefix" \
        \\  --with-zlib="$zlib_prefix" \
        \\  --with-zstd="$zstd_prefix" \
        \\  CFLAGS=-Os\ -fPIC \
        \\  CPPFLAGS=-D_GNU_SOURCE\ -I"$zlib_prefix/include"\ -I"$mbedtls_prefix/include"\ -I"$zstd_prefix/include" \
        \\  LDFLAGS=-L"$zlib_prefix/lib"\ -L"$mbedtls_prefix/lib"\ -L"$zstd_prefix/lib"
        \\run_logged "$@"
        \\run_logged make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\run_logged make install
    ,
        .{
            cross_env,
            cross_host,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-curl" });
    bootstrap.addDirectoryArg(source_dir);
    const prefix = bootstrap.addOutputDirectoryArg("curl");
    bootstrap.addDirectoryArg(zlib.prefix);
    bootstrap.addDirectoryArg(mbedtls.prefix);
    bootstrap.addDirectoryArg(zstd.prefix);

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}
