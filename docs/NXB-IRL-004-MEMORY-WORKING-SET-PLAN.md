# NXB-IRL-004 — RAM, Page-Fault and Working-Set Capture Plan

## Status

`IN PROGRESS — PROFILE VALIDATED — SNAPSHOT CONTRACT IMPLEMENTED`

- Tracking issue: `#2`
- Parent draft PR: `#8 — trace-loss and circular-overwrite accounting`
- Parent closeout head: `6d67df571e4355bc1a87cb91c04b5e46800b268d`
- Stacked draft PR: `#9`
- Stacked branch: `nxb-irl-004-memory-working-set`
- Validated profile head: `d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773`
- Profile validation record: `docs/NXB-IRL-004-MEMORY-PROFILE-VALIDATION.md`

GitHub Actions remain intentionally disabled repository-wide. Native validation must run on a real Windows installation from an elevated PowerShell 7 shell.

## Objective

Add a bounded memory-observability capture domain that can explain:

- process working-set and private/commit changes,
- system memory pressure,
- hard and soft page-fault activity,
- virtual allocation/free and mapped-region lifecycle,
- page-in behavior that can later be correlated with storage and scheduler events,
- collector overhead and trace loss through the existing NXB-IRL-004 mechanisms.

All evidence must remain bound to experiment, machine, boot, collector and profile provenance. Unsupported or unavailable measurements must be represented explicitly rather than synthesized as zero.

## Validated profile foundation

Profile name:

```text
NxbMemoryWorkingSet
```

Profile variants:

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

The matching memory-mode collector uses the same buffer size and count but does not declare `MaximumFileSize`.

Exact head `d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773` passed:

- native `wpr.exe -profiles`,
- repository smoke,
- PowerShell parser,
- PSScriptAnalyzer,
- PowerShell 7 Pester: 10/10,
- Windows PowerShell 5.1 Pester: 10/10.

## Minimal kernel event contract

Required system keywords:

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

The minimal profile records soft-fault events but does not require stacks for every soft-fault subtype. Soft-fault stack capture remains deferred until native overhead and event-rate measurements justify it.

## Reference-set boundary

`ReferenceSet` is deliberately excluded from the minimal profile.

Reference-set tracing removes pages from process working sets at capture start and can materially perturb system behavior. It belongs only in a short, explicit, focused diagnostic mode with separate operator acknowledgement, overhead calibration and result classification. It must not be silently enabled by the normal RAM/page-fault profile.

## Evidence separation

The memory domain keeps the following evidence classes separate:

1. **Process footprint evidence**
   - working set and peak working set,
   - private bytes,
   - paged memory,
   - virtual size and peak virtual size.
2. **Fault evidence**
   - cumulative process page-fault count,
   - hard and soft fault attribution from future ETW summaries,
   - explicit non-measured state until ETW evidence exists.
3. **System pressure evidence**
   - total and available physical memory,
   - commit limit and commit use,
   - standby, modified and compression-store state where exposed.
4. **Scenario reference-set evidence**
   - excluded from minimal mode,
   - future focused diagnostic only.

A process working set is a point-in-time resident-set measurement and must not be presented as the total system-wide cost of a scenario.

## Canonical memory snapshot contract

The canonical contract is:

```text
schemas/memory-snapshot.schema.json
tests/fixtures/memory-snapshot.valid.json
tools/validate_memory_snapshot.py
scripts/Test-MemorySnapshot.ps1
tests/MemorySnapshot.Tests.ps1
```

Every measurement has:

```text
status: measured | unsupported | unavailable | failed | not_assessed
value:  non-negative integer or null
unit:   bytes | count
source: hash-bound collector provenance or null
reason: null for measured, required text otherwise
```

The schema requires:

- experiment, machine, boot and target-process identity,
- captured UTC time,
- seven system-memory measurements,
- nine per-process memory/fault measurements,
- exact measured/failed summary counts,
- evidence-completeness classification,
- narrow claim constants.

The semantic validator rejects:

- mismatched experiment-relative paths,
- process start times after capture,
- available physical memory greater than total physical memory,
- commit use greater than commit limit,
- duplicate process identities,
- target identity/flag mismatch,
- current working set greater than peak working set,
- current virtual size greater than peak virtual size,
- hard or soft fault counts greater than total page-fault count,
- summary counts inconsistent with measurement states,
- non-measured fields that retain numeric values,
- claims that working set equals total memory cost,
- claims of memory-pressure absence, page-fault absence or capture completeness.

## Validation architecture

Profile-only exact-head validation:

```text
scripts/Invoke-NxbMemoryProfileLocalValidation.ps1
```

Combined profile + snapshot-contract validation:

```text
scripts/Invoke-NxbMemoryFoundationLocalValidation.ps1
```

Combined gates:

- Python `jsonschema` availability or bootstrap,
- nested exact-head bounded-profile validation,
- snapshot PowerShell parser,
- snapshot PSScriptAnalyzer,
- schema and semantic contract validation,
- PowerShell 7 snapshot Pester,
- Windows PowerShell 5.1 snapshot Pester,
- combined JSON summary and review ZIP.

The current foundation head must pass this combined runner before Slice 2 is considered validated.

## Planned vertical slices

### Slice 1 — profile foundation

- [x] Define bounded profile contract.
- [x] Commit `profiles/Nxb.MemoryWorkingSet.wprp`.
- [x] Add exact safe-XML contract validator.
- [x] Add PowerShell 7 / Windows PowerShell 5.1 adversarial tests.
- [x] Pass native `wpr.exe -profiles` validation.
- [x] Record exact-head Windows evidence.

### Slice 2 — memory snapshot contract

- [x] Define Draft 2020-12 memory evidence schema.
- [ ] Add process and system memory snapshot collector.
- [x] Distinguish measured, unsupported, unavailable, failed and not-assessed fields.
- [x] Bind each measured value to collector provenance.
- [x] Add semantic validator and canonical fixture.
- [x] Add adversarial snapshot tests.
- [ ] Pass combined exact-head Windows validation.

### Slice 3 — ETL memory event adapter

- [ ] Parse hard/soft fault classes without inventing missing counts.
- [ ] Parse virtual allocation/free and mapped-region lifecycle.
- [ ] Bind events to process/thread and common timeline identity.
- [ ] Reconcile ETL SHA-256, profile provenance and trace-loss state.

### Slice 4 — bounded deterministic fixture

- [ ] Add a safe memory-pressure workload with strict allocation and duration limits.
- [ ] Exercise demand-zero, copy-on-write, mapped-file and bounded hard-fault paths.
- [ ] Record deterministic workload checksum and lifecycle evidence.
- [ ] Guarantee cleanup on timeout or failure.

### Slice 5 — calibration and exact-head closure

- [ ] Reuse paired control/capture overhead calibration.
- [ ] Reuse trace-loss and circular-overwrite accounting.
- [ ] Run full PowerShell 7 and Windows PowerShell 5.1 matrices.
- [ ] Run elevated real-Windows WPR validation.
- [ ] Inspect review ZIP and write canonical closeout record.

## Next implementation slice

Implement the process and system memory snapshot collector.

Required behavior:

- target an explicit process identity rather than process name alone,
- bind target identity to PID, start time and executable hash,
- gather physical-memory and commit measurements,
- gather process working-set, peak, private, virtual, paged-memory and page-fault counters,
- preserve inaccessible metrics as explicit non-measured states,
- avoid dumps and arbitrary process-memory reads,
- write schema-valid evidence beneath the experiment root,
- retain collector and schema SHA-256 provenance,
- add deterministic fixtures and PS7/PS5.1 adversarial tests.

## Safety and public-repository boundary

Never commit:

- raw ETL,
- memory dumps,
- page files,
- protected binaries,
- private keys or credentials,
- undisclosed findings.

The bounded fixture must not attempt system-wide exhaustion, disable memory protections, manipulate another process, or use reference-set working-set flushing without an explicit focused-mode contract.

## Completion gate

This block is complete only when:

- the exact profile passes the native WPR parser,
- all schema and semantic checks pass,
- PowerShell 7 and Windows PowerShell 5.1 test matrices pass,
- real hard/soft fault and memory-pressure evidence is collected on Windows,
- collector overhead and trace loss are measured,
- all unsupported fields remain explicit,
- the final evidence retains narrow claims and does not claim total memory-cost completeness.
