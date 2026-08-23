# Roadmap

This is a plan, not a specification. Nothing here is normative — `specification-details.md` describes what Mere does, and this describes what we intend to do next and why in that order. Expect it to be revised as work lands.

## What 1.0 would mean

Mere is the package manager and system-management tool for a distribution, so the promise a 1.0 makes is mostly about persistence: a machine you installed it on keeps working. That is a claim about on-disk formats, the trust model, and the system layout far more than about the CLI.

The formats already version themselves (see "Format Versions and Compatibility"), so 1.0 is not "get the formats right forever". It is **the point at which the set of variants Mere promises to keep reading stops being accidental**.

Mere uses semantic versioning. 1.0 promises what semver means and nothing beyond it: breaking the interface requires a major version.

Working definition:

> At 1.0, the accepted-variant list in "Format Versions and Compatibility" is deliberate, and every "Current conformance" gap in the interface contract is either closed or explicitly accepted.

Note what the second clause does and does not require. A gap may be closed by building something, or closed by deciding not to and recording why. What it rules out is a gap surviving to 1.0 because nobody looked at it.

### Why this is stated as properties and not as consumers

The work that produced the interface contract started from a question about AI agents: what would Mere look like if it were built for them and not only for a person at a terminal? The contract does not answer in those terms, and the difference is deliberate.

An agent is not a consumer with novel requirements. It is one that exhibits, constantly, properties other consumers exhibit occasionally — no continuity of memory, interruption as the ordinary end of an operation, acting on text it did not author. Each of those was always true of something. A CI job gets killed. A script parses a package description someone else wrote. A person running a command twice a year has forgotten what they did last time. Every case was marginal enough to absorb with documentation and habit, and an agent makes the marginal case the common one until the neglect stops being survivable.

So the agent question is what makes a property visible, and the property is what gets specified. Keep both: the question is the best generator of design problems this project has, and skipping the translation is what produces bad scope. Asked directly, "what does an agent need" answers with surfaces — an inspector, an event stream, a machine-readable everything. Asked as a property, the same need answers with an invariant, and invariants are the things that cannot be added later for free.

Hence the test for anything proposed on some consumer's behalf: does it survive translation to the others? A command that prints existing state as JSON does not; it is a convenience for one caller, genuinely useful, and additive. Even an invariant that survives the translation still needs a concrete use: conditional activation, for example, is only meaningful when a caller acts on an earlier observation rather than asking Mere to perform the whole operation at once.

One place the frame runs out, recorded so it is not forced: several consumers operating on one root at once is a scale difference that becomes a kind difference, and no single-caller property naturalizes it. That is why lockless store admission is scheduled on its own terms below rather than derived from this test.

## Scope for 1.0

Three kinds of work, distinguished by whether they have a deadline.

**Format changes have one.** Each is a change to a signed or content-addressed format, so doing it after 1.0 means adding an accepted variant that every verification path carries until a major version retires it.

**Capability removals have one.** Not because of formats, but because each one deferred is a reason 2.0 has to happen.

**Additive work does not.** It can land after 1.0 without breaking anyone, and gating 1.0 on it buys no compatibility benefit.

### Before 1.0

Format changes (detailed below):

- Decide what store identity covers
- Signature discriminator and domain separation
- Retire read-only variants
- Settle the store's permission model

Capability removals:

- **Remove ambient state.** Working-directory profile discovery and TTL-based metadata staleness.
- **Stop treating every installed package as a resolution root.** `mere install` moves every installed package, because nothing records which ones were asked for. Narrowing install is the removal; the additive half — recording intent, and a `mere upgrade` that moves the world deliberately — lands first. Detailed below.

Closing the remaining conformance gaps:

- **Attestation.** A signed, append-only record of what was done, closing "no record of action". Self-contained, and reuses the existing Ed25519 machinery.
- **Artifact schemas: accepted, not closed.** Machine-readable schemas for the hand-rolled binary formats are deliberately *not* planned. Consumers reach these formats through Mere rather than around it, the shapes are already specified in `specification-details.md`, and a hand-maintained schema document would carry exactly the drift risk that `mere describe` exists to avoid. What "through Mere" owes depends on the artifact, and the cases are not alike. A generation's `profile.kdl` (§6) is KDL — already legible, already the declarative input to the operation that produced it — and nothing is owed for it. The binary encodings are where the question arises, and being binary does not settle it either: a package manifest (§17) holds the authoritative package metadata, and a consumer asking what a package is has no other path to it, so declining the schema is what commits Mere to a reader. A realization manifest is equally opaque but answers a file-level question that so far only Mere and its own garbage collection ask. So the test has two steps and an order: an artifact that is already legible owes nothing, and a binary one owes a reader where a consumer needs the question it answers.

### After 1.0

- **Plans as artifacts.** Additive alongside the existing imperative commands.
- **Machine-readable output.** The commands that answer inspection questions already exist — `store verify`, `profile list`, `generation list`, `status`, `search`, `etc status`, `etc diff`, `key fingerprint`. What they lack is a serialization a consumer can parse without scraping prose. That is an output mode on commands that already answer the question, not a second family of `inspect` commands standing beside them, and it freezes no representation the human output has not already frozen.
- **Failure identity in machine output.** The vocabulary exists and so does the exit-code mapping; what a consumer cannot currently see is which member of the vocabulary it hit. See "Exit status" in the contract for the distinction the present codes lose.
- **Lockless store admission.** A content-addressed store needs no mutual exclusion, so unrelated work should stop serializing on one lock per root. Deferred deliberately — its failure mode is corrupted state rather than an error message, and the suite cannot exercise concurrency at all today. The prerequisite is test scaffolding that runs concurrent mutators, which is hard to bound before starting it. Better in a 1.1 with real tests than rushed to make a date.

## Detail

### Format changes

None of these is impossible after 1.0. Each done later means another accepted variant, carried by every verification path until a major version retires it.

- **Decide what store identity covers.** The content hash currently records a file's exec bit and nothing else about mode: setuid, setgid, sticky, the remaining permission bits, and ownership are all outside it, so two payloads differing only in setuid share a store path and `mere store verify` cannot tell them apart. Changing this changes every content hash. Doing it before 1.0 costs a v3 variant; doing it after costs a v3 variant *and* a fourth fallback.
- **Give signatures a discriminator.** A manifest signature is 64 raw bytes with no header, so there is no way to express a different algorithm — even though the key file it verifies against records one. Separately, signatures are computed over a digest in one path and over raw bytes in another, with no domain separation between them.
- **Retire read-only variants.** The transitional store hash exists for one unversioned release and is carried by five fallback sites. Decide whether v1 store objects are still readable at 1.0, and drop what is not.
- **Settle the store's permission model.** The store is world-writable by design (§4.1, two-tier admission), and the existing-object fast path accepts a directory on the strength of its content-addressed name. Those two decisions interact, and the interaction should be deliberate.

### Install and upgrade semantics

`mere install` moves every installed package, not only the ones named. That is not a badly chosen default: there is no `mere upgrade`, so install is the upgrade mechanism, and the manifest gives it no way to be anything else.

A generation's `profile.kdl` records the full resolved closure and marks none of it as requested. When install rebuilds requirements from that record, every package arrives as a bare name — keeping the recorded `content-hash` would freeze the system permanently, since a hash enters the resolver as a hard constraint, and keeping the version is nearly as rigid. Floating everything is the only option the format leaves.

What is missing is one optional property, not a second file. A lockfile pair separates intent from state with a file boundary and pays for it with two files that can disagree; the same distinction fits on the package node:

```kdl
package "python" version="3.13.2" release=1 content-hash="..." requested=#true
package "libdisplay-info" version="0.2.0" release=1 content-hash="..."
```

The resolver already separates explicit roots from inherited ones and discards the distinction on write. `readManifest` looks up properties by name and ignores ones it does not know, so recording this is additive and needs no `schema-version` bump.

Four stages, in this order:

1. **Record it.** Write `requested` for roots. Absence means requested, because the opposite default makes resolution drop nearly everything. No behaviour change yet, which is what makes stage 3 reviewable.
2. **Add `mere upgrade`.** Bare, it re-resolves the requested roots unconstrained — today's install behaviour, named honestly. With a package, it moves that root and whatever it forces. Additive, and it must precede stage 3 or that release leaves no way to upgrade at all.
3. **Narrow `install`.** Roots come from the requested set and carry their recorded version as a constraint; derived packages return through resolution instead of entering as roots. This is the capability removal.
4. **Collect orphans on uninstall.** Removing a requested package can leave derived packages with nothing requesting them. A separate behaviour change, so a separate release.

Existing generations have no `requested`, so everything in them reads as requested and orphan collection stays inert until reclassified. The inference available — a package nothing else in the closure depends on must have been requested, or it would not be there — belongs behind an explicit reclassify command rather than in the read path. Separating the constraint a user expressed from the version that resolved is a further step, since `version=` currently means both; it is needed only if `mere upgrade` should honour ranges.

### Interface and automation

- **Interface contract and self-description.** Done: the contract section, and `mere describe`. Shipped early so the document's shape gets contact with real consumers while `schema_version: 1` is still free to revise.
- **Remove ambient state.** Working-directory profile discovery and TTL-based metadata staleness both make one command mean different things on different runs for reasons not visible in the command. Where the convenience is worth keeping for interactive use, it should at least be resolvable to an explicit form.
- **Attestation.** A signed, append-only record of what was done — who, which plan, which generation before and after.
- **Plans as artifacts.** Separate deciding from doing: resolve an operation into a content-addressed plan, then apply the plan by its hash. Gives idempotent retry, a reviewable diff before anything mutates, and a natural identity for crash recovery.
- **Concurrency.** Dropping the per-root lock for store admission waits for concurrent-mutator tests. Conditional activation is not scheduled: without a concrete split between observing state and applying a previously derived decision, an expected-generation argument merely asks callers to repeat state Mere can already read. Reconsider it if a real split-phase consumer or observed lost update establishes the need.
- **Build isolation.** Mere builds enter a real namespace in routine package CI, providing end-to-end evidence that the supported build environment works. Network access and the host resolver and CA bundle remain practical inputs rather than bugs by definition. Tighter isolation is not a 1.0 requirement: consider it only for an observed problem or a simple proposal that improves the boundary without sacrificing recipe clarity, debugging, or ease of use.

## Release approach

- Minor bump for anything a user can observe; patch only for fixes that change nothing else.
- Never bundle a behaviour change with a security fix — that forces someone to take the first to get the second.
- One behaviour-changing item per release, so a regression is attributable. Additive items may share one.
- Release notes are generated from commit subjects since the previous tag, so commit subjects are user-facing text.
- `mere describe`'s `schema_version` is independent of Mere's version and moves only when the document's shape breaks a parser.

## Known gaps not scheduled here

Recorded so they are not mistaken for oversights:

- **Repository metadata freshness is not inferred.** A repository signature authenticates provenance and integrity, not universal recency. Mere does not retain a highest-seen timestamp or sequence: timestamps require clock authority, while counters still require every mirror, restored machine, and recovery path to agree on one canonical lineage. Without that authority, anti-rollback state can reject legitimate metadata and make recovery or intentional rollback unsafe. A hostile mirror can therefore replay an older validly signed database; deployments that require freshness need a separately trusted distribution mechanism. Revisit this only with a concrete repository, replica, and recovery model.
