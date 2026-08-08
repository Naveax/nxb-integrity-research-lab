# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active issue: `#2 — NXB-IRL-004 — Full-system observability fabric`
- Latest merged PR: `#7 — NXB-IRL-004: paired collector overhead calibration`
- Active draft PR: `#8 — NXB-IRL-004: trace-loss and circular-overwrite accounting`
- PR `#8` validated implementation head: `e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258`

GitHub Actions are intentionally disabled repository-wide and must remain disabled.

## Completed NXB-IRL-004 blocks

### Minimal CPU and scheduler profile

- PR: `#6`
- Squash merge: `04214ac4e27a1b35e4327392480c2f89e9caaddc`
- Status: `MERGED`

Completed properties:

- repository-owned minimal CPU/scheduler WPR profile,
- bounded 512 MiB file-mode collector,
- explicit opt-in for legacy unbounded `GeneralProfile`,
- profile provenance and integrity binding,
- teardown-first stop lifecycle,
- adversarial profile/path/reparse coverage,
- PowerShell 7 and Windows PowerShell 5.1 support.

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
- schema-valid failed-pair preservation.

### Trace-loss and circular-overwrite accounting

- PR: `#8`
- Branch: `nxb-irl-004-trace-loss-accounting`
- Validated implementation head: `e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258`
- Status: `IMPLEMENTATION COMPLETE — EXACT-HEAD WINDOWS VALIDATION PASSED — DOCUMENTATION CLOSEOUT`
- Validation record: `docs/NXB-IRL-004-TRACE-LOSS-VALIDATION.md`

Required validation results:

- public repository guard: passed — 108 candidates,
- native WPR profile parser: passed,
- PSScriptAnalyzer: 0 Error/Warning findings,
- repository smoke: passed,
- PowerShell 7 Pester: 136 passed, 0 failed,
- Windows PowerShell 5.1 Pester: 136 passed, 0 failed,
- native paired WPR regression calibration: 1/1 pair,
- base exact-head validation: passed,
- native trace-loss accounting: passed,
- evidence integrity and finalization: passed.

Validated native accounting result:

```text
trace_loss_classification:         no_native_loss_reported
measured_counter_count:            2
total_reported_loss:               0
circular_overwrite_classification: no_risk_observed
circular_utilization_ratio:        0.162109375
evidence_completeness:             complete
post_stop_counter_source:          etl_header_snapshot
xperf_available:                   false
```

Completed properties:

- strict Draft 2020-12 trace-loss evidence schema,
- cross-field semantic validation and Python companion validator,
- pre-stop native WPR status snapshot,
- post-stop `Events Lost`, `Buffers Lost` and `Buffers Written` accounting,
- native `OpenTraceW` / `TRACE_LOGFILE_HEADER` ETL reader,
- xperf-independent measured fallback,
- hash-bound native counter provenance,
- actual ETL SHA-256 and byte-length reconciliation,
- file-mode `realtime_buffers_lost: not_applicable`,
- separate trace-loss and circular-overwrite classifications,
- fixed circular-capacity risk threshold,
- short WPR stop staging followed by canonical ETL placement,
- fail-closed lifecycle when a successful stop produces no ETL,
- safe exact-head local Windows validation runner,
- complete PowerShell 7 and Windows PowerShell 5.1 adversarial coverage.

The validated classifications remain deliberately narrow. They do not claim general trace-loss absence, circular-overwrite absence or capture completeness.

## Current closeout boundary

PR `#8` remains open and draft. Merge or ready-for-review transition has not been performed.

The authoritative runtime/schema/test head is:

```text
e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258
```

Commits after that head must remain documentation-only. Before merge, compare the final PR head against the validated implementation head and verify that only closeout documentation changed.

Issue `#2` remains open because the broader full-system observability fabric is not complete.

## Next required block

Start with:

```text
RAM/page-fault/working-set capture profile
```

Required scope:

- define bounded RAM, working-set, commit and page-fault evidence contracts,
- identify native ETW/WPR providers and events available on supported Windows versions,
- separate process working-set evidence from system memory-pressure evidence,
- represent hard faults, soft faults, page reads, standby-list effects and commit pressure without inventing unsupported values,
- bind all measurements to experiment, machine, boot, profile, tool and ETL provenance,
- add deterministic memory-pressure fixtures that remain safe and bounded,
- measure collector overhead and trace-loss state using the existing NXB-IRL-004 mechanisms,
- add schema, semantic validation, adversarial tests and exact-head Windows validation,
- preserve the public repository boundary.

## Remaining NXB-IRL-004 work

- RAM/page-fault/working-set profile,
- expanded capture-completeness classification across future provider sets,
- disk/file-system/storage queue profile,
- GPU/DXGKRNL/present profile,
- network/NDIS/connection profile,
- device/driver/PCIe provider inventory,
- power/frequency/thermal snapshot,
- firmware/VBS/HVCI/Secure Boot experiment binding,
- cross-domain correlation engine,
- controlled memory, storage, GPU and network fixtures,
- representative production overhead thresholds.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens or undisclosed findings.

## Continuation prompt

```text
Continue Naveax/nxb-integrity-research-lab from draft PR #8.
Validated implementation head: e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258.
Read issue #2, docs/HANDOFF.md, docs/NXB-IRL-004-TRACE-LOSS-ACCOUNTING.md and docs/NXB-IRL-004-TRACE-LOSS-VALIDATION.md.
Verify the final PR #8 head differs from the validated implementation head only by closeout documentation.
Do not merge or mark ready without explicit instruction.
After PR #8 closeout, start the RAM/page-fault/working-set profile block from updated main on a new branch and draft PR.
Keep GitHub Actions disabled and preserve the public repository boundary.
```
