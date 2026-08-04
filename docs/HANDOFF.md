# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active required issue: `#1 — NXB-IRL-002`
- Prepared observability issue: `#2 — NXB-IRL-004`
- Active closeout branch: `nxb-irl-002-closeout`
- Active draft PR: `#3 — NXB-IRL-002: close deterministic lifecycle validation gaps`

## Current objective

Complete and verify `NXB-IRL-002 — Deterministic experiment lifecycle`.

Do not merge PR #3, close issue #1, or start the next required block as complete until the Windows validation jobs are visible and their logs have been inspected.

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

Required design references:

1. `docs/MASTER_PLAN.md`
2. `docs/FULL_SYSTEM_OBSERVABILITY.md`
3. `docs/ROADMAP.md`
4. issue `#2`

## Completed base work

### NXB-IRL-001

- workspace and experiment creation,
- baseline collection,
- WPR trace lifecycle,
- KDNET preparation check,
- evidence hashing and finalization,
- initial smoke validation,
- public/private evidence boundary.

### NXB-IRL-002 before closeout PR

- canonical state machine,
- atomic JSON writes,
- idempotent finalization,
- evidence integrity verification,
- interrupted-experiment recovery,
- explicit failed state,
- path escape checks,
- manifest JSON Schema validation,
- public repository artifact policy,
- PowerShell 5.1 / PowerShell 7 test matrix,
- PSScriptAnalyzer workflow definition.

### NXB-IRL-004 preparation already on main

- `docs/FULL_SYSTEM_OBSERVABILITY.md`,
- system capability schema and collector,
- capability baseline integration and tests,
- normalized observability event schema,
- machine/boot/monotonic-clock identity schema,
- observation identity collector and tests,
- full-system issue `#2`.

## Draft PR #3 implementation

PR #3 adds the remaining NXB-IRL-002 closeout implementation:

- explicit/injectable WPR executable resolution,
- native WPR exit-code preservation,
- existing-session cancellation failure handling,
- WPR unavailable/start/stop failure tests,
- successful stop without ETL fails closed,
- synthetic successful start/stop lifecycle test,
- trace-session validation before stop,
- manifest and trace-session failure provenance,
- safe stack-based evidence traversal,
- reparse-point rejection before descending,
- junction adversarial test,
- untracked synthetic `.dmp` guard test,
- deterministic public-artifact candidate handling,
- `workflow_dispatch`,
- `docs/NXB-IRL-002-VALIDATION.md`.

Important branch files:

- `scripts/Nxb.Lab.Common.psm1`
- `scripts/Start-PerformanceTrace.ps1`
- `scripts/Stop-PerformanceTrace.ps1`
- `scripts/Test-PublicRepositoryContent.ps1`
- `tests/WprFailurePaths.Tests.ps1`
- `tests/SafetyGuards.Tests.ps1`
- `docs/NXB-IRL-002-VALIDATION.md`
- `.github/workflows/validate.yml`

## Current validation state

Status: `PENDING WINDOWS CI`

What is known:

- PR #3 is open, draft and mergeable.
- Connector queries return no workflow runs for PR head commits.
- Connector combined-status queries return no status checks for the PR head or merge ref.
- The execution environment has no authenticated GitHub CLI.
- The execution environment has no local PowerShell runtime.
- A clean network checkout was unavailable because the execution container could not resolve GitHub.

Therefore no claim is made that PSScriptAnalyzer, Pester or repository smoke validation passed.

## Required next action

1. In GitHub, open **Actions**.
2. Confirm Actions are enabled for the repository.
3. Open the **Validate** workflow.
4. Run it manually with branch `nxb-irl-002-closeout` if no PR run exists.
5. Inspect all jobs and logs:
   - static analysis,
   - repository smoke validation,
   - PowerShell 7 Pester,
   - Windows PowerShell 5.1 Pester.
6. Repair every failure on the same branch.
7. Update `docs/NXB-IRL-002-VALIDATION.md` with exact results and run identifiers.
8. Mark PR #3 ready, merge it, and close issue #1 only after every required job succeeds.

## After NXB-IRL-002

Required sequence:

1. `NXB-IRL-003 — Evidence integrity store`
2. `NXB-IRL-004 — Full-system observability fabric`
3. `NXB-IRL-005 — Controlled kernel test driver`
4. `NXB-IRL-006 — Controller/target transport`
5. `NXB-IRL-007 — Debugger evidence pipeline`
6. static/runtime/semantic analysis pipeline
7. target adapter framework
8. EAC adapter
9. performance/security validation and reporting

## Continuation prompt

Use this in a new chat:

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md and docs/FULL_SYSTEM_OBSERVABILITY.md.
Inspect issues #1 and #2 and draft PR #3.
Check the latest PR head and GitHub Actions state.
Continue from the first unverified NXB-IRL-002 validation gate.
Update HANDOFF.md and the relevant issue/PR after every completed block.
```

## Current branch head

The branch head changes after every repair. Resolve it from PR #3 rather than relying on a stale SHA stored in this document.
