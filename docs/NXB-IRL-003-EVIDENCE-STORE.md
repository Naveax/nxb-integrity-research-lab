# NXB-IRL-003 — Evidence Integrity Store

## Status

`INITIAL CONTRACT`

Tracking issue: `#4`.

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
5. JSON strings use the serializer's required escaping only.
6. Timestamps use UTC RFC 3339 form with a trailing `Z`.
7. Hashes are lowercase hexadecimal SHA-256 strings without a prefix.
8. Numbers used by the contract are integers; floating-point values are not allowed in hash-bearing records.
9. `record_sha256` is excluded from its own hash input.
10. Optional signatures are excluded from the unsigned record and bundle identities.

The canonicalization implementation must be shared by record creation, bundle creation, verification and comparison.

## Evidence record

A record binds one payload to an experiment identity and the previous record.

Required identity fields:

- `experiment_id`,
- `machine_id`,
- `boot_id`,
- `session_id`.

Required ordering fields:

- `sequence`,
- `previous_record_sha256`.

Required timing fields:

- `captured_utc`,
- `monotonic_ns`.

Required payload fields:

- `record_type`,
- `payload`,
- `payload_sha256`.

`record_sha256` is SHA-256 over the canonical record object after removing only the `record_sha256` property.

The genesis record has sequence `0` and `previous_record_sha256: null`. Every later record must use sequence `previous.sequence + 1` and the exact SHA-256 of the previous record.

## Initial record types

- `manifest_snapshot`
- `evidence_index_snapshot`
- `tool_provenance`
- `clock_offset`
- `observation_identity`
- `bundle_seal`

Unknown record types are rejected in schema version 1.

## Tool provenance

Tool provenance records include only verifiable metadata:

- normalized executable path or stable tool identifier,
- file SHA-256 when a local executable exists,
- product/file version when available,
- invocation name,
- normalized argument digest,
- collector/runtime identity,
- exit code and bounded status metadata.

Raw secrets, tokens, passwords, private keys and unredacted sensitive command arguments are forbidden.

## Clock-offset evidence

Clock-offset records bind controller and target observations using integers:

- controller send UTC nanoseconds,
- target receive monotonic nanoseconds,
- target send monotonic nanoseconds,
- controller receive UTC nanoseconds,
- estimated offset nanoseconds,
- round-trip nanoseconds,
- uncertainty nanoseconds,
- measurement method.

A verifier checks internal arithmetic bounds but does not claim physical clock accuracy beyond the recorded uncertainty.

## Chain head

`chain-head.json` summarizes the verified append-only chain:

- identity binding,
- record count,
- genesis record hash,
- last sequence,
- last record hash,
- canonical chain digest.

The chain digest is SHA-256 over the ordered concatenation of raw 32-byte record digests. It is not computed over filenames or directory order.

## Offline evidence bundle

The bundle manifest contains a deterministic sorted inventory of:

- evidence-store records,
- chain head,
- selected experiment metadata,
- selected evidence files by relative path, length and SHA-256.

Bundle verification must require no network access. Absolute paths are forbidden. Path traversal, reparse-point traversal and case-collision ambiguity must fail closed.

`bundle_sha256` excludes only the `bundle_sha256` property and optional signature material.

## Optional local signatures

Signing is optional and local.

- Unsigned bundles remain verifiable and are reported as `unsigned`.
- A present valid signature is reported as `valid`.
- A present invalid signature is rejected.
- Public keys or certificates may be distributed; private keys may not be committed.
- Signature absence must never be represented as signature success.

The first implementation may support a detached signature adapter while keeping the unsigned hash contract stable.

## Comparison semantics

Comparison reports distinguish:

- identical bundle identity,
- same experiment identity with different content,
- different experiment identity,
- missing records,
- added records,
- reordered/substituted chain,
- payload changes,
- provenance changes,
- clock-evidence changes,
- signature-state changes.

Comparison output is evidence metadata, not proof that two target executions were behaviorally equivalent.

## Fail-closed rules

Verification fails when:

- canonical serialization cannot be reproduced,
- a record hash mismatches,
- sequence is discontinuous,
- previous hash mismatches,
- genesis rules are violated,
- identity fields change within one chain,
- a payload hash mismatches,
- chain-head values disagree with records,
- a listed bundle file is missing or changed,
- an unexpected case-colliding path exists,
- a reparse point is encountered,
- a present signature is invalid.

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

## Initial implementation sequence

1. Add Draft 2020-12 schemas.
2. Implement canonical JSON serialization and hashing.
3. Implement append-only record creation.
4. Implement full chain verification.
5. Add tool provenance and clock-offset record helpers.
6. Implement deterministic offline bundle creation.
7. Implement bundle verification and comparison.
8. Add optional detached signing adapter.
9. Add adversarial Pester tests on PowerShell 5.1 and PowerShell 7.

## Completion gates

- identical inputs produce identical canonical hashes,
- one-byte changes are detected,
- deletion, reordering and substitution are detected,
- identity mismatch fails closed,
- tool provenance can be independently checked,
- offline verification requires no network,
- unsigned and invalid-signature states are unambiguous,
- all Windows CI jobs are green,
- no private evidence or key enters the public repository.
