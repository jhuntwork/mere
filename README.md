# mere

`mere` is the package manager and system-management tool for
[Mere Linux](https://merelinux.org), a lightweight Linux distribution built on
musl libc.

It takes the properties that make Nix compelling — an immutable package store,
atomic upgrades, build isolation, safe rollbacks — and keeps them close to
traditional Unix instead of fighting it. The system is designed to be legible:
everything lives on disk in a form you can read, inspect, and understand.

## How It Works

Packages are stored as immutable objects in a content-addressed store at
`/mere/store`. Each object is identified by a BLAKE3 hash of its contents, so
identity is unambiguous and multiple versions coexist safely.

Profiles are symlink trees that reference store objects. A system profile
defines which packages are visible; activating a new configuration creates a
new generation and swaps a single symlink. Rollback is the same operation in
reverse.

On a native Mere system, the root directories (`/bin`, `/lib`, `/usr/bin`, ...)
are themselves symlinks into the active profile, so switching generations
changes the entire system view atomically.

## Design Principles

- **Immutable store** — package payloads live in a content-addressed store; changing contents produces a new object
- **Generation-based profiles** — every generation is a fully realized tree of selected store objects
- **Atomic switching** — activation is one pointer swap after the target generation is built
- **Isolated builds** — packages are built in a synthetic root via mount namespaces and chroot
- **Explicit trust** — repos and packages are accepted only when Ed25519 signatures verify against trusted keys
- **Filesystem as truth** — store objects, profiles, manifests, and repository databases are all inspectable on disk

## Quick Start

```sh
# install packages
mere install busybox curl

# remove a package
mere uninstall curl

# build a package from a recipe
mere dev build recipe.kdl

# roll back to a previous generation
mere generation activate 15

# garbage-collect unreferenced store objects
mere gc
```

## Building from Source

Requires [Zig](https://ziglang.org/) 0.16. The build system automatically
fetches and builds all C library dependencies (libsodium, zstd, libarchive,
libcurl, sqlite3). Host prerequisites: musl, LLVM, busybox (for sha256sum),
curl, and cmake.

```sh
zig build
zig build test
```

## Status

Pre-release. The core package manager is functional and manages a real Mere
Linux system, but the CLI surface and some subsystems are still stabilizing.

## Documentation

- [Specification Details](docs/design/specification-details.md) — full system specification
- [Recipe Specification](docs/design/recipe_spec.md) — guide to writing build recipes
- [Build Isolation Model](docs/design/namespaces.md) — namespace and chroot design

## License

MIT
