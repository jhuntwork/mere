# Install and activation performance baseline

Mere includes an opt-in synthetic benchmark for the local filesystem work in package installation and system generation activation. It is deliberately separate from the ordinary test suite and does not use the network or the host `/mere` tree.

Run it with an optimized build:

```sh
zig build test-performance_baseline -Doptimize=ReleaseFast --summary all
```

The benchmark constructs a signed local development repository and a fixed package set inside a temporary root. Fixture construction is not timed. It prints the fixture scale, sample count, and median elapsed microseconds for:

- `cold_local_install`: dependency resolution, local archive transfer, verification, store admission, and named-profile publication after removing the prior store, profile, cache, and GC-root state.
- `warm_noop_install`: resolution and the already-current profile fast path with the store and profile intact.
- `incremental_generation`: system generation construction using the preceding generated state as its parent.
- `fast_activation`: manifest validation, `/etc` and boot policy processing, the atomic generation switch, and GC-root maintenance without recomputing store content hashes.
- `full_store_activation`: the same activation path with store content hashes recomputed.

## Interpretation

Compare results only when the Mere commit, optimization mode, fixture constants, filesystem, and machine are recorded. The benchmark reports medians to reduce incidental scheduler and cache noise, but it is not a substitute for measuring a real MereLinux workload.

The benchmark intentionally excludes remote repository latency, production package sizes, service-manager effects, and host-specific `/etc` or boot artifacts. Its purpose is to identify whether Mere's local store/profile/activation work is large enough to justify a focused optimization. A later optimization should name the scenario it improves and preserve the other scenarios as regression evidence.
