# NXB-IRL-004 — Memory Foundation Validation Record

## Status

`PASSED — REVIEW ARCHIVE HASH NOT INGESTED`

- Tracking issue: `#2`
- Stacked draft pull request: `#9`
- Branch: `nxb-irl-004-memory-working-set`
- Validated implementation head: `ae3debb4bf16276c08eb79dc3575ed7cf8ce5492`
- Validation results root: `nxb-memory-foundation-v2-ae3debb4bf16-20260806T205535Z`

GitHub Actions remained intentionally disabled. Validation was performed locally on real Windows from a fresh exact-head clone in an elevated PowerShell 7 shell.

## Environment

```text
OS:                         Microsoft Windows NT 10.0.22631.0
PowerShell:                 7.6.4 Core
Windows PowerShell:         5.1
PowerShell 7 Pester:        6.0.1
Windows PowerShell Pester:  5.7.1
Python:                     C:\ProgramData\minicond3\python.exe
Elevated:                   true
```

## Gate results

The bounded WPR profile foundation passed under both PowerShell runtimes:

```text
PowerShell 7:             10 passed, 0 failed
Windows PowerShell 5.1:  10 passed, 0 failed
```

The Draft 2020-12 memory snapshot schema and semantic contract passed under both PowerShell runtimes:

```text
PowerShell 7:              9 passed, 0 failed
Windows PowerShell 5.1:   9 passed, 0 failed
```

No focused test was skipped, inconclusive or not run.

The successful run also completed:

- [x] fresh exact-head clone verification,
- [x] clean working-tree verification,
- [x] Python `jsonschema` availability,
- [x] repository smoke,
- [x] PowerShell parser gates,
- [x] zero-finding PSScriptAnalyzer gates,
- [x] exact structural WPR profile contract,
- [x] native `wpr.exe -profiles` acceptance,
- [x] canonical memory snapshot fixture validation,
- [x] fail-closed V2 orchestration correction,
- [x] final passed foundation summary.

## Review artifact

The successful run reported:

```text
nxb-memory-foundation-v2-ae3debb4bf16-20260806T205535Z-review.zip
```

The archive was not attached with the successful console result, so its SHA-256 is not recorded or claimed here. The exact-head pass is supported by the supplied console transcript; archive integrity remains a separate evidence-ingestion step.

## Closed scope

This validation closes:

- bounded memory WPR profile parsing,
- repository-owned profile provenance,
- Draft 2020-12 memory snapshot schema,
- semantic snapshot validation,
- partial/unavailable/failed measurement representation,
- PowerShell 7 and Windows PowerShell 5.1 foundation test matrices.

## Remaining scope

This validation does not yet close:

- real process/system memory snapshot collection,
- hard/soft page-fault ETL attribution,
- virtual allocation and mapped-region ETL extraction,
- deterministic bounded memory-pressure workload,
- paired overhead calibration,
- trace-loss accounting under the memory workload,
- final end-to-end memory evidence closure.

PR #9 remains draft while those slices are implemented and validated.
