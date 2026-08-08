# NXB-IRL-004 Storage Real Aggregate Summary Validation

Status: **PASSED**

## Canonical validated implementation head

```text
fc1f8754a10c9a26ea5a3419369d55e6c76dc5fa
```

The validation was executed on real Windows against the preserved storage capture and normalized storage event export. No new WPR capture was performed.

## Repository-native gates

```text
Runner parser:              PASS
Runner PSScriptAnalyzer:    0 findings
PowerShell 7 Pester:        9/9
Windows PowerShell 5.1:     9/9
Adapter PSScriptAnalyzer:   0 findings
Python converter/validator: py_compile PASS
```

Storage summary adapter SHA-256:

```text
1ba71848e82f9668a6d2b98391cd6f020fcaa3ea17ddee48f4a0ae253934fa1c
```

## Real preserved-evidence result

```text
normalized_event_count:      26436
process_count:                34
measured_event_class_count:   10
measured_metric_count:        0
parser_completeness:          partial
evidence_completeness:        partial
trace_loss:                   none
circular_overwrite:           unknown
split_io:                     not_assessed
```

Canonical local result filename from the validation run:

```text
nxb-storage-real-summary-fc1f8754a10c-20260808-191042.json
```

The result file is local evidence and is not committed to the repository.

## Verified aggregate event accounting

| event_type | count | bytes | unattributed | attribution |
| --- | ---: | ---: | ---: | --- |
| disk_flush | 4 | null | 0 | partial |
| disk_read | 137 | 1312256 | 0 | partial |
| disk_write | 894 | 51073024 | 2 | partial |
| file_close | 2435 | null | 0 | partial |
| file_create | 2928 | null | 0 | partial |
| file_delete | 4 | null | 0 | partial |
| file_flush | 2 | null | 0 | partial |
| file_read | 405 | 6861668 | 0 | partial |
| file_rename | 3 | null | 0 | partial |
| file_write | 19624 | 62203939 | 0 | partial |

## Verified target-process accounting

| event_type | count | bytes |
| --- | ---: | ---: |
| disk_flush | 1 | null |
| disk_read | 2 | 32768 |
| disk_write | 8 | 4239360 |
| file_close | 1012 | null |
| file_create | 1209 | null |
| file_delete | 3 | null |
| file_flush | 1 | null |
| file_read | 90 | 4802639 |
| file_rename | 1 | null |
| file_write | 17113 | 9564696 |

## Conservative claim boundary

The validation does **not** establish any of the following:

```text
queue_depth_semantics:            false
queue_latency_semantics:          false
service_time_semantics:           false
throughput_representativeness:    false
iops_representativeness:          false
trace_completeness:               not_claimed
```

`split_io` was not observed and therefore remains `not_assessed`; no measured zero is synthesized.

## Next mandatory gate

Run deterministic downstream replay using the same preserved capture receipt, ETL, bridge manifest and normalized CSV. The replay summary must have the exact same SHA-256 as the canonical local source summary; semantic equivalence alone is insufficient.
