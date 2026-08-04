# NXB Integrity Research Lab

Yetkilendirilmiş güvenlik, runtime gözlemlenebilirliği, tersine mühendislik ve performans araştırması için tekrarlanabilir Windows laboratuvarı.

Proje yalnızca Easy Anti-Cheat'e bağlı değildir. Anti-cheat, anti-tamper, DRM, integrity kontrolü, korumalı kullanıcı modu bileşenleri ve kernel sürücüleri gibi farklı hedefler için ortak deney altyapısı sağlar.

## İlk kapsam

- Deney manifestleri ve kanıt sınıflandırması
- Sistem, servis, sürücü, süreç ve binary baseline toplama
- SHA-256 tabanlı hedef sürüm sabitleme
- WPR/ETW performans izleri
- KDNET hazırlık denetimi
- Deney sonunda evidence hash listesi
- Statik analiz ile runtime kanıtlarını eşleştirmek için not şablonları

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

Bu başlangıç sürümü anti-VM atlatma, anti-debug bypass, koruma etkisizleştirme veya hedef kodu değiştirme özelliği içermez.

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

## Kanıt sınıfları

- `OBSERVED`: Trace, debugger, hash veya kontrollü deneyle doğrudan görüldü.
- `INFERRED`: Kod ve veri akışından çıkarıldı.
- `HYPOTHESIS`: Deneyle sınanmayı bekliyor.
- `VALIDATED`: Bağımsız kanıtlarla doğrulandı.
- `REJECTED`: Deney tarafından reddedildi.

## Güvenlik ve veri yönetimi

Binary, memory dump, ETL, sembol önbelleği, kişisel veri veya raporlanmamış bulgu kanıtlarını public repoya commit etmeyin. Varsayılan `.gitignore` bu sınıfların yaygın yollarını dışlar.

Ayrıntılar:

- [Mimari](docs/ARCHITECTURE.md)
- [Yol haritası](docs/ROADMAP.md)
- [Güvenlik politikası](SECURITY.md)
