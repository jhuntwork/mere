# Manifest signature compatibility fixtures

These hex fixtures freeze Mere's manifest-signature contracts.

- `legacy-v3-manifest.hex` and `legacy-v3-signature.hex` freeze the raw-signature contract inherited unchanged from merged-main commit `b8726de6b1c7901fb5ac3214c319ee233ff03de3`.
- `domain-v2-manifest-v4.hex` and `domain-v2-envelope.hex` freeze the v4 domain-separated message and envelope.
- `test-public-key.hex` is the public key from RFC 8032 test vector 1. Tests derive its matching keypair from the published test seed; no operational Mere key is present here.

The fixtures are encoded as lowercase hex so changes remain reviewable. Tests decode them before verification and assert byte-for-byte writer compatibility. Changing a fixture is a persisted-format change, not routine test maintenance.
