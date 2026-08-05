# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active issue: `#2 — NXB-IRL-004 — Full-system observability fabric`
- Merged PR: `#6 — NXB-IRL-004: minimal CPU and scheduler capture profile`
- Closeout PR: `#7 — NXB-IRL-004: paired collector overhead calibration`
- Branch: `nxb-irl-004-overhead-calibration`

GitHub Actions are intentionally disabled repository-wide and must remain disabled.

## PR #7 validation

Status: `EXACT IMPLEMENTATION HEAD VALIDATED — CLOSEOUT READY`

Validated implementation head:

```text
76c2d9cbc6d52c7025664bc06a108fa44d3457f4
```

Validation record:

```text
docs/NXB-IRL-004-VALIDATION.md
```

Required gate results:

- public repository guard: passed,
- native WPR profile parser: passed,
- PSScriptAnalyzer: 0 findings,
- repository smoke: passed,
- PowerShell 7 Pester: 98 passed, 0 failed,
- Windows PowerShell 5.1 Pester: 98 passed, 0 failed,
- native WPR calibration: 3/3 successful pairs and 1 warmup.

Commits after the validated implementation head are limited to validation and handoff documentation. They do not change runtime, schema, validator, tests, workflows or calibration behavior. The authoritative closeout head is stored in PR metadata and must be checked immediately before merge.

## Completed NXB-IRL-004 blocks

### Minimal CPU and scheduler profile

Status: `MERGED`

PR: `#6`

Squash merge:

```text
04214ac4e27a1b35e4327392480c2f89e9caaddc
```

### Paired collector overhead calibration

Status: `IMPLEMENTED AND VALIDATED`

Completed properties:

- strict JSON Schema 2020-12 evidence contract,
- semantic identity, ordering, delta and distribution verification,
- parent and separate child experiment lifecycle binding,
- same-machine and same-boot enforcement,
- active power-policy verification before and after every arm,
- deterministic workload identity and checksum equivalence,
- independent process CPU, working-set and private-byte observations,
- WPR start and stop latency,
- ETL SHA-256, length, effective byte rate and provenance binding,
- bounded warmups, repetitions, cooldown and ordering,
- explicit measured, unsupported and failed states,
- teardown-first stop and explicit cancellation on failure,
- schema-valid failed-pair preservation,
- mandatory `threshold_policy.status: not_declared`,
- PowerShell 7 and Windows PowerShell 5.1 compatibility.

## Merge boundary

Before merging PR `#7`:

1. read the current PR head from GitHub,
2. compare it with validated implementation head `76c2d9cbc6d52c7025664bc06a108fa44d3457f4`,
3. confirm the later diff contains only documentation,
4. confirm no workflow was restored,
5. mark ready,
6. squash merge with expected-head locking.

Issue `#2` remains open after PR `#7`.

## Still outside PR #7

- trace-loss accounting,
- circular-overwrite quantification,
- capture-completeness classification,
- representative production overhead thresholds,
- RAM, storage, GPU and network capture profiles,
- cross-domain correlation engine.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens or undisclosed findings.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab PR #7 and docs/NXB-IRL-004-VALIDATION.md.
Confirm validated implementation head 76c2d9cbc6d52c7025664bc06a108fa44d3457f4.
Confirm all later commits are documentation-only and no workflow was restored.
Mark PR #7 ready and squash merge with expected-head locking.
Keep issue #2 open and continue with the next NXB-IRL-004 observability block.
```
