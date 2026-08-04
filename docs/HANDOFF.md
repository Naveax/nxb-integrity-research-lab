# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Completed issue: `#1 — NXB-IRL-002`
- Prepared observability issue: `#2 — NXB-IRL-004`
- Merged PR: `#3 — NXB-IRL-002: close deterministic lifecycle validation gaps`
- Validated head: `878710229ad11c5c1b95247e304986ca4e5eda47`
- NXB-IRL-002 squash merge: `e3b3ab79ab72cafa92f2afa97895258cec912d86`

## Current objective

Start `NXB-IRL-003 — Evidence integrity store`.

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
5. issue `#2`

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

## NXB-IRL-003 initial implementation order

1. Define canonical evidence-store schema and immutable record identity.
2. Bind manifest hash, evidence index hash, machine ID, boot ID and experiment ID.
3. Add append-only experiment chain with previous-record hash.
4. Record tool provenance: executable path, version, SHA-256 and invocation metadata.
5. Add controller/target clock-offset evidence and uncertainty.
6. Build deterministic offline evidence bundle manifest.
7. Add independent bundle verification and comparison commands.
8. Add optional local signing without making signing mandatory for verification.
9. Add adversarial tests for truncation, reordering, record substitution, clock mismatch and signature absence/failure.
10. Keep raw ETL, dumps, target binaries, keys and undisclosed findings outside the public repository.

## Required quality gates for NXB-IRL-003

- deterministic serialization and hashing,
- append-only chain verification,
- one-byte tamper detection,
- record deletion/reordering/substitution detection,
- machine/boot/experiment identity mismatch rejection,
- tool provenance validation,
- offline verification without network access,
- PowerShell 5.1 and PowerShell 7 CI,
- no private evidence or signing key committed to the public repository.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md and docs/NXB-IRL-002-VALIDATION.md.
Confirm PR #3 is merged and issue #1 is closed.
Continue NXB-IRL-003 from the first incomplete evidence-store task.
Keep issue #2 as the prepared NXB-IRL-004 full-system observability track.
Update HANDOFF.md and the active issue/PR after every completed block.
```
