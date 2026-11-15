# Atlas Trafo PDKS Kayıt Düzeltme Sistemi

Bilişim Sistemleri Analizi ve Tasarımı dersi ekip projesi (4 kişi, teslim: 30.12.2026).

## Ne yapar?
- Fabrikadaki kartlı PDKS kayıtlarını alır, hatalı/eksik kayıtları bulur.
- Kanıt varsa (kapı / yemekhane / servis kaydı) kendisi düzeltir, yoksa amire sorar.
- Ham kayda dokunmaz; her düzeltme kim / ne zaman / eski-yeni / gerekçe ile silinemeyen tabloda tutulur.
- Fazla mesaide yazılı onay, günlük 11 saat ve yıllık 270 saat sınırlarını kontrol eder.
- Ay sonunda bordroya hazır puantaj çıkarır; ücret hesaplamaz.
- Çalışan aleyhine kararı sistem vermez, İK verir (KVKK m.11). Biyometri kullanılmaz.
- Kiosk yoktur: çalışan isterse İK sistemden kayıt dökümünü PDF olarak verir; itirazı amir ya da İK sisteme girer.

## Teknoloji
| Katman | Teknoloji |
|---|---|
| Veritabanı | Supabase (PostgreSQL). Tüm tablolar `pdks` şemasında; şema internete kapalıdır. Ayrıntı: [docs/veritabani.md](docs/veritabani.md) |
| Uygulama | Python + Streamlit (amir ve İK ekranları), pandas |
| Veritabanı bağlantısı | psycopg (doğrudan bağlantı, ayrı yetkili roller: `pdks_uygulama`, `pdks_gece_isi`) |
| Gece işi | Python betiği. Sunumda ekrandaki "Şimdi çalıştır" butonuyla; gerçek kullanımda sunucuda zamanlanmış görev olarak her gece çalışır |
| Test | SQL testleri (`supabase/tests`), Docker'da yerel PostgreSQL + psql |
| Raporlama | Power BI — *karar bekliyor* (Power BI Desktop yalnızca Windows'ta çalışır) |
| Veri | Yalnızca sentetik (sahte) veri; gerçek Atlas Trafo verisi repoya girmez |

## Çalışma kuralları
- `main` korumalıdır; doğrudan push yapılmaz.
- Her iş için dal: `feature/<issue-no>-kisa-ad`
- Her PR en az 1 onay alır.
- Gizli bilgiler (şifre, bağlantı dizesi) koda yazılmaz; `.env` dosyasında tutulur.
- Mevcut migration dosyaları değiştirilmez; her değişiklik yeni numaralı migration dosyasıdır.
