# NXB-IRL-003 — Evidence Integrity Store

## Status

`ACTIVE — FINAL CI REPAIR`

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
- raw 32-byte digest concatenation chain hash.

## Tool provenance

Implemented commands:

- `scripts/New-ToolProvenanceRecord.ps1`
- `scripts/Test-ToolProvenanceRecord.ps1`

Records include normalized executable path, executable SHA-256 and length, version metadata, invocation identity, redacted argument-envelope digest, collector identity, status and optional exit code. Raw arguments and secrets are not persisted.

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
- record inventory truncation,
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
- writes only a detached signature under `evidence-store/signatures/`,
- stores certificate SHA-256, signature SHA-256 and algorithm metadata,
- never stores the PFX path, password or private key material,
- preserves the unsigned `bundle_sha256` identity.

Signature states:

- `unsigned`: no signature metadata,
- `present_unverified`: signature file and digest are present but no public certificate was supplied,
- `valid`: the supplied public certificate verified the RSA signature.

A manifest that declares `valid` without public-certificate verification fails closed. Missing, modified or wrong-certificate signatures fail closed.

## Repository smoke integration

`scripts/Test-Repository.ps1` now runs a complete synthetic flow:

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

- canonical insertion-order equivalence,
- known SHA-256 vector,
- array-order sensitivity,
- floating-point rejection,
- UTF-8 no-BOM output,
- payload tamper,
- record deletion and sequence gaps,
- identity substitution with recomputed record hash,
- sensitive argument non-persistence,
- changed tool binary,
- inconsistent re-hashed clock payload,
- invalid clock sample,
- repeated deterministic bundle generation,
- selected-file mutation,
- record-inventory truncation,
- case-collision and traversal,
- reparse-point path,
- detached signature identity preservation,
- one-byte signature modification,
- wrong public certificate,
- missing signature file,
- unverified `valid` state rejection.

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

## Current validation state

Validate run `#145` targets the current PR head. The previous run identified eight PSScriptAnalyzer findings: seven state-changing helper verb names and one plaintext SecureString fixture conversion. All eight were repaired without disabling analyzer rules.

Required final jobs:

- Static analysis and repository smoke validation,
- Lifecycle — PowerShell 7,
- Lifecycle — Windows PowerShell 5.1.

## Remaining sequence

1. Inspect and repair Validate `#145`.
2. Record the final all-green run and every job log.
3. Update issue `#4`, PR `#5`, `HANDOFF.md` and the validation closeout record.
4. Mark PR ready and merge only with exact validated head.
5. Close issue `#4` and begin `NXB-IRL-004`.
