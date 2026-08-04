# Roadmap

Kanonik uçtan uca plan: [`MASTER_PLAN.md`](MASTER_PLAN.md)

Yeni sohbet/devralma durumu: [`HANDOFF.md`](HANDOFF.md)

Tam sistem gözlem mimarisi: [`FULL_SYSTEM_OBSERVABILITY.md`](FULL_SYSTEM_OBSERVABILITY.md)

Önceki CPU/GPU tasarım notları: [`CPU_GPU_OBSERVABILITY.md`](CPU_GPU_OBSERVABILITY.md)

## Current block

### NXB-IRL-002 — Deterministic experiment lifecycle

Durum: `IN PROGRESS`

GitHub takip kaydı: issue `#1`

Tamamlananlar:

- [x] Ortak path/lifecycle/atomic-write modülü
- [x] Evidence integrity verifier
- [x] Experiment status ve failed-state komutları
- [x] Interrupted experiment recovery
- [x] Atomik manifest oluşturma
- [x] WPR start/stop durum geçişleri
- [x] Atomik ve idempotent finalization
- [x] Draft 2020-12 manifest schema validation
- [x] Pester lifecycle/recovery testleri
- [x] PowerShell 5.1 / PowerShell 7 CI matrisi
- [x] PSScriptAnalyzer workflow tanımı
- [x] Public repository sensitive-artifact guard
- [x] Canonical evidence ordering ve tamper testleri

Kalanlar:

- [ ] GitHub Actions çalışmasını doğrulama ve gerekirse onarma
- [ ] WPR unavailable/start/stop failure-path testleri
- [ ] Gerçek Windows reparse-point adversarial testi
- [ ] Sentetik blocked-artifact guard testi
- [ ] İlk CI loglarını inceleme ve tüm hataları düzeltme
- [ ] Final validation report ve issue `#1` kapanışı

## Full-system track preparation

### NXB-IRL-004 — Full-system observability fabric

Durum: `PLANNED / INITIAL IMPLEMENTATION STARTED`

GitHub takip kaydı: issue `#2`

İlk tamamlananlar:

- [x] CPU/RAM/GPU/disk/ağ/PCIe/kernel/power/firmware mimari belgesi
- [x] System capability JSON Schema
- [x] Windows PowerShell capability inventory collector
- [x] Baseline collector entegrasyonu
- [x] Capability schema validator
- [x] Repository smoke validation entegrasyonu
- [x] Pester capability testleri

Sıradaki alt görevler:

- [ ] Canonical cross-domain event schema
- [ ] Machine/boot/clock identity contract
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

## Upcoming blocks

1. `NXB-IRL-003` — Evidence integrity store
2. `NXB-IRL-004` — Full-system observability fabric
3. `NXB-IRL-005` — Controlled kernel test driver
4. `NXB-IRL-006` — Controller/target transport
5. `NXB-IRL-007` — Debugger evidence pipeline
6. `NXB-IRL-008` — PE and binary inventory
7. `NXB-IRL-009` — Static-analysis import
8. `NXB-IRL-010` — Runtime snapshot correlation
9. `NXB-IRL-011` — Semantic intermediate representation
10. `NXB-IRL-012` — LLM-assisted semantic analysis
11. `NXB-IRL-013` — Target adapter framework
12. `NXB-IRL-014` — EAC adapter
13. `NXB-IRL-015` — Performance harness
14. `NXB-IRL-016` — Performance root-cause analysis
15. `NXB-IRL-017` — Security analysis workflow
16. `NXB-IRL-018` — Clean-room behavioral model
17. `NXB-IRL-019` — Security equivalence/regression
18. `NXB-IRL-020` — Reporting pipeline
19. `NXB-IRL-021` — Additional adapters
20. `NXB-IRL-022` — Release/operator tooling

Her blok için ayrıntılı görevler ve tamamlanma kapıları `MASTER_PLAN.md` ve ilgili özel mimari belgesinde tutulur.
