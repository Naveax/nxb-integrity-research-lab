# NXB-IRL-003 — Evidence Integrity Store

## Status

`COMPLETE — VALIDATION RECORDED`

Tracking issue: `#4`.

Pull request: `#5`.

Canonical validation record: [`NXB-IRL-003-VALIDATION.md`](NXB-IRL-003-VALIDATION.md).

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
    bundle.sig
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
10. `bundle_sha256`, `signature_state` and detached `signature` metadata are excluded from the unsigned bundle identity.

The canonicalization implementation is shared by record creation, chain verification, bundle creation, bundle verification, signing and comparison.

Implemented in `scripts/Nxb.EvidenceStore.psm1`:

- ordinal, case-sensitive object-key sorting,
- array-order preservation,
- manual JSON string escaping,
- unpaired-surrogate rejection,
- integral-number-only enforcement,
- normalized UTC `DateTime` and `DateTimeOffset` handling,
- UTF-8 without BOM hashing,
- lowercase SHA-256 output,
- root-only excluded properties,
- atomic canonical JSON writes.

## Evidence record and append-only chain

Implemented commands:

- `scripts/New-EvidenceStoreRecord.ps1`
- `scripts/Update-EvidenceStoreChainHead.ps1`
- `scripts/Test-EvidenceStoreChain.ps1`
- `scripts/Test-EvidenceStoreSchema.ps1`

A record binds one payload to:

- `experiment_id`,
- `machine_id`,
- `boot_id`,
- `session_id`,
- `sequence`,
- `previous_record_sha256`,
- `captured_utc`,
- `monotonic_ns`.

A new record is written to a pending file, schema-validated and atomically moved to its fixed final filename. Invalid staged records never enter the chain.

Verification checks:

- fixed-width filename and sequence agreement,
- no sequence gaps,
- genesis previous-hash rule,
- exact previous-record linkage,
- stable experiment/machine/boot/session identity,
- payload SHA-256,
- record SHA-256,
- chain-head agreement,
- raw 32-byte digest-concatenation chain hash.

## Tool provenance

Implemented commands:

- `scripts/New-ToolProvenanceRecord.ps1`
- `scripts/Test-ToolProvenanceRecord.ps1`

Records include normalized executable path, executable SHA-256 and length, version metadata, invocation identity, redacted argument-envelope digest, collector identity, status and optional exit code. Raw arguments and secrets are not persisted. Explicit exit code `0` is distinguished from an omitted exit code.

## Clock-offset evidence

Implemented commands:

- `scripts/New-ClockOffsetRecord.ps1`
- `scripts/Test-ClockOffsetRecord.ps1`

Version 1 uses a bounded four-timestamp midpoint method and independently verifies controller elapsed time, target processing time, adjusted round-trip, midpoint offset and uncertainty.

## Deterministic offline evidence bundles

Implemented commands:

- `scripts/New-EvidenceBundle.ps1`
- `scripts/Test-EvidenceBundle.ps1`
- `scripts/Compare-EvidenceBundle.ps1`

Bundle generation:

- verifies the evidence chain first,
- inventories every record in sequence order,
- inventories selected files in ordinal path order,
- binds relative path, byte length and SHA-256,
- requires `chain-head.json`,
- copies no raw evidence,
- requires no network access.

Bundle verification rejects:

- absolute paths,
- `.` or `..` segments,
- duplicate or case-colliding paths,
- bundle self-reference,
- record-inventory truncation,
- missing or modified files,
- identity or chain mismatches,
- reparse-point traversal.

Comparison distinguishes identical bundle identity, same experiment identity with different content and different experiment identity. Signature-state changes are reported separately from unsigned bundle identity.

## Detached local signatures

Implemented commands:

- `scripts/Add-EvidenceBundleSignature.ps1`
- `scripts/Test-EvidenceBundleSignature.ps1`

Version 1 signature algorithm:

```text
rsa-sha256-pkcs1-v1_5
```

The signer:

- loads a local PFX with a SecureString password,
- signs the raw 32-byte `bundle_sha256` digest,
- validates prospective output paths through the nearest existing safe ancestor,
- writes only a detached signature under `evidence-store/signatures/`,
- stores certificate SHA-256, signature SHA-256 and algorithm metadata,
- never stores the PFX path, password or private-key material,
- preserves the unsigned `bundle_sha256` identity,
- rolls the manifest and signature back on a failed commit path.

Signature states:

- `unsigned`: no signature metadata,
- `present_unverified`: signature file and digest are present but no public certificate was supplied,
- `valid`: the supplied public certificate verified the RSA signature.

A manifest that declares `valid` without public-certificate verification fails closed. Missing, modified or wrong-certificate signatures fail closed.

## Repository smoke integration

`scripts/Test-Repository.ps1` runs a complete synthetic flow:

```text
experiment lifecycle
→ observation identity
→ final evidence index
→ append-only evidence records
→ chain-head verification
→ unsigned deterministic bundle
→ offline bundle verification
```

## Adversarial validation coverage

Canonicalization and schemas:

- canonical insertion-order equivalence,
- known SHA-256 vector,
- array-order sensitivity,
- floating-point rejection,
- UTF-8 no-BOM output,
- `DateTime`/`DateTimeOffset` UTC equivalence.

Chain and identity:

- exact one-byte record modification,
- record deletion and sequence gaps,
- record reordering,
- previous-record mismatch after record rehashing,
- record substitution from another experiment,
- machine identity substitution,
- boot identity substitution,
- session identity substitution.

Provenance and clock:

- sensitive argument non-persistence,
- explicit zero versus absent exit code,
- changed tool binary,
- inconsistent re-hashed clock payload,
- invalid clock sample.

Bundle and paths:

- repeated deterministic bundle generation,
- selected-file mutation detected by length or SHA-256,
- record-inventory truncation,
- case-collision and traversal,
- reparse-point path,
- deterministic comparison semantics.

Detached signatures:

- unsigned identity preservation,
- valid public-certificate verification,
- one-byte signature modification,
- wrong public certificate,
- missing signature file,
- unverified `valid` state rejection.

## Validation evidence

Implementation and tests were validated at head:

```text
77c90ea00eb63a64791d0d418999dd5a8abb78a0
```

Validate run `#162`, run ID `30980814078`:

- PowerShell 7 job `92224628625`: 63 passed, 0 failed,
- Windows PowerShell 5.1 job `92224628713`: 63 passed, 0 failed,
- static job `92224628723`: public guard, zero analyzer findings and complete repository smoke success.

The exact acceptance matrix and warning classification are recorded in `docs/NXB-IRL-003-VALIDATION.md`.

Documentation-only closeout commits must pass the same three jobs before PR `#5` is marked ready or merged. Their final exact head/run evidence is stored in PR and issue metadata to avoid changing the validated documentation head again.

## Public repository boundary

Never commit:

- raw ETL or packet captures,
- memory or crash dumps,
- target executables, DLLs, drivers or protected assets,
- private signing keys or PFX files,
- debug secrets,
- undisclosed vulnerability evidence,
- credentials or tokens.

Schemas, synthetic fixtures, verifiers, public certificates and redacted metadata are allowed.

## Closeout sequence

1. Validate the final documentation-only head.
2. Inspect all three final job logs.
3. Update issue `#4` and PR `#5` with exact final head/run/job evidence.
4. Mark PR `#5` ready.
5. Squash merge with expected-head locking.
6. Close issue `#4`.
7. Begin `NXB-IRL-004` from issue `#2`.
