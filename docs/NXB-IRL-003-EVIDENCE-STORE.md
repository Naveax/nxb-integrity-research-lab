# NXB-IRL-003 — Evidence Integrity Store

## Status

`ACTIVE IMPLEMENTATION`

Tracking issue: `#4`.

Draft PR: `#5`.

## Objective

Provide a deterministic, append-only and independently verifiable evidence integrity store for authorized research experiments.

The store protects evidence metadata and provenance. It does not make raw ETL, dumps, target binaries, signing keys or undisclosed findings suitable for the public repository.

## Directory contract

Each experiment may contain:

```text
evidence-store/
  records/
    0000000000000000.json
    0000000000000001.json
  chain-head.json
  bundle-manifest.json
  signatures/
```

Record filenames are fixed-width lowercase decimal sequence numbers. Directory enumeration order is never trusted.

## Canonical serialization

Version 1 canonical JSON uses these rules:

1. UTF-8 without a byte-order mark for hashed JSON bytes.
2. Object properties sorted by ordinal Unicode code-point order.
3. Arrays preserve their declared order.
4. No insignificant whitespace.
5. JSON strings use required escaping only.
6. Timestamps use UTC RFC 3339 form with a trailing `Z`.
7. Hashes are lowercase hexadecimal SHA-256 strings without a prefix.
8. Hash-bearing numbers are integers; floating-point values are rejected.
9. Self-hash properties are excluded only at the root object.
10. Detached signature material must not change the unsigned bundle identity.

The implementation is shared by record creation, chain verification, bundle creation, bundle verification and comparison through `scripts/Nxb.EvidenceStore.psm1`.

Implemented canonical primitives:

- ordinal, case-sensitive object-key sorting,
- array-order preservation,
- manual JSON string escaping,
- unpaired-surrogate rejection,
- integral-number-only enforcement,
- UTF-8 without BOM hashing,
- lowercase SHA-256 output,
- root-only excluded properties,
- atomic canonical JSON writes.

## Evidence records and append-only chain

A record binds one payload to:

- `experiment_id`,
- `machine_id`,
- `boot_id`,
- `session_id`,
- `sequence`,
- `previous_record_sha256`,
- `captured_utc`,
- `monotonic_ns`,
- `record_type`,
- `payload_sha256`,
- `record_sha256`.

The genesis record has sequence `0` and `previous_record_sha256: null`. Every later record uses the previous sequence plus one and the exact previous record hash.

Records are created under an exclusive append lock. A record is first written to a pending file outside `records/`, schema-validated and then atomically moved to its fixed final filename. Invalid staged records are removed and never become chain members.

Implemented commands:

- `scripts/New-EvidenceStoreRecord.ps1`
- `scripts/Update-EvidenceStoreChainHead.ps1`
- `scripts/Test-EvidenceStoreChain.ps1`
- `scripts/Test-EvidenceStoreSchema.ps1`

Chain verification checks:

- fixed-width filename and sequence agreement,
- no sequence gaps,
- genesis previous-hash rule,
- exact previous-record linkage,
- stable experiment/machine/boot/session identity,
- payload SHA-256,
- record SHA-256,
- chain-head agreement,
- raw 32-byte digest concatenation chain hash.

## Record types

Version 1 permits:

- `manifest_snapshot`
- `evidence_index_snapshot`
- `tool_provenance`
- `clock_offset`
- `observation_identity`
- `bundle_seal`

Unknown record types are rejected.

## Tool provenance

Implemented commands:

- `scripts/New-ToolProvenanceRecord.ps1`
- `scripts/Test-ToolProvenanceRecord.ps1`

Tool provenance records contain bounded verifiable metadata:

- normalized executable path,
- executable SHA-256 and byte length,
- last-write UTC,
- product/file version when available,
- invocation name,
- canonical digest of a redacted argument envelope,
- argument and redaction counts,
- collector identity,
- status and optional exit code.

Raw arguments are not persisted. Sensitive argument indexes are replaced with `<redacted>` before hashing. Verification independently re-hashes the current or explicitly overridden executable.

## Clock-offset evidence

Implemented commands:

- `scripts/New-ClockOffsetRecord.ps1`
- `scripts/Test-ClockOffsetRecord.ps1`

Version 1 uses four timestamps:

- controller send UTC nanoseconds,
- target receive monotonic nanoseconds,
- target send monotonic nanoseconds,
- controller receive UTC nanoseconds.

The helper and independent verifier reproduce:

- controller elapsed time,
- target processing time,
- adjusted round-trip,
- midpoint UTC-minus-monotonic offset,
- half-round-trip uncertainty rounded upward.

Negative elapsed values and target processing longer than controller elapsed time fail closed.

## Chain head

`chain-head.json` contains:

- chain identity binding,
- record count,
- genesis record hash,
- last sequence,
- last record hash,
- SHA-256 over the ordered concatenation of raw 32-byte record digests.

The chain digest is independent of filesystem enumeration order.

## Deterministic offline evidence bundle

Implemented commands:

- `scripts/New-EvidenceBundle.ps1`
- `scripts/Test-EvidenceBundle.ps1`
- `scripts/Compare-EvidenceBundle.ps1`

`bundle-manifest.json` contains:

- chain identity and `chain_sha256`,
- every record in exact sequence order with relative path, byte length and file SHA-256,
- selected experiment files sorted by ordinal canonical relative path,
- explicit `signature_state`,
- canonical `bundle_sha256`.

The generator does not copy raw evidence. It creates a deterministic manifest for files already inside the experiment boundary.

Version 1 bundle paths:

- use forward slashes only,
- are relative to the experiment root,
- reject drive prefixes and leading slashes,
- reject empty, `.` and `..` segments,
- reject repeated separators,
- reject exact duplicates,
- reject case-colliding paths,
- reject reparse-point traversal,
- cannot include the bundle manifest itself,
- cannot place the manifest inside `evidence-store/records/`.

The bundle must include `evidence-store/chain-head.json`.

Offline verification requires no network and performs:

1. Draft 2020-12 schema validation.
2. Canonical bundle self-hash reproduction.
3. Complete append-only chain verification.
4. Bundle identity and chain-digest comparison.
5. Exact record count, sequence and path checks.
6. Record and selected-file byte-length checks.
7. Record and selected-file SHA-256 checks.
8. Canonical path ordering, duplicate and case-collision checks.
9. Explicit signature-state handling.

Until the detached signing adapter is implemented, `Test-EvidenceBundle.ps1` accepts only explicitly `unsigned` bundles and rejects other signature states.

## Bundle comparison

`Compare-EvidenceBundle.ps1` distinguishes:

- `identical_bundle_identity`,
- `same_experiment_identity_different_content`,
- `different_experiment_identity`.

It reports:

- identity-field changes,
- chain digest changes,
- signature-state changes,
- record entries present only on either side,
- changed record entries,
- file entries present only on either side,
- changed file entries.

With experiment roots supplied, both bundles are fully verified before comparison. Without roots, each manifest is schema-validated and self-hash-validated before metadata comparison.

Comparison is evidence metadata analysis; it is not proof that two target executions were behaviorally equivalent.

## Optional local signatures

Signing remains the next implementation block.

Required semantics:

- unsigned bundles remain verifiable and report `unsigned`,
- detached signature material does not change the unsigned bundle identity,
- a present valid signature reports `valid`,
- a present signature without a verification certificate reports `present_unverified`,
- an invalid signature is rejected,
- public certificates may be distributed,
- private keys may not be committed.

## Fail-closed rules

Verification fails when:

- canonical serialization cannot be reproduced,
- record or payload hashes mismatch,
- sequence or previous-hash linkage is invalid,
- identity changes inside a chain,
- chain-head values disagree,
- tool binary hash or length mismatches,
- clock arithmetic cannot be reproduced,
- bundle identity disagrees with the chain,
- a listed record or file is missing, changed or reordered,
- bundle record inventory is truncated,
- a path is absolute, non-canonical, duplicated or case-colliding,
- a reparse point is encountered,
- the bundle references itself,
- an unsupported or invalid signature state is encountered.

## Public repository boundary

Never commit:

- raw ETL or packet captures,
- memory or crash dumps,
- target executables, DLLs, drivers or protected assets,
- private signing keys,
- debug secrets,
- undisclosed vulnerability evidence,
- credentials or tokens.

Schemas, synthetic fixtures, verifiers and redacted metadata are allowed.

## Validation coverage implemented

- canonical insertion-order equivalence,
- known SHA-256 vector,
- array-order sensitivity,
- floating-point rejection,
- UTF-8 no-BOM output,
- root-only hash-field exclusion,
- schema self-validation,
- deterministic linked record hashes,
- payload tamper,
- record deletion and sequence gaps,
- identity substitution with a recomputed record hash,
- sensitive argument non-persistence,
- tool binary mutation,
- clock arithmetic reproduction,
- re-hashed inconsistent clock payload,
- invalid clock sample,
- deterministic repeated bundle generation,
- selected-file mutation,
- bundle record-inventory truncation,
- case-colliding inventory paths,
- traversal paths,
- identical and same-identity-different-content comparison.

## Remaining implementation sequence

1. Implement the optional detached local signing adapter.
2. Add valid, unverified and invalid-signature tests.
3. Add an explicit bundle reparse-point adversarial test.
4. Integrate an evidence-store and bundle flow into repository smoke validation.
5. Inspect and repair Windows CI on the final candidate head.
6. Complete PowerShell 5.1, PowerShell 7 and PSScriptAnalyzer closeout.
7. Mark PR #5 ready and merge only after every gate is green.

## Completion gates

- identical inputs produce identical canonical hashes,
- one-byte changes are detected,
- deletion, reordering and substitution are detected,
- identity mismatch fails closed,
- tool provenance is independently verifiable,
- clock-offset arithmetic is independently reproducible,
- offline bundle verification requires no network,
- bundle truncation and path ambiguity are rejected,
- unsigned, unverified, valid and invalid-signature states are unambiguous,
- all Windows CI jobs are green,
- no private evidence or key enters the public repository.
