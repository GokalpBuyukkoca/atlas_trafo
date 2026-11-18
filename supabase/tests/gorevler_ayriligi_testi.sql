-- =====================================================================
-- Görevler ayrılığı testleri: kimse kendi kaydında işlem yapamaz.
-- Her şey tek işlemde çalışır ve sonda geri alınır (ROLLBACK).
-- Çalıştırma: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gorevler_ayriligi_testi.sql
-- =====================================================================
\pset tuples_only on
\pset format unaligned
begin;

create schema test;
-- Hata bekler; hata mesajı verilen kalıbı içermeli (doğru kural yakalamalı)
create function test.kural_hatasi(p_ad text, p_kalip text, p_sql text) returns void language plpgsql as $$
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
create function test.dogrula(p_ad text, p_kosul boolean) returns void language plpgsql as $$
begin
    if p_kosul is not true then raise exception 'KALDI  %', p_ad; end if;
    raise notice 'GEÇTİ  %', p_ad;
end $$;
create function test.k(p text) returns bigint language sql as $$ select id from pdks.kullanici where eposta = p $$;
create function test.c(p text) returns bigint language sql as $$ select id from pdks.calisan where sicil_no = p $$;
create function test.g(p text) returns bigint language sql as $$
    select id from pdks.gun_kaydi where calisan_id = test.c(p) and is_gunu = '2026-11-13' $$;

set timezone = 'Europe/Istanbul';

-- Örnek veri (yalnızca sahte) ----------------------------------------------
-- Herkes hem kullanıcı hem kart basan çalışan
insert into pdks.departman (ad) values ('GA Montaj'), ('GA İdari');
insert into pdks.calisan (sicil_no, ad, soyad, departman_id, ise_giris_tarihi)
select s, a, 'Örnek', (select id from pdks.departman where ad = d), '2025-01-01'
from (values ('GA01', 'Ahmet', 'GA Montaj'),     -- işçi
             ('GA11', 'Gökalp', 'GA İdari'),     -- İK
             ('GA12', 'Ayşe', 'GA İdari'),       -- ikinci İK
             ('GA21', 'Ali', 'GA Montaj'),       -- Montaj amiri
             ('GA22', 'Üst', 'GA İdari'),        -- Ali'nin üst amiri
             ('GA31', 'Gül', 'GA İdari'))        -- güvenlik
     v(s, a, d);

insert into pdks.kullanici (ad_soyad, eposta, rol, calisan_id) values
    ('Gökalp Örnek', 'gokalp@ornek.test', 'ik',       test.c('GA11')),
    ('Ayşe Örnek',   'ayse@ornek.test',   'ik',       test.c('GA12')),
    ('Üst Örnek',    'ust@ornek.test',    'amir',     test.c('GA22')),
    ('Gül Örnek',    'gul@ornek.test',    'guvenlik', test.c('GA31'));
insert into pdks.kullanici (ad_soyad, eposta, rol, calisan_id, ust_amir_id)
values ('Ali Örnek', 'ali@ornek.test', 'amir', test.c('GA21'), test.k('ust@ornek.test'));
update pdks.departman set amir_id = test.k('ali@ornek.test') where ad = 'GA Montaj';

insert into pdks.gun_kaydi (calisan_id, is_gunu, vardiya_id, durum)
select test.c(s), '2026-11-13', 1, 'eksik' from unnest(array['GA01', 'GA11', 'GA21']) s;

select test.dogrula('kullanıcı çalışan kaydına bağlanabiliyor',
    (select calisan_id = test.c('GA11') from pdks.kullanici where eposta = 'gokalp@ornek.test'));
select test.kural_hatasi('bir çalışan iki kullanıcıya bağlanamaz', 'kullanici_calisan_id_key',
    $$insert into pdks.kullanici (ad_soyad, eposta, rol, calisan_id)
      values ('Kopya', 'kopya@ornek.test', 'ik', test.c('GA11'))$$);

-- 1) Düzeltme ---------------------------------------------------------------
select test.kural_hatasi('İK kendi gün kaydını düzeltemez', 'Görevler ayrılığı',
    $$select pdks.duzeltme_uygula(test.g('GA11'), 'giris_zamani', '2026-11-13 08:00+03',
                                  'Kendi kaydım', 'ik', test.k('gokalp@ornek.test'))$$);
select test.dogrula('İK, başka İK''nın kaydını düzeltebilir',
    pdks.duzeltme_uygula(test.g('GA11'), 'giris_zamani', '2026-11-13 08:00+03',
                         'Ayşe düzeltti', 'ik', test.k('ayse@ornek.test')) is not null);
select test.dogrula('İK, işçinin kaydını düzeltebilir',
    pdks.duzeltme_uygula(test.g('GA01'), 'giris_zamani', '2026-11-13 08:00+03',
                         'Gökalp düzeltti', 'ik', test.k('gokalp@ornek.test')) is not null);

-- 2) Amir sorusu -------------------------------------------------------------
insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
values (test.g('GA21'), 'giris_yok', 'Ali''nin kendi günü', test.k('ali@ornek.test'), '2026-11-17');
select test.dogrula('amirin kendi hakkındaki soru üst amirine yönlendi',
    (select atanan_id = test.k('ust@ornek.test') from pdks.amir_sorusu where gun_kaydi_id = test.g('GA21')));
select test.kural_hatasi('amir kendi hakkındaki soruyu cevaplayamaz', 'Görevler ayrılığı',
    $$update pdks.amir_sorusu set cevap = 'geldi_saat_dogru', cevaplayan_id = test.k('ali@ornek.test')
      where gun_kaydi_id = test.g('GA21')$$);
select test.kural_hatasi('soru, sorunun sahibine eskale edilemez', 'Görevler ayrılığı',
    $$update pdks.amir_sorusu set eskale_edilen_id = test.k('ali@ornek.test')
      where gun_kaydi_id = test.g('GA21')$$);
update pdks.kullanici set ust_amir_id = null where eposta = 'ali@ornek.test';
select test.kural_hatasi('üst amiri yoksa kendi sorusu açılamaz', 'üst amiri tanımlı değil',
    $$insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
      values (test.g('GA21'), 'cikis_yok', 'Ali''nin çıkışı', test.k('ali@ornek.test'), '2026-11-17')$$);
insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
values (test.g('GA01'), 'cikis_yok', 'Ahmet''in çıkışı', test.k('ali@ornek.test'), '2026-11-17');
select test.dogrula('amir, ekibindeki çalışanın sorusuna atanabiliyor',
    (select atanan_id = test.k('ali@ornek.test') from pdks.amir_sorusu where gun_kaydi_id = test.g('GA01')));

-- 3) İtiraz ------------------------------------------------------------------
insert into pdks.itiraz (calisan_id, gun_kaydi_id, metin) values (test.c('GA11'), test.g('GA11'), 'O gün işteydim');
select test.kural_hatasi('İK kendi itirazına karar veremez', 'Görevler ayrılığı',
    $$update pdks.itiraz set durum = 'kabul', karar_veren_id = test.k('gokalp@ornek.test')
      where calisan_id = test.c('GA11')$$);

-- 4) Fazla mesai --------------------------------------------------------------
select test.kural_hatasi('İK kendi yazılı fazla mesai onayını giremez', 'Görevler ayrılığı',
    $$insert into pdks.fazla_mesai_onayi (calisan_id, yil, imza_tarihi, belge_no, giren_id)
      values (test.c('GA11'), 2026, '2026-01-02', 'GA-FMO-1', test.k('gokalp@ornek.test'))$$);
select test.kural_hatasi('amir kendi fazla mesaisini talep edemez', 'Görevler ayrılığı',
    $$insert into pdks.fazla_mesai_plani (calisan_id, is_gunu, vardiya_id, planli_dk, gerekce, talep_eden_id)
      values (test.c('GA21'), '2026-12-01', 1, 60, 'Sipariş yetişmeli', test.k('ali@ornek.test'))$$);
insert into pdks.fazla_mesai_onayi (calisan_id, yil, imza_tarihi, belge_no, giren_id)
values (test.c('GA01'), 2026, '2026-01-02', 'GA-FMO-2', test.k('ayse@ornek.test'));
insert into pdks.vardiya_plani (calisan_id, tarih, vardiya_id) values (test.c('GA01'), '2026-12-01', 1);
insert into pdks.fazla_mesai_plani (calisan_id, is_gunu, vardiya_id, planli_dk, gerekce, talep_eden_id)
values (test.c('GA01'), '2026-12-01', 1, 60, 'Sipariş yetişmeli', test.k('ayse@ornek.test'));
select test.kural_hatasi('fazla mesaide talep eden ile onaylayan aynı kişi olamaz', 'fazla_mesai_talep_onay_farkli',
    $$update pdks.fazla_mesai_plani set durum = 'onaylandi', karar_veren_id = talep_eden_id, karar_zamani = now()
      where calisan_id = test.c('GA01') and is_gunu = '2026-12-01'$$);

-- 5) Geçici kart ----------------------------------------------------------------
insert into pdks.gecici_kart (kart_no) values ('GA-GK1');
select test.kural_hatasi('güvenlik kendine geçici kart veremez', 'Görevler ayrılığı',
    $$insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id)
      values ((select id from pdks.gecici_kart where kart_no = 'GA-GK1'), test.c('GA31'),
              '2026-11-13 07:50+03', test.k('gul@ornek.test'))$$);

-- 6) İzin, vardiya, uyarı, kart ------------------------------------------------
select test.kural_hatasi('İK kendi iznini giremez', 'Görevler ayrılığı',
    $$insert into pdks.izin (calisan_id, tur, baslangic, bitis, giren_id)
      values (test.c('GA11'), 'yillik', '2026-12-01', '2026-12-02', test.k('gokalp@ornek.test'))$$);
insert into pdks.izin (calisan_id, tur, baslangic, bitis, giren_id)
values (test.c('GA11'), 'yillik', '2026-12-01', '2026-12-02', test.k('ayse@ornek.test'));
select test.dogrula('başka İK, İK''nın iznini girebilir',
    exists (select 1 from pdks.izin where calisan_id = test.c('GA11')));
select test.kural_hatasi('İK kendi vardiyasını giremez', 'Görevler ayrılığı',
    $$insert into pdks.vardiya_plani (calisan_id, tarih, vardiya_id, giren_id)
      values (test.c('GA11'), '2026-12-03', 1, test.k('gokalp@ornek.test'))$$);
insert into pdks.uyari (tur, calisan_id, mesaj) values ('kart_paylasim_suphesi', test.c('GA11'), 'Örnek uyarı');
select test.kural_hatasi('İK kendisiyle ilgili uyarıyı "görüldü" yapamaz', 'Görevler ayrılığı',
    $$update pdks.uyari set goruldu = true, goren_id = test.k('gokalp@ornek.test'), gorulme_zamani = now()
      where calisan_id = test.c('GA11')$$);
insert into pdks.kart (kart_no, calisan_id) values ('GA-K11', test.c('GA11'));
select test.kural_hatasi('İK kendi kartını iptal edemez', 'Görevler ayrılığı',
    $$update pdks.kart set durum = 'iptal', iptal_nedeni = 'kayip', iptal_zamani = now(),
                           iptal_eden_id = test.k('gokalp@ornek.test')
      where kart_no = 'GA-K11'$$);

do $$ begin raise notice 'GÖREVLER AYRILIĞI TESTLERİ GEÇTİ'; end $$;
rollback;
