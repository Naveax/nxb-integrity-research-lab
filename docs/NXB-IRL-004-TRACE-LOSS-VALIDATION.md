# NXB-IRL-004 — Trace-Loss Accounting Validation Record

## Status

`PENDING — EXACT-HEAD WINDOWS VALIDATION REQUIRED`

Tracking issue: `#2`

Draft pull request: `#8`

Branch:

```text
nxb-irl-004-trace-loss-accounting
```

GitHub Actions are intentionally disabled repository-wide. This block is validated on a real Windows installation with:

```text
scripts/Invoke-NxbTraceLossLocalValidation.ps1
```

No gate is considered passed until the generated summary, complete logs, both Pester XML files and safe native accounting summary have been inspected.

## Required environment

- Windows 10 or Windows 11
- elevated administrator PowerShell 7
- Git
- PowerShell 7
- Windows PowerShell 5.1
- Python with `jsonschema`
- Pester 5 or later for both PowerShell hosts
- PSScriptAnalyzer
- `wpr.exe`
- `xperf.exe`

## Required gates

1. Existing exact-head base validation:
   - public repository content guard,
   - native WPR profile parser,
   - zero-finding PSScriptAnalyzer,
   - repository smoke,
   - full PowerShell 7 Pester matrix,
   - full Windows PowerShell 5.1 Pester matrix,
   - one native paired WPR regression trial.
2. Native trace-loss accounting:
   - real pre-stop WPR status snapshot,
   - real WPR ETL stop/finalization,
   - post-stop xperf trace-header statistics,
   - actual ETL SHA-256 and length reconciliation,
   - strict trace-loss accounting semantic validation,
   - stopped lifecycle verification,
   - final evidence integrity verification.

A skipped native gate is not accepted.

## Native validation boundary

The native gate validates the accounting mechanism. It does not require reported event loss or circular risk to be zero.

The terminal accounting document must retain:

```text
claims.trace_loss_absence: false
claims.circular_overwrite_absence: false
claims.capture_completeness: not_claimed
```

The review ZIP excludes:

- raw ETL,
- the full xperf trace-statistics report,
- complete native experiment directories.

It includes only summaries, gate logs and Pester XML files.

## Exact-head command

From a clean checkout of the PR branch in an elevated PowerShell 7 window:

```powershell
$head = (git rev-parse HEAD).Trim()

./scripts/Invoke-NxbTraceLossLocalValidation.ps1 `
    -ExpectedHead $head `
    -BootstrapDependencies `
    -Iterations 5000 `
    -Seed 73 `
    -Confirm:$false
```

The terminal summary must contain:

```json
{
  "status": "passed"
}
```

## Pending evidence fields

```text
Validated head:
Validation summary path:
Validation started UTC:
Validation stopped UTC:
Base exact-head validation result:
PowerShell 7 Pester result:
Windows PowerShell 5.1 Pester result:
PSScriptAnalyzer result:
Native trace-loss accounting result:
Pre-stop Events Lost status:
Post-stop Events Lost status:
Post-stop Buffers Lost status:
Post-stop Buffers Written status:
Trace-loss classification:
Circular-overwrite classification:
Evidence completeness:
```
