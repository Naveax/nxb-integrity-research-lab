# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlı ve kanonik biçimde bulmak için kullanılır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Active umbrella issue: `#2 — NXB-IRL-004 — Full-system observability fabric`
- Active draft PR: `#7 — NXB-IRL-004: paired collector overhead calibration`
- Active branch: `nxb-irl-004-overhead-calibration`
- GitHub Actions: intentionally disabled repository-wide

## Current objective

Complete PR #7 validation and closeout for deterministic paired control/capture overhead calibration of the bounded CPU/scheduler WPR profile.

The implementation is present. No acceptable overhead threshold and no native-WPR performance result are claimed yet.

## Completed milestones

### NXB-IRL-001 — Repository bootstrap

Status: `COMPLETE`

- workspace and experiment creation,
- baseline collection,
- WPR lifecycle,
- KDNET preparation checks,
- evidence hashing and finalization,
- public/private evidence boundary.

### NXB-IRL-002 — Deterministic experiment lifecycle

Status: `COMPLETE`

Squash merge:

```text
e3b3ab79ab72cafa92f2afa97895258cec912d86
```

### NXB-IRL-003 — Evidence integrity store

Status: `COMPLETE`

Merged PR: `#5`

Squash merge:

```text
d913c037aabb39aa13cd41e59716a17c8a04bc68
```

Completed scope includes canonical JSON, append-only evidence records, chain verification, deterministic offline bundles, provenance and clock evidence, detached RSA signing and adversarial substitution/tamper coverage.

Canonical references:

```text
docs/NXB-IRL-003-EVIDENCE-STORE.md
docs/NXB-IRL-003-VALIDATION.md
```

### NXB-IRL-004 block 1 — Minimal CPU/scheduler WPR profile

Status: `COMPLETE`

Merged PR: `#6`

Squash merge:

```text
04214ac4e27a1b35e4327392480c2f89e9caaddc
```

Implemented:

- repository-owned native-parser-valid WPRP,
- separate File and Memory collectors,
- 512 MiB circular file bound,
- exact CPU/scheduler keywords and stack walks,
- explicit legacy `GeneralProfile` opt-in,
- profile SHA-256/length/bounds provenance,
- canonical provenance seal,
- teardown-first stop,
- ETL metadata binding,
- fail-closed profile/session mutation handling.

Canonical reference:

```text
docs/NXB-IRL-004-CPU-SCHEDULER-PROFILE.md
```

## Active PR #7 implementation

### Evidence contract

```text
schemas/collector-overhead-calibration.schema.json
scripts/Test-CollectorOverheadCalibration.ps1
tools/validate_overhead_calibration.py
tests/fixtures/collector-overhead-calibration.valid.json
```

The contract enforces:

- explicit `measured`, `unsupported`, `failed` states,
- parent and child lifecycle experiment paths,
- unique arm experiment IDs,
- machine and boot identity binding,
- canonical power-policy and workload fingerprints,
- deterministic arm ordering,
- exact delta and distribution math,
- ETL effective byte-rate math,
- mandatory `not_declared` threshold policy.

### Controlled workload and sampler

```text
tools/Invoke-NxbCpuWorkload.ps1
scripts/Invoke-NxbMeasuredWorkload.ps1
```

Implemented:

- deterministic SHA-256 CPU workload,
- bounded iteration, seed and timeout values,
- atomic result file,
- overwrite refusal,
- child PowerShell process execution,
- wall-clock duration,
- exit code and timeout evidence,
- CPU-time sampling,
- peak working-set and private-bytes sampling,
- bounded process teardown,
- stdout/stderr and runner provenance.

### Paired runner

```text
scripts/Get-NxbActivePowerPolicy.ps1
scripts/Invoke-CollectorOverheadCalibration.ps1
```

Implemented:

- prepared parent experiment,
- separate warmup/control/capture child experiments,
- same-machine and same-boot checks,
- power-policy verification before and after every arm,
- deterministic arm ordering,
- bounded warmups, pairs and cooldown,
- WPR start/stop latency,
- workload measurement under capture,
- ETL hash/length/rate/provenance evidence,
- explicit WPR cancel after stop failure,
- failed child transition,
- preserved schema-valid failed-pair evidence,
- parent finalization followed by nonzero command outcome for partial calibration.

### Tests

```text
tests/CollectorOverheadCalibration.Tests.ps1
tests/CpuWorkload.Tests.ps1
tests/MeasuredWorkload.Tests.ps1
tests/CollectorOverheadRunner.Tests.ps1
```

The matrix covers schema mutation, identity/path substitution, ordering, delta/statistics tamper, threshold injection, workload failure/timeout/path safety, successful fake-WPR lifecycle and WPR stop failure with explicit cancel.

### Documentation

```text
docs/NXB-IRL-004-OVERHEAD-CALIBRATION.md
docs/NXB-IRL-004-CPU-SCHEDULER-PROFILE.md
```

## Validation boundary

GitHub Actions are intentionally disabled. Do not add workflow files to PR #7 and do not claim hosted CI validation.

Required manual validation from repository root on Windows:

### PowerShell 7

```powershell
python -m pip install --disable-pip-version-check jsonschema
Import-Module Pester -MinimumVersion 5.5.0 -Force
Invoke-Pester -Path ./tests -CI
```

### Windows PowerShell 5.1

```powershell
python -m pip install --disable-pip-version-check jsonschema
Import-Module Pester -MinimumVersion 5.5.0 -Force
Invoke-Pester -Path ./tests -CI
```

### Static analysis and smoke

```powershell
Import-Module PSScriptAnalyzer -Force
$results = @(
  Get-ChildItem ./scripts, ./tests, ./tools -Recurse -File |
    Where-Object Extension -In '.ps1', '.psm1' |
    ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName }
)
$results | Format-Table -AutoSize
if ($results.Count -gt 0) { throw "PSScriptAnalyzer reported $($results.Count) issue(s)." }

./scripts/Test-Repository.ps1
```

### Controlled native-WPR calibration

1. Create one prepared parent experiment.
2. Run one warmup and at least three alternating pairs with the repository WPR profile.
3. Preserve console output and generated calibration JSON outside the public repository when it contains machine-specific evidence.
4. Run `Test-CollectorOverheadCalibration.ps1` against the generated JSON.
5. Record exact PowerShell, Python, Pester, PSScriptAnalyzer, WPR and OS versions.

Example:

```powershell
$parent = ./scripts/New-Experiment.ps1 `
  -Root <lab-root> `
  -Name 'Overhead-Calibration' `
  -Hypothesis 'Bounded WPR overhead is measured with paired trials'

./scripts/Invoke-CollectorOverheadCalibration.ps1 `
  -ExperimentPath $parent `
  -WarmupCount 1 `
  -RepetitionCount 3 `
  -Ordering alternating_control_first `
  -Iterations 1000 `
  -Confirm:$false
```

## PR #7 closeout sequence

1. Resolve exact current PR head.
2. Run full Pester under PowerShell 7.
3. Run full Pester under Windows PowerShell 5.1.
4. Run PSScriptAnalyzer and require zero findings.
5. Run repository smoke and inspect all output.
6. Perform one controlled native-WPR calibration.
7. Add a validation document with exact commands, versions, results and evidence boundary.
8. Update PR #7 and issue #2 with exact validation evidence.
9. Mark PR #7 ready.
10. Squash merge using expected-head locking.
11. Continue issue #2 with trace-loss accounting.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens, undisclosed findings or machine-specific sensitive evidence.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/NXB-IRL-004-OVERHEAD-CALIBRATION.md and draft PR #7.
Resolve the exact PR head and changed-file set.
Do not enable GitHub Actions.
Run or inspect manual PowerShell 7, Windows PowerShell 5.1, PSScriptAnalyzer and repository-smoke validation.
Fix every exact failure without weakening the schema, lifecycle, path-safety, identity or fail-closed contracts.
Then perform one controlled native-WPR calibration, write exact validation evidence, update PR #7 and issue #2, mark ready and squash merge with expected-head locking.
```
