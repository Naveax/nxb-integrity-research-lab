# NXB-IRL-004 — RAM, Page-Fault and Working-Set Capture Plan

## Status

`IMPLEMENTATION VALIDATED — MEMORY BLOCK CLOSED — STACKED DRAFT MERGE BOUNDARY REMAINS`

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
- Validated real end-to-end capture head: `5ef11042146ba4d964ce553edd02a0f6329732e6`
- Validated exact downstream replay head: `d895f4819cf31cc4e89c04fa7b9e02f11136b7d5`
- Validated memory overhead calibration head: `dd3b8016091c40dfea6364076888f022a0d782d3`

Validation and closeout records:

```text
docs/NXB-IRL-004-MEMORY-PROFILE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-FOUNDATION-VALIDATION.md
docs/NXB-IRL-004-MEMORY-COLLECTOR-VALIDATION.md
docs/NXB-IRL-004-MEMORY-ETL-ADAPTER-VALIDATION.md
docs/NXB-IRL-004-MEMORY-RAW-BRIDGE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-REAL-CAPTURE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-DOWNSTREAM-REPLAY-VALIDATION.md
docs/NXB-IRL-004-MEMORY-OVERHEAD-CALIBRATION-VALIDATION.md
docs/NXB-IRL-004-MEMORY-CLOSEOUT.md
```

GitHub Actions remain intentionally disabled repository-wide. Native validation runs locally on real Windows.

## Objective

The memory domain provides bounded, provenance-bound evidence for:

- process working-set and private/commit state,
- system physical-memory and commit state,
- hard and soft page-fault activity,
- virtual allocation/free activity,
- mapped-section lifecycle when actually observed,
- trace-loss and capture-quality state,
- collector/capture overhead.

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

The downstream summary binds experiment, machine/boot, target PID/start/image, trace/profile/export/adapter hashes, trace timing, trace-loss/circular-overwrite state, aggregate/per-process evidence, attribution quality and conservative claims.

## Real xperf bridge behavior

The bridge handles the observed real Windows xperf dumper format with streaming ANSI-tolerant decoding and no full-dumper memory load.

Mappings include:

```text
DemandZero   -> demand_zero_fault
CopyOnWrite  -> copy_on_write_fault
Transition   -> transition_fault
GuardPage    -> guard_page_fault
```

Dedicated `HardFault` uses `IOSize`; generic `PageFault.Type=HardFault` remains unmapped when the dedicated stream is present, preventing possible double counting.

## Validated bounded real capture

Exact implementation head:

```text
5ef11042146ba4d964ce553edd02a0f6329732e6
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

The exact-head run normalized `265258` real events:

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

`mapped_section_create` and `mapped_section_delete` remained `not_assessed` because those classes were not covered.

Review archive:

```text
nxb-memory-real-capture-5ef11042146b-20260807T150026Z-review.zip
sha256: 15c60f11acc1102ee8e1e4d57cc6312243cd409e8265afccba394f3ff1721323
```

## Validated exact downstream replay

Replay head:

```text
d895f4819cf31cc4e89c04fa7b9e02f11136b7d5
```

The repository-native replay passed 6/6 Pester tests, zero PSScriptAnalyzer findings and reproduced the preserved real summary byte-for-byte:

```text
normalized_event_count: 265258
source_summary_sha256: 14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5
replay_summary_sha256: 14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5
byte_identical_summary: true
```

## Validated paired memory overhead calibration

Canonical exact-head calibration:

```text
dd3b8016091c40dfea6364076888f022a0d782d3
```

Protocol:

```text
warmups:       1
pairs:         3
ordering:      alternating_control_first
private:       32 MiB
mapped:        8 MiB
hold:          1000 ms
sample:        25 ms
cooldown:      1 s
threshold:     not_declared
```

Canonical gates:

```text
PowerShell parser:                PASS
PSScriptAnalyzer:                 0 findings
Memory calibration Pester:       8/8
Native WPR profile parse:        PASS
EvidenceStore source dependency: PASS
Harness dependency injection:    none
```

Result:

```text
successful pairs: 3
failed pairs:     0
```

Median measured deltas:

```text
duration:           +1.700128930209937 %
CPU time:          +54.54545454545454 %
peak working set:   +1.3916161529924016 %
peak private bytes: -0.664332063034298 %
```

No production threshold is inferred from this bounded three-pair run.

Review archive:

```text
nxb-memory-overhead-calibration-dd3b8016091c-20260807T214351Z-review.zip
sha256: 2f0c7110fd83a0026377ac8c281a1afd38f8ae8235dc037626adefc05d8e4832
```

Raw calibration ETLs remain local.

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

- [x] Run paired control/capture overhead calibration.
- [x] Record native trace-loss counters for the real capture.
- [x] Determine circular-overwrite absence is not directly provable by the current contract; retain `unknown`.
- [x] Write canonical NXB-IRL-004 memory closeout.

## Circular-overwrite decision

The parent trace-loss contract may classify circular-buffer pressure, but even `no_risk_observed` is explicitly not proof that circular overwrite did not occur.

Therefore the memory closeout intentionally retains:

```text
circular_overwrite: unknown
claims.circular_overwrite_absence: false
trace_completeness: not_claimed
```

This is a resolved evidence boundary, not a pending implementation failure.

## Immediate next gate

There is no remaining memory-domain implementation gate.

The next repository operation is stack management: keep PR #9 open/draft on PR #8 until the parent is explicitly merged, then advance the stack under exact-head control. Do not rerun native memory calibration merely because documentation-only commits advance the branch head.

## Safety and public-repository boundary

Never commit raw ETL, full xperf dumper text, memory dumps, page files, protected binaries, credentials or undisclosed findings.

The workload must not attempt system-wide exhaustion, disable memory protections, manipulate another process or silently flush working sets.

## Completion gate

The memory block is complete because:

- all profile/snapshot/collector/ETL/raw-bridge gates are recorded,
- exact-head real capture is recorded,
- deterministic downstream replay is recorded,
- paired control/capture overhead is measured,
- trace-loss state is recorded,
- circular-overwrite absence is explicitly not claimed and remains `unknown`,
- unsupported fields remain explicit,
- final claims do not assert total-memory-cost or trace completeness.

PR #9 itself remains a stacked draft; implementation completion does not override the parent merge boundary.