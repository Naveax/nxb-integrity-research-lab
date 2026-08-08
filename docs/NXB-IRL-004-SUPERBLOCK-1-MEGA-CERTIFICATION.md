# NXB-IRL-004 SUPERBLOCK 1 Mega Certification

SUPERBLOCK 1 now has a one-shot native Windows gate that deliberately batches the formerly separate metadata/adaptor, profile, real-capture, trace-quality, header-discovery, and first deterministic-replay stages.

## Gate chain

1. Existing selected-provider metadata + capability-adaptor certification.
2. Dual-runtime 10/10 multi-domain WPR profile contract plus native `wpr.exe` parse.
3. Dual-runtime 8/8 real-capture evidence-boundary contract plus PSScriptAnalyzer.
4. Real bounded WPR File-mode capture.
5. Local-only bounded workload: loopback TCP, localhost DNS, bounded registry read, bounded temporary file I/O, and child-process lifecycle.
6. Native post-stop ETL loss accounting through the repository `Get-NxbEtlTraceStatistics.ps1` adapter.
7. Full xperf dumper kept local; header-only inventory admitted to bounded review evidence.
8. Deterministic header-normalization replay; source and replay inventory JSON must be byte-identical.
9. Bounded mega review ZIP; raw ETL, full dumper, raw provider metadata, and full capability snapshot remain local.

## Multi-domain WPR profile

`profiles/Nxb.Superblock1MultiDomain.wprp` combines:

- kernel SystemProvider foundation keywords: `Loader`, `NetworkTrace`, `ProcessThread`, `Registry`;
- native-certified GPU provider masks already validated in the GPU profile gate;
- six native-certified network/kernel manifest-provider identities from the selected-provider metadata gate.

File mode uses two independently bounded circular collectors:

- SystemCollector: 256 KiB buffers, 64 buffers, 128 MiB circular maximum;
- EventCollector: 256 KiB buffers, 64 buffers, 128 MiB circular maximum.

The six network/kernel manifest providers intentionally do not encode individual keyword filters yet. The gate captures bounded provider output for host-shape discovery without promoting observed keyword names or event IDs into semantics.

## Native attempt history

### Attempt 1 — `a51064db2cb27b6b04f2b7cebc11329443a5edd8`

The first mega native run established that the chained prerequisite layers were sound:

- selected-provider metadata tests: 9/9;
- capability-adapter tests: 8/8;
- aggregate capture/adaptor gate: 17/17 on PowerShell 7 and 17/17 on Windows PowerShell 5.1;
- PSScriptAnalyzer: 0;
- all six selected provider GUIDs re-observed with measured keyword rows `3/10/20/12/17/25`;
- fresh full-system capability snapshot passed JSON Schema validation;
- capability collection errors: 0;
- multi-domain WPR profile tests: 10/10 on both PowerShell runtimes;
- native `wpr.exe` multi-domain profile parse: PASS.

The run stopped before any real ETL capture in the capture-contract Pester suite. A double-quoted PowerShell regex assertion used `"\$false"`; PowerShell expanded `$false`, producing the invalid regex fragment `\False`. This was a test-only literal-escaping defect, not a provider/profile/capture failure.

The repair at `58c406b28eba22dfd40067c5ce55c89826468a01` converts all literal `$false` source assertions in that test suite to `[regex]::Escape(...)`, preventing the same interpolation class from recurring across workload, review-policy, header-policy, and semantic-claim assertions.

## Evidence boundary

The mega gate may certify only:

- exact clean repository head;
- profile/provider identity binding;
- native WPR parse and successful real ETL creation;
- bounded workload completion;
- measured native loss counters;
- header-only xperf discovery;
- deterministic header-normalization replay;
- bounded evidence-package policy.

The following remain false or `not_claimed` until later evidence gates establish them:

```text
keyword_semantics_validated:         false
event_ids_validated:                 false
present_semantics:                   false
gpu_queue_semantics:                 false
network_connection_semantics:        false
network_latency_semantics:           false
kernel_lifecycle_semantics:          false
device_lifecycle_semantics:          false
power_thermal_representative:        false
firmware_security_effect_semantics:  false
circular_overwrite:                  unknown
trace_completeness:                  not_claimed
```

No controlled GPU workload is claimed by the foundation workload. Natural desktop GPU activity can be captured, but its presence is not treated as a controlled stimulus.

## Native success criteria

The gate is successful only when all static/runtime gates pass, the real ETL is produced, `EventsLost == 0`, `BuffersLost == 0`, `BuffersWritten > 0`, the header inventory is non-empty, the repeated header inventory is byte-identical, and the review ZIP contains no raw ETL/full dumper/provider/capability evidence.

The first successful native mega run becomes the evidence source for the next wide batch: domain-specific event normalization, replay, measured event-shape coverage, and semantic investigation without reopening the already-certified foundation contracts.
