# Roadmap

Kanonik uçtan uca plan: [`MASTER_PLAN.md`](MASTER_PLAN.md)

Yeni sohbet/devralma durumu: [`HANDOFF.md`](HANDOFF.md)

CPU/GPU gözlem hattı: [`CPU_GPU_OBSERVABILITY.md`](CPU_GPU_OBSERVABILITY.md)

## Current block

### NXB-IRL-002 — Deterministic experiment lifecycle

Durum: `IN PROGRESS`

GitHub takip kaydı: issue `#1`

Tamamlananlar:

- [x] Ortak path/lifecycle/atomic-write modülü
- [x] Evidence integrity verifier
- [x] Experiment status command
- [x] Atomik manifest oluşturma
- [x] WPR start/stop durum geçişleri
- [x] Atomik ve idempotent finalization
- [x] İlk Pester lifecycle testleri
- [x] PowerShell 5.1 / PowerShell 7 CI matrisi
- [x] PSScriptAnalyzer workflow tanımı

Kalanlar:

- [ ] GitHub Actions çalışmasını doğrulama ve gerekirse onarma
- [ ] Gerçek JSON Schema validation
- [ ] Interrupted experiment recovery
- [ ] Failed-state writer
- [ ] Path traversal/reparse-point adversarial tests
- [ ] Sensitive artifact commit guard
- [ ] WPR unavailable/failure-path tests
- [ ] Canonical evidence ordering tests
- [ ] Lifecycle schema update
- [ ] Final validation report

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
2. `NXB-IRL-004` — Custom CPU/GPU WPR/ETW profiles
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

Her blok için ayrıntılı görevler ve tamamlanma kapıları `MASTER_PLAN.md` içindedir.
