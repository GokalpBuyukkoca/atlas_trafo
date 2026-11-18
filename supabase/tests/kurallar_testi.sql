-- =====================================================================
-- Kural testleri. Her şey tek işlemde çalışır ve sonda geri alınır
-- (ROLLBACK), veritabanında iz bırakmaz.
-- Çalıştırma: psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/kurallar_testi.sql
-- Hepsi geçerse sonda "TÜM TESTLER GEÇTİ" yazar.
-- =====================================================================
\pset tuples_only on
\pset format unaligned
begin;

create schema test;
-- Verilen SQL'in hata vermesini bekler; hata vermezse test düşer
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

set timezone = 'Europe/Istanbul';

-- Test verisine kimlik numarasıyla değil adıyla ulaşılır; veritabanında başka veri olsa da çalışır
create function test.kul(p text) returns bigint language sql as $$ select id from pdks.kullanici where eposta = p $$;
create function test.cal() returns bigint language sql as $$ select id from pdks.calisan where sicil_no = 'KT1001' $$;
create function test.gk() returns bigint language sql as $$
    select id from pdks.gun_kaydi where calisan_id = test.cal() and is_gunu = '2026-11-13' $$;
create function test.oku(p text) returns smallint language sql as $$ select id from pdks.okuyucu where kod = p $$;
create function test.akt(p text) returns bigint language sql as $$ select id from pdks.aktarim where dosya_ozeti = p $$;
create function test.kanit() returns bigint language sql as $$
    select id from pdks.kanit_kaydi where kart_no = 'KT-K1001' $$;

-- Örnek veri ------------------------------------------------------------
insert into pdks.kullanici (ad_soyad, eposta, rol) values
    ('Amir Bir', 'amir@ornek.test', 'amir'),
    ('İK Bir',   'ik@ornek.test',   'ik');
insert into pdks.departman (ad, amir_id) values ('KT Montaj', test.kul('amir@ornek.test'));
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
values ('KT1001', 'Ahmet', 'Örnek', (select id from pdks.departman where ad = 'KT Montaj'), '2025-01-01');
insert into pdks.kart (kart_no, calisan_id) values ('KT-K1001', test.cal());
insert into pdks.okuyucu (kod, ad, sistem) values ('KT-PDKS', 'A kapısı PDKS', 'pdks'),
                                                ('KT-KAPI', 'Tesis kapısı', 'kapi');
insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi)
values ('pdks', 'kt_pdks_20261113.csv', 'kt-abc', '2026-11-13'),
       ('kapi', 'kt_kapi_20261113.csv', 'kt-def', '2026-11-13');
insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani, yon)
values (test.akt('kt-abc'), test.oku('KT-PDKS'), 'KT-K1001', '2026-11-13 17:02+03', 'cikis');
insert into pdks.kanit_kaydi (aktarim_id, okuyucu_id, kaynak, kart_no, okutma_zamani, yon)
values (test.akt('kt-def'), test.oku('KT-KAPI'), 'kapi', 'KT-K1001', '2026-11-13 07:50+03', 'giris');

-- Günlük kaydı oluştur (sorun 1: giriş yok)
insert into pdks.gun_kaydi (calisan_id, is_gunu, vardiya_id, cikis_zamani, cikis_kaynagi, durum)
values (test.cal(), '2026-11-13', 1, '2026-11-13 17:02+03', 'pdks', 'eksik');

-- 1) Ham kayıt değiştirilemez / silinemez ------------------------------
grant usage on schema test to authenticated;
grant execute on all functions in schema test to authenticated;
set role authenticated;
select test.hata_bekle('uygulama (authenticated) ham_okutma UPDATE yetkisi yok', $$update pdks.ham_okutma set kart_no = 'X'$$);
select test.hata_bekle('uygulama (authenticated) ham_okutma DELETE yetkisi yok', $$delete from pdks.ham_okutma$$);
reset role;
select test.hata_bekle('ham_okutma UPDATE tablo sahibi için bile trigger ile engelli',
                       $$update pdks.ham_okutma set kart_no = 'X'$$);
select test.hata_bekle('aynı dosya iki kez yüklenemez (sorun 16)',
    $$insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi)
      values ('pdks', 'tekrar.csv', 'kt-abc', '2026-11-13')$$);
select test.hata_bekle('aynı okutma iki kez eklenemez',
    $$insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani)
      values (test.akt('kt-abc'), test.oku('KT-PDKS'), 'KT-K1001', '2026-11-13 17:02+03')$$);

-- 2) İzsiz düzeltme imkânsız -------------------------------------------
select test.hata_bekle('giriş saati doğrudan UPDATE edilemez',
    $$update pdks.gun_kaydi set giris_zamani = '2026-11-13 08:00+03' where id = test.gk()$$);
select test.hata_bekle('gece işi kanıtsız düzeltme yapamaz',
    $$select pdks.duzeltme_uygula(test.gk(), 'giris_zamani', '2026-11-13 08:00+03', 'kanıtsız deneme', 'gece_isi')$$);

-- Kanıtlı düzeltme (kapı 07:50, vardiya 08:00'den önce)
select pdks.duzeltme_uygula(test.gk(), 'giris_zamani', '2026-11-13 08:00+03',
                            'Kapı kaydı 07:50, vardiya başı yazıldı', 'gece_isi', p_kanit_kaydi_id => test.kanit());
select test.dogrula('düzeltme kaydı tutuldu (eski boş, yeni 08:00)',
    (select eski_deger is null and yeni_deger::timestamptz = '2026-11-13 08:00+03' and kaynak = 'gece_isi'
     from pdks.duzeltme where gun_kaydi_id = test.gk()));
select test.dogrula('günlük kayıt güncellendi, kaynak=kanit',
    (select giris_zamani = '2026-11-13 08:00+03' and giris_kaynagi = 'kanit' from pdks.gun_kaydi where id = test.gk()));
select test.hata_bekle('düzeltme izi UPDATE edilemez', $$update pdks.duzeltme set gerekce = 'değişti'$$);
select test.hata_bekle('düzeltme izi DELETE edilemez', $$delete from pdks.duzeltme$$);
select test.hata_bekle('düzeltme izi tablo sahibi için bile silinemez', $$delete from pdks.duzeltme$$);
select test.hata_bekle('düzeltme izi TRUNCATE edilemez', $$truncate pdks.duzeltme cascade$$);

-- 3) Çalışan aleyhine karar yalnızca İK ---------------------------------
select test.hata_bekle('amir devamsız kararı veremez',
    $$select pdks.duzeltme_uygula(test.gk(), 'durum', 'devamsiz', 'Amir gelmedi dedi', 'amir', test.kul('amir@ornek.test'))$$);
select test.hata_bekle('amir kendini İK diye gösteremez',
    $$select pdks.duzeltme_uygula(test.gk(), 'durum', 'devamsiz', 'İK gibi deneme', 'ik', test.kul('amir@ornek.test'))$$);
select test.hata_bekle('devamsız doğrudan yazılamaz',
    $$update pdks.gun_kaydi set durum = 'devamsiz' where id = test.gk()$$);
select test.dogrula('İK devamsız kararı verebilir',
    pdks.duzeltme_uygula(test.gk(), 'durum', 'devamsiz', 'İK kararı, test', 'ik', test.kul('ik@ornek.test')) is not null);
select test.dogrula('İK kararı aleyhine olarak işaretlendi',
    (select calisan_aleyhine from pdks.duzeltme where alan = 'durum' and gun_kaydi_id = test.gk()));

-- Amir "gelmedi" derse soru İK'ya gider
insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
values (test.gk(), 'giris_yok', 'Giriş yok, kanıt yok', test.kul('amir@ornek.test'), '2026-11-17');
update pdks.amir_sorusu set cevap = 'gelmedi', cevaplayan_id = test.kul('amir@ornek.test') where gun_kaydi_id = test.gk();
select test.dogrula('amir "gelmedi" deyince soru İK kararına düştü',
    (select durum = 'ik_karari_bekliyor' from pdks.amir_sorusu where gun_kaydi_id = test.gk()));

-- İtirazı yalnızca İK reddeder
insert into pdks.itiraz (calisan_id, gun_kaydi_id, metin) values (test.cal(), test.gk(), 'O gün işteydim');
select test.hata_bekle('amir itirazı reddedemez',
    $$update pdks.itiraz set durum = 'red', karar_veren_id = test.kul('amir@ornek.test') where gun_kaydi_id = test.gk()$$);

-- 4) Ay kilidi ve fark satırı (sorun 11) --------------------------------
select test.hata_bekle('amir ayı kilitleyemez', $$select pdks.donem_kilitle(pdks.donem_bul('2026-11-13'), test.kul('amir@ornek.test'), true)$$);
select pdks.donem_kilitle(pdks.donem_bul('2026-11-13'), test.kul('ik@ornek.test'), true);
select test.hata_bekle('kilit geri açılamaz',
    $$update pdks.donem set durum = 'acik' where yil = 2026 and ay = 11$$);
select test.hata_bekle('kilitli aydaki günlük kayıt değişmez',
    $$update pdks.gun_kaydi set gec_kalma_dk = 3 where id = test.gk()$$);
select pdks.duzeltme_uygula(test.gk(), 'cikis_zamani', '2026-11-13 17:30+03', 'Kilit sonrası düzeltme testi', 'ik', test.kul('ik@ornek.test'));
select test.dogrula('kilitli ay düzeltmesi Aralık''a fark satırı oldu',
    (select fark_satiri and dn.ay = 12 from pdks.duzeltme d join pdks.donem dn on dn.id = d.hedef_donem_id
     where d.alan = 'cikis_zamani' and d.gun_kaydi_id = test.gk()));
select test.dogrula('kilitli aydaki kayıt değişmedi',
    (select cikis_zamani = '2026-11-13 17:02+03' from pdks.gun_kaydi where id = test.gk()));

-- 5) Ayar değişikliği izlenir -------------------------------------------
update pdks.ayar set deger = 10, guncelleyen_id = test.kul('ik@ornek.test') where anahtar = 'yurume_payi_dk';
select test.dogrula('ayar değişikliği geçmişe yazıldı',
    exists (select 1 from pdks.ayar_gecmisi where anahtar = 'yurume_payi_dk' and eski_deger = 5 and yeni_deger = 10));

-- 6) API rolleri (Supabase) erişemez ------------------------------------
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'anon') then
        perform test.dogrula('anon pdks şemasına erişemez', not has_schema_privilege('anon', 'pdks', 'usage'));
    end if;
end $$;

do $$ begin raise notice 'TÜM TESTLER GEÇTİ'; end $$;
rollback;
