# NXB-IRL-004 — RAM, Page-Fault and Working-Set Capture Plan

## Status

`IN PROGRESS — INITIAL PROFILE CONTRACT`

- Tracking issue: `#2`
- Parent draft PR: `#8 — trace-loss and circular-overwrite accounting`
- Parent closeout head: `6d67df571e4355bc1a87cb91c04b5e46800b268d`
- Stacked branch: `nxb-irl-004-memory-working-set`

GitHub Actions remain intentionally disabled repository-wide. Native validation must run on a real Windows installation from an elevated PowerShell 7 shell.

## Objective

Add a bounded memory-observability capture domain that can explain:

- process working-set and private/commit changes,
- system memory pressure,
- hard and soft page-fault activity,
- virtual allocation/free and mapped-region lifecycle,
- page-in behavior that can later be correlated with storage and scheduler events,
- collector overhead and trace loss through the already implemented NXB-IRL-004 mechanisms.

All evidence must remain bound to experiment, machine, boot, profile and ETL provenance. Unsupported or unavailable measurements must be represented explicitly rather than synthesized as zero.

## First implementation slice

The first slice establishes a repository-owned WPR profile and exact structural validator before any ETL parser or memory evidence schema is accepted.

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

The minimal profile records soft-fault events but does not require stacks for every soft-fault subtype. Soft-fault stack capture is intentionally deferred until native overhead and event-rate measurements justify it.

## Reference-set boundary

`ReferenceSet` is deliberately excluded from the minimal profile.

Reference-set tracing removes pages from process working sets at capture start and can materially perturb system behavior. It belongs only in a short, explicit, focused diagnostic mode with separate operator acknowledgement, overhead calibration and result classification. It must not be silently enabled by the normal RAM/page-fault profile.

## Evidence separation

The memory domain will keep the following evidence classes separate:

1. **Process footprint evidence**
   - working set,
   - private bytes,
   - commit/private commit where supported,
   - virtual allocation and mapped-region lifecycle.
2. **Fault evidence**
   - hard faults,
   - transition faults,
   - demand-zero faults,
   - copy-on-write faults,
   - guard/access-violation events where exposed.
3. **System pressure evidence**
   - free, used, standby and modified page state where exposed,
   - commit limit and committed bytes,
   - paging and compression activity where exposed.
4. **Scenario reference-set evidence**
   - excluded from minimal mode,
   - future focused diagnostic only.

A process working set is a point-in-time resident-set measurement and must not be presented as the total system-wide cost of a scenario.

## Planned vertical slices

### Slice 1 — profile foundation

- [x] Define bounded profile contract.
- [ ] Commit `profiles/Nxb.MemoryWorkingSet.wprp`.
- [ ] Add exact safe-XML contract validator.
- [ ] Add PowerShell 7 / Windows PowerShell 5.1 adversarial tests.
- [ ] Add native `wpr.exe -profiles` validation.

### Slice 2 — memory snapshot contract

- [ ] Define Draft 2020-12 memory evidence schema.
- [ ] Add process and system memory snapshot collector.
- [ ] Distinguish measured, unsupported, unavailable and failed fields.
- [ ] Bind snapshot to observation identity and tool provenance.
- [ ] Add semantic validator and canonical fixture.

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
