# NXB-IRL-004 — Trace-Loss and Circular-Overwrite Accounting

## Status

`IMPLEMENTATION COMPLETE — WINDOWS VALIDATION PENDING`

Tracking issue: `#2`

Draft PR: `#8`

Branch:

```text
nxb-irl-004-trace-loss-accounting
```

## Objective

Make trace loss, collector drop state, bounded-buffer pressure and circular-overwrite risk explicit evidence rather than implicit assumptions.

The block never converts missing evidence into a claim that no loss or overwrite occurred.

## Implemented evidence pipeline

```text
recording experiment
 -> Get-NxbWprStatusSnapshot.ps1
 -> Stop-PerformanceTrace.ps1
 -> Get-NxbEtlTraceStatistics.ps1
 -> New-NxbTraceLossAccountingFromSources.ps1
 -> New-NxbTraceLossAccounting.ps1
 -> Test-TraceLossAccounting.ps1
 -> analysis/trace-loss-accounting.json
```

The operator-facing integration entry point is:

```text
scripts/Stop-PerformanceTraceWithAccounting.ps1
```

This wrapper takes the pre-stop WPR snapshot before stopping the active session, delegates existing ETL finalization to `Stop-PerformanceTrace.ps1`, collects post-stop trace-header statistics, merges the native sources and writes strict accounting evidence.

If the accounting document reaches `failed`, the already stopped experiment is transitioned to `failed`; partial or unavailable counters remain visible without inventing zeroes.

## Native sources

### Pre-stop WPR status

The collector invokes:

```text
wpr -status collectors -details
```

It records:

- raw output SHA-256,
- command and exit code,
- collector-level `Events Lost` values when available,
- top-level `Dropped event` only as a fallback,
- explicit unsupported or unavailable states for counters not exposed by this command.

### Post-stop ETL trace statistics

The post-stop adapter invokes:

```text
xperf -i performance.etl -o xperf-tracestats.txt -a tracestats -timespan -timezone utc
```

The `-timespan` mode is deliberately limited to trace-header inspection. The adapter extracts, when exposed:

- `Events Lost`,
- `Buffers Lost`,
- `Buffers Written`.

Parsed values are bound to the SHA-256 of the trace-statistics output. Missing fields are `unavailable`; an unavailable xperf executable is `unsupported`; a nonzero xperf exit is `failed`.

## Source precedence

Post-stop evidence has priority when it is `measured` or `failed` because it is derived from the completed ETL. Pre-stop measured evidence is used when the post-stop source is unsupported or unavailable.

A post-stop failure is not masked by a pre-stop zero.

## Evidence states

Every observation is represented with one of these states:

- `measured`: a supported source returned a bounded numeric observation,
- `unsupported`: the platform or collector does not expose the observation,
- `unavailable`: the source is normally supported but the field was absent,
- `failed`: collection or parsing failed,
- `not_assessed`: the evidence needed for classification was not collected,
- `not_applicable`: the counter does not apply to the selected capture mode.

For file-mode ETL capture, `realtime_buffers_lost` is `not_applicable` because no real-time consumer delivery path exists. This state is excluded from required-counter completeness rather than being misclassified as missing evidence.

## Required bindings

Loss and overwrite evidence binds to:

- experiment identity,
- machine identity,
- boot identity,
- collector/profile identity and SHA-256,
- ETL SHA-256 and byte length,
- capture start and stop timestamps,
- configured circular file capacity,
- observed final ETL length,
- native source-output SHA-256 values.

## Trace-loss classification

- `native_loss_observed`: at least one measured applicable native counter is greater than zero,
- `no_native_loss_reported`: every applicable counter is measured and zero,
- `not_assessed`: an applicable counter remains unsupported, unavailable or not collected,
- `failed`: an applicable native accounting source failed.

For the current file-mode WPR path, the applicable set is:

```text
Events Lost
Buffers Lost
```

`realtime_buffers_lost` remains represented as `not_applicable`, not omitted.

`no_native_loss_reported` is limited to the applicable native counters represented by the exact evidence document. It is not a universal completeness claim.

## Circular-overwrite classification

- `not_applicable`: non-circular capture,
- `not_assessed`: circular capacity or required observations missing,
- `risk_observed`: final ETL length reaches the fixed 0.9 capacity-risk threshold or exceeds declared capacity,
- `no_risk_observed`: measured final ETL length remains below that threshold,
- `failed`: accounting could not complete.

`no_risk_observed` is not proof that circular overwrite or event loss did not occur.

Every document retains:

```text
claims.trace_loss_absence: false
claims.circular_overwrite_absence: false
claims.capture_completeness: not_claimed
```

## Implemented validation

- strict JSON Schema 2020-12 contract,
- Python cross-field semantic validator,
- hash-bound native counter source validation,
- applicable-counter and `not_applicable` enforcement,
- PowerShell validator wrapper with PS7/PS5.1 native stderr handling,
- canonical valid fixture,
- adversarial classification and provenance tests,
- fake-WPR status parser tests,
- fake-xperf trace-statistics tests,
- final collector tests,
- accounting-aware stop lifecycle tests,
- dedicated repository smoke gate,
- exact-head native Windows validation runner.

## Remaining work

- run PSScriptAnalyzer with zero findings,
- run complete PowerShell 7 Pester matrix,
- run complete Windows PowerShell 5.1 Pester matrix,
- run real elevated WPR/xperf capture on Windows,
- inspect exact-head logs and native evidence,
- wire the accounting-aware path into the final canonical operator flow after validation,
- update closeout metadata and merge with expected-head locking.

## Validation boundary

- no raw ETL is committed,
- no xperf report from a real target is committed,
- no target binaries or dumps are committed,
- synthetic fixtures are used for parser and semantic tests,
- native Windows validation is required before merge,
- GitHub Actions remain disabled.
