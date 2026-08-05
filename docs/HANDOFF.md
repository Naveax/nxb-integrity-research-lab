# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active issue: `#2 — NXB-IRL-004 — Full-system observability fabric`
- Latest merged PR: `#7 — NXB-IRL-004: paired collector overhead calibration`

GitHub Actions are intentionally disabled repository-wide and must remain disabled.

## Completed NXB-IRL-004 blocks

### Minimal CPU and scheduler profile

- PR: `#6`
- Squash merge: `04214ac4e27a1b35e4327392480c2f89e9caaddc`
- Status: `MERGED`

### Paired collector overhead calibration

- PR: `#7`
- Squash merge: `04ac296da24c9e6b755ef6868ba0b82a34bd0f4a`
- Validated implementation head: `76c2d9cbc6d52c7025664bc06a108fa44d3457f4`
- Status: `MERGED AND VALIDATED`
- Validation record: `docs/NXB-IRL-004-VALIDATION.md`

Required validation results:

- public repository guard: passed,
- native WPR profile parser: passed,
- PSScriptAnalyzer: 0 findings,
- repository smoke: passed,
- PowerShell 7 Pester: 98 passed, 0 failed,
- Windows PowerShell 5.1 Pester: 98 passed, 0 failed,
- native WPR calibration: 3/3 successful pairs and 1 warmup,
- threshold policy: `not_declared`.

Completed properties:

- strict calibration evidence schema and semantic validation,
- parent and separate child experiment lifecycle binding,
- same-machine, same-boot, same-power-policy and same-workload enforcement,
- deterministic control/capture ordering,
- process CPU, working-set and private-byte measurements,
- WPR start and stop/finalization latency,
- ETL SHA-256, length, effective byte rate and profile provenance,
- pair deltas and distribution summaries,
- explicit measured, unsupported and failed states,
- teardown-first stop and explicit WPR cancellation,
- schema-valid failed-pair preservation,
- PowerShell 7 and Windows PowerShell 5.1 compatibility.

## Next required block

Start with:

```text
trace-loss and circular-overwrite accounting
```

Required scope:

- define explicit trace-loss evidence states,
- collect native loss/drop counters where available,
- distinguish unsupported, unavailable, failed and measured states,
- bind loss evidence to experiment, machine, boot, profile and ETL provenance,
- quantify circular-buffer overwrite risk without claiming absence when unmeasured,
- add schema, semantic validation, adversarial tests and Windows validation,
- preserve the public repository boundary.

After trace-loss accounting, continue with RAM/page-fault/working-set capture.

Issue `#2` remains open.

## Remaining NXB-IRL-004 work

- trace-loss and circular-overwrite accounting,
- capture-completeness classification,
- RAM/page-fault/working-set profile,
- disk/file-system/storage queue profile,
- GPU/DXGKRNL/present profile,
- network/NDIS/connection profile,
- device/driver/PCIe inventory and event sources,
- power/frequency/thermal snapshot,
- firmware/VBS/HVCI/Secure Boot experiment binding,
- cross-domain correlation engine,
- controlled memory, storage, GPU and network fixtures,
- representative production overhead thresholds.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens or undisclosed findings.

## Continuation prompt

```text
Continue Naveax/nxb-integrity-research-lab from main after PR #7 merge 04ac296da24c9e6b755ef6868ba0b82a34bd0f4a.
Read issue #2, docs/HANDOFF.md and docs/NXB-IRL-004-VALIDATION.md.
Start the trace-loss and circular-overwrite accounting block on a new branch and draft PR.
Keep GitHub Actions disabled and preserve the public repository boundary.
```
