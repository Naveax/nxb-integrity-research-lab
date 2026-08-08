# NXB-IRL-004 — Memory Observability Closeout

## Status

`IMPLEMENTATION VALIDATED — STACKED DRAFT — MERGE BLOCKED ON PR #8`

Validated memory implementation/calibration head:

```text
dd3b8016091c40dfea6364076888f022a0d782d3
```

This document closes the RAM, page-fault, working-set and virtual-memory observability implementation block. PR #9 remains stacked on `nxb-irl-004-trace-loss-accounting` and must remain draft/open until the parent PR is explicitly merged.

## Validated chain

```text
profile:                    d494a12fd7dd044ca0abaa83f1a8c6ffcbff6773
foundation:                 ae3debb4bf16276c08eb79dc3575ed7cf8ce5492
native collector:           d49aaef68da1e8be4141ccc55f032c13e211e64a
normalized ETL adapter:     d9502f8f69419ec12a6ae43e79c83f14b6113ef2
raw ETL/xperf bridge:       c9ec8cf498d8bebb992be865f2c76fd496d4b8c1
real bounded WPR capture:   5ef11042146ba4d964ce553edd02a0f6329732e6
exact downstream replay:    d895f4819cf31cc4e89c04fa7b9e02f11136b7d5
memory overhead calibration:dd3b8016091c40dfea6364076888f022a0d782d3
```

Validation records:

```text
docs/NXB-IRL-004-MEMORY-PROFILE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-FOUNDATION-VALIDATION.md
docs/NXB-IRL-004-MEMORY-COLLECTOR-VALIDATION.md
docs/NXB-IRL-004-MEMORY-ETL-ADAPTER-VALIDATION.md
docs/NXB-IRL-004-MEMORY-RAW-BRIDGE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-REAL-CAPTURE-VALIDATION.md
docs/NXB-IRL-004-MEMORY-DOWNSTREAM-REPLAY-VALIDATION.md
docs/NXB-IRL-004-MEMORY-OVERHEAD-CALIBRATION-VALIDATION.md
```

## Real bounded capture

The exact-head real Windows capture used:

```text
private allocation: 32 MiB
mapped file:        8 MiB
hold:               1000 ms
page stride:        4096 bytes
```

It normalized `265258` real events and produced a schema-valid downstream summary.

Measured aggregate event evidence:

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

`mapped_section_create` and `mapped_section_delete` remained `not_assessed` because the normalized trace did not cover those classes.

Native pre-stop evidence reported:

```text
Dropped event: 0
Events Lost:   0
trace_loss:    none
```

This is limited to the native counters represented by the recorded evidence and is not a universal completeness claim.

## Deterministic downstream replay

The repository-native replay at `d895f4819cf31cc4e89c04fa7b9e02f11136b7d5` reprocessed the preserved real normalized export and produced a byte-identical summary:

```text
normalized_event_count: 265258
source summary SHA-256: 14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5
replay summary SHA-256: 14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5
byte_identical_summary: true
```

Raw ETL, full dumper text and normalized CSV were excluded from the replay review archive.

## Paired capture overhead

The canonical exact-head memory overhead calibration at `dd3b8016091c40dfea6364076888f022a0d782d3` passed:

```text
warmups:          1
pairs:            3
successful pairs: 3
failed pairs:     0
threshold policy: not_declared
```

Median measured deltas:

```text
duration:           +1.700128930209937 %
CPU time:          +54.54545454545454 %
peak working set:   +1.3916161529924016 %
peak private bytes: -0.664332063034298 %
```

The CPU percentage is explicitly not promoted into a production threshold because the bounded workload is short and absolute process CPU time is small.

Calibration review archive:

```text
nxb-memory-overhead-calibration-dd3b8016091c-20260807T214351Z-review.zip
sha256: 2f0c7110fd83a0026377ac8c281a1afd38f8ae8235dc037626adefc05d8e4832
```

## Circular-overwrite boundary

The parent trace-loss accounting design can classify circular-buffer pressure as `risk_observed`, `no_risk_observed`, `not_assessed`, `not_applicable` or `failed` from configured capacity and observed trace statistics.

However, even `no_risk_observed` is explicitly not proof that circular overwrite did not occur. The parent contract always retains:

```text
claims.circular_overwrite_absence: false
claims.capture_completeness: not_claimed
```

The validated memory capture therefore closes with:

```text
circular_overwrite: unknown
trace_completeness: not_claimed
```

No synthetic `none`, `false` or zero-valued absence claim is introduced.

## Final claim boundary

The memory block proves bounded collection, normalization, provenance, replay determinism and paired overhead measurement for the recorded Windows environment.

It does not claim:

- arbitrary process-memory visibility,
- memory-dump coverage,
- working set equals total memory cost,
- hard-fault bytes equal total scenario memory cost,
- missing event classes are zero,
- circular-overwrite absence,
- universal trace completeness,
- representative production overhead thresholds.

## Repository and artifact boundary

Raw ETL, full xperf dumper text and calibration ETLs remain local. Review archives contain only bounded derived evidence and provenance material.

GitHub Actions remain intentionally disabled repository-wide; the recorded native validations were performed locally on real Windows.

## Merge boundary

The memory implementation block itself is validated and closed. PR #9 remains an open stacked draft and must not be retargeted, marked ready or merged until PR #8 is explicitly merged and the stack is advanced under exact-head control.