# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Completed issue: `#1 — NXB-IRL-002`
- Prepared observability issue: `#2 — NXB-IRL-004`
- Active issue: `#4 — NXB-IRL-003 — Evidence integrity store`
- Merged PR: `#3 — NXB-IRL-002: close deterministic lifecycle validation gaps`
- Active draft PR: `#5 — NXB-IRL-003: deterministic evidence integrity store`
- Active branch: `nxb-irl-003-evidence-integrity-store`
- NXB-IRL-002 validated head: `878710229ad11c5c1b95247e304986ca4e5eda47`
- NXB-IRL-002 squash merge: `e3b3ab79ab72cafa92f2afa97895258cec912d86`

## Current objective

Complete `NXB-IRL-003 — Evidence integrity store`.

Required scope:

- canonical evidence identity,
- append-only record chain,
- tool provenance,
- controller/target clock offset,
- machine/boot/session identity,
- deterministic offline evidence bundle,
- bundle verification and comparison,
- optional detached local signature.

## Canonical references

1. `docs/MASTER_PLAN.md`
2. `docs/FULL_SYSTEM_OBSERVABILITY.md`
3. `docs/ROADMAP.md`
4. `docs/NXB-IRL-002-VALIDATION.md`
5. `docs/NXB-IRL-003-EVIDENCE-STORE.md`
6. issue `#4`
7. draft PR `#5`
8. issue `#2`

## Completed phases

### NXB-IRL-001 — Repository bootstrap

- workspace and experiment creation,
- baseline collection,
- WPR trace lifecycle,
- KDNET preparation check,
- evidence hashing and finalization,
- public/private evidence boundary.

### NXB-IRL-002 — Deterministic experiment lifecycle

Status: `COMPLETE`

Validated on GitHub Actions:

- static analysis and repository smoke validation,
- PowerShell 7 lifecycle suite,
- Windows PowerShell 5.1 lifecycle suite.

Detailed record: `docs/NXB-IRL-002-VALIDATION.md`.

### NXB-IRL-004 preparation already on main

- full-system observability architecture,
- system-capability schema and collector,
- normalized event schema,
- machine/boot/monotonic-clock identity,
- issue `#2`.

## NXB-IRL-003 implemented on draft PR #5

### Contracts and canonical identity

- Draft 2020-12 record, chain-head and bundle schemas,
- record-type-specific provenance and clock payload schemas,
- ordinal case-sensitive canonical JSON,
- manual JSON escaping and invalid-surrogate rejection,
- integer-only hash-bearing values,
- UTF-8 without BOM hash bytes,
- lowercase SHA-256,
- root-only self-hash exclusions,
- atomic canonical JSON writes.

### Append-only evidence chain

- exclusive append lock,
- staged schema validation before final append,
- fixed-width 16-digit record filenames,
- payload and record SHA-256,
- exact previous-record linkage,
- experiment/machine/boot/session identity binding,
- deterministic chain-head,
- raw digest-concatenation chain hash,
- complete chain verifier.

### Tool provenance

- executable path/hash/length/version capture,
- invocation and collector identity,
- redacted argument-envelope digest,
- no raw argument persistence,
- independent executable verification.

### Clock-offset evidence

- four-timestamp midpoint method,
- controller and target elapsed accounting,
- adjusted round-trip,
- midpoint offset,
- upward-rounded uncertainty,
- independent arithmetic verification.

### Deterministic offline bundle

Implemented commands:

- `scripts/New-EvidenceBundle.ps1`
- `scripts/Test-EvidenceBundle.ps1`
- `scripts/Compare-EvidenceBundle.ps1`

Implemented behavior:

- exact record inventory in sequence order,
- selected-file inventory in ordinal canonical path order,
- relative path, byte length and file SHA-256 binding,
- mandatory chain-head inventory,
- offline schema/self-hash/chain/file verification,
- no network dependency,
- no raw evidence copying,
- exact duplicate and case-collision rejection,
- absolute/traversal/non-canonical path rejection,
- reparse-point rejection,
- bundle self-reference rejection,
- identical/same-identity-different-content/different-identity comparison.

### Adversarial coverage

- canonical property insertion order,
- array-order sensitivity,
- floating-point rejection,
- payload tamper,
- record deletion and sequence gaps,
- identity substitution with recomputed record hash,
- sensitive argument non-persistence,
- changed tool binary,
- inconsistent clock arithmetic after rehash,
- invalid clock samples,
- deterministic repeated bundle generation,
- selected-file mutation,
- record-inventory truncation,
- case-colliding paths,
- traversal paths,
- bundle comparison semantics.

## Current validation state

Status: `WINDOWS CI QUEUED`

The workflow uses PR/ref concurrency with `cancel-in-progress`. Resolve the current head and latest Validate run from PR #5; do not trust a stale SHA stored in this document.

Required jobs:

- Static analysis and repository smoke validation,
- Lifecycle — PowerShell 7,
- Lifecycle — Windows PowerShell 5.1.

PR #5 remains draft until full NXB-IRL-003 completion and final green CI.

## Remaining NXB-IRL-003 sequence

1. Implement optional detached local signing while preserving unsigned bundle identity.
2. Add explicit unsigned, present-unverified, valid and invalid-signature tests.
3. Add a bundle reparse-point adversarial test.
4. Integrate evidence-store and bundle creation into repository smoke validation.
5. Inspect the first completed final-head Windows CI logs.
6. Repair parser, PSScriptAnalyzer or Pester failures without weakening gates.
7. Update PR #5 and issue #4 closeout records.
8. Mark ready and merge only after every final job is green.

## Required quality gates

- deterministic serialization and hashing,
- append-only chain verification,
- record deletion/reordering/substitution detection,
- identity mismatch rejection,
- independent tool provenance verification,
- independent clock arithmetic verification,
- offline bundle verification,
- bundle truncation and path ambiguity rejection,
- explicit signature-state semantics,
- PowerShell 5.1 and PowerShell 7 CI,
- clean PSScriptAnalyzer and repository smoke gates,
- no raw private evidence or signing key committed.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md and docs/NXB-IRL-003-EVIDENCE-STORE.md.
Confirm PR #3 is merged and issue #1 is closed.
Inspect issue #4 and draft PR #5.
Resolve the current PR #5 head and latest Validate run.
Continue from the first incomplete item: optional detached local signing, then final CI repair.
Keep issue #2 as the prepared NXB-IRL-004 full-system observability track.
Update HANDOFF.md and the active issue/PR after every completed block.
```
