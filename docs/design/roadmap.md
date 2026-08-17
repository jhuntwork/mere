# Roadmap

This is a plan, not a specification. Nothing here is normative — `specification-details.md` describes what Mere does, and this describes what we intend to do next and why in that order. Expect it to be revised as work lands.

## What 1.0 would mean

Mere is the package manager and system-management tool for a distribution, so the promise a 1.0 makes is mostly about persistence: a machine you installed it on keeps working. That is a claim about on-disk formats, the trust model, and the system layout far more than about the CLI.

The formats already version themselves (see "Format Versions and Compatibility"), so 1.0 is not "get the formats right forever". It is **the point at which the set of variants Mere promises to keep reading stops being accidental**. Every variant alive at 1.0 is one every later release inherits.

Working definition:

> At 1.0, the accepted-variant list in "Format Versions and Compatibility" is deliberate, every "Current conformance" gap in the interface contract is either closed or explicitly accepted, and no release afterwards removes a capability that existing users depend on.

Note what the middle clause does and does not require. A gap may be closed by building something, or closed by deciding not to and recording why. What it rules out is a gap surviving to 1.0 because nobody looked at it.

## Scope for 1.0

Three kinds of work, distinguished by whether they have a deadline.

**Format changes have one.** Each is a change to a signed or content-addressed format, so doing it after 1.0 means adding an accepted variant that every later release inherits and every verification path carries.

**Capability removals have one.** Not because of formats, but because 1.0 promises not to do them afterwards.

**Additive work does not.** It can land after 1.0 without breaking anyone, and gating 1.0 on it buys no compatibility benefit.

### Before 1.0

Format changes (detailed below):

- Decide what store identity covers
- Rollback protection for repository metadata
- Signature discriminator and domain separation
- Retire read-only variants
- Settle the store's permission model

Capability removals:

- **Remove ambient state.** Working-directory profile discovery and TTL-based metadata staleness.
- **Hermetic builds by default.** Opt-in can ship earlier; flipping the default is the removal.

Closing the remaining conformance gaps:

- **`--expect-generation N` on activation.** Closes the half of the concurrency gap that consumers actually need: expressing "apply only if the profile is still where I last saw it", so a loser re-derives instead of clobbering. Small — activation already stages a temporary symlink and renames it.
- **Attestation.** A signed, append-only record of what was done, closing "no record of action". Self-contained, and reuses the existing Ed25519 machinery.
- **Artifact schemas: accepted, not closed.** Machine-readable schemas for the hand-rolled binary manifests and profile state are deliberately *not* planned. Consumers reach these formats through Mere rather than around it, the shapes are already specified in `specification-details.md`, and a hand-maintained schema document would carry exactly the drift risk that `mere describe` exists to avoid. Revisit if a real consumer needs it.

### After 1.0

- **Plans as artifacts.** Additive alongside the existing imperative commands.
- **Lockless store admission.** The other half of the concurrency gap: a content-addressed store needs no mutual exclusion, so unrelated work should stop serializing on one lock per root. Deferred deliberately — its failure mode is corrupted state rather than an error message, and the suite cannot exercise concurrency at all today. The prerequisite is test scaffolding that runs concurrent mutators, which is hard to bound before starting it. Better in a 1.1 with real tests than rushed to make a date.

## Detail

### Format changes

None of these is impossible after 1.0. Each done later means another accepted variant, carried by every verification path indefinitely.

- **Decide what store identity covers.** The content hash currently records a file's exec bit and nothing else about mode: setuid, setgid, sticky, the remaining permission bits, and ownership are all outside it, so two payloads differing only in setuid share a store path and `mere store verify` cannot tell them apart. Changing this changes every content hash. Doing it before 1.0 costs a v3 variant; doing it after costs a v3 variant *and* a permanent fourth fallback.
- **Decide on rollback protection for repository metadata.** A validly signed but older `repo.db` is currently indistinguishable from the current one, so a mirror can pin a client to a stale snapshot and keep offering known-vulnerable versions. A monotonic sequence number in the signed database would close this without timestamps or clock trust, which matters because "no network trust or timestamps" is an explicit non-goal. This is a `repo.db` schema change.
- **Give signatures a discriminator.** A manifest signature is 64 raw bytes with no header, so there is no way to express a different algorithm — even though the key file it verifies against records one. Separately, signatures are computed over a digest in one path and over raw bytes in another, with no domain separation between them.
- **Retire read-only variants.** The transitional store hash exists for one unversioned release and is carried by five fallback sites. Decide whether v1 store objects are still readable at 1.0, and drop what is not.
- **Settle the store's permission model.** The store is world-writable by design (§4.1, two-tier admission), and the existing-object fast path accepts a directory on the strength of its content-addressed name. Those two decisions interact, and the interaction should be deliberate.

### Interface and automation

- **Interface contract and self-description.** Done: the contract section, and `mere describe`. Shipped early so the document's shape gets contact with real consumers while `schema_version: 1` is still free to revise.
- **Remove ambient state.** Working-directory profile discovery and TTL-based metadata staleness both make one command mean different things on different runs for reasons not visible in the command. Where the convenience is worth keeping for interactive use, it should at least be resolvable to an explicit form.
- **Attestation.** A signed, append-only record of what was done — who, which plan, which generation before and after.
- **Plans as artifacts.** Separate deciding from doing: resolve an operation into a content-addressed plan, then apply the plan by its hash. Gives idempotent retry, a reviewable diff before anything mutates, and a natural identity for crash recovery.
- **Concurrency.** Two halves, scheduled apart. `--expect-generation N` is small and belongs before 1.0. Dropping the per-root lock for store admission is not, and waits for concurrent-mutator tests.
- **Hermetic builds.** Builds currently have network access and inherit the host resolver and CA bundle, so a build is not a function of its declared inputs.

## Release approach

- Minor bump for anything a user can observe; patch only for fixes that change nothing else.
- Never bundle a behaviour change with a security fix — that forces someone to take the first to get the second.
- One behaviour-changing item per release, so a regression is attributable. Additive items may share one.
- Release notes are generated from commit subjects since the previous tag, so commit subjects are user-facing text.
- `mere describe`'s `schema_version` is independent of Mere's version and moves only when the document's shape breaks a parser.

## Known gaps not scheduled here

Recorded so they are not mistaken for oversights:

- Namespace setup is not covered by the test suite: the suite substitutes a host runner, so `enterEnv` never executes under test. Verification is manual. An integration test that actually enters a namespace would close this, and is a prerequisite worth having before the hermetic-build work changes that setup again.
