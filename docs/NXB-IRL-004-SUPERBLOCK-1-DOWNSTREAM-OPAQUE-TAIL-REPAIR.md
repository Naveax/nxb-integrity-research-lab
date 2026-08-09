# NXB-IRL-004 SUPERBLOCK 1 — Downstream opaque-tail repair

## Measured failure

Exact-head downstream attempt:

```text
54de52c8db3d255988ce96e50d45bfe3287da147
```

The static gate passed:

```text
PowerShell 7:            10/10
Windows PowerShell 5.1: 10/10
PSScriptAnalyzer:        0
Python syntax:           PASS
canonical source binding:PASS
```

The canonical real dumper then measured:

```text
normalized rows:          176369
unresolved schema rows:    12136
malformed source rows:          5
recognized malformed rows:      not yet separated by that implementation
```

All 12,136 unresolved rows had the same structural reason:

```text
active_header_nonempty_extra = 12136
```

Dominant measured event classes:

```text
T-DCEnd:   5938
T-DCStart: 5912
T-Start:     96
T-End:       90
P-DCEnd:     49
P-DCStart:   49
DNS Info:     2
```

The gate failed closed before replay and promoted no semantic claim.

## Repair contract

The active xperf header remains authoritative for all named fields. If a recognized row contains non-empty fields beyond that header, the fields are no longer discarded or treated as semantically named columns. They are preserved in the local normalized event as deterministic ordinal fields:

```text
__xperf_opaque_tail_001
__xperf_opaque_tail_002
...
```

The extended structural schema receives its own SHA-256 while retaining the base header SHA-256. The receipt records only bounded counts and event/row-length shape counts; raw opaque values remain local with the normalized JSONL.

Claims remain conservative:

```text
nonempty_extra_columns_discarded:          false
nonempty_extra_columns_preserved_as_opaque:true
opaque_tail_semantics_resolved:            false
timestamp_unit_resolved:                   false
kernel_lifecycle_semantics:                false
network_connection_semantics:              false
trace_completeness:                        not_claimed
```

## Malformed-row boundary

The normalizer now separates:

```text
malformed_rows
recognized_malformed_rows
```

Domain-external one-field xperf fragments remain audit evidence but do not fail certification. A malformed row whose event name belongs to the recognized GPU/network/kernel family remains fail-closed.

## New acceptance

```text
observed header shapes:        126
recognized header shapes:       73
unresolved schema rows:          0
recognized malformed rows:       0
normalized rows == recognized candidate rows
normalized-event replay: byte-identical
coverage replay:         byte-identical
```

Raw ETL, full xperf dumper, normalized JSONL, IP/path/registry values, and opaque-tail values remain local-only.
