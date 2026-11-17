-- =====================================================================
-- Kiosk kaldırma testi (migration 20261117010000_kiosk_kaldir.sql).
-- Kiosktan hiçbir parça kalmadığını doğrular. Sonda ROLLBACK, iz bırakmaz.
-- Çalıştırma: psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/kiosk_kaldirma_testi.sql
-- =====================================================================
\pset tuples_only on
\pset format unaligned
begin;

create schema test;
create function test.dogrula(p_ad text, p_kosul boolean) returns void language plpgsql as $$
begin
    if p_kosul is not true then raise exception 'KALDI  %', p_ad; end if;
    raise notice 'GEÇTİ  %', p_ad;
end $$;
create function test.hata_bekle(p_ad text, p_sql text) returns void language plpgsql as $$
begin
    begin
        execute p_sql;
    exception when others then
        raise notice 'GEÇTİ  %  (%)', p_ad, sqlerrm;
        return;
    end;
    raise exception 'KALDI  %: hata bekleniyordu ama komut çalıştı', p_ad;
end $$;

select test.dogrula('kiosk fonksiyonları yok',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'pdks'
                  and p.proname in ('kiosk_giris', 'kiosk_pin_degistir', 'pin_sifirla')));
select test.dogrula('kiosk görünümü yok',
    to_regclass('pdks.v_kiosk_kayitlar') is null);
select test.dogrula('çalışan tablosunda PIN alanı yok',
    not exists (select 1 from information_schema.columns
                where table_schema = 'pdks' and table_name = 'calisan'
                  and column_name in ('pin_ozeti', 'pin_degismeli', 'hatali_pin_sayisi', 'kilitli_mi')));
select test.dogrula('kiosk ayarları yok',
    not exists (select 1 from pdks.ayar
                where anahtar in ('kiosk_gun_sayisi', 'pin_hatali_deneme_siniri')));
select test.dogrula('veritabanında kiosk/PIN adı geçen fonksiyon, görünüm ya da alan kalmadı',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'pdks' and (p.proname ~ '(kiosk|pin_)' or p.prosrc ~* 'kiosk|pin_ozeti'))
    and not exists (select 1 from information_schema.columns
                    where table_schema = 'pdks' and column_name ~ '(kiosk|pin_)')
    and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'pdks' and c.relname ~ 'kiosk'));

-- Örnek veri: uyarı ve itiraz kiosk olmadan çalışmalı
insert into pdks.kullanici (ad_soyad, eposta, rol) values ('İK Bir', 'ik@ornek.test', 'ik');
insert into pdks.departman (ad, amir_id)
values ('Montaj', (select id from pdks.kullanici where eposta = 'ik@ornek.test'));
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
values ('1001', 'Ahmet', 'Örnek', (select id from pdks.departman where ad = 'Montaj'), '2025-01-01');

select test.hata_bekle('pin_kilitlendi uyarı türü artık kabul edilmiyor',
    $q$insert into pdks.uyari (tur, calisan_id, mesaj) select 'pin_kilitlendi', id, 'deneme' from pdks.calisan where sicil_no = '1001'$q$);
select test.dogrula('diğer uyarı türleri yerinde (sik_kart_unutma)',
    (select pg_get_constraintdef(oid) like '%sik_kart_unutma%'
     from pg_constraint where conrelid = 'pdks.uyari'::regclass and conname = 'uyari_tur_check'));
insert into pdks.uyari (tur, calisan_id, mesaj)
select 'sik_kart_unutma', id, 'deneme' from pdks.calisan where sicil_no = '1001';
select test.dogrula('normal uyarı yazılabiliyor',
    exists (select 1 from pdks.uyari where tur = 'sik_kart_unutma'));
select test.dogrula('uygulama ve gece işi rolleri şifreleme şemasına erişemiyor',
    not has_schema_privilege('pdks_uygulama', 'extensions', 'usage')
    and not has_schema_privilege('pdks_gece_isi', 'extensions', 'usage'));

do $$ begin raise notice 'KİOSK KALDIRMA TESTLERİ GEÇTİ'; end $$;
rollback;
