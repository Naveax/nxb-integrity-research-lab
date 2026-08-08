# NXB-IRL-004 — Native Memory Collector Validation

## Result

`PASSED`

Validated exact head:

```text
d49aaef68da1e8be4141ccc55f032c13e211e64a
```

Validation ran on real elevated Windows from PowerShell 7.6.4. The exact-head fresh clone used the stacked branch `nxb-irl-004-memory-working-set`.

## Review artifact

```text
nxb-memory-collector-d49aaef68da1-20260806T222934Z-review.zip
sha256: ed8ec6191be105cc78abbe7cccbc180b285ca7864f774d663122b21760647a92
```

The review archive contains the collector summary, nested foundation and profile summaries, all focused NUnit XML results, and per-gate logs.

## Collector gates

All collector gates passed with exit code 0:

- `memory-foundation-v2`
- `memory-collector-parser`
- `memory-collector-psscriptanalyzer`
- `pester-memory-collector-pwsh`
- `pester-memory-collector-ps51`

## Nested foundation gates

All combined foundation gates passed:

- Python `jsonschema`
- profile foundation
- snapshot parser
- snapshot PSScriptAnalyzer
- snapshot schema and semantic contract
- PowerShell 7 snapshot Pester
- Windows PowerShell 5.1 snapshot Pester

All profile-only gates also passed, including native `wpr.exe -profiles` parsing.

## Focused test totals

```text
profile tests:
  PowerShell 7:             10/10
  Windows PowerShell 5.1:  10/10

snapshot-contract tests:
  PowerShell 7:              9/9
  Windows PowerShell 5.1:    9/9

native collector tests:
  PowerShell 7:              7/7
  Windows PowerShell 5.1:    7/7
```

Across all recorded NUnit XML files:

```text
failures:      0
errors:        0
not-run:       0
skipped:       0
inconclusive:  0
invalid:       0
```

## Validated collector behavior

The exact head successfully demonstrated:

- current-process snapshot production on real Windows,
- PID, process-start UTC, and executable SHA-256 identity binding,
- native physical-memory and commit measurements through `GetPerformanceInfo`,
- native process footprint and cumulative page-fault measurements through `GetProcessMemoryInfo`,
- explicit `not_assessed` hard/soft-fault attribution until ETW evidence exists,
- collector SHA-256 provenance on every measured field,
- schema and semantic validation before atomic publication,
- overwrite denial without explicit `-Force`,
- rejection of a missing process,
- zero PSScriptAnalyzer findings in the collector validation set.

## Boundary

This validation does not claim ETW-derived hard/soft fault attribution, virtual-allocation lifecycle parsing, memory-pressure workload coverage, overhead calibration, or end-to-end WPR capture closure. Those remain later slices of PR #9.
