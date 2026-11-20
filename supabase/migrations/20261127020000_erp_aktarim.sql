-- =====================================================================
-- ERP aktarımı: kilitli ayın puantaj icmali, standart satır biçiminde
--
--   v_puantaj_aktarim: her satır bir çalışanın bir puantaj kodudur
--     donem         : puantajın yazıldığı ay (YYYY-MM)
--     sicil         : çalışan sicil no
--     satir_turu    : normal / fark
--     kaynak_donem  : fark satırında düzeltmenin ait olduğu ay (YYYY-MM)
--     kod           : NÇ, FM50, FM100, Yİ, RPR, MZR, ÜCSZ, Dİ, DVMSZ, RT, HT
--     gun, dakika
--   Yalnızca kilitli aylar (kesin veri) yer alır. Ekran bu satırlardan CSV ve
--   XML dosyası üretir. Ücret yoktur; yalnızca gün ve dakika.
--   Çağıranın yetkisiyle çalışır: İK ve yönetici görür (puantaj_kalemi RLS).
-- =====================================================================

create view pdks.v_puantaj_aktarim
with (security_invoker = true)
as
select d.id                                                    as donem_id,
       to_char(make_date(d.yil, d.ay, 1), 'YYYY-MM')           as donem,
       c.sicil_no                                              as sicil,
       s.satir_turu,
       case when kd.id is not null then to_char(make_date(kd.yil, kd.ay, 1), 'YYYY-MM') end as kaynak_donem,
       k.kod,
       k.gun,
       k.dakika,
       s.calisan_id,
       s.id                                                    as puantaj_satiri_id
from pdks.puantaj_kalemi k
join pdks.puantaj_satiri s on s.id = k.puantaj_satiri_id
join pdks.donem d on d.id = s.donem_id and d.durum = 'kilitli'
join pdks.calisan c on c.id = s.calisan_id
left join pdks.donem kd on kd.id = s.kaynak_donem_id;

comment on view pdks.v_puantaj_aktarim is
    'ERP aktarımı: kilitli ayın puantaj kalemleri (sicil, dönem, satır türü, kaynak dönem, kod, gün, dakika).';

grant select on pdks.v_puantaj_aktarim to authenticated;
