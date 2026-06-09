# Service Management

## Overview

Service management is integrated into `mere` as top-level commands. The CLI
surface and recipe format are provider-neutral; runtime service operations go
through `services.zig`, and package-time service metadata is translated by the
active artifact generator.

The default and currently implemented provider is s6-rc. Service definitions
in recipes are pure KDL metadata. Mere's packager translates them into raw
s6-rc source directories at build time when the active provider is s6-rc.

The active provider is configured in `/mere/config.kdl`:

```kdl
settings {
    init-provider "s6-rc"
}
```

`dinit` is a recognized provider name for the provider-selection boundary, but
its runtime commands and package artifact generator are not implemented yet.

## Command Semantics

**Boot intent and live state are strictly separated.**

`enable` and `disable` change what happens at next boot. They never start or
stop anything. `start` and `stop` change live state. They never change boot
prescriptions. No command does both.

| Command | What it does | Requires root |
|---|---|---|
| `mere enable <name>` | Add to boot set (assemble, sync, set prescription) | yes |
| `mere disable <name>` | Remove from boot set (service keeps running if up) | yes |
| `mere start <name>` | Bring up now (lazy-syncs live db if needed) | yes |
| `mere stop <name>` | Bring down now | yes |
| `mere restart <name>` | Stop then start | yes |
| `mere reload <name>` | Send SIGHUP to reload config | yes |
| `mere status` | List all services with state and boot prescription | no |
| `mere status <name>` | Detailed view (type, deps, pipeline, logs, svstat) | no (root for full detail) |
| `mere logs <name>` | Show service logs via s6-tai64nlocal | no (root for log access) |

## Filesystem Layout

| Path | Purpose |
|---|---|
| `/usr/share/s6-rc/sources/` | Package-shipped s6-rc source dirs (build-time generated) |
| `/etc/s6-rc/sources/` | Admin overrides (same name wins over package-shipped) |
| `/var/lib/s6-rc/store/` | Assembled source dirs (conflicts resolved) |
| `/var/lib/s6-rc/repository/` | s6-rc repo (prescriptions, compiled databases) |
| `/run/s6-rc/` | Live s6-rc state |
| `/var/log/<name>/` | Service log directories |

## What the Commands Do

**`mere enable ntpd`**:
1. Scan both source paths, assemble into store (admin overrides win)
2. Sync repo (`s6-rc-repo-sync`)
3. Set prescription to active (`s6-rc-set-change`)
4. Commit (`s6-rc-set-commit`)
5. Does NOT install to live db — ntpd starts at next boot or via `mere start`

**`mere start ntpd`**:
1. Ensure live db is current (assemble, sync, commit, install if needed)
2. `s6-rc -u change ntpd`

**`mere disable ntpd`**:
1. Set prescription to latent
2. Commit
3. Service keeps running if it was running — use `mere stop` to bring it down

**`mere stop ntpd`**:
1. Ensure live db is current
2. `s6-rc -d change ntpd`

## Recipe Service Definitions

See [Recipe Specification](recipe_spec.md) for the full `service` node reference.

Minimal example:

```kdl
service "ntpd" {
    type "daemon"
    command "/usr/bin/ntpd" "-n" "-d"
}
```

The packager generates run scripts, logging pipelines, dependency dirs, and
notification-fd files from this metadata. The result is a standard s6-rc source
directory at `usr/share/s6-rc/sources/ntpd/` inside the package.

For features beyond what KDL expresses, ship raw s6-rc source directories
directly — they're used as-is with no translation.
