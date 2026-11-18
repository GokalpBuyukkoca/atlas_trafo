# Ekran fonksiyonları (RPC)

Ekranlar veritabanına **yazmak** için yalnızca bu fonksiyonları çağırır. Tablolara doğrudan `insert` / `update` yetkisi yoktur; okuma ise `select` ile yapılır ve RLS her kullanıcıya yalnızca rolünün izin verdiği satırları gösterir.

Kaynak: `supabase/migrations/20261119010000_ekran_fonksiyonlari.sql` · Testler: `supabase/tests/ekran_fonksiyonlari_testi.sql`

## Nasıl çağrılır

```ts
const { data, error } = await supabase
  .schema('pdks')
  .rpc('soru_cevapla', { p_soru_id: 42, p_cevap: 'geldi_saat_dogru' })

if (error) toast.error(error.message)   // mesajlar Türkçe ve kullanıcıya gösterilebilir
```

- Parametre adları SQL'deki gibidir (`p_` önekli). Varsayılanı olan parametreler gönderilmeyebilir.
- Zamanlar ISO metin olarak gönderilir: `'2026-11-13T08:05:00+03:00'`. Tarihler `'2026-11-13'`.
- Fonksiyon, oturumdaki kullanıcıyı kendisi bulur; "kim yaptı" bilgisi ekrandan gönderilmez.
- Her fonksiyon önce rolü kontrol eder. Yetkisiz çağrı `Bu işlem için yetkiniz yok.` hatası verir.
- Amir yalnızca kendi departmanının çalışanları için işlem yapabilir.
- Kimse kendi kaydında işlem yapamaz (görevler ayrılığı); deneme `Görevler ayrılığı: ...` hatası verir.

## Amir

| Fonksiyon | Parametreler | Ne yapar |
|---|---|---|
| `soru_cevapla` | `p_soru_id`, `p_cevap`, `p_giris?`, `p_cikis?`, `p_aciklama?` | Kendisine atanmış (ya da kendisine eskale edilmiş) açık soruyu cevaplar |
| `itiraz_gir` | `p_gun_kaydi_id`, `p_metin` | Çalışanın itirazını sisteme girer; itiraz no döner |
| `fazla_mesai_talep_et` | `p_calisan_id`, `p_is_gunu`, `p_planli_dk`, `p_gerekce` | Fazla mesai talebi açar (vardiya, vardiya planından alınır); talep no döner |
| `vardiya_plani_gir` | `p_calisan_id`, `p_tarih`, `p_vardiya_id`, `p_aciklama?` | Vardiya planı girer ya da değiştirir. Geçmiş tarih İK onayına düşer; kilitli aya girilemez |

`p_cevap` değerleri:

| Cevap | Sonuç |
|---|---|
| `geldi_saat_dogru` | Saat gönderilmezse sistemin önerdiği saat, o da yoksa vardiya başı/sonu yazılır |
| `kart_unuttu` | `geldi_saat_dogru` ile aynı; ayrıca gerekçede kart unutma görünür |
| `geldi_saat_farkli` | `p_giris` ve/veya `p_cikis` zorunlu; girilen saat yazılır |
| `gelmedi` | Kayıt değişmez; soru İK kararına geçer (`ik_karari_bekliyor`) |
| `bilmiyorum` | `gelmedi` ile aynı: karar İK'nındır |

`vardiya_uyusmazligi` türündeki sorularda saatler her cevapta girilmelidir.

## Güvenlik

| Fonksiyon | Parametreler | Ne yapar |
|---|---|---|
| `gecici_kart_ver` | `p_gecici_kart_id`, `p_calisan_id`, `p_aciklama?` | Kartını unutan çalışana geçici kart zimmetler; zimmet no döner |
| `gecici_kart_iade_al` | `p_zimmet_id` | Geçici kartı geri alır |

İK de bu iki fonksiyonu çağırabilir.

## İK

| Fonksiyon | Parametreler | Ne yapar |
|---|---|---|
| `uyari_goruldu` | `p_uyari_id` | Uyarıyı "görüldü" yapar |
| `soru_ik_karari` | `p_soru_id`, `p_devamsiz`, `p_gerekce`, `p_giris?`, `p_cikis?` | Amirin "gelmedi / bilmiyorum" dediği soruyu kapatır. `p_devamsiz = true` → gün devamsız (çalışan aleyhine işaretlenir); `false` → saat zorunlu |
| `itiraz_incelemeye_al` | `p_itiraz_id` | İtirazı "incelemede" yapar |
| `itiraz_karar` | `p_itiraz_id`, `p_kabul`, `p_aciklama` | İtirazı kabul ya da reddeder |
| `kayit_duzelt` | `p_gun_kaydi_id`, `p_alan`, `p_yeni_deger`, `p_gerekce`, `p_itiraz_id?`, `p_izin_id?` | Gün kaydında tek alanı düzeltir (`giris_zamani`, `cikis_zamani`, `durum` …); düzeltme no döner |
| `vardiya_plani_onayla` | `p_plan_id`, `p_onay` | Geçmişe dönük vardiya planını onaylar/reddeder; planı giren kişi onaylayamaz |
| `izin_gir` | `p_calisan_id`, `p_tur`, `p_baslangic`, `p_bitis`, `p_aciklama?` | İzin kaydı girer |
| `fazla_mesai_karar` | `p_plan_id`, `p_onay`, `p_aciklama?` | Fazla mesai talebini onaylar/reddeder |
| `fazla_mesai_onayi_gir` | `p_calisan_id`, `p_yil`, `p_imza_tarihi`, `p_belge_no` | Çalışanın yıllık yazılı fazla mesai onayını kaydeder |
| `fazla_mesai_onayi_geri_al` | `p_onay_id`, `p_bildirim_tarihi` | Çalışan onayını geri çektiğinde kaydeder |
| `kart_iptal_et` | `p_kart_id`, `p_neden` | Kartı iptal eder |
| `kart_tanimla` | `p_calisan_id`, `p_kart_no` | Yeni kart tanımlar (aktif kartı olana tanımlanmaz) |
| `ariza_gir` | `p_okuyucu_id`, `p_baslangic`, `p_bitis?`, `p_aciklama?` | Okuyucu arızası girer |
| `ariza_karar` | `p_ariza_id`, `p_onay` | Sistemin şüphe olarak açtığı arızayı onaylar/reddeder |
| `ay_kilitle` | `p_yil`, `p_ay`, `p_zorla?` | Ayı kilitler ve puantajı dondurur. Açık soru/itiraz varsa kilitlemez |
| `dosya_yukle` | `p_kaynak`, `p_dosya_adi`, `p_veri_tarihi`, `p_satirlar` | CSV'den okunan satırları yükler; aktarım no döner |

### `dosya_yukle` satır biçimi

Ekran CSV'yi Papa Parse ile okur ve satırları JSON dizisi olarak gönderir:

```ts
await supabase.schema('pdks').rpc('dosya_yukle', {
  p_kaynak: 'pdks',                 // pdks | kapi | yemekhane | servis
  p_dosya_adi: 'pdks_20261113.csv',
  p_veri_tarihi: '2026-11-13',
  p_satirlar: [
    { okuyucu: 'PDKS-1', kart_no: 'K1001', zaman: '2026-11-13T07:52:00+03:00', yon: 'giris' },
  ],
})
```

- `pdks` kaynağı ham okutmaya, diğerleri kanıt kaydına yazılır.
- Okuyucu o kaynağa ait değilse dosyanın tamamı reddedilir.
- Aynı içerik ikinci kez yüklenirse `Bu dosya daha önce yüklenmiş.` hatası döner.

## Okuma (select)

Listeler doğrudan tablo ve görünümlerden okunur; RLS süzgeci otomatik uygulanır:

```ts
const { data } = await supabase.schema('pdks')
  .from('amir_sorusu')
  .select('id, soru_turu, aciklama, son_cevap_tarihi, gun_kaydi(is_gunu, calisan(ad, soyad))')
  .in('durum', ['acik', 'eskale'])
```

İzin listesi için amir `v_izin_amir` görünümünü kullanır (izin türü gizlidir).
