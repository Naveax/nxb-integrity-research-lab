# CPU/GPU Observability Track

## Amaç

CPU veya GPU'yu gizlice taklit etmek yerine, kontrollü araştırma ortamında yürütme ve iş kuyruğu davranışını mümkün olan en düşük ek yükle gözlemlemek.

## Neden doğrudan görünmez bir arabulucu hedeflenmiyor?

- Modern korumalı yazılımlar zamanlama, topoloji ve donanım davranışındaki farkları gözlemleyebilir.
- Tam görünmezlik doğrulanabilir bir mühendislik şartı değildir.
- Donanımı taklit eden katman, hedef davranışını ölçülemeyecek kadar değiştirebilir.
- Araştırma platformunun amacı bypass değil, kanıt kalitesidir.

Bu nedenle mimari, görünmezlik yerine şu hedefleri kullanır:

1. Düşük ve ölçülebilir overhead.
2. Kaynak ve zaman provenance'ı.
3. Trace loss görünürlüğü.
4. Runtime adreslerin statik RVA'larla korelasyonu.
5. Aynı deneyde instrumentation açık/kapalı karşılaştırması.

## CPU veri yolu

```text
Target thread
    -> Windows scheduler / CPU
    -> ETW sampled profile
    -> context switch / ready thread
    -> DPC / ISR / exception events
    -> optional hardware control-flow trace
    -> normalized execution events
    -> module + RVA correlation
```

### Katmanlar

#### C0 — Baseline

- instrumentation kapalı,
- yalnız sistem/binary envanteri,
- referans CPU ve frame-time ölçümü.

#### C1 — ETW sampling

- sampled profile,
- call stacks,
- process/thread/image load,
- context switch,
- ready thread,
- DPC/ISR,
- hard faults.

#### C2 — Kernel debugger correlation

- module base,
- runtime addresses,
- stack snapshots,
- symbol provenance,
- debugger pause overhead.

#### C3 — Hardware trace

Desteklenen donanım ve işletim sistemi kombinasyonlarında control-flow trace değerlendirilir. Bu katman opsiyoneldir ve capability probing ile etkinleştirilir.

#### C4 — Controlled instruction mediator

Yalnız kendi test binary'leri ve sentetik fixture'lar için emulator/hypervisor tabanlı instruction tracing. Gerçek korumalı hedefler için anti-detection veya görünmez çalıştırma özelliği geliştirilmez.

## GPU veri yolu

```text
Application graphics API
    -> user-mode graphics driver
    -> DXGKRNL
    -> command submission / scheduling
    -> GPU engine execution
    -> present
    -> ETW/GPUView/PIX evidence
```

### Katmanlar

#### G0 — Baseline

- instrumentation kapalı frame-time,
- GPU utilization,
- clock/temperature/power snapshot,
- aynı sahne veya replay.

#### G1 — DXGKRNL ETW

- command buffer submission,
- queue/context scheduling,
- resource create/destroy/lock/bind,
- present,
- preemption ve wait zamanları.

#### G2 — GPUView correlation

- CPU thread -> submission -> GPU engine -> present zinciri,
- queue saturation,
- frame pacing,
- CPU/GPU bubbles.

#### G3 — PIX capture

Yalnız izinli, uyumlu D3D11/D3D12 senaryolarında ayrıntılı frame capture. Capture overhead ayrıca ölçülür.

#### G4 — Synthetic GPU mediator

Kendi shader, command-list ve resource fixture'larımız için komut kaydı yapan kontrollü test katmanı. Üçüncü taraf korumalı hedefi yanıltmak için kullanılmaz.

## Normalized event modeli

```json
{
  "schema_version": 1,
  "experiment_id": "...",
  "boot_id": "...",
  "event_id": 1,
  "timestamp_utc": "...",
  "timestamp_monotonic_ns": 0,
  "domain": "cpu|gpu",
  "source": "etw|debugger|hardware-trace|pix|synthetic",
  "process_id": 0,
  "thread_id": 0,
  "module_sha256": "...",
  "module_rva": "0x0",
  "engine_or_core": "...",
  "event_type": "...",
  "payload": {},
  "evidence_class": "OBSERVED",
  "overhead_profile": "..."
}
```

## Ölçüm matrisi

Her profil için en az:

1. Baseline — instrumentation yok.
2. Minimal — en düşük yeterli trace.
3. Diagnostic — ayrıntılı trace.
4. Tekrarlı koşular.
5. Trace loss ve buffer kullanım kaydı.
6. CPU, p95/p99 frame-time ve 1%/0.1% low farkı.

## İlk uygulama görevleri

- [ ] CPU/GPU capability probe.
- [ ] DXGKRNL provider envanteri.
- [ ] Minimal CPU WPRP.
- [ ] Minimal GPU WPRP.
- [ ] Overhead calibration manifesti.
- [ ] Normalized event JSON Schema.
- [ ] GPUView export parser araştırması.
- [ ] PIX metadata importer araştırması.
- [ ] Controlled CPU fixture.
- [ ] Controlled GPU fixture.

## Başarı kriteri

Sistem, belirli bir performans olayını şu zincire bağlayabilmelidir:

```text
experiment -> target hash -> process/thread -> CPU/GPU event -> module/RVA -> static function -> hypothesis -> validation result
```
