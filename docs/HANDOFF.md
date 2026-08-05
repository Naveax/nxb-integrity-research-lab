# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active issue: `#2 — NXB-IRL-004 — Full-system observability fabric`
- Merged PR: `#6 — NXB-IRL-004: minimal CPU and scheduler capture profile`
- Active draft PR: `#7 — NXB-IRL-004: paired collector overhead calibration`
- Active branch: `nxb-irl-004-overhead-calibration`

## Current objective

The paired collector-overhead implementation is complete. The remaining work is exact-head Windows validation, evidence inspection, PR closeout and merge.

Current validation candidate before this handoff update:

```text
f785cc38a53f7ffaf234d3a9b431a9903e8619d4
```

Because this handoff update creates a new commit, resolve the current PR head again before running validation.

## Completed NXB-IRL-004 blocks

### Minimal CPU and scheduler profile

Status: `MERGED`

- repository-owned WPRP,
- native WPR parser compatibility,
- bounded 512 MiB circular file collector,
- matching memory-mode variant,
- deterministic profile provenance,
- teardown-first stop behavior,
- ETL metadata and profile integrity binding,
- adversarial path/XML/profile mutation coverage.

PR: `#6`

Squash merge:

```text
04214ac4e27a1b35e4327392480c2f89e9caaddc
```

### Paired collector overhead calibration

Status: `IMPLEMENTATION COMPLETE — EXACT-HEAD WINDOWS VALIDATION PENDING`

Implemented artifacts:

- `schemas/collector-overhead-calibration.schema.json`
- `scripts/Get-NxbActivePowerPolicy.ps1`
- `scripts/Invoke-NxbMeasuredWorkload.ps1`
- `scripts/Invoke-CollectorOverheadCalibration.ps1`
- `scripts/Test-CollectorOverheadCalibration.ps1`
- `scripts/Invoke-NxbLocalValidation.ps1`
- `tools/Invoke-NxbCpuWorkload.ps1`
- `tools/validate_overhead_calibration.py`
- `tests/CollectorOverheadCalibration.Tests.ps1`
- `tests/CollectorOverheadRunner.Tests.ps1`
- `tests/CpuWorkload.Tests.ps1`
- `tests/MeasuredWorkload.Tests.ps1`
- `docs/NXB-IRL-004-OVERHEAD-CALIBRATION.md`
- `docs/NXB-IRL-004-VALIDATION.md`

Implemented properties:

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
- mandatory `threshold_policy.status: not_declared`.

## Exact-head local validation

GitHub Actions are intentionally disabled repository-wide. Do not add a workflow to validate PR `#7`.

Canonical runner:

```text
scripts/Invoke-NxbLocalValidation.ps1
```

Canonical pending record:

```text
docs/NXB-IRL-004-VALIDATION.md
```

The runner requires:

- real Windows,
- elevated PowerShell 7,
- clean working tree,
- exact expected Git head,
- PowerShell 7 and Windows PowerShell 5.1,
- Pester 5 in both hosts,
- PSScriptAnalyzer,
- Python `jsonschema`,
- `wpr.exe`.

Run from the PR branch after resolving the latest head:

```powershell
git fetch origin
git switch nxb-irl-004-overhead-calibration
git pull --ff-only origin nxb-irl-004-overhead-calibration

git status --short
$head = (git rev-parse HEAD).Trim()

./scripts/Invoke-NxbLocalValidation.ps1 `
    -ExpectedHead $head `
    -BootstrapDependencies `
    -RepetitionCount 3 `
    -WarmupCount 1 `
    -Ordering alternating_control_first `
    -Iterations 1000 `
    -Seed 73 `
    -Confirm:$false
```

The required terminal summary is:

```json
{
  "status": "passed"
}
```

Required gates:

1. public repository content guard,
2. native WPR profile parsing,
3. zero PSScriptAnalyzer Error/Warning findings,
4. repository smoke validation,
5. complete PowerShell 7 Pester matrix,
6. complete Windows PowerShell 5.1 Pester matrix,
7. native paired WPR calibration.

A skipped native calibration is not accepted.

## Validation handling

When the local runner finishes:

1. preserve the complete `%TEMP%\nxb-validation-*` directory,
2. inspect `validation-summary.json`,
3. inspect every gate log,
4. inspect both Pester XML files,
5. inspect native parent/child experiment evidence,
6. fix any verified failures,
7. rerun all gates against the new exact head,
8. only after full success update PR `#7` and issue `#2`,
9. mark PR ready,
10. squash merge using expected-head locking.

Do not edit the validation record to claim success before the evidence is available.

## Still outside this PR

- trace-loss accounting,
- circular-overwrite quantification,
- capture-completeness classification,
- representative production overhead thresholds,
- RAM, storage, GPU and network capture profiles,
- cross-domain correlation engine.

Issue `#2` remains open after PR `#7` because these broader NXB-IRL-004 blocks remain incomplete.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens or undisclosed findings.

Local validation evidence remains outside the repository until it has been reduced to safe metadata. Do not commit the native calibration lab directory or raw ETL files.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab PR #7.
Read docs/HANDOFF.md, docs/NXB-IRL-004-OVERHEAD-CALIBRATION.md and docs/NXB-IRL-004-VALIDATION.md.
Resolve the current exact PR head.
Run scripts/Invoke-NxbLocalValidation.ps1 from an elevated PowerShell 7 shell on real Windows with all required gates enabled.
Inspect validation-summary.json, all gate logs, both Pester XML files and the native parent/child calibration evidence.
Fix only verified failures, rerun every gate on the new exact head, then update PR #7 and issue #2 with safe exact-head evidence.
Do not enable GitHub Actions and do not merge until all required gates pass.
```
