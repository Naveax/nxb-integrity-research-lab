# Security Policy

## Intended use

Bu proje yalnız yetkilendirilmiş güvenlik araştırması, performans analizi, eğitim ve kontrollü laboratuvar doğrulaması içindir.

## Do not commit

- Üçüncü taraf proprietary binary veya kaynak kodu
- Memory dump, kernel dump veya ETL kanıtı
- Kimlik bilgileri, sertifika private key'leri veya debug anahtarları
- Kişisel ya da üçüncü taraf kullanıcı verisi
- Disclosure tamamlanmamış güvenlik açığı ayrıntıları
- Koruma atlatmaya veya üretim ortamında kaçınmaya hazır operasyonel materyal

## Reporting project vulnerabilities

Bu repodaki araçlarda bir güvenlik sorunu bulunursa public issue açmadan önce repository owner ile özel kanaldan iletişim kurulmalıdır.

## Research discipline

- Testler yalnız izinli hedef ve hesaplarda yürütülür.
- En düşük etkili doğrulama yöntemi kullanılır.
- Availability veya üçüncü taraf verisi risk altına girerse deney durdurulur.
- Hipotez ile doğrulanmış bulgu aynı dilde sunulmaz.
