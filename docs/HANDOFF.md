# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için tutulur.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public

## Current objective

`NXB-IRL-002 — Deterministic experiment lifecycle`

Mevcut deney altyapısını deterministik, idempotent, atomik ve doğrulanabilir hâle getirmek.

## Completed

### NXB-IRL-001

- workspace initialization,
- experiment manifest creation,
- system/binary baseline collection,
- WPR start/stop,
- KDNET preparation check,
- evidence SHA-256 finalization,
- initial repository smoke test,
- public/private evidence boundary documentation.

### Planning documentation

- `docs/MASTER_PLAN.md` kanonik uçtan uca plan,
- `docs/CPU_GPU_OBSERVABILITY.md` CPU/GPU gözlem hattı,
- `docs/ARCHITECTURE.md` mevcut mimari,
- `docs/ROADMAP.md` blok özeti.

## In progress

### NXB-IRL-002 tasks

- [ ] canonical experiment state machine,
- [ ] atomic manifest writer,
- [ ] idempotent finalization,
- [ ] evidence integrity verifier,
- [ ] experiment status command,
- [ ] interrupted experiment recovery,
- [ ] Pester tests,
- [ ] PSScriptAnalyzer CI,
- [ ] JSON Schema validation,
- [ ] Windows PowerShell 5.1 / PowerShell 7 test matrix,
- [ ] path traversal and reparse-point protection,
- [ ] sensitive artifact commit guard.

## Next implementation order

1. `scripts/Test-EvidenceIntegrity.ps1`
2. `scripts/Get-ExperimentStatus.ps1`
3. shared manifest state module
4. update existing lifecycle scripts to use atomic writes
5. Pester lifecycle tests
6. update GitHub Actions workflow
7. recovery tooling
8. sensitive artifact guard

## CPU/GPU track decision

User requested a structure behaving between applications and CPU/GPU to collect decrypted/runtime outputs.

Accepted engineering direction:

- ETW/WPR and hardware-supported execution trace,
- DXGKRNL/GPUView and compatible PIX evidence,
- controlled emulator/hypervisor tracing for project-owned fixtures,
- runtime address to module/RVA/static-function correlation,
- explicit overhead calibration.

Not a project goal:

- guaranteed invisibility,
- anti-debug or anti-VM bypass,
- impersonating hardware to evade a protected target,
- disabling or weakening integrity controls.

## Continuation protocol

In a new chat, ask the assistant to:

1. inspect this file,
2. inspect `docs/MASTER_PLAN.md`,
3. inspect the latest commits and CI state,
4. continue the first unchecked task under `NXB-IRL-002`,
5. update this file after each completed block.

## Latest planning commits

- canonical master plan: `09c9f681ee850f08ac54b8ac1ed4d7f015bd5891`
- CPU/GPU observability track: `fff42dd6c9597274df2ff087b4c8749cd9a25098`

The commit for this handoff file is intentionally recorded in the next update after creation.
