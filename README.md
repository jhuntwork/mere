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
curl -Lo mere https://github.com/jhuntwork/mere/releases/download/v0.21.0/mere-0.21.0-linux-x86_64

# aarch64
curl -Lo mere https://github.com/jhuntwork/mere/releases/download/v0.21.0/mere-0.21.0-linux-aarch64

sudo install -m 755 mere /usr/local/bin/
```

### 2. Initialize

Preview what `mere store init` will create, then apply it:

```sh
sudo mere store init --dry-run
sudo mere store init
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
# search for packages
mere search python

# install more packages
mere install -p test busybox curl git

# see what's in your profile
mere profile list

# inspect the store
ls /mere/store/

# store maintenance
mere store clean --dry-run
mere store verify
```

## Service Management

On a native Mere system, `mere` provides integrated service management as
top-level commands. The active provider is selected in `/mere/config.kdl`;
s6-rc and dinit both have lifecycle and introspection adapters.

```kdl
settings {
    init-provider "dinit" // or "s6-rc"
}
```

```sh
mere status              # show all services with status
mere status nginx        # detailed view for a service
mere enable nginx        # add to boot set
mere start nginx         # bring up now
mere stop nginx          # bring down now
mere restart nginx       # stop and start
mere reload nginx        # signal config reload
mere disable nginx       # remove from boot set
mere logs nginx          # view service logs
```

Recipe service declarations are normalized into `.mere/meta.kdl` and carried
in packages independently of the target init provider. During system profile
realization, dinit materializes the configured package-owned service files
under `/usr/share/dinit.d`; `/etc/dinit.d` remains administrator-owned.
Provider-specific build-time service artifacts are retained temporarily for
backward compatibility while profile reconciliation is completed. `mere
enable/disable` change boot intent only; `mere start/stop` operate on live
state only.

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
- [Service Management](docs/design/service-management.md) — service architecture, s6-rc, and dinit integration
