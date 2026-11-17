-- =====================================================================
-- Kiosk kaldırıldı (ekip kararı, Kasım 2026)
--
-- Sorun 17'nin yeni çözümü: çalışan isterse İK, sistemden kayıt dökümünü
-- PDF olarak verir; itirazı (pdks.itiraz) amir ya da İK sisteme girer.
-- Kiosk için 0100–0400'de eklenen her şey burada kaldırılır.
-- Mevcut migration dosyaları değiştirilmez; bu dosya onların üstüne gelir.
-- 0500 (fazla mesai) kurulu olsa da olmasa da çalışır.
-- =====================================================================

-- 1) Kiosk görünümü ve PIN fonksiyonları
--    (Fonksiyonlar silinince onlara verilmiş yetkiler de kendiliğinden kalkar.)
drop view if exists pdks.v_kiosk_kayitlar;
drop function if exists pdks.kiosk_pin_degistir(text, text, text);
drop function if exists pdks.kiosk_giris(text, text);
drop function if exists pdks.pin_sifirla(bigint, text, bigint);

-- 2) Çalışan tablosundaki PIN alanları
alter table pdks.calisan
    drop column if exists pin_ozeti,
    drop column if exists pin_degismeli,
    drop column if exists hatali_pin_sayisi,
    drop column if exists kilitli_mi;

-- 3) 'pin_kilitlendi' uyarı türü
--    Kısıtın güncel hâli okunur, yalnızca bu tür çıkarılıp yeniden eklenir;
--    böylece başka migration'ların eklediği türler korunur.
do $$
declare
    v_tanim text;
begin
    if exists (select 1 from pdks.uyari where tur = 'pin_kilitlendi') then
        raise exception 'pin_kilitlendi türünde uyarı kaydı var; kiosk kaldırılmadan önce İK incelemeli.';
    end if;
    select pg_get_constraintdef(oid) into v_tanim
    from pg_constraint
    where conrelid = 'pdks.uyari'::regclass and conname = 'uyari_tur_check';
    v_tanim := replace(v_tanim, '''pin_kilitlendi''::text, ', '');
    if v_tanim like '%pin_kilitlendi%' then
        raise exception 'uyari_tur_check kısıtı beklenen biçimde değil: %', v_tanim;
    end if;
    alter table pdks.uyari drop constraint uyari_tur_check;
    execute 'alter table pdks.uyari add constraint uyari_tur_check ' || v_tanim;
end;
$$;

-- 4) Kiosk ayarları
--    Ayarlar normalde silinemez (ayar_iz trigger'ı). Bu tek seferlik temizlik
--    için trigger aynı işlemde kısa süre kapatılıp açılır.
--    ayar_gecmisi'ndeki eski kayıtlar silinemez iz olduğu için yerinde kalır.
alter table pdks.ayar disable trigger ayar_iz;
delete from pdks.ayar where anahtar in ('kiosk_gun_sayisi', 'pin_hatali_deneme_siniri');
alter table pdks.ayar enable trigger ayar_iz;

-- 5) extensions şemasını (pgcrypto) yalnızca kiosk PIN'i kullanıyordu.
--    Uygulama ve gece işi rollerinin oraya erişimi kaldırılır. pgcrypto eklentisi
--    yerinde kalır; amir/İK girişi yazılınca gereken yetki ayrıca verilir.
revoke execute on function extensions.crypt(text, text), extensions.gen_salt(text)
    from pdks_uygulama;
revoke usage on schema extensions from pdks_uygulama, pdks_gece_isi;

-- 6) İtiraz tablosunun açıklaması
comment on table pdks.itiraz is
    'Çalışanın itirazı. Kiosk yok: itirazı amir ya da İK girer. Reddi yalnızca İK.';
