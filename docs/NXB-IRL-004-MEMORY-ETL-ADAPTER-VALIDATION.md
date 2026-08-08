# NXB-IRL-004 Memory ETL Adapter Validation

## Status

`PASSED ON REAL WINDOWS — ARCHIVE HASH PENDING ATTACHMENT`

Validated implementation and validation-runner head:

```text
d9502f8f69419ec12a6ae43e79c83f14b6113ef2
```

Branch:

```text
nxb-irl-004-memory-working-set
```

GitHub Actions remained intentionally disabled. Validation ran locally on a real elevated Windows installation.

## Environment

Observed validation environment:

```text
Windows:       Microsoft Windows NT 10.0.19045.0
PowerShell 7:  7.6.3
PSEdition:     Core
Python:        C:\Users\umut\AppData\Local\Programs\Python\Python312\python.exe
```

The exact-head clone used:

```text
C:\Users\umut\Downloads\nxb-memory-etl-adapter-validation-20260807-121148
```

## Exact-head results

Repository smoke passed with the committed memory profile, snapshot collector, normalized ETL summary contract and event-export adapter.

Profile tests:

```text
PowerShell 7:             10/10
Windows PowerShell 5.1:  10/10
```

Snapshot-contract tests:

```text
PowerShell 7:              9/9
Windows PowerShell 5.1:    9/9
```

Native collector tests:

```text
PowerShell 7:              7/7
Windows PowerShell 5.1:    7/7
```

Memory ETL contract + normalized event-export adapter tests:

```text
PowerShell 7:             18/18
Windows PowerShell 5.1:   18/18
```

For every recorded Pester matrix:

```text
failed:        0
skipped:       0
inconclusive:  0
not run:       0
```

The final fail-closed V3 validation wrapper completed successfully and produced a `passed` summary.

## Validation-chain history

Earlier exact-head runs exposed runner-only failures rather than product failures:

1. `b4093c49ff90b69d2ff0b1031b5acec027e6763c`
   - event adapter used a `Measure-Object.Sum` path that failed on empty event selections;
   - one soft-fault test was overly coupled to validation ordering;
   - analyzer findings remained in the initial adapter foundation.
2. `66c27fbd69b32171b47f3d27bbe1b8d13cb87e45`
   - both ETL Pester matrices actually passed 18/18;
   - V1 accounting produced false negatives from a PowerShell 7 CLIXML control-character decode failure and missing Pester 5 `PassThru` result accounting.
3. `91a155f90bd1bc03e5d7dc59aea187515e6e4970`
   - the first fail-closed accounting wrapper contained a PowerShell interpolation parser error around `$Path:`.
4. `91f08bb9f9c019930ad12f73acb2b68ae4097dcb`
   - all product/ETL matrices passed again;
   - the wrapper's self-analysis correctly rejected assignment to the built-in `$matches` automatic variable.
5. `d9502f8f69419ec12a6ae43e79c83f14b6113ef2`
   - the wrapper automatic-variable finding was fixed;
   - the complete profile, snapshot, collector and ETL matrices passed;
   - final V3 accounting completed successfully.

The final wrapper only supersedes the two previously characterized Pester transport/accounting false negatives when successful 18-test NUnit evidence is present and every other ETL validation gate passed. Unknown failures remain fail-closed.

## Review artifact

The successful run reported:

```text
nxb-memory-etl-adapter-v3-d9502f8f6941-20260807T091150Z-review.zip
```

Its SHA-256 is intentionally **not recorded yet** because the final review ZIP itself was not attached to the validation conversation when this record was written. The hash must be added only after computing it from the actual archive bytes.

## Validated scope

This validation closes the normalized memory-event adapter foundation:

- hard-fault and soft-fault component classes remain separate;
- `soft_fault_total` is derived only with complete soft-fault component coverage;
- virtual allocation/free and mapped-section lifecycle classes are modeled separately;
- undeclared coverage never becomes an inferred zero;
- aggregate, process and unattributed counts reconcile;
- target PID/start/image identity is bound into evidence;
- trace, profile, normalized export and adapter provenance are hash-bound;
- trace-loss, circular-overwrite and parser-completeness states remain explicit;
- output is published only after schema and semantic validation.

## Boundary

This validation does **not** yet prove direct raw ETL/xperf-dumper ingestion or real ETW-derived memory-event counts. The next implementation slice is a fail-closed bridge from raw Xperf dumper output into the already validated normalized event-export contract, followed by elevated real-WPR capture validation.
