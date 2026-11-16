# Atlas Trafo PDKS Kayıt Düzeltme Sistemi

Bilişim Sistemleri Analizi ve Tasarımı dersi ekip projesi.
**Ekip:** Mehmet · Gökalp · Yusuf · Fırat · **Teslim:** 07.12.2026

> Gerçek bir şirket için tasarlandı. Repoda **yalnızca sahte (sentetik) veri** bulunur; gerçek Atlas Trafo verisi asla yüklenmez.

---

## 1. Ne yapar?

Atlas Trafo (İzmir, ~2000 çalışan, gece vardiyası dahil vardiyalı üretim) kartlı PDKS kullanıyor. Kart okutmayı unutma, mükerrer okutma, okuyucu arızası, gece vardiyası gibi nedenlerle kayıtlar hatalı oluyor ve İK bunları ay sonunda Excel'de elle düzeltiyor.

Bu sistem mevcut PDKS'yi **değiştirmez**, kayıtlarını alıp yanında çalışır:

1. PDKS, kapı, yemekhane ve servis kayıtlarını içe alır. Ham kayda hiç dokunmaz.
2. Hatalı ve eksik kayıtları bulur.
3. **Kanıt varsa** (kapı / yemekhane / servis kaydı) kaydı kendisi düzeltir.
4. **Kanıt yoksa** ertesi sabah amire sorar. Cevapsız soru 3 gün sonra üst amire ve İK'ya gider.
5. Her düzeltme kim / ne zaman / eski-yeni değer / gerekçe / dayanak ile **silinemeyen** bir tabloya yazılır.
6. Fazla mesaide yazılı onay, günlük 11 saat ve yıllık 270 saat sınırlarını denetler.
7. Ay sonunda İK ayı kilitler; bordroya hazır puantaj (gün ve dakika, ücret yok) CSV olarak alınır.

### Temel kararlar
- **Çalışan aleyhine her karar İK'dadır** (KVKK m.11): devamsızlık, itirazın reddi, kart paylaşımı, plansız fazla mesai. Sistem en fazla "şüphe" ya da "uyarı" üretir.
- **Biyometri yok** (KVKK Kurulu kararı). **Akıllı telefon varsayılmaz.**
- **Kiosk yok.** Çalışan isterse İK, sistemden kayıt dökümünü PDF olarak verir; itirazı amir ya da İK sisteme girer.
- **Kart unutana:** güvenlikten zimmetli **geçici kart**; o da yoksa amir onayı.
- Kilitli ay geri açılamaz; sonradan gelen düzeltme sonraki aya "fark satırı" olur.

Sorun–tablo eşlemesi (17 sorun): [docs/veritabani.md](docs/veritabani.md).

---

## 2. Teknoloji

| Katman | Teknoloji | Not |
|---|---|---|
| Veritabanı | **Supabase (PostgreSQL)** | Tüm tablolar `pdks` şemasında; şema internete (Supabase API'ye) kapalı. Kurallar trigger ve fonksiyonlarla veritabanının içinde |
| Veritabanı dili | SQL, PL/pgSQL | Değişiklikler sıra numaralı migration dosyalarıyla |
| Şifreleme | pgcrypto (bcrypt) | Şifreler açık metin saklanmaz |
| Uygulama | **Python + Streamlit** | Amir ve İK ekranları |
| Veri işleme | pandas | Tablolar, CSV çıktısı |
| Veritabanı bağlantısı | psycopg | Doğrudan bağlantı; iki kısıtlı rol: `pdks_uygulama` (ekranlar), `pdks_gece_isi` (gece işi) |
| Gizli bilgiler | python-dotenv + `.env` | `.env` asla GitHub'a gitmez |
| Gece işi | Python betiği | Sunumda ekrandaki "Şimdi çalıştır" butonuyla; gerçek kullanımda sunucuda her gece zamanlanmış görev |
| PDF döküm | fpdf2 *(eklenecek)* | Çalışan kayıt dökümü |
| Test | SQL testleri (`supabase/tests`), pytest *(gece işiyle)* | SQL testleri sonda ROLLBACK ile iz bırakmaz |
| Raporlama | Power BI — **karar bekliyor** | Power BI Desktop yalnızca Windows'ta çalışır; zorunlu değilse grafikler Streamlit'te |
| Araçlar | Git, GitHub, GitHub Actions, Supabase CLI, psql, Claude Code | |

**Kullanılmayanlar:** biyometri, mobil uygulama, kiosk, Supabase Auth ve Supabase'in otomatik REST API'si.

---

## 3. Klasör yapısı

```
atlas_trafo/
├─ README.md
├─ .env.example              # bağlantı bilgisi şablonu (şifresiz)
├─ requirements.txt          # Python paketleri
├─ docs/
│  └─ veritabani.md          # veritabanı dokümanı ve ER diyagramı
├─ supabase/
│  ├─ migrations/            # sıra numaralı veritabanı değişiklikleri (mevcutlar asla değiştirilmez)
│  └─ tests/                 # SQL kural testleri
├─ web/                      # Streamlit uygulaması
│  ├─ app.py
│  ├─ veri.py                # veri katmanı (şimdilik örnek veri)
│  └─ sayfalar/              # amir.py, ik.py
├─ scripts/                  # yardımcı betikler (bağlantı testi vb.)
└─ .github/workflows/        # PR yetki koruması
```

---

## 4. Veritabanı

`pdks` şemasında **24 tablo** (main) + fazla mesai için **2 tablo** (PR #6). Ayrıntı ve ER diyagramı: [docs/veritabani.md](docs/veritabani.md).

| Grup | Tablolar |
|---|---|
| Kişiler ve organizasyon | kullanici, departman, calisan, kart |
| Vardiya, izin, ayar | vardiya_tanim, vardiya_plani, izin, resmi_tatil, ayar, ayar_gecmisi |
| Ham veri (değiştirilemez) | aktarim, okuyucu, ham_okutma, kanit_kaydi, okutma_isareti |
| İşleme | gece_isi, ariza, uyari |
| Gün, karar, düzeltme, dönem | gun_kaydi, amir_sorusu, itiraz, duzeltme, donem, puantaj_satiri |
| Fazla mesai (PR #6) | fazla_mesai_onayi, fazla_mesai_plani |

**Veritabanının zorladığı kurallar:** ham kayıt, `duzeltme` ve `puantaj_satiri` değiştirilemez ve silinemez · `gun_kaydi` yalnızca `pdks.duzeltme_uygula()` ile değişir · devamsızlık ve itiraz reddi yalnızca İK · kilitli ay açılamaz.

| Migration | İçerik |
|---|---|
| `20261114000100_tablolar.sql` | Şema ve 24 tablo |
| `20261114000200_kurallar.sql` | Trigger'lar, fonksiyonlar, görünümler |
| `20261114000300_roller_ve_yetkiler.sql` | `pdks_uygulama` ve `pdks_gece_isi` rolleri |
| `20261114000400_varsayilan_ayarlar.sql` | Varsayılan ayarlar ve 4 vardiya |
| `20261115000500_fazla_mesai.sql` *(PR #6)* | Yazılı onay, plan, 11 / 270 saat sınırı |

---

## 5. Kurulum ve çalıştırma

```bash
# 1) Python ortamı
python -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 2) Bağlantı bilgileri
cp .env.example .env                 # değerleri Supabase > Project Settings > Database'den doldurun

# 3) Ekranlar
streamlit run web/app.py
```

**Veritabanı kurulumu (tek kişi, bir kez):** Supabase SQL Editor'de `supabase/migrations` altındaki dosyalar **sırayla** çalıştırılır; ardından rollere şifre verilir (bkz. `docs/veritabani.md`).

**Testler:** `psql "$PDKS_ADMIN_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/kurallar_testi.sql` — sonda "TÜM TESTLER GEÇTİ" yazmalı. Testler veritabanında iz bırakmaz.

---

## 6. Durum ve yol haritası

| Parça | Durum |
|---|---|
| Veritabanı şeması, kurallar, roller (32 test) | ✅ main |
| Amir ve İK ekranları | ✅ main — örnek veriyle; veritabanına bağlanacak |
| Fazla mesai (33 test) + bağlantı testi | ⏳ PR #6 |
| Kiosk parçalarının veritabanından kaldırılması | ⬜ Yapılacak (yeni migration) |
| Kart paylaşımı şüphe kuralı + fiili fazla mesai uyarıları | ⬜ Yapılacak (migration 0600) |
| Geçici kart ve zimmet | ⬜ Yapılacak (migration 0700) |
| Saatlik izin | ⬜ Yapılacak (migration 0800) |
| Sahte veri (çalışan, okutma, bilerek konmuş hatalar) | ⬜ Yapılacak |
| Gece işi (içe aktarma → işaretleme → günlük kayıt → kanıtla düzeltme → amire soru → uyarı) | ⬜ Yapılacak |
| Ekranların veritabanına bağlanması, giriş | ⬜ Yapılacak |
| Ay kilidi, bordro CSV, çalışan PDF dökümü | ⬜ Yapılacak |
| Raporlama (Power BI veya Streamlit) | ⬜ Karar bekliyor |
| Rapor diyagramları (Use Case, DFD, AS-IS, TO-BE) | ⬜ Yapılacak |

**Karar bekleyenler:** Power BI zorunlu mu · amir/İK ekranlara nasıl giriş yapacak (öneri: `kullanici` tablosunda bcrypt şifre).

---

## 7. Çalışma kuralları

- `main` korumalıdır; doğrudan push yapılmaz. PR'ları birleştirme, kapatma, etiketleme ve atama yalnızca ekip liderindedir (otomasyonla korunur).
- Her iş için dal: `feature/<issue-no>-kisa-ad`. Her iş bir issue olarak açılır.
- Her PR en az 1 onay alır.
- Commit mesajları Türkçe ve kısa: `feat(db): ...`, `fix: ...`, `docs: ...`, `test: ...`.
- `supabase/migrations` altındaki mevcut dosyalar **asla değiştirilmez**; her değişiklik yeni numaralı dosyadır ve testiyle gelir.
- Gizli bilgiler (şifre, bağlantı adresi) koda, loglara, ekran görüntülerine yazılmaz; yalnızca `.env` dosyasında tutulur.
- SQL her zaman parametreli yazılır.
- Ekran görüntülerinde çalışan adları ve sicil numaraları bulanıklaştırılır.
