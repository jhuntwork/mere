# Service Management

## Overview

Service management is integrated into `mere` as top-level commands. The CLI
surface and recipe format are provider-neutral; runtime service operations go
through `services.zig`, and package-time service metadata is translated by the
active artifact generator.

The default provider is s6-rc. dinit is also supported for lifecycle
operations, status/list/logs, and system-profile service reconciliation.

The active provider is configured in `/mere/config.kdl`:

```kdl
settings {
    init-provider "s6-rc" // or "dinit"
}
```

Packages carry normalized service intent in `.mere/meta.kdl`. This keeps the
package artifact independent of the target init provider. During system
profile realization, the configured provider consumes that metadata. dinit
materializes package-owned files under `/usr/share/dinit.d`; administrator
files under `/etc/dinit.d` are not modified. s6-rc continues to use its
existing source-store/repository path.

Provider-specific build-time generators remain as transitional compatibility
output. The eventual steady state is to remove those generators after all
install-time materialization paths and provider-switch reconciliation are
covered.

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
1. For s6-rc, assemble sources, sync the repo, and set the active prescription.
2. For dinit, add the service to the `boot` bundle with `dinitctl enable`.
3. Neither provider starts the service as a side effect.

**`mere start ntpd`** changes live state only; **`mere disable ntpd`** removes
boot intent but leaves a running service alone; **`mere stop ntpd`** changes
live state only. dinit status/list/logs use its native `dinitctl` protocol;
when buffered output is unavailable, logs fall back to the configured service
log file.

## Recipe Service Definitions

See [Recipe Specification](recipe_spec.md) for the full `service` node reference.

Minimal example:

```kdl
service "ntpd" {
    type "daemon"
    command "/usr/bin/ntpd" "-n" "-d"
}
```

The packager records service intent in `.mere/meta.kdl`; it does not need to
preserve provider-specific recipe KDL. During system profile realization, dinit
reads that metadata and reconciles package-owned files in
`usr/share/dinit.d/`. Service additions, upgrades, and removals are handled;
conflicting service names are rejected. Administrator overrides in
`/etc/dinit.d/` are not overwritten.

The existing build-time native generators are transitional compatibility output
while the remaining install-time/provider-switch coverage is completed.
