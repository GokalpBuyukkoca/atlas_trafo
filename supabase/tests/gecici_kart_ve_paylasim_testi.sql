-- =====================================================================
-- Geçici kart (sorun 4) ve kart paylaşımı (sorun 6) testleri
-- Migration: 20261117020000_gecici_kart.sql, 20261117030000_kart_paylasimi.sql
-- Her şey tek işlemde çalışır ve sonda geri alınır (ROLLBACK), iz bırakmaz.
-- Çalıştırma: psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gecici_kart_ve_paylasim_testi.sql
-- =====================================================================
\pset tuples_only on
\pset format unaligned
begin;

create schema test;
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
create function test.dogrula(p_ad text, p_kosul boolean) returns void language plpgsql as $$
begin
    if p_kosul is not true then raise exception 'KALDI  %', p_ad; end if;
    raise notice 'GEÇTİ  %', p_ad;
end $$;
-- Kısa yollar: e-posta / sicil / kart no → id
create function test.k(p text) returns bigint language sql as $$ select id from pdks.kullanici where eposta = p $$;
create function test.c(p text) returns bigint language sql as $$ select id from pdks.calisan where sicil_no = p $$;
create function test.g(p text) returns bigint language sql as $$ select id from pdks.gecici_kart where kart_no = p $$;
create function test.uyari_sayisi(p_tur text) returns bigint language sql as $$ select count(*) from pdks.uyari where tur = p_tur $$;
grant usage on schema test to pdks_uygulama, pdks_gece_isi;
grant execute on all functions in schema test to pdks_uygulama, pdks_gece_isi;

set timezone = 'Europe/Istanbul';

-- Örnek veri (yalnızca sahte) -------------------------------------------
insert into pdks.kullanici (ad_soyad, eposta, rol) values
    ('İK Bir', 'ik@ornek.test', 'ik'),
    ('Amir Bir', 'amir@ornek.test', 'amir');
insert into pdks.kullanici (ad_soyad, eposta, rol) values ('Güvenlik Bir', 'guvenlik@ornek.test', 'guvenlik');
select test.dogrula('güvenlik rolü eklenebiliyor', test.k('guvenlik@ornek.test') is not null);
insert into pdks.departman (ad, amir_id) values ('Montaj', test.k('amir@ornek.test'));
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
select s, 'Ad' || s, 'Soyad' || s, (select id from pdks.departman where ad = 'Montaj'), '2025-01-01'
from unnest(array['1001','1002','1003','1004','1005','1006','1007','1008']) s;
insert into pdks.kart (kart_no, calisan_id)
select 'K' || s, test.c(s) from unnest(array['1001','1002','1003','1004','1005','1006','1007','1008']) s;
insert into pdks.gecici_kart (kart_no) values ('GK-01'), ('GK-02'), ('GK-03'), ('GK-04');
insert into pdks.okuyucu (kod, ad, sistem) values ('PDKS-A', 'A kapısı PDKS', 'pdks'),
                                                ('KAPI-1', 'Tesis kapısı', 'kapi');
insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi)
values ('pdks', 'pdks_kasim.csv', 'ozet-pdks', '2026-11-30'),
       ('kapi', 'kapi_kasim.csv', 'ozet-kapi', '2026-11-30');

-- =====================================================================
-- A) GEÇİCİ KART VE ZİMMET
-- =====================================================================
select test.hata_bekle('geçici kart numarası asıl kartla aynı olamaz',
    $$insert into pdks.gecici_kart (kart_no) values ('K1001')$$);
select test.hata_bekle('asıl kart numarası geçici kartla aynı olamaz',
    $$insert into pdks.kart (kart_no, calisan_id) values ('GK-01', test.c('1008'))$$);

set role pdks_uygulama;
select test.hata_bekle('amir geçici kart veremez',
    $$insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
      values (test.g('GK-01'), test.c('1001'), '2026-11-10 07:50+03', test.k('amir@ornek.test'))$$);

insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
values (test.g('GK-01'), test.c('1001'), '2026-11-10 07:50+03', test.k('guvenlik@ornek.test'));
select test.dogrula('güvenlik geçici kartı verdi', exists (select 1 from pdks.gecici_kart_zimmet));

select test.hata_bekle('iade edilmemiş kart başkasına verilemez',
    $$insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
      values (test.g('GK-01'), test.c('1002'), '2026-11-10 09:00+03', test.k('guvenlik@ornek.test'))$$);
select test.hata_bekle('bir çalışanda aynı anda iki geçici kart olamaz',
    $$insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
      values (test.g('GK-02'), test.c('1001'), '2026-11-10 09:00+03', test.k('guvenlik@ornek.test'))$$);
select test.hata_bekle('zimmetin çalışanı değiştirilemez',
    $$update pdks.gecici_kart_zimmet set calisan_id = test.c('1002')$$);
select test.hata_bekle('zimmet silinemez (yetki yok)',
    $$delete from pdks.gecici_kart_zimmet$$);
select test.hata_bekle('amir iade alamaz',
    $$update pdks.gecici_kart_zimmet set iade_zamani = '2026-11-10 17:10+03', iade_alan_id = test.k('amir@ornek.test')$$);

update pdks.gecici_kart_zimmet
set iade_zamani = '2026-11-10 17:10+03', iade_alan_id = test.k('guvenlik@ornek.test')
where gecici_kart_id = test.g('GK-01');
select test.dogrula('güvenlik iadeyi aldı',
    (select iade_zamani is not null from pdks.gecici_kart_zimmet where gecici_kart_id = test.g('GK-01')));
select test.hata_bekle('iade edilmiş zimmet değiştirilemez',
    $$update pdks.gecici_kart_zimmet set iade_zamani = '2026-11-10 18:00+03'$$);
select test.hata_bekle('geriye dönük çakışan zimmet girilemez',
    $$insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
      values (test.g('GK-01'), test.c('1002'), '2026-11-10 12:00+03', test.k('guvenlik@ornek.test'))$$);
reset role;

select test.hata_bekle('zimmet postgres için bile silinemez',
    $$delete from pdks.gecici_kart_zimmet$$);
select test.hata_bekle('zimmet tablosu boşaltılamaz (TRUNCATE)',
    $$truncate pdks.gecici_kart_zimmet$$);

update pdks.gecici_kart set durum = 'kayip' where kart_no = 'GK-04';
set role pdks_uygulama;
select test.hata_bekle('kayıp geçici kart verilemez',
    $$insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
      values (test.g('GK-04'), test.c('1003'), '2026-11-11 07:00+03', test.k('guvenlik@ornek.test'))$$);
reset role;

select test.dogrula('okutma sahibi: zimmet içindeki geçici kart → çalışan',
    pdks.okutma_sahibi('GK-01', '2026-11-10 10:00+03') = test.c('1001'));
select test.dogrula('okutma sahibi: zimmet dışındaki geçici kart → kimse',
    pdks.okutma_sahibi('GK-01', '2026-11-10 18:30+03') is null);
select test.dogrula('okutma sahibi: asıl kart → sahibi',
    pdks.okutma_sahibi('K1002', '2026-11-10 10:00+03') = test.c('1002'));
select test.dogrula('okutma sahibi: bilinmeyen kart → kimse',
    pdks.okutma_sahibi('X-999', '2026-11-10 10:00+03') is null);

-- Gece işi kontrolleri için okutmalar (10 Kasım)
insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani, yon)
select (select id from pdks.aktarim where kaynak = 'pdks'), (select id from pdks.okuyucu where kod = 'PDKS-A'), k, t::timestamptz, y
from (values ('GK-01', '2026-11-10 08:00+03', 'giris'),   -- zimmet içinde: normal
             ('GK-01', '2026-11-10 18:30+03', 'giris'))   -- zimmet dışında: uyarı
     v(k, t, y);
insert into pdks.kanit_kaydi (aktarim_id, okuyucu_id, kaynak, kart_no, okutma_zamani, yon)
values ((select id from pdks.aktarim where kaynak = 'kapi'), (select id from pdks.okuyucu where kod = 'KAPI-1'),
        'kapi', 'K1001', '2026-11-10 12:00+03', 'giris');   -- A'nın asıl kartı, geçici kart zimmetliyken

-- C'ye 11 Kasım'da verilip iade edilmeyen kart; D'ye ayda 3 kez kart
set role pdks_uygulama;
insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
values (test.g('GK-03'), test.c('1003'), '2026-11-11 07:00+03', test.k('guvenlik@ornek.test'));
insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id, iade_zamani, iade_alan_id)
select test.g('GK-02'), test.c('1004'), (d || ' 07:00+03')::timestamptz, test.k('guvenlik@ornek.test'), null, null
from unnest(array['2026-11-02']) d;
update pdks.gecici_kart_zimmet set iade_zamani = '2026-11-02 17:00+03', iade_alan_id = test.k('guvenlik@ornek.test')
where calisan_id = test.c('1004') and iade_zamani is null;
insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
values (test.g('GK-02'), test.c('1004'), '2026-11-03 07:00+03', test.k('guvenlik@ornek.test'));
update pdks.gecici_kart_zimmet set iade_zamani = '2026-11-03 17:00+03', iade_alan_id = test.k('guvenlik@ornek.test')
where calisan_id = test.c('1004') and iade_zamani is null;
insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
values (test.g('GK-02'), test.c('1004'), '2026-11-04 07:00+03', test.k('guvenlik@ornek.test'));
update pdks.gecici_kart_zimmet set iade_zamani = '2026-11-04 17:00+03', iade_alan_id = test.k('guvenlik@ornek.test')
where calisan_id = test.c('1004') and iade_zamani is null;
reset role;

set role pdks_gece_isi;
select pdks.gecici_kart_kontrol('2026-11-10');
select test.dogrula('geçici kart zimmetliyken asıl kart okutuldu → İK''ya uyarı',
    test.uyari_sayisi('gecici_kart_cakisma') = 1);
select test.dogrula('geçici kart zimmet dışında okutuldu → İK''ya uyarı',
    test.uyari_sayisi('gecici_kart_zimmetsiz') = 1);
select test.dogrula('aynı gün tekrar işlenince uyarı çoğalmıyor',
    pdks.gecici_kart_kontrol('2026-11-10') = 0
    and test.uyari_sayisi('gecici_kart_cakisma') = 1 and test.uyari_sayisi('gecici_kart_zimmetsiz') = 1);
select pdks.gecici_kart_kontrol('2026-11-12');
select test.dogrula('iade edilmeyen geçici kart → İK''ya uyarı',
    exists (select 1 from pdks.uyari where tur = 'gecici_kart_iade_edilmedi' and calisan_id = test.c('1003')));
select pdks.gecici_kart_kontrol('2026-11-04');
select test.dogrula('ayda 3 geçici kart alan çalışan → bilgi uyarısı',
    exists (select 1 from pdks.uyari where tur = 'sik_kart_unutma' and calisan_id = test.c('1004')));
select test.dogrula('gece işi zimmet yazamaz (yalnızca okur)',
    not has_table_privilege('pdks_gece_isi', 'pdks.gecici_kart_zimmet', 'insert'));
reset role;

-- =====================================================================
-- B) KART PAYLAŞIMI ŞÜPHESİ
-- =====================================================================
-- 1005 ve 1006: 5 farklı günde 3 saniye arayla arka arkaya → şüphe
-- 1007 ve 1008: 4 farklı günde arka arkaya → eşik altı, şüphe yok
-- 1001 ve 1002: 5 günde ama 20 saniye arayla → ardışık sayılmaz
-- 1003 ve 1004: tek seferlik ardışık okutma → şüphe yok
insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani, yon)
select (select id from pdks.aktarim where kaynak = 'pdks'), (select id from pdks.okuyucu where kod = 'PDKS-A'),
       k, (g || ' ' || s)::timestamptz, 'giris'
from (
    select g::date::text as g, k, s
    from generate_series('2026-11-16'::date, '2026-11-20'::date, '1 day') g,
         (values ('K1005', '07:40:00+03'), ('K1006', '07:40:03+03'),
                 ('K1001', '07:45:00+03'), ('K1002', '07:45:20+03')) v(k, s)
    union all
    select g::date::text, k, s
    from generate_series('2026-11-16'::date, '2026-11-19'::date, '1 day') g,
         (values ('K1007', '07:50:00+03'), ('K1008', '07:50:02+03')) v(k, s)
    union all
    select '2026-11-16', k, s from (values ('K1003', '07:55:00+03'), ('K1004', '07:55:01+03')) v(k, s)
) x;

set role pdks_gece_isi;
select test.dogrula('kart paylaşımı şüphesi: tek çift için tek uyarı',
    pdks.kart_paylasim_kontrol('2026-11-30') = 1);
select test.dogrula('şüpheli çift 1005–1006',
    exists (select 1 from pdks.uyari where tur = 'kart_paylasim_suphesi'
            and calisan_id = test.c('1005') and mesaj like '%1006%'));
select test.dogrula('eşik altı (4 gün) çift uyarı almadı',
    not exists (select 1 from pdks.uyari where tur = 'kart_paylasim_suphesi' and mesaj like '%1007%'));
select test.dogrula('20 saniye arayla okutanlar ardışık sayılmadı',
    not exists (select 1 from pdks.uyari where tur = 'kart_paylasim_suphesi' and calisan_id = test.c('1001')));
select test.dogrula('tek seferlik ardışık okutma uyarı almadı',
    not exists (select 1 from pdks.uyari where tur = 'kart_paylasim_suphesi' and mesaj like '%1003%'));
select test.dogrula('tekrar çalıştırınca uyarı çoğalmıyor',
    pdks.kart_paylasim_kontrol('2026-11-30') = 0 and test.uyari_sayisi('kart_paylasim_suphesi') = 1);
select test.dogrula('kart paylaşımı günlük kaydı değiştirmedi (ceza yok)',
    not exists (select 1 from pdks.gun_kaydi) and not exists (select 1 from pdks.duzeltme));
reset role;

update pdks.ayar set deger = 4 where anahtar = 'kart_paylasim_gun';
set role pdks_gece_isi;
select pdks.kart_paylasim_kontrol('2026-11-30');
select test.dogrula('eşik ayardan değişince (4 gün) 1007–1008 da uyarı aldı',
    exists (select 1 from pdks.uyari where tur = 'kart_paylasim_suphesi' and calisan_id = test.c('1007')));
reset role;

do $$ begin raise notice 'GEÇİCİ KART VE KART PAYLAŞIMI TESTLERİ GEÇTİ'; end $$;
rollback;
