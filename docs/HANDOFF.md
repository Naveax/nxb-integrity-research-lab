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
- Active draft PR: `#5 — NXB-IRL-003: evidence integrity store contracts`
- Active branch: `nxb-irl-003-evidence-integrity-store`
- NXB-IRL-002 validated head: `878710229ad11c5c1b95247e304986ca4e5eda47`
- NXB-IRL-002 squash merge: `e3b3ab79ab72cafa92f2afa97895258cec912d86`

## Current objective

Complete `NXB-IRL-003 — Evidence integrity store`.

The required scope from `docs/MASTER_PLAN.md` is:

- canonical manifest hash,
- experiment chain,
- tool provenance,
- controller/target clock offset,
- machine/boot/session identity,
- offline evidence bundle,
- integrity comparison,
- optional local signature.

## Canonical project direction

The platform is a full-system observability and evidence system for authorized security and performance research across:

- CPU and scheduler,
- RAM, virtual memory, page faults and working set,
- GPU, queue, residency and present,
- disk, storage queue and file system,
- network and NDIS,
- PCIe, PnP devices and signed drivers,
- kernel/service/driver lifecycle,
- power, frequency and thermal state,
- firmware, Secure Boot, TPM, VBS/HVCI and boot identity.

Required references:

1. `docs/MASTER_PLAN.md`
2. `docs/FULL_SYSTEM_OBSERVABILITY.md`
3. `docs/ROADMAP.md`
4. `docs/NXB-IRL-002-VALIDATION.md`
5. `docs/NXB-IRL-003-EVIDENCE-STORE.md`
6. issue `#4`
7. issue `#2`

## Completed

### NXB-IRL-001 — Repository bootstrap

- workspace and experiment creation,
- baseline collection,
- WPR trace lifecycle,
- KDNET preparation check,
- evidence hashing and finalization,
- initial smoke validation,
- public/private evidence boundary.

### NXB-IRL-002 — Deterministic experiment lifecycle

Status: `COMPLETE`

Implemented and validated:

- canonical state machine,
- atomic JSON writes,
- idempotent finalization,
- evidence integrity verification,
- interrupted-experiment recovery,
- explicit failed state,
- path escape checks,
- reparse-point rejection,
- manifest JSON Schema validation,
- public repository artifact policy,
- WPR unavailable/cancel/start/stop/missing-ETL failure paths,
- synthetic successful WPR lifecycle,
- PowerShell 5.1 and PowerShell 7 Pester jobs,
- PSScriptAnalyzer Error/Warning gate,
- UTF-8 BOM compatibility for non-ASCII PowerShell sources.

Final validation:

- static analysis and repository smoke validation: green,
- PowerShell 7 lifecycle suite: green,
- Windows PowerShell 5.1 lifecycle suite: green,
- final all-green run confirmed in the repository owner's Actions view.

Detailed record: `docs/NXB-IRL-002-VALIDATION.md`.

### NXB-IRL-004 preparation already on main

- `docs/FULL_SYSTEM_OBSERVABILITY.md`,
- system capability schema and collector,
- capability baseline integration and tests,
- normalized observability event schema,
- machine/boot/monotonic-clock identity schema,
- observation identity collector and tests,
- full-system issue `#2`.

## NXB-IRL-003 implemented on draft PR #5

### Contracts and schemas

- version-1 evidence-store design contract,
- evidence record Draft 2020-12 schema,
- chain-head Draft 2020-12 schema,
- bundle-manifest Draft 2020-12 schema,
- record-type-specific tool provenance and clock-offset payload schemas,
- generic schema self-validation wrapper.

### Canonical identity

- ordinal case-sensitive property ordering,
- array-order preservation,
- manual JSON escaping and invalid surrogate rejection,
- integer-only hash-bearing values,
- UTF-8 without BOM hash bytes,
- lowercase SHA-256,
- root-only self-hash property exclusion,
- atomic canonical JSON writer.

### Append-only chain

- exclusive append lock,
- staged schema validation before final append,
- fixed-width 16-digit record filenames,
- payload and record SHA-256,
- exact previous-record linkage,
- experiment/machine/boot/session identity binding,
- deterministic chain-head generation,
- raw digest concatenation chain hash,
- complete chain and chain-head verifier.

### Tool provenance

- local executable path/hash/length/version capture,
- invocation and collector identity,
- redacted argument-envelope digest without raw argument persistence,
- status and optional exit code,
- independent executable hash/length verifier.

### Clock-offset evidence

- four-timestamp midpoint method,
- controller and target elapsed times,
- adjusted round-trip,
- midpoint offset,
- upward-rounded uncertainty,
- invalid timing rejection,
- independent arithmetic verifier.

### Current adversarial tests

- insertion-order equivalence,
- known SHA-256 vector,
- array-order sensitivity,
- floating-point rejection,
- BOM-free canonical output,
- payload tamper,
- record deletion and sequence gap,
- identity substitution with recomputed record hash,
- sensitive argument non-persistence,
- changed tool binary,
- inconsistent re-hashed clock payload,
- invalid clock sample.

## Current validation state

Status: `WINDOWS CI QUEUED`

The branch now uses workflow concurrency with `cancel-in-progress` so superseded PR-head runs do not continue once GitHub applies the updated workflow. Several runs created before that change may still occupy the hosted-runner queue.

Resolve the latest PR head from PR #5. Do not rely on a stale SHA stored here.

Required jobs:

- Static analysis and repository smoke validation,
- Lifecycle — PowerShell 7,
- Lifecycle — Windows PowerShell 5.1.

PR #5 must remain draft until the full NXB-IRL-003 scope and every final job are green.

## Remaining NXB-IRL-003 sequence

1. Inspect and repair the first completed Windows CI run for the current implementation.
2. Implement deterministic offline bundle creation.
3. Implement offline bundle verification.
4. Implement evidence-store/bundle comparison.
5. Add optional detached local signing with explicit unsigned state.
6. Add bundle truncation, path collision, reparse and invalid-signature tests.
7. Integrate evidence-store smoke flow into repository validation.
8. Complete final Windows CI and close issue #4 only after all gates pass.

## Required quality gates for NXB-IRL-003

- deterministic serialization and hashing,
- append-only chain verification,
- one-byte tamper detection,
- record deletion/reordering/substitution detection,
- machine/boot/experiment identity mismatch rejection,
- tool provenance validation,
- clock-offset arithmetic validation,
- offline verification without network access,
- PowerShell 5.1 and PowerShell 7 CI,
- no private evidence or signing key committed to the public repository.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md and docs/NXB-IRL-003-EVIDENCE-STORE.md.
Confirm PR #3 is merged and issue #1 is closed.
Inspect issue #4 and draft PR #5.
Resolve the current PR #5 head and latest Validate run.
Repair the first incomplete Windows CI gate, then continue deterministic offline bundle creation.
Keep issue #2 as the prepared NXB-IRL-004 full-system observability track.
Update HANDOFF.md and the active issue/PR after every completed block.
```
