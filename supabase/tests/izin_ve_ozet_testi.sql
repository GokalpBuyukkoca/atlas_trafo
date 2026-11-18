-- =====================================================================
-- İzin iptali ve departman özeti testleri (20261122010000_izin_iptal_ve_departman_ozeti.sql)
-- Testin kendi sahte verisi (Ekim 2026); örnek veri yüklü olsun olmasın çalışır.
-- Her şey tek işlemde çalışır ve sonda geri alınır (ROLLBACK).
-- Çalıştırma: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/izin_ve_ozet_testi.sql
-- =====================================================================
\pset tuples_only on
\pset format unaligned
begin;
set local timezone = 'Europe/Istanbul';

create schema test;
create function test.dogrula(p_ad text, p_kosul boolean) returns void language plpgsql as $$
begin
    if p_kosul is not true then raise exception 'KALDI  %', p_ad; end if;
    raise notice 'GEÇTİ  %', p_ad;
end $$;
create function test.hata(p_ad text, p_kalip text, p_sql text) returns void language plpgsql as $$
begin
    begin
        execute p_sql;
    exception when others then
        if sqlerrm not like '%' || p_kalip || '%' then
            raise exception 'KALDI  %: beklenmeyen hata: %', p_ad, sqlerrm;
        end if;
        raise notice 'GEÇTİ  %  (%)', p_ad, sqlerrm;
        return;
    end;
    raise exception 'KALDI  %: hata bekleniyordu ama komut çalıştı', p_ad;
end $$;
create function test.oturum(p_eposta text) returns void language sql security definer as $$
    select set_config('request.jwt.claims',
        json_build_object('sub', (select auth_kullanici_id from pdks.kullanici where eposta = p_eposta),
                          'role', 'authenticated')::text, true);
$$;
create function test.c(p text) returns bigint language sql security definer as $$
    select id from pdks.calisan where sicil_no = p $$;
create function test.k(p text) returns bigint language sql security definer as $$
    select id from pdks.kullanici where eposta = p $$;
create function test.izin(p_sicil text) returns bigint language sql security definer as $$
    select id from pdks.izin where calisan_id = test.c(p_sicil) order by id desc limit 1 $$;
create function test.gk(p_sicil text, p_gun date) returns pdks.gun_kaydi language sql security definer as $$
    select * from pdks.gun_kaydi where calisan_id = test.c(p_sicil) and is_gunu = p_gun $$;
create function test.ts(p text) returns timestamptz language sql immutable as $$
    select (p::timestamp) at time zone 'Europe/Istanbul' $$;
grant usage on schema test to authenticated;
grant execute on all functions in schema test to authenticated;

-- Test verisi (yalnızca sahte) ---------------------------------------------
insert into pdks.departman (ad) values ('IZ Üretim'), ('IZ Kalite'), ('IZ İdari');
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
select s, 'Ad' || s, 'Örnek', (select id from pdks.departman where ad = d), '2025-01-01'
from (values ('IZ01', 'IZ Üretim'), ('IZ02', 'IZ Üretim'), ('IZA1', 'IZ Üretim'),
             ('IZ11', 'IZ Kalite'), ('IZI1', 'IZ İdari'), ('IZI2', 'IZ İdari')) v(s, d);
insert into pdks.kullanici (ad_soyad, eposta, rol, calisan_id, auth_kullanici_id) values
    ('IZ Amir', 'iz_amir@ornek.test', 'amir', test.c('IZA1'), '00000000-0000-0000-0000-0000000000c1'),
    ('IZ İK 1', 'iz_ik1@ornek.test',  'ik',   test.c('IZI1'), '00000000-0000-0000-0000-0000000000c2'),
    ('IZ İK 2', 'iz_ik2@ornek.test',  'ik',   test.c('IZI2'), '00000000-0000-0000-0000-0000000000c3');
update pdks.departman set amir_id = test.k('iz_amir@ornek.test') where ad = 'IZ Üretim';
insert into pdks.kart (kart_no, calisan_id) values ('IZ-11', test.c('IZ11'));
insert into pdks.okuyucu (kod, ad, sistem) values ('IZ-PDKS', 'IZ PDKS', 'pdks');

-- 12 Ekim: IZ01, IZ02 (Üretim) ve IZ11 (Kalite) gündüz vardiyasında
insert into pdks.vardiya_plani (calisan_id, tarih, vardiya_id, giren_id)
select test.c(s), '2026-10-12', (select id from pdks.vardiya_tanim where kod = 'GUNDUZ'), test.k('iz_ik1@ornek.test')
from unnest(array['IZ01', 'IZ02', 'IZ11']) s;
insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi)
values ('pdks', 'iz_pdks.csv', 'iz-pdks-20261012', '2026-10-12');
-- IZ11: 20 dk geç geldi
insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani, yon)
select (select id from pdks.aktarim where dosya_ozeti = 'iz-pdks-20261012'),
       (select id from pdks.okuyucu where kod = 'IZ-PDKS'), 'IZ-11', test.ts(z), y
from (values ('2026-10-12 08:20:00', 'giris'), ('2026-10-12 17:02:00', 'cikis')) v(z, y);

-- İzinler (İK 1 girer; İK 1'in kendi iznini İK 2 girer)
set local role authenticated;
select test.oturum('iz_ik1@ornek.test');
select pdks.izin_gir(test.c('IZ01'), 'yillik', '2026-10-12', '2026-10-13', 'Yanlış kişiye girildi');
select pdks.izin_gir(test.c('IZ02'), 'yillik', '2026-10-12', '2026-10-12', 'Doğru izin');
select test.oturum('iz_ik2@ornek.test');
select pdks.izin_gir(test.c('IZI1'), 'mazeret', '2026-10-20', '2026-10-20', 'İK 1''in izni');

-- 1) İzin iptali: yetki ve kurallar -------------------------------------------
select test.oturum('iz_amir@ornek.test');
select test.hata('amir izin iptal edemez', 'yetkiniz yok',
    $$select pdks.izin_iptal(test.izin('IZ01'), 'Yanlış kişiye girilmiş')$$);
select test.dogrula('amir görünümünde IZ01 izni görünüyor (iptal öncesi)',
    exists (select 1 from pdks.v_izin_amir where id = test.izin('IZ01')));

select test.oturum('iz_ik1@ornek.test');
select test.hata('nedensiz iptal edilemez', 'İptal nedeni', $$select pdks.izin_iptal(test.izin('IZ01'), ' ')$$);
select test.hata('İK kendi iznini iptal edemez', 'Görevler ayrılığı',
    $$select pdks.izin_iptal(test.izin('IZI1'), 'Kendi iznimi iptal ediyorum')$$);
select pdks.izin_iptal(test.izin('IZ01'), 'Yanlış kişiye girilmiş');
select test.hata('iptal edilen izin ikinci kez iptal edilemez', 'zaten iptal',
    $$select pdks.izin_iptal(test.izin('IZ01'), 'Tekrar deneme')$$);
reset role;

select test.dogrula('izin silinmedi, iptal izi tutuldu (kim, ne zaman, neden)',
    (select iptal_zamani is not null and iptal_eden_id = test.k('iz_ik1@ornek.test')
            and iptal_nedeni = 'Yanlış kişiye girilmiş'
     from pdks.izin where id = test.izin('IZ01')));

set local role authenticated;
select test.oturum('iz_amir@ornek.test');
select test.dogrula('amir görünümü iptal edilen izni göstermiyor; diğer izin duruyor',
    not exists (select 1 from pdks.v_izin_amir where id = test.izin('IZ01'))
    and exists (select 1 from pdks.v_izin_amir where id = test.izin('IZ02')));
reset role;

-- 2) Gece işi iptal edilen izni yok sayar ---------------------------------------
select pdks.gece_isi_calistir('2026-10-12');
select test.dogrula('iptal edilen izin: gün "izinli" değil, amire soru gitti',
    (select durum = 'soru_bekliyor' from test.gk('IZ01', '2026-10-12')));
select test.dogrula('geçerli izin: gün "izinli"',
    (select durum = 'izinli' from test.gk('IZ02', '2026-10-12')));

set local role authenticated;
select test.oturum('iz_ik1@ornek.test');
select test.hata('işlenmiş günü olan izin iptal edilemez', 'günü işlenmiş',
    $$select pdks.izin_iptal(test.izin('IZ02'), 'Sonradan vazgeçildi')$$);

-- 3) Departman özeti --------------------------------------------------------------
select test.dogrula('İK iki departmanın Ekim özetini görür',
    (select count(*) = 2 from pdks.v_departman_ozet
     where yil = 2026 and ay = 10 and departman in ('IZ Üretim', 'IZ Kalite')));
select test.dogrula('Üretim: 2 çalışan, 0 çalışılan gün, 1 açık soru, 1 bekleyen gün',
    (select calisan_sayisi = 2 and calisilan_gun = 0 and acik_soru = 1 and bekleyen_gun = 1
            and devamsiz_gun = 0 and acik_itiraz = 0
     from pdks.v_departman_ozet where yil = 2026 and ay = 10 and departman = 'IZ Üretim'));
select test.dogrula('Kalite: 1 çalışılan gün, 1 geç kalınan gün, 20 dk',
    (select calisilan_gun = 1 and gec_kalinan_gun = 1 and gec_kalma_dk = 20 and acik_soru = 0
     from pdks.v_departman_ozet where yil = 2026 and ay = 10 and departman = 'IZ Kalite'));
select test.dogrula('özet gün kayıtlarıyla tutarlı (Kalite çalışma dakikası)',
    (select (select calisma_dk from test.gk('IZ11', '2026-10-12')) = 520));

select test.oturum('iz_amir@ornek.test');
select test.dogrula('amir yalnızca kendi departmanını görür',
    (select count(*) = 1 and bool_and(departman = 'IZ Üretim')
     from pdks.v_departman_ozet where yil = 2026 and ay = 10));
reset role;

do $$ begin raise notice 'TÜM TESTLER GEÇTİ'; end $$;
rollback;
