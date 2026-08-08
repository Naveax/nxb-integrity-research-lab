# Roadmap

Kanonik uçtan uca plan: [`MASTER_PLAN.md`](MASTER_PLAN.md)

Yeni sohbet/devralma durumu: [`HANDOFF.md`](HANDOFF.md)

Tam sistem gözlem mimarisi: [`FULL_SYSTEM_OBSERVABILITY.md`](FULL_SYSTEM_OBSERVABILITY.md)

Önceki CPU/GPU tasarım notları: [`CPU_GPU_OBSERVABILITY.md`](CPU_GPU_OBSERVABILITY.md)

## Current block

### NXB-IRL-004 — Full-system observability fabric

Durum: `IN PROGRESS — TRACE-LOSS BLOCK VALIDATED — RAM PROFILE NEXT`

GitHub takip kaydı: issue `#2`.

Hazır temel:

- [x] CPU/RAM/GPU/disk/ağ/PCIe/kernel/power/firmware mimari belgesi
- [x] System capability JSON Schema
- [x] Windows PowerShell capability inventory collector
- [x] Baseline collector entegrasyonu
- [x] Capability schema validator
- [x] Repository smoke validation entegrasyonu
- [x] Pester capability testleri
- [x] Canonical cross-domain event schema
- [x] Machine/boot/clock identity contract
- [x] Deterministic evidence integrity store
- [x] Minimal bounded CPU + scheduler profile
- [x] Paired collector overhead calibration mechanism
- [x] Trace-loss and circular-overwrite accounting
- [x] Native ETL `OpenTraceW` header fallback independent of xperf
- [x] Exact-head Windows trace-loss validation

Sıradaki alt görevler:

- [ ] RAM/page-fault/working-set profile
- [ ] Disk/file-system/storage queue profile
- [ ] GPU/DXGKRNL/present profile
- [ ] Network/NDIS/connection profile
- [ ] Device/driver/PCIe provider inventory
- [ ] Power/frequency/thermal snapshot
- [ ] Expanded cross-provider capture-completeness classification
- [ ] Cross-domain correlation engine
- [ ] Controlled CPU/RAM/disk/GPU/network fixtures
- [ ] Representative production overhead thresholds

## Active PR closeout

### NXB-IRL-004 — Trace-loss and circular-overwrite accounting

Durum: `IMPLEMENTATION COMPLETE — EXACT-HEAD WINDOWS VALIDATION PASSED — DRAFT PR #8 CLOSEOUT`

GitHub takip kaydı: issue `#2`

Draft PR: `#8`

Validated implementation head:

```text
e5a7e0cf2f7c1a4c5f50b3c460e0c859d74db258
```

Canonical validation:

[`NXB-IRL-004-TRACE-LOSS-VALIDATION.md`](NXB-IRL-004-TRACE-LOSS-VALIDATION.md)

Tamamlanan kapılar:

- [x] Public repository guard — 108 candidate files
- [x] Native WPR profile parser
- [x] PSScriptAnalyzer — 0 Error/Warning findings
- [x] Repository smoke
- [x] PowerShell 7 Pester — 136/136
- [x] Windows PowerShell 5.1 Pester — 136/136
- [x] Native paired WPR regression calibration — 1/1 pair
- [x] Base exact-head validation
- [x] Real elevated WPR capture
- [x] Native ETL `TRACE_LOGFILE_HEADER` accounting
- [x] Measured pre-stop and post-stop applicable loss counters
- [x] ETL SHA-256/length reconciliation
- [x] Evidence finalization and integrity verification
- [x] Safe review bundles inspected
- [x] Canonical validation record
- [x] Handoff and roadmap closeout update

Kalan closeout işlemleri:

- [ ] Compare final PR head with validated implementation head and confirm documentation-only delta
- [ ] Update PR `#8` body with exact validation evidence
- [ ] Mark PR ready only with explicit instruction
- [ ] Exact-head squash merge only with explicit instruction

PR `#8` tracks issue `#2` without closing it. The broader observability fabric continues with RAM/page-fault/working-set capture.

## Completed

### NXB-IRL-001 — Repository bootstrap

- [x] Deney çalışma alanı
- [x] Baseline collector
- [x] WPR trace başlatma/durdurma
- [x] Evidence hash finalization
- [x] KDNET hazırlık denetimi
- [x] Manifest şeması ve analiz notu

### NXB-IRL-002 — Deterministic experiment lifecycle

- [x] Canonical lifecycle and atomic writes
- [x] Evidence verification and recovery
- [x] WPR failure-path matrix
- [x] Reparse and sensitive-artifact adversarial tests
- [x] PowerShell 5.1 and PowerShell 7 Windows CI
- [x] PSScriptAnalyzer and repository smoke validation
- [x] PR #3 merge and issue #1 closure

### NXB-IRL-003 — Evidence integrity store

- [x] Version-1 evidence-store contract
- [x] Record, chain-head and bundle-manifest Draft 2020-12 schemas
- [x] Canonical JSON serializer and deterministic SHA-256 identity
- [x] Append-only record chain and independent verification
- [x] Tool provenance and clock-offset evidence
- [x] Deterministic offline bundles
- [x] Optional detached local signatures
- [x] Adversarial tamper, traversal, reparse and signature coverage
- [x] PowerShell 7 and Windows PowerShell 5.1 validation
- [x] PSScriptAnalyzer and public repository guard
- [x] PR #5 merge and issue #4 closure

## Upcoming blocks

1. `NXB-IRL-004` — Full-system observability fabric
2. `NXB-IRL-005` — Controlled kernel test driver
3. `NXB-IRL-006` — Controller/target transport
4. `NXB-IRL-007` — Debugger evidence pipeline
5. `NXB-IRL-008` — PE and binary inventory
6. `NXB-IRL-009` — Static-analysis import
7. `NXB-IRL-010` — Runtime snapshot correlation
8. `NXB-IRL-011` — Semantic intermediate representation
9. `NXB-IRL-012` — LLM-assisted semantic analysis
10. `NXB-IRL-013` — Target adapter framework
11. `NXB-IRL-014` — EAC adapter
12. `NXB-IRL-015` — Performance harness
13. `NXB-IRL-016` — Performance root-cause analysis
14. `NXB-IRL-017` — Security analysis workflow
15. `NXB-IRL-018` — Clean-room behavioral model
16. `NXB-IRL-019` — Security equivalence/regression
17. `NXB-IRL-020` — Reporting pipeline
18. `NXB-IRL-021` — Additional adapters
19. `NXB-IRL-022` — Release/operator tooling

Her blok için ayrıntılı görevler ve tamamlanma kapıları `MASTER_PLAN.md` ve ilgili özel mimari belgesinde tutulur.
