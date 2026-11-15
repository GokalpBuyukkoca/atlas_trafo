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
grant usage on schema test to pdks_uygulama, pdks_gece_isi;
grant execute on all functions in schema test to pdks_uygulama, pdks_gece_isi;

set timezone = 'Europe/Istanbul';

-- Örnek veri ------------------------------------------------------------
insert into pdks.kullanici (ad_soyad, eposta, rol) values
    ('Amir Bir', 'amir@ornek.test', 'amir'),
    ('İK Bir',   'ik@ornek.test',   'ik');
insert into pdks.departman (ad, amir_id) values ('Montaj', 1);
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
values ('1001', 'Ahmet', 'Örnek', 1, '2025-01-01');
insert into pdks.kart (kart_no, calisan_id) values ('K1001', 1);
insert into pdks.okuyucu (kod, ad, sistem) values ('PDKS-A', 'A kapısı PDKS', 'pdks'),
                                                ('KAPI-1', 'Tesis kapısı', 'kapi');
insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi)
values ('pdks', 'pdks_20261113.csv', 'abc', '2026-11-13'),
       ('kapi', 'kapi_20261113.csv', 'def', '2026-11-13');
insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani, yon)
values (1, 1, 'K1001', '2026-11-13 17:02+03', 'cikis');
insert into pdks.kanit_kaydi (aktarim_id, okuyucu_id, kaynak, kart_no, okutma_zamani, yon)
values (2, 2, 'kapi', 'K1001', '2026-11-13 07:50+03', 'giris');

-- Gece işi rolüyle günlük kaydı oluştur (sorun 1: giriş yok)
set role pdks_gece_isi;
insert into pdks.gun_kaydi (calisan_id, is_gunu, vardiya_id, cikis_zamani, cikis_kaynagi, durum)
values (1, '2026-11-13', 1, '2026-11-13 17:02+03', 'pdks', 'eksik');

-- 1) Ham kayıt değiştirilemez / silinemez ------------------------------
select test.hata_bekle('ham_okutma UPDATE yetkisi yok', $$update pdks.ham_okutma set kart_no = 'X'$$);
select test.hata_bekle('ham_okutma DELETE yetkisi yok', $$delete from pdks.ham_okutma$$);
reset role;
select test.hata_bekle('ham_okutma UPDATE postgres için bile trigger ile engelli',
                       $$update pdks.ham_okutma set kart_no = 'X'$$);
select test.hata_bekle('aynı dosya iki kez yüklenemez (sorun 16)',
    $$insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi)
      values ('pdks', 'tekrar.csv', 'abc', '2026-11-13')$$);
select test.hata_bekle('aynı okutma iki kez eklenemez',
    $$insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani)
      values (1, 1, 'K1001', '2026-11-13 17:02+03')$$);

-- 2) İzsiz düzeltme imkânsız -------------------------------------------
set role pdks_gece_isi;
select test.hata_bekle('giriş saati doğrudan UPDATE edilemez',
    $$update pdks.gun_kaydi set giris_zamani = '2026-11-13 08:00+03' where id = 1$$);
select test.hata_bekle('gece işi kanıtsız düzeltme yapamaz',
    $$select pdks.duzeltme_uygula(1, 'giris_zamani', '2026-11-13 08:00+03', 'kanıtsız deneme', 'gece_isi')$$);

-- Kanıtlı düzeltme (kapı 07:50, vardiya 08:00'den önce)
select pdks.duzeltme_uygula(1, 'giris_zamani', '2026-11-13 08:00+03',
                            'Kapı kaydı 07:50, vardiya başı yazıldı', 'gece_isi', p_kanit_kaydi_id => 1);
select test.dogrula('düzeltme kaydı tutuldu (eski boş, yeni 08:00)',
    (select eski_deger is null and yeni_deger::timestamptz = '2026-11-13 08:00+03' and kaynak = 'gece_isi'
     from pdks.duzeltme where gun_kaydi_id = 1));
select test.dogrula('günlük kayıt güncellendi, kaynak=kanit',
    (select giris_zamani = '2026-11-13 08:00+03' and giris_kaynagi = 'kanit' from pdks.gun_kaydi where id = 1));
select test.hata_bekle('düzeltme izi UPDATE edilemez', $$update pdks.duzeltme set gerekce = 'değişti'$$);
select test.hata_bekle('düzeltme izi DELETE edilemez', $$delete from pdks.duzeltme$$);
reset role;
select test.hata_bekle('düzeltme izi postgres için bile silinemez', $$delete from pdks.duzeltme$$);
select test.hata_bekle('düzeltme izi TRUNCATE edilemez', $$truncate pdks.duzeltme cascade$$);

-- 3) Çalışan aleyhine karar yalnızca İK ---------------------------------
set role pdks_uygulama;
select test.hata_bekle('amir devamsız kararı veremez',
    $$select pdks.duzeltme_uygula(1, 'durum', 'devamsiz', 'Amir gelmedi dedi', 'amir', 1)$$);
select test.hata_bekle('amir kendini İK diye gösteremez',
    $$select pdks.duzeltme_uygula(1, 'durum', 'devamsiz', 'İK gibi deneme', 'ik', 1)$$);
select test.hata_bekle('devamsız doğrudan yazılamaz',
    $$update pdks.gun_kaydi set durum = 'devamsiz' where id = 1$$);
select test.dogrula('İK devamsız kararı verebilir',
    pdks.duzeltme_uygula(1, 'durum', 'devamsiz', 'İK kararı, test', 'ik', 2) is not null);
select test.dogrula('İK kararı aleyhine olarak işaretlendi',
    (select calisan_aleyhine from pdks.duzeltme where alan = 'durum'));

-- Amir "gelmedi" derse soru İK'ya gider
reset role;
insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
values (1, 'giris_yok', 'Giriş yok, kanıt yok', 1, '2026-11-17');
set role pdks_uygulama;
update pdks.amir_sorusu set cevap = 'gelmedi', cevaplayan_id = 1 where id = 1;
select test.dogrula('amir "gelmedi" deyince soru İK kararına düştü',
    (select durum = 'ik_karari_bekliyor' from pdks.amir_sorusu where id = 1));

-- İtirazı yalnızca İK reddeder
insert into pdks.itiraz (calisan_id, gun_kaydi_id, metin) values (1, 1, 'O gün işteydim');
select test.hata_bekle('amir itirazı reddedemez',
    $$update pdks.itiraz set durum = 'red', karar_veren_id = 1 where id = 1$$);

-- 4) Ay kilidi ve fark satırı (sorun 11) --------------------------------
select test.hata_bekle('amir ayı kilitleyemez', $$select pdks.donem_kilitle(pdks.donem_bul('2026-11-13'), 1, true)$$);
select pdks.donem_kilitle(pdks.donem_bul('2026-11-13'), 2, true);
select test.hata_bekle('kilit geri açılamaz',
    $$update pdks.donem set durum = 'acik' where yil = 2026 and ay = 11$$);
select test.hata_bekle('kilitli aydaki günlük kayıt değişmez',
    $$update pdks.gun_kaydi set gec_kalma_dk = 3 where id = 1$$);
select pdks.duzeltme_uygula(1, 'cikis_zamani', '2026-11-13 17:30+03', 'Kilit sonrası düzeltme testi', 'ik', 2);
select test.dogrula('kilitli ay düzeltmesi Aralık''a fark satırı oldu',
    (select fark_satiri and dn.ay = 12 from pdks.duzeltme d join pdks.donem dn on dn.id = d.hedef_donem_id
     where d.alan = 'cikis_zamani'));
select test.dogrula('kilitli aydaki kayıt değişmedi',
    (select cikis_zamani = '2026-11-13 17:02+03' from pdks.gun_kaydi where id = 1));

-- 5) Kiosk PIN (sorun 17) ----------------------------------------------
select pdks.pin_sifirla(1, '1234', 2);
select test.dogrula('ilk girişte PIN değişimi istenir', pdks.kiosk_giris('1001', '1234') = 'pin_degismeli');
select test.dogrula('PIN değiştirildi', pdks.kiosk_pin_degistir('1001', '1234', '5678'));
select test.dogrula('yeni PIN ile giriş', pdks.kiosk_giris('1001', '5678') = 'tamam');
select pdks.kiosk_giris('1001', '0000') from generate_series(1, 4);
select test.dogrula('5. hatalı denemede kilit', pdks.kiosk_giris('1001', '0000') = 'kilitli');
select test.dogrula('kilit İK''ya uyarı olarak düştü',
    exists (select 1 from pdks.uyari where tur = 'pin_kilitlendi' and calisan_id = 1));
select test.dogrula('PIN açık metin olarak saklanmıyor',
    (select pin_ozeti not like '%5678%' from pdks.calisan where id = 1));

-- 6) Ayar değişikliği izlenir -------------------------------------------
update pdks.ayar set deger = 10, guncelleyen_id = 2 where anahtar = 'yurume_payi_dk';
select test.dogrula('ayar değişikliği geçmişe yazıldı',
    exists (select 1 from pdks.ayar_gecmisi where anahtar = 'yurume_payi_dk' and eski_deger = 5 and yeni_deger = 10));

-- 7) API rolleri (Supabase) erişemez ------------------------------------
reset role;
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'anon') then
        perform test.dogrula('anon pdks şemasına erişemez', not has_schema_privilege('anon', 'pdks', 'usage'));
    end if;
end $$;

do $$ begin raise notice 'TÜM TESTLER GEÇTİ'; end $$;
rollback;
