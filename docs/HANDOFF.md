# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için tutulur.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active issue: `#1 — NXB-IRL-002`

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

## NXB-IRL-002 progress

Completed:

- [x] canonical experiment state transition helper,
- [x] PowerShell 5.1-compatible relative-path helper,
- [x] atomic JSON writer,
- [x] reparse-point rejection helper,
- [x] atomic manifest creation,
- [x] guarded WPR start/stop state transitions,
- [x] atomic and idempotent finalization,
- [x] evidence integrity verifier,
- [x] experiment status command,
- [x] Pester lifecycle tests,
- [x] PSScriptAnalyzer workflow definition,
- [x] Windows PowerShell 5.1 / PowerShell 7 CI matrix definition,
- [x] strengthened repository smoke test.

Remaining:

- [ ] confirm and repair GitHub Actions execution,
- [ ] real JSON Schema validation,
- [ ] interrupted experiment recovery,
- [ ] explicit failed-state writer,
- [ ] path traversal and reparse-point adversarial tests,
- [ ] sensitive artifact commit guard,
- [ ] WPR unavailable/failure-path tests,
- [ ] canonical evidence ordering tests,
- [ ] lifecycle schema update,
- [ ] final validation report and issue closure.

## Important implementation files

- `scripts/Nxb.Lab.Common.psm1`
- `scripts/New-Experiment.ps1`
- `scripts/Start-PerformanceTrace.ps1`
- `scripts/Stop-PerformanceTrace.ps1`
- `scripts/Finalize-Experiment.ps1`
- `scripts/Test-EvidenceIntegrity.ps1`
- `scripts/Get-ExperimentStatus.ps1`
- `scripts/Test-Repository.ps1`
- `tests/ExperimentLifecycle.Tests.ps1`
- `.github/workflows/validate.yml`

## Current CI state

Workflow definition exists, but GitHub connector returned no commit statuses after the latest pushes. Do not claim CI success until a run and its jobs are visible. First next action is to verify whether Actions is enabled and inspect the first run/logs.

## CPU/GPU track decision

User requested a structure behaving between applications and CPU/GPU to collect runtime outputs.

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
3. inspect issue `#1`, latest commits and CI state,
4. continue the first unchecked task under `NXB-IRL-002`,
5. update this file after each completed block.

## Relevant commits

Planning:

- master plan: `09c9f681ee850f08ac54b8ac1ed4d7f015bd5891`
- CPU/GPU observability: `fff42dd6c9597274df2ff087b4c8749cd9a25098`
- initial handoff: `a68ca097dfbd60cef4cfedd55190ee9fec3b7d3b`

Lifecycle implementation:

- common lifecycle module: `ea7b97d9bb88e15a32391772f7144268d12a7b6b`
- evidence verifier: `afdc5fe0dd8633ccf7d6829246797649baf6f30b`
- status command: `4f768127679b35f86ca6cccf050d9afb2c43def9`
- idempotent finalizer: `5fa2d5eeaf0f8774e87d38cd2659fe8e22b79cba`
- atomic experiment creation: `124e16760b9cb9f19dbc94c815c1ff48b7a1e0c1`
- guarded trace start: `52e704a93baa7911fa6aa638618315f0f63e4c27`
- guarded trace stop: `792a47e9cba8a13fc55e50383a42aff0d2fd3a3a`
- lifecycle tests: `248bcd0359bbdd1d635e88e6081a66047da2a14c`
- CI matrix: `efdf0b6b3c3be68da72884572b4d829b1ac02154`
- smoke validation: `630f1b00bf77afd15a99bc73dde30cd8cc97728c`
