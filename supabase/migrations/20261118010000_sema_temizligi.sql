-- =====================================================================
-- Şema temizliği
--
-- 1. itiraz tablosunun açıklaması güncel iş akışını anlatır.
-- 2. ayar_gecmisi'nden, artık var olmayan iki ayarın geçmiş satırları silinir.
--    Tablo normalde değiştirilemez; silme yalnızca bu dosyada, korumalar
--    kısa süre kapatılarak yapılır ve hemen geri açılır.
-- =====================================================================

comment on table pdks.itiraz is
    'Çalışanın itirazı. Amir ya da İK girer; reddi yalnızca İK.';

alter table pdks.ayar_gecmisi disable trigger ayar_gecmisi_degistirilemez;

delete from pdks.ayar_gecmisi
where anahtar in ('kiosk_gun_sayisi', 'pin_hatali_deneme_siniri');

alter table pdks.ayar_gecmisi enable trigger ayar_gecmisi_degistirilemez;
