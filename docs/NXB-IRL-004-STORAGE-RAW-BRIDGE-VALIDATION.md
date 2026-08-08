# NXB-IRL-004 — Real Storage Raw Bridge Validation

## Status

`VALIDATED`

Canonical raw-bridge implementation head:

```text
fdf0506eda29918077ff7aec3923ab98dcb56d87
```

Source real header-probe capture head:

```text
c4e6b8cc435fe700acfa0a5d17c50684a00052d3
```

## Real Windows replay result

The preserved local xperf dumper from the canonical bounded storage capture was replayed through the exact raw-bridge head above.

```text
Pester:                         8/8
PSScriptAnalyzer findings:      0
Python normalizer py_compile:   PASS
Normalized events:              58669
Parser completeness:            partial
Target PID:                     8444
Target normalized rows:         19427
Target rows carrying paths:     19426
Rows carrying raw timing text:  233
Timing units resolved:          False
Normalized duration_us:         False
Queue semantics claimed:        False
Service-time semantics claimed: False
Trace completeness claimed:     False
Trace loss:                     none
Circular overwrite:             unknown
```

## Provenance

```text
source dumper SHA-256:
d233b89a2d6f0f21ac8e3648b4971d62beee08880e095f941a93df0f6a5b1cf9

normalized CSV SHA-256:
6dc452450a85cb0a1680fb4cbba2eeb09052a504a9c4cd56a96b264214c2883e

bridge manifest SHA-256:
06fdb9501a1c2f6e6026a9be9ecd614a65229a54e08372569e02505528d7589f
```

Raw ETL, full xperf dumper and normalized replay output remain local-only.

## Semantic boundary

The raw bridge is validated to normalize only directly observed identity/integer evidence:

```text
process_id
thread_id
disk_number
file_key/path
offset_bytes
transfer_bytes
```

Native timing fields remain raw evidence:

```text
timestamp_raw
duration_raw
disk_service_time_raw
```

No unit conversion is performed yet. In particular, the bridge does not convert `ElapsedTime` or `DiskSvcTime` into microseconds and does not infer storage-device queue semantics.

Observed event presence never implies that an unobserved class has count zero. Downstream summary generation must keep unobserved event classes explicit as `not_assessed` rather than synthesizing zero.

## Operator-wrapper note

The surrounding portable wrapper displayed malformed event-count table labels (`(0, -20) 1`) because of a formatting-expression defect in the wrapper only. The repository-native bridge, normalized CSV and bridge manifest had already passed and their event counts/provenance were unaffected. No canonical event-class count claim is derived from those malformed display lines.

## Next gate

Build and validate the storage event-export summary adapter. It must:

- bind the real capture receipt, raw-bridge manifest and normalized CSV by SHA-256;
- aggregate only observed normalized rows;
- keep unobserved event classes `not_assessed` rather than zero;
- preserve target process identity separately from partial non-target identities;
- leave latency/queue/service-time/throughput/IOPS metrics `not_assessed` while timing units are unresolved;
- emit a `storage-etl-summary.schema.json` compliant summary and pass the existing semantic validator.
