-- =====================================================================
-- ayar_al() yetkisi
--
-- Sorun
--   20261118030000_giris_ve_yetki.sql pdks_uygulama rolünü sildi ve
--   pdks fonksiyonlarındaki çalıştırma yetkisini public/anon'dan aldı.
--   ayar_al() için çalıştırma yetkisi yalnızca silinen pdks_uygulama
--   rolündeydi. Bu yüzden v_fazla_mesai_yillik (security_invoker) Next.js
--   uygulamasından sorgulanınca
--       42501 permission denied for function ayar_al
--   hatası veriyordu.
--
-- Neden yalnızca "grant execute" yetmez?
--   ayar_al() çağıranın yetkisiyle çalışıyordu. pdks.ayar tablosunda RLS
--   açık ve yalnızca ik/yonetici okuyabiliyor. Sadece yetki verilseydi
--   amir hata almaz, ama ayar_al() NULL döner ve kalan_dk sessizce boş
--   gelirdi.
--
-- Çözüm
--   ayar_al() tablo sahibinin yetkisiyle (SECURITY DEFINER) çalışır ve
--   authenticated rolüne çalıştırma yetkisi verilir. Ayarlar yalnızca
--   tamsayı sınır değerleridir (270 saat, 11 saat, eşikler); hassas veri
--   değildir. pdks.ayar tablosunun kendisi yine yalnızca ik/yonetici'ye açık
--   kalır, ayar değiştirmek için hiçbir yetki verilmez.
--
-- ayar_al() kullanan diğer yerler
--   fm_plan_denetle(), fazla_mesai_plani_kontrol() : fazla mesai planı
--       yazılırken çalışır; ileride RPC ile yazma açılınca bu düzeltmeyle
--       aynı hatayı vermez.
--   gecici_kart_kontrol(), kart_paylasim_kontrol() : gece işi, tablo sahibi
--       olarak pg_cron ile çalışır; etkilenmez.
-- =====================================================================

create or replace function pdks.ayar_al(p_anahtar text)
returns integer
language sql
stable
security definer
set search_path = pdks
as $$
    select deger from pdks.ayar where anahtar = p_anahtar;
$$;

revoke execute on function pdks.ayar_al(text) from public, anon;
grant execute on function pdks.ayar_al(text) to authenticated;
