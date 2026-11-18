# Remote repository cache snapshots

## Scope and layout

Remote caches use one immutable directory for each verified database/signature
pair, selected by a relative `current` symlink:

```
/mere/cache/repos/<trust-identity>/
    .sync.lock
    last_sync.kdl
    current -> snapshot-<32 random lowercase hex digits>
    snapshot-<id>/
        repo.db
        repo.db.sig
        .lease
    .snapshot-<id>.staging/    # private, unpublished downloads
```

`RepoCache.cacheDir()` remains the cache container, not the selected directory.
Package archives retain their existing independent cache layout.

This addresses #104's remote-cache publication boundary in `repocache.zig`.
It does not change HTTP repository filenames or the repository-authoring
publication in `repo_history.zig`. Remote servers still expose `repo.db` and
`repo.db.sig`: a server-side update between the downloads causes verification
to fail, never publication of a mismatched cached pair. Authoring snapshots,
server/client protocol changes, and #94's cross-user ownership policy remain
separate work. Local `file://` repositories retain their existing flat layout
and verification behavior; they are not mutated by cache snapshot maintenance.

## Publication

The per-cache exclusive sync lock still serializes freshness checking,
downloads, publication, and collection. A publisher:

1. Creates a unique mode-0700 stage and its reader lease.
2. Downloads both files inside that stage and verifies the database against
   the configured trusted fingerprints.
3. Writes the exact verified database bytes back into the private stage.
4. Makes the complete stage readable, then publishes it durably with
   `publishDirectory(no_replace)`: files/tree first, rename, parent sync.
5. Syncs the cache directory's ancestor entries, including first-use setup.
6. Replaces `current` with `replaceSymlink(durable)` and syncs the cache parent.
7. Invalidates the publisher's previously initialized in-memory repository,
   records the advisory freshness timestamp, and attempts optional collection.

Before the pointer switch, any failure leaves the previous selection intact.
A failure after publishing the directory but before selection may leave an
unselected snapshot, not a partially published pair. After switching `current`,
a failed checkpoint or parent fsync is an explicit committed durability error:
`sync` returns `FileSystem` with a selected-but-not-durable diagnostic, even
when ordinary stale-cache fallback is enabled. It does not collect snapshots.
A retry that hits the TTL fast path still syncs the cache directory, repairing
that pointer barrier rather than silently assuming durability.

The timestamp is an optimization, not the authority for selecting a pair.
Its write remains best-effort and independent of the snapshot transaction.

## Readers and exact verified bytes

Each verification reads `current` once and derives both file paths from that
same snapshot name. Names must match the generated single-component format;
absolute paths and traversal are rejected. A malformed or dangling pointer
never falls back to legacy metadata.

The reader opens `.lease` and holds a shared `flock` through signature
verification. A collector may win before that lock is acquired: the reader
checks that the leased directory still exists and retries selection if it was
removed. No retry combines paths from different selections. Writers never
modify a published snapshot.

Signature verification returns the exact database bytes it hashed. SQLite
uses `RepoDB.initFromVerifiedBytes`, which copies those bytes into its own
read-only database. Repository initialization must not reopen or require the
on-disk database after verification; its filesystem paths are diagnostic labels.
The reader can then release its lease without affecting subsequent queries.

## Collection and migration

After a fully durable refresh, collection is best-effort maintenance under the
same exclusive sync lock. `RepoCache.pruneSnapshots()` also exposes explicit
collection, acquiring that lock itself. Before deleting anything, collection
persists the actual `current` selection (including a previously failed pointer
sync) and its ancestor entries. It never deletes current.

For each unselected snapshot, collection attempts a nonblocking exclusive lock
on that snapshot's lease. An active verifier's shared lock prevents deletion;
that snapshot can be collected on a later pass. An already initialized SQLite
repository needs no on-disk retention because it owns its verified bytes.
Collection syncs the cache directory after deletion. Optional collection errors
are logged and do not undo a successfully published refresh.

When `current` is absent, readers may verify the legacy flat `repo.db` and
`repo.db.sig`. The first successful snapshot refresh leaves those legacy files
untouched and atomically starts selecting snapshots. Legacy flat files are not
collected automatically. Older Mere binaries do not understand `current`; they
may read stale flat metadata or fail on caches created by a newer version.
Downgrading or running older cache writers concurrently is not supported.

Unrecognized names and private staging trees left by process termination are
not collected. Their ownership/cleanup policy is separate from snapshot GC.

## Tests and platform assumptions

The snapshot tests cover reader pins across refresh/collection, legacy reads,
malformed/dangling pointers, pre/post-publication failures, a required directory
sync failure, and real subprocess termination/restart at all four publication
checkpoints. Signed remote-cache integration tests cover migration, exact
verified SQLite bytes, invalid signatures, committed error reporting, TTL
repair, invalidation of an initialized repository, and collection with readers.

The implementation assumes Linux directory-fsync and rename semantics stated
in `durable-publication.md`, and local-filesystem `flock` behavior. Network
filesystems with different locking or directory-fsync semantics are not covered.
Snapshots are immutable by Mere's protocol, not by inode flags; the cache owner
can modify files, so every newly opened repository still verifies its signature.
