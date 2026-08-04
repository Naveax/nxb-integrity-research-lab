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
5. JSON strings use the serializer's required escaping only.
6. Timestamps use UTC RFC 3339 form with a trailing `Z`.
7. Hashes are lowercase hexadecimal SHA-256 strings without a prefix.
8. Numbers used by the contract are integers; floating-point values are not allowed in hash-bearing records.
9. `record_sha256` is excluded from its own hash input.
10. Optional signatures are excluded from the unsigned record and bundle identities.

The canonicalization implementation is shared by record creation, chain verification, bundle creation, bundle verification and comparison.

## Implemented canonical identity

Implemented in `scripts/Nxb.EvidenceStore.psm1`:

- ordinal, case-sensitive object key sorting,
- array-order preservation,
- manual JSON string escaping,
- unpaired-surrogate rejection,
- integral-number-only enforcement,
- UTF-8 without BOM hashing,
- lowercase SHA-256 output,
- root-only excluded properties,
- atomic canonical JSON writes.

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

`record_sha256` is SHA-256 over the canonical record object after removing only the root `record_sha256` property.

The genesis record has sequence `0` and `previous_record_sha256: null`. Every later record uses sequence `previous.sequence + 1` and the exact SHA-256 of the previous record.

Records are written under an exclusive append lock. A new record is first written to a pending file outside `records/`, schema-validated, then atomically moved to its fixed final filename. Invalid staged records are removed and never become part of the chain.

## Initial record types

- `manifest_snapshot`
- `evidence_index_snapshot`
- `tool_provenance`
- `clock_offset`
- `observation_identity`
- `bundle_seal`

Unknown record types are rejected in schema version 1.

## Implemented append-only chain

Implemented commands:

- `scripts/New-EvidenceStoreRecord.ps1`
- `scripts/Update-EvidenceStoreChainHead.ps1`
- `scripts/Test-EvidenceStoreChain.ps1`
- `scripts/Test-EvidenceStoreSchema.ps1`

Verification checks:

- fixed-width filename and sequence agreement,
- no sequence gaps,
- genesis previous-hash rule,
- exact previous-record linkage,
- stable experiment/machine/boot/session identity,
- payload SHA-256,
- record SHA-256,
- chain-head agreement,
- raw 32-byte digest concatenation chain hash.

## Tool provenance

Implemented commands:

- `scripts/New-ToolProvenanceRecord.ps1`
- `scripts/Test-ToolProvenanceRecord.ps1`

Tool provenance records contain only verifiable bounded metadata:

- normalized executable path,
- executable SHA-256 and byte length,
- last-write UTC,
- product/file version when available,
- invocation name,
- canonical digest of a redacted argument envelope,
- argument and redaction counts,
- collector identity,
- status and optional exit code.

Raw command arguments are not stored. Sensitive argument indexes are replaced with `<redacted>` before the argument envelope is hashed. A verifier independently re-hashes the current or explicitly overridden executable path.

## Clock-offset evidence

Implemented commands:

- `scripts/New-ClockOffsetRecord.ps1`
- `scripts/Test-ClockOffsetRecord.ps1`

Version 1 uses four timestamps:

- controller send UTC nanoseconds,
- target receive monotonic nanoseconds,
- target send monotonic nanoseconds,
- controller receive UTC nanoseconds.

The helper computes:

- controller elapsed time,
- target processing time,
- adjusted round-trip time,
- midpoint estimated UTC-minus-monotonic offset,
- half-round-trip uncertainty rounded upward.

Negative elapsed values and samples where target processing exceeds controller elapsed time fail closed. The verifier independently reproduces the arithmetic.

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

The bundle manifest will contain a deterministic sorted inventory of:

- evidence-store records,
- chain head,
- selected experiment metadata,
- selected evidence files by relative path, length and SHA-256.

Bundle verification must require no network access. Absolute paths are forbidden. Path traversal, reparse-point traversal and case-collision ambiguity must fail closed.

`bundle_sha256` excludes only the root `bundle_sha256` property and optional signature material.

Status: `NEXT IMPLEMENTATION BLOCK`.

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
- tool binary hash or length mismatches,
- clock arithmetic cannot be reproduced,
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

## Validation coverage implemented

- canonical insertion-order equivalence,
- known SHA-256 vector,
- array-order sensitivity,
- floating-point rejection,
- UTF-8 no-BOM output,
- root-only hash-field exclusion,
- schema self-validation,
- valid and invalid schema fixtures,
- deterministic two-store record hashes,
- payload tamper detection,
- record deletion/sequence-gap detection,
- identity substitution detection,
- tool secret non-persistence,
- tool binary mutation detection,
- clock arithmetic verification,
- re-hashed clock arithmetic tamper detection,
- invalid clock sample rejection.

## Remaining implementation sequence

1. Complete Windows CI repair for the current branch.
2. Implement deterministic offline bundle creation.
3. Implement bundle verification and comparison.
4. Add optional detached signing adapter.
5. Add bundle truncation, path collision and signature adversarial tests.
6. Run final PowerShell 5.1, PowerShell 7, PSScriptAnalyzer and repository smoke validation.

## Completion gates

- identical inputs produce identical canonical hashes,
- one-byte changes are detected,
- deletion, reordering and substitution are detected,
- identity mismatch fails closed,
- tool provenance can be independently checked,
- clock-offset arithmetic is independently reproducible,
- offline verification requires no network,
- unsigned and invalid-signature states are unambiguous,
- all Windows CI jobs are green,
- no private evidence or key enters the public repository.
