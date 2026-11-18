# Durable Publication

## Overview

Mere publishes new state in many places: store objects, generations,
the `current` pointer, GC roots, `/etc` files, boot artifacts, repository
metadata and keys. Each publication must make two separate promises clear:

- **Atomic visibility.** A reader sees the previous state or the complete new
  state, never a partial one. A rename within one directory provides this.
- **Durability.** Once the operation reports success, the new state survives
  power loss. This needs fsync calls in a specific order around the rename.

`src/publish.zig` implements both promises in one place. This document states
what each helper guarantees and which guarantee each caller relies on.
Callers that publish new state should use these helpers instead of their
own rename and fsync sequences.

## Helpers

Every helper takes a `Guarantee`:

- `.atomic`: atomic visibility only. No fsync is performed.
- `.durable` (the default): atomic visibility, and the new state survives
  power loss once the call returns.

| Helper | Sequence with `.durable` | Modes |
| --- | --- | --- |
| `beginFile` + `StagedFile.publish` | create a temporary file in the destination directory; the caller writes it; fsync the file; rename; fsync the directory | replace, or no-replace (returns `.exists`) |
| `replaceFile`, `copyFile` | the same, writing the given bytes or a copy of a source file | as above; `copyFile` keeps the source mode by default |
| `replaceSymlink` | create a temporary symlink; rename over the destination; fsync the directory | always replaces; the name never disappears |
| `createSymlink` | symlink(2) at the final name; fsync the directory | no-replace (returns `.exists`) |
| `publishDirectory` | fsync every file in the staged tree, then every directory child-first; rename; fsync the parent | `no_replace` (returns `.exists`), or `exchange` (old tree ends up at the staged path) |
| `syncDir`, `syncTree` | fsync primitives for callers that publish by other means | — |

With `.atomic`, the same sequences run without the fsync steps.

Temporary entries are created in the destination directory with names of the
form `.<name>.mere-tmp-<16 hex digits>`. The helpers try to remove them on
every error path. An entry stays behind if that removal also fails or the
process terminates mid-publication; it is never visible under the final name.

The helpers never take the store lock. Public operations take the lock and
call the helpers from their `*Locked` paths, as established in #100.

### Error contract

`error.PublishedNotDurable` is the only error a helper returns after the call
made new state visible. It means the rename happened, but a later step
failed: the directory fsync, or an injected fault after the rename. The
caller must treat the publication as having happened; for the `current`
pointer this is the `committed_needs_repair` activation outcome from #99.

Every other error means the call published nothing, and the caller can roll
back as if the helper had never run.

A no-replace publication that finds the destination already present returns
`.exists` and publishes nothing. The after-rename checkpoint does not fire.
With `.durable` it still fsyncs the directory, because the existing entry may
come from a process that stopped before its own fsync; if that fsync fails,
the error is an ordinary one, not `PublishedNotDurable`.

No sync failure required by the chosen guarantee is ignored.

### Fault checkpoints

Each helper fires a pair of `fault_injection.Checkpoint` values immediately
before and after its rename:

- `publish_file_before_rename`, `publish_file_after_rename`
- `publish_directory_before_rename`, `publish_directory_after_rename`
- `publish_symlink_before_rename`, `publish_symlink_after_rename`

A checkpoint fires only once per configuration, so a generic checkpoint
targets the first publication of that kind in a process. Callers can pass
their own `Checkpoints` pair, such as `current_before_replace` and
`current_after_replace`, so a restart test targets exactly one publication.

A `fail` action before the rename returns `error.InjectedFailure` with
nothing published. A `fail` action after the rename returns
`error.PublishedNotDurable`. A `terminate` action exits the process at that
point and can leave a temporary entry behind.

## Ordering between publications

A pointer is only as durable as the state it points at. A caller that
publishes a pointer durably must first publish its target durably:

- a generation directory before `current` selects it;
- a store object before a generation or GC root references it;
- boot artifacts, `/etc` files and the service tree before `current` selects
  the generation that expects them;
- a repository snapshot before the pointer that selects it (#104).

## Platform assumptions

- Linux only.
- The temporary entry and its destination are in the same directory, so
  rename(2) is atomic.
- fsync on a directory file descriptor persists that directory's entries.
  ext4, xfs and btrfs guarantee this. The helpers reopen a directory for
  reading before calling fsync, because fsync on an `O_PATH` descriptor fails
  with `EBADF`.
- A new symlink is made durable by its parent directory's fsync alone. Older
  btrfs kernels had bugs that could lose the target of a symlink persisted
  this way.
- No-replace publication uses renameat2 `RENAME_NOREPLACE` and directory
  exchange uses `RENAME_EXCHANGE` (Linux 3.15 and later). Where a filesystem
  rejects `RENAME_NOREPLACE`, file publication falls back to link(2), which
  refuses any existing entry. Directory publication falls back to checking
  that the destination is absent and then calling rename(2); only an empty
  directory created between the check and the rename can be replaced.
  `RENAME_EXCHANGE` has no fallback and returns `error.Unsupported`.
- Raw `std.os.linux` syscalls must be decoded with `std.os.linux.errno`.
  Mere links libc, so `std.posix.errno` is libc's version: it treats only
  `-1` as failure and reports every raw `-errno` result as success.

## Callers

The table lists the guarantee each caller needs and the helper it uses or
will use. Callers marked "planned" still use their own sequence; the gaps
column describes that sequence.

| Caller | Guarantee | Helper | Status | Gaps in the current sequence |
| --- | --- | --- | --- | --- |
| `current` pointer (`activation.zig`) | atomic + durable | `replaceSymlink` with the `current_*` checkpoints | planned | no directory fsync |
| Generation directory (`profile.zig`, `createGeneration`) | atomic + durable | `publishDirectory`, `no_replace` | planned | no tree or parent fsync |
| Generation manifest and realization (`generation.zig`) | atomic + durable | `replaceFile` | planned | no file or directory fsync; fixed `.tmp` name |
| Named profile root (`profile.zig`, `publishProfileRoot`) | atomic + durable | `publishDirectory`, `exchange` for an existing root | planned | no tree or parent fsync; a failed exchange is reported as success |
| Profile entry symlinks (`profile.zig`) | atomic, inside a staged tree | `replaceSymlink`, `.atomic` | planned | none once the enclosing tree is synced |
| GC root `current` (`gcroots.zig`) | atomic + durable | `replaceSymlink` | planned | no directory fsync |
| GC roots `kept/gen-N` (`gcroots.zig`) | atomic + durable | `replaceSymlink` | planned | deletes before recreating; no fsync |
| Store admission (`install.zig`) | atomic + durable | `publishDirectory`, `no_replace` | `syncTree` in use; rename planned | a failed parent fsync is only logged; the existing-target errno is decoded incorrectly |
| Boot artifacts (`activation.zig`) | durable before the pointer switch; never replaces | `copyFile`, no-replace | planned | no fsync |
| `/etc` templates (`etc.zig`) | atomic + durable | hardlink the old file to `.old`, then `copyFile` | planned | the file is missing between the backup rename and the copy; no fsync |
| dinit service tree (`service_reconcile.zig`) | durable before the pointer switch | `syncTree`, then the existing two renames, then `syncDir` | planned | no fsync; the two-rename window stays (see below) |
| Pins (`pin.zig`) | durable | `createSymlink`, `replaceFile` for the note | planned | no fsync |
| Package pool import (`import.zig`) | durable | `copyFile` | planned | no fsync |
| Signing keys (`sign.zig`, `sign_io.zig`) | durable | `replaceFile` / no-replace | planned | no fsync |
| Repository cache `last-sync` (`repocache.zig`) | atomic | `replaceFile`, `.atomic` | planned | fixed `.tmp` name |
| Repository cache db/sig pair (`repocache.zig`) | atomic pair + durable | snapshot directory + pointer (#104) | #104 | two renames; a crash leaves a mismatched pair; no fsync |
| Repository authoring db/sig pair (`repo_history.zig`) | atomic pair + durable | to be decided with #104 | #104 | same as above; clients fetch the flat file names |

### Out of scope

These publications are rebuilt or re-verified by hash when lost, and only
need atomic visibility, which they already have:

- downloads (`download.zig`);
- build-cache directories (`build_cache.zig`);
- archive and package outputs (`archive.zig`, `packaging.zig`);
- hardlink deduplication and extraction into staging trees
  (`archive.zig`, `extract.zig`);
- files written inside a staging tree that is later published as a whole,
  such as projection indexes.

SQLite commits in `repodb.zig` follow SQLite's own durability settings.

### Deliberate gaps

- **dinit service tree.** Publication keeps the backup-and-rename sequence
  from #99, so there is a short window between the two renames with no live
  service tree. Replacing it with `RENAME_EXCHANGE` changes the
  `.mere-old` recovery states that rollback and repair rely on, and is left
  to a separate issue.
- **Store hardening.** The ownership, mode and immutable-flag changes made
  after admission are not synced, so a power loss can undo some of them.
  Trust in a hardened object is decided by its top-level directory alone
  (#101). If the top-level change is lost, the next admission re-verifies and
  re-hardens the object. If only changes to entries inside it are lost, the
  object is still treated as hardened.
- **Temporary entries after termination.** Nothing removes a temporary entry
  left by a terminated process. The names are unique and never collide with
  final names.

## Guidance for repository snapshots (#104)

Publish each snapshot directory with `publishDirectory` (`no_replace`,
`.durable`), so both files and the directory entry are on disk before
anything refers to them. Then switch the selecting pointer with
`replaceSymlink`. If the pointer switch returns
`error.PublishedNotDurable`, the new snapshot is selected, but the selection
may not survive power loss; the previous snapshot must be kept until a later
switch succeeds durably.
