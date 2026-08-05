# NXB-IRL-004 — Trace-Loss and Circular-Overwrite Accounting

## Status

`IN PROGRESS`

Tracking issue: `#2`

Branch:

```text
nxb-irl-004-trace-loss-accounting
```

## Objective

Make trace loss, collector drop state, bounded-buffer pressure and circular-overwrite risk explicit evidence rather than implicit assumptions.

The block must never claim that loss or overwrite did not occur unless a supported native measurement proves that statement for the exact experiment and trace provenance.

## Evidence model

Every observation is represented with one of these states:

- `measured`: a supported source returned a bounded numeric or boolean observation,
- `unsupported`: the platform or collector does not expose the required observation,
- `unavailable`: the source is normally supported but was not present for this run,
- `failed`: collection or parsing failed,
- `not_assessed`: the evidence required to classify the condition was not collected.

## Required bindings

Loss and overwrite evidence must bind to:

- experiment identity,
- machine identity,
- boot identity,
- collector/profile identity and SHA-256,
- ETL SHA-256 and byte length,
- capture start and stop timestamps,
- configured circular file capacity,
- observed final ETL length,
- native loss/drop counters when available.

## Circular-overwrite classification

The first implementation will classify overwrite evidence conservatively:

- `not_applicable`: non-circular capture,
- `not_assessed`: circular capacity or required observations missing,
- `risk_observed`: final ETL length or native metadata indicates capacity pressure or overwrite,
- `no_risk_observed`: bounded evidence remained below the declared risk threshold; this is not proof that no event loss occurred,
- `failed`: accounting could not complete.

A separate trace-loss classification is mandatory. `no_risk_observed` must never be interpreted as `no_trace_loss`.

## Validation boundary

- no raw ETL is committed,
- no target binaries or dumps are committed,
- synthetic fixtures are used for parser and semantic tests,
- native Windows validation is required before merge,
- GitHub Actions remain disabled.
