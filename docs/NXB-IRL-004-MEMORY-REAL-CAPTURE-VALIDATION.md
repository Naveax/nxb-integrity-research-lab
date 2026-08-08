# NXB-IRL-004 Memory Real Capture Validation

## Status

`PASSED — EXACT-HEAD REAL WINDOWS END-TO-END CAPTURE`

Validated implementation head:

```text
5ef11042146ba4d964ce553edd02a0f6329732e6
```

Branch:

```text
nxb-irl-004-memory-working-set
```

Validation ran locally on real elevated Windows. GitHub Actions remained intentionally disabled.

## Environment

```text
Windows:      Microsoft Windows NT 10.0.19045.0
PowerShell 7: 7.6.3 Core
wpr.exe:      Windows Performance Recorder 10.0.26100
xperf.exe:    C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe
```

The portable validator cloned the branch fresh and required exact HEAD `5ef11042146ba4d964ce553edd02a0f6329732e6` before running native capture.

## Preflight gates

All mandatory preflight gates passed:

```text
PowerShell parser:                 PASS
PSScriptAnalyzer:                  0 findings
Python normalizer py_compile:      PASS
memory profile contract:           PASS
native wpr.exe profile parse:      PASS
bounded workload runtime smoke:    PASS
```

## Bounded workload

The real WPR session exercised the repository-owned bounded workload:

```text
private allocation: 32 MiB
mapped file:        8 MiB
hold:               1000 ms
page stride:        4096 bytes
workload PID:       16052
checksum:           1269180
```

The workload explicitly does not guarantee hard faults, a particular soft-fault class, or a controlled cache state, and it does not attempt system-memory exhaustion.

## Native trace quality

The pre-stop WPR status reported:

```text
Dropped event: 0
Events Lost:   0
```

Canonical quality state:

```text
trace_loss:          none
circular_overwrite:  unknown
trace_completeness:  not_claimed
```

`circular_overwrite` remains `unknown`; the run does not infer absence merely because the native loss counters were zero.

## Raw acquisition evidence

The successful run produced a native ETL and xperf dumper locally:

```text
ETL SHA-256:
07da3d1f71d0739cc20ca33b21ad96f0a5d421520bdf5a8f6db357eebbac09ef

xperf dumper SHA-256:
09fe1ec6b3551453ce99b8d8e9d300974e9d362c90b30c95d77449d55647b917
```

Raw ETL and full dumper text were deliberately excluded from the review ZIP.

## Real xperf normalization

The same exact-head run normalized the real xperf dumper successfully.

```text
input_encoding:              windows-ansi
decode_error_policy:         replace
decode_replacement_count:    0
normalized_event_count:      265258
process_attribution:         partial
normalized CSV SHA-256:      b1c9669aea5be127efe4ac963f9e223a59cab48b8bf54b49e53020da38eba8aa
```

Observed covered event classes:

```text
copy_on_write_fault
demand_zero_fault
guard_page_fault
hard_fault
transition_fault
virtual_allocation
virtual_free
```

Observed aggregate counts:

```text
hard_fault:           372
demand_zero_fault:    125532
copy_on_write_fault:  3563
transition_fault:     106197
guard_page_fault:     591
virtual_allocation:   23683
virtual_free:         5320
```

The four mapped soft-fault components therefore produce:

```text
soft_fault_total: 235883
```

The generic `PageFault` stream separately exposed:

```text
CopyOnWrite: 3563
DemandZero:  125532
GuardPage:   591
HardFault:   570
Transition:  106197
```

`PageFault.Type=HardFault` remains intentionally unmapped because the same trace contains a dedicated `HardFault` stream. This preserves the fail-closed no-double-count boundary. The dedicated `HardFault` stream exposes `IOSize`, so hard-fault bytes are derived only from that header field.

Virtual allocation/free size is derived from the observed `BaseAddr`/`EndAddr` range. No virtual-memory balance claim is made.

## Downstream memory ETL summary

The exact-head run converted the normalized CSV into the repository memory ETL summary contract and passed semantic validation.

Summary quality:

```text
trace_loss:                   none
circular_overwrite:           unknown
parser_completeness:          partial
evidence_completeness:        partial
measured_event_class_count:   8
failed_event_class_count:     0
process_count:                94
```

The eighth measured class is derived `soft_fault_total`.

The following classes remain explicit rather than inferred as zero:

```text
mapped_section_create: not_assessed
mapped_section_delete: not_assessed
```

Target identity was complete and bound to PID, process start UTC and executable SHA-256.

Target-process observed counts:

```text
hard_fault:           14
demand_zero_fault:    18661
copy_on_write_fault:  529
transition_fault:     15004
guard_page_fault:     114
soft_fault_total:     34308
virtual_allocation:   3816
virtual_free:         155
```

## Artifact integrity

Uploaded diagnostic archive:

```text
nxb-memory-real-capture-diagnostic-5ef11042146b-20260807-180600.zip
sha256: 1aadd69c06b509a037cb1e175967ae51fc120b81f657a2fb8690909357827b00
```

Uploaded review archive:

```text
nxb-memory-real-capture-5ef11042146b-20260807T150026Z-review.zip
sha256: 15c60f11acc1102ee8e1e4d57cc6312243cd409e8265afccba394f3ff1721323
```

The overlapping evidence files in the diagnostic and review archives were byte-for-byte identical. Selected evidence hashes:

```text
capture receipt:
0bd7b3e2f5421c4105ea1c9de2e978d885a0530494eafe46e055ace8340c14db

bridge manifest:
4bf3ff4896c752c58d513f846e414c66117a28fdd9777ee5b19aaea443e3fbde

memory ETL summary:
14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5

WPR pre-stop status:
9eaef84ac0cb4e2af9d57d1abd2a2e7a290bfcb159614f8986c23735c0a833c5
```

## Claims boundary

This validation proves that, on the observed Windows 10 build and exact implementation head, the repository can execute the bounded workload under WPR, stop to a real ETL, export the trace through xperf, normalize the observed real headers, and produce a semantically valid downstream memory ETL summary in one exact-head run.

It does **not** claim:

- trace completeness,
- absence of circular overwrite,
- deterministic hard-fault production,
- cache-state control,
- that missing event classes mean zero,
- mapped-section lifecycle coverage in this trace,
- virtual allocation/free byte balance,
- working set equals total scenario memory cost.

## Remaining closure work

The real capture vertical slice is validated. Remaining NXB-IRL-004 closure work is deliberately narrower:

1. paired control/capture overhead calibration;
2. decide whether circular-overwrite absence can be measured directly or must remain `unknown`;
3. canonical closeout record after calibration;
4. keep PR #9 draft/stacked until the parent PR and remaining closure gates are explicitly resolved.
