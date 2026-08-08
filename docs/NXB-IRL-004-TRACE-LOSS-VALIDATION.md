# NXB-IRL-004 — Trace-Loss Accounting Validation Record

## Status

`PASSED — EXACT IMPLEMENTATION HEAD VALIDATED ON WINDOWS`

- Tracking issue: `#2`
- Draft pull request: `#8`
- Branch: `nxb-irl-004-trace-loss-accounting`
- Validated implementation head: `e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258`
- Validation started UTC: `2026-08-06T11:30:52.4556072Z`
- Validation stopped UTC: `2026-08-06T11:41:42.5223398Z`
- Summary status: `passed`

GitHub Actions remain intentionally disabled repository-wide. Validation was performed from an elevated PowerShell 7 shell on a real Windows installation with:

```text
scripts/Invoke-NxbTraceLossLocalValidation.ps1
```

The generated exact-head summaries, complete gate logs, both Pester XML files, safe native accounting summary and review ZIPs were inspected before this record was written.

## Environment boundary

Validated environment:

- Windows 10 `10.0.19045`
- elevated administrator PowerShell 7
- Windows PowerShell 5.1
- Git
- Python with `jsonschema`
- Pester 6.0.1 for PowerShell 7
- Pester 5.7.1 for Windows PowerShell 5.1
- PSScriptAnalyzer
- native `wpr.exe`

`xperf.exe` was unavailable on the validated host. Post-stop counters were measured directly from the ETL `TRACE_LOGFILE_HEADER` through the native `OpenTraceW` reader. The validation therefore proves the xperf-independent fallback path rather than the xperf adapter path.

## Required gates

| Gate | Result |
|---|---|
| Bootstrap — PowerShell 7 | passed |
| Bootstrap — Windows PowerShell 5.1 | passed |
| Public repository content | passed — 108 candidate files inspected |
| Native WPR profile parser | passed |
| PSScriptAnalyzer | passed — 0 Error/Warning findings |
| Repository smoke | passed |
| PowerShell 7 Pester | passed — 136/136 |
| Windows PowerShell 5.1 Pester | passed — 136/136 |
| Native paired WPR regression calibration | passed — 1/1 pair, 0 warmups |
| Base exact-head validation | passed |
| Native trace-loss accounting | passed |

No required gate was skipped. The base summary recorded identical `head_sha` and `expected_head_sha` values:

```text
e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258
```

## Base validation protocol

```text
repetition_count: 1
warmup_count:     0
ordering:         alternating_control_first
iterations:       1000
seed:             73
```

The calibration mechanism remained conservative:

```text
threshold_policy.status: not_declared
```

This regression trial validates that the paired calibration pipeline still works on the exact implementation head. It does not establish a representative production overhead threshold.

## Native trace-loss result

```text
status:                            passed
trace_loss_classification:         no_native_loss_reported
measured_counter_count:            2
total_reported_loss:               0
circular_overwrite_classification: no_risk_observed
circular_utilization_ratio:        0.162109375
evidence_completeness:             complete
pre_stop_events_lost_status:       measured
post_stop_events_lost_status:      measured
post_stop_buffers_lost_status:     measured
post_stop_buffers_written_status:  measured
post_stop_counter_source:          etl_header_snapshot
xperf_available:                   false
realtime_buffers_lost_status:      not_applicable
```

Native ETL identity:

```text
sha256: 7a4ac54fb9a351ba8eba32af043fcdfca7028d8769f169498ac64f6ce4333a57
length: 87031808 bytes
profile_provenance_sha256: 6290daaf6e68e35ebe9fecb1fba7c8164e3bc04bd660a568b6845f95a1c53f33
```

The applicable file-mode loss counters were measured as zero. `Buffers Written` was measured as a diagnostic native header counter. The circular ETL used approximately `16.2109375%` of its represented capacity, below the fixed risk threshold.

## Applicable counter model

For the bounded file-mode WPR profile, trace-loss assessment requires:

```text
Events Lost
Buffers Lost
```

The real-time consumer counter remains explicitly represented as:

```text
realtime_buffers_lost.status: not_applicable
```

When both applicable counters are measured, zero values may produce `no_native_loss_reported`; positive values produce `native_loss_observed`. Neither classification permits a general absence or completeness claim.

The terminal accounting document retains:

```text
claims.trace_loss_absence: false
claims.circular_overwrite_absence: false
claims.capture_completeness: not_claimed
```

`no_native_loss_reported` is limited to the represented applicable native counters. `no_risk_observed` is not proof that no event loss or circular overwrite occurred.

## Artifact hashes

```text
trace-loss review ZIP:
  bfffddfd3a16374dd3056464bc3057e3667b3791331a9377cf2598fcf74714a5
base validation review ZIP:
  288f9439dcacc2f32bbe9847a64603c6deea4146c812cdab78647f20e7335df8
trace-loss-validation-summary.json:
  10b7c89918921004bacb2946d14492e1f168f148f7dabffb88c8bc1fa93d924c
native-trace-loss-summary.json:
  d8182a3093115b2b5c541873233a875f04bf89a3492037c4fa215bc0832e8b1f
validation-summary.json:
  ae29cbe98850adc61544e2b8e6f76e64fa4572eabb01f906e3d3ea452c615b05
pester-pwsh.xml:
  d6f83746a0aa0389e4c195de86ad284a3b4ba4c4f1ddeb579ca832a67bbdd528
pester-ps51.xml:
  8657a8e9c6fe4e104a3b873797504190a3a00b94cfbac471acbbb8851c532206
native-calibration.json:
  c67094e6da18b8fea540b029c6515501843fbbe089b6a298ab7d2fe7ece32aa8
```

The review bundles exclude raw ETL and complete native experiment directories. They retain safe summaries, required gate logs and Pester XML evidence.

## Operator flow

The validated operator flow was:

```powershell
$head = (git rev-parse HEAD).Trim()

./scripts/Invoke-NxbTraceLossLocalValidation.ps1 `
    -ExpectedHead $head `
    -BootstrapDependencies `
    -Iterations 5000 `
    -Seed 73 `
    -Confirm:$false
```

The final summary recorded both required top-level gates as passed:

```text
base-exact-head-validation: passed
native-trace-loss-accounting: passed
```

## Closeout boundary

The validated implementation head is:

```text
e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258
```

Any later commits in PR `#8` are restricted to closeout documentation and PR metadata. Runtime, schema, validator and test claims remain bound to the exact implementation head above. Before merge, the final PR head must be compared with this implementation head and the difference must remain documentation-only.
