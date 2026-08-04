# Roadmap

Kanonik uçtan uca plan: [`MASTER_PLAN.md`](MASTER_PLAN.md)

Yeni sohbet/devralma durumu: [`HANDOFF.md`](HANDOFF.md)

Tam sistem gözlem mimarisi: [`FULL_SYSTEM_OBSERVABILITY.md`](FULL_SYSTEM_OBSERVABILITY.md)

Önceki CPU/GPU tasarım notları: [`CPU_GPU_OBSERVABILITY.md`](CPU_GPU_OBSERVABILITY.md)

## Current block

### NXB-IRL-003 — Evidence integrity store

Durum: `ACTIVE IMPLEMENTATION`

GitHub takip kaydı: issue `#4`

Draft PR: `#5`

Tamamlananlar:

- [x] Version-1 evidence-store contract
- [x] Record, chain-head ve bundle-manifest Draft 2020-12 şemaları
- [x] Canonical JSON serializer
- [x] UTF-8 BOM'suz deterministic SHA-256
- [x] Root-only self-hash exclusion
- [x] Atomik canonical JSON writer
- [x] Append-only record zinciri
- [x] Staged schema validation before append
- [x] Previous-record hash linkage
- [x] Experiment/machine/boot/session identity binding
- [x] Deterministic chain-head ve chain verifier
- [x] Tool provenance record helper ve executable verifier
- [x] Hassas argümanları saklamayan redacted argument digest
- [x] Four-timestamp clock-offset record helper
- [x] Clock arithmetic verifier
- [x] Canonicalization/schema/chain/provenance/clock adversarial tests
- [x] PR/ref concurrency ile superseded Actions run cancellation

Sıradaki işler:

- [ ] İlk tamamlanan Windows CI loglarını inceleme ve onarma
- [ ] Deterministic offline bundle oluşturma
- [ ] Offline bundle doğrulama
- [ ] Evidence-store/bundle karşılaştırma
- [ ] Optional detached local signing
- [ ] Bundle truncation ve case-collision testleri
- [ ] Reparse/path traversal bundle testleri
- [ ] Unsigned/invalid-signature durum testleri
- [ ] Final validation report ve issue `#4` kapanışı

## Full-system track preparation

### NXB-IRL-004 — Full-system observability fabric

Durum: `PLANNED / INITIAL IMPLEMENTATION STARTED`

GitHub takip kaydı: issue `#2`.

İlk tamamlananlar:

- [x] CPU/RAM/GPU/disk/ağ/PCIe/kernel/power/firmware mimari belgesi
- [x] System capability JSON Schema
- [x] Windows PowerShell capability inventory collector
- [x] Baseline collector entegrasyonu
- [x] Capability schema validator
- [x] Repository smoke validation entegrasyonu
- [x] Pester capability testleri
- [x] Canonical cross-domain event schema
- [x] Machine/boot/clock identity contract

Sıradaki alt görevler:

- [ ] Minimal CPU + scheduler profile
- [ ] RAM/page-fault/working-set profile
- [ ] Disk/file-system/storage queue profile
- [ ] GPU/DXGKRNL/present profile
- [ ] Network/NDIS/connection profile
- [ ] Device/driver/PCIe provider inventory
- [ ] Power/frequency/thermal snapshot
- [ ] Trace-loss ve overhead accounting
- [ ] Cross-domain correlation engine
- [ ] Controlled CPU/RAM/disk/GPU/network fixtures

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
