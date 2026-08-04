# NXB Integrity Research Lab — Canonical Master Plan

Bu belge projenin kanonik planıdır. Yeni bir sohbette veya yeni bir geliştiriciyle devam edilirken ilk okunacak dosyadır.

Tam sistem gözlem ayrıntıları için ayrıca [`FULL_SYSTEM_OBSERVABILITY.md`](FULL_SYSTEM_OBSERVABILITY.md) zorunlu referanstır. Bu belge, önceki yalnız CPU/GPU odaklı hattı CPU, RAM, GPU, disk, ağ, PCIe/aygıt, kernel, güç/termal ve firmware kapsamına genişletir.

## 1. Nihai hedef

Genel amaçlı, tekrar üretilebilir ve kanıta dayalı bir araştırma platformu oluşturmak:

- anti-cheat,
- anti-tamper,
- DRM,
- integrity sistemleri,
- kernel sürücüleri,
- korumalı kullanıcı modu uygulamaları.

Platformun görevi hedefi etkisizleştirmek değildir. Görevi hedefin davranışını, güvenlik sınırlarını, performans maliyetlerini ve hata yollarını ölçülebilir biçimde anlamaktır.

## 2. Değişmez kurallar

1. Her veri tam hedef sürümü ve SHA-256 ile ilişkilendirilir.
2. `OBSERVED`, `INFERRED`, `HYPOTHESIS`, `VALIDATED`, `REJECTED` sınıfları karıştırılmaz.
3. LLM yorumu tek başına kanıt değildir.
4. Gerçek binary, dump, ETL, debug anahtarı ve açıklanmamış bulgu public repoya girmez.
5. Her performans iddiası kontrollü ve tekrarlı deneyle ölçülür.
6. Her güvenlik bulgusu alternatif açıklamalar elenmeden `VALIDATED` olmaz.
7. Performans iyileştirmesi güvenlik kapsamını azaltamaz.
8. Platform çekirdeği hedefe özel olmamalı; ürünler adapter olarak eklenmelidir.
9. Ölçüm sisteminin kendi ek yükü ayrıca kalibre edilir.
10. Veri kaybı, trace overflow veya collector failure sessizce gerçekleşemez.
11. Bütün domainler ortak experiment/machine/boot/time kimliği kullanır.
12. Anti-detection, görünmezlik veya koruma atlatma özelliği proje hedefi değildir.

## 3. Üst seviye mimari

```text
Protected target
    -> target adapter
    -> target runtime environment
    -> CPU / RAM / GPU / disk / network / device observability
    -> kernel / power / firmware context
    -> evidence controller
    -> cross-domain common timeline
    -> static/runtime correlation
    -> semantic intermediate representation
    -> LLM-assisted hypotheses
    -> controlled validation
    -> security/performance reports
```

## 4. Fazlar

### NXB-IRL-001 — Repository bootstrap

Durum: `COMPLETE`

Teslimatlar:

- workspace oluşturma,
- deney manifesti,
- baseline collector,
- WPR trace başlatma/durdurma,
- KDNET hazırlık denetimi,
- evidence SHA-256 finalization,
- temel Windows smoke testi.

### NXB-IRL-002 — Deterministic experiment lifecycle

Durum: `IN PROGRESS`

Yapılacaklar:

- Pester test altyapısı,
- PSScriptAnalyzer kapısı,
- JSON Schema doğrulaması,
- kanonik durum makinesi,
- atomik manifest güncelleme,
- idempotent finalization,
- evidence yeniden doğrulama,
- yarım deney recovery,
- bozuk WPR/failure-path testleri,
- Windows PowerShell 5.1 ve PowerShell 7 CI matrisi,
- path traversal ve reparse-point testleri,
- hassas dosya commit engeli.

Tamamlanma kapısı:

- izin verilmeyen durum geçişleri reddedilir,
- ikinci finalization çıktıyı değiştirmez,
- tek byte değişikliği doğrulamada bulunur,
- yarım deney güvenli biçimde kurtarılır,
- tüm testler Windows CI üzerinde geçer.

### NXB-IRL-003 — Evidence integrity store

Yapılacaklar:

- canonical manifest hash,
- experiment chain,
- tool provenance,
- controller/target clock offset,
- machine/boot/session identity,
- offline evidence bundle,
- integrity comparison,
- isteğe bağlı yerel imza.

### NXB-IRL-004 — Full-system observability fabric

Durum: `PLANNED / INITIAL IMPLEMENTATION STARTED`

GitHub takip kaydı: issue `#2`.

Kapsam:

- CPU sampling, stack, scheduler, context switch, DPC/ISR,
- RAM, commit, working set, hard/soft fault, memory region yaşam döngüsü,
- GPU/DXGKRNL queue, resource, residency ve present,
- disk/storage queue/file-system/paging I/O,
- network/NDIS/connection/DNS/retransmit metadata,
- PCIe/PnP/device/driver topolojisi,
- kernel/service/driver yaşam döngüsü,
- power/frequency/thermal state,
- firmware/Secure Boot/TPM/VBS/HVCI/boot state,
- trace loss ve collector overhead,
- ortak zaman çizelgesi ve cross-domain correlation.

İlk tamamlananlar:

- full-system mimari belgesi,
- system capability JSON Schema,
- Windows capability inventory collector,
- baseline entegrasyonu,
- capability validator ve Pester testleri.

Sıradaki işler:

- normalized cross-domain event schema,
- machine/boot/clock identity contract,
- minimal CPU/RAM/disk/GPU/network profilleri,
- device/driver ve power/firmware snapshot,
- overhead ve dropped-event accounting,
- cross-domain correlation engine,
- controlled CPU, memory, storage, GPU ve network fixtures.

Tamamlanma kapısı:

- bütün domainler aynı experiment ve zaman sözleşmesine bağlıdır,
- desteklenmeyen capability açıkça `unavailable/partial` görünür,
- collector overhead ve dropped events ölçülür,
- bir latency veya frame-time problemi en az üç domain boyunca izlenebilir,
- target adapter eklemek platform çekirdeğini değiştirmez.

### NXB-IRL-005 — Controlled kernel test driver

Yapılacaklar:

- benign test sürücüsü,
- load/unload yaşam döngüsü,
- process/thread/image callbacks,
- registry ve object callback fixture'ları,
- pool allocation,
- worker thread,
- timer/DPC,
- lock contention,
- kontrollü yavaş yol,
- Driver Verifier matrisi.

### NXB-IRL-006 — Controller/target transport

Yapılacaklar:

- kimlik doğrulamalı kanal,
- event sequence ve monotonic ID,
- duplicate/loss detection,
- bounded queue,
- backpressure,
- bounded local spool,
- emergency stop,
- yarım aktarım recovery.

### NXB-IRL-007 — Debugger evidence pipeline

Yapılacaklar:

- salt-okuma WinDbg scriptleri,
- module base/RVA korelasyonu,
- thread ve stack kaydı,
- symbol provenance,
- transcript hash,
- debugger pause süreleri,
- hedef hash + module + RVA + experiment ID zorunluluğu.

### NXB-IRL-008 — PE and binary inventory

Yapılacaklar:

- PE headers ve sections,
- entropy,
- imports/exports,
- relocations,
- TLS callbacks,
- exception/load config,
- CFG/CET,
- Authenticode,
- debug/PDB metadata,
- resources/version,
- overlay ve packing göstergeleri.

### NXB-IRL-009 — Static-analysis import

Yapılacaklar:

- Ghidra adapter,
- IDA adapter,
- generic JSON adapter,
- canonical function identity,
- call graph,
- basic blocks,
- strings/import/data references,
- provenance ve confidence.

### NXB-IRL-010 — Runtime snapshot correlation

Yapılacaklar:

- loaded module map,
- image-backed/private/mapped memory ayrımı,
- executable page inventory,
- relocation/import normalization,
- runtime/disk karşılaştırması,
- dynamic executable region classification,
- snapshot provenance.

### NXB-IRL-011 — Semantic intermediate representation

Yapılacaklar:

- function/basic block/call edge,
- data-flow ve state transition,
- resource ownership,
- synchronization,
- API usage,
- side effects,
- error paths,
- security boundary,
- performance cost,
- CPU/RAM/GPU/storage/network resource attribution.

### NXB-IRL-012 — LLM-assisted semantic analysis

Yapılacaklar:

- function summary,
- call-context analysis,
- data-flow analysis,
- runtime ve cross-domain correlation,
- alternative explanation generation,
- validation test generation,
- confidence/provenance enforcement,
- hypothesis revision history.

### NXB-IRL-013 — Target adapter framework

Adapter sözleşmesi:

- target discovery,
- binary inventory,
- service/driver names,
- lifecycle,
- process tree,
- ETW providers,
- system-domain metrics,
- experiment scenarios,
- security boundaries,
- performance metrics.

### NXB-IRL-014 — EAC adapter

İlk deneyler:

- installed inventory,
- service start,
- driver load,
- steady state,
- lobby/loading/gameplay/alt-tab,
- shutdown/teardown,
- process/service/driver/thread/event/runtime-region haritası,
- CPU/RAM/GPU/disk/network etkilerinin ortak zaman çizelgesi.

### NXB-IRL-015 — Performance harness

Yapılacaklar:

- kontrollü sistem matrisi,
- warm-up,
- en az beş tekrar,
- average/median/p95/p99,
- 1% ve 0.1% low,
- confidence interval,
- effect size,
- CPU/kernel/DPC/ISR/context-switch,
- commit/working-set/page-fault,
- GPU queue/present/residency,
- disk/file/network I/O,
- power/frequency/thermal ölçümleri.

### NXB-IRL-016 — Performance root-cause analysis

Aranacak sınıflar:

- gereksiz polling,
- tekrar tarama/hash,
- allocation/copy,
- global lock/lock convoy,
- busy wait,
- aşırı context switch,
- fazla kernel/user geçişi,
- yanlış priority,
- batching eksikliği,
- bounded olmayan queue,
- gereksiz telemetry ve disk sorgusu,
- working-set thrashing/page-fault burst,
- storage queue saturation,
- GPU queue starvation/residency churn,
- network retransmit veya NDIS/DPC yoğunluğu,
- thermal/power throttling.

### NXB-IRL-017 — Security analysis workflow

İncelenecek sınıflar:

- trust-boundary errors,
- IOCTL/input validation,
- integer/buffer errors,
- race/TOCTOU,
- UAF/double free,
- pool/resource leaks,
- uninitialized memory,
- object lifetime,
- privilege/ACL/device permissions,
- unsafe symbolic links,
- teardown/error-path cleanup,
- fail-open ve denial-of-service koşulları.

Bulgu yaşam döngüsü:

```text
SUSPECTED -> REPRODUCIBLE -> ALTERNATIVES_ELIMINATED -> VALIDATED -> REPORT_READY
```

### NXB-IRL-018 — Clean-room behavioral model

Amaç:

- orijinal kodu kopyalamadan,
- gözlemlenen alt sistemleri anlaşılabilir ve test edilebilir biçimde modellemek,
- interface, behavior, timing, security coverage ve performance eşdeğerliğini ayrı ölçmek.

### NXB-IRL-019 — Security equivalence and regression

Her optimizasyon için:

- event kapsamı,
- tespit gecikmesi,
- race window,
- stale cache,
- kısa ömürlü olay kaybı,
- queue overflow,
- fail-open,
- teardown blind spot,
- false-positive ve stability regresyonları,
- CPU/RAM/GPU/disk/network kapsam değişiklikleri ölçülür.

### NXB-IRL-020 — Reporting pipeline

Raporlar:

- bağımsız güvenlik kök nedeni başına ayrı rapor,
- bağımsız performans kök nedeni başına ayrı rapor,
- aynı root cause'un farklı etkileri tek raporda açıklanabilir,
- yalnız `VALIDATED` bulgular gönderilir.

### NXB-IRL-021 — Additional adapters

EAC sonrasında başka anti-cheat, anti-tamper, DRM ve integrity ürünleri adapter olarak eklenir.

### NXB-IRL-022 — Release and operator tooling

Yapılacaklar:

- SemVer,
- signed releases,
- checksums,
- SBOM,
- offline installation,
- controller/target paketleri,
- recovery/operator/reproducibility belgeleri,
- manifest migration.

## 5. Full-System Instrumented Observability Track

Bu hat uygulamaların arasına gizlice giren veya fiziksel donanımı görünmez biçimde taklit eden bir bypass sistemi değildir. Amaç, kontrollü araştırma ortamında bütün sistem kaynaklarını ortak zaman çizelgesinde gözlemlemektir.

### Domainler

1. CPU ve scheduler.
2. RAM ve virtual memory.
3. GPU ve presentation.
4. Disk, storage queue ve file system.
5. Network ve NDIS.
6. PCIe, PnP, device ve signed drivers.
7. Kernel, services ve driver lifecycle.
8. Power, frequency ve thermal state.
9. Firmware, boot ve security configuration.

### Örnek korelasyon

```text
frame-time spike
 -> thread ready
 -> hard page fault
 -> disk read
 -> RAM page-in
 -> CPU scheduling delay
 -> late GPU submission
 -> queue bubble
 -> delayed present
```

### Kabul kriterleri

- hedef davranışı instrumentation olmadan ve instrumentation ile karşılaştırılır,
- ölçüm ek yükü sayısal olarak raporlanır,
- veri kaybı veya trace overflow görünür olmalıdır,
- bütün olaylar experiment/machine/boot/time kimliğine bağlanır,
- görünmezlik garantisi verilmez,
- anti-debug/anti-VM atlatma uygulanmaz,
- gerçek hedef için yalnız program kapsamındaki ve zarar vermeyen gözlem yöntemleri kullanılır.

## 6. Şu anki uygulama sırası

1. `NXB-IRL-002` deterministic lifecycle.
2. `NXB-IRL-003` evidence store.
3. `NXB-IRL-004` full-system observability fabric.
4. `NXB-IRL-005` kontrollü test sürücüsü.
5. `NXB-IRL-006` controller/target transport.
6. `NXB-IRL-007` debugger evidence.
7. Statik/runtime/semantic hat.
8. Target adapters.
9. EAC adapter.
10. Performance, security, clean-room model ve raporlama.

## 7. Devam etme protokolü

Yeni sohbet başladığında şu dosyalar sırasıyla okunmalıdır:

1. `docs/HANDOFF.md`
2. `docs/MASTER_PLAN.md`
3. `docs/FULL_SYSTEM_OBSERVABILITY.md`
4. `docs/ROADMAP.md`
5. `docs/ARCHITECTURE.md`
6. ilgili aktif blok dosyaları ve testleri.

Aktif blok tamamlanmadan sonraki zorunlu bloğa geçilmez. Her blok sonunda:

- commit SHA,
- değişen dosyalar,
- doğrulama sonuçları,
- açık riskler,
- sıradaki blok

`docs/HANDOFF.md` içine yazılır.
