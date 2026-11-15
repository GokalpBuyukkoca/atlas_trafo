# Atlas Trafo PDKS Kayıt Düzeltme Sistemi

Bilişim Sistemleri Analizi ve Tasarımı dersi ekip projesi (4 kişi, teslim: 30.12.2026).

## Ne yapar?
- Fabrikadaki kartlı PDKS kayıtlarını her gece alır, hatalı/eksik kayıtları bulur.
- Kanıt varsa (kapı / yemekhane kaydı) kendisi düzeltir, yoksa sabah amire sorar.
- Ham kayda dokunmaz; her düzeltme kim / ne zaman / eski-yeni / gerekçe ile silinemeyen tabloda tutulur.
- Ay sonunda bordroya hazır puantaj çıkarır.
- Çalışan kiosktan son 2 haftasını görüp itiraz edebilir.
- Çalışan aleyhine kararı sistem vermez, İK verir. Ücret hesaplamaz.

## Teknoloji
- SQL Server Express
- Python + Streamlit
- Gece işi: Python betiği (Windows Görev Zamanlayıcı)
- Veri: sentetik (≈100 sahte çalışan, 1–2 ay)

## Çalışma kuralları
- `main` korumalıdır; doğrudan push yapılmaz.
- Her iş için dal: `feature/<issue-no>-kisa-ad`
- Her PR en az 1 onay alır.
- Gizli bilgiler (şifre, bağlantı dizesi) koda yazılmaz; `.env` dosyasında tutulur.
