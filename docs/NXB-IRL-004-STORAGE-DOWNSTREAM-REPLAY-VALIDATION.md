# NXB-IRL-004 Storage Deterministic Downstream Replay Validation

Status: **PASS**

Validated exact head:

```text
3cbf3c986b6be53b850d0d5996ceafc5af8a3460
```

Validated on real Windows from PowerShell 7.6.4 using the preserved real storage capture, normalized event export and canonical real summary.

## Repository-native replay preflight

```text
PowerShell 7 Pester:       6/6
Windows PowerShell 5.1:    6/6
PSScriptAnalyzer:          0 findings
Byte-identical required:   True
Semantic-only sufficient:  False
```

Nested storage-summary adapter validation remained clean:

```text
PowerShell 7 Pester:       9/9
Windows PowerShell 5.1:    9/9
PSScriptAnalyzer:          0 findings
Python py_compile:         PASS
```

## Real replay result

```text
source_summary_sha256: 095cb43af75d195e7f3132fbdeb546e712898d73f64796a611b14fd1b1c2b912
replay_summary_sha256: 095cb43af75d195e7f3132fbdeb546e712898d73f64796a611b14fd1b1c2b912
byte_identical_summary: True
normalized_event_count: 26436
process_count: 34
measured_event_classes: 10
measured_metrics: 0
parser_completeness: partial
evidence_completeness: partial
trace_loss: none
circular_overwrite: unknown
split_io: not_assessed
```

The replay summary was generated through the same repository-owned real-summary runner and was byte-identical to the previously validated source summary. Semantic equivalence alone is not accepted.

## Conservative boundary retained

```text
queue_depth_semantics: false
queue_latency_semantics: false
service_time_semantics: false
throughput_representativeness: false
iops_representativeness: false
trace_completeness: not_claimed
```

Circular overwrite remains `unknown` pending explicit native ETL header/capacity risk accounting. A low final ETL utilization ratio, if observed, may support `no_risk_observed`; it must not be converted into an overwrite-absence claim.
