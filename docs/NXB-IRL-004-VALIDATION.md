# NXB-IRL-004 — Paired Collector Overhead Validation Record

## Status

`PENDING — LOCAL WINDOWS VALIDATION REQUIRED`

Tracking issue: `#2`

Draft pull request: `#7`

Active branch:

```text
nxb-irl-004-overhead-calibration
```

GitHub Actions are intentionally disabled repository-wide. Validation for this block is therefore performed on a real Windows installation by the repository-owned exact-head runner:

```text
scripts/Invoke-NxbLocalValidation.ps1
```

No gate in this document is considered passed until the generated validation summary, complete logs, Pester XML files and native calibration evidence have been inspected.

## Required environment

- Windows 10 or Windows 11
- elevated administrator PowerShell 7 shell
- Git
- PowerShell 7
- Windows PowerShell 5.1
- Python with `jsonschema`
- Pester 5 available to both PowerShell hosts
- PSScriptAnalyzer available to PowerShell 7
- Windows Performance Recorder (`wpr.exe`)

The runner may install missing user-scoped PowerShell modules and Python `jsonschema` only when `-BootstrapDependencies` is explicitly supplied.

## Exact-head execution

From a clean checkout of the PR branch:

```powershell
git fetch origin
git switch nxb-irl-004-overhead-calibration
git pull --ff-only origin nxb-irl-004-overhead-calibration

git status --short

git rev-parse HEAD
```

Then, from an elevated PowerShell 7 window:

```powershell
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

The runner refuses to start when:

- the current platform is not Windows,
- the working tree contains tracked or untracked changes,
- `-ExpectedHead` does not match `git rev-parse HEAD`,
- required executables cannot be resolved,
- required modules or Python packages remain unavailable,
- native calibration is requested without administrator elevation.

Results are written outside the repository under `%TEMP%` unless an explicit external `-ResultsRoot` is supplied.

## Required gates

| Gate | Required result | Evidence |
|---|---|---|
| Public repository content | passed | `logs/public-repository-content.log` |
| Native WPR profile parser | passed | `logs/native-wpr-profile-parser.log` |
| PSScriptAnalyzer | zero Error/Warning findings | `logs/psscriptanalyzer.log` |
| Repository smoke | passed | `logs/repository-smoke.log` |
| PowerShell 7 Pester | zero failed tests | `logs/pester-pwsh.log`, `pester-pwsh.xml` |
| Windows PowerShell 5.1 Pester | zero failed tests | `logs/pester-ps51.log`, `pester-ps51.xml` |
| Native paired WPR calibration | passed | `logs/native-wpr-calibration.log`, native calibration lab evidence |

The terminal machine-readable record is:

```text
validation-summary.json
```

Its required terminal state is:

```json
{
  "status": "passed"
}
```

A skipped native calibration is not accepted as full validation.

## Native calibration protocol

The required controlled validation run uses:

```text
repetition_count: 3
warmup_count:     1
ordering:          alternating_control_first
iterations:        1000
seed:              73
```

Each pair must remain bound to:

- one exact repository head,
- one machine identity,
- one boot identity,
- one active power-policy fingerprint,
- one deterministic workload fingerprint.

Successful output must include:

- separate parent and child experiment evidence,
- control and capture workload results,
- process CPU time,
- peak working set,
- peak private bytes,
- WPR start latency,
- WPR stop/finalization latency,
- ETL SHA-256 and byte length,
- effective ETL byte rate,
- profile-provenance SHA-256,
- pair deltas and distribution summaries,
- `threshold_policy.status: not_declared`.

This run validates the measurement mechanism. It does not establish a representative production overhead threshold.

## Failure handling

When a gate fails:

1. preserve the complete results directory,
2. do not edit this document to claim success,
3. inspect the specific gate log and Pester XML,
4. fix the smallest verified root cause,
5. commit the fix,
6. rerun every required gate against the new exact head.

Do not merge PR `#7` from a head that differs from the validated head.

## Pending evidence fields

The following fields remain intentionally blank until a real run completes:

```text
Validated head:
Validation summary path:
Validation started UTC:
Validation stopped UTC:
PowerShell 7 Pester result:
Windows PowerShell 5.1 Pester result:
PSScriptAnalyzer result:
Repository smoke result:
Native WPR calibration result:
Native parent experiment ID:
```
