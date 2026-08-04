# Architecture

## Design goals

1. Her gözlemi tam hedef sürümü ve SHA-256 ile ilişkilendirmek.
2. Statik çıkarım, runtime gözlemi ve doğrulanmış sonucu birbirinden ayırmak.
3. Ölçüm altyapısının hedef davranışına etkisini ölçmek.
4. Deneyleri aynı koşullarda yeniden çalıştırabilmek.
5. Ham kanıtı public kaynak kodundan ayırmak.

## Components

### Workspace controller

Deney dizinlerini, manifestleri, evidence hash listesini ve araç sürümlerini yönetir.

### Baseline collector

İşletim sistemi, sürücü, servis, süreç, ağ ve hedef dosya hash envanterini kaydeder.

### Trace controller

WPR/ETW oturumlarını başlatır ve durdurur. İlk profil `GeneralProfile` kullanır; sonraki bloklarda özel WPRP profili eklenecektir.

### Kernel-debug preparation

KDNET uygunluğunu denetler ve yalnız açık `-Apply` seçeneğiyle boot debug yapılandırmasını uygular. Otomatik yeniden başlatma yapmaz.

### Evidence finalizer

Deney dosyaları için SHA-256 listesi çıkarır ve manifesti `finalized` durumuna geçirir.

## Trust boundaries

- Controller ve target ayrı güven alanlarıdır.
- Target üzerindeki çıktı tek başına güvenilir kabul edilmez; controller kayıtlarıyla korele edilir.
- LLM tarafından üretilen adlandırmalar `INFERRED` veya `HYPOTHESIS` olarak başlar.
- Bir bulgu yalnız tekrar üretilebilir kanıt ve alternatif açıklamaların elenmesi sonrasında `VALIDATED` olur.

## Repository boundary

Public repoda yalnız araç kaynakları, şemalar, test fixture'ları ve sentetik örnekler tutulur. Gerçek hedef binary'leri, dump'lar, ETL dosyaları ve disclosure öncesi bulgular repo dışında saklanır.
