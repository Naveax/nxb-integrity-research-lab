# NXB-IRL-004 — Memory Profile Validation Record

## Status

`PASSED`

- Tracking issue: `#2`
- Stacked draft pull request: `#9`
- Branch: `nxb-irl-004-memory-working-set`
- Validated implementation head: `d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773`
- Validation started UTC: `2026-08-06T17:14:24.8059409Z`
- Validation stopped UTC: `2026-08-06T17:14:45.1150111Z`

GitHub Actions remain intentionally disabled. Validation was performed locally on real Windows from an elevated PowerShell 7 shell using a fresh exact-head clone.

## Environment

```text
OS:                 Microsoft Windows NT 10.0.22631.0
PowerShell:         7.6.4 Core
Windows PowerShell: 5.1 with Pester 5.7.1
WPR:                C:\Windows\system32\wpr.exe
Elevated:           true
```

## Profile provenance

```text
relative_path:          profiles/Nxb.MemoryWorkingSet.wprp
name:                   NxbMemoryWorkingSet
sha256:                 bf03c2ec1e138f314f58d31f9e57bdefac3af089974817e0e81645e0ed3d14f5
length:                 2948 bytes
buffer_size_kib:        1024
buffers:                64
maximum_file_size_mib:  512
file_mode:              Circular
keyword_count:          11
stack_count:            9
reference_set_enabled:  false
```

## Exact-head gate results

All nine gates passed:

- [x] dependency bootstrap — PowerShell 7
- [x] dependency bootstrap — Windows PowerShell 5.1
- [x] PowerShell parser
- [x] PSScriptAnalyzer
- [x] memory-profile repository smoke
- [x] exact structural memory-profile contract
- [x] native `wpr.exe -profiles` acceptance
- [x] PowerShell 7 focused Pester
- [x] Windows PowerShell 5.1 focused Pester
- [x] summary and review ZIP inspection

Focused test results:

```text
PowerShell 7 / Pester 6.0.1:             10 passed, 0 failed
Windows PowerShell 5.1 / Pester 5.7.1:  10 passed, 0 failed
```

No test was skipped, inconclusive or not run.

## Review artifact

```text
file:    nxb-memory-profile-d494a12fd7dd-20260806T171424Z-review.zip
sha256:  da57bd23983f39939681addbcf8469f507cf1a39297ca0f761d67738f8772ef8
```

The archive contains:

- `memory-profile-validation-summary.json`,
- PowerShell 7 and Windows PowerShell 5.1 Pester XML,
- dependency bootstrap logs,
- PowerShell parser log,
- PSScriptAnalyzer log,
- repository-smoke log,
- profile-contract output,
- native WPR parser output.

## Earlier failed attempts

Two non-elevated launcher attempts were correctly rejected before cloning or validation. The first elevated implementation attempt reached a fresh exact-head clone but stopped before substantive gates because the gate-recording helper did not accept an initially empty strongly typed list. That binder defect was repaired with `AllowEmptyCollection`; the successful run above supersedes those attempts.

## Scope boundary

This validation closes the bounded memory WPR profile foundation only. It does not yet validate:

- process/system memory snapshot collection,
- ETL hard/soft fault extraction,
- deterministic bounded memory-pressure fixtures,
- paired collector-overhead calibration,
- trace-loss behavior under memory workload,
- end-to-end memory evidence finalization.

PR #9 remains draft while those implementation slices are in progress.
