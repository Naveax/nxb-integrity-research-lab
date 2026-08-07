# NXB-IRL-004 — RAM, Page-Fault and Working-Set Capture Plan

## Status

`IN PROGRESS — REAL END-TO-END CAPTURE VALIDATED — CALIBRATION/CLOSEOUT REMAINING`

- Tracking issue: `#2`
- Parent draft PR: `#8 — trace-loss and circular-overwrite accounting`
- Parent closeout head: `6d67df571e4355bc1a87cb91c04b5e46800b268d`
- Stacked draft PR: `#9`
- Stacked branch: `nxb-irl-004-memory-working-set`
- Validated profile head: `d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773`
- Validated foundation head: `ae3debb4bf16276c08eb79dc3575ed7cf8ce5492`
- Validated native collector head: `d49aaef68da1e8be4141ccc55f032c13e211e64a`
- Validated normalized ETL adapter head: `d9502f8f69419ec12a6ae43e79c83f14b6113ef2`
- Validated raw bridge head: `c9ec8cf498d8bebb992be865f2c76fd496d4b8c1`
- Validated real end-to-end capture implementation head: `5ef11042146ba4d964ce553edd02a0f6329732e6`

Validation records:

```text
docs/NXB-IRL-004-MEMORY-PROFILE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-FOUNDATION-VALIDATION.md
docs/NXB-IRL-004-MEMORY-COLLECTOR-VALIDATION.md
docs/NXB-IRL-004-MEMORY-ETL-ADAPTER-VALIDATION.md
docs/NXB-IRL-004-MEMORY-RAW-BRIDGE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-REAL-CAPTURE-VALIDATION.md
```

GitHub Actions remain intentionally disabled repository-wide. Native validation runs locally on a real elevated Windows installation.

## Objective

The memory domain must provide bounded, provenance-bound evidence for:

- process working-set and private/commit state,
- system physical-memory and commit state,
- hard and soft page-fault activity,
- virtual allocation/free activity,
- mapped-section lifecycle when actually observed,
- trace loss and capture-quality state,
- collector/capture overhead before final closeout.

Unsupported or unavailable evidence remains explicit. Missing evidence is never synthesized as zero.

## Validated profile and collector foundation

Profile:

```text
NxbMemoryWorkingSet
```

Validated bounded file collector:

```text
buffer_size_kib:       1024
buffers:               64
maximum_file_size_mib: 512
file_mode:             Circular
```

The profile passed native WPR parsing and two-runtime PowerShell validation. The native snapshot collector binds the target to PID, process-start UTC and executable SHA-256 and records system/process memory counters without reading arbitrary process memory.

Validated Windows matrices include:

```text
profile:
  PowerShell 7:             10/10
  Windows PowerShell 5.1:  10/10

snapshot contract:
  PowerShell 7:              9/9
  Windows PowerShell 5.1:    9/9

native collector:
  PowerShell 7:              7/7
  Windows PowerShell 5.1:    7/7

normalized ETL adapter:
  PowerShell 7:             18/18
  Windows PowerShell 5.1:   18/18

raw xperf bridge:
  PowerShell 7:              9/9
  Windows PowerShell 5.1:    9/9
```

## Normalized memory-event contract

Canonical event classes:

```text
hard_fault
demand_zero_fault
copy_on_write_fault
transition_fault
guard_page_fault
soft_fault_total
virtual_allocation
virtual_free
mapped_section_create
mapped_section_delete
```

`CoveredEventType` is mandatory. Only observed/declared classes may become `measured`. `soft_fault_total` is derived only when all four component classes are covered.

The downstream summary binds:

- experiment identity,
- machine and boot identity,
- target PID/start/image SHA-256,
- trace/profile/export/adapter SHA-256,
- trace start/end UTC,
- trace loss,
- circular-overwrite state,
- aggregate and per-process event evidence,
- attribution quality,
- narrow fail-closed claims.

## Real xperf bridge behavior

The bridge now handles the real Windows xperf dumper format observed on Windows 10 build 19045:

- streaming ANSI-tolerant decode;
- no full-dumper memory load;
- `VirtualAlloc`/`VirtualFree` size from `EndAddr - BaseAddr` when no explicit size field exists;
- dedicated `HardFault` size from `IOSize`;
- generic `PageFault.Type` mapping for:
  - `DemandZero` → `demand_zero_fault`
  - `CopyOnWrite` → `copy_on_write_fault`
  - `Transition` → `transition_fault`
  - `GuardPage` → `guard_page_fault`
- generic `PageFault.Type=HardFault` remains unmapped whenever the dedicated hard-fault stream is used, preventing possible double counting.

Parser completeness remains `not_claimed` at the raw-bridge layer.

## Validated bounded real capture

Exact implementation head:

```text
5ef11042146ba4d964ce553edd02a0f6329732e6
```

The single exact-head V11 run passed:

```text
PowerShell parser
PSScriptAnalyzer: 0 findings
Python normalizer py_compile
memory profile contract
native wpr.exe profile parse
bounded workload runtime smoke
real WPR start/workload/stop
real ETL creation
xperf dumper export
real-header normalization
downstream memory ETL summary validation
header-only inventory
```

Bounded workload:

```text
private allocation: 32 MiB
mapped file:        8 MiB
hold:               1000 ms
page stride:        4096 bytes
```

Native trace-quality evidence:

```text
Dropped event: 0
Events Lost:   0
trace_loss:    none
```

Conservative quality boundary:

```text
circular_overwrite:  unknown
trace_completeness:  not_claimed
```

The exact-head run normalized `265258` real events and measured these aggregate classes:

```text
hard_fault:           372
demand_zero_fault:    125532
copy_on_write_fault:  3563
transition_fault:     106197
guard_page_fault:     591
soft_fault_total:     235883
virtual_allocation:   23683
virtual_free:         5320
```

The downstream summary reported:

```text
measured_event_class_count: 8
failed_event_class_count:   0
parser_completeness:        partial
evidence_completeness:      partial
process_count:              94
```

Target identity was complete. `mapped_section_create` and `mapped_section_delete` remained `not_assessed` because they were not covered by the observed normalized trace.

Review artifact:

```text
nxb-memory-real-capture-5ef11042146b-20260807T150026Z-review.zip
sha256: 15c60f11acc1102ee8e1e4d57cc6312243cd409e8265afccba394f3ff1721323
```

Diagnostic artifact:

```text
nxb-memory-real-capture-diagnostic-5ef11042146b-20260807-180600.zip
sha256: 1aadd69c06b509a037cb1e175967ae51fc120b81f657a2fb8690909357827b00
```

Raw ETL and full xperf dumper remain local and are not part of the review archive.

## Vertical slices

### Slice 1 — profile foundation

- [x] Define bounded WPR profile.
- [x] Add exact XML/native WPR validation.
- [x] Pass PowerShell 7 and 5.1 validation.
- [x] Record exact-head evidence.

### Slice 2 — snapshot and native collector

- [x] Define snapshot schema.
- [x] Add native process/system memory collector.
- [x] Preserve explicit evidence states.
- [x] Bind target and collector provenance.
- [x] Pass exact-head Windows validation.

### Slice 3 — normalized ETL adapter and raw bridge

- [x] Define memory ETL summary schema.
- [x] Define normalized event-export contract.
- [x] Pass ETL adapter Windows matrix.
- [x] Add raw xperf dumper bridge.
- [x] Pass raw-bridge Windows matrix.
- [x] Inspect real xperf headers.
- [x] Add real Windows ANSI streaming decode.
- [x] Add real soft-fault mapping.
- [x] Preserve no-double-count hard-fault boundary.

### Slice 4 — bounded real workload and capture

- [x] Add strict private/mapped allocation limits.
- [x] Add bounded duration and child timeout.
- [x] Record workload checksum and lifecycle evidence.
- [x] Guarantee own temporary mapped-file cleanup.
- [x] Run elevated real-Windows WPR capture.
- [x] Produce native ETL and xperf dumper locally.
- [x] Normalize real hard/soft/virtual-memory evidence.
- [x] Produce and validate downstream summary in the same exact-head run.
- [x] Record exact-head end-to-end evidence.

### Slice 5 — calibration and closure

- [ ] Run paired control/capture overhead calibration.
- [x] Record native trace-loss counters for the real capture.
- [ ] Determine whether circular-overwrite absence can be measured directly; otherwise retain `unknown`.
- [ ] Write canonical NXB-IRL-004 memory closeout after calibration.

## Immediate next gate

The next mandatory gate is **paired overhead calibration**, not another parser or WPR smoke run.

Calibration must preserve the same bounded workload parameters and compare a control path against the WPR capture path without changing the workload contract. It must report overhead rather than infer it from a single run.

Do not mark the memory block fully closed until calibration is recorded and the circular-overwrite boundary is resolved or explicitly accepted as `unknown`.

## Safety and public-repository boundary

Never commit:

- raw ETL,
- full xperf dumper text,
- memory dumps,
- page files,
- protected binaries,
- private keys or credentials,
- undisclosed findings.

The workload must not attempt system-wide exhaustion, disable memory protections, manipulate another process, or silently flush working sets.

## Completion gate

This block is complete only when:

- all validated profile/snapshot/collector/ETL/raw-bridge gates remain green,
- the exact-head real capture remains recorded,
- paired control/capture overhead is measured,
- trace-loss state is recorded,
- circular-overwrite state is either directly measured or explicitly retained as unknown,
- unsupported fields remain explicit,
- final claims do not assert total-memory-cost or trace completeness.
