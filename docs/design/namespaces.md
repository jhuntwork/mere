# Build Isolation Model (Mount-Based)

## Overview

Mere build execution uses **Linux namespaces** (user namespace + mount namespace) with **bind mounts** and **chroot** to create an isolated build environment. A synthetic root filesystem is constructed by bind-mounting profile directories and `/mere`, then chrooting into it.

This document describes both **build isolation** and **shell isolation**, which share the same namespace mechanism with different mount policies.

## Design Goals

1. **Single namespace mechanism** for both `mere shell` and `mere dev build`
2. **Host mount table is never mutated** (mount namespace isolates all changes)
3. **Deterministic inputs** for builds (no host PATH or host `/etc` leakage)
4. **Debuggable failures** via preserved workspace artifacts
5. **Two modes** with different isolation levels (shell vs build)

## Environment Modes

### Shell Mode
- "Hosty" environment with access to host `/home`, `/var`, `/run`, `/dev`
- Overlayfs `/etc` (with fallback to read-only bind mount)
- `/mere` bind-mounted read-write so `mere install` works from inside
- Feels like the host but with a different `/usr` worldview from the profile

### Build Mode
- "Clean lab" environment with minimal host exposure
- Only the workspace directory is accessible (bound to `/work`)
- Generated minimal `/etc` (not host `/etc`)
- Minimal `/dev` via tmpfs with essential device nodes
- `/mere` bind-mounted read-only
- tmpfs for `/var` and `/run`

## Namespace Setup

Build and shell execution both follow the same sequence:

1. **Create user namespace** (`unshare(CLONE_NEWUSER)`) with uid/gid mapping
2. **Create mount namespace** (`unshare(CLONE_NEWNS)`)
3. **Make all mounts private** (`mount(MS_REC | MS_PRIVATE)` on `/`)
4. **Create session directory** under `$XDG_RUNTIME_DIR/mere/env/<id>/` or `/tmp/mere/env/<id>/`
5. **Build synthetic root** at `<session>/root/`
6. **Apply mode-specific mounts** (shell or build)
7. **Mount `/proc`** and tmpfs `/tmp` in the synthetic root
8. **Chroot** into the synthetic root
9. **Drop privileges** back to original uid/gid
10. **Execute command** (or return for orchestrated builds)

## Synthetic Root Construction

The synthetic root (`<session>/root/`) is built by:

1. Creating base directories: `etc`, `home`, `tmp`, `dev`, `proc`, `run`, `var`, `mere`
2. For build mode: also creating `work`
3. Bind-mounting profile directories (`bin`, `sbin`, `lib`, `usr`) from the profile root into the synthetic root (read-only)
4. Bind-mounting `/mere` into the synthetic root (read-only for builds, read-write for shell)

Profile directories contain symlinks into `/mere/store/...` paths. Since `/mere` is also bind-mounted, these symlinks resolve correctly inside the chroot.

## Build Mode Mounts

For build execution, the following mounts are applied after the synthetic root is built:

| Mount | Source | Target | Type | Access |
|-------|--------|--------|------|--------|
| Workspace | host workspace dir | `/work` | bind | read-write |
| /var | — | `/var` | tmpfs | read-write |
| /run | — | `/run` | tmpfs | read-write |
| /etc | generated minimal etc | `/etc` | bind | read-write |
| /dev | — | `/dev` | tmpfs + device nodes | limited |
| /proc | — | `/proc` | proc | read-only |
| /tmp | — | `/tmp` | tmpfs | read-write |

### Minimal /dev

Build mode creates a tmpfs at `/dev` with essential device nodes:
- `/dev/null` (1,3)
- `/dev/zero` (1,5)
- `/dev/random` (1,8)
- `/dev/urandom` (1,9)
- `/dev/tty` (5,0)

### Minimal /etc

Build mode generates a minimal `/etc` with:
- `/etc/passwd` — root and nobody entries
- `/etc/group` — root and nobody entries
- `/etc/hosts` — localhost mapping
- `/etc/resolv.conf` — copied from host if available

Host `/etc` is never exposed to build scripts.

## Build Workspace Layout

Each build allocates a workspace under `${root}/mere/build/`:

```
${root}/mere/build/<name>-<version>-<release>-<uuid>/
├── build-src/      # MERE_BUILD_DIR - source unpack + phase working directory
├── sources/  # MERE_SOURCES_DIR - downloaded/copied source artifacts
├── dest/     # MERE_DESTDIR / DESTDIR - install destination root
└── profile/  # Build dependency environment (symlinks into store)
```

This workspace directory is bind-mounted to `/work` inside the chroot, so inside the namespace:

- `MERE_BUILD_DIR` = `/work/build-src`
- `MERE_SOURCES_DIR` = `/work/sources`
- `MERE_DESTDIR` = `/work/dest`
- `DESTDIR` = `${MERE_DESTDIR}`
- `PREFIX` = `/usr`

On failure, the workspace path MUST be printed prominently and preserved for debugging.

## Environment Variables

### PATH Rules

`PATH` MUST be set to a deterministic value and MUST NOT inherit the host `PATH`.

`PATH` MUST reference only standard paths inside the chrooted build root (e.g., `/usr/bin:/bin`).

### Build Variables

Inside the chrooted environment:

- `MERE_BUILD_DIR` MUST be `/work/build-src`
- `MERE_SOURCES_DIR` MUST be `/work/sources`
- `MERE_DESTDIR` MUST be `/work/dest`
- `DESTDIR` MUST be set to `${MERE_DESTDIR}`
- `PREFIX` MUST be set to `/usr`

## Execution Model

### Build Orchestration

The build orchestrator uses `forkAndEnterEnv()` which:

1. Creates pipes for stdout/stderr capture
2. Forks a child process
3. Child enters the namespace environment and executes the phase script
4. Parent polls pipes and forwards output (to terminal and log file)
5. Parent waits for child exit and returns the exit status

Each build phase (`prepare`, `build`, `check`, `install`) is executed as a separate `forkAndEnterEnv()` invocation with `/bin/sh -e -c "<phase script>"`.

### Shell Sessions

`mere shell` uses `enterEnv()` which enters the namespace and exec's the shell directly (does not return on success).

## Session Directory

Namespace sessions use a temporary directory structure:

```
$XDG_RUNTIME_DIR/mere/env/<session-id>/
├── root/       # Synthetic root filesystem (mount points)
├── etc-upper/  # Overlayfs upper dir (shell mode only)
├── etc-work/   # Overlayfs work dir (shell mode only)
└── etc-gen/    # Generated /etc (build mode only)
```

Session directories are ephemeral and cleaned up with the mount namespace when the process exits.

## Security Notes

- These namespace environments are for **correctness and isolation**, not a security boundary against hostile users
- The mount namespace ensures the host mount table is never mutated
- User namespace provides sufficient privilege for chroot without requiring root
- Build mode isolation prevents host filesystem leakage into builds
