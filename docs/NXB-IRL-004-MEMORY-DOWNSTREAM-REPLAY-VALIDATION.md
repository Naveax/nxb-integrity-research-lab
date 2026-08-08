# NXB-IRL-004 Memory Downstream Replay Validation

## Status

`PASSED — EXACT-HEAD REAL WINDOWS REPLAY`

Validated replay head:

```text
d895f4819cf31cc4e89c04fa7b9e02f11136b7d5
```

Source real-capture head:

```text
5ef11042146ba4d964ce553edd02a0f6329732e6
```

Branch:

```text
nxb-irl-004-memory-working-set
```

Validation ran locally on real Windows from PowerShell 7. GitHub Actions remained intentionally disabled.

## Validation gates

The exact-head portable validator cloned the repository, detached-checkout the replay implementation head, required a clean worktree and then executed the repository-native replay path.

All preflight gates passed:

```text
PowerShell parser:       PASS
PSScriptAnalyzer:        0 findings
Replay Pester:           6/6 passed
failed:                  0
skipped:                 0
inconclusive:            0
not run:                 0
```

The regression matrix covered:

- successful byte-identical replay,
- canonical sub-microsecond receipt timing tolerance,
- source capture HEAD mismatch rejection,
- normalized CSV tamper rejection,
- source-summary adapter provenance drift rejection,
- source receipt trace-timing drift rejection.

## Real source replay

The replay used the preserved successful real capture directory:

```text
nxb-memory-real-capture-5ef11042146b-20260807-175831
```

The repository-native replay validated:

- source capture receipt status and exact source HEAD binding,
- bridge manifest -> normalized CSV SHA-256 binding,
- source summary -> normalized CSV SHA-256 binding,
- receipt -> summary machine/boot/trace/profile provenance,
- target PID/image/start-time provenance,
- trace start/end timing provenance,
- trace-quality propagation,
- adapter-byte provenance,
- replay output semantic validity,
- byte-identical source/replay summary SHA-256 and length,
- exclusion of raw ETL, full dumper and normalized CSV from the review ZIP.

## Real replay result

```text
status:                        passed
replay_head_sha:               d895f4819cf31cc4e89c04fa7b9e02f11136b7d5
source_capture_head_sha:       5ef11042146ba4d964ce553edd02a0f6329732e6
normalized_event_count:        265258
source_summary_sha256:         14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5
replay_summary_sha256:         14a87be87a0d4efb31b213702744c9fc08312aff51a563531244dfe70d22aec5
byte_identical_summary:        true
trace_loss:                    none
circular_overwrite:            unknown
parser_completeness:           partial
evidence_completeness:         partial
measured_event_class_count:    8
failed_event_class_count:      0
process_count:                  94
raw_etl_included:              false
raw_dumper_included:           false
normalized_csv_included:       false
```

The replay result does not upgrade any conservative source-capture claims. In particular, `circular_overwrite` remains `unknown`, parser/evidence completeness remain `partial`, and trace completeness remains unclaimed.

## Review artifact

```text
nxb-memory-downstream-replay-d895f4819cf3-20260807T154611Z-review.zip
sha256: 3229490d37c34310789189c4a71878b16b9e9392b11407d5badbe14987b4e1b3
```

The review archive intentionally excludes raw ETL, the full xperf dumper text and the normalized CSV.

## Boundary

This validation proves deterministic downstream reinterpretation of the preserved real normalized memory evidence using the exact repository replay implementation head. It does not prove raw-trace completeness, absence of circular overwrite, mapped-section coverage, or acceptable capture overhead.

The next mandatory memory-domain closure gate is paired control/capture overhead calibration using the same bounded workload contract.
