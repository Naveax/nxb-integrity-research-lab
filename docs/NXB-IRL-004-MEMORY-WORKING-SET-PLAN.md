# NXB-IRL-004 — RAM, Page-Fault and Working-Set Capture Plan

## Status

`IN PROGRESS — COLLECTOR VALIDATED — ETL ADAPTER FOUNDATION IMPLEMENTED`

- Tracking issue: `#2`
- Parent draft PR: `#8 — trace-loss and circular-overwrite accounting`
- Parent closeout head: `6d67df571e4355bc1a87cb91c04b5e46800b268d`
- Stacked draft PR: `#9`
- Stacked branch: `nxb-irl-004-memory-working-set`
- Validated profile head: `d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773`
- Validated foundation head: `ae3debb4bf16276c08eb79dc3575ed7cf8ce5492`
- Validated native collector head: `d49aaef68da1e8be4141ccc55f032c13e211e64a`
- Profile validation record: `docs/NXB-IRL-004-MEMORY-PROFILE-VALIDATION.md`
- Foundation validation record: `docs/NXB-IRL-004-MEMORY-FOUNDATION-VALIDATION.md`
- Collector validation record: `docs/NXB-IRL-004-MEMORY-COLLECTOR-VALIDATION.md`

GitHub Actions remain intentionally disabled repository-wide. Native validation runs on a real Windows installation from elevated PowerShell 7.

## Objective

Add a bounded memory-observability domain that can explain:

- process working-set and private/commit changes,
- system physical-memory and commit state,
- hard and soft page-fault activity,
- virtual allocation/free and mapped-section lifecycle,
- page-in behavior that can later be correlated with storage and scheduler events,
- collector overhead and trace loss through the existing NXB-IRL-004 mechanisms.

All evidence remains bound to experiment, machine, boot, target, collector, trace and profile provenance. Unsupported or unavailable evidence is represented explicitly rather than synthesized as zero.

## Validated profile foundation

Profile:

```text
NxbMemoryWorkingSet
```

Variants:

```text
NxbMemoryWorkingSet.Verbose.File
NxbMemoryWorkingSet.Verbose.Memory
```

Bounded file collector:

```text
buffer_size_kib:       1024
buffers:               64
maximum_file_size_mib: 512
file_mode:             Circular
```

Exact head `d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773` passed:

- native `wpr.exe -profiles`,
- repository smoke,
- PowerShell parser,
- zero-finding PSScriptAnalyzer,
- PowerShell 7 Pester: 10/10,
- Windows PowerShell 5.1 Pester: 10/10.

Required kernel keywords:

```text
AllFaults
CpuConfig
HardFaults
Loader
Memory
MemoryInfo
MemoryInfoWS
ProcessCounter
ProcessThread
VAMap
VirtualAllocation
```

Required stack points:

```text
HardFault
ImageLoad
PagefaultHard
PagefileMappedSectionCreate
PagefileMappedSectionDelete
ProcessCreate
UnMapFile
VirtualAllocation
VirtualFree
```

`ReferenceSet` remains excluded from the minimal profile because working-set removal at capture start can materially perturb the scenario.

## Validated snapshot and collector foundation

Canonical snapshot contract:

```text
schemas/memory-snapshot.schema.json
tests/fixtures/memory-snapshot.valid.json
tools/validate_memory_snapshot.py
scripts/Test-MemorySnapshot.ps1
tests/MemorySnapshot.Tests.ps1
```

Native collector:

```text
scripts/New-NxbMemorySnapshot.ps1
tests/MemorySnapshotCollector.Tests.ps1
scripts/Invoke-NxbMemoryCollectorLocalValidation.ps1
```

The collector binds the target to PID, process-start UTC and executable SHA-256. It uses `GetPerformanceInfo` for system physical-memory and commit evidence and `GetProcessMemoryInfo` for working set, private usage, pagefile usage and cumulative page-fault count. Hard/soft fault attribution remains explicitly `not_assessed` until ETW evidence exists.

Exact head `d49aaef68da1e8be4141ccc55f032c13e211e64a` passed on real elevated Windows:

```text
profile tests:
  PowerShell 7:             10/10
  Windows PowerShell 5.1:  10/10

snapshot-contract tests:
  PowerShell 7:              9/9
  Windows PowerShell 5.1:    9/9

native collector tests:
  PowerShell 7:              7/7
  Windows PowerShell 5.1:    7/7
```

Review artifact:

```text
nxb-memory-collector-d49aaef68da1-20260806T222934Z-review.zip
sha256: ed8ec6191be105cc78abbe7cccbc180b285ca7864f774d663122b21760647a92
```

## ETL memory-event adapter foundation

Canonical summary contract:

```text
schemas/memory-etl-summary.schema.json
tests/fixtures/memory-etl-summary.valid.json
tools/validate_memory_etl_summary.py
scripts/Test-MemoryEtlSummary.ps1
tests/MemoryEtlSummary.Tests.ps1
```

Canonical normalized event-export adapter:

```text
scripts/ConvertFrom-NxbMemoryEventExport.ps1
tests/fixtures/memory-event-export.valid.csv
tests/MemoryEventExportAdapter.Tests.ps1
scripts/Invoke-NxbMemoryEtlAdapterLocalValidation.ps1
```

The adapter contract keeps these event classes separate:

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

The adapter does not infer coverage from absent rows. `CoveredEventType` is mandatory. Only declared classes can become `measured`; undeclared classes remain `not_assessed`. `soft_fault_total` is derived only when all four soft-fault component classes are covered.

Each summary binds:

- experiment-relative identity,
- machine and boot identity,
- target PID, start time and image SHA-256,
- trace, profile, normalized export and adapter SHA-256,
- trace start/end UTC,
- trace-loss and circular-overwrite state,
- aggregate and per-process counts,
- unattributed counts and attribution quality,
- narrow non-absence and non-completeness claims.

The semantic validator rejects:

- invalid trace ranges,
- duplicate process identities,
- a partial target identity,
- aggregate/process count mismatches,
- invalid unattributed counts,
- soft totals inconsistent with component classes,
- measured classes marked unsupported,
- summary counts inconsistent with evidence states,
- unsupported absence, balance or completeness claims.

This foundation consumes the repository-owned normalized CSV contract. It does **not** yet claim direct raw ETL/xperf-dumper integration or real ETW-derived counts.

## Validation architecture

Profile-only runner:

```text
scripts/Invoke-NxbMemoryProfileLocalValidation.ps1
```

Profile + snapshot-contract runner:

```text
scripts/Invoke-NxbMemoryFoundationLocalValidationV2.ps1
```

Profile + snapshot + native collector runner:

```text
scripts/Invoke-NxbMemoryCollectorLocalValidation.ps1
```

Collector + ETL adapter runner:

```text
scripts/Invoke-NxbMemoryEtlAdapterLocalValidation.ps1
```

The ETL runner adds these gates:

- nested exact-head collector validation,
- Python semantic-validator compile,
- PowerShell parser,
- zero-finding PSScriptAnalyzer,
- canonical schema and semantic contract,
- PowerShell 7 ETL contract/adapter Pester matrix,
- Windows PowerShell 5.1 ETL contract/adapter Pester matrix,
- combined JSON summary and review ZIP.

## Planned vertical slices

### Slice 1 — profile foundation

- [x] Define bounded profile contract.
- [x] Commit the WPR profile.
- [x] Add exact safe-XML validation and adversarial tests.
- [x] Pass native WPR and two-runtime Windows validation.
- [x] Record exact-head evidence.

### Slice 2 — snapshot and native collector

- [x] Define the Draft 2020-12 snapshot schema.
- [x] Add process/system memory snapshot collector.
- [x] Preserve measured, unsupported, unavailable, failed and not-assessed states.
- [x] Bind measured fields to collector provenance.
- [x] Add semantic validation and adversarial tests.
- [x] Pass combined exact-head Windows validation.
- [x] Record exact-head collector evidence.

### Slice 3 — ETL memory-event adapter

- [x] Define the memory ETL summary schema.
- [x] Add a canonical normalized event-export contract.
- [x] Separate hard faults and soft-fault component classes.
- [x] Add virtual allocation/free and mapped-section lifecycle classes.
- [x] Bind trace, profile, export and adapter provenance.
- [x] Add coverage-aware aggregate/process reconciliation.
- [x] Add semantic and adversarial tests.
- [x] Add exact-head Windows validation runner.
- [ ] Pass the ETL adapter Windows matrix.
- [ ] Add a raw ETL/xperf export bridge into the normalized event contract.
- [ ] Validate real ETW-derived memory-event evidence.

### Slice 4 — bounded deterministic fixture

- [ ] Add a safe memory-pressure workload with strict allocation and duration limits.
- [ ] Exercise demand-zero, copy-on-write, mapped-file and bounded hard-fault paths.
- [ ] Record deterministic workload checksum and lifecycle evidence.
- [ ] Guarantee cleanup on timeout or failure.

### Slice 5 — calibration and exact-head closure

- [ ] Reuse paired control/capture overhead calibration.
- [ ] Reuse trace-loss and circular-overwrite accounting.
- [ ] Run elevated real-Windows WPR capture with the bounded fixture.
- [ ] Inspect the complete review archive.
- [ ] Write canonical end-to-end closeout evidence.

## Immediate validation gate

Run the ETL adapter exact-head Windows validator against the current branch head. Do not mark the ETL foundation validated until:

- the nested collector matrix passes,
- both PowerShell runtimes pass all ETL contract and adapter tests,
- PSScriptAnalyzer reports zero findings,
- the final summary status is `passed`,
- the review ZIP is inspected and hashed.

## Safety and public-repository boundary

Never commit:

- raw ETL,
- memory dumps,
- page files,
- protected binaries,
- private keys or credentials,
- undisclosed findings.

The bounded fixture must not attempt system-wide exhaustion, disable memory protections, manipulate another process or silently flush working sets.

## Completion gate

This block is complete only when:

- the exact profile passes the native WPR parser,
- snapshot, collector and ETL contracts pass in PowerShell 7 and Windows PowerShell 5.1,
- real hard/soft fault and virtual-memory evidence is collected from a bounded Windows capture,
- collector overhead and trace loss are measured,
- unsupported fields remain explicit,
- final claims remain narrow and do not claim total-memory-cost or trace completeness.
