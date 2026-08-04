# Roadmap

## NXB-IRL-001 — Repository bootstrap

- [x] Deney çalışma alanı
- [x] Baseline collector
- [x] WPR trace başlatma/durdurma
- [x] Evidence hash finalization
- [x] KDNET hazırlık denetimi
- [x] Manifest şeması ve analiz notu

## NXB-IRL-002 — Validation and tests

- [ ] Pester test altyapısı
- [ ] PowerShell syntax ve ScriptAnalyzer kapısı
- [ ] Manifest schema doğrulaması
- [ ] WPR bulunmadığında kontrollü hata testleri
- [ ] Finalization idempotency testleri

## NXB-IRL-003 — Custom performance profile

- [ ] CPU sampling ve stack capture
- [ ] Context switch, DPC ve ISR
- [ ] Disk/file I/O
- [ ] Process/thread/image load
- [ ] Ölçüm overhead kalibrasyonu

## NXB-IRL-004 — Controlled test driver

- [ ] Kendi imzalı benign test sürücüsü
- [ ] Load/unload yaşam döngüsü
- [ ] Process/thread/image callback telemetrisi
- [ ] Pool allocation ve synchronization ölçümü
- [ ] Driver Verifier test matrisi

## NXB-IRL-005 — Debugger evidence pipeline

- [ ] Salt-okuma WinDbg komut dosyaları
- [ ] Module base ve RVA korelasyonu
- [ ] Symbol provenance kaydı
- [ ] Debugger transcript bütünlük hash'i

## NXB-IRL-006 — Static/runtime semantic model

- [ ] Fonksiyon ve çağrı grafı şeması
- [ ] `OBSERVED/INFERRED/VALIDATED` alanları
- [ ] Runtime olaylarının statik offsetlerle eşleştirilmesi
- [ ] LLM çıktılarına confidence ve provenance zorunluluğu

## NXB-IRL-007 — Performance experiment harness

- [ ] Tekrarlı deney matrisi
- [ ] Ortalama, p95, p99 ve confidence interval
- [ ] Frame-time 1%/0.1% low analizi
- [ ] Güvenlik kapsamı regresyon kapıları
