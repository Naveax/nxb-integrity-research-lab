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
- [x] explicit failed-state command,
- [x] interrupted experiment recovery command,
- [x] abandoned atomic temporary-file cleanup,
- [x] canonical evidence ordering test,
- [x] evidence tamper test,
- [x] unsafe relative-path rejection test,
- [x] public repository sensitive-artifact policy and guard,
- [x] Draft 2020-12 lifecycle schema conditions,
- [x] Python JSON Schema validator,
- [x] PowerShell schema wrapper,
- [x] Pester lifecycle/recovery tests,
- [x] PSScriptAnalyzer policy and workflow definition,
- [x] Windows PowerShell 5.1 / PowerShell 7 CI matrix definition,
- [x] Python/jsonschema CI setup,
- [x] strengthened repository smoke validation.

Remaining:

- [ ] confirm and repair GitHub Actions execution,
- [ ] WPR unavailable/start failure/stop failure tests,
- [ ] reparse-point adversarial test on a suitable Windows runner,
- [ ] synthetic blocked-artifact guard test without committing an artifact,
- [ ] inspect first CI logs and repair every failure,
- [ ] final validation report and issue closure.

## Important implementation files

- `scripts/Nxb.Lab.Common.psm1`
- `scripts/New-Experiment.ps1`
- `scripts/Start-PerformanceTrace.ps1`
- `scripts/Stop-PerformanceTrace.ps1`
- `scripts/Finalize-Experiment.ps1`
- `scripts/Test-EvidenceIntegrity.ps1`
- `scripts/Get-ExperimentStatus.ps1`
- `scripts/Set-ExperimentFailed.ps1`
- `scripts/Repair-Experiment.ps1`
- `scripts/Test-ExperimentManifest.ps1`
- `scripts/Test-PublicRepositoryContent.ps1`
- `scripts/Test-Repository.ps1`
- `schemas/experiment.schema.json`
- `tools/validate_manifest.py`
- `tests/ExperimentLifecycle.Tests.ps1`
- `.github/PSScriptAnalyzerSettings.psd1`
- `.github/workflows/validate.yml`

## Current CI state

Workflow definition exists and now includes:

- public repository content guard,
- PSScriptAnalyzer,
- Python 3.13 + `jsonschema`,
- repository smoke validation,
- PowerShell 7 Pester tests,
- Windows PowerShell 5.1 Pester tests.

GitHub connector still returns no commit statuses for the latest commit `ace14ca7679339a7a27d34c598f9c71cc874dcb9`. Do not claim CI success until a workflow run and its jobs are visible. The first next action is to verify whether Actions is enabled and inspect the first run/logs.

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

## Latest implementation commits

- recovery failed-state command: `29ebfca69d300cb01f3073c6b78c02b9f7d6ff6f`
- recovery controller: `e2499e1cba65d0279b034944cd53d5ca22972dc4`
- public artifact policy: `7d46917ec92a33d6c7901f40b8ac8ce00833e7d8`
- public artifact guard: `22b4ca3ea0652ee12ee70461b784d4884904c153`
- analyzer-compliant module: `db8895206e3a4be835fecfb64f2a45cffb6aad2a`
- recovery and guard tests: `432afd167ae9cfc0e85bbfbac61ece8c25585a49`
- lifecycle schema: `68147a1a31417487899aaf8bb83725ce776bef74`
- Python schema validator: `087e61b8a5565da1c27b37633f367bb882db32ce`
- PowerShell schema wrapper: `13e51e8c0d3228d367fbdeb83ff4567122877178`
- schema-aware smoke validation: `b4404ad066d32e803630d16b1ad1910996c47500`
- CI Python/schema setup: `ace14ca7679339a7a27d34c598f9c71cc874dcb9`
