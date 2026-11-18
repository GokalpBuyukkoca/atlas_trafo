-- =====================================================================
-- İzin iptali ve departman özeti
--
--  * pdks.izin_iptal(izin_id, neden)  (İK): izin silinmez, iptal işareti alır
--    (kim, ne zaman, neden). İznin bir günü gece işinden "izinli/raporlu"
--    olarak geçmişse iptal reddedilir; o günler kayit_duzelt ile düzeltilir.
--    İptal edilen izni gece işi ve amir görünümü (v_izin_amir) yok sayar.
--  * pdks.v_departman_ozet: ay + departman başına özet (yönetici paneli).
--    Çağıranın yetkisiyle çalışır: İK ve yönetici hepsini, amir kendi
--    departmanını görür (mevcut RLS kuralları).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. İzin iptal izi
-- ---------------------------------------------------------------------
alter table pdks.izin
    add column iptal_zamani  timestamptz,
    add column iptal_eden_id bigint references pdks.kullanici (id),
    add column iptal_nedeni  text,
    add constraint izin_iptal_tam check (
        (iptal_zamani is null and iptal_eden_id is null and iptal_nedeni is null)
        or (iptal_zamani is not null and iptal_eden_id is not null and length(trim(iptal_nedeni)) >= 5));

comment on column pdks.izin.iptal_zamani is 'Dolu ise izin iptal edilmiştir; gece işi ve amir görünümü yok sayar.';

-- Görevler ayrılığı: İK kendi iznini iptal edemez
drop trigger izin_gorev_ayriligi on pdks.izin;
create trigger izin_gorev_ayriligi before insert or update on pdks.izin
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'giren_id', 'iptal_eden_id');

-- ---------------------------------------------------------------------
-- 2. İzin iptali (ekran fonksiyonu, yalnızca İK)
-- ---------------------------------------------------------------------
create function pdks.izin_iptal(p_izin_id bigint, p_neden text)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben    bigint := pdks.yetki_gerekli('ik');
    v_izin   pdks.izin;
    v_islenen integer;
begin
    select * into v_izin from pdks.izin where id = p_izin_id for update;
    if not found then
        raise exception 'İzin bulunamadı.';
    end if;
    if v_izin.iptal_zamani is not null then
        raise exception 'Bu izin zaten iptal edilmiş.';
    end if;
    if p_neden is null or length(trim(p_neden)) < 5 then
        raise exception 'İptal nedeni yazılmalı (en az 5 karakter).';
    end if;

    select count(*) into v_islenen
    from pdks.gun_kaydi g
    where g.calisan_id = v_izin.calisan_id
      and g.is_gunu between v_izin.baslangic and v_izin.bitis
      and g.durum in ('izinli', 'raporlu');
    if v_islenen > 0 then
        raise exception 'Bu iznin % günü işlenmiş; o günleri önce kayıt düzeltmeyle düzeltin.', v_islenen;
    end if;

    update pdks.izin
    set iptal_zamani = now(), iptal_eden_id = v_ben, iptal_nedeni = trim(p_neden)
    where id = p_izin_id;
end;
$$;

revoke execute on function pdks.izin_iptal(bigint, text) from public, anon;
grant execute on function pdks.izin_iptal(bigint, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Gece işi iptal edilen izni yok sayar (yalnızca izin sorgusu değişti)
-- ---------------------------------------------------------------------
create or replace function pdks.gece_isi_gun_kayitlari(p_gun date, p_gece_isi_id bigint)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_n integer;
begin
    with plan as (
        select vp.calisan_id, vp.vardiya_id, vt.pencere_once_dk, vt.pencere_sonra_dk,
               (p_gun + vt.baslangic) at time zone 'Europe/Istanbul' as bas,
               (p_gun + case when vt.gece_yarisini_asar then 1 else 0 end + vt.bitis) at time zone 'Europe/Istanbul' as bit
        from pdks.vardiya_plani vp
        join pdks.vardiya_tanim vt on vt.id = vp.vardiya_id
        join pdks.calisan c on c.id = vp.calisan_id and c.aktif
        where vp.tarih = p_gun
          and not exists (select 1 from pdks.gun_kaydi g where g.calisan_id = vp.calisan_id and g.is_gunu = p_gun)
    ), tam as (
        select p.* from plan p
        where pdks.pdks_verisi_tam_mi(p.bas - make_interval(mins => p.pencere_once_dk),
                                      p.bit + make_interval(mins => p.pencere_sonra_dk))
    ), okut as (
        select p.calisan_id,
               min(h.okutma_zamani) filter (where h.yon is distinct from 'cikis') as giris,
               max(h.okutma_zamani) filter (where h.yon is distinct from 'giris') as cikis
        from tam p
        join pdks.ham_okutma h
          on h.okutma_zamani between p.bas - make_interval(mins => p.pencere_once_dk)
                                 and p.bit + make_interval(mins => p.pencere_sonra_dk)
        where pdks.okutma_sahibi(h.kart_no, h.okutma_zamani) = p.calisan_id
          and not pdks.okutma_gecersiz_mi(h.id)
        group by p.calisan_id
    ), durumlu as (
        select t.calisan_id, t.vardiya_id, t.bas, t.bit, o.giris,
               -- Giriş yoksa çıkış tek başına geçerlidir; ikisi de varsa çıkış girişten sonra olmalı
               case when o.giris is null or o.cikis > o.giris then o.cikis end as cikis,
               (select i.tur from pdks.izin i
                where i.calisan_id = t.calisan_id and p_gun between i.baslangic and i.bitis
                  and i.iptal_zamani is null              -- iptal edilen izin yok sayılır
                order by i.id limit 1) as izin_turu,
               exists (select 1 from pdks.resmi_tatil r where r.tarih = p_gun and not r.yarim_gun) as tatil
        from tam t
        left join okut o on o.calisan_id = t.calisan_id
    )
    insert into pdks.gun_kaydi (calisan_id, is_gunu, vardiya_id, planli_baslangic, planli_bitis,
                                giris_zamani, cikis_zamani, giris_kaynagi, cikis_kaynagi,
                                durum, hesap_tamam, gece_isi_id)
    select d.calisan_id, p_gun, d.vardiya_id, d.bas, d.bit,
           d.giris, d.cikis,
           case when d.giris is not null then 'pdks' end,
           case when d.cikis is not null then 'pdks' end,
           case when d.izin_turu = 'rapor' then 'raporlu'
                when d.izin_turu is not null then 'izinli'
                when d.tatil then 'tatil'
                when d.giris is not null and d.cikis is not null then 'tamam'
                else 'eksik' end,
           (d.izin_turu is not null or d.tatil),
           p_gece_isi_id
    from durumlu d;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

revoke execute on function pdks.gece_isi_gun_kayitlari(date, bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Amirin izin görünümü iptal edilen izni göstermez (sütunlar aynı)
-- ---------------------------------------------------------------------
create or replace view pdks.v_izin_amir as
select id, calisan_id, baslangic, bitis, 'izinli'::text as tur
from pdks.izin
where (pdks.tum_veriyi_gorur() or pdks.amirin_calisani_mi(calisan_id))
  and iptal_zamani is null;

-- ---------------------------------------------------------------------
-- 5. Departman özeti (yönetici paneli)
-- ---------------------------------------------------------------------
create view pdks.v_departman_ozet
with (security_invoker = true)
as
with gunler as (
    select extract(year from g.is_gunu)::int as yil,
           extract(month from g.is_gunu)::int as ay,
           c.departman_id, g.*
    from pdks.gun_kaydi g
    join pdks.calisan c on c.id = g.calisan_id
)
select g.yil, g.ay, d.id as departman_id, d.ad as departman,
       count(distinct g.calisan_id)                                      as calisan_sayisi,
       count(*) filter (where g.durum = 'tamam')                         as calisilan_gun,
       count(*) filter (where g.durum = 'devamsiz')                      as devamsiz_gun,
       count(*) filter (where g.gec_kalma_dk > 0)                        as gec_kalinan_gun,
       coalesce(sum(g.gec_kalma_dk), 0)                                  as gec_kalma_dk,
       coalesce(sum(g.erken_cikis_dk), 0)                                as erken_cikis_dk,
       coalesce(sum(g.fazla_mesai_dk), 0)                                as fazla_mesai_dk,
       count(*) filter (where g.durum in ('eksik', 'soru_bekliyor', 'devamsiz_suphesi')
                           or not g.hesap_tamam)                         as bekleyen_gun,
       (select count(*) from pdks.amir_sorusu q
        join pdks.gun_kaydi g2 on g2.id = q.gun_kaydi_id
        join pdks.calisan c2 on c2.id = g2.calisan_id
        where c2.departman_id = d.id
          and extract(year from g2.is_gunu) = g.yil and extract(month from g2.is_gunu) = g.ay
          and q.durum in ('acik', 'eskale', 'ik_karari_bekliyor'))       as acik_soru,
       (select count(*) from pdks.itiraz i
        join pdks.gun_kaydi g2 on g2.id = i.gun_kaydi_id
        join pdks.calisan c2 on c2.id = g2.calisan_id
        where c2.departman_id = d.id
          and extract(year from g2.is_gunu) = g.yil and extract(month from g2.is_gunu) = g.ay
          and i.durum in ('acik', 'inceleniyor'))                        as acik_itiraz
from gunler g
join pdks.departman d on d.id = g.departman_id
group by g.yil, g.ay, d.id, d.ad;

comment on view pdks.v_departman_ozet is
    'Ay ve departman başına devam özeti (yönetici paneli). Çağıranın yetkisiyle çalışır.';

grant select on pdks.v_departman_ozet to authenticated;
