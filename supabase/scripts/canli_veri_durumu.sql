-- =====================================================================
-- Canlıda hangi veri var? (YALNIZCA OKUR; hiçbir şeyi değiştirmez)
-- Supabase > SQL Editor'da çalıştırılır. Canlıya migration ya da seed uygulamadan
-- önce verinin örnek veri mi yoksa elle girilmiş veri mi olduğunu anlamak için.
--
-- 3. satır, örnek verideki ilk 31 sicili (1001–1010, 2001–2010, 3001–3005, 4001–4006)
-- tanır; 19 departmanlı yeni örnek veride diğer siciller de "örnek veri dışında" sayılır.
-- =====================================================================
select x.sira, x.kalem, x.deger
from (values
    (1,  'örnek veri yüklü mü (sicil 1001 var)', (select count(*) from pdks.calisan where sicil_no = '1001')::text),
    (2,  'çalışan / departman',                  (select count(*) from pdks.calisan) || ' / ' || (select count(*) from pdks.departman)),
    (3,  'örnek veri dışında çalışan',           (select count(*) from pdks.calisan
                                                 where sicil_no !~ '^(10(0[1-9]|10)|20(0[1-9]|10)|300[1-5]|400[1-6])$')::text),
    (4,  'gün kaydı (toplam)',                   (select count(*) from pdks.gun_kaydi)::text),
    (5,  'gün kaydı: ilk / son iş günü',         coalesce((select min(is_gunu) || ' / ' || max(is_gunu) from pdks.gun_kaydi), '—')),
    (6,  'gece işi: son başarılı gün',           coalesce((select max(islenen_gun)::text from pdks.gece_isi where durum = 'basarili'), '—')),
    (7,  'gece işi: hatalı çalışma',             (select count(*) from pdks.gece_isi where durum = 'hatali')::text),
    (8,  'insan düzeltmesi (amir / İK)',         (select count(*) from pdks.duzeltme where kaynak <> 'gece_isi')::text),
    (9,  'açık amir sorusu',                     (select count(*) from pdks.amir_sorusu where durum in ('acik', 'eskale', 'ik_karari_bekliyor'))::text),
    (10, 'kilitli dönem',                        (select count(*) from pdks.donem where durum = 'kilitli')::text),
    (11, 'kullanıcı / Auth hesabına bağlı',      (select count(*) || ' / ' || count(*) filter (where auth_kullanici_id is not null) from pdks.kullanici)),
    (12, 'pg_cron gece işi zamanlı mı',          (select case when to_regclass('cron.job') is null then 'pg_cron yok'
                                                              else (xpath('/row/n/text()', x))[1]::text end
                                                  from query_to_xml(
                                                      case when to_regclass('cron.job') is null then 'select 0 as n'
                                                           else 'select count(*) as n from cron.job where jobname = ''pdks-gece-isi''' end,
                                                      false, false, '') t(d), unnest(xpath('/table/row', d)) x))
) as x(sira, kalem, deger)
order by x.sira;
