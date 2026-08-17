# Specification Details

This document contains detailed design specifications that supplement the main `README.md` document.
These are authoritative implementation details for specific subsystems.

---

## Consumers and the Interface Contract

The sections below specify subsystems. This one states what any consumer of Mere may rely on, so that those sections can be read as consequences of a stated model rather than as independent choices.

Mere is driven by people at a terminal, by scripts, by CI, and by automated callers including AI agents. These differ in ways that matter to the interface, and the differences are properties rather than categories — a shell script in a CI job and an agent share most of them, and a human running the same command twice a year shares more of them than one might expect.

**A consumer may have no continuity of memory.** It may arrive knowing nothing of prior invocations, or holding a lossy summary of them. Therefore:

- Current state MUST be discoverable by reading the filesystem, without being told what was true previously. This is what "filesystem as truth" buys, and it is the property most worth protecting.
- Identifiers that a consumer may record and later act on MUST remain valid when read back. Content hashes and generation numbers qualify; phrases resolved at use time, such as "the current generation" or "the latest version", do not, and MUST NOT be the only way to name a thing.
- Operations SHOULD be safe to repeat. A consumer that cannot tell whether its previous call took effect will call again.

**Concurrency is normal.** Several consumers may operate against one root at the same time, and one of them may be blocked on something slow and external while holding whatever it holds. Therefore:

- A mutating operation MUST either serialize correctly or fail cleanly. It MUST NOT corrupt state under contention, and it MUST NOT depend on being the only operation running.
- Contention MUST be reported rather than silently waited out forever or resolved by force.
- An operation that acts on a state it observed earlier SHOULD be expressible as "apply only if the state is still what I saw", so a loser can re-derive instead of clobbering.

**Abandonment is expected, not exceptional.** Consumers are interrupted, killed, cancelled, and timed out as a matter of course. Therefore in-flight work MUST have a discoverable owner and MUST be reclaimable once that owner is gone — specified for scratch directories in §4.3.

**A consumer's authority is bounded, and its inputs are not trusted.** Every consumer acts partly on text it has read: package names and descriptions, recipe contents, build output, search results. That text is authored elsewhere and may be hostile, and this is true of a shell script parsing output as much as of a model reading it. Therefore:

- What a consumer is permitted to do MUST NOT be derivable from what it has read. Authority comes from where it runs and as whom — the root prefix in use, file ownership, privilege — never from what the operation asks for.
- Verification MUST NOT be satisfiable by the artifact being verified. Trust is anchored in configured fingerprints and local keys (§9.2, §9.10), and a package cannot nominate the key that admits it.

### Same input, same effect

Because a consumer may not remember its own past and may not be the only one running, an invocation SHOULD depend only on its arguments and on state it can observe. Behaviour that varies with ambient context — the working directory, elapsed time since some earlier action, what a previous invocation happened to leave behind — makes the same command mean different things on different runs for reasons not visible in the command. Where such conveniences exist for interactive use, they SHOULD be resolvable to an explicit form.

### Self-description

`mere describe` writes a machine-readable description of the command surface to stdout, so a consumer can learn the interface at runtime instead of being told about it out of band. It reports the program name, the running version, global flags, and the command tree with each command's group, positional arguments, and flags — including each flag's type, short form, value name, default, and whether it is required.

The output is JSON. Mere reads KDL but has no KDL writer, and this document exists to be parsed by other tools rather than edited by hand.

Requirements on the output:

- It MUST carry a `schema_version`. Additive fields do not change it; a change that would break a consumer parsing the document MUST bump it.
- Ordering MUST be deterministic, not hash order. Two runs of the same binary MUST produce byte-identical output, so a consumer diffing it sees only real changes.
- Hidden commands MUST be omitted, matching `--help`.
- `describe` MUST describe itself. It is an ordinary registered command rather than a specially intercepted one, so it appears in `--help` and in its own output; a self-description facility that cannot be discovered is of little use.

The description covers the command surface only. Schemas for on-disk artifacts — manifests, profile state, repository databases — are specified in this document and are not yet emitted in machine-readable form.

### Current conformance

This contract is a design commitment, and Mere does not yet meet all of it. Known gaps, recorded here so they are not mistaken for intent:

- **Ambient state.** `mere shell` resolves a profile from the working directory (§15.12), and repository sync is skipped on a TTL, so `mere install` may resolve against different metadata depending only on elapsed time. Neither is expressible as an explicit argument.
- **Concurrency granularity.** All mutating operations serialize on one exclusive lock per root. This is correct but coarse: unrelated work blocks, and there is no way to express "apply only if the profile is still at generation N".
- **Self-description.** The command surface is machine-readable via `mere describe`. The schemas of on-disk artifacts are not, so a consumer parsing a manifest or profile state must still be told their shape out of band.
- **No record of action.** Mere keeps no account of what it did, so a consumer cannot reconstruct its own prior operations, and an operator cannot audit another consumer's.

One deliberate exception to "state is inspectable via filesystem": scratch ownership (§4.3) is an `flock` held on a directory, which is process state rather than on-disk state and is therefore not visible to `ls`. This is accepted because the alternative — a marker file — either enters a store object's payload and changes its identity, or becomes debris needing its own reclamation. Liveness is a property of a running process, and encoding it on disk misrepresents it.

---

## Store and Content Hashing

### 1. Store Hash Byte-Level Format

The store path is `<hash>-<name>-<version>` where hash is BLAKE3 of the realized payload.

**Algorithm**: Use a single incremental BLAKE3 hasher. Walk entries in deterministic (lexicographic) order. For each entry, feed a canonical record with explicit length-prefixed boundaries.

**Record format per entry**:
```
entry_tag       = 0x01 (1 byte)
path_len        = u32 LE
path            = UTF-8 bytes, '/' separators, no leading slash
type_tag        = 1 byte: 0x10=file, 0x11=dir, 0x12=symlink

If file (0x10):
  exec_bit      = 1 byte: 0x00 (not executable) or 0x01 (executable)
  content_len   = u64 LE
  content       = raw file bytes (streamed)

If symlink (0x12):
  target_len    = u32 LE
  target        = symlink target bytes

If dir (0x11):
  (nothing else - just the entry_tag + path + type_tag)
```

**Rules**:
- Entries sorted lexicographically by path before hashing
- Empty directories ARE included (hash their entry record)
- Path uses forward slash separators, no leading slash (e.g., `usr/bin/foo`)
- Type tag distinguishes file vs directory with same name
- No implicit concatenation - all fields explicitly length-prefixed or fixed-size

**Store path format**:
- Hash is **64 lowercase hex characters** (full BLAKE3 output, not truncated)
- Store path is `<hash>-<name>-<version>` with **no release number**
- Example: `/mere/store/9f2c3a...64chars...-nginx-1.24.0/`

**Metadata location**:
- `.mere/manifest.v1` (binary) and `.mere/manifest.v1.sig` (signature) in the `.mere/` subdirectory
- Both manifest files are **excluded from the content hash** (see spec #4) because the manifest contains the hash it describes and the signature authenticates that manifest
- `.mere/meta.kdl` is canonical package intent metadata and **is included in the content hash**
- `.mere/projection.v1` is a derived index and **is excluded from the content hash**; it is regenerated and validated from the package contents and metadata
- The `content_hash` field in the manifest and the hash in the store path are **identical** (same 32 bytes, displayed as 64 hex chars in path)

#### 1.1 Content Identity Invariants

The store content hash **MUST** incorporate:
- File bytes
- Path names
- File type (file / directory / symlink)
- Executable bit (`+x`)

The store content hash **MUST NOT** incorporate:
- Read/write permission bits (other than executable)
- Ownership (uid/gid)
- Timestamps
- ACLs or extended attributes

**Normative invariant**: Two payloads that differ only in non-executable permission bits or ownership are considered *identical content*.

Implementations MUST preserve extracted permission bits when unpacking archives, but MUST NOT treat them as part of store identity.

---

### 2. Package Filename Parsing

Package filenames are `<name>-<version>-<release>-<arch>-<archive_hash>.pkg.tar.zst`.

**Rule**: Package filenames are **not intended to be parsed**. The filename format is a human-readable label only. All machine parsing uses the metadata inside the package (`manifest.v1`), not the filename.

**Normative rules**:
- Hyphens are allowed in package names and versions
- No parsing ambiguity exists because we don't parse filenames
- Tools read `manifest.v1` for name, version, release, arch, and the complete package `content_hash`

---

### 3. Version Comparison Algorithm

**Algorithm**: Arch/pacman-style `vercmp` with epoch and tilde extension.

**Comparison order**: `(epoch, version, release)` tuple comparison
1. **Epoch** (optional): Integer prefix `N:` (e.g., `1:2.0.0`), default is `0` if omitted
2. **Version**: Compared using vercmp algorithm (see below)
3. **Release**: Integer tie-breaker (e.g., the `1` in `1.0.0-1`)

**vercmp algorithm**:
- Split version string into runs of digits and non-digits
- Compare runs left-to-right:
  - Digit runs: compare as integers (leading zeros ignored)
  - Non-digit runs: compare lexicographically (ASCII)
- Longer version wins if all compared runs are equal

**Tilde for pre-releases**:
- `~` sorts before everything, including empty string
- `1.0~rc1 < 1.0~rc2 < 1.0`

**Examples**:
- `1.0 < 1.1 < 1.2 < 1.10` (numeric comparison)
- `1.0~alpha < 1.0~beta < 1.0~rc1 < 1.0` (tilde pre-release)
- `1:1.0 > 2.0` (epoch wins)
- `1.0-1 < 1.0-2` (release tie-breaker)

---

### 4. Content Hash and Metadata

The store content hash identifies the complete immutable Mere store object: its realized payload plus canonical package intent metadata. Metadata (`manifest.v1`) binds to that hash but is not part of it.

**Rule**: Compute `content_hash` over the realized package payload and `.mere/meta.kdl`, excluding the self-referential manifest files and the derived projection index. This prevents metadata-only changes—such as adding or changing dependencies, provisions, or service definitions—from colliding with an earlier immutable store object and silently retaining stale behavior.

**Included in content hash**:
- All realized payload entries
- `.mere/meta.kdl`, in its canonical serialized form

**Excluded from content hash**:
- `.mere/manifest.v1` (package manifest, which contains `content_hash`)
- `.mere/manifest.v1.sig` (signature over the excluded manifest)
- `.mere/projection.v1` (derived projection index)

Only these explicitly listed derived/authentication files are excluded. Other unexpected files under `.mere/` are included, so adding package metadata requires an intentional, specified format rather than silently bypassing store identity.

The package metadata must be generated before the final content hash is computed. The manifest and signature are written afterward or rewritten with that final hash.

---

### 4.1 Store Admission Protocol

The store supports **two-tier admission**: unprivileged users can add objects for personal use, while privileged operations publish objects for system use.

**Store Directory Setup**:
- `/mere/store` owned by `root:root`
- Mode `1777` (world-writable with sticky bit)
- Allows unprivileged addition, prevents unauthorized deletion

**Normative invariant**: If `/mere/store/<hash>-<name>-<version>/` exists, it is **immutable forever** (enforced by permissions, ownership, and filesystem immutable flags on system-hardened objects). For system profile store objects, immutability is enforced by `FS_IMMUTABLE_FL` which prevents modification even by root. For user-owned store objects, immutability is enforced by read-only permissions only.

#### Unprivileged Admission Steps

For unprivileged `mere install` or `mere dev build`:

1. **Verify manifest signature before touching the store**:
   - Partial-extract `manifest.v1` and `manifest.v1.sig` from the package archive
   - Verify Ed25519 signature over manifest bytes using trusted fingerprints
   - If verification fails, reject the package (no store changes)
   - Verify repository metadata binding for the selected package record:
     - `name`, `version`, `release`, and `arch` in repository DB MUST match `manifest.v1`
     - `content_hash` in repository DB MUST match `manifest.v1` content hash
   - Any DB↔manifest mismatch is a hard integrity error (reject with no store changes)

2. **Materialize into a temporary directory**:
   - Create a unique temp dir under `/mere/store/.incoming/<rand>/`
   - Using `.incoming/` ensures same-filesystem for atomic rename
   - Claim the directory under the scratch ownership protocol (§4.3) so it is reclaimable if this process dies before admission

3. **Extract payload and validate**:
   - Extract package contents to temp dir
   - Enforce symlink boundary rules (no escapes outside package root)
   - Read and validate canonical `.mere/meta.kdl`
   - Compute content hash from the realized payload and `.mere/meta.kdl`

4. **Write manifest files to temp dir's `.mere/` subdirectory**:
   - Create `.mere/` directory in temp dir
   - Copy `manifest.v1` and `manifest.v1.sig` into `.mere/`
   - These files are excluded from content hash by design

5. **Atomically admit to final path**:
   - Final path: `/mere/store/<hash>-<name>-<version>/`
   - Admission is one atomic operation: `rename(temp_dir, final_dir)`
   - If `final_dir` already exists: treat as success (idempotent)
   - **Ownership**: Object remains owned by the unprivileged user

6. **Post-admission verification** (optional):
   - Not required for normal install once pre-verification + payload hash check succeeded
   - May be performed by explicit verification tools (`mere store verify`) or privileged hardening

7. **Set permissions**:
   - Make the admitted directory and contents read-only for the owner

**Result**: User-owned (unpublished) store object suitable for experimentation but NOT for system profiles.

#### Existing Store Object Fast-Path

If `/mere/store/<hash>-<name>-<version>/` already exists and `reinstall` is false:

- The object is reusable only for the same complete content identity, including canonical `.mere/meta.kdl`
- A package with changed metadata produces a different `content_hash` and therefore a different immutable store path
- The existing object is never overwritten or augmented with metadata from a later package revision
- **Unprivileged**: No further verification required (user is only affecting their own profile)
- **Privileged**: MUST harden the existing store object before referencing it in a system profile. An unprivileged user may have admitted this object previously; the privileged fast-path ensures it is root-owned, read-only, has valid symlink boundaries, has verified content hash, and has filesystem immutable flags set before any system generation uses it. If the object is already hardened (root-owned with immutable flags set), verification and hardening are skipped — the object was verified when first admitted.

This keeps installs fast for already-admitted complete identities while enforcing the trust boundary for system profiles.

#### Privileged Publication Steps

For privileged `sudo mere install` (system installation):

1. **Perform unprivileged admission** (steps 1-7 above) if object doesn't exist
   - May be performed by the privileged process itself
   - Or may reference an existing user-owned object

2. **Verify and harden** all referenced store objects:
   - Verify integrity and signatures of all store objects referenced by the operation
   - Recompute content hash from realized store path and compare against manifest (mandatory, not opt-in)
   - For each referenced store object:
     - Use `lstat`-based recursive traversal (MUST NOT follow symlinks outside boundary)
     - Change ownership to `root:root` recursively
     - Set read-only permissions recursively
     - Set filesystem immutable flag (`FS_IMMUTABLE_FL` via `FS_IOC_SETFLAGS` ioctl) on all files and directories recursively
     - Verify no symlinks escape the store object boundary
   - If the filesystem does not support immutable flags (e.g., tmpfs in containers): emit a single warning at the start of the operation and proceed without immutable flags. This is a correctness degradation, not a failure.

3. **Validate publication**:
   - Ensure all referenced store paths are now owned by `root:root`
   - Ensure all referenced paths reside within `/mere/store`
   - Ensure all files and directories have the immutable flag set (when filesystem supports it)
   - If any object cannot be verified or hardened: **fail the entire operation**

4. **Create system profile generation**:
   - Build generation directory with symlinks to published (root-owned) store objects
   - Write generation manifest
   - Atomically activate if requested

**Result**: System-owned (published) store objects suitable for system profiles.

**Normative Invariant**: No system profile or generation may reference unpublished (non-root-owned) store objects.

#### Collision Handling

If the final store path already exists when attempting rename:

1. Verify the existing directory's `manifest.v1.sig` is valid
2. If valid: success (content already present, skip)
3. If invalid: error (store corruption detected)

For privileged operations, additionally verify ownership:
- If object is already `root:root` owned: success (already published)
- If object is user-owned: proceed with hardening (change ownership to `root:root`)

#### Security Boundaries

**Unprivileged users can**:
- Add new objects (legitimate use for personal profiles)
- Delete their own objects (via GC or manual removal)
- Read all objects (store is world-readable)

**Unprivileged users cannot**:
- Delete or modify objects owned by other users (sticky bit protection)
- Delete or modify root-owned objects (ownership protection)
- Affect system profiles (activation enforces root ownership)

**Privileged operations can**:
- Publish user-owned objects (change ownership to root)
- Create system profiles referencing only root-owned objects
- Delete any objects during GC (respecting reachability rules)

**Remaining attack surface**: Unprivileged users can fill disk (DoS via disk exhaustion, mitigated by quotas if needed).

---

### 4.2 Manifest Location in Archives and Store

**In package archives** (`.pkg.tar.zst`):
- `.mere/manifest.v1` (manifest)
- `.mere/manifest.v1.sig` (signature)

**In store objects** (`/mere/store/<hash>-<name>-<version>/`):
- `.mere/manifest.v1`
- `.mere/manifest.v1.sig`

---

### 4.3 Scratch Ownership and Reclamation

Several operations create directories that are meaningful only while their creating process is alive:

- store staging directories under `/mere/store/.incoming/<rand>/` (§4.1 step 2)
- namespace session trees under the session base (§14.1)

Abnormal termination — a crash, `SIGKILL`, a cancelled or timed-out invocation — leaves these behind. Mere MUST treat abandonment as an expected outcome rather than an exceptional one, because a consumer that is killed mid-operation is normal, not rare: automated and agent-driven callers are routinely interrupted, and each interruption otherwise leaks a directory tree permanently. Without reclamation `.incoming` grows without bound in a world-writable directory that garbage collection never inspects.

**Ownership protocol**. A process claims a scratch directory by holding an exclusive `flock(2)` on **the directory's own file descriptor**, opened `O_DIRECTORY | O_NOFOLLOW`. The claim exists only as long as that descriptor does: it is held on the open file description, so it survives `execve` and is released by the kernel when the owning process exits for any reason. Liveness therefore requires no heartbeat, timeout, or pid check, and is immune to pid reuse.

The claim MUST NOT be represented by anything on disk — no lock file, no state file. A store staging directory *becomes* the store object via `rename(2)`, and its content hash is computed over exactly what it contains, so a marker inside it would enter the payload and change the object's identity; a marker beside it would be debris requiring its own reclamation. Locking the directory itself has neither problem, and the lock follows the inode across the rename that admits the object.

For namespace sessions the claim is made inheritable across `execve` (`FD_CLOEXEC` cleared), because the session remains in use for as long as the shell or build command runs and that command replaces the claiming process.

**Reclamation**. A process sweeping a scratch base directory MUST, for each child directory:

1. Skip it unless it is owned by the sweeping user, or the sweeper is privileged. Scratch bases may be world-writable and MUST NOT become a route to deleting another user's in-flight work. Ownership MUST be determined without following symlinks.
2. Attempt a non-blocking exclusive `flock` on the directory. Failure to acquire means the owner is live, and the directory MUST be left alone regardless of its age — a long extraction can leave a staging directory's own mtime well behind while the install is still running.
3. Acquiring the lock means no process owns the directory. It MAY then be removed, but only once its mtime is older than a grace period. Without an on-disk marker there is nothing to distinguish "abandoned" from "created moments ago and not yet claimed", so age closes that window.

Reclamation is opportunistic and MUST NOT fail the operation that triggers it: a directory that cannot be swept is left for a later sweep.

**Where sweeping occurs**:

- Garbage collection sweeps `/mere/store/.incoming/`. Store staging is no longer exempt from GC; only *live* staging is exempt, and liveness is determined by the lock rather than by the directory's name.
- Namespace session creation sweeps its session base before allocating a new session, so the tree is self-limiting without a separate command.

**Normative invariant**: A scratch directory whose owner is not alive is reclaimable by any process entitled to delete it. No scratch directory is permanently exempt from reclamation.

---

### 5. Signature File Binary Format

**Blob Signing (.sig files)**:

| Field     | Size     | Description                                 |
| --------- | -------- | ------------------------------------------- |
| signature | 64 bytes | Raw Ed25519 signature (`crypto_sign_BYTES`) |

**That's it.** No header, no version, no timestamp, no signer identifier.

**What is signed**: The exact bytes of the file being signed (for `manifest.v1.sig`, this is the raw bytes of `manifest.v1`).
```
signature = ed25519_sign(secret_key, manifest_bytes)
```

**Key file formats**:
- `.pub`: 32 raw bytes (Ed25519 public key)
- `.key`: 64 raw bytes (libsodium secret key format: seed || public), permissions 0600

**Package manifest signing**:
- The manifest (`manifest.v1`) carries semantic meaning (name, version, content_hash, created_at)
- The signature (`manifest.v1.sig`) proves the manifest bytes are intact
- Together they provide authenticated package metadata

---

## Profile and Generation System

### 6. Profile Manifest Schema

`/mere/profiles/system/gen-<N>/profile.kdl` and `/mere/profiles/<name>/root/profile.kdl` share the same manifest schema.

The profile manifest uses KDL format, consistent with the recipe format used
throughout Mere. It serves as both the **authoritative record** of a realized
generation and as a **declarative input** for constructing new generations.

#### Bidirectional usage

The same `profile.kdl` format flows in both directions — from user to system
and from system back to user — but the user's file and the generation's file
are separate instances with different lifecycles.

- **User's file**: Lives in a project directory or is passed to
  `mere profile apply`. Owned by the user. Contains package names and optional
  version/release pins. Never written to by the system.
- **Generation's file**: Lives in the generation directory, managed by the
  system. Contains the full resolved state — versions, releases, content
  hashes. Written after resolution. Read back by activation, verification,
  gc, and profile projection.

Feeding a generation's `profile.kdl` back as input reproduces the exact
system on the same architecture, because the content hashes drive exact
artifact resolution. Cross-architecture, content hashes will not resolve
(the artifacts are different binaries); the version and release fields
serve as fallback constraints, producing the same versions built for the
target architecture. This makes the realized output a portable system
specification within an architecture, and a version-pinned specification
across architectures.

Both imperative commands (`mere install X`) and declarative application
(`mere profile apply profile.kdl`) produce the same artifact — a generation
directory with a fully resolved `profile.kdl`.

#### Input resolution gradient

When `profile.kdl` is used as input, each `package` node is resolved
according to what fields are present:

1. **content-hash present** → look in local store; fetch by hash if missing.
   Version/release are human-readable labels only. Enters the resolver as a
   hard constraint.
2. **version (and optionally release) present, no hash** → resolve from repo
   with version constraint. Compute hash from fetched content.
3. **name only** → resolve latest from repo. Compute hash from fetched content.

When a profile mixes hashed and unhashed packages, the resolver handles the
full set. Hashed packages enter as hard constraints (strongest possible pin).
The resolver checks consistency across all packages and fails early if
constraints conflict.

#### Schema

**Required top-level properties (output only — ignored on input):**

| Property         | Type    | Description                 |
| ---------------- | ------- | --------------------------- |
| `schema-version` | integer | Schema version, starts at 2 |
| `created-at`     | u64     | Unix epoch seconds          |

**Package node properties:**

Each `package` node's first argument is the package name (string).

| Property       | Type    | On input (user-specifiable)            | On output (system-resolved)  |
| -------------- | ------- | -------------------------------------- | ---------------------------- |
| `version`      | string  | Optional version constraint            | Always present               |
| `release`      | integer | Optional exact build pin               | Always present               |
| `content-hash` | string  | Optional, 64 hex chars, exact artifact | Always present, 64 hex chars |

On input, all properties are optional. When `content-hash` is present, it
takes precedence — the system fetches the exact artifact by hash, and
`version`/`release` are treated as labels. When only `version` (and
optionally `release`) is present, the resolver uses them as constraints.
When only the name is present, the resolver picks the latest version.

**Not in the format:**

- **`store-path`**: derived from content-hash + name + version per spec #1.
  The store path is `{store-root}/{content-hash}-{name}-{version}/`.
- **`arch`**: derived from the target system. Cross-arch install is not a
  supported input.

**Optional top-level properties (may be omitted):**

| Property           | Type    | Description                              |
| ------------------ | ------- | ---------------------------------------- |
| `generation`       | integer | System generation number N               |
| `parent-generation`| integer | Previous generation this was built from  |
| `notes`            | string  | Human comment                            |
| `profile-name`     | string  | Profile name (for multi-profile support) |
| `tool-version`     | string  | Version of `mere` that produced it       |

**Emitted example (output — full resolved state):**
```kdl
profile {
    schema-version 2
    generation 42
    parent-generation 41
    created-at 1769880000
    tool-version "0.6.5"
    notes "weekly update"

    package "busybox" version="1.37.0" release=5 \
        content-hash="ab3f...64chars..."

    package "llvm-dev" version="1.0-beta" release=1 \
        content-hash="9f2c...64chars..."
}
```

**Input example (user-authored — minimal):**
```kdl
profile {
    package "llvm-dev"
    package "busybox"
    package "curl"
}
```

**Input example (version-pinned):**
```kdl
profile {
    package "llvm-dev" version="1.0-beta"
    package "busybox" version="1.37.0" release=5
    package "curl"
}
```

**Canonical form**: When emitting `profile.kdl`, `mere` MUST write packages in
sorted order by name, use consistent quoting, and omit comments. This ensures
that identical generations produce byte-identical manifests.

**Signing**: Optional in v2.

**Rationale (KDL)**: KDL is the human-readable format used throughout Mere
(recipes, package metadata). Using it for the profile manifest eliminates a
one-off JSON format, keeps the system to two formats (binary for machine trust
and performance, KDL for everything humans read and write), and enables the
bidirectional input/output usage that makes declarative system management
possible without adding a new file or concept.

#### 6.1 Realization Validity

A profile realization directory (`gen-N/` for system, `root/` for named profiles) is considered **valid** if and only if:
- `profile.kdl` exists
- `profile.kdl` parses successfully
- `schema-version` is supported

**Incomplete Realizations**: Any realization directory lacking a valid manifest **MUST** be treated as:
- Non-existent for all purposes
- Ignored by publishing, activation, GC, listing, and rollback commands

**Failure Semantics**: If realization construction fails:
- Partial directories MAY remain on disk
- Tools MUST NOT attempt recovery
- The absence of a valid `profile.kdl` is the sole indicator of failure

**Normative invariant**: The filesystem is the source of truth; the manifest is the authority. No additional state or marker files are permitted.

#### 6.2 Trust Boundary for Profile Metadata

Profile manifests are **unsigned** in v1. The system assumes:
- `/mere/profiles/system/` is host-owned and trusted for system activation
- Named profile manifests are user-owned and authoritative only for that named profile
- Local filesystem integrity is a prerequisite for correct operation

**GC Implications**: GC correctness depends on system generation manifests and named profile manifests being truthful within their respective trust domains.

**Normative invariant**: If `/mere/profiles/system/` is compromised, system integrity is already lost. If a named profile is compromised, that profile's realization and retention behavior are undefined, but this MUST NOT expand to privileged system activation decisions.

---

### 7. Symlink Validation Boundaries

**a) Allowed symlink targets**:
For profile activation symlinks, the only allowed targets are **inside `/mere/store/`** (specifically: inside a store root like `/mere/store/<hash>-<name>-<version>/...`). Nothing in `/etc`, `/run`, `/tmp`, `/home`, etc. If it's not in the store, it's not a valid activation target.

**b) Allowed symlink destinations**:
Activation may create symlinks **only inside the profile realization directory being built**, e.g. `/mere/profiles/system/gen-<N>/...` or `/mere/profiles/<name>/.root-new-<nonce>/...`. Never write outside that tree during build. The only exception is the control pointer used to publish the finished realization (`/mere/profiles/system/current` for the system profile, or the final `root/` exchange for a named profile).

**c) Relative symlinks inside packages**:
Yes, relative symlinks in store payloads are allowed **if they resolve safely**. Absolute symlinks are allowed only if they resolve within the same store root (rare; usually reject them as escape hatches).

**d) Symlink chain validation**:
Validate symlinks as **a chain**, not single-hop. Rules:
- Resolve symlink chains with controlled traversal:
  - **Max depth: 64** (hard limit, covers all reasonable cases)
  - Loop detection (track visited paths)
  - Path traversal (`..`) rejection if it would escape the boundary
- Boundary depends on context:
  - Store-internal links: boundary is the **store root** of that package
  - Profile links: target must stay in **store**, destination must stay in **profile root**

**Resolution algorithm** (controlled traversal with boundary checking):
1. Read symlink target via `readlink()`
2. If target is relative, resolve against symlink's parent directory
3. Normalize path (collapse `.`, `..`, redundant slashes)
4. Check boundary at each step - reject if path escapes allowed root
5. If result is still a symlink, repeat from step 1 (increment depth counter)
6. Stop when target is not a symlink, or depth exceeded, or loop detected

**e) Internal package symlinks** (e.g., `libfoo.so -> libfoo.so.1`):
Allowed and expected. Treated as normal store payload. Requirement: when resolved, must not escape the package's store root. Chains like `libfoo.so -> libfoo.so.1 -> libfoo.so.1.2` are fine. A symlink like `libfoo.so -> /usr/lib/libfoo.so.1` is rejected (points outside store).

**Two validators**:

1. **Store payload validator** (at package creation and store ingestion):
   - Runs when the payload is materialized as a filesystem tree:
     - At package creation time (`mere dev build`) - validates staged directory before archiving
     - At store ingestion/install time (`mere install`) - validates extracted package before moving to store
   - Does NOT run at `mere dev import` - which is metadata-focused and doesn't fully extract payloads
   - Walk all symlinks inside the payload root
   - Ensure each symlink's resolved target stays within that same root
   - Reject links that escape, loop, or exceed depth

2. **Profile realization validator** (during realization build):
   - Every symlink created in profile must:
     - Have destination path within the profile root
     - Target a path within `/mere/store/` (ideally within store roots listed in generation manifest)

---

### 8. Atomic Switching Mechanics

**Symlink structure**:
```
/usr/bin -> /mere/profiles/system/current/usr/bin
/mere/profiles/system/current -> gen-<N>
```

**Switching procedure**:
1. Validate the target generation:
   - Generation directory exists
   - `profile.kdl` exists and parses (completion marker)
   - Schema version is sane
2. Clean up any stale temp symlink (idempotent): `unlink(".current-new")` ignoring ENOENT
3. Create temporary symlink: `/mere/profiles/system/.current-new -> gen-<N>`
4. Atomic rename: `rename("/mere/profiles/system/.current-new", "/mere/profiles/system/current")`

**Validation philosophy**: The manifest serves as a **completion marker** - its presence and parseability indicates "this generation was assembled coherently." Activation performs **fast integrity checks** (store paths exist, are within `/mere/store`, and are root-owned/read-only for the system profile). For system profile activation, content hash verification is **mandatory for unhardened store objects** — the content hash is recomputed and compared against the manifest before hardening. Already-hardened objects (root-owned with immutable flags) skip verification since they were verified when first admitted. This ensures correctness without redundant work on subsequent installs. For named (non-system) profiles, full hash verification remains opt-in due to cost.

**Idempotent cleanup**: If `.current-new` exists from a previously interrupted switch, it is deleted unconditionally before creating a new one. This makes switching idempotent and self-healing.

**Concurrency**: No locking is required. The atomic rename is the TOCTOU prevention - the system is always in a valid state. Concurrent switches result in last-writer-wins, which is acceptable (though potentially confusing for users).

**How many symlinks change**: Exactly **one** (`/mere/profiles/system/current`). The `/usr` subtree symlinks (`/usr/bin`, `/usr/lib`, etc.) never change after initial setup.

**Running processes**: Not migrated. Old processes continue seeing old paths (via their already-opened file descriptors and cached paths). New processes see the new profile. Process restarts are policy/service-management concerns, not handled by the switch itself.

**Rollback**: Same procedure in reverse - atomically update `/mere/profiles/system/current` to point back to `gen-<N>` (or any previous generation that still exists).

---

### 9. Path Hierarchy and Configuration

Mere uses a single system-wide root at `/mere/` (or `${root}/mere/` for alternate roots). User-specific data is minimal.

#### 9.0.1 System Paths (`/mere/`)

```
/mere/
├── config.kdl              # System-wide configuration (remote repos, global settings)
├── store/                  # Content-addressed package storage (mode 1777, sticky bit)
│   ├── .incoming/          # Temporary staging for atomic admission
│   └── <hash>-<name>-<version>/
│       ├── manifest.v1     # Package manifest (excluded from content hash)
│       ├── manifest.v1.sig # Manifest signature (excluded from content hash)
│       └── ...             # Package payload
├── profiles/               # System generations + named profile roots
│   ├── system/             # System profile (root-owned)
│   │   ├── current -> gen-N
│   │   └── gen-N/
│   └── <user>/             # User profiles
│       └── root/           # Live realized tree for the named profile
│           └── profile.kdl
├── dev/                    # Local development state (mode 1777 subdirs)
│   ├── repo/
│   │   └── <name>/
│   │       ├── refs/
│   │       │   └── current -> ../gens/gen-<N>/
│   │       ├── gens/
│   │       │   └── gen-<N>/
│   │       │       ├── <name>.db
│   │       │       └── <name>.db.sig
│   ├── build/
│   │   └── <name>-<version>-<release>-<uuid>/
│   │       ├── build-src/        # MERE_BUILD_DIR - source unpack + phase working directory
│   │       ├── sources/          # MERE_SOURCES_DIR - downloaded/copied source artifacts (optional)
│   │       ├── dest/             # MERE_DESTDIR / DESTDIR - install destination root
│   │       ├── profile/          # Build dependency environment (symlinks into store)
│   │       ├── build.log
│   │       └── build-report.kdl
│   ├── outputs/            # Latest built package archives by recipe tuple
│   └── cache/
│       ├── sources/        # Shared source artifact cache for local builds
│       └── build/          # Shared build execution cache for local builds
├── cache/                  # Downloaded artifacts (can be purged)
│   ├── packages/           # Shared package archive pool (canonical archive_hash filenames, GC-managed)
│   └── repos/
│       └── <name>-<hash16>/   # Trust-context-scoped cache directory
│           ├── <name>.db
│           ├── last_sync.kdl
├── gc-roots/               # GC root symlinks (admin-controlled, NOT world-writable)
│   ├── profiles/
│   │   ├── system/
│   │   │   ├── current -> /mere/profiles/system/current
│   │   │   └── kept/
│   │   │       └── gen-N -> /mere/profiles/system/gen-N
│   └── pins/
│       └── <pin-name> -> /mere/store/<hash>-<name>-<version>/
└── keys/                   # System-wide public keys (optional)
```

#### 9.0.2 User Paths (`~/.mere/`)

```
~/.mere/
├── keys/                   # User's personal signing keys (secrets)
└── trusted.kdl             # Fingerprints this user trusts
```


**Directory Permissions**:

| Directory             | Owner     | Mode | Rationale                                                                   |
| --------------------- | --------- | ---- | --------------------------------------------------------------------------- |
| `/mere/store/`        | root:root | 1777 | **Required**: Allows unprivileged admission, prevents unauthorized deletion |
| `/mere/dev/repo/`   | root:root | 1777 | **Required**: Multi-user local repo authoring without conflicts              |
| `/mere/dev/build/`  | root:root | 1777 | **Required**: Multi-user build workspaces, prevents workspace deletion       |
| `/mere/dev/outputs/` | root:root | 1777 | Latest exported build outputs by recipe tuple                               |
| `/mere/dev/cache/`  | root:root | 1777 | Shared developer cache root for build workflow state                         |
| `/mere/dev/cache/sources/` | root:root | 1777 | Shared local source cache for development builds                     |
| `/mere/dev/cache/build/` | root:root | 1777 | Shared build execution cache for development builds                  |
| `/mere/gc-roots/`     | root:root | 0755 | **Required**: Admin-controlled GC keep-set, NOT world-writable              |
| `/mere/cache/`        | root:root | 1777 | Shared cache root, safe concurrent use                                       |
| `/mere/cache/packages/` | root:root | 1777 | Shared package archive pool for local reuse; `mere store clean` prunes unreferenced archives |
| `/mere/cache/repos/`  | root:root | 1777 | Remote repository sync cache                                                  |

**Build Workspace Structure**:

The `${root}/mere/dev/build/<name>-<version>-<release>-<uuid>/` directory is the canonical host-visible build workspace:
- **Primary debugging artifact** for build inspection
- **Workspace naming**: `<name>-<version>-<release>-<uuid>` where `<name>`, `<version>`, `<release>` come from the recipe and `<uuid>` is a random hex string for uniqueness
- **Lifecycle**: Preserved by default on both success and failure until explicit cleanup
- **Minimum structure**: `build-src/` (working tree), `sources/` (downloads, optional), `dest/` (staging root), `profile/` (build dependency environment), `build.log`, and `build-report.kdl`

The build profile (`profile/`) contains the realized build dependency environment (symlinks into the store). It is ephemeral, created fresh for each build, and lives inside the preserved workspace.

#### 9.0.3 Access Model

| Path                     | Owner | Write Access                          | Purpose                                                    |
| ------------------------ | ----- | ------------------------------------- | ---------------------------------------------------------- |
| `/mere/config.kdl`       | root  | root only                             | Remote repos, global settings                              |
| `/mere/dev/repo/`         | root  | anyone can create subdirs             | Local repo sources (authoritative, mutated by mere import) |
| `/mere/dev/build/`        | root  | anyone can create subdirs             | Build workspaces                                           |
| `/mere/dev/outputs/`      | root  | anyone can create subdirs             | Exported build outputs                                     |
| `/mere/dev/cache/`        | root  | anyone can create subdirs             | Development cache root                                     |
| `/mere/dev/cache/sources/`| root  | anyone can create subdirs             | Shared local source cache for builds                       |
| `/mere/dev/cache/build/`  | root  | anyone can create subdirs             | Shared build execution cache for builds                    |
| `/mere/store/`            | root  | anyone can add (append-only protocol) | Package content                                            |
| `/mere/store/.incoming/`  | root  | anyone                                | Temporary staging                                          |
| `/mere/profiles/system/` | root  | root only                             | System profile                                             |
| `/mere/profiles/<user>/` | user  | user                                  | User profiles                                              |
| `~/.mere/keys/`          | user  | user                                  | Personal signing keys                                      |
| `~/.mere/trusted.kdl`    | user  | user                                  | Personal trust config                                      |

---

### 9.1 Configuration Files

#### config.kdl (`/mere/config.kdl`)

System-wide configuration defining remote repositories and global settings:

```kdl
// Remote repository definitions
settings {
    // Remote repo sync defaults (seconds)
    sync-ttl 900
    sync-timeout 30
    color false
}

repo "core" {
    url "https://repo.mere.linux/core"
    priority 100
    // Optional overrides (seconds)
    sync-ttl 900
    sync-timeout 30
    // Trusted fingerprints for THIS repo's DB signature
    trusted-fingerprints "abc123...64chars..."  // Official Mere key
}

repo "community" {
    url "https://repo.mere.linux/community"
    priority 200
    trusted-fingerprints "def456...64chars..."
}
```

**Remote repos require trusted fingerprints**: Each remote repo definition MUST include at least one trusted fingerprint. If verification fails or no fingerprints are configured, it is an error.
**Sync TTL and timeout apply only to remote repos**. Local dev repositories are not subject to TTL/timeout settings.

#### trusted.kdl (`~/.mere/trusted.kdl`)

Per-user list of trusted signing key fingerprints **for local repos**:

```kdl
// Fingerprints I trust for LOCAL repository database signatures
// (repos auto-discovered from /mere/dev/repo/)
trusted-fingerprint "abc123...64chars..."  // Official Mere key
trusted-fingerprint "def456...64chars..."  // Bob's key (coworker)
```

**Semantics**:
- Applies to auto-discovered local repos in `/mere/dev/repo/`
- If a local repo's signing key isn't in the user's trusted.kdl, the repo is skipped

**Empty trusted.kdl**: If the file is missing or empty, no local repositories are trusted (they are skipped).

---

### 9.2 Key Resolution and Security

Keys are stored in `~/.mere/keys/` (user signing keys) and `/mere/keys/` (system-wide public keys).

**Key matching**: By **fingerprint**, not by repo name or filename. Fingerprint is the BLAKE3 hash of the public key bytes (32 bytes → 64 hex chars).

**Trust model** (two distinct paths):

| Repo Type                   | Trust Source                             | On Verification Failure                           |
| --------------------------- | ---------------------------------------- | ------------------------------------------------- |
| Remote (config.kdl)         | `trusted-fingerprints` in repo definition | **Hard error** - admin configured it, must verify |
| Local (/mere/dev/repo/) | User's `~/.mere/trusted.kdl`             | **Skip repo** - user hasn't opted in              |

**Key lookup procedure**:
1. Load all `.pub` files from `/mere/keys/` and `~/.mere/keys/`
2. Compute fingerprint for each loaded key
3. For verification, find a key whose fingerprint matches the trust source (config.kdl or trusted.kdl)
4. Verify the signature against that key

**No shadowing problem**: Since matching is by fingerprint (cryptographic identity), user keys cannot "shadow" system keys. A key either matches the fingerprint or it doesn't.

**Key file naming**: Filenames are labels only (e.g., `mere-official.pub`). Tools MUST NOT infer trust or identity from filenames.

---

### 9.3 Repository Sources vs Repository Cache

Mere separates authoritative artifacts from synced copies:

**Shared package pool** (local canonical package archive store):
- Lives at `/mere/cache/packages/`
- Canonical filename: `<name>-<version>-<release>-<arch>-<archive_hash>.pkg.tar.zst`
- Used by local authoring, publish staging, and remote sync ingestion to avoid duplicate archive copies
- Repository DB entries bind to packages via `(name, version, release, arch, content_hash, archive_hash)`
- `mere store clean` prunes archives not referenced by any local repo `current/repo.db` or `previous/repo.db`

**Repository cache** (synced, derived — remote repos only):
- Lives at `/mere/cache/repos/<name>-<hash16>/` where `<hash16>` is the first 16 hex characters of a BLAKE3 hash derived from the repo's trust context
- Cache identity hash derivation: sort trusted fingerprints lexicographically, concatenate them, append `"\0"` and the repo name (`sorted_fp1 || sorted_fp2 || ... || "\0" || name`), compute BLAKE3, take first 16 hex characters
- Different trust configurations (same name, different fingerprints) produce isolated cache directories
- Populated by syncing from remote repository URLs defined in `config.kdl`
- Read-only from user perspective; managed by repocache
- Tracks last successful sync time in `last_sync.kdl`
- On first sync, any old-format directory (`/mere/cache/repos/<name>/`) is deleted automatically (non-fatal on failure)
- **Not used for local package storage**: local package archives are stored in `/mere/cache/packages/`, not per-repo cache directories

**Repository source** (local, authoritative, mutated by `mere import`):
- Lives at `/mere/dev/repo/<name>/`
- Auto-discovered: any valid repo structure under `/mere/dev/repo/` is usable
- No config entry needed - presence is sufficient
- Accessed directly by `RepoCache` — the `cache_dir` points at the source directory itself, avoiding data duplication and stale cache issues
- Signature is verified once on first access; subsequent operations use the already-opened database without re-verification

**Distinction**: A repository source is local because it's a directory you mutate (import writes DB/signature state). A configured remote repo is a URL you sync into cache.

---

### 9.4 Repository Source Layout

A repository source named `<name>` uses a generation-based layout:

```
/mere/dev/repo/<name>/
├── refs/
│   └── current -> ../gens/gen-<N>/     # Active generation pointer
├── gens/
│   ├── gen-1/
│   │   ├── <name>.db                   # SQLite database
│   │   └── <name>.db.sig               # Repository database signature
│   └── gen-2/...
```

**Validation**: A directory is a valid repository source if:
1. `current` symlink exists and resolves to a valid `gens/gen-<N>/` directory
2. `<name>.db` exists within the active generation and is a valid SQLite database
3. `<name>.db.sig` exists within the active generation
4. Signature verifies against a key the user trusts (otherwise repo is skipped)

**Generation rules**:
- `current` symlink MUST be the active repository state used by resolver/install
- Each `gens/gen-N/` MUST be self-contained (`.db`, `.db.sig`)
- Generation activation MUST be an atomic pointer update (temp symlink + rename)
- Repositories without `current` symlink are skipped during local repo discovery

---

### 9.5 Repository Resolution

When resolving repositories for operations:

1. **Remote repos**: Load from `config.kdl`, sync to cache
2. **Local repos**: Auto-discover from `/mere/dev/repo/*/`
3. **Naming conflicts**: If a local repo name matches a remote repo name, **error**. User must rename one.
4. **Trust filtering**: Repos whose DB signature doesn't verify against user's `trusted.kdl` are **skipped** (with debug message)

**Priority**: Remote repos use configured priority. Local repos use default priority.

**Sync policy (remote repos)**:
- `mere install` syncs each remote repo **only if stale** (based on `last_sync.kdl`)
- Default TTL is **15 minutes**
- `--sync` forces a sync regardless of TTL
- `last_sync.kdl` format:
  ```
  sync at=<unix-seconds>
  ```
- On sync failure:
  - If a previously verified cache exists (DB + sig present and `last_sync.kdl` exists), **fall back to cached DB** with a warning/info message

**Sync policy (local repos)**:
- No download or file copying — the source directory is used directly
- Signature is verified at discovery time (`discoverLocalRepos`); the sync step is a no-op
- No `last_sync.kdl` is written
- No TTL or timeout applies
- No old-format cache migration applies

---

### 9.6 Repository Resolution for `mere import`

`mere import <name> <pkg>` resolves the repository source directory:

1. If a repo source exists at `/mere/dev/repo/<name>/`, use it
2. Else if a signing key can be resolved (from `--key` or default `~/.mere/keys/mere.key`), bootstrap a new repository (see 9.8)
3. Else: error "Repository '<name>' not found and no signing key available to bootstrap"

**Normative rule**: `mere import` MUST NOT accept a raw filesystem path to a SQLite database. Repository names map to directories via the standard layout.

---

### 9.7 `mere import` Behavior

`mere import <repo-name> <package-file> [--key <path>]`

1. Resolve `<repo-name>` to directory (per 9.6)
2. Extract manifest from package, validate format
3. Verify package manifest signature against trusted keys available on the authoring machine (hard error on failure)
4. Verify content hash matches package contents (integrity check)
5. Copy package to `/mere/cache/packages/` using canonical filename
6. Add package metadata to `<name>.db`
7. Sign `<name>.db` → `<name>.db.sig` using `--key` or default signing key

**Signature verification is required at import time.** This acts as an authoring quality gate to ensure repository contents are publish-ready.

---

### 9.8 Repository Bootstrap

If a repository source does **not exist** and a signing key can be resolved:

- Create the generation-layout skeleton at `/mere/dev/repo/<name>/`:
  - `refs/` directory with `current` symlink pointing to `../gens/gen-1/`
  - `gens/gen-1/` directory
- Create empty `<name>.db` with schema in `gens/gen-1/`
- Proceed with import
- Sign `<name>.db` with the resolved key
- If any step fails, clean up the partially-created directory

**Key resolution order**:
1. `--key <path>` if provided
2. Default user key at `~/.mere/keys/mere.key`

**Without a resolvable key**: Error "Repository '<name>' not found and no signing key available to bootstrap (checked --key and ~/.mere/keys/mere.key)"

---

### 9.9 Release Publication Requirements

Local repository authoring and public release publication are distinct phases:

- `/mere/dev/repo/<name>/` is for local iteration and testing.
- Local package archives are sourced from `/mere/cache/packages/`.
- Public release output is the externally consumed `{repo}.db`, `{repo}.db.sig`, and `packages/` set.

Normative publication requirements:

1. Publication MUST build the output DB from the dev repo (`/mere/dev/repo/<name>/`) as the sole source of truth. The output directory is a write-only target; it is never read as input.
2. Publication MUST select packages from the dev repo (all latest by default, or explicit selectors) and apply keep-count retention (default N=3 per `(name, arch)`).
3. All selected package archives MUST exist in the local shared pool (`/mere/cache/packages/`). Publication MUST fail if any required archive is missing.
4. Publication MUST fail if repository DB rows and published `packages/` archives do not match by `(name, version, release, arch, content_hash, archive_hash)`.
5. Archive filenames in both `/mere/cache/packages/` and published `packages/` MUST use `<name>-<version>-<release>-<arch>-<archive_hash>.pkg.tar.zst`.

---

### 9.10 Trust Model Summary

| Operation      | Repo Type | Who decides trust | How                                       | On Failure |
| -------------- | --------- | ----------------- | ----------------------------------------- | ---------- |
| Repo sync      | Remote    | Admin             | `trusted-fingerprints` in config.kdl       | Hard error |
| Repo sync      | Local     | User              | `~/.mere/trusted.kdl`                     | Skip repo  |
| `mere import`  | Local     | Importer          | Mandatory manifest signature verification | Hard error |
| `mere install` | Any       | Consumer          | Trusts repo DB (verified at sync time)    | N/A        |

**Producer side**: The repository maintainer controls what goes into their repo. The repo DB signature proves the maintainer published this exact database state.

**Consumer side**:
- **Remote repos**: Admin configures trusted fingerprints in `/mere/config.kdl`
- **Local repos**: Each user configures which signing keys they trust in `~/.mere/trusted.kdl`. Repos signed by untrusted keys are silently skipped

**Package manifest signatures** (inside `.mere/manifest.v1.sig`) provide an additional layer proving who built the package. Verification is mandatory during install/store admission.

---

## Dependency Resolution

### 10. Dependency Resolution Algorithm

**Strategy**: Deterministic greedy resolver with limited backtracking.

**Provider selection order** (first matching wins):
1. **Pins** - explicit system pins override everything (admin-controlled)
2. **Highest version** - using vercmp algorithm (spec #3)
3. **Highest release** - tie-breaker within same version
4. **Repo priority** - lower priority number wins (as configured)

**Backtracking**: Limited backtracking within a requirement's candidate list when conflicts arise. Not a full SAT solver - if greedy + backtracking fails, report error.

**Cycle handling**: Tolerate dependency cycles via **SCC (Strongly Connected Component) condensation**. Treat each SCC as a unit for ordering purposes. Cycles are not errors - they're installed together.

**Conflict handling**: **Hard errors** unless explicit policy/pins select a resolution.
- Path conflicts (two packages own same path): error - detected during profile building
- Provision ambiguity (multiple packages could satisfy a requirement without deterministic selection): error - detected during resolution
- Incompatible version constraints: error

**Normative distinction**:
- Multiple packages CAN provide the same `(type, resource)` in the repository
- Provision ambiguity only occurs during resolution when:
  1. A dependency requires a provision
  2. Multiple packages in the candidate set could satisfy it
  3. The selection rules (pins → version → release → repo priority) don't produce a unique winner

**No silent conflict solving**. User must explicitly resolve via pins or policy.

**Output**: A deterministic installation order (topological sort of condensed dependency graph).

#### 10.1 Resolution Failure Diagnostics

When dependency resolution fails, implementations MUST provide diagnostics that include:
- The failing requirement
- All candidate providers considered
- The rule that rejected each candidate (version, release, pin, priority, conflict)

**Backtracking Exhaustion**: If limited backtracking fails:
- The resolver MUST report the minimal conflicting set
- Silent fallback or heuristic resolution is prohibited

**Normative invariant**: Resolution errors must be actionable without guesswork. This aligns with Mere's prohibition on silent conflict solving.

---

### 11. Repository Priority vs Version

**Rule**: Version wins by default. Repository priority is a tie-breaker, not a "prefer older stable even if newer exists elsewhere" mechanism.

**Selection order** (confirming spec #10):
1. Pins (explicit override)
2. Highest version (vercmp)
3. Highest release
4. Repo priority (tie-breaker only)

**Example**: If `core` repo (priority 10) has `foo-1.0` and `community` repo (priority 50) has `foo-1.1`, the resolver picks `foo-1.1` from `community` because version wins.

---

## Garbage Collection

### 12. GC Root Storage

GC roots are a combination of:
- **Directory-namespaced symlinks under `/mere/gc-roots/`** for the system profile and explicit pins
- **Direct named-profile manifests** under `/mere/profiles/<name>/root/profile.kdl`

**Structure**:
```
/mere/gc-roots/
├── profiles/
│   ├── system/
│   │   ├── current -> /mere/profiles/system/current
│   │   └── kept/
│   │       ├── gen-41 -> /mere/profiles/system/gen-41
│   │       └── gen-42 -> /mere/profiles/system/gen-42
└── pins/
    ├── my-pin -> /mere/store/<hash>-foo-1.0/
    ├── my-pin.note
    └── ...
```

Named profiles are **not** mirrored into `/mere/gc-roots/`. Their live realized trees are rooted directly by the existence of `/mere/profiles/<name>/root/profile.kdl`.

**Pins**: Named symlinks under `gc-roots/pins/` pointing to store paths. Optionally accompanied by a `.note` file (plain text) explaining why the pin exists.

**What creates/removes roots**:
- **System generation switching**: Creates/maintains roots for active and kept system generations
- **Named profile install/uninstall**: Replaces the live `root/` realization in-place
- **Admin commands**: `mere store pin` / `mere store pin remove` create/remove explicit pins (requires root)
- **GC**: Never mutates roots - only deletes store paths unreachable from any root

**System generation retention policy**:

A generation is "kept" (has a GC root) if:
1. It is the **active system generation** (always rooted as `current`), OR
2. It is among the **last K system generations** (default K=2, configurable), OR
3. It has an **explicit keep marker** (`/mere/profiles/system/gen-N/.keep` exists)

**Keep marker files**:
- `/mere/profiles/system/gen-N/.keep` - empty file or small text marking a system generation as explicitly kept
- `/mere/profiles/system/gen-N/.keep.note` - optional human explanation (like pin notes)

**Root management during system activation**:
1. Update `gc-roots/profiles/system/current` to point to the active generation
2. For each kept system generation: ensure a root exists under `gc-roots/profiles/system/kept/`
3. For system generations not satisfying kept criteria: remove the root from `kept/`

**Named profile liveness**:
- A named profile is live if `/mere/profiles/<name>/root/profile.kdl` exists and parses
- No additional GC-root symlink is created for named profiles
- Deleting the profile directory removes that root

**Generation deletion** (`mere store generation delete <N>`):
- Removes the generation directory (`/mere/profiles/system/gen-N/`)
- Removes the corresponding root if it exists
- Fails if trying to delete the active generation

**Explicit keep/unkeep commands**:
- `mere store generation keep <N>` - creates `.keep` marker on a system generation
- `mere store generation unkeep <N>` - removes `.keep` marker (the generation may still be rooted by the retention window)

**GC algorithm (MVP)**:

GC is filesystem-driven and does not perform transitive dependency closure at GC time. A system generation or named profile realization is already the realized closure of what's needed. GC keeps exactly what those realized manifests and explicit pins reference.

Algorithm:
1. **Collect reachable set**:
   - Walk all symlinks in `/mere/gc-roots/` recursively
   - For system generation roots (under `profiles/system/`):
     - Follow symlink to generation directory
     - Read generation manifest
     - Derive store path from each package entry (content-hash + name + version)
     - Add each to reachable set
   - For pin roots (under `pins/`):
     - Add store path to reachable set directly
   - For each named profile under `/mere/profiles/`:
     - If `root/profile.kdl` exists, read it
     - Derive store path from each package entry (content-hash + name + version)
     - Add each to reachable set

2. **Enumerate candidates**:
   - Scan `/mere/store/` directory
   - Each direct child directory is a candidate store object
   - `.incoming/` is not a store object and is not a deletion candidate here; it is swept separately in step 5
   - Don't parse name/version from path; use exact path for reachability

3. **Delete unreachable**:
   - For each candidate not in reachable set:
     - Verify path is exactly a direct child of `/mere/store/`
     - Verify path is a directory (not symlink or file)
     - Clear filesystem immutable flags (`FS_IMMUTABLE_FL`) recursively on all files and directories before deletion
     - Delete recursively

4. **Prune unkept system generations**:
   - Enumerate `gen-N/` directories under `/mere/profiles/system/`
   - Determine the kept set using system retention policy (`current`, last K, `.keep`)
   - Delete any system generation directory not in the kept set

5. **Reclaim abandoned store staging**:
   - Sweep `/mere/store/.incoming/` under the scratch ownership protocol (§4.3)
   - Live staging directories (owner lock held) are left untouched
   - Reclaimed directories are reported alongside deleted store paths

System generation pruning is therefore decoupled from activation: switches update the keep-set, and `mere store clean` is the operation that reclaims unkept system generations on disk.

**Safety measures**:
- Refuse to run GC if `/mere/gc-roots/` has no roots
- Only delete direct children of `/mere/store/` that are directories
- Don't follow symlinks when scanning the store
- Take exclusive lock (same as switching) to prevent races with installs/activation

**CLI**:
- `mere store clean` - run garbage collection (store objects + unkept system generations)
- `mere store clean --dry-run` - show what would be deleted (paths + count) without deleting

**Dry-run output**:
```
Would delete:
  /mere/store/abc123...-oldpkg-1.0/
  /mere/store/def456...-unused-2.0/
  /mere/profiles/system/gen-3/
Summary: would delete 3 paths
```

**Safety**: GC never deletes a store path that is reachable from any root. Roots are the single source of truth for "what to keep".

---

## Configuration Management

### 13. Config Template System

**Template location**: `${store_root}/etc-defaults/**` maps to `/etc/**`

Example:
```
/mere/store/<hash>-nginx-1.0/etc-defaults/nginx/nginx.conf
  → /etc/nginx/nginx.conf
```

**When templates are processed**: During generation activation. Template processing is part of the "switch to system-N" flow, not a separate user-invoked step.

**Template scanning**: Walk each package's store root at activation time, looking for `etc-defaults/` subtrees. This follows the "filesystem as truth" pattern—no separate template registry in the manifest.

**Which packages**: All packages in the active generation are scanned. The
idempotent rules (copy if missing, skip if identical, report drift if differs)
make this safe and simple.

**Activation behavior**:
- If destination **missing** → copy template to `/etc`
- If destination **exists and differs** → leave `/etc` unchanged and record the
  drift in activation output
- If destination **exists and identical** → do nothing

**Key rule**: Activation **never overwrites** existing `/etc` files. User customizations are always preserved.

**Duplicate template paths**: If two packages in the same generation both provide `etc-defaults/<path>` (same destination), activation MUST fail with an error. No implicit ordering or "last wins" behavior is permitted.

#### 13.1 Template Processing Determinism

**Scan Order**: Packages are scanned for `etc-defaults/**` templates in deterministic order:
1. Sorted by package name (lexicographically)
2. Then by version (vercmp)
3. Then by release

**Collision Errors**: If two packages provide the same destination path:
- Activation MUST fail
- The error MUST list both providers explicitly

**Drift handling**: Activation MUST NOT eagerly materialize `.new` files for
differing paths. Drift is inspected and applied on demand through `mere etc`
commands using the active generation's `etc-defaults/**` trees as the source of
truth.

**Rollback behavior**: `/etc` is host-owned and mutable. Rolling back to a previous generation does not rewind `/etc` state. The rollback changes `/usr` (via profile switching), but `/etc` remains whatever the host currently has. Rolling back may cause activation to report different drift against active defaults, but never overwrites.

**User helpers**:
- `mere etc status` - list differing and missing `/etc` paths relative to the active system generation
- `mere etc diff <path>` - show diff between current `/etc` content and the active generation's default
- `mere etc apply <path>` - install or replace `/etc` with the active generation's default, backing up to `.old` when replacing

**No templating language**: Despite the name "templates," these are literal config files, not a templating language with variables or conditionals. "Template" here means "packaged default config file."

---

## Build Environment

### 14. Build Environment Details

#### Shell Interpreter
- Phases executed using **POSIX `/bin/sh -e -c "<phase script>"`**
- `-e` causes abort on first failing command
- Recipes must not rely on bash-specific features (POSIX sh only)

#### Workspace Structure
Each build gets a unique workspace:
```
${root}/mere/dev/build/<name>-<version>-<release>-<uuid>/
├── build-src/      # MERE_BUILD_DIR - source unpack + phase working directory
├── sources/  # MERE_SOURCES_DIR - downloaded/copied source artifacts (patches, configs)
├── dest/     # MERE_DESTDIR / DESTDIR - install destination root
└── profile/  # Build dependency environment (symlinks into store)
```

The workspace directory is bind-mounted to `/work` inside the chroot namespace.

#### Working Directory
- Phases start in `MERE_BUILD_DIR` by default
- Recipes may `cd` explicitly if needed

#### Guaranteed Environment Variables

**Paths:**
- `MERE_BUILD_DIR` - build/source working directory for phases
- `MERE_SOURCES_DIR` - downloaded/copied source artifacts (patches, configs)
- `MERE_DESTDIR` - install destination root

**Build compatibility:**
- `DESTDIR=${MERE_DESTDIR}`
- `PREFIX=/usr`
- `PATH` explicitly set to minimal toolchain (no host leakage)

#### Multiple Output Packages
- **Build phases** (`prepare`, `build`, `check`) run **once**, shared across all outputs
- **Install phase** runs **once**, installing into `MERE_DESTDIR` / `DESTDIR`
- Output packages are split by each package's `files` patterns against `DESTDIR`
- Packages must not write outside `MERE_DESTDIR` / `DESTDIR`

#### Failure Semantics
- **Any phase failure aborts the entire build**
- Phase fails if shell exits non-zero
- Partial success not allowed (no "one subpackage built, another failed")
- Failures reported via diagnostic context (phase, output package, failing command)

#### 14.0 Build Workspaces and Artifact Reuse

Build execution MUST use a fresh scratch workspace under `${root}/mere/dev/build/<name>-<version>-<release>-<uuid>/`.

That workspace is an execution scratch area, not resumable build state. Reuse MUST come from explicit build artifacts and cache keys, not from resuming a prior mutable session.

The build runner MUST execute phases as **discrete invocations**, not one merged shell script:

1. `prepare` (if present)
2. `build` (if present)
3. `check` (if present)
4. `install` (if present)
5. `package` (split staging + archive creation)

Each phase invocation MUST run as:

- POSIX `/bin/sh -e -c "<phase script>"`

The process environment MUST be re-established for each phase. Shell process state from earlier phases (working shell variables, shell functions, traps, etc.) MUST NOT be relied upon.

**Execution artifact model**:

- Build reuse MUST be represented by explicit cached artifacts, not hidden session checkpoints.
- Cached artifact classes MUST include at least:
  - fetched sources
  - unpacked source tree
  - realized dependency profile tree
  - per-phase outputs for `prepare`, `build`, `check`, and `install`
  - split staging tree
  - package archives
- Re-running the same build request MUST be the mechanism for reuse and recovery. There is no separate resume command.

**Execution backend model**:

- Build execution MUST be represented internally as a coarse node pipeline with explicit node kinds and explicit artifact outputs.
- The minimum node set MUST include:
  - `source_fetch`
  - `source_unpack`
  - `profile_realize`
  - `prepare`
  - `build`
  - `check`
  - `install`
  - `split_stage`
  - `package_archive`
- The build orchestrator MUST NOT be the source of cache protocol truth. Cache key computation, cache restore, and cache store behavior for these node kinds MUST live behind a dedicated execution backend / solver boundary.
- The orchestrator MAY still own miss-path execution details (for example invoking phase scripts or package splitting) so long as the solver boundary remains the authoritative execution-cache interface.

**Solver API model**:

- The execution backend MUST expose typed request/response APIs for cacheable build operations rather than requiring callers to construct ad hoc cache key and artifact plumbing inline at each call site.
- Request construction MAY be step-specific and coarse; the system does not require a generic unrestricted DAG language.
- The current build pipeline MAY remain ordered and mostly linear even when represented through explicit node and solver APIs.

**Artifact identity rules**:

- Final package/store identity MUST remain content-addressed and MUST ignore mtimes.
- Build execution snapshots MUST use a separate identity relation that includes operationally relevant metadata required for correct tool behavior.
- For directory/tree snapshots used by the build cache, that operational metadata MUST include file mtimes and mode bits at minimum.

**Failure and preservation rules**:

- On phase failure, the build MUST fail immediately.
- The scratch workspace MUST be preserved for inspection.
- Failure output MUST identify the preserved workspace path.
- On full success, the scratch workspace MUST remain available for inspection until explicit cleanup.
- Successful build output SHOULD identify the workspace path, build log path, and build report path.

**CLI contract**:

- `mere dev build <recipe>` executes a build in a fresh scratch workspace.
- `mere dev build --no-cache <recipe>` MUST skip build-cache reads for that run while still writing newly produced cache artifacts.

**Build outputs and lifecycle**:

- Successful development-build package archives MUST be exported to `${root}/mere/dev/outputs/<name>-<version>-<release>-<arch>/`, where the tuple identifies the source recipe. The per-build subdirectory MUST be wiped and recreated on each build so it always reflects exactly the latest result.
- Development build outputs are not build-cache entries and MUST NOT be deleted by `mere dev clean --cache`.
- `mere dev import <repo>` MAY use `${root}/mere/dev/outputs/` as the default source of locally built package archives, scanning all per-build subdirectories.

**Packaging concurrency**:

- Split analysis and staging MAY remain serial.
- Package archive creation MAY execute in parallel once per-package staged trees are ready.
- Parallel archive execution MUST preserve deterministic result ordering in user-visible build results and reporting.

### 14.1 Build Isolation Model (Mount Namespace + userns + chroot)

All builds execute inside a **mount-namespace-isolated synthetic root** with **bind mounts**, a **user namespace**, and **chroot**. Profile directories and `/mere` are bind-mounted into the synthetic root so that store symlinks resolve correctly.

`mere shell` uses the same namespace mechanism with a different mount policy: host `/home`, `/var`, `/run`, `/dev` are accessible, `/etc` uses overlayfs (with fallback to read-only bind mount), and `/mere` is read-write so `mere install` works from inside.

Session directories are created under `$XDG_RUNTIME_DIR/mere-env/<session-id>/`, falling back to `/tmp/mere-env-<uid>/<session-id>/` when `XDG_RUNTIME_DIR` is unset.

The session base directory (`mere-env` / `mere-env-<uid>`) MUST be a directory owned by the invoking user with no group or other access. Mere creates it mode `0700` and, if it already exists, MUST verify ownership and mode before use — refusing to proceed rather than reusing a base that is a symlink, is owned by another user, or is group/world accessible. The base is uid-scoped rather than a single shared name because it lives in a world-writable parent: a shared name belongs to whichever user creates it first, which both locks other users out and lets that user choose where another user's session tree — including the overlayfs upperdir backing `/etc` inside `mere shell` — is stored.

The mounts inside a session tree are private to its mount namespace and disappear when that namespace exits. The **directories do not**: they are reclaimed under the scratch ownership protocol (§4.3), not by namespace teardown.

#### 14.1.1 Build Workspace Root

Mere uses `${root}/mere/dev/build/` as the build workspace root directory:

- **Path**: `${root}/mere/dev/build/`
- **Owner**: `root:root`
- **Mode**: `1777` (world-writable with sticky bit)

#### 14.1.2 Workspace Naming

Each build execution allocates a unique workspace directory under `${root}/mere/dev/build/`:

- **Format**: `<name>-<version>-<release>-<uuid>`
- `<name>` is the recipe package name
- `<version>` is the recipe version
- `<release>` is the recipe release number
- `<uuid>` is a random hex string for uniqueness

Resulting path example:

- `${root}/mere/dev/build/nginx-1.24.0-1-a3f2b1c9d4e5f678/`

#### 14.1.3 Build Workspace Layout

Each workspace directory contains the build artifacts directly (no `root/` or `work/` subdirectories):

```
${root}/mere/dev/build/<name>-<version>-<release>-<uuid>/
├── build-src/        # MERE_BUILD_DIR - source unpack + phase working directory
├── sources/          # MERE_SOURCES_DIR - downloaded/copied source artifacts
├── dest/             # MERE_DESTDIR / DESTDIR - install destination root
├── profile/          # Build dependency environment (symlinks into store)
├── tmp/              # TMPDIR - disk-backed scratch for the build
├── build.log
└── build-report.kdl
```

The workspace directory is the canonical host-visible debugging artifact. Mere SHOULD print the workspace path prominently for both successful and failed builds.

#### 14.1.4 Namespace Isolation

Build execution uses the following namespace setup:

1. **User namespace** (`unshare(CLONE_NEWUSER)`) with uid/gid mapping
2. **Mount namespace** (`unshare(CLONE_NEWNS)`) to isolate all mount changes
3. **PID namespace** (`unshare(CLONE_NEWPID)`) so the environment sees only its own processes
4. **Private mounts** (`mount(MS_REC | MS_PRIVATE)` on `/`) to prevent propagation
5. **Fork**, so the child is PID 1 of the new PID namespace and performs all remaining setup
6. **Synthetic root** constructed at a session-specific temporary path
7. **Bind mounts** of profile directories (`bin`, `sbin`, `lib`, `usr`) into the synthetic root (read-only)
8. **Bind mount** of `/mere` into the synthetic root (read-only for builds)
9. **Bind mount** of the workspace directory to `/work` in the synthetic root
10. **Private procfs** mounted at `/proc` inside the synthetic root
11. **Chroot** into the synthetic root

Step 5 is required by step 10, not incidental: `unshare(CLONE_NEWPID)` moves only *children* into the new PID namespace, and mounting procfs requires the mounter to be inside the namespace the procfs will describe. The process that performs the unshare therefore cannot mount it. The forking process reaps its child and exits with the child's status, so callers observe the command's result unchanged.

Because the environment's command runs as PID 1, it does not receive default-action signals sent from inside the namespace, and its exit tears down anything else still running there.

#### 14.1.5 Build Mode Mounts

In build mode, the following mounts are applied:

- Workspace → `/work` (bind, read-write)
- tmpfs → `/var` and `/run`
- Generated minimal `/etc` → `/etc` (bind)
- tmpfs → `/dev` with essential device nodes (`null`, `zero`, `random`, `urandom`, `tty`)
- A **private procfs** → `/proc`, mounted `nosuid,nodev,noexec`
- tmpfs → `/tmp`

`/proc` MUST be a procfs mounted for the environment's own PID namespace. It MUST NOT be a bind mount of the host `/proc`, which places the host's entire process table — including other users' and other agents' command lines — inside the environment. If the procfs mount fails, the operation MUST fail; falling back to a host bind mount is prohibited, as it silently reintroduces the exposure.

The host `/etc` is NEVER exposed to build scripts. A minimal `/etc` is generated with basic `passwd`, `group`, `hosts`, and optionally `resolv.conf`.

#### 14.1.6 Working Directory and Environment Variables

Inside the chrooted environment:

- `MERE_BUILD_DIR` MUST be `/work/build-src`
- `MERE_SOURCES_DIR` MUST be `/work/sources`
- `MERE_DESTDIR` MUST be `/work/dest`
- `DESTDIR` MUST be set to `${MERE_DESTDIR}`
- `PREFIX` MUST be set to `/usr`
- `TMPDIR` MUST be `/work/tmp`

`TMPDIR` MUST point inside the workspace rather than being left unset. `/tmp` in the synthetic root is a bounded tmpfs (§14.1.5), so an unset `TMPDIR` sends every default-located temporary file into memory; compiling or linking a large package exhausts it and fails with `ENOSPC`. Routing temporaries to the workspace puts them on the same disk as the rest of the build and keeps them inspectable afterwards, alongside the other host-visible build artifacts.

A recipe MAY override `TMPDIR` through its own environment settings. Tools that ignore `TMPDIR` and hardcode `/tmp` remain subject to the tmpfs limit.

The build runner ensures that `/work` in the chroot resolves to the host-visible workspace directory.

#### 14.1.7 PATH Rules

The build runner MUST set `PATH` to a deterministic value and MUST NOT inherit the host `PATH`.

`PATH` MUST reference only standard paths inside the chrooted build root (e.g., `/usr/bin:/bin`) and must not contain host paths.

---

## Profiles and Generations

### 15. Profile System

A **profile** is a named collection of realized package content presented as a `/usr` tree.

#### 15.1 Profile Model

Profiles live under `/mere/profiles/<profile-name>/`. There are two kinds:

1. **System profile** (`system`) - managed by `mere install` + activation
2. **Named user profiles** (e.g., `dev`, `go`, `audio`) - explicitly created and managed

#### 15.2 System Profile Generations

The system profile uses the nested generational layout.

**On-disk structure**:
```
/mere/profiles/system/
├── current -> gen-42
├── gen-41/
│   ├── bin/
│   ├── lib/
│   ├── share/
│   └── profile.kdl
├── gen-42/
│   ├── bin/
│   ├── lib/
│   ├── share/
│   └── profile.kdl
└── config.kdl        (optional, profile-local config)
```

**Rules**:
- `current` is a symlink to the active generation
- Generation directories are immutable once created
- Generation numbering is system-only and starts at 1
- Next generation = max existing `gen-N` + 1 (filesystem scan)

The `/usr` symlink points to `/mere/profiles/system/current`.

#### 15.3 Named Profile Realized State

Named profiles are **not generational**. Each named profile has at most one live realized tree.

**On-disk structure**:
```
/mere/profiles/<name>/
├── root/
│   ├── profile.kdl
│   ├── bin/
│   ├── lib/
│   ├── share/
│   └── ...
└── config.kdl        (optional, profile-local config)
```

**Rules**:
- `root/` is the live realized tree for that named profile
- `root/` may be absent for a newly created empty profile
- Named profiles do **not** have `current`, `gen-N`, retention windows, or rollback semantics
- Updating a named profile replaces `root/` atomically as a unit

#### 15.4 Bidirectional `profile.kdl`

The `profile.kdl` format (spec #6) serves as both the **realized manifest** inside
generation directories and named profile roots, and as the **declarative input**
for building new profiles. There is no separate "requested set" or lockfile.

**User's file** (input): Lives in a project directory or is passed to
`mere profile apply`. Contains package names and optional version/release pins.
The system never writes to the user's file.

**Generation's file** (output): Lives in the generation directory or named
profile `root/`. Contains the full resolved state — versions, releases, content
hashes. Store paths are not stored; they are derived from content-hash + name +
version per spec #1.

**Bidirectional loop**: A generation's `profile.kdl` is a valid input. When fed
back in on the same architecture, content hashes drive exact artifact
resolution — the system fetches the same artifacts by hash, skipping version
resolution. Cross-architecture, content hashes will not resolve; the system
falls back to version/release constraints, producing the same versions built
for the target architecture.

**Input resolution gradient** (see spec #6 for details):
- `package "vim"` → resolve latest from repo
- `package "vim" version="9.1.0"` → resolve with version constraint
- `package "vim" version="9.1.0" release=1 content-hash="e5f6..."` → exact artifact

**Install/uninstall semantics**: `mere install <pkg>` reads the current
generation's `profile.kdl`, extracts the package name list, adds the new
package, resolves the full set, and builds a new generation. `mere uninstall`
does the same but removes a name. The realized `profile.kdl` is always the
source of truth for what is installed — no separate bookkeeping file.

**Project-local discovery**: A `profile.kdl` placed in any directory serves as
a declarative environment specification for `mere shell` (see §15.12).

#### 15.5 Realized Manifests

Every realized system generation directory and every named profile `root/` contains a `profile.kdl` using the same schema as spec #6. No separate "profile manifest" schema exists. Store paths are not stored in the manifest; they are derived from content-hash + name + version per spec #1.

#### 15.6 GC Roots Layout

GC roots are directory-namespaced to prevent collisions for system generations and pins. Named profiles are rooted directly by their live `root/` realization.

**Structure**:
```
/mere/gc-roots/
├── profiles/
│   ├── system/
│   │   ├── current -> /mere/profiles/system/current
│   │   └── kept/
│   │       ├── gen-41 -> /mere/profiles/system/gen-41
│   │       └── gen-42 -> /mere/profiles/system/gen-42
└── pins/
    ├── keep-vim -> /mere/store/<hash>-vim-9.0
    └── keep-vim.note  (optional explanation)
```

**Direct named profile roots**:
- `/mere/profiles/<name>/root/profile.kdl` is itself a live GC root
- There is no `/mere/gc-roots/profiles/<name>/` subtree for named profiles

**Root types**:

| Path                                  | Purpose                                           |
| ------------------------------------- | ------------------------------------------------- |
| `gc-roots/profiles/system/current`    | Active system generation                          |
| `gc-roots/profiles/system/kept/gen-N` | Retained system generations                       |
| `/mere/profiles/<name>/root/profile.kdl` | Live named-profile realization (direct root) |
| `gc-roots/pins/<pin-name>`            | Admin pins (store path references, requires root) |

#### 15.7 System Retention Policy

Retention applies to the **system profile generation history**.

**Rules**:
- Always keep `current`
- Keep last **K** system generations (default K=2, configurable)
- Keep any generation with a `.keep` marker file inside

**Keep markers**:
```
/mere/profiles/system/gen-N/.keep
/mere/profiles/system/gen-N/.keep.note  (optional explanation)
```

**GC behavior**:
- Walks all roots under `/mere/gc-roots/`
- Walks all named profile roots under `/mere/profiles/<name>/root/`
- Collects reachable store paths from manifests and pins
- Deletes unreachable store paths
- Prunes system generation directories not in the kept set (`current`, last K, `.keep`)
- Never mutates roots

#### 15.8 Profile Lifecycle Commands

**`mere profile list`**: Lists all profiles. The system profile reports current generation state; named profiles report whether a live `root/` exists.

**`mere profile create <name> [--from <base>]`**:
- Without `--from`: Creates empty profile directory (no `root/`)
- With `--from <base>`: Clones the base profile's active realized state into `<name>/root/`
- Errors: profile exists, base doesn't exist, base has no realized state, name is `system`

**`mere profile delete <name>`**:
- Removes `/mere/profiles/<name>/` recursively
- Errors: doesn't exist, name is `system`

#### 15.9 `mere install` Integration

**Default behavior** (`mere install <pkg...>`):
- Targets system profile
- Reads the current generation's `profile.kdl` to determine the existing package set
- Adds the new package name(s) to the set (deduplicated by name)
- Resolves the full set and realizes a new generation under `/mere/profiles/system/`
- Updates `current` symlink
- Updates `/mere/gc-roots/profiles/system/current`

**Profile-targeted install** (`mere install --profile <name> <pkg...>`):
- Targets `/mere/profiles/<name>/`
- Reads the current `root/profile.kdl` to determine the existing package set
- Adds the new package name(s) to the set (deduplicated by name)
- Resolves the full set and atomically replaces `/mere/profiles/<name>/root/`
- Does NOT affect system or host `/usr`

**Auto-create**: If target profile doesn't exist, auto-creates it (empty, like `mere profile create <name>`).

**`mere uninstall` integration** (`mere uninstall [--profile <name>] <pkg...>`):
- Reads the target profile's current `profile.kdl` and removes the named package(s)
- For the system profile: creates and activates a new generation from the remaining set
- For a named profile: atomically replaces `root/` with the remaining realized closure
- If the package set becomes empty, realizes an empty system generation or an empty named `root/`

**`mere profile apply <file>`**:
- Reads the supplied `profile.kdl` (minimal or full form)
- For each package, resolves according to the input gradient (spec #6):
  content-hash → exact artifact, version/release → constrained resolution,
  name only → latest from repo
- Resolves the full set through the resolver (hashed packages enter as hard
  constraints, unhashed packages resolve normally)
- Builds a new generation (system) or replaces `root/` (named)
- The resulting `profile.kdl` in the new generation/root is the fully resolved output
- Targets system profile by default; use `--profile <name>` for named profiles

#### 15.10 Generation Management Commands

Generation commands apply to the **system profile only**.

**`mere store generation list`**: Lists system generations. Shows number, timestamp, kept status, active status.

**`mere store generation keep <N>`**: Creates `.keep` marker and GC root under `kept/`.

**`mere store generation unkeep <N>`**: Removes `.keep` marker and GC root from `kept/`.

**`mere store generation delete <N>`**: Removes the system generation directory and GC root. Error if generation is `current`.

#### 15.11 Atomic Publishing

System activation uses atomic symlink replacement:

1. Build new generation at `/mere/profiles/system/gen-<N+1>/`
2. Create temp symlink: `/mere/profiles/system/.current-new -> gen-<N+1>`
3. Atomic rename: `rename(".current-new", "current")`
4. Update GC roots

This switching step does not prune old generation directories. It only updates the active pointer and GC roots; generation pruning happens later during `mere store clean`.

The `/usr` symlink always points to `/mere/profiles/system/current` and never changes after bootstrap.

#### 15.12 `mere shell` and Project-Local Profiles

`mere shell` enters an isolated namespace with a profile's package tree as the environment.

**Resolution order**:
1. `mere shell --profile <name>` — use existing named profile `<name>`
2. `mere shell` (no args) — discover `profile.kdl` in the current working directory
3. `mere shell <path/to/profile.kdl>` — use the specified file

If none of these resolve, `mere shell` exits with an error.

**Project-local `profile.kdl`**: A `profile.kdl` placed in any directory serves as a declarative environment specification. When `mere shell` discovers it:
1. Read the file and parse package specifications
2. Compute a BLAKE3 hash of the file content
3. If a cached named profile keyed on that hash exists, reuse it
4. Otherwise, resolve packages per the input gradient (spec #6), build a new
   named profile, and cache it under `/mere/profiles/shell-<hash-prefix>/`
5. Enter the namespace with the resolved profile

**Caching**: Resolved project-local profiles are cached as named profiles
keyed by a hash of the `profile.kdl` file content. Editing the file produces
a different hash and triggers a fresh resolve/build. Cached profiles are
subject to normal GC.

**Example workflow**:
```
$ cd ~/projects/myapp
$ cat profile.kdl
profile {
    package "go"
    package "protobuf"
    package "grpcurl"
}
$ mere shell
# → resolves packages, builds/caches profile, enters namespace
# go, protobuf, grpcurl are available
```

**System activation / rollback** (`mere store generation activate <N>`): Same atomic procedure, different target. System activation also applies system-specific host integration such as `/etc` template processing.

**Named profile publishing**:
1. Build a staged realization directory at `/mere/profiles/<name>/.root-new-<nonce>/`
2. Validate the staged `profile.kdl`
3. Publish it atomically as `/mere/profiles/<name>/root/`
4. Remove the previously live tree after the publish succeeds

Named profiles do not retain historical realized trees and do not support rollback by generation number.

---

## Archive Format

### 16. Archive Format Details

#### Format
- **Tar variant**: POSIX pax (via libarchive)
- **Compression**: zstd, fixed level 19

#### Extended Attributes
- **Not preserved by default**

#### Hardlinks
- **Preserved** in archives
- Inability to recreate hardlinks during extraction is an **error** (no silent degradation to copies)

#### Hardlink Identity Semantics

Hardlinks are treated as **file content**, not inode identity.

When computing the store content hash:
- Each path entry is hashed independently
- Multiple hardlinked paths with identical content hash identically
- Inode identity and link count are NOT part of the hash

**Normative invariant**: Store identity represents *observable filesystem content*, not inode topology.

The requirement to preserve hardlinks during extraction exists for runtime correctness and space efficiency, not identity stability.

#### Path Limits
- Follow pax + filesystem limits
- Extraction failures due to path length are errors

#### Security (Extraction)
- **No absolute paths** - reject entries starting with `/`
- **No path traversal** - reject entries containing `..` that escape destination
- Extraction **must stay within destination root**
- Violations are hard errors, not warnings

#### Error Handling
- Any extraction failure is an error
- No partial extraction (all-or-nothing)
- Errors reported with entry path and reason

---

### 16.1 File Deduplication During Package Creation

**Automatic deduplication** is performed during package creation to reduce archive size and storage footprint.

#### Algorithm

Before creating the tar archive, the staging directory is deduplicated in-place:

1. **Scan**: Walk the staging directory and collect all regular files
2. **Hash**: Compute BLAKE3 hash for each file's content
3. **Identify duplicates**: Group files by content hash
4. **Select canonical**: For each group, the first file encountered becomes the canonical file
5. **Replace duplicates**: All other files in the group are deleted and replaced with hard links to the canonical file
6. **Archive**: Create tar archive with libarchive, which preserves the hardlinks

#### Canonical File Selection

The canonical file (hardlink target) is determined by **directory traversal order**.

**Example**: In a busybox package:
- If `sbin/arping` is encountered first during traversal, it becomes the canonical file
- All other busybox utilities (`bin/busybox`, `bin/ls`, `bin/cat`, etc.) become hardlinks to `sbin/arping`

**Properties**:
- **Deterministic**: Same directory structure produces same result
- **Simple**: No complex heuristics for "best" canonical file
- **Correct**: Hardlinks are symmetric - any file can be the target

#### Implementation

**Invocation**: Deduplication is performed internally by `archive.createPackageArchive()` in `src/archive.zig` before tar creation

**Memory**: Uses arena allocator for temporary hash map and path strings

**Error handling**: Returns `ArchiveError.FileSystem` on I/O failures

#### Benefits

**Space savings**:
- **Archive size**: Hardlinks take minimal space in tar format (~100 bytes per link vs full file content)
- **Compression**: Less unique data to compress
- **Bandwidth**: Smaller packages to download
- **Store footprint**: Hardlinks preserved after installation

**Performance**:
- **Faster compression**: Less data to compress
- **Faster extraction**: Less data to decompress and write

**Common use cases**:
- **Busybox packages**: 300+ utilities, all the same binary (~30MB → ~1MB)
- **Duplicate libraries**: Multiple copies of the same library file
- **Documentation**: Identical files in different locations
- **Static binaries**: Multiple copies of the same statically-linked binary

#### Example

A busybox package before deduplication:
```
bin/busybox    (1.2 MB)
bin/ls         (1.2 MB, identical to busybox)
bin/cat        (1.2 MB, identical to busybox)
bin/grep       (1.2 MB, identical to busybox)
... (300+ more utilities)
```

After deduplication:
```
bin/busybox    (1.2 MB)
bin/ls         (hardlink to bin/busybox)
bin/cat        (hardlink to bin/busybox)
bin/grep       (hardlink to bin/busybox)
... (300+ more hardlinks)
```

Archive size: ~30MB → ~1.2MB (before compression)

#### Interaction with Content Hash

**Normative rule**: Deduplication happens **before** content hashing.

The content hash (used in store paths) is computed over the **deduplicated** staging directory.

**Properties**:
- Packages with identical content produce identical hashes, regardless of whether files were originally duplicates or hardlinks
- The hash reflects the logical content, not the physical layout
- Rebuilding a package with the same content produces the same hash

#### Preservation Through Pipeline

Hardlinks are preserved through the entire pipeline:

1. **Build**: Recipe installs files to staging directory (may contain duplicates)
2. **Deduplication**: Duplicates replaced with hardlinks in staging directory
3. **Archiving**: libarchive creates tar with hardlink entries
4. **Compression**: zstd compresses the tar (hardlinks already deduplicated)
5. **Extraction**: libarchive recreates hardlinks during extraction
6. **Store**: Hardlinks preserved in content-addressed store

**Verification**: After extraction, files that were hardlinks in the archive remain hardlinks in the store (same inode).

---

## Package Manifest

### 17. PackageManifestV1 Binary Format

The package manifest is the authoritative source of package metadata, using a deterministic binary encoding.

**File locations**:
- Archive: `.mere/manifest.v1` and `.mere/manifest.v1.sig`
- Store: `<store_root>/.mere/manifest.v1` and `<store_root>/.mere/manifest.v1.sig`

**Binary format** (canonical byte layout, all integers little-endian):

| Offset        | Field          | Size              | Description                        |
| ------------- | -------------- | ----------------- | ---------------------------------- |
| 0             | magic          | 8 bytes           | ASCII `"MEREMFST"` (Mere Manifest) |
| 8             | schema_version | u32 LE            | Must be `1` for v1                 |
| 12            | created_at     | u64 LE            | Unix epoch seconds                 |
| 20            | release        | u32 LE            | Package release number             |
| 24            | arch_len       | u32 LE            | Length of arch string              |
| 28            | arch           | arch_len bytes    | Architecture (e.g., `x86_64`)      |
| 28+arch_len   | name_len       | u32 LE            | Length of name string              |
| 28+arch_len+4 | name           | name_len bytes    | Package name                       |
| ...           | version_len    | u32 LE            | Length of version string           |
| ...           | version        | version_len bytes | Package version                    |
| ...           | content_hash   | 32 bytes          | Raw BLAKE3 hash (not hex)          |

**Total size**: 8 + 4 + 8 + 4 + 4 + arch_len + 4 + name_len + 4 + version_len + 32 bytes

**Field ordering is part of the canonical definition** - do not reorder fields.

**Required fields (v1)**:
- `schema_version`: Must be `1`
- `name`: Package name (UTF-8, no null bytes)
- `version`: Package version (UTF-8, no null bytes)
- `release`: Release number (positive integer)
- `arch`: Architecture string (`x86_64`, `aarch64`, `any`)
- `content_hash`: 32-byte BLAKE3 hash of the realized payload plus canonical `.mere/meta.kdl`
- `created_at`: Unix timestamp when package was built (informational; surfaced in metadata for auditing and display)

**Signature file** (`manifest.v1.sig`):
- Exactly 64 bytes: raw Ed25519 signature
- Signs the exact bytes of `manifest.v1`
- Verification tries each allowlisted repo key until one verifies

**Validation rules**:
1. Magic must be exactly `"MEREMFST"`
2. Schema version must be `1` (reject unknown versions)
3. All string lengths must be reasonable (< 1024 bytes)
4. content_hash must match computed store content hash
5. Signature must verify against an allowlisted key

---

### 18. Profile Build Algorithm

A profile realization is a **symlink tree projection** of store contents. System generation directories and named profile `root/` directories contain symlinks into `/mere/store/`, not copied files.

**Structure** (note: content under `usr/` subtree, metadata outside):
```
/mere/profiles/system/gen-42/
├── profile.kdl          # Generation metadata (NOT under usr/)
└── usr/                   # REQUIRED - visible at /usr after activation
    ├── bin/               # Symlinks to store paths
    │   ├── sh -> /mere/store/<hash>-busybox-1.0/bin/sh
    │   └── ls -> /mere/store/<hash>-coreutils-9.0/usr/bin/ls
    ├── lib/
    │   └── libc.so.6 -> /mere/store/<hash>-musl-1.2/lib/libc.so.6
    └── share/
        └── ...
```

**Build algorithm**:

Input: Ordered list of packages (already resolved via dependency resolver)

```
for each package in resolved_packages:
    store_root = /mere/store/<hash>-<name>-<version>/
    for each path in package's file tree (excluding .mere/*, etc/*):
        # No path canonicalization - packages can use bin/, usr/bin/, etc.
        profile_path = profile_root + "/" + relative_path
        store_target = store_root + "/" + relative_path

        if path is directory:
            create directory at profile_path (if not exists)
        else if path is file or symlink:
            if profile_path not seen:
                create symlink: profile_path -> store_target
                record (profile_path, store_target) in seen_paths
            else if seen_paths[profile_path] == store_target:
                skip (identical, idempotent)
            else:
                ERROR: path conflict between packages
```

**Conflict handling**:
- Path conflicts are **hard errors** by default
- No implicit resolution via repo priority or package order

**Symlink granularity**: File-level symlinks by default. Directory symlinks are not used because:
- Precise conflict detection on individual paths
- Deterministic behavior regardless of package order
- Simpler validation (each symlink is independent)

#### 18.1 External Scaffolding and /usr Structure (No Path Canonicalization)

The system `/usr` directory and its subtree symlinks are **external scaffolding** - they are NOT managed by Mere. They are established by bootstrap/installer (or base system setup) as stable invariants.

**Required structure**:

```
/usr/                           # Real directory (NOT a symlink)
├── local/                      # Real directory, unmanaged, persistent
├── bin -> /mere/profiles/system/current/usr/bin
├── sbin -> /mere/profiles/system/current/usr/sbin
├── lib -> /mere/profiles/system/current/usr/lib
├── share -> /mere/profiles/system/current/usr/share
├── libexec -> /mere/profiles/system/current/usr/libexec  # Optional
└── include -> /mere/profiles/system/current/usr/include  # Optional
```

Optional: `/bin`, `/sbin`, `/lib` may exist as compatibility symlinks:
```
/bin -> /usr/bin
/sbin -> /usr/sbin
/lib -> /usr/lib
```

**Implications**:
- Mere MUST NOT modify `/usr`, `/usr/local`, or the subtree symlinks (`/usr/bin`, `/usr/lib`, etc.)
- `/usr` MUST be a real directory (MUST NOT be a symlink)
- `/usr/local` MUST be a real directory reserved for admin use
- Packages can use any path structure: `bin/`, `sbin/`, `lib/`, `usr/bin/`, etc.
- No path canonicalization is performed during profile realization
- Profile realizations contain whatever directory structure the packages provide

**What this means for packages**:
- Packages shipping `bin/foo` will have `bin/foo` in the realization
- Packages shipping `usr/bin/foo` will have `usr/bin/foo` in the realization
- Both are valid and will be accessible via the external scaffolding symlinks
- Packages MUST NOT ship any content under `usr/local/` - such packages MUST be rejected

#### 18.2 /etc Path Handling

Package-provided configuration MUST NOT be projected directly into the profile realization.

**Rules**:
- `etc/*` paths encountered in payloads during profile realization MUST be **ignored** (not symlinked into the realization)
- Configuration defaults are supplied under `${store_root}/etc-defaults/**` and applied at activation time using the drift-reporting rules in spec #13
- This maintains the separation between immutable package content and host-owned `/etc`

**What gets symlinked**:
- All files under `usr/`, `bin/`, `sbin/`, `lib/` in store packages map to corresponding profile subtrees
- `etc/` paths are **excluded** from profile realization (defense in depth)
- `etc-defaults/` paths ARE included (for template processing at activation time)
- Symlinks in store are re-created as symlinks in profile (pointing to store location)
- Directories are created (not symlinked) to allow merging from multiple packages

**Validation** (after build, before publish or activation):
- Run profile realization validator (spec #7) on all created symlinks
- Verify profile.kdl is valid and matches built content
- Ensure no symlinks escape boundaries

---

### 19. System Generation Numbering

**Rule**: Next system generation number = 1 + max existing `gen-N` directory under `/mere/profiles/system/`.

**Algorithm**:
```
scan /mere/profiles/system/ for directories matching "gen-<N>" pattern
extract N from each match
next_generation = max(all N values) + 1
if no matches exist: next_generation = 1
```

**Properties**:
- No separate counter file (filesystem is the source of truth)
- Survives manual deletion of generations
- Deterministic and inspectable
- Gaps in sequence are allowed (e.g., after GC deletes old generations)
- Numbering exists only for the system profile

**Edge cases**:
- Empty system profile (no generations): first generation is `gen-1`
- Only non-matching directories: first generation is `gen-1`
- Concurrent builds: use atomic directory creation with unique staging name, then rename

---

### 20. /usr Structure and /usr/local Preservation

#### 20.1 Goal

Preserve traditional `/usr/local` semantics (admin-installed, unmanaged, persistent) while keeping Mere's system content generation-switched and fully reproducible.

#### 20.2 Definitions

**Managed paths**: Filesystem locations whose contents are provided by the active system profile generation.

**Unmanaged paths**: Filesystem locations reserved for the system administrator; Mere MUST NOT write to or manage them.

#### 20.3 /usr MUST be a Real Directory

On a Mere-managed system:

- `/usr` MUST be a real directory on the host filesystem
- `/usr` MUST NOT be a symlink into `/mere/profiles/...`

**Rationale**: If `/usr` is a symlink, then `/usr/local` becomes implicitly generation-scoped, which violates the intended semantics of `/usr/local`.

#### 20.4 /usr/local MUST be Unmanaged and Persistent

`/usr/local` MUST be a real directory on the host filesystem.

`/usr/local` MUST be treated as unmanaged:

- Mere MUST NOT write to `/usr/local`
- Mere MUST NOT template, merge, or otherwise manage `/usr/local`
- Activation MUST NOT modify `/usr/local`
- GC MUST NOT consider `/usr/local` content as store-reachable state
- `/usr/local` MUST remain stable across activations and generations

#### 20.5 /usr Subtree Symlinks Define the Managed System View

Mere-managed system content under `/usr` MUST be represented via symlinks for each relevant subtree, pointing to the active system profile generation.

**At minimum, the following paths MUST be symlinks**:

```
/usr/bin -> /mere/profiles/system/current/usr/bin
/usr/sbin -> /mere/profiles/system/current/usr/sbin
/usr/lib -> /mere/profiles/system/current/usr/lib
/usr/share -> /mere/profiles/system/current/usr/share
```

**Optional but RECOMMENDED if used by packages in the ecosystem**:

```
/usr/libexec -> /mere/profiles/system/current/usr/libexec
/usr/include -> /mere/profiles/system/current/usr/include
```

**Notes**:

- The exact set of symlinked subtrees is the contract
- If your packaging policy never installs headers, `/usr/include` may remain absent or unmanaged
- Activation only switches `/mere/profiles/system/current`; it does not rewrite these symlinks

#### 20.6 Packages MUST NOT Install into /usr/local

Package builds and activations MUST enforce:

- No package may claim provisions under `/usr/local/**`
- No package may install files into `/usr/local/**`
- If a built package attempts to stage outputs into `/usr/local`, the build or packaging step MUST fail with a clear error identifying the offending paths

This rule applies regardless of whether `/usr/local` exists in the build namespace; `/usr/local` is reserved and out-of-band by definition.

#### 20.7 Activation MUST Treat /usr/local as a Boundary

During system activation and profile realization:

- Mere MUST NOT create, remove, or modify `/usr/local`
- Path conflict detection MUST treat `/usr/local/**` as reserved and non-overridable

#### 20.8 Activation Switches `current` Only

System activation consists solely of updating the profile pointer:

```
/mere/profiles/system/current -> gen-N
```

No other system-global symlinks are required to change during activation. The `/usr` subtree symlinks (`/usr/bin`, `/usr/lib`, etc.) never change after bootstrap.

#### 20.9 Generation Structure Requirements

**Normative rules**:
- Generation metadata (e.g., `profile.kdl`) MUST be placed at the generation root, NOT under any package content directories
- Packages may provide content under `usr/`, `bin/`, `sbin/`, `lib/` - all are valid
- No path canonicalization is performed - packages freely choose their layout
- External scaffolding (system symlinks) determines visibility
- Generations may legitimately lack `usr/` if no package provides it - empty directories are not required

**Example generation structure**:
```
/mere/profiles/system/gen-42/
├── usr/                    # Optional - only if packages provide usr/ content
│   ├── bin/
│   ├── lib/
│   └── share/
├── bin/                    # Optional - only if packages provide bin/ content
├── lib/                    # Optional - only if packages provide lib/ content
└── profile.kdl           # REQUIRED - generation metadata at root
```

#### 20.10 Expected State Before Mere Operates

```
/usr/                       # Real directory
├── local/                  # Real directory, unmanaged
├── bin -> /mere/profiles/system/current/usr/bin
├── sbin -> /mere/profiles/system/current/usr/sbin
├── lib -> /mere/profiles/system/current/usr/lib
└── share -> /mere/profiles/system/current/usr/share

/mere/profiles/system/current -> gen-<N>  (or doesn't exist yet)
```

**mere's responsibilities**:
- Create new generation directories (`/mere/profiles/system/gen-<N+1>/`)
- Atomically switch `/mere/profiles/system/current` symlink
- Never touch `/usr`, `/usr/local`, or the `/usr` subtree symlinks

**mere's assumptions**:
- `/usr` is a real directory with subtree symlinks as described above
- `/usr/local` is a real directory and remains unmanaged
- `/mere/profiles/` directory exists and is writable
- `/mere/store/` directory exists and is writable

**If assumptions not met**: Operations that require profile switching fail with clear error. No attempt to "fix" or "initialize" the system structure.

---

### 21. Pin System

Pins are explicit user-controlled GC roots that also influence dependency resolution.

**Storage**: Pins are named symlinks under `/mere/gc-roots/pins/` pointing to store paths.

```
/mere/gc-roots/pins/
├── my-toolchain -> /mere/store/<hash>-llvm-20.1/    # pin named "my-toolchain"
├── my-toolchain.note                                # optional explanation
├── foo -> /mere/store/<hash>-foo-1.0/              # pin named "foo"
└── ...
```

**Pin target**: Always a specific store path (`/mere/store/<hash>-<name>-<version>/`). Pins are concrete artifacts, not version constraints or abstract requirements.

**Pin naming**:
- User-chosen label (e.g., `my-toolchain`, `stable-compiler`)
- Default suggestion: package name (for common case of "pin the current foo")
- Multiple pins to different versions of the same package are allowed (different pin names)

**Optional note file**: `<pin-name>.note` is plain text. Tools ignore content.

**Pin matching semantics** (for resolver integration):

Pins are indexed by **package name only**. Pins do not match provision identifiers directly.

When the resolver needs to select a package:
1. **Direct package requirement** (e.g., "need package foo"):
   - Check if any pin's target is a store path for package `foo`
   - If found, use the pinned store path (overrides version selection)
2. **Provision requirement** (e.g., "need bin:sh"):
   - Compute candidate provider packages
   - If any candidate package has a pin, prefer the pinned one(s) via pins-first ordering
   - Pins do not "magically match" provisions; they influence provider selection when the pinned package is among candidates

**CLI commands** (all require root):
- `mere store pin add <store-path> [--name <label>]` - create pin (default name: package name from store path)
- `mere store pin remove <name>` - remove pin
- `mere store pin list` - list all pins with their targets

**Validation**:
- Pin target must be a valid store path (exists, matches `<hash>-<name>-<version>` format)
- Pin name must be a valid filename (no `/`, reasonable length)
- Creating a pin with an existing name is an error (use unpin first)

**GC behavior**: Pinned store paths are always reachable. GC will not delete a store path that is the target of any pin.

---

## System Initialization

### 22. mere store init - System Layout Initialization

`mere store init` initializes and validates the system-wide Mere filesystem layout and permissions. It is the only supported mechanism for creating and repairing critical `/mere` directories.

**Requirements**:
- MUST be run as root
- MUST be idempotent (safe to run multiple times)
- MUST report all changes made
- MUST NOT modify user data, packages, or profiles

#### 22.1 Purpose

`mere store init` exists to:
- Ensure correct ownership and permissions
- Prevent silent misconfiguration
- Provide a reproducible installation baseline
- Avoid reliance on manual setup

#### 22.2 Scope

`mere store init` is responsible for:
- Creating required directories
- Setting required ownership and permissions
- Applying sticky-bit where specified
- Validating existing installations
- Reporting misconfigurations

`mere store init` MUST NOT:
- Install packages
- Activate profiles
- Modify store contents
- Perform GC
- Modify user data

#### 22.3 Required Directory Layout

After successful `mere store init`, the following directories MUST exist:

```
/mere/
├── dev/
│   ├── build/
│   ├── repo/
│   ├── outputs/
│   └── cache/
│       ├── sources/
│       └── build/
├── cache/
│   ├── packages/
│   └── repos/
├── gc-roots/
│   ├── profiles/
│   │   └── system/
│   └── pins/
├── profiles/
│   └── system/
└── store/
```

If any required directory is missing, `mere store init` MUST create it.

#### 22.4 Ownership and Permissions

`mere store init` MUST enforce the canonical directory ownership and mode requirements defined in **9.0.2 Directory Permissions**.
This section is intentionally non-duplicative to avoid configuration drift in documentation.

**Sticky-bit semantics** (mode 1777):
- World-writable: any user can create new entries
- Sticky bit: only owner (or root) can delete/rename entries
- Enables unprivileged contribution while protecting existing content

#### 22.5 Hardening Rules

During `mere store init`, the implementation MUST:
- Ensure all directories exist
- Apply correct ownership
- Apply correct permissions
- Apply sticky-bit where specified
- Remove unsafe permissions (e.g., group/world write on protected dirs)
- Refuse to proceed if critical paths are symlinks
- Refuse to operate if `/mere` is mounted with `nosuid`, `nodev`, `noexec` in incompatible ways

During system profile activation, the implementation MUST harden each referenced store object:
- Recompute content hash and verify against manifest (mandatory)
- Change ownership to `root:root` recursively
- Set read-only permissions recursively
- Set filesystem immutable flag (`FS_IMMUTABLE_FL` via `ioctl(fd, FS_IOC_SETFLAGS)`) on all files and directories recursively
- If the filesystem does not support immutable flags: emit a single warning per operation (not per file) and proceed. The store is still protected by ownership and permissions, but not against accidental root writes through symlinks.

Any violation MUST be reported. Silent repair is not permitted without user-visible output.

#### 22.6 Validation Mode

`mere store init` provides a validation-only mode that performs verification and reports deviations without making changes.

```bash
mere store init --dry-run  # short: -n
```

**Behavior**:
- Perform all verification
- Make no changes
- Report all deviations
- Exit non-zero if invalid

**Output format**:
```
Checking /mere/store... OK
Checking /mere/dev/build... FAIL: incorrect permissions (expected 1777, found 0755)
Checking /mere/gc-roots... OK
Checking /mere/profiles/system... FAIL: missing directory

Summary: 2 issues found
```

#### 22.7 Repair Mode

`mere store init` (default behavior) applies repairs when deviations are found. The command is idempotent: running it multiple times when the layout already conforms is a no-op and reports no changes.

**Actions**:
- Create missing directories
- Correct ownership
- Correct permissions
- Apply sticky-bit
- Report all changes made

**Output format**:
```
Creating /mere/profiles/system... done
Fixing permissions on /mere/dev/build (0755 -> 1777)... done
Fixing ownership on /mere/store (user:user -> root:root)... done

Summary: 3 changes applied
```

#### 22.8 Optional Flags

| Flag               | Behavior                                    |
| ------------------ | ------------------------------------------- |
| `--dry-run` / `-n` | Show intended actions only, make no changes |
| `--verbose`        | Explain each operation in detail            |

**Example dry-run output**:
```bash
$ mere store init --dry-run
Would create /mere/profiles/system
Would fix permissions on /mere/dev/build (0755 -> 1777)
Would fix ownership on /mere/store (user:user -> root:root)

Summary: 3 changes would be applied (dry-run, no changes made)
```

#### 22.9 Failure Semantics

`mere store init` MUST fail if:
- Not executed as root
- Critical directories cannot be created
- Ownership cannot be applied
- Filesystem does not support required modes
- Symlink attacks are detected
- Existing layout conflicts with spec

**Failure handling**:
- Failure MUST leave the system unchanged when possible
- Partial application is acceptable only if each change is atomic
- All failures MUST be reported with actionable error messages

**Example failure**:
```
Error: /mere/store is a symlink (expected directory)
Refusing to proceed - potential symlink attack
Remove the symlink and run 'mere store init' again
```

#### 22.10 Relationship to Other Commands

**Assumptions**:
- `mere install` assumes `mere store init` has been run
- `mere store clean` assumes validated layout
- `mere activate` assumes hardened profiles
- No command except `mere store init` may create top-level `/mere` directories

**Bootstrap order**:
1. `mere store init` (as root) - create and validate layout
2. `mere import` or `mere install` - populate store and profiles
3. `mere activate` - switch to new generation

#### 22.11 Rationale

This design ensures:
- **Predictable system layout**: No hidden setup steps
- **No ambient authority**: Explicit initialization required
- **No dependency on group hacks**: Clear ownership model
- **No background daemons**: One-time setup command
- **No permission ambiguity**: Explicit mode specification
- **Initialization is explicit, auditable, and repeatable**

**Alignment with Mere principles**:
- **Filesystem as truth**: Layout is inspectable and verifiable
- **Atomicity over cleverness**: Each directory operation is atomic
- **Facts separate from policy**: `mere store init` creates structure, doesn't impose policy
- **Legibility over abstraction**: Plain directories with explicit permissions

---

## Non-Goals (Explicit)

This specification explicitly does NOT:

- **Introduce global policy**: All policy is local or user-configured
- **Encode provenance or build purity**: Content identity is observable filesystem state
- **Require network trust or timestamps**: Time is advisory; cryptographic signatures provide integrity
- **Add hidden mutable state**: All state is inspectable via filesystem

All specifications preserve Mere's core principles:

| Principle                   | Manifestation                                   |
| --------------------------- | ----------------------------------------------- |
| Filesystem as truth         | Generation validity, GC roots, store identity   |
| Atomicity over cleverness   | Symlink switching, no partial states            |
| Facts separate from policy  | Manifests describe; configs decide              |
| Legibility over abstraction | Plain files, symlinks, deterministic algorithms |

---

## 23. Recipe `package.files` Semantics

This section defines the authoritative behavior for `files` entries in recipe `package` nodes.

### 23.1 Variable Expansion in `files`

`files` entries are interpolated at recipe-parse time using the same interpolation engine as phase scripts.

Supported placeholders:
- `${recipe.name}`
- `${recipe.version}`
- `${recipe.release}`
- `${recipe.url}`
- `${recipe.description}`
- `${recipe.arch}` (only when architecture has been resolved; see 23.3)
- `${vars.<key>}`

Unsupported or malformed placeholders are handled using recipe interpolation error rules.

### 23.2 Pattern Matching Rules

`files` patterns are matched using POSIX `fnmatch(3)` semantics with pathname-aware matching enabled (`FNM_PATHNAME`).

Normative rules:
- Matching is performed against paths relative to `${DESTDIR}`.
- Leading `/` is not used in recipe patterns.
- `*`, `?`, and bracket expressions (`[abc]`, `[a-z]`) follow `fnmatch(3)` behavior.
- `/` is treated as a path separator and is not matched by `*` when pathname-aware matching is enabled.
- Custom wildcard extensions are not supported.
- In particular, `**` has no special recursive meaning.
- One custom shorthand is supported on top of `fnmatch`: a pattern ending in `/` means "all files under this directory recursively".
- Example: `usr/share/doc/` matches `usr/share/doc/pkg/README` and `usr/share/doc/pkg/nested/guide.txt`.
- Exclusion patterns are supported: a pattern beginning with `!` is an exclusion filter.
- Exclusion patterns use the same matching rules after stripping the leading `!`.
- Match decision per path:
  - The path MUST match at least one inclusion pattern (pattern not starting with `!`).
  - The path MUST NOT match any exclusion pattern (pattern starting with `!`).
- Example: `usr/bin/*` with `!usr/bin/ncurses6-config` includes all `usr/bin/*` except `usr/bin/ncurses6-config`.

### 23.3 Pattern Authoritativeness

The `files` list is authoritative at per-pattern granularity.

Normative invariant:
- Every inclusion pattern (`files` entry not starting with `!`) MUST match at least one collected path.
- If any inclusion pattern matches zero paths, artifact collection MUST fail with a hard error.
- Exclusion patterns are filters and are NOT required to match any path.

### 23.4 Architecture Guidance

`recipe.arch` is resolved during recipe parsing from `archs` against the host architecture.

Normative rules:
- If `archs` is omitted, `recipe.arch` may be unset.
- `${recipe.arch}` MUST only be used when `archs` is declared and resolvable.
- Architecture-independent recipes SHOULD declare `archs "any"` instead of relying on an implicit default.
