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

## Try It

`mere` is a statically linked binary that runs on any Linux system. You can
try it alongside your existing distribution — everything lives under `/mere`
and won't interfere with your host system.

### 1. Download

Grab the latest release for your architecture:

```sh
# x86_64
curl -Lo mere https://codeberg.org/merelinux/mere/releases/download/v0.8.0/mere-0.8.0-linux-x86_64

# aarch64
curl -Lo mere https://codeberg.org/merelinux/mere/releases/download/v0.8.0/mere-0.8.0-linux-aarch64

sudo install -m 755 mere /usr/local/bin/
```

### 2. Initialize

Preview what `mere init` will create, then apply it:

```sh
sudo mere init --dry-run
sudo mere init
```

Add a basic config for the official repository and its public key:

```sh
sudo curl -so /mere/config.kdl https://pkgs.merelinux.org/config.kdl
sudo curl -so /mere/keys/mere.pub https://pkgs.merelinux.org/mere.pub
```

### 3. Create a profile and install packages

```sh
mere profile create test
mere install -p test python
```

This fetches Python and its dependencies from the Mere repository, verifies
signatures, places everything in the content-addressed store at `/mere/store`,
and realizes the profile.

### 4. Try it out

```sh
mere shell -p test
python3 --version
```

`mere shell` drops you into an interactive shell with the profile's packages
available. Type `exit` to return to your host environment.

### 5. Explore

```sh
# see what's in your profile
mere profile list

# install more packages
mere install -p test busybox curl git

# inspect the store
ls /mere/store/

# build a package from a recipe
mere dev build recipe.kdl

# roll back to a previous system generation
sudo mere generation list
sudo mere generation activate 1
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
