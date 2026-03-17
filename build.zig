const std = @import("std");

const ArchiveKind = enum {
    tar_gz,
    tar_bz2,
    tar_xz,

    fn tarExtractFlag(self: ArchiveKind) []const u8 {
        return switch (self) {
            .tar_gz => "-xzf",
            .tar_bz2 => "-xjf",
            .tar_xz => "-xJf",
        };
    }
};

const VendorSource = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    archive_basename: []const u8,
    source_dirname: []const u8,
    archive_kind: ArchiveKind,
};

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
};

const VendorSourceEntry = struct {
    dep: VendorDep,
    source: VendorSource,
};

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

const CMakeBootstrap = struct {
    step_name: []const u8,
    output_dirname: []const u8,
    source: VendorSource,
    cmake_source_subdir: ?[]const u8 = null,
    cmake_flags: []const []const u8,
};

const AutotoolsBootstrap = struct {
    step_name: []const u8,
    output_dirname: []const u8,
    source: VendorSource,
    configure_args: []const []const u8,
};

const SourceTreeBootstrap = struct {
    step_name: []const u8,
    output_dirname: []const u8,
    source: VendorSource,
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

const vendor_sources = [_]VendorSourceEntry{
    .{
        .dep = .zlib,
        .source = blk: {
            const version = "2.2.5";
            break :blk .{
                .name = "zlib-ng",
                .version = version,
                .url = std.fmt.comptimePrint("https://github.com/zlib-ng/zlib-ng/archive/refs/tags/{s}.tar.gz", .{version}),
                .sha256 = "5b3b022489f3ced82384f06db1e13ba148cbce38c7941e424d6cb414416acd18",
                .archive_basename = std.fmt.comptimePrint("zlib-ng-{s}.tar.gz", .{version}),
                .source_dirname = std.fmt.comptimePrint("zlib-ng-{s}", .{version}),
                .archive_kind = .tar_gz,
            };
        },
    },
    .{
        .dep = .mbedtls,
        .source = blk: {
            const version = "3.6.5";
            break :blk .{
                .name = "mbedtls",
                .version = version,
                .url = std.fmt.comptimePrint("https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-{0s}/mbedtls-{0s}.tar.bz2", .{version}),
                .sha256 = "4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8",
                .archive_basename = std.fmt.comptimePrint("mbedtls-{s}.tar.bz2", .{version}),
                .source_dirname = std.fmt.comptimePrint("mbedtls-{s}", .{version}),
                .archive_kind = .tar_bz2,
            };
        },
    },
    .{
        .dep = .libsodium,
        .source = blk: {
            const version = "1.0.21";
            break :blk .{
                .name = "libsodium",
                .version = version,
                .url = std.fmt.comptimePrint("https://download.libsodium.org/libsodium/releases/libsodium-{s}.tar.gz", .{version}),
                .sha256 = "9e4285c7a419e82dedb0be63a72eea357d6943bc3e28e6735bf600dd4883feaf",
                .archive_basename = std.fmt.comptimePrint("libsodium-{s}.tar.gz", .{version}),
                .source_dirname = std.fmt.comptimePrint("libsodium-{s}", .{version}),
                .archive_kind = .tar_gz,
            };
        },
    },
    .{
        .dep = .zstd,
        .source = blk: {
            const version = "1.5.7";
            break :blk .{
                .name = "zstd",
                .version = version,
                .url = std.fmt.comptimePrint("https://github.com/facebook/zstd/releases/download/v{0s}/zstd-{0s}.tar.gz", .{version}),
                .sha256 = "eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3",
                .archive_basename = std.fmt.comptimePrint("zstd-{s}.tar.gz", .{version}),
                .source_dirname = std.fmt.comptimePrint("zstd-{s}", .{version}),
                .archive_kind = .tar_gz,
            };
        },
    },
    .{
        .dep = .lzma,
        .source = blk: {
            const version = "5.8.2";
            break :blk .{
                .name = "xz",
                .version = version,
                .url = std.fmt.comptimePrint("https://github.com/tukaani-project/xz/releases/download/v{0s}/xz-{0s}.tar.xz", .{version}),
                .sha256 = "890966ec3f5d5cc151077879e157c0593500a522f413ac50ba26d22a9a145214",
                .archive_basename = std.fmt.comptimePrint("xz-{s}.tar.xz", .{version}),
                .source_dirname = std.fmt.comptimePrint("xz-{s}", .{version}),
                .archive_kind = .tar_xz,
            };
        },
    },
    .{
        .dep = .bzip2,
        .source = blk: {
            const version = "1.0.8";
            break :blk .{
                .name = "bzip2",
                .version = version,
                .url = std.fmt.comptimePrint("https://sourceware.org/pub/bzip2/bzip2-{s}.tar.gz", .{version}),
                .sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
                .archive_basename = std.fmt.comptimePrint("bzip2-{s}.tar.gz", .{version}),
                .source_dirname = std.fmt.comptimePrint("bzip2-{s}", .{version}),
                .archive_kind = .tar_gz,
            };
        },
    },
    .{
        .dep = .libarchive,
        .source = blk: {
            const version = "3.8.2";
            break :blk .{
                .name = "libarchive",
                .version = version,
                .url = std.fmt.comptimePrint("https://github.com/libarchive/libarchive/releases/download/v{0s}/libarchive-{0s}.tar.xz", .{version}),
                .sha256 = "db0dee91561cbd957689036a3a71281efefd131d35d1d98ebbc32720e4da58e2",
                .archive_basename = std.fmt.comptimePrint("libarchive-{s}.tar.xz", .{version}),
                .source_dirname = std.fmt.comptimePrint("libarchive-{s}", .{version}),
                .archive_kind = .tar_xz,
            };
        },
    },
    .{
        .dep = .curl,
        .source = blk: {
            const version = "8.19.0";
            break :blk .{
                .name = "curl",
                .version = version,
                .url = std.fmt.comptimePrint("https://curl.se/download/curl-{s}.tar.xz", .{version}),
                .sha256 = "4eb41489790d19e190d7ac7e18e82857cdd68af8f4e66b292ced562d333f11df",
                .archive_basename = std.fmt.comptimePrint("curl-{s}.tar.xz", .{version}),
                .source_dirname = std.fmt.comptimePrint("curl-{s}", .{version}),
                .archive_kind = .tar_xz,
            };
        },
    },
    .{
        .dep = .sqlite,
        .source = blk: {
            const version = "3.51.3";
            const release_id = "3510300";
            const year = "2026";
            break :blk .{
                .name = "sqlite",
                .version = version,
                .url = std.fmt.comptimePrint("https://www.sqlite.org/{0s}/sqlite-autoconf-{1s}.tar.gz", .{ year, release_id }),
                .sha256 = "81f5be397049b0cae1b167f2225af7646fc0f82e4a9b3c48c9ea3a533e21d77a",
                .archive_basename = std.fmt.comptimePrint("sqlite-autoconf-{s}.tar.gz", .{release_id}),
                .source_dirname = std.fmt.comptimePrint("sqlite-autoconf-{s}", .{release_id}),
                .archive_kind = .tar_gz,
            };
        },
    },
    .{
        .dep = .ckdl,
        .source = blk: {
            const version = "1.0";
            break :blk .{
                .name = "ckdl",
                .version = version,
                .url = std.fmt.comptimePrint("https://github.com/tjol/ckdl/archive/refs/tags/{s}.tar.gz", .{version}),
                .sha256 = "0bf3a7d81d661eafccfbf82c68278d38c939b0b7329ad4599f95bbf2f4ca6dc8",
                .archive_basename = std.fmt.comptimePrint("ckdl-{s}.tar.gz", .{version}),
                .source_dirname = std.fmt.comptimePrint("ckdl-{s}", .{version}),
                .archive_kind = .tar_gz,
            };
        },
    },
};

fn vendorSource(comptime dep: VendorDep) VendorSource {
    inline for (vendor_sources) |entry| {
        if (entry.dep == dep) return entry.source;
    }
    @compileError("missing vendor source manifest entry");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = VendoredDeps{
        .zlib = bootstrapZlib(b),
        .mbedtls = bootstrapMbedTls(b),
        .libsodium = bootstrapLibsodium(b),
        .zstd = bootstrapZstd(b),
        .lzma = bootstrapLzma(b),
        .bzip2 = bootstrapBzip2(b),
        .libarchive = undefined,
        .curl = undefined,
        .sqlite = unpackVendorSourceTree(b, .{
            .step_name = "vendor-source-sqlite",
            .output_dirname = "sqlite-source",
            .source = vendorSource(.sqlite),
        }),
        .ckdl = unpackVendorSourceTree(b, .{
            .step_name = "vendor-source-ckdl",
            .output_dirname = "ckdl-source",
            .source = vendorSource(.ckdl),
        }),
    };
    var vendored = deps;
    vendored.libarchive = bootstrapLibarchive(b, vendored.zlib, vendored.bzip2, vendored.zstd, vendored.lzma);
    vendored.curl = bootstrapCurl(b, vendored.zlib, vendored.mbedtls, vendored.zstd);

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
    mere.linkLibrary(sqlite_lib);
    mere.linkLibrary(ckdl_lib);
    addVendoredObjectFiles(mere, b, vendored);
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
        .{ .name = "verify", .path = "src/verify.zig" },
        .{ .name = "version", .path = "src/version.zig" },
        .{ .name = "workspace_manager", .path = "src/workspace_manager.zig" },
        .{ .name = "zstd_c", .path = "src/zstd_c.zig" },
    };

    // Main test step uses all_tests.zig to run each test exactly once
    const test_step = b.step("test", "Run all tests");
    const all_tests_run = createTestStep(b, .{ .name = "all", .path = "src/all_tests.zig" }, target, optimize, sqlite_lib, ckdl_lib, vendored);
    test_step.dependOn(&all_tests_run.step);

    // Individual test steps for running specific module tests
    for (test_modules) |test_module| {
        _ = createTestStep(b, test_module, target, optimize, sqlite_lib, ckdl_lib, vendored);
    }
}

const TestModule = struct {
    name: []const u8,
    path: []const u8,
};

fn linkSystemLibraries(artifact: *std.Build.Step.Compile) void {
    artifact.linkLibC();
}

fn createTestStep(
    b: *std.Build,
    test_module: TestModule,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite_lib: *std.Build.Step.Compile,
    ckdl_lib: *std.Build.Step.Compile,
    deps: VendoredDeps,
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
            break :blk mod;
        },
    });
    addVendoredIncludePaths(test_exe, b, deps);
    linkSystemLibraries(test_exe);
    test_exe.linkLibrary(sqlite_lib);
    test_exe.linkLibrary(ckdl_lib);
    addVendoredObjectFiles(test_exe, b, deps);

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

fn addVendoredIncludePaths(target: anytype, b: *std.Build, deps: VendoredDeps) void {
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
    artifact: *std.Build.Step.Compile,
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
    sqlite_lib.linkLibC();
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
    ckdl_lib.linkLibC();
    return ckdl_lib;
}

fn downloadVendorSource(b: *std.Build, source: VendorSource) std.Build.LazyPath {
    const download = b.addSystemCommand(&.{
        "sh",
        "-ceu",
        \\url="$1"
        \\expected="$2"
        \\out="$3"
        \\
        \\if command -v curl >/dev/null 2>&1; then
        \\  curl -L --fail --retry 3 -o "$out" "$url"
        \\elif command -v wget >/dev/null 2>&1; then
        \\  wget -O "$out" "$url"
        \\else
        \\  echo "need curl or wget to fetch vendor source: $url" >&2
        \\  exit 1
        \\fi
        \\
        \\if command -v sha256sum >/dev/null 2>&1; then
        \\  set -- $(sha256sum "$out")
        \\elif command -v shasum >/dev/null 2>&1; then
        \\  set -- $(shasum -a 256 "$out")
        \\else
        \\  echo "need sha256sum or shasum to verify vendor source: $out" >&2
        \\  exit 1
        \\fi
        \\
        \\actual="$1"
        \\if [ "$actual" != "$expected" ]; then
        \\  echo "sha256 mismatch for $out" >&2
        \\  echo "expected: $expected" >&2
        \\  echo "actual:   $actual" >&2
        \\  rm -f "$out"
        \\  exit 1
        \\fi
        ,
        "vendor-fetch",
    });
    download.addArg(source.url);
    download.addArg(source.sha256);
    return download.addOutputFileArg(source.archive_basename);
}

fn unpackVendorSourceTree(b: *std.Build, spec: SourceTreeBootstrap) SourceTree {
    const tarball = downloadVendorSource(b, spec.source);
    const unpack_script = b.fmt(
        \\tarball="$1"
        \\out="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\
        \\tar {s} "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\cp -R "$src/." "$out"
    ,
        .{
            spec.source.archive_kind.tarExtractFlag(),
            spec.source.source_dirname,
        },
    );
    const unpack = b.addSystemCommand(&.{ "sh", "-ceu", unpack_script, spec.step_name });
    unpack.addFileArg(tarball);

    return .{
        .root = unpack.addOutputDirectoryArg(spec.output_dirname),
    };
}

fn appendCMakeFlags(b: *std.Build, flags: []const []const u8) []const u8 {
    var script = std.ArrayList(u8){};
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
    var script = std.ArrayList(u8){};
    for (args) |arg| {
        script.appendSlice(b.allocator, "\nset -- \"$@\" ") catch @panic("OOM");
        appendShellQuotedArg(&script, b.allocator, arg);
    }
    return script.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn bootstrapCMakePrefix(b: *std.Build, spec: CMakeBootstrap) BootstrappedPrefix {
    const tarball = downloadVendorSource(b, spec.source);
    const cmake_flags = appendCMakeFlags(b, spec.cmake_flags);
    const source_subdir = spec.cmake_source_subdir orelse "";
    const source_suffix = if (source_subdir.len == 0)
        ""
    else
        b.fmt("/{s}", .{source_subdir});
    const bootstrap_script = b.fmt(
        \\tarball="$1"
        \\prefix="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\
        \\tar {s} "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}{s}"
        \\build="$tmpdir/build"
        \\
        \\cmake -S "$src" -B "$build"{s}
        \\cmake --build "$build"
        \\cmake --install "$build" --prefix "$prefix"
    ,
        .{
            spec.source.archive_kind.tarExtractFlag(),
            spec.source.source_dirname,
            source_suffix,
            cmake_flags,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, spec.step_name });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg(spec.output_dirname);

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapAutotoolsPrefix(b: *std.Build, spec: AutotoolsBootstrap) BootstrappedPrefix {
    const tarball = downloadVendorSource(b, spec.source);
    const configure_args = appendShellSetArgs(b, spec.configure_args);
    const bootstrap_script = b.fmt(
        \\tarball="$1"
        \\prefix="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\
        \\tar {s} "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" --prefix="$prefix" --libdir="$prefix/lib"{s}
        \\"$@"
        \\make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\make install
    ,
        .{
            spec.source.archive_kind.tarExtractFlag(),
            spec.source.source_dirname,
            configure_args,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, spec.step_name });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg(spec.output_dirname);

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}

fn bootstrapZlib(b: *std.Build) BootstrappedPrefix {
    return bootstrapCMakePrefix(b, .{
        .step_name = "vendor-bootstrap-zlib",
        .output_dirname = "zlib-ng-prefix",
        .source = vendorSource(.zlib),
        .cmake_flags = &.{
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DZLIB_COMPAT=ON",
            "-DZLIB_ENABLE_TESTS=OFF",
            "-DZLIBNG_ENABLE_TESTS=OFF",
        },
    });
}

fn bootstrapMbedTls(b: *std.Build) BootstrappedPrefix {
    return bootstrapCMakePrefix(b, .{
        .step_name = "vendor-bootstrap-mbedtls",
        .output_dirname = "mbedtls-prefix",
        .source = vendorSource(.mbedtls),
        .cmake_flags = &.{
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DENABLE_PROGRAMS=OFF",
            "-DENABLE_TESTING=OFF",
            "-DUSE_STATIC_MBEDTLS_LIBRARY=ON",
            "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
        },
    });
}

fn bootstrapLibsodium(b: *std.Build) BootstrappedPrefix {
    return bootstrapAutotoolsPrefix(b, .{
        .step_name = "vendor-bootstrap-libsodium",
        .output_dirname = "libsodium-prefix",
        .source = vendorSource(.libsodium),
        .configure_args = &.{
            "--disable-shared",
            "--enable-static",
            "--enable-minimal",
        },
    });
}

fn bootstrapZstd(b: *std.Build) BootstrappedPrefix {
    return bootstrapCMakePrefix(b, .{
        .step_name = "vendor-bootstrap-zstd",
        .output_dirname = "zstd-prefix",
        .source = vendorSource(.zstd),
        .cmake_source_subdir = "build/cmake",
        .cmake_flags = &.{
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DZSTD_BUILD_PROGRAMS=OFF",
            "-DZSTD_BUILD_SHARED=OFF",
            "-DZSTD_BUILD_STATIC=ON",
            "-DZSTD_BUILD_TESTS=OFF",
        },
    });
}

fn bootstrapLzma(b: *std.Build) BootstrappedPrefix {
    return bootstrapAutotoolsPrefix(b, .{
        .step_name = "vendor-bootstrap-lzma",
        .output_dirname = "lzma-prefix",
        .source = vendorSource(.lzma),
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
    });
}

fn bootstrapBzip2(b: *std.Build) BootstrappedPrefix {
    const source = vendorSource(.bzip2);
    const tarball = downloadVendorSource(b, source);
    const bootstrap_script = b.fmt(
        \\tarball="$1"
        \\prefix="$2"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\
        \\tar {s} "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\cd "$src"
        \\make -f Makefile-libbz2_so clean >/dev/null 2>&1 || true
        \\make \
        \\  CC=cc \
        \\  AR=ar \
        \\  RANLIB=ranlib \
        \\  CFLAGS=-O2\ -fPIC \
        \\  libbz2.a
        \\mkdir -p "$prefix/lib" "$prefix/include"
        \\cp libbz2.a "$prefix/lib/libbz2.a"
        \\cp bzlib.h "$prefix/include/bzlib.h"
    ,
        .{
            source.archive_kind.tarExtractFlag(),
            source.source_dirname,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-bzip2" });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg("bzip2-prefix");

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
) BootstrappedPrefix {
    const source = vendorSource(.libarchive);
    const tarball = downloadVendorSource(b, source);
    const bootstrap_script = b.fmt(
        \\tarball="$1"
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
        \\
        \\tar {s} "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" \
        \\  --prefix="$prefix" \
        \\  --libdir="$prefix/lib" \
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
        \\  LDFLAGS=-L"$zlib_prefix/lib"\ -L"$bzip2_prefix/lib"\ -L"$zstd_prefix/lib"\ -L"$lzma_prefix/lib"
        \\"$@"
        \\make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\make install
    ,
        .{
            source.archive_kind.tarExtractFlag(),
            source.source_dirname,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-libarchive" });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg("libarchive-prefix");
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
) BootstrappedPrefix {
    const source = vendorSource(.curl);
    const tarball = downloadVendorSource(b, source);
    const bootstrap_script = b.fmt(
        \\tarball="$1"
        \\prefix="$2"
        \\zlib_prefix="$(realpath "$3")"
        \\mbedtls_prefix="$(realpath "$4")"
        \\zstd_prefix="$(realpath "$5")"
        \\tmpdir="$(mktemp -d)"
        \\cleanup() {{
        \\  rm -rf "$tmpdir"
        \\}}
        \\trap cleanup EXIT INT TERM
        \\
        \\tar {s} "$tarball" -C "$tmpdir"
        \\src="$tmpdir/{s}"
        \\build="$tmpdir/build"
        \\mkdir -p "$build"
        \\cd "$build"
        \\
        \\set -- "$src/configure" \
        \\  --prefix="$prefix" \
        \\  --libdir="$prefix/lib" \
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
        \\  --with-mbedtls="$mbedtls_prefix" \
        \\  --with-zlib="$zlib_prefix" \
        \\  --with-zstd="$zstd_prefix" \
        \\  CFLAGS=-Os\ -fPIC \
        \\  CPPFLAGS=-D_GNU_SOURCE\ -I"$zlib_prefix/include"\ -I"$mbedtls_prefix/include"\ -I"$zstd_prefix/include" \
        \\  LDFLAGS=-L"$zlib_prefix/lib"\ -L"$mbedtls_prefix/lib"\ -L"$zstd_prefix/lib"
        \\"$@"
        \\make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        \\make install
    ,
        .{
            source.archive_kind.tarExtractFlag(),
            source.source_dirname,
        },
    );
    const bootstrap = b.addSystemCommand(&.{ "sh", "-ceu", bootstrap_script, "vendor-bootstrap-curl" });
    bootstrap.addFileArg(tarball);
    const prefix = bootstrap.addOutputDirectoryArg("curl-prefix");
    bootstrap.addDirectoryArg(zlib.prefix);
    bootstrap.addDirectoryArg(mbedtls.prefix);
    bootstrap.addDirectoryArg(zstd.prefix);

    return .{
        .prefix = prefix,
        .include_dir = prefix.path(b, "include"),
    };
}
