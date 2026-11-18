-- =====================================================================
-- Örnek veri testleri. supabase/seed.sql yüklendikten sonra çalıştırılır.
-- Verinin beklenen büyüklükte olduğunu ve her senaryonun yerinde durduğunu
-- doğrular. Her şey sonda geri alınır (ROLLBACK).
-- Çalıştırma: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ornek_veri_testi.sql
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
create function test.c(p text) returns bigint language sql as $$ select id from pdks.calisan where sicil_no = p $$;
-- Bir çalışanın bir günde (yerel saat) belirli sistemdeki okutmaları
create function test.okutma(p_sicil text, p_gun date, p_sistem text, p_yon text)
returns setof timestamptz language sql as $$
    select o.okutma_zamani
    from (select kart_no, okutma_zamani, yon, 'pdks' as sistem from pdks.ham_okutma
          union all select kart_no, okutma_zamani, yon, kaynak from pdks.kanit_kaydi) o
    where o.sistem = p_sistem and o.yon is not distinct from p_yon
      and (o.okutma_zamani at time zone 'Europe/Istanbul')::date = p_gun
      and (pdks.okutma_sahibi(o.kart_no, o.okutma_zamani) = test.c(p_sicil)
           or o.kart_no in (select kart_no from pdks.kart where calisan_id = test.c(p_sicil)))
$$;

do $$ begin
    if not exists (select 1 from pdks.calisan where sicil_no = '1001') then
        raise exception 'KALDI  Örnek veri yüklü değil; önce supabase/seed.sql çalıştırılmalı.';
    end if;
end $$;

-- Büyüklük ve bütünlük --------------------------------------------------------
select test.dogrula('31 çalışan, 4 departman', (select count(*) from pdks.calisan) = 31 and (select count(*) from pdks.departman) = 4);
select test.dogrula('8 kullanıcı: 2 İK, 4 amir, 1 güvenlik, 1 yönetici',
    (select count(*) from pdks.kullanici) = 8
    and (select count(*) from pdks.kullanici where rol = 'ik') = 2
    and (select count(*) from pdks.kullanici where rol = 'amir') = 4);
select test.dogrula('her kullanıcı bir çalışana bağlı', not exists (select 1 from pdks.kullanici where calisan_id is null));
select test.dogrula('kullanıcı e-postaları yalnızca örnek alan adında (example.com)',
    not exists (select 1 from pdks.kullanici where eposta not like '%@example.com'));
select test.dogrula('her departmanın amiri var', not exists (select 1 from pdks.departman where amir_id is null));
select test.dogrula('her çalışanın tam olarak bir aktif kartı var',
    not exists (select 1 from pdks.calisan c
                where (select count(*) from pdks.kart k where k.calisan_id = c.id and k.durum = 'aktif') <> 1));
select test.dogrula('Kasım hafta içi her gün herkesin vardiya planı var (31 kişi x 21 gün)',
    (select count(*) from pdks.vardiya_plani where tarih between '2026-11-01' and '2026-11-30') = 31 * 21);
select test.dogrula('her kaynaktan her gün bir dosya (27 Kasım servis hariç)',
    (select count(*) from pdks.aktarim) = 4 * 30 - 1);
select test.dogrula('yüzlerce PDKS ve kanıt okutması var',
    (select count(*) from pdks.ham_okutma) > 1000 and (select count(*) from pdks.kanit_kaydi) > 2000);
select test.dogrula('Bobinaj grupları haftalık dönüyor (Kemal: V1, V2, V3)',
    (select count(distinct vardiya_id) from pdks.vardiya_plani where calisan_id = test.c('2002')) = 3);
select test.dogrula('resmi tatiller girili (2026)', (select count(*) from pdks.resmi_tatil where extract(year from tarih) = 2026) >= 17);

-- Senaryolar -------------------------------------------------------------------
select test.dogrula('S1  Mehmet 3 Kasım: PDKS girişi yok, kapı girişi 08:00 öncesi',
    not exists (select test.okutma('1002', '2026-11-03', 'pdks', 'giris'))
    and (select min(z) from test.okutma('1002', '2026-11-03', 'kapi', 'giris') z) < '2026-11-03 08:00+03');
select test.dogrula('S2  Ali 4 Kasım: PDKS girişi yok, kapı girişi 08:25',
    not exists (select test.okutma('1003', '2026-11-04', 'pdks', 'giris'))
    and (select min(z) from test.okutma('1003', '2026-11-04', 'kapi', 'giris') z) = '2026-11-04 08:25+03');
select test.dogrula('S3  Veli 5 Kasım: PDKS çıkışı yok, kapı çıkışı 17:12',
    not exists (select test.okutma('1004', '2026-11-05', 'pdks', 'cikis'))
    and (select max(z) from test.okutma('1004', '2026-11-05', 'kapi', 'cikis') z) = '2026-11-05 17:12+03');
select test.dogrula('S4  Mustafa 5 Kasım: çıkışa dair hiçbir okutma yok',
    not exists (select test.okutma('1005', '2026-11-05', s, 'cikis') from unnest(array['pdks', 'kapi', 'servis']) s));
select test.dogrula('S5  Hüseyin 6 Kasım: iki PDKS girişi 40 sn arayla',
    (select count(*) from test.okutma('1006', '2026-11-06', 'pdks', 'giris')) = 2);
select test.dogrula('S6  İbrahim 10 Kasım: geçici kart GK-01 zimmetli ve okutulmuş',
    exists (select 1 from pdks.gecici_kart_zimmet z join pdks.gecici_kart g on g.id = z.gecici_kart_id
            where g.kart_no = 'GK-01' and z.calisan_id = test.c('1007')
              and (z.verilis_zamani at time zone 'Europe/Istanbul')::date = '2026-11-10')
    and exists (select 1 from pdks.ham_okutma where kart_no = 'GK-01'
                and pdks.okutma_sahibi(kart_no, okutma_zamani) = test.c('1007')));
select test.dogrula('S7  Osman Kasım''da 3 kez geçici kart aldı',
    (select count(*) from pdks.gecici_kart_zimmet where calisan_id = test.c('1008')) = 3);
select test.dogrula('S8  Emre''nin eski kartı kayıp diye iptal, yeni kartı aktif, eski kart 16 Kasım''da okutuldu',
    (select durum = 'iptal' and iptal_nedeni = 'kayip' from pdks.kart where kart_no = 'K1009')
    and (select durum = 'aktif' from pdks.kart where kart_no = 'K1009B')
    and exists (select 1 from pdks.ham_okutma where kart_no = 'K1009'
                and (okutma_zamani at time zone 'Europe/Istanbul')::date = '2026-11-16'));
select test.dogrula('S9  Burak''ın GK-02 zimmeti iade edilmedi',
    exists (select 1 from pdks.gecici_kart_zimmet z join pdks.gecici_kart g on g.id = z.gecici_kart_id
            where g.kart_no = 'GK-02' and z.calisan_id = test.c('1010') and z.iade_zamani is null));
select test.dogrula('S10 19 Kasım 05:30-09:30 atölye PDKS''inde okutma yok, kapıda var',
    not exists (select 1 from pdks.ham_okutma h join pdks.okuyucu r on r.id = h.okuyucu_id
                where r.kod = 'PDKS-2' and h.okutma_zamani >= '2026-11-19 05:30+03' and h.okutma_zamani < '2026-11-19 09:30+03')
    and exists (select 1 from pdks.kanit_kaydi
                where kaynak = 'kapi' and okutma_zamani >= '2026-11-19 05:30+03' and okutma_zamani < '2026-11-19 09:30+03'));
select test.dogrula('S12 gece vardiyası gece yarısını aşıyor (Cem 16 Kasım girişi, 17 Kasım çıkışı)',
    exists (select test.okutma('2004', '2026-11-16', 'pdks', 'giris'))
    and exists (select test.okutma('2004', '2026-11-17', 'pdks', 'cikis')));
select test.dogrula('S13 Okan''ın 13 Kasım planı geriye dönük ve İK onayı bekliyor',
    (select geriye_donuk and ik_onay_durumu = 'bekliyor' from pdks.vardiya_plani
     where calisan_id = test.c('2005') and tarih = '2026-11-13'));
select test.dogrula('S14 Selin 9 Kasım 08:35''te girdi, 13 Kasım 16:20''de çıktı',
    (select min(z) from test.okutma('3002', '2026-11-09', 'pdks', 'giris') z) = '2026-11-09 08:35+03'
    and (select max(z) from test.okutma('3002', '2026-11-13', 'pdks', 'cikis') z) = '2026-11-13 16:20+03');
select test.dogrula('S15 Gizem''in 20 Kasım fazla mesai planı onaylı (120 dk)',
    (select durum = 'onaylandi' and planli_dk = 120 from pdks.fazla_mesai_plani
     where calisan_id = test.c('3003') and is_gunu = '2026-11-20'));
select test.dogrula('S16 Ece 23 Kasım planı olmadan 19:30''a kalmış',
    not exists (select 1 from pdks.fazla_mesai_plani where calisan_id = test.c('3004'))
    and (select max(z) from test.okutma('3004', '2026-11-23', 'pdks', 'cikis') z) = '2026-11-23 19:30+03');
select test.dogrula('S17 Merve''nin yazılı fazla mesai onayı yok',
    not exists (select 1 from pdks.fazla_mesai_onayi where calisan_id = test.c('3005')));
select test.dogrula('S18 Can raporlu, Deniz yıllık izinli; izin günlerinde okutmaları yok',
    exists (select 1 from pdks.izin where calisan_id = test.c('2007') and tur = 'rapor')
    and exists (select 1 from pdks.izin where calisan_id = test.c('2008') and tur = 'yillik')
    and not exists (select test.okutma('2007', '2026-11-24', 'pdks', 'giris')));
select test.dogrula('S19 Kaan 25 Kasım: planı var, izni ve hiçbir okutması yok',
    exists (select 1 from pdks.vardiya_plani where calisan_id = test.c('2009') and tarih = '2026-11-25')
    and not exists (select test.okutma('2009', '2026-11-25', s, 'giris') from unnest(array['pdks', 'kapi']) s));
select test.dogrula('S20 sistemde olmayan kart (K9999) okutulmuş',
    exists (select 1 from pdks.ham_okutma where kart_no = 'K9999')
    and not exists (select 1 from pdks.kart where kart_no = 'K9999'));
select test.dogrula('S21 27 Kasım servis dosyası yok',
    not exists (select 1 from pdks.aktarim where kaynak = 'servis' and veri_tarihi = '2026-11-27'));
select test.dogrula('S22 Montaj amiri Hasan''ın 26 Kasım girişine dair hiçbir okutma yok, üst amiri tanımlı',
    not exists (select test.okutma('1001', '2026-11-26', s, 'giris') from unnest(array['pdks', 'kapi', 'servis']) s)
    and (select ust_amir_id is not null from pdks.kullanici where calisan_id = test.c('1001')));

-- Hazır kontrol fonksiyonları beklenen uyarıları üretiyor ------------------------
select pdks.kart_paylasim_kontrol('2026-11-30');
select pdks.gecici_kart_kontrol(g::date) from generate_series(date '2026-11-01', date '2026-11-30', interval '1 day') g;
select test.dogrula('S11 Kemal ve Murat için kart paylaşımı şüphesi',
    exists (select 1 from pdks.uyari where tur = 'kart_paylasim_suphesi'));
select test.dogrula('S6  İbrahim''in asıl kartı geçici kart zimmetliyken okutuldu uyarısı',
    exists (select 1 from pdks.uyari where tur = 'gecici_kart_cakisma' and calisan_id = test.c('1007')));
select test.dogrula('S7  Osman için sık kart unutma bilgisi',
    exists (select 1 from pdks.uyari where tur = 'sik_kart_unutma' and calisan_id = test.c('1008')));
select test.dogrula('S9  Burak için iade edilmeyen geçici kart uyarısı',
    exists (select 1 from pdks.uyari where tur = 'gecici_kart_iade_edilmedi' and calisan_id = test.c('1010')));
select test.dogrula('S23 zimmetsiz okutulan geçici kart (yalnızca GK-05)',
    (select count(*) from pdks.uyari where tur = 'gecici_kart_zimmetsiz') = 1
    and exists (select 1 from pdks.uyari where tur = 'gecici_kart_zimmetsiz' and mesaj like '%GK-05%'));

do $$ begin raise notice 'ÖRNEK VERİ TESTLERİ GEÇTİ'; end $$;
rollback;
