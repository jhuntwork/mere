# Recipe Specification

This document provides a comprehensive guide to writing Mere Linux build recipes in KDL format.

## Overview

A recipe (`recipe.kdl`) defines how to build one or more packages from source. Recipes use KDL (KDL Document Language) syntax and support:

- Multiple source files (remote URLs or local files)
- Multi-phase builds (prepare, build, check, install)
- Multiple output packages from a single build
- Variable interpolation
- Custom environment variables per phase

## Basic Structure

Every recipe consists of:

1. **`recipe` node** (required) - Package metadata
2. **`source` nodes** (one or more) - Source files to download/include
3. **Phase nodes** (optional) - `prepare`, `build`, `check`, `install`
4. **`package` nodes** (one or more, required) - Output package definitions
5. **`vars` node** (optional) - Custom variables

## Complete Example

Here's a complete recipe showing all features:

```kdl
// Recipe metadata
recipe {
    name "busybox"
    version "1.37.0"
    release 1
    description "Tiny versions of common UNIX utilities built into a single binary"
    url "http://busybox.net"
    licenses "GPL"
    archs "aarch64" "x86_64"
    depends "linux-headers" "llvm" "make" "musl-dev" "patch"
    env CFLAGS="-Os -pipe"
}

// Custom variables (optional)
vars {
    major "1"
    custom-flag "-O2"
}

// Remote source with hash verification
source "http://busybox.net/downloads/${recipe.name}-${recipe.version}.tar.bz2" {
    blake3 "179c4567a112635be6cb442fd8e3ff95dd0e718facd0666f2426d94322110a8f"
}

// Local source files
source "poweroff.patch" {
    blake3 "0356be472dc11883a49c47a6f5c5263ab11a910151e92d60321d7f14db5940d3"
}

source "busybox-config" {
    blake3 "7d79a841eea928665affe33ef991006f020d3785342fb1e9ea28e83485f5eacf"
}

// Prepare phase (optional)
prepare {
    script r#"
        patch -Np1 -i "${MERE_SOURCES_DIR}/poweroff.patch"
        cp "${MERE_SOURCES_DIR}/busybox-config" .config
    "#
}

// Build phase
build {
    env LDFLAGS="-static"
    script r#"
        make CFLAGS="$CFLAGS -static" \
            HOSTCC=clang CC=clang
    "#
}

// Check phase (optional)
check {
    script r#"
        make test
    "#
}

// Install phase
install {
    script r#"
        make DESTDIR="${DESTDIR}" install
        install -d "${DESTDIR}/usr/share/man/man1"
        install -m0644 "docs/busybox.1" "${DESTDIR}/usr/share/man/man1/"
    "#
}

// Output package
package "busybox" {
    files "*"
}
```

## Node Reference

### `recipe` Node (Required)

The `recipe` node defines package metadata. All properties are specified as child nodes.

**Required properties:**

| Property | Type | Description | Example |
|----------|------|-------------|---------|
| `name` | string | Package name (lowercase, alphanumeric + hyphens) | `name "busybox"` |
| `version` | string | Package version | `version "1.37.0"` |
| `release` | integer | Release number (increment for recipe changes) | `release 1` |

**Optional properties:**

| Property | Type | Default | Description | Example |
|----------|------|---------|-------------|---------|
| `description` | string | "" | Human-readable description | `description "Tiny UNIX utilities"` |
| `url` | string | "" | Project homepage URL | `url "http://busybox.net"` |
| `licenses` | string(s) | [] | License identifiers (multiple allowed) | `licenses "GPL" "MIT"` |
| `archs` | string(s) | ["x86_64"] | Supported architectures | `archs "aarch64" "x86_64"` |
| `depends` | string(s) | [] | Build dependencies | `depends "make" "llvm"` |
| `env` | properties | {} | Environment variables for all phases | `env CC="clang"` |

**Example:**

```kdl
recipe {
    name "nginx"
    version "1.24.0"
    release 1
    description "High-performance HTTP server"
    url "https://nginx.org"
    licenses "BSD"
    archs "x86_64" "aarch64"
    depends "openssl-dev" "pcre2-dev" "zlib-ng-dev"
    env CC="clang" CFLAGS="-O2"
}
```

### `vars` Node (Optional)

Define custom variables for use in string interpolation.

**Syntax:**
```kdl
vars {
    major "20"
    minor "1"
    custom-flag "-O3"
}
```

**Usage:**
```kdl
source "https://example.org/v${vars.major}.${vars.minor}/file.tar.gz"
```

### `source` Node (Repeatable)

Defines a source file to download or include. The first argument is the URL or local filename.

**For remote sources:**

```kdl
source "https://example.org/file-${recipe.version}.tar.gz" {
    blake3 "abc123...64chars..."
}
```

**For local sources:**

```kdl
source "local-patch.diff" {
    blake3 "def456...64chars..."
}
```

**Properties:**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `blake3` | string | yes | BLAKE3 hash (64 hex chars) for verification |

**Notes:**
- Remote sources (http://, https://) are downloaded to cache
- Local sources are resolved relative to the recipe directory
- BLAKE3 hashes are required for all sources (remote and local)
- Sources are extracted/copied to `${MERE_SOURCES_DIR}` before build

### Phase Nodes

Build phases execute shell scripts in order. All phases are optional but typically you'll have at least `build` and `install`.

**Available phases (in execution order):**

1. **`prepare`** - Patch sources, configure, pre-build setup
2. **`build`** - Compile the software
3. **`check`** - Run tests (optional, can be skipped)
4. **`install`** - Install to `${DESTDIR}`

**Phase syntax:**

```kdl
<phase-name> {
    env KEY="value" KEY2="value2"  // Optional phase-specific env vars
    script r#"
        # Shell script here
        # Use r#"..."# for raw strings (no escaping needed)
    "#
}
```

**Example:**

```kdl
build {
    env CFLAGS="-O2" LDFLAGS="-s"
    script r#"
        ./configure --prefix=/usr
        make -j$(nproc)
    "#
}

install {
    script r#"
        make DESTDIR="${DESTDIR}" install
        install -d "${DESTDIR}/usr/share/doc/${recipe.name}"
        install -m644 README.md "${DESTDIR}/usr/share/doc/${recipe.name}/"
    "#
}
```

**Shell environment:**
- Phases execute with `/bin/sh -e -c "<script>"`
- `-e` flag causes abort on first failing command
- Must be POSIX sh compatible (no bash-isms)
- Working directory is `${MERE_BUILD_DIR}` by default

### `package` Node (Required, Repeatable)

Defines output packages. The first argument is the package name.

**Syntax:**

```kdl
package "<name>" {
    files "<pattern>" "<pattern>" ...
}
```

**Properties:**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `files` | string(s) | yes | `fnmatch(3)` patterns for files to include (relative to `${DESTDIR}`) |
| `strip` | boolean | no | Enable/disable automatic stripping of ELF binaries and static archives (default: `true`) |

**Stripping behavior:**

By default, all ELF binaries, shared libraries, and static archives are automatically stripped during packaging:
- Executables (ET_EXEC): `strip --strip-unneeded -R .comment -R .note`
- Shared libraries (ET_DYN): `strip --strip-unneeded -R .comment -R .note`
- Static archives (.a) and relocatables (ET_REL): `strip --strip-debug`

Set `strip false` on a package node to disable this for that package (e.g., for debug packages or packages where symbols must be preserved).

**File patterns:**
- Patterns are relative to `${DESTDIR}` (no leading slash)
- Patterns use POSIX `fnmatch(3)` with `FNM_PATHNAME`
- `*` does not match `/` (use additional path segments if needed)
- `?` and `[...]` are supported
- A pattern ending with `/` is shorthand for recursive directory inclusion
- `files` patterns support variable interpolation (for example `${recipe.version}` and `${vars.name}`)
- Multiple patterns can be specified
- Each listed pattern must match at least one file or packaging fails

**Examples:**

```kdl
// Single package with all files
package "myapp" {
    files "*"
}

// Split package: runtime
package "nginx" {
    files "usr/bin/nginx" \
          "usr/lib/nginx/" \
          "etc/nginx/*"
}

// Split package: development files
package "nginx-dev" {
    files "usr/include/" \
          "usr/lib/*.a" \
          "usr/lib/pkgconfig/*"
}

// Package for configuration files
package "myapp-config" {
    files "etc/myapp/*"
}

// Package that preserves debug symbols
package "myapp-dbg" {
    strip false
    files "usr/lib/debug/*"
}
```

## Variable Interpolation

Variables can be used in strings with `${...}` syntax.

**Available variables:**

### Recipe Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `${recipe.name}` | Recipe name | `busybox` |
| `${recipe.version}` | Recipe version | `1.37.0` |
| `${recipe.release}` | Release number | `1` |
| `${pkgver}` | Alias for `${recipe.version}` | `1.37.0` |

### Custom Variables

| Variable | Description |
|----------|-------------|
| `${vars.name}` | Custom variable from `vars` node |

### Build Environment Variables

These are set by the build system and available in phase scripts:

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `${MERE_BUILD_DIR}` | Build/source working directory for phase scripts | `/mere/build/busybox-1.37.0-1-a3f2b1c9/build-src` |
| `${MERE_SOURCES_DIR}` | Directory containing downloaded/copied sources | `/mere/build/busybox-1.37.0-1-a3f2b1c9/sources` |
| `${MERE_DESTDIR}` | Install destination root | `/mere/build/busybox-1.37.0-1-a3f2b1c9/dest` |
| `${DESTDIR}` | Alias for `${MERE_DESTDIR}` | `/mere/build/busybox-1.37.0-1-a3f2b1c9/dest` |
| `${PREFIX}` | Install prefix | `/usr` |

**Usage examples:**

```kdl
// In source URLs
source "https://example.org/${recipe.name}-${recipe.version}.tar.gz"

// In scripts
build {
    script r#"
        cd "${MERE_BUILD_DIR}/${recipe.name}-${recipe.version}"
        ./configure --prefix=/usr
        make
    "#
}

install {
    script r#"
        make DESTDIR="${DESTDIR}" install
        install -d "${DESTDIR}/usr/share/doc/${recipe.name}"
    "#
}
```

## Multi-Package Recipes

A single recipe can produce multiple packages (split packages). This is useful for separating runtime files from development files.

**Key points:**
- Build phases (`prepare`, `build`, `check`) run **once**, shared across all outputs
- Install phase runs **once**, installing everything to `${DESTDIR}`
- Each `package` node defines which files go into which output package

**Example:**

```kdl
recipe {
    name "llvm"
    version "20.1.8"
    release 1
    depends "cmake" "ninja"
}

source "https://github.com/llvm/llvm-project/releases/download/llvmorg-${recipe.version}/llvm-project-${recipe.version}.src.tar.xz" {
    blake3 "6898f963c8e938981e6c4a302e83ec5beb4630147c7311183cf61069af16333d"
}

build {
    script r#"
        cmake -G Ninja -B build -S llvm \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr
        ninja -C build
    "#
}

install {
    script r#"
        DESTDIR="${DESTDIR}" ninja -C build install
    "#
}

// Runtime package
package "llvm" {
    files "usr/bin/*" \
          "usr/lib/libLLVM*.so*" \
          "usr/lib/libclang.so*"
}

// Development package
package "llvm-dev" {
    files "usr/include/" \
          "usr/lib/*.a" \
          "usr/lib/cmake/" \
          "usr/lib/pkgconfig/*"
}
```

## Common Patterns

### Pattern: Autotools Build

```kdl
build {
    script r#"
        ./configure --prefix=/usr \
            --sysconfdir=/etc \
            --localstatedir=/var
        make
    "#
}

install {
    script r#"
        make DESTDIR="${DESTDIR}" install
    "#
}
```

### Pattern: CMake Build

```kdl
build {
    script r#"
        cmake -B build -S . \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr
        cmake --build build
    "#
}

install {
    script r#"
        DESTDIR="${DESTDIR}" cmake --install build
    "#
}
```

### Pattern: Meson Build

```kdl
build {
    script r#"
        meson setup build \
            --prefix=/usr \
            --buildtype=release
        meson compile -C build
    "#
}

install {
    script r#"
        DESTDIR="${DESTDIR}" meson install -C build
    "#
}
```

### Pattern: Go Build

```kdl
build {
    env CGO_ENABLED="0"
    script r#"
        go build -o myapp \
            -ldflags="-s -w" \
            ./cmd/myapp
    "#
}

install {
    script r#"
        install -Dm755 myapp "${DESTDIR}/usr/bin/myapp"
    "#
}
```

### Pattern: Python Package

```kdl
build {
    script r#"
        python3 -m build --wheel --no-isolation
    "#
}

install {
    script r#"
        pip install --root="${DESTDIR}" --prefix=/usr \
            --no-deps dist/*.whl
    "#
}
```

### Pattern: Applying Patches

```kdl
source "fix-build.patch" {
    blake3 "abc123..."
}

prepare {
    script r#"
        # Apply patch from MERE_SOURCES_DIR
        patch -Np1 -i "${MERE_SOURCES_DIR}/fix-build.patch"

        # Or use sed for simple changes
        sed -i 's/old/new/g' Makefile
    "#
}
```

### Pattern: Installing Configuration Files

```kdl
install {
    script r#"
        # Install main files
        make DESTDIR="${DESTDIR}" install

        # Install config files
        install -d "${DESTDIR}/etc/myapp"
        install -m644 "${MERE_SOURCES_DIR}/myapp.conf" "${DESTDIR}/etc/myapp/"

        # Install s6 service files
        install -d "${DESTDIR}/etc/s6/services/available/myapp"
        install -m755 "${MERE_SOURCES_DIR}/myapp-service" \
            "${DESTDIR}/etc/s6/services/available/myapp/run"
    "#
}
```

### Pattern: Static Linking

```kdl
recipe {
    env CFLAGS="-static" LDFLAGS="-static"
}

build {
    script r#"
        make CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
    "#
}
```

## Best Practices

### 1. Use Raw Strings for Scripts

Always use raw strings (`r#"..."#`) for shell scripts to avoid escaping issues:

```kdl
// Good
build {
    script r#"
        echo "Building ${recipe.name}"
    "#
}

// Bad (requires escaping)
build {
    script "
        echo \"Building \${recipe.name}\"
    "
}
```

### 2. Verify Source Hashes

Always include BLAKE3 hashes for all sources:

```kdl
// Good
source "https://example.org/file.tar.gz" {
    blake3 "abc123...64chars..."
}

// Bad (will fail)
source "https://example.org/file.tar.gz"
```

### 3. Use Explicit Paths

Use `${DESTDIR}` and other variables explicitly:

```kdl
// Good
install {
    script r#"
        make DESTDIR="${DESTDIR}" install
        install -d "${DESTDIR}/usr/share/doc/${recipe.name}"
    "#
}

// Bad (implicit paths)
install {
    script r#"
        make install
        install -d /usr/share/doc/${recipe.name}
    "#
}
```

### 4. Handle Multiple Architectures

Use `archs` to specify supported architectures:

```kdl
recipe {
    archs "x86_64" "aarch64"
}
```

### 5. Declare All Dependencies

List all build-time dependencies:

```kdl
recipe {
    depends "make" "llvm" "pkgconf" "openssl-dev"
}
```

### 6. Use Meaningful Package Names

For split packages, use clear suffixes:

```kdl
package "myapp" {        // Runtime
    files "usr/bin/*" "usr/lib/*.so*"
}

package "myapp-dev" {    // Development
    files "usr/include/" "usr/lib/*.a"
}

package "myapp-doc" {    // Documentation
    files "usr/share/doc/" "usr/share/man/"
}
```

### 7. Test Your Recipe

Always test the build:

```sh
# Validate the recipe
mere dev validate recipe.kdl

# Build the recipe
mere dev build recipe.kdl

# Check the output
mere dev inspect <package-file>
```

### 8. Don't Worry About Duplicate Files

If your recipe installs duplicate files (e.g., multiple copies of the same binary), don't worry about it. The build system automatically deduplicates identical files by replacing them with hardlinks before creating the package archive. This happens transparently and requires no action from recipe authors.

**Example**: Busybox packages install 300+ utilities that are all the same binary. The recipe just installs them normally, and deduplication reduces the package from ~30MB to ~1MB automatically.

## Troubleshooting

### Build Fails with "command not found"

**Problem:** Missing build dependency

**Solution:** Add the required tool to `depends`:

```kdl
recipe {
    depends "make" "llvm" "pkgconf"
}
```

### Source Hash Mismatch

**Problem:** Downloaded file doesn't match expected hash

**Solution:** Recompute the hash:

```sh
mere dev hash file.tar.gz
```
or
```sh
b3sum file.tar.gz
```

### Files Not Included in Package

**Problem:** `files` pattern doesn't match

**Solution:** Check the pattern and `${DESTDIR}` contents:

```kdl
// Use fnmatch-compatible patterns:
// - `*` does not cross `/`
// - trailing `/` means recursive directory inclusion
package "myapp" {
    files "usr/bin/*" "usr/lib/" "usr/share/myapp/"
}
```

### Phase Script Fails

**Problem:** Shell script exits with error

**Solution:**
- Check the script for errors
- Remember: `/bin/sh -e` aborts on first error
- Use `set +e` temporarily if you need to ignore errors:

```kdl
build {
    script r#"
        # This command might fail, but we don't care
        set +e
        optional-command || true
        set -e

        # This command must succeed
        required-command
    "#
}
```

## See Also

- `docs/design/specification-details.md` - Build environment details
- `docs/design/namespaces.md` - Build isolation design
