# Ekran fonksiyonları (RPC)

Ekranlar veritabanına **yazmak** için yalnızca bu fonksiyonları çağırır. Tablolara doğrudan `insert` / `update` yetkisi yoktur; okuma ise `select` ile yapılır ve RLS her kullanıcıya yalnızca rolünün izin verdiği satırları gösterir.

Kaynak: `supabase/migrations/20261119010000_ekran_fonksiyonlari.sql` · Testler: `supabase/tests/ekran_fonksiyonlari_testi.sql`
Sonradan eklenenler: gece işi ve puantaj (`20261120…`, `20261121…`), izin iptali (`20261122…`), onaysız fazla mesai, saatlik izin ve puantaj kodları (`20261123010000_puantaj_kurallari.sql`, testi `puantaj_kurallari_testi.sql`).

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
| `izin_iptal` | `p_izin_id`, `p_neden` | Yanlış girilen izni iptal eder (silmez; kim/ne zaman/neden tutulur). İznin bir günü gece işinden "izinli/raporlu" olarak geçmişse reddeder: o günler `kayit_duzelt` ile düzeltilir. İK kendi iznini iptal edemez |
| `fazla_mesai_karar` | `p_plan_id`, `p_onay`, `p_aciklama?` | Fazla mesai talebini onaylar/reddeder |
| `fazla_mesai_inceleme_karar` | `p_inceleme_id`, `p_onay`, `p_aciklama?` | Onaysız fazla mesai havuzundaki kaydı onaylar ya da reddeder. Ret için gerekçe zorunlu (en az 5 karakter). Onay puantaja girer; kilitli aya aitse sonraki açık aya fark olur. Yıllık sınır aşılsa da onaylanır, İK'ya uyarı yazılır. İK kendi kaydına karar veremez |
| `saatlik_izin_gir` | `p_calisan_id`, `p_tarih`, `p_baslangic`, `p_bitis`, `p_tur`, `p_aciklama?` | Saat aralıklı izin girer (`p_tur`: `vizite` / `mazeret` / `diger`); izin no döner. Çakışan izin, kilitli ay ve iş günüyle uyuşmayan saat reddedilir. Hesaplanmış gün yeniden hesaplanır. İK kendi iznini giremez |
| `fazla_mesai_onayi_gir` | `p_calisan_id`, `p_yil`, `p_imza_tarihi`, `p_belge_no` | Çalışanın yıllık yazılı fazla mesai onayını kaydeder |
| `fazla_mesai_onayi_geri_al` | `p_onay_id`, `p_bildirim_tarihi` | Çalışan onayını geri çektiğinde kaydeder |
| `kart_iptal_et` | `p_kart_id`, `p_neden` | Kartı iptal eder |
| `kart_tanimla` | `p_calisan_id`, `p_kart_no` | Yeni kart tanımlar (aktif kartı olana tanımlanmaz) |
| `ariza_gir` | `p_okuyucu_id`, `p_baslangic`, `p_bitis?`, `p_aciklama?` | Okuyucu arızası girer |
| `ariza_karar` | `p_ariza_id`, `p_onay` | Sistemin şüphe olarak açtığı arızayı onaylar/reddeder |
| `ay_kilitle` | `p_yil`, `p_ay`, `p_zorla?` | Ayı kilitler ve puantajı yazar: her çalışan için `normal` satır (canlı puantajın aynısı) ve önceki kilitli aylara sonradan gelen düzeltmeler ya da havuz onayları için `fark` satırı (`kaynak_donem_id` ile); her satırın kod kırılımı `puantaj_kalemi`'ne yazılır. Açık soru/itiraz ya da İK kararı bekleyen onaysız fazla mesai varsa kilitlemez; `p_zorla = true` ile geçilir. Kilit geri açılamaz |
| `dosya_yukle` | `p_kaynak`, `p_dosya_adi`, `p_veri_tarihi`, `p_satirlar` | CSV'den okunan satırları yükler; aktarım no döner |
| `gece_isi_tetikle` | `p_baslangic`, `p_bitis?` | **Demo düğmesi.** Tarih aralığını gün gün gece işinden geçirir (en fazla 62 gün). Her gün için `gun`, `durum` (`basarili` / `hatali`), `ozet`, `hata_mesaji` satırı döner. Verisi yüklenmemiş gün işlenmez |

### `gece_isi_tetikle` (demo)

Gece işi normalde her gece 06:30'da kendiliğinden çalışır (pg_cron). Demoda İK ekranındaki düğme örnek ayı tek seferde işletir:

```ts
const { data, error } = await supabase.schema('pdks')
  .rpc('gece_isi_tetikle', { p_baslangic: '2026-11-01', p_bitis: '2026-11-30' })
// data: [{ gun: '2026-11-01', durum: 'basarili', ozet: { gun_kaydi: 31, soru: 0, ... }, hata_mesaji: null }, ...]
```

Tekrar çalıştırmak güvenlidir; var olan kayıtlar bozulmaz, yalnızca eksikler eklenir. Son çalışmanın durumu `v_gece_isi_durumu` görünümünden okunur.

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

İzin listesi için amir `v_izin_amir` görünümünü kullanır (izin türü gizlidir; iptal edilen izinler görünmez). Saatlik izinler için de `v_saatlik_izin_amir` (tür her zaman `saatlik_izin`).

Onaysız fazla mesai havuzu `fazla_mesai_inceleme` tablosundan okunur (İK ve yönetici hepsini, amir kendi departmanını görür):

```ts
await supabase.schema('pdks').from('fazla_mesai_inceleme')
  .select('id, is_gunu, tur, dakika, durum, calisan(sicil_no, ad, soyad)')
  .eq('durum', 'inceleme_bekliyor')
```

Gün gün puantaj kodları (yalnızca İK ve yönetici; izin türünü içerir):

```ts
const { data } = await supabase.schema('pdks').rpc('gun_kodlari', { p_yil: 2026, p_ay: 11 })
// data: [{ calisan_id: 12, tarih: '2026-11-02', kod: 'NÇ', gun: 1, dakika: 540 }, { ..., kod: 'FM50', gun: 0, dakika: 60 }, ...]
```

Kilitli ayın kod kırılımı `puantaj_kalemi` tablosundadır (`puantaj_satiri_id`, `kod`, `gun`, `dakika`). `puantaj_satiri` ve `v_puantaj_canli` ayrıca `fm50_dk`, `fm100_dk`, `gece_calisma_dk`, `saatlik_izin_dk` sütunlarını verir.

**İK `izin` tablosunu doğrudan okuyorsa iptal edilen izinleri süzmelidir:**

```ts
await supabase.schema('pdks').from('izin').select('*').is('iptal_zamani', null)
```

Yönetici paneli için `v_departman_ozet` görünümü ay ve departman başına özet verir: `calisan_sayisi`, `calisilan_gun`, `devamsiz_gun`, `gec_kalinan_gun`, `gec_kalma_dk`, `erken_cikis_dk`, `fazla_mesai_dk`, `bekleyen_gun`, `acik_soru`, `acik_itiraz`. İK ve yönetici tüm departmanları, amir yalnızca kendi departmanını görür.

```ts
await supabase.schema('pdks').from('v_departman_ozet').select('*').eq('yil', 2026).eq('ay', 11)
```
