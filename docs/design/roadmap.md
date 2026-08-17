# Roadmap

This is a plan, not a specification. Nothing here is normative — `specification-details.md` describes what Mere does, and this describes what we intend to do next and why in that order. Expect it to be revised as work lands.

## What 1.0 would mean

Mere is the package manager and system-management tool for a distribution, so the promise a 1.0 makes is mostly about persistence: a machine you installed it on keeps working. That is a claim about on-disk formats, the trust model, and the system layout far more than about the CLI.

The formats already version themselves (see "Format Versions and Compatibility"), so 1.0 is not "get the formats right forever". It is **the point at which the set of variants Mere promises to keep reading stops being accidental**. Every variant alive at 1.0 is one every later release inherits.

Proposed definition, to be agreed rather than assumed:

> At 1.0, the accepted-variant list in "Format Versions and Compatibility" is deliberate, the "Current conformance" gaps in the interface contract are closed or consciously accepted, and no release afterwards removes a capability that existing users depend on.

## Two tracks

The remaining work splits cleanly, and the split matters because only one half has a deadline.

### Track A — compatibility and formats (before 1.0)

These change signed or content-addressed formats. None is impossible later, but each done later means another accepted variant, carried by every verification path indefinitely.

- **Decide what store identity covers.** The content hash currently records a file's exec bit and nothing else about mode: setuid, setgid, sticky, the remaining permission bits, and ownership are all outside it, so two payloads differing only in setuid share a store path and `mere store verify` cannot tell them apart. Changing this changes every content hash. Doing it before 1.0 costs a v3 variant; doing it after costs a v3 variant *and* a permanent fourth fallback.
- **Decide on rollback protection for repository metadata.** A validly signed but older `repo.db` is currently indistinguishable from the current one, so a mirror can pin a client to a stale snapshot and keep offering known-vulnerable versions. A monotonic sequence number in the signed database would close this without timestamps or clock trust, which matters because "no network trust or timestamps" is an explicit non-goal. This is a `repo.db` schema change.
- **Give signatures a discriminator.** A manifest signature is 64 raw bytes with no header, so there is no way to express a different algorithm — even though the key file it verifies against records one. Separately, signatures are computed over a digest in one path and over raw bytes in another, with no domain separation between them.
- **Retire read-only variants.** The transitional store hash exists for one unversioned release and is carried by five fallback sites. Decide whether v1 store objects are still readable at 1.0, and drop what is not.
- **Settle the store's permission model.** The store is world-writable by design (§4.1, two-tier admission), and the existing-object fast path accepts a directory on the strength of its content-addressed name. Those two decisions interact, and the interaction should be deliberate.

### Track B — interface and automation (mostly additive)

These add capability without changing existing formats, so most can land after 1.0 without breaking anyone. Ordered by dependency rather than by date.

- **Interface contract and self-description.** Done: the contract section, and `mere describe`. Ship early so the document's shape gets contact with real consumers while `schema_version: 1` is still free to revise.
- **Remove ambient state.** Working-directory profile discovery and TTL-based metadata staleness both make one command mean different things on different runs. This *takes something away* from interactive use, so it belongs before 1.0 even though it is not a format change.
- **Plans as artifacts.** Separate deciding from doing: resolve an operation into a content-addressed plan, then apply the plan by its hash. Gives idempotent retry, a reviewable diff before anything mutates, and a natural identity for crash recovery. Purely additive alongside the existing imperative commands.
- **Attestation.** A signed, append-only record of what was done — who, which plan, which generation before and after. Additive, and reuses the existing Ed25519 machinery.
- **Per-profile compare-and-swap.** Replace the single exclusive lock per root with a content-addressed store that needs no lock plus a compare-and-swap on the profile pointer, so unrelated work stops serializing. **This one is different in kind:** its failure mode is corrupted state rather than an error message, and the test suite currently cannot exercise concurrency at all. The real prerequisite is tests that can run concurrent mutators, not a version number.
- **Hermetic builds.** Builds currently have network access and inherit the host resolver and CA bundle, so a build is not a function of its declared inputs. Opt-in first; flipping the default removes a capability and so belongs before 1.0.

## Release approach

- Minor bump for anything a user can observe; patch only for fixes that change nothing else.
- Never bundle a behaviour change with a security fix — that forces someone to take the first to get the second.
- One behaviour-changing item per release, so a regression is attributable. Additive items may share one.
- Release notes are generated from commit subjects since the previous tag, so commit subjects are user-facing text.
- `mere describe`'s `schema_version` is independent of Mere's version and moves only when the document's shape breaks a parser.

## Known gaps that are not on either track

Recorded so they are not mistaken for oversights:

- Namespace setup is not covered by the test suite: the suite substitutes a host runner, so `enterEnv` never executes under test. Verification is manual. An integration test that actually enters a namespace would close this.
- Schemas for on-disk artifacts are specified here but not emitted in machine-readable form; only the command surface is.
