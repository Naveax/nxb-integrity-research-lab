# Full-System Observability Fabric

Bu belge CPU/GPU gözlem hattını tam sistem gözlemlenebilirliği mimarisine genişletir.

## Amaç

Korunan bir hedefin çalışma davranışını yalnız işlemci veya ekran kartı açısından değil, bütün donanım ve işletim sistemi zinciri boyunca korele etmek:

- CPU ve scheduler,
- RAM, virtual memory ve cache davranışı,
- GPU ve görüntü sunum zinciri,
- disk, dosya sistemi ve depolama kuyruğu,
- ağ yığını,
- PCIe, DMA ve aygıt topolojisi,
- kernel, driver ve interrupt zinciri,
- güç, frekans ve termal durum,
- firmware, boot ve güvenlik durumu,
- registry, servis, process, thread ve handle yaşam döngüsü.

Platform donanımı görünmez biçimde taklit etmeyi hedeflemez. Hedef; düşük ve ölçülebilir ek yükle yüksek kaliteli kanıt üretmek, veri kaybını görünür kılmak ve olayları ortak zaman çizelgesinde birleştirmektir.

## Üst seviye veri yolu

```text
Protected target
    -> process/thread/runtime state
    -> CPU / RAM / GPU / storage / network / device events
    -> timestamp normalization
    -> experiment + boot + target identity
    -> cross-domain correlation engine
    -> module/RVA/static-function correlation
    -> security/performance hypotheses
    -> controlled validation
```

## Gözlem alanları

### S0 — Sistem kimliği ve zaman tabanı

Her olay aşağıdaki bağlara sahip olmalıdır:

- `experiment_id`,
- `boot_id`,
- `machine_id`,
- hedef binary SHA-256,
- UTC zaman,
- monotonic zaman,
- clock source,
- controller/target clock offset,
- collector adı ve sürümü.

Bu alan kurulmadan farklı kaynaklardan gelen olaylar güvenilir biçimde birleştirilemez.

### C — CPU ve scheduler

Toplanacak veriler:

- sampled CPU stacks,
- process/thread start-stop,
- context switch ve ready-thread,
- core migration,
- CPU frequency/power state,
- DPC/ISR,
- exception ve mode transition,
- page-fault ile yürütme korelasyonu,
- desteklenen sistemlerde hardware control-flow trace,
- instrumentation overhead.

Kök neden örnekleri:

- gereksiz polling,
- busy wait,
- lock contention,
- aşırı context switch,
- yüksek DPC/ISR süresi,
- yanlış thread priority/affinity,
- CPU frequency throttling.

### M — RAM ve virtual memory

Toplanacak veriler:

- physical memory topolojisi ve kapasite,
- NUMA node bilgisi,
- commit/working set/private bytes,
- hard/soft page faults,
- standby/modified list baskısı,
- mapped/image/private region sınıfları,
- page protection geçişleri,
- executable page yaşam döngüsü,
- allocation/free ve heap/pool davranışı,
- memory compression ve paging activity,
- cache/TLB etkisini temsil eden desteklenen sayaçlar,
- snapshot provenance.

Kök neden örnekleri:

- working-set thrashing,
- gereksiz allocation/copy,
- page-fault burst,
- memory leak,
- NUMA uzak erişimi,
- bounded olmayan cache veya queue,
- sürekli page protection değişimi.

### G — GPU ve presentation

Toplanacak veriler:

- DXGKRNL queue/context scheduling,
- graphics/compute/copy submission,
- preemption ve wait süreleri,
- resource create/destroy/map/bind,
- GPU memory budget ve residency,
- CPU submit -> GPU execute -> present zinciri,
- frame pacing,
- GPU engine utilization,
- clock/power/thermal snapshot,
- izinli D3D11/D3D12 PIX metadata,
- capture overhead.

Kök neden örnekleri:

- queue starvation,
- CPU/GPU bubble,
- resource residency churn,
- gereksiz copy,
- present gecikmesi,
- GPU memory pressure,
- shader/PSO preparation gecikmesi.

### D — Disk ve dosya sistemi

Toplanacak veriler:

- fiziksel disk ve bus türü,
- partition/volume/filesystem envanteri,
- read/write/flush/trim,
- I/O size ve latency,
- queue depth,
- file create/open/read/write/close,
- metadata ve directory enumeration,
- paging I/O,
- cache hit/miss için erişilebilir göstergeler,
- filter-driver zinciri,
- storage driver ve firmware kimliği.

Kök neden örnekleri:

- senkron küçük I/O,
- gereksiz flush,
- tekrar tekrar dosya/hash taraması,
- filtre sürücüsü gecikmesi,
- page-in burst,
- queue saturation,
- disk power-state wake-up.

### N — Ağ

Toplanacak veriler:

- adapter ve driver envanteri,
- TCP/UDP bağlantı yaşam döngüsü,
- DNS ve name-resolution zamanlaması,
- send/receive throughput,
- retransmit ve packet-loss göstergeleri,
- connection setup/TLS zamanlaması için erişilebilir metadata,
- NDIS/DPC maliyeti,
- interface queue ve offload capability,
- network namespace/profile state.

Kök neden örnekleri:

- aşırı küçük paket,
- gereksiz polling/heartbeat,
- retransmission,
- DNS gecikmesi,
- NDIS/DPC yoğunluğu,
- bounded olmayan telemetry upload kuyruğu.

### B — PCIe, DMA ve aygıt topolojisi

Toplanacak veriler:

- PnP device tree,
- PCI/PCIe bus-device-function kimlikleri erişilebildiği ölçüde,
- driver/INF/signature provenance,
- interrupt mode ve kaynakları için erişilebilir metadata,
- IOMMU/virtualization capability,
- device power state,
- surprise remove/restart olayları,
- WHEA/hardware error kayıtları.

Bu katman, belirli bir performans olayının CPU/GPU dışındaki bus veya aygıt yolundan kaynaklanıp kaynaklanmadığını ayırmak için kullanılır.

### K — Kernel, driver ve işletim sistemi

Toplanacak veriler:

- kernel build ve boot configuration,
- loaded driver/filter listesi,
- service/driver lifecycle,
- process/thread/image callbacks için kendi kontrollü fixture'larımız,
- registry/file/object olayları,
- handle/object lifetime,
- timer/DPC/work-item davranışı,
- bugcheck/WER metadata,
- ETW trace loss ve buffer state.

### P — Güç, frekans ve termal durum

Toplanacak veriler:

- Windows power plan,
- processor performance state,
- GPU power/clock metadata erişilebildiği ölçüde,
- battery/AC state,
- thermal zone verisi erişilebildiği ölçüde,
- throttling göstergeleri,
- sleep/modern standby ve device power transition.

Performans karşılaştırması sırasında güç ve sıcaklık değişkenleri sabitlenmeden sonuç `VALIDATED` sayılmaz.

### F — Firmware, boot ve güvenlik durumu

Toplanacak veriler:

- BIOS/UEFI ve baseboard kimliği,
- Secure Boot,
- TPM,
- VBS/HVCI/Device Guard durumu,
- hypervisor ve SLAT capability,
- BCD/debug state,
- code-integrity policy metadata,
- OS build ve güncelleme kimliği.

Bu alanlar davranışı değiştirebileceği için her deney manifestine bağlanmalıdır.

## Cross-domain korelasyon örneği

```text
frame-time spike
    -> game thread ready fakat çalışamıyor
    -> hard page fault
    -> storage read queue artışı
    -> image/private page RAM'e alınıyor
    -> CPU thread yeniden çalışıyor
    -> GPU submission gecikiyor
    -> graphics queue boş kalıyor
    -> present geç tamamlanıyor
```

Başka bir örnek:

```text
periodic anti-integrity workload
    -> timer wake-up
    -> process/module inventory
    -> file metadata reads
    -> repeated hashing
    -> memory allocation burst
    -> CPU package frequency/power değişimi
    -> frame-critical thread ile contention
```

## Normalized event sözleşmesi

```json
{
  "schema_version": 1,
  "experiment_id": "...",
  "boot_id": "...",
  "machine_id": "...",
  "event_id": 1,
  "timestamp_utc": "...",
  "timestamp_monotonic_ns": 0,
  "domain": "cpu|memory|gpu|storage|network|bus|kernel|power|firmware",
  "source": "etw|counter|debugger|hardware-trace|wmi|cim|pix|synthetic",
  "process_id": 0,
  "thread_id": 0,
  "device_id": "...",
  "module_sha256": "...",
  "module_rva": "0x0",
  "event_type": "...",
  "payload": {},
  "evidence_class": "OBSERVED",
  "collector": {
    "name": "...",
    "version": "..."
  },
  "overhead_profile": "baseline|minimal|diagnostic"
}
```

## Capture seviyeleri

### L0 — Inventory

Statik capability ve konfigürasyon envanteri. Sürekli trace yoktur.

### L1 — Minimal

En düşük yeterli olay seti:

- CPU sample,
- context switch,
- process/thread/image,
- hard fault,
- disk I/O,
- DXGKRNL present/queue,
- network connection summary.

### L2 — Diagnostic

Stack capture ve daha ayrıntılı resource lifecycle etkinleştirilir.

### L3 — Focused deep trace

Yalnız belirli, kısa ve kontrollü deneylerde ayrıntılı debugger/hardware trace/PIX veya sentetik fixture kullanılır.

## Overhead ve veri bütçesi

Her collector için zorunlu alanlar:

- CPU overhead,
- memory overhead,
- disk write rate,
- event rate,
- dropped event count,
- buffer utilization,
- target behavior delta.

Queue, spool ve trace dosyaları bounded olmak zorundadır. Veri kaybı sessizce gerçekleşemez.

## Güvenlik sınırı

Bu mimari:

- korumayı devre dışı bırakmaz,
- hedef kodunu değiştirmez,
- anti-debug veya anti-VM bypass geliştirmez,
- donanım kimliğini sahteleyerek hedefi yanıltmaz,
- üçüncü taraf kullanıcı veya üretim hizmetleri üzerinde zarar verici test yapmaz.

Kendi test programlarımızda emulator, synthetic device veya controlled mediator kullanılabilir; gerçek hedefte yalnız yetkili ve zarar vermeyen gözlem yöntemleri uygulanır.

## Uygulama sırası

1. Full-system capability inventory ve JSON Schema.
2. Ortak event schema ve zaman kimliği.
3. Minimal CPU/RAM/disk/GPU WPRP.
4. Network ve device/driver provider envanteri.
5. Power/thermal/firmware snapshot.
6. Trace-loss ve overhead ölçümü.
7. Cross-domain correlation engine.
8. Controlled CPU, memory, storage, GPU ve network fixtures.
9. Target adapter entegrasyonu.

## Başarı kriteri

Platform bir problemi şu zincirle açıklayabilmelidir:

```text
experiment
 -> machine/boot/target hash
 -> process/thread/device
 -> CPU/RAM/GPU/disk/network eventleri
 -> ortak zaman çizelgesi
 -> module/RVA/static function
 -> kök neden hipotezi
 -> kontrollü doğrulama
 -> güvenlik veya performans raporu
```
