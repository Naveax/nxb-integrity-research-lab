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
- [x] baseline capability integration,
- [x] `scripts/Test-SystemCapabilities.ps1`,
- [x] repository smoke capability validation,
- [x] `tests/SystemCapabilities.Tests.ps1`,
- [x] `schemas/observability-event.schema.json`,
- [x] `schemas/observation-identity.schema.json`,
- [x] `scripts/Get-ObservationIdentity.ps1`,
- [x] `scripts/Test-ObservationIdentity.ps1`,
- [x] baseline machine/boot/clock identity integration,
- [x] repository smoke identity validation,
- [x] `tests/ObservationIdentity.Tests.ps1`,
- [x] issue `#2` tracking record,
- [x] canonical master plan and roadmap expansion.

Next NXB-IRL-004 tasks after prerequisite blocks:

1. minimal CPU/scheduler profile,
2. RAM/page-fault/working-set profile,
3. disk/file-system/storage queue profile,
4. GPU/DXGKRNL/present profile,
5. network/NDIS/connection profile,
6. device/driver/PCIe provider inventory,
7. power/frequency/thermal snapshot,
8. firmware/security experiment binding,
9. trace-loss and collector-overhead accounting,
10. cross-domain correlation engine,
11. controlled CPU/RAM/disk/GPU/network fixtures.

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

### Full-system inventory and identity

- `docs/FULL_SYSTEM_OBSERVABILITY.md`
- `scripts/Get-SystemCapabilities.ps1`
- `scripts/Test-SystemCapabilities.ps1`
- `scripts/Get-ObservationIdentity.ps1`
- `scripts/Test-ObservationIdentity.ps1`
- `schemas/system-capabilities.schema.json`
- `schemas/observation-identity.schema.json`
- `schemas/observability-event.schema.json`
- `tests/SystemCapabilities.Tests.ps1`
- `tests/ObservationIdentity.Tests.ps1`
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

A clean checkout from the execution container could not be performed because that container had no DNS resolution to GitHub. This is not a source or test failure, but it means no independent local checkout validation was completed in that environment.

The capability, event and identity contracts must be validated by the first visible Windows Actions run before being marked fully verified.

## Canonical event identity

Every future event must carry:

```text
experiment_id
machine_id
boot_id
event_id
timestamp_utc
timestamp_monotonic_ns
domain
source
event_type
collector version
overhead profile
```

Schema: `schemas/observability-event.schema.json`.

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
- capability baseline integration: `fc9a8de1ad88a308d3a01ad2e4575d5e2c55a20b`
- capability validator: `2ff6f2ce6f66217e77c22fbb9e002b3b700eb026`
- capability smoke integration: `04c8ecec9410a8acfec695dbac8f7da1eed48db1`
- capability tests: `ff4d9d3321b1cf6d324813bb93466d3260c5dc4c`
- master plan expansion: `34846ca3c685aefa6cf313f3fe250c39ad99f94e`
- observability event schema: `47a0d84f8bc100b40df7057f1fa3a80954febdc3`
- observation identity schema: `f4c7c8dfc181f3e63a01c82587cd54543d5d28b8`
- observation identity collector: `d442b057d95eae3be00c8d00af95660c366ecde3`
- observation identity validator: `9bd0a22f15b473bd96b90b1c6664b9fe8804f328`
- baseline identity integration: `20c0d17dd5e66314db4ac182679484a5dde1368e`
- identity-aware smoke validation: `557ca2753f0f3fb245c25e1fd41ddaef67744cfe`
- observation identity tests: `406b9569c6ce700ecb58e0f678952bdb36270cbe`
