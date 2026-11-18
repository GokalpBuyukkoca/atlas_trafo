-- =====================================================================
-- Puantaj: ay kilitlenince bordroya hazır satırlar yazılır
--
--   pdks.ay_kilitle(yıl, ay, zorla)  (İK) artık şunları tek işlemde yapar:
--     1. Ayı kilitler (açık soru/itiraz varsa durur; zorla ile geçilir)
--     2. "normal" satır: ayın her çalışanı için canlı puantajın (v_puantaj_canli) aynısı
--     3. "fark" satırı : önceki kilitli aylara sonradan gelen ve bu aya yönlendirilen
--                        düzeltmelerin etkisi (çalışan + kaynak ay başına)
--   Puantaj satırları silinemez ve değiştirilemez; kilit geri açılamaz.
--
--   Günün dakikalarını hesaplayan kural tek yerde durur: pdks.gun_hesabi().
--   Gece işi de fark hesabı da onu kullanır.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tek hesap kuralı
--    Geç kalma ve erken çıkış toleransı aşınca tam dakikasıyla sayılır.
--    Fazla mesai yalnızca onaylı plan kadar ve geçerli yazılı onay varsa sayılır.
-- ---------------------------------------------------------------------
create function pdks.gun_hesabi(p_calisan_id bigint, p_is_gunu date,
                                p_bas timestamptz, p_bit timestamptz,
                                p_giris timestamptz, p_cikis timestamptz,
                                out gec_kalma_dk integer, out erken_cikis_dk integer,
                                out calisma_dk integer, out fazla_mesai_dk integer)
language plpgsql
stable
set search_path = pdks
as $$
declare
    v_gec    integer := pdks.dakika(p_bas, p_giris);
    v_erken  integer := pdks.dakika(p_cikis, p_bit);
    v_plan   integer;
begin
    select planli_dk into v_plan from pdks.fazla_mesai_plani
    where calisan_id = p_calisan_id and is_gunu = p_is_gunu and durum = 'onaylandi';

    gec_kalma_dk   := case when v_gec   > pdks.ayar_al('gec_kalma_tolerans_dk')   then v_gec   else 0 end;
    erken_cikis_dk := case when v_erken > pdks.ayar_al('erken_cikis_tolerans_dk') then v_erken else 0 end;
    fazla_mesai_dk := case when v_plan is not null and pdks.fm_onay_gecerli_mi(p_calisan_id, p_is_gunu)
                           then least(v_plan, greatest(0, pdks.dakika(p_bit, p_cikis)))
                           else 0 end;
    calisma_dk     := greatest(0, pdks.dakika(greatest(p_giris, p_bas),
                                              least(p_cikis, p_bit + make_interval(mins => fazla_mesai_dk))));
end;
$$;

-- Gece işinin hesap adımı aynı kuralı kullanır (sonuçlar değişmez)
create or replace function pdks.gece_isi_hesapla()
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_n integer;
begin
    with h as (
        select g.id, x.*
        from pdks.gun_kaydi g
        cross join lateral pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                           g.giris_zamani, g.cikis_zamani) x
        where not g.hesap_tamam
          and g.giris_zamani is not null and g.cikis_zamani is not null
          and g.planli_baslangic is not null
          and g.durum in ('eksik', 'tamam', 'soru_bekliyor')
          and not pdks.donem_kilitli_mi(g.is_gunu)
          and not exists (select 1 from pdks.amir_sorusu q
                          where q.gun_kaydi_id = g.id and q.durum in ('acik', 'eskale', 'ik_karari_bekliyor'))
    )
    update pdks.gun_kaydi g
    set gec_kalma_dk   = h.gec_kalma_dk,
        erken_cikis_dk = h.erken_cikis_dk,
        fazla_mesai_dk = h.fazla_mesai_dk,
        calisma_dk     = h.calisma_dk,
        durum          = 'tamam',
        hesap_tamam    = true
    from h
    where g.id = h.id;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Bir günün puantaja katkısı
--    p_duzeltmeler: güne uygulanacak düzeltme numaraları (sırayla). Boş dizi =
--    günün kayıttaki hali. Kilitli günün kaydı değişmediği için "düzeltilmiş hali"
--    bu fonksiyonda hesaplanır, tabloya yazılmaz.
-- ---------------------------------------------------------------------
create function pdks.gun_katkisi(p_gun_kaydi_id bigint, p_duzeltmeler bigint[],
                                 out calisilan_gun numeric, out calisma_dk integer,
                                 out gec_kalma_dk integer, out erken_cikis_dk integer,
                                 out devamsiz_gun numeric, out izinli_gun numeric,
                                 out raporlu_gun numeric, out tatil_gun numeric,
                                 out fazla_mesai_dk integer)
language plpgsql
stable
set search_path = pdks
as $$
declare
    g        pdks.gun_kaydi;
    d        record;
    v_durum_duzeltildi boolean := false;
    v_vt     pdks.vardiya_tanim;
    h        record;
begin
    select * into g from pdks.gun_kaydi where id = p_gun_kaydi_id;

    for d in select * from pdks.duzeltme where id = any (coalesce(p_duzeltmeler, '{}')) order by id loop
        case d.alan
            when 'giris_zamani' then g.giris_zamani := d.yeni_deger::timestamptz;
            when 'cikis_zamani' then g.cikis_zamani := d.yeni_deger::timestamptz;
            when 'durum'        then g.durum := d.yeni_deger; v_durum_duzeltildi := true;
            when 'vardiya_id'   then
                g.vardiya_id := d.yeni_deger::smallint;
                select * into v_vt from pdks.vardiya_tanim where id = g.vardiya_id;
                g.planli_baslangic := (g.is_gunu + v_vt.baslangic) at time zone 'Europe/Istanbul';
                g.planli_bitis := (g.is_gunu + case when v_vt.gece_yarisini_asar then 1 else 0 end + v_vt.bitis)
                                  at time zone 'Europe/Istanbul';
        end case;
    end loop;

    -- Saatleri tamamlanan eksik gün tamamlanmış sayılır (durum açıkça düzeltilmediyse)
    if not v_durum_duzeltildi and coalesce(array_length(p_duzeltmeler, 1), 0) > 0
       and g.durum in ('eksik', 'soru_bekliyor', 'devamsiz_suphesi')
       and g.giris_zamani is not null and g.cikis_zamani is not null then
        g.durum := 'tamam';
    end if;

    calisilan_gun := case when g.durum = 'tamam'    then 1 else 0 end;
    devamsiz_gun  := case when g.durum = 'devamsiz' then 1 else 0 end;
    izinli_gun    := case when g.durum = 'izinli'   then 1 else 0 end;
    raporlu_gun   := case when g.durum = 'raporlu'  then 1 else 0 end;
    tatil_gun     := case when g.durum = 'tatil'    then 1 else 0 end;

    if g.durum = 'tamam' and g.giris_zamani is not null and g.cikis_zamani is not null
       and g.planli_baslangic is not null then
        select * into h from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                              g.giris_zamani, g.cikis_zamani);
        calisma_dk := h.calisma_dk; gec_kalma_dk := h.gec_kalma_dk;
        erken_cikis_dk := h.erken_cikis_dk; fazla_mesai_dk := h.fazla_mesai_dk;
    else
        calisma_dk := 0; gec_kalma_dk := 0; erken_cikis_dk := 0; fazla_mesai_dk := 0;
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Fark satırında fazla mesai eksi olabilir (ör. fazla mesai sonradan geri alındı)
-- ---------------------------------------------------------------------
alter table pdks.puantaj_satiri drop constraint puantaj_satiri_fazla_mesai_dk_check;
alter table pdks.puantaj_satiri add constraint puantaj_satiri_fazla_mesai_dk_check
    check (satir_turu = 'fark' or fazla_mesai_dk >= 0);

-- ---------------------------------------------------------------------
-- 4. Kilitli dönemin puantajını yazar (yalnızca ay_kilitle çağırır)
-- ---------------------------------------------------------------------
create function pdks.puantaj_yaz(p_donem_id bigint)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_donem  pdks.donem;
    v_bas    date;
    v_say    integer := 0;
    v_n      integer;
begin
    select * into v_donem from pdks.donem where id = p_donem_id;
    if v_donem.durum is distinct from 'kilitli' then
        raise exception 'Puantaj yalnızca kilitlenmiş döneme yazılır.';
    end if;
    v_bas := make_date(v_donem.yil, v_donem.ay, 1);

    -- Normal satırlar: kilit anındaki canlı puantajın aynısı
    insert into pdks.puantaj_satiri (donem_id, calisan_id, satir_turu, calisilan_gun, calisma_dk, gec_kalma_dk,
                                     erken_cikis_dk, devamsiz_gun, izinli_gun, raporlu_gun, tatil_gun, fazla_mesai_dk)
    select p_donem_id, v.calisan_id, 'normal', v.calisilan_gun, v.calisma_dk, v.gec_kalma_dk,
           v.erken_cikis_dk, v.devamsiz_gun, v.izinli_gun, v.raporlu_gun, v.tatil_gun, v.fazla_mesai_dk
    from pdks.v_puantaj_canli v
    where v.yil = v_donem.yil and v.ay = v_donem.ay;
    get diagnostics v_n = row_count;
    v_say := v_say + v_n;

    -- Fark satırları: bu döneme yönlendirilmiş düzeltmeler.
    --   önce  = gün + daha önce başka dönemlere yönlendirilmiş fark düzeltmeleri
    --   sonra = önce + bu döneme yönlendirilenler
    with gunler as (
        select d.gun_kaydi_id,
               array_agg(d.id order by d.id) as bu_donem,
               (select coalesce(array_agg(o.id order by o.id), '{}')
                from pdks.duzeltme o
                where o.gun_kaydi_id = d.gun_kaydi_id and o.fark_satiri and o.hedef_donem_id <> p_donem_id
                  and o.id < max(d.id)) as onceki
        from pdks.duzeltme d
        where d.hedef_donem_id = p_donem_id and d.fark_satiri
        group by d.gun_kaydi_id
    ), farklar as (
        select g.calisan_id,
               pdks.donem_bul(date_trunc('month', g.is_gunu)::date) as kaynak_donem_id,
               s.calisilan_gun - o.calisilan_gun   as calisilan_gun,
               s.calisma_dk - o.calisma_dk         as calisma_dk,
               s.gec_kalma_dk - o.gec_kalma_dk     as gec_kalma_dk,
               s.erken_cikis_dk - o.erken_cikis_dk as erken_cikis_dk,
               s.devamsiz_gun - o.devamsiz_gun     as devamsiz_gun,
               s.izinli_gun - o.izinli_gun         as izinli_gun,
               s.raporlu_gun - o.raporlu_gun       as raporlu_gun,
               s.tatil_gun - o.tatil_gun           as tatil_gun,
               s.fazla_mesai_dk - o.fazla_mesai_dk as fazla_mesai_dk
        from gunler x
        join pdks.gun_kaydi g on g.id = x.gun_kaydi_id
        cross join lateral pdks.gun_katkisi(x.gun_kaydi_id, x.onceki) o
        cross join lateral pdks.gun_katkisi(x.gun_kaydi_id, x.onceki || x.bu_donem) s
    )
    insert into pdks.puantaj_satiri (donem_id, calisan_id, satir_turu, kaynak_donem_id, calisilan_gun, calisma_dk,
                                     gec_kalma_dk, erken_cikis_dk, devamsiz_gun, izinli_gun, raporlu_gun,
                                     tatil_gun, fazla_mesai_dk)
    select p_donem_id, calisan_id, 'fark', kaynak_donem_id,
           sum(calisilan_gun), sum(calisma_dk), sum(gec_kalma_dk), sum(erken_cikis_dk), sum(devamsiz_gun),
           sum(izinli_gun), sum(raporlu_gun), sum(tatil_gun), sum(fazla_mesai_dk)
    from farklar
    group by calisan_id, kaynak_donem_id
    -- Etkisi olmayan düzeltme (ör. aynı değer) satır üretmez
    having sum(abs(calisilan_gun)) + sum(abs(calisma_dk)) + sum(abs(gec_kalma_dk)) + sum(abs(erken_cikis_dk))
         + sum(abs(devamsiz_gun)) + sum(abs(izinli_gun)) + sum(abs(raporlu_gun)) + sum(abs(tatil_gun))
         + sum(abs(fazla_mesai_dk)) > 0;
    get diagnostics v_n = row_count;
    v_say := v_say + v_n;

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Ay kilidi: kilitle + puantajı yaz (tek işlem; biri olmazsa hiçbiri olmaz)
-- ---------------------------------------------------------------------
create or replace function pdks.ay_kilitle(p_yil smallint, p_ay smallint, p_zorla boolean default false)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben    bigint := pdks.yetki_gerekli('ik');
    v_donem  bigint := pdks.donem_bul(make_date(p_yil, p_ay, 1));
begin
    perform pdks.donem_kilitle(v_donem, v_ben, p_zorla);
    perform pdks.puantaj_yaz(v_donem);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Yetkiler: yardımcılar kimseye açık değil; ay_kilitle'nin yetkisi değişmez
-- ---------------------------------------------------------------------
revoke execute on function
    pdks.gun_hesabi(bigint, date, timestamptz, timestamptz, timestamptz, timestamptz),
    pdks.gun_katkisi(bigint, bigint[]),
    pdks.puantaj_yaz(bigint),
    pdks.gece_isi_hesapla()
from public, anon, authenticated;
