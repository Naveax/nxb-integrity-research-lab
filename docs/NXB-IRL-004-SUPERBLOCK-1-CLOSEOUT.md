# NXB-IRL-004 — SUPERBLOCK 1 Closeout

## Status

`VALIDATED — SUPERBLOCK 1 CLOSED`

- Tracking issue: `#2`
- Pull request: `#12`
- Branch: `nxb-irl-004-superblock1-remaining-domains`
- Native exact-head authority: Windows PowerShell 7 exact-head validation
- Final validated runtime/test head: `d2d29a0ebe9ef44bbe9aa948a040a34b2a0e8218`
- GitHub Actions: intentionally disabled repository-wide

This closeout records the final native validation of the remaining SUPERBLOCK 1 observability domains. Commits after the validated runtime/test head may update documentation/checklists only and do not replace the native exact-head authority.

## Canonical predecessor chain

```text
foundation / real capture:
  head:       57dd8a466509bd390b94ad8426b2af6dd56c1687
  review ZIP: 4dbbf73c58d6bb241e3dfb91fb859eb6b4550ef40359f246aa4bfa939a035bf5

downstream normalization:
  head:       7fd766d15faa9b2ca0197edf342a0f794f4d1f0b
  review ZIP: b5009e314aeed4f20e4daec951ea661255c094638bab697cf5c3aaf0fde13480

structural correlation:
  head:       8bb94d10b4a74629668ddee2ad2fe378f8928999
  review ZIP: 6697c15afc7eefec460b6ae436bb0aee41c2052caabbe980d38ff618f71a1d76

Round 1 controlled same-PID eligibility:
  head:       2230864433890c2992b59088fe1af3db0c635808
  review ZIP: 97922ba500a0f66d34a8b8cbda54b34aa7e871af3e3d68d81255bcd8bd39a150

Round 2 repeated ON/OFF semantic controls:
  head:       36d962b7c6d42aef6c5034fc42705a78b2ee8bc4
  review ZIP: c7dc5f723af5ea28903efc04a7f45391d7856f06f3d87f43ddc0627bcfafb98a
  semantic summary: 4f4a55c34469dafcfde14f8fc9ae21efedf6457e19f26674bf25a4ff31eae20c
```

## Final native gate

Final exact head:

```text
d2d29a0ebe9ef44bbe9aa948a040a34b2a0e8218
```

Static/native contract:

```text
PowerShell 7 Pester:          18/18
Windows PowerShell 5.1:      18/18
PSScriptAnalyzer findings:    0
native x64 fixture build:     PASS
canonical Round 1 binding:    PASS
canonical Round 2 binding:    PASS
```

Paired calibration protocol:

```text
warmup pairs:                  1
measured pairs:                4
ordering:                      C->I, I->C, C->I, I->C
workload:                      same bounded all_on fixture in both arms
instrumented loss-free pairs:  4/4
threshold policy:              not_declared
representative benchmark:      false
```

Measured median deltas:

```text
fixture duration delta:         4.13935 ms
fixture duration overhead:      0.189142 %
process CPU delta:              15.625 ms
peak working-set delta:         28672 bytes
peak private-byte delta:        622592 bytes
```

These measurements are bounded same-machine calibration evidence. They are not a declared production acceptance threshold and are not claimed to represent arbitrary production workloads.

## Final evidence hashes

```text
overhead calibration SHA-256:
08f626d7ee6ac4f4e4156d19f9776c2eade082e1ab8775a12fa08a1643c135e5

claim matrix SHA-256:
b91dd05fa6c21b3ff701b68e9a6dfa61eead0fbd0bb1c40911fd2c01b815c29a

final certification receipt SHA-256:
71e06f767abe7009756c68b13723d43502aa5495b2bce992cf81d4889d55cb0b

final review ZIP SHA-256:
2949aa445d96922221e17d287ce19bceaac81f2d9a89996a00d4f100ae262c8d
```

The final certification gate audits the review ZIP boundary before success. Per-arm ETLs, fixture receipts, native executables/build products and other raw/local artifacts remain local-only.

## Promoted bounded claims

The final evidence supports only bounded claims already established by controlled native experiments:

```text
controlled_fixture_process:                    true
exact_fixture_pid_attribution:                 true
exact_pid_three_domain_observability:          true
controlled_present_count_mapping_validated:    true
controlled_network_activity_mapping_validated: true
deterministic_normalization_replay:             true
deterministic_correlation_replay:               true
repeated_control_analysis_replay:               true
bounded_paired_overhead_measured:               true
```

Round 2 reproduced the controlled Present count differential in both repetitions:

```text
GPU positive:  fixture-PID Present Start/Stop = 128 / 128
GPU negative:  fixture-PID Present Start/Stop = 0 / 0
```

Network positive and negative controls likewise separated in both repetitions. These results validate the bounded controlled mappings only.

## Withheld claims

The following remain explicitly false/unclaimed:

```text
present_event_mapping_generalized:        false
present_pairing_semantics:                false
present_success_semantics:                false
gpu_queue_semantics:                      false
tcp_connection_lifecycle_validated:       false
network_connection_semantics:             false
network_latency_semantics:                false
dns_payload_semantics:                    false
kernel_lifecycle_semantics:               false
registry_operation_semantics:             false
timestamp_unit_resolved:                   false
causal_relationship_validated:            false
root_cause_validated:                     false
circular_overwrite_absence:               false
circular_overwrite:                       unknown
trace_completeness:                       not_claimed
```

Round 2 reproduced asymmetric Present Start/Stop field shapes, so exact named Present pairing remains ineligible. Kernel-off counts also remained close to all-on counts, so the explicit kernel stimulus did not isolate kernel/registry semantics sufficiently for promotion.

## SUPERBLOCK 1 completion

No Round 4 residual repair is required by the final native run.

SUPERBLOCK 1 closes the remaining GPU/network/cross-domain controlled-observability work in PR #12. Issue #2 remains open because broader full-system work still includes device/driver/PCIe, power/frequency/thermal and firmware/VBS/HVCI/Secure Boot coverage.

PR #12 remains draft/open until an explicit merge or ready-for-review decision is made.
