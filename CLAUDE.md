# CLAUDE.md — Atlas Trafo PDKS Kayıt Düzeltme Sistemi

Claude Code bu dosyayı her oturumda okur. Buradaki kurallar her istekte geçerlidir.

## 1. Proje özeti
- Bilişim Sistemleri Analizi ve Tasarımı ders projesi; 4 kişilik ekip, teslim 30.12.2026.
- Firma: Atlas Trafo (İzmir), ~2000 çalışan, gece vardiyası dahil vardiyalı üretim.
- Mevcut kartlı PDKS değişmez. Sistem onun kayıtlarını alır, hatalı/eksik olanları bulur:
  kanıt (kapı, yemekhane, servis kaydı) varsa kendisi düzeltir, yoksa amire sorar.
- Çalışan aleyhine karar (devamsızlık, itiraz reddi, kart paylaşımı) her zaman İK'dadır (KVKK m.11).
- Biyometri yok. Akıllı telefon varsayılmaz.
- Veritabanı: Supabase (PostgreSQL). Tüm tablolar `pdks` şemasında (24 tablo). Ayrıntı: `docs/veritabani.md`.
- Uygulama: Python + Streamlit. Raporlar: Power BI.

## 2. Değişmez veritabanı kuralları
- `ham_okutma`, `kanit_kaydi`, `aktarim`, `okutma_isareti` değiştirilemez ve silinemez.
- `gun_kaydi` doğrudan UPDATE edilmez; yalnızca `pdks.duzeltme_uygula(...)` ile değişir.
- `duzeltme` ve `puantaj_satiri` silinemez, değiştirilemez.
- Kilitli ay (`donem.durum = 'kilitli'`) açılamaz; sonradan gelen düzeltme fark satırı olur.
- Ücret hesaplanmaz; puantajda yalnızca gün ve dakika vardır.

## 3. Migration kuralı
- `supabase/migrations/` altındaki mevcut dosyalar ASLA değiştirilmez.
- Her değişiklik yeni, sıra numaralı bir dosyadır: `YYYYMMDDHHMMSS_kisa_ad.sql`
  (ör. `20261115000500_fazla_mesai.sql`).
- Her yeni kural için `supabase/tests/` altına test eklenir; testler sonda ROLLBACK ile iz bırakmaz.

## 4. Güvenlik (asla ihlal etme)
- `.env` ve `.env.*` dosyaları okunmaz, yazdırılmaz, commit edilmez (`.env.example` hariç).
- Şifre, bağlantı adresi veya anahtar koda, loglara, ekran çıktısına yazılmaz.
- Repoda yalnızca sahte (sentetik) veri olur; gerçek Atlas Trafo verisi asla.
- SQL her zaman parametreli yazılır; kullanıcı girdisi SQL metnine eklenmez.
- Supabase'e veya herhangi bir canlı veritabanına Fırat'ın açık onayı olmadan komut çalıştırılmaz.
- `main` dalına ve başkasının dalına push yapılmaz.

## 5. Git düzeni
- Her iş ayrı dalda: `feature/<no>-kisa-ad`.
- Commit mesajları Türkçe ve kısa: `feat(db): ...`, `fix: ...`, `chore: ...`, `test: ...`.
- Commit ve push öncesi Fırat'a ne değiştiğini göster ve onay al.

## 6. Fırat ile çalışma şekli (öğreterek ilerle)
Fırat YBS 3. sınıf; SQL'de JOIN ve GROUP BY biliyor, Python'da yeni. Her adımda:
1. Ne yapacağını önce 2-3 cümleyle anlat.
2. Yeni kavramları sade dille, ilk kez gören birine anlatır gibi açıkla.
3. Basit kısımları `TODO(Fırat)` olarak bırak; ipucu ver, çözümü verme.
4. Adım sonunda anladığını ölçen 2-3 soru sor ve cevabını bekle.
