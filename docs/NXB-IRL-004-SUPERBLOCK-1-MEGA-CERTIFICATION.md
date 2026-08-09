# NXB-IRL-004 SUPERBLOCK 1 Mega Certification

SUPERBLOCK 1 batches metadata/adaptor validation, profile validation, native provider enableability, real capture, trace-quality accounting, header discovery, and first deterministic replay into one Windows exact-head gate.

## Current candidate

```text
239a1b3c37b4b3b60b5eacfa7c904ac869be6c30
```

## Gate chain

1. Existing selected-provider metadata + capability-adaptor certification.
2. Dual-runtime multi-domain WPR profile contract plus native `wpr.exe` parse.
3. Dual-runtime real-capture evidence-boundary contract plus PSScriptAnalyzer.
4. Dual-runtime provider enable-matrix contract.
5. Eight single-provider native WPR start probes with `Strict=true`.
6. Resilient combined WPR File-mode capture with event providers explicitly `Strict=false`.
7. Local-only bounded workload: loopback TCP, localhost DNS, bounded registry read, bounded temporary file I/O, and child-process lifecycle.
8. Native post-stop ETL loss accounting through `Get-NxbEtlTraceStatistics.ps1`.
9. Full xperf dumper kept local; header-only inventory admitted to bounded review evidence.
10. Deterministic header-normalization replay; source and replay inventory JSON must be byte-identical.
11. Bounded mega review ZIP; raw ETL, full dumper, raw provider metadata, capability snapshot, probe WPRP files, and raw WPR start output remain local.

## Multi-domain WPR profile

`profiles/Nxb.Superblock1MultiDomain.wprp` combines:

- SystemProvider foundation keywords: `Loader`, `NetworkTrace`, `ProcessThread`, `Registry`;
- native-certified GPU provider masks from the GPU profile gate;
- six native-certified network/kernel manifest-provider identities from the selected-provider metadata gate.

File mode uses two independently bounded circular collectors:

- SystemCollector: 256 KiB buffers, 64 buffers, 128 MiB circular maximum;
- EventCollector: 256 KiB buffers, 64 buffers, 128 MiB circular maximum.

The six network/kernel manifest providers intentionally do not encode individual keyword filters yet. Event/timing semantics remain unpromoted.

### Strict-provider policy

Single-provider enable probes use `Strict=true`: each probe answers whether that exact configured provider can be enabled by WPR on the host at that moment. A failed probe records `unavailable`; it does not imply provider absence, event-delivery absence, or semantic absence.

The combined capture uses `Strict=false` for all eight event providers. This is deliberate. WPR documents that a strict provider enable failure rolls back the recording, while a non-strict provider failure permits the recording to continue with providers that can start. The separate enable matrix preserves explicit per-provider evidence, so resilience does not hide a missing provider.

## Native attempt history

### Attempt 1 — `a51064db2cb27b6b04f2b7cebc11329443a5edd8`

Established:

- selected-provider metadata 9/9;
- capability adapter 8/8;
- aggregate capture/adaptor gate 17/17 on both PowerShell runtimes;
- PSScriptAnalyzer 0;
- six provider GUIDs re-observed with measured keyword rows `3/10/20/12/17/25`;
- fresh capability snapshot schema PASS and collection errors 0;
- multi-domain profile 10/10 on both runtimes;
- native WPR profile parse PASS.

It stopped before capture because a test used a double-quoted `"\$false"` regex. PowerShell expanded `$false`, yielding invalid `\False`. The repair changed all such literal assertions to `[regex]::Escape(...)`.

### Attempt 2 — `5b3b451be86f433dd73704562a563f6d479b3cff`

Repeated all prerequisite native gates successfully:

- capture/adaptor 17/17 + 17/17;
- selected-provider metadata re-measured at `3/10/20/12/17/25` keyword rows;
- capability snapshot schema PASS; collection errors 0;
- multi-domain profile 10/10 + 10/10;
- profile PSScriptAnalyzer 0;
- native profile parse PASS;
- capture contract 8/8 + 8/8.

The run then reached the first real combined `wpr -start` and failed with:

```text
0xc558300c
The event provider was not enabled.
```

No pre-existing session was cancelled. The failure occurred before the bounded workload and before an ETL was produced.

This result demonstrated that parse-time validity is not equivalent to native enable-time availability and that `Strict=true` on every combined event provider was too strong for a broad foundation capture. The repair introduces the eight-provider native enable matrix and makes the combined provider policy explicitly non-strict while preserving per-provider startability evidence.

### Attempt 3 — `185d73f7456c306eead9907d19e7a75c9e3f2829`

The run was stopped before provider probing or real capture by the mega gate's analyzer preflight. Two findings were isolated to the newly added provider-enable matrix runner:

```text
PSUseShouldProcessForStateChangingFunctions
  New-NxbProviderProbeProfile

PSUseDeclaredVarsMoreThanAssignments
  $profileOutput
```

No WPR probe session or combined recording was started. The repair is behavior-preserving:

- the internal profile writer is now `Write-NxbProviderProbeProfile`, avoiding the state-changing `New-*` analyzer rule while retaining the same bounded file write;
- native `wpr -profiles` output is discarded directly while its exit code remains authoritative, removing the unused `$profileOutput` assignment;
- the matrix regression guard locks both fixes without changing the existing 8-test contract count.

The provider set, strict/non-strict policy, raw-evidence boundary, and semantic claims are unchanged.

## Provider enable matrix evidence

For each of the eight event providers the matrix records:

- domain and provider identity;
- configured keyword count;
- native probe-profile parse status;
- `enabled` or `unavailable`;
- WPR start exit code;
- parsed hexadecimal error code when exposed;
- SHA-256 and line count of raw WPR start output;
- owned-session cancel exit code when a probe started successfully.

Raw WPR start output and generated probe WPRP files remain local.

## Evidence boundary

The mega gate may certify only:

- exact clean repository head;
- provider identity and configured mask binding;
- individual WPR native enableability state;
- successful resilient combined recording;
- bounded workload completion;
- measured native loss counters;
- header-only xperf discovery;
- deterministic header-normalization replay;
- bounded evidence-package policy.

The following remain false or `not_claimed`:

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

No controlled GPU workload is claimed by the foundation workload. Natural desktop GPU activity may be captured but is not treated as a controlled stimulus.

## Native success criteria

The gate is successful only when:

- all static/dual-runtime contracts pass;
- all eight providers receive a measured enableability assessment;
- the resilient combined WPR recording starts and produces an ETL;
- `EventsLost == 0`;
- `BuffersLost == 0`;
- `BuffersWritten > 0`;
- header inventory is non-empty;
- repeated header inventory is byte-identical;
- review ZIP contains no raw ETL/full dumper/provider/capability/probe-profile payloads;
- semantic claims remain disabled.

The first successful native mega run becomes the evidence source for the next wide batch: GPU/network/kernel event normalization, coverage, downstream replay, and semantic investigation without reopening foundation/profile work.
