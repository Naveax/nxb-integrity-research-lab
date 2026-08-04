# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için tutulur.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active issue: `#1 — NXB-IRL-002`
- Planned observability issue: `#2 — NXB-IRL-004`

## Current objective

`NXB-IRL-002 — Deterministic experiment lifecycle`

Mevcut deney altyapısını deterministik, idempotent, atomik ve doğrulanabilir hâle getirmek. Bu blok kapanmadan gerçek hedef trace hattı ana çalışma bloğu olarak başlatılmaz.

## Expanded project direction

CPU/GPU gözlem hattı artık **full-system observability fabric** olarak genişletildi.

Kapsanan alanlar:

- CPU ve scheduler,
- RAM, virtual memory, page fault ve working set,
- GPU, DXGKRNL, queue ve present,
- disk, storage queue ve file system,
- network ve NDIS,
- PCIe, PnP device ve signed-driver topolojisi,
- kernel/driver/service yaşam döngüsü,
- güç, frekans ve termal durum,
- firmware, Secure Boot, TPM, VBS/HVCI ve boot state.

Kanonik ayrıntı: `docs/FULL_SYSTEM_OBSERVABILITY.md`.

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
- `docs/FULL_SYSTEM_OBSERVABILITY.md` tam sistem gözlem hattı,
- `docs/CPU_GPU_OBSERVABILITY.md` önceki CPU/GPU tasarım notları,
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

## NXB-IRL-004 preparation progress

Initial implementation completed while keeping issue `#1` as the active required block:

- [x] full-system architecture document,
- [x] `schemas/system-capabilities.schema.json`,
- [x] `scripts/Get-SystemCapabilities.ps1`,
- [x] baseline collector integration,
- [x] `scripts/Test-SystemCapabilities.ps1`,
- [x] repository smoke validation integration,
- [x] `tests/SystemCapabilities.Tests.ps1`,
- [x] issue `#2` tracking record.

Next NXB-IRL-004 tasks after prerequisite blocks:

1. normalized cross-domain event schema,
2. machine/boot/clock identity contract,
3. minimal CPU/scheduler profile,
4. RAM/page-fault/working-set profile,
5. disk/file-system/storage queue profile,
6. GPU/DXGKRNL/present profile,
7. network/NDIS/connection profile,
8. device/driver/PCIe provider inventory,
9. power/frequency/thermal snapshot,
10. trace-loss and collector-overhead accounting,
11. cross-domain correlation engine,
12. controlled CPU/RAM/disk/GPU/network fixtures.

## Important implementation files

### Lifecycle and evidence

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

### Full-system inventory

- `docs/FULL_SYSTEM_OBSERVABILITY.md`
- `scripts/Get-SystemCapabilities.ps1`
- `scripts/Test-SystemCapabilities.ps1`
- `schemas/system-capabilities.schema.json`
- `tests/SystemCapabilities.Tests.ps1`
- `scripts/Capture-Baseline.ps1`

### CI

- `.github/PSScriptAnalyzerSettings.psd1`
- `.github/workflows/validate.yml`

## Current CI state

Workflow definition includes:

- public repository content guard,
- PSScriptAnalyzer,
- Python 3.13 + `jsonschema`,
- repository smoke validation,
- PowerShell 7 Pester tests,
- Windows PowerShell 5.1 Pester tests.

GitHub connector has not yet returned a visible successful workflow status. Do not claim CI success until a workflow run and its jobs are inspected.

The new capability collector and tests were committed, but they must be validated by the first visible Windows Actions run before being marked fully verified.

## Full-system correlation target

```text
experiment
 -> machine/boot/target hash
 -> process/thread/device
 -> CPU/RAM/GPU/disk/network events
 -> common timeline
 -> module/RVA/static function
 -> root-cause hypothesis
 -> controlled validation
```

Example performance chain:

```text
thread wake-up
 -> hard page fault
 -> disk read queue
 -> RAM page-in
 -> CPU scheduling delay
 -> late GPU submission
 -> queue bubble
 -> delayed present
```

## Safety and engineering boundary

Accepted engineering direction:

- ETW/WPR and supported hardware trace,
- RAM/page-fault/working-set correlation,
- DXGKRNL/GPUView and compatible PIX evidence,
- storage/file-system/network/device event correlation,
- controlled emulator/hypervisor or synthetic devices for project-owned fixtures,
- runtime address to module/RVA/static-function correlation,
- explicit overhead and trace-loss accounting.

Not a project goal:

- guaranteed invisibility,
- anti-debug or anti-VM bypass,
- impersonating hardware to evade a protected target,
- disabling or weakening integrity controls.

## Continuation protocol

In a new chat, ask the assistant to:

1. inspect this file,
2. inspect `docs/MASTER_PLAN.md`,
3. inspect `docs/FULL_SYSTEM_OBSERVABILITY.md`,
4. inspect issues `#1` and `#2`, latest commits and CI state,
5. continue the first unchecked task under active issue `#1`,
6. update this file after each completed block.

## Latest full-system commits

- architecture: `c0c500e8c47f132e94fcebe1d0efe667828d4aa8`
- capability schema: `f6f82bfdbdf50f6220754b85f48c88824939725f`
- capability collector: `ca43ef695470bbe6216197227619f21287c0f77c`
- baseline integration: `fc9a8de1ad88a308d3a01ad2e4575d5e2c55a20b`
- capability validator: `2ff6f2ce6f66217e77c22fbb9e002b3b700eb026`
- repository smoke integration: `04c8ecec9410a8acfec695dbac8f7da1eed48db1`
- capability Pester tests: `ff4d9d3321b1cf6d324813bb93466d3260c5dc4c`
- roadmap update: `d2ae5aafb0751a21dff84c08c14dc40e8d21a7f9`
