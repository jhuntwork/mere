# Dinit Build Issue — `mere dev build --root` namespace exec failure

**Status: RESOLVED.** Root cause found and fixed — profile symlinks embedded the
physical `--root` prefix and dangled inside the build namespace. See
[Resolution](#resolution) below.

## Summary

`mere dev build` with `--root` successfully enters the build namespace but fails to execute the build script. The build log is created but remains empty (0 bytes), indicating `/bin/sh` never actually runs despite being present in the profile.

## Environment

- Machine: jingqi (Mere Linux, real hardware — not a container)
- Mere version: v0.16.0 (includes the `mere_root` bind-mount fix from PR #124)
- Kernel: no overlay errors in dmesg (the v0.16.0 fix resolved that)

## Command

```
/home/jeremy/swamp/.swamp/mere-dev/bin/mere-0.16.0-linux-x86_64 \
  --root /home/jeremy/swamp/.swamp/mere-dev/root \
  dev build /home/jeremy/codeberg.org/merelinux/recipes/recipes/core/dinit/recipe.kdl
```

## What works

- Config loads correctly from `{root}/mere/config.kdl`
- Source fetches and unpacks (cached after first run)
- Dependencies resolve (15 packages including busybox, llvm, make, m4, mimalloc-dev, musl-dev)
- All packages install and verify signatures
- Profile links successfully (6738 entries, 288ms)
- `/bin/sh` symlink exists in the profile at the expected location
- The build workspace is created and preserved on failure

## What failed (original symptom)

- The build script produces zero output to `build.log`
- Exit code 1 from the build phase
- `build_profile=<none>` in the error details
- Even `echo` at the first line of the script never executes

## Resolution

### Root cause

Profile symlinks were created with **absolute store targets that embed the
physical `--root` prefix**. For the failing build, the profile's `bin/sh` pointed
at:

```
/home/jeremy/swamp/.swamp/mere-dev/root/mere/store/ec124…-busybox-1.37.0/bin/sh
```

The build namespace bind-mounts `{root}/mere` onto `/mere` (see
`namespace.buildSyntheticRoot`), so the store is reachable inside the namespace at
`/mere/store/…` — **not** at its host-absolute `{root}/mere/store/…` path. Inside
the namespace that host-absolute path lands in the empty `/home` directory (build
mode does not mount `/home`), so `/bin/sh` was a dangling symlink. `execve("/bin/sh")`
then failed with `ENOENT` before the shell produced any output — a 0-byte
`build.log` and an exit-1 child. `handlePhaseFailure` nulls the build-profile
instance on a phase failure, which is why the diagnostic read `build_profile=<none>`.

### Why `mere shell --root` masked it

`mere shell --root … -- echo hello` worked with the *same* host-absolute symlinks,
by coincidence: `applyShellMounts` bind-mounts the host `/home` into the namespace,
and because `--root` (`/home/jeremy/swamp/.swamp/mere-dev/root`) lives *under*
`/home`, the store became visible inside the shell namespace at exactly its
host-absolute path. Build mode mounts only `{root}/mere → /mere` (plus a minimal
`/dev`, `/etc`, `/work`), so it got no such accident. Without `--root` at all,
everything worked because the physical path already is `/mere/store/…`.

### Fix

Profile symlink targets are now **logical** (`/mere/store/…`) rather than physical
(`{root}/mere/store/…`). The store is content-addressed at a stable logical prefix;
`--root` is purely a physical staging location that gets bind-mounted to `/mere`.
A logical target resolves in all three contexts — inside a build namespace, inside
`mere shell`, and on a booted system — because `/mere` is the store mount point in
each. When no `--root` is in effect (`root_path == "/"`) logical and physical are
identical.

Implementation:

- `src/store.zig` — new `toLogicalStorePath(allocator, root_path, physical)` that
  rewrites a leading `{root}/mere` to `/mere` (identity when `root_path == "/"`;
  leaves non-mere paths untouched).
- `src/profile.zig` — `applyRealization` (the single choke point for *all* profile
  symlink creation: shell profiles, system generations, and build-dependency
  profiles) translates the target to logical before writing the symlink. Boundary
  validation still runs against the physical path, so its integrity is unchanged.
- Tests: helper unit tests, a `--root` realization regression test
  (`buildProfile emits logical /mere/store symlink targets under --root staging`),
  and updated install/generation integration tests that now assert profile entries
  *exist and are backed by a real store object* (via `readlink`, which does not
  follow) rather than *following* the link on the host — logical targets only
  resolve where `/mere` is mounted.

Host-side consumers were audited to confirm safety: GC and `verify` compute liveness
from generation *manifests* (which keep physical `store_path`), never by readlinking
profile entries; `hash.calculateStoreContentHash` hashes the symlink target *string*
only (making the profile-tree cache key root-independent — a bonus). Nothing on the
host resolves profile store-target symlinks to physical paths.

### Verification

- `zig build test` → 712 pass, 1 skip (pre-existing).
- End-to-end `mere dev build --root` against the dinit recipe: `build.log` now
  contains real output, `/bin/sh` and `c++` resolve, configure passes, and the
  compiler runs. The build now fails only on an unrelated recipe/toolchain issue
  (`fatal error: 'utmpx.h' file not found` — musl lacks `<utmpx.h>`; dinit needs its
  utmp support disabled), which is out of scope for this namespace-exec bug.
- Confirmed the new build profile's `bin/sh` now points at
  `/mere/store/ec124…-busybox-1.37.0/bin/sh` (logical), not the `--root` path.

## Key files

- `src/store.zig` — `toLogicalStorePath` (logical/physical store-path mapping)
- `src/profile.zig` — `applyRealization` (emits logical symlink targets)
- `src/namespace.zig` — `buildSyntheticRoot`, `applyBuildMounts`, `applyShellMounts` (the `{root}/mere → /mere` bind mount and the shell-vs-build mount divergence)
- `src/build_orchestrator.zig` — builds `EnvOptions`, calls `namespace_runner`

## Recipe (for reference)

```kdl
recipe {
    name "dinit"
    version "0.22.1"
    release 1
    description "A service manager and init system with dependency support"
    url "https://github.com/davmac314/dinit"
    licenses "Apache-2.0"
    archs "aarch64" "x86_64"
    depends "busybox" \
            "llvm" \
            "make" \
            "m4" \
            "mimalloc-dev" \
            "musl-dev"
}
```
