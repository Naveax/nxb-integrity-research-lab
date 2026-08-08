# NXB-IRL-004 — Storage Evidence Contract Validation

## Status

`VALIDATED`

Canonical implementation / validation head:

```text
4e72e2fdb132f06741575a83da526b6c4875e896
```

Validation environment:

```text
Windows
PowerShell 7.6.4
Windows PowerShell 5.1
Python + jsonschema
Git exact detached head
clean worktree required
```

## Result

Repository-native storage evidence validation completed successfully at the exact head above.

```text
PowerShell 7 summary Pester:      8/8
PowerShell 7 event Pester:        9/9
Windows PowerShell 5.1 summary:   8/8
Windows PowerShell 5.1 event:     9/9
PSScriptAnalyzer findings:        0
Python semantic validators:       PASS
JSON Schema self-validation:      PASS
Canonical summary fixture:        PASS
Canonical event fixture:          PASS
```

The repository-native runner emitted:

```text
Storage evidence exact-head validation passed:
4e72e2fdb132f06741575a83da526b6c4875e896
```

The surrounding operator wrapper subsequently failed only because it contained a stale hard-coded expectation that the event suite must contain 8 tests. The event suite intentionally contains 9 tests after the queue-semantics guard was added. This outer-wrapper assertion is not part of the repository-native contract and does not invalidate the repository-native PASS result.

## Validated contracts

Normalized event schema:

```text
schemas/storage-event.schema.json
```

Aggregate/per-process summary schema:

```text
schemas/storage-etl-summary.schema.json
```

Semantic validators:

```text
tools/validate_storage_event.py
tools/validate_storage_etl_summary.py
```

PowerShell validation wrappers:

```text
scripts/Test-StorageEvent.ps1
scripts/Test-StorageEtlSummary.ps1
```

Canonical fixtures:

```text
tests/fixtures/storage-event.valid.json
tests/fixtures/storage-etl-summary.valid.json
```

## Conservative evidence boundary

The validated v1 contract does not claim storage-device queue semantics merely because DiskIO/FileIO events exist.

```text
queue_depth_semantics:            false
queue_latency_semantics:          false
service_time_semantics:           false
throughput_representativeness:    false
iops_representativeness:          false
trace_completeness:               not_claimed
```

Normalized event `queue_semantics=measured` is rejected before real ETL/header semantics are validated.

Missing or unobserved evidence remains explicit using:

```text
measured
unsupported
unavailable
failed
not_assessed
```

No missing value is synthesized as zero.

## Next gate

Slice 3 is real Windows ETL/xperf storage header inspection. The next implementation must capture a bounded trace, inspect native DiskIO/FileIO event/header fields, and only then bind duration, transfer-size, disk/file attribution, queue/dispatch/service timing, throughput or IOPS semantics that the native evidence directly supports.

Raw ETL remains local-only.