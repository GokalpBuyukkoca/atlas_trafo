-- =====================================================================
-- Giriş ve yetki testleri (Supabase Auth + RLS).
-- Uygulamanın "authenticated" rolüyle, farklı kullanıcılar adına neyi
-- görebildiği denenir. Her şey tek işlemde çalışır ve sonda geri alınır.
-- Çalıştırma: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/giris_ve_yetki_testi.sql
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
-- Oturumu verilen Auth kullanıcısı olarak açar (Supabase'in JWT ayarı)
create function test.oturum(p_uuid text) returns void language sql as $$
    select set_config('request.jwt.claims', json_build_object('sub', p_uuid, 'role', 'authenticated')::text, true);
$$;
create function test.c(p text) returns bigint language sql security definer as $$
    select id from pdks.calisan where sicil_no = p $$;
grant usage on schema test to authenticated;
grant execute on all functions in schema test to authenticated;

set timezone = 'Europe/Istanbul';

-- Örnek veri (yalnızca sahte) ----------------------------------------------
insert into pdks.departman (ad) values ('RLS Montaj'), ('RLS Bobinaj'), ('RLS İdari');
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
select s, 'Ad' || s, 'Örnek', (select id from pdks.departman where ad = d), '2025-01-01'
from (values ('R01', 'RLS Montaj'), ('R02', 'RLS Montaj'),        -- Montaj işçileri
             ('R03', 'RLS Bobinaj'),                               -- Bobinaj işçisi
             ('R11', 'RLS İdari'), ('R12', 'RLS İdari'),           -- İK, yönetici
             ('R21', 'RLS Montaj'), ('R22', 'RLS Bobinaj'),        -- amirler
             ('R31', 'RLS İdari'), ('R41', 'RLS İdari'),           -- güvenlik, pasif kullanıcı
             ('R51', 'RLS İdari'))                                 -- bağsız kullanıcının kaydı
     v(s, d);

insert into pdks.kullanici (ad_soyad, eposta, rol, calisan_id, auth_kullanici_id, aktif) values
    ('İK',        'r_ik@ornek.test',       'ik',       test.c('R11'), '00000000-0000-0000-0000-000000000011', true),
    ('Yönetici',  'r_yon@ornek.test',      'yonetici', test.c('R12'), '00000000-0000-0000-0000-000000000012', true),
    ('Amir M',    'r_amir_m@ornek.test',   'amir',     test.c('R21'), '00000000-0000-0000-0000-000000000021', true),
    ('Amir B',    'r_amir_b@ornek.test',   'amir',     test.c('R22'), '00000000-0000-0000-0000-000000000022', true),
    ('Güvenlik',  'r_guv@ornek.test',      'guvenlik', test.c('R31'), '00000000-0000-0000-0000-000000000031', true),
    ('Pasif',     'r_pasif@ornek.test',    'ik',       test.c('R41'), '00000000-0000-0000-0000-000000000041', false),
    ('Bağsız',    'r_bagsiz@ornek.test',   'ik',       null,          '00000000-0000-0000-0000-000000000051', true);
update pdks.departman set amir_id = (select id from pdks.kullanici where eposta = 'r_amir_m@ornek.test') where ad = 'RLS Montaj';
update pdks.departman set amir_id = (select id from pdks.kullanici where eposta = 'r_amir_b@ornek.test') where ad = 'RLS Bobinaj';

insert into pdks.gun_kaydi (calisan_id, is_gunu, vardiya_id, durum)
select test.c(s), '2026-11-13', 1, 'eksik' from unnest(array['R01', 'R02', 'R03']) s;
insert into pdks.izin (calisan_id, tur, baslangic, bitis, giren_id)
select test.c(s), t, '2026-11-20', '2026-11-21', (select id from pdks.kullanici where eposta = 'r_ik@ornek.test')
from (values ('R01', 'rapor'), ('R03', 'yillik')) v(s, t);
insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
select g.id, 'giris_yok', 'Örnek soru', d.amir_id, '2026-11-17'
from pdks.gun_kaydi g join pdks.calisan c on c.id = g.calisan_id join pdks.departman d on d.id = c.departman_id
where c.sicil_no in ('R01', 'R03');
insert into pdks.uyari (tur, calisan_id, mesaj) values ('kart_paylasim_suphesi', test.c('R01'), 'Örnek uyarı');
insert into pdks.gecici_kart (kart_no) values ('R-GK1');
-- Onaylı fazla mesai: R01 (Montaj) ve R03 (Bobinaj), birer saat
insert into pdks.vardiya_plani (calisan_id, tarih, vardiya_id)
select test.c(s), '2026-12-01', (select id from pdks.vardiya_tanim where kod = 'GUNDUZ')
from unnest(array['R01', 'R03']) s;
insert into pdks.fazla_mesai_onayi (calisan_id, yil, imza_tarihi, belge_no, giren_id)
select test.c(s), 2026, '2026-01-02', 'RLS-FMO-' || s, (select id from pdks.kullanici where eposta = 'r_ik@ornek.test')
from unnest(array['R01', 'R03']) s;
insert into pdks.fazla_mesai_plani (calisan_id, is_gunu, planli_dk, gerekce, talep_eden_id)
select test.c(s), '2026-12-01', 60, 'Örnek sipariş', d.amir_id
from unnest(array['R01', 'R03']) s
join pdks.calisan c on c.sicil_no = s join pdks.departman d on d.id = c.departman_id;
update pdks.fazla_mesai_plani set durum = 'onaylandi',
       karar_veren_id = (select id from pdks.kullanici where eposta = 'r_ik@ornek.test')
where calisan_id in (test.c('R01'), test.c('R03'));

-- Sayımlar (sahibin gözünden)
create temp table toplam as
select (select count(*) from pdks.calisan) as calisan, (select count(*) from pdks.gun_kaydi) as gun,
       (select count(*) from pdks.gecici_kart) as gecici_kart;
grant select on toplam to authenticated;

-- 1) Yapı ---------------------------------------------------------------------
select test.dogrula('pdks şemasındaki her tabloda RLS açık',
    not exists (select 1 from pg_tables where schemaname = 'pdks' and not rowsecurity));
select test.dogrula('anon pdks şemasına erişemez', not has_schema_privilege('anon', 'pdks', 'usage'));
select test.dogrula('authenticated hiçbir pdks tablosuna doğrudan yazamaz',
    not exists (select 1 from pg_tables t where schemaname = 'pdks'
                and (has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'insert')
                  or has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'update')
                  or has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'delete'))));
select test.dogrula('eski doğrudan bağlantı rolleri yok',
    not exists (select 1 from pg_roles where rolname in ('pdks_uygulama', 'pdks_gece_isi')));
select test.dogrula('anon ayar_al() çalıştıramaz, authenticated çalıştırabilir',
    not has_function_privilege('anon', 'pdks.ayar_al(text)', 'execute')
    and has_function_privilege('authenticated', 'pdks.ayar_al(text)', 'execute'));
select test.dogrula('authenticated, okuyabildiği her görünümün fonksiyonlarını çalıştırabilir',
    not exists (
        select 1
        from pg_views v
        join pg_depend d on d.classid = 'pg_rewrite'::regclass
        join pg_rewrite r on r.oid = d.objid and r.ev_class = format('%I.%I', v.schemaname, v.viewname)::regclass
        join pg_proc p on d.refclassid = 'pg_proc'::regclass and p.oid = d.refobjid
        where v.schemaname = 'pdks'
          and has_table_privilege('authenticated', format('%I.%I', v.schemaname, v.viewname), 'select')
          and p.pronamespace = 'pdks'::regnamespace
          and not has_function_privilege('authenticated', p.oid, 'execute')));

set role authenticated;

-- 2) Oturumu olmayan, bağsız ve pasif kullanıcı hiçbir şey görmez ------------
select test.oturum('00000000-0000-0000-0000-000000000099');
select test.dogrula('tanımsız kullanıcı çalışan göremez', (select count(*) from pdks.calisan) = 0);
select test.oturum('00000000-0000-0000-0000-000000000051');
select test.dogrula('çalışana bağlı olmayan kullanıcı hiçbir şey göremez',
    (select count(*) from pdks.calisan) = 0 and (select count(*) from pdks.kullanici) = 0);
select test.oturum('00000000-0000-0000-0000-000000000041');
select test.dogrula('pasif kullanıcı hiçbir şey göremez', (select count(*) from pdks.calisan) = 0);

-- 3) İK ve yönetici her şeyi görür ---------------------------------------------
select test.oturum('00000000-0000-0000-0000-000000000011');
select test.dogrula('İK tüm çalışanları görür', (select count(*) from pdks.calisan) = (select calisan from toplam));
select test.dogrula('İK izin türünü görür', exists (select 1 from pdks.izin where tur = 'rapor'));
select test.dogrula('İK uyarıları görür', (select count(*) from pdks.uyari) >= 1);
select test.oturum('00000000-0000-0000-0000-000000000012');
select test.dogrula('yönetici tüm gün kayıtlarını görür', (select count(*) from pdks.gun_kaydi) = (select gun from toplam));
select test.dogrula('yönetici yıllık fazla mesai görünümünü sınırla birlikte görür',
    (select count(*) = 2 and bool_and(kalan_dk = pdks.ayar_al('fm_yillik_sinir_dk') - 60)
     from pdks.v_fazla_mesai_yillik
     -- yalnızca testin kendi çalışanları (örnek veri yüklüyken başka satırlar da olur)
     where calisan_id in (test.c('R01'), test.c('R03'))));
select test.hata_bekle('yönetici hiçbir şey yazamaz',
    $$update pdks.calisan set ad = 'X' where sicil_no = 'R01'$$);

-- 4) Amir yalnızca kendi departmanını görür --------------------------------
select test.oturum('00000000-0000-0000-0000-000000000021');
select test.dogrula('amir yalnızca kendi departmanının çalışanlarını görür',
    (select count(*) from pdks.calisan) = 3
    and not exists (select 1 from pdks.calisan where sicil_no = 'R03'));
select test.dogrula('amir yalnızca kendi ekibinin gün kayıtlarını görür',
    (select count(*) from pdks.gun_kaydi) = 2);
select test.dogrula('amir yalnızca kendisine gelen soruları görür',
    (select count(*) from pdks.amir_sorusu) = 1);
select test.dogrula('amir izin tablosunu doğrudan göremez', (select count(*) from pdks.izin) = 0);
select test.dogrula('amir ekibinin iznini yalnızca "izinli" olarak görür',
    (select count(*) from pdks.v_izin_amir) = 1
    and (select tur from pdks.v_izin_amir) = 'izinli');
select test.dogrula('amir uyarıları ve ham kayıtları göremez',
    (select count(*) from pdks.uyari) = 0 and (select count(*) from pdks.ham_okutma) = 0);
select test.dogrula('amir yalnızca kendi kullanıcı satırını görür', (select count(*) from pdks.kullanici) = 1);
select test.dogrula('amir canlı puantajda yalnızca ekibini görür',
    (select count(distinct calisan_id) from pdks.v_puantaj_canli) = 2);
select test.dogrula('amir geçici kartları göremez', (select count(*) from pdks.gecici_kart) = 0);
select test.dogrula('amir ayar tablosunu doğrudan göremez', (select count(*) from pdks.ayar) = 0);
select test.dogrula('amir yıllık fazla mesaide yalnızca ekibini, sınırı boş gelmeden görür',
    (select count(*) = 1 and bool_and(calisan_id = test.c('R01')) and bool_and(kalan_dk is not null)
     from pdks.v_fazla_mesai_yillik));

-- 5) Güvenlik: çalışan listesi ve geçici kartlar ----------------------------
select test.oturum('00000000-0000-0000-0000-000000000031');
select test.dogrula('güvenlik çalışan listesini görür', (select count(*) from pdks.calisan) = (select calisan from toplam));
select test.dogrula('güvenlik geçici kartları görür', (select count(*) from pdks.gecici_kart) = (select gecici_kart from toplam));
select test.dogrula('güvenlik gün kayıtlarını, düzeltmeleri ve izinleri göremez',
    (select count(*) from pdks.gun_kaydi) = 0 and (select count(*) from pdks.duzeltme) = 0
    and (select count(*) from pdks.izin) = 0 and (select count(*) from pdks.v_izin_amir) = 0);

reset role;
do $$ begin raise notice 'GİRİŞ VE YETKİ TESTLERİ GEÇTİ'; end $$;
rollback;
