# NXB Integrity Research Lab

Yetkilendirilmiş güvenlik, runtime gözlemlenebilirliği, tersine mühendislik ve performans araştırması için tekrarlanabilir Windows laboratuvarı.

Proje yalnızca Easy Anti-Cheat'e bağlı değildir. Anti-cheat, anti-tamper, DRM, integrity kontrolü, korumalı kullanıcı modu bileşenleri ve kernel sürücüleri gibi farklı hedefler için ortak deney altyapısı sağlar.

## Devam etme ve plan

Yeni bir sohbet veya geliştirme oturumu başlarken sırayla okuyun:

1. [Project handoff](docs/HANDOFF.md)
2. [Canonical master plan](docs/MASTER_PLAN.md)
3. [Roadmap](docs/ROADMAP.md)
4. [CPU/GPU observability track](docs/CPU_GPU_OBSERVABILITY.md)
5. [Architecture](docs/ARCHITECTURE.md)

Aktif çalışma kaydı: **NXB-IRL-002 — issue #1**.

## İlk kapsam

- Deney manifestleri ve kanıt sınıflandırması
- Sistem, servis, sürücü, süreç ve binary baseline toplama
- SHA-256 tabanlı hedef sürüm sabitleme
- WPR/ETW performans izleri
- KDNET hazırlık denetimi
- Deney sonunda evidence hash listesi
- Statik analiz ile runtime kanıtlarını eşleştirmek için not şablonları
- CPU/GPU instruction, scheduling ve command-queue gözlem hattı

## Mimari

### Controller / Debug Host

- WinDbg ve Windows Performance Toolkit kurulu ayrı Windows bilgisayar
- Kernel-debug oturumunu ve deney kayıtlarını yönetir
- ETL, dump, sembol ve raporları saklar

### Target

- Temiz ve geri döndürülebilir Windows kurulumu
- İncelenen hedefin tam sürümü ve SHA-256 envanteri
- Kişisel dosya, günlük hesap ve üçüncü taraf kullanıcı verisi bulunmayan test ortamı

### Çalışma hatları

1. **Kontrollü VM hattı:** Kendi test sürücülerimizi, telemetriyi ve otomasyonu doğrular.
2. **Fiziksel target hattı:** Program kapsamındaki gerçek korumalı yazılımı standart Windows gözlem araçlarıyla inceler.
3. **CPU/GPU observability hattı:** ETW/WPR, DXGKRNL/GPUView, uyumlu PIX senaryoları ve proje tarafından sahip olunan fixture'larda kontrollü instruction/command tracing.

Bu proje anti-VM atlatma, anti-debug bypass, koruma etkisizleştirme veya hedef kodu değiştirme özelliği geliştirmez. Görünmezlik yerine düşük ve ölçülebilir overhead, provenance ve tekrar üretilebilirlik hedeflenir.

## Başlangıç

PowerShell'i yönetici olarak açın:

```powershell
Set-ExecutionPolicy -Scope Process Bypass

git clone https://github.com/Naveax/nxb-integrity-research-lab.git
cd nxb-integrity-research-lab

.\scripts\Initialize-Lab.ps1 -Root C:\NXB-Lab -Role Target
```

Yeni deney:

```powershell
$exp = .\scripts\New-Experiment.ps1 `
  -Root C:\NXB-Lab `
  -Name "Baseline-Idle" `
  -Hypothesis "Korunan hedef çalışmıyorken temiz sistem tabanı"
```

Baseline:

```powershell
.\scripts\Capture-Baseline.ps1 `
  -ExperimentPath $exp `
  -TargetPaths "C:\Path\To\Target"
```

Performans izi:

```powershell
.\scripts\Start-PerformanceTrace.ps1 -ExperimentPath $exp
# Kontrollü deneyi gerçekleştirin.
.\scripts\Stop-PerformanceTrace.ps1 -ExperimentPath $exp
.\scripts\Finalize-Experiment.ps1 -ExperimentPath $exp
```

Durum ve bütünlük:

```powershell
.\scripts\Get-ExperimentStatus.ps1 -ExperimentPath $exp
.\scripts\Test-EvidenceIntegrity.ps1 -ExperimentPath $exp
```

## Kanıt sınıfları

- `OBSERVED`: Trace, debugger, hash veya kontrollü deneyle doğrudan görüldü.
- `INFERRED`: Kod ve veri akışından çıkarıldı.
- `HYPOTHESIS`: Deneyle sınanmayı bekliyor.
- `VALIDATED`: Bağımsız kanıtlarla doğrulandı.
- `REJECTED`: Deney tarafından reddedildi.

## Güvenlik ve veri yönetimi

Binary, memory dump, ETL, sembol önbelleği, kişisel veri veya raporlanmamış bulgu kanıtlarını public repoya commit etmeyin. Varsayılan `.gitignore` bu sınıfların yaygın yollarını dışlar.

Ayrıntılar:

- [Master plan](docs/MASTER_PLAN.md)
- [Handoff](docs/HANDOFF.md)
- [Mimari](docs/ARCHITECTURE.md)
- [CPU/GPU gözlem hattı](docs/CPU_GPU_OBSERVABILITY.md)
- [Yol haritası](docs/ROADMAP.md)
- [Güvenlik politikası](SECURITY.md)
