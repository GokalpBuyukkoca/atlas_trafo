-- =====================================================================
-- Vardiya kuralları
--
--   1. Yeni vardiyalar: 08-16 Gündüz, 16-24 Akşam, 00-08 Gece,
--      08:30-18:00 Beyaz yaka sabit, Esnek. Eski vardiyalar kalır.
--      00-08 vardiyası 00:00'ın takvim gününe yazılır (vardiyanın başladığı gün).
--   2. Esnek mesai (vardiya_tanim.esnek): geç kalma / erken çıkış sayılmaz,
--      çalışma = giriş–çıkış arası; günlük fazla mesai yok. Ay sonunda
--      planlı esnek gün × esnek_gunluk_hedef_dk hedefine göre eksik / fazla.
--   3. Otomatik vardiya tanıma: okutmalar planlı vardiyaya uymuyor ama başka bir
--      vardiyaya uyuyorsa amire vardiya_uyusmazligi sorusu açılır, öneri soruya
--      eklenir. Kayıt amir onaylamadan değişmez.
--   4. Mola (İş Kanunu m.68): 4 saate kadar 15 dk, 4–7,5 saat 30 dk, 7,5 saat
--      üstü 1 saat net çalışmadan düşülür. Süreler ayardan gelir. Gece çalışması
--      dakikasından da molanın gece payı düşülür.
--   Ayrıca: vardiya düzeltmesi (duzeltme_uygula, alan vardiya_id) artık
--   günün planlı başlangıç ve bitişini de yeni vardiyaya göre günceller.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Ayarlar
-- ---------------------------------------------------------------------
insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('mola_kisa_sinir_dk',    240, 'dakika', 'Mola (m.68): bu süreye kadar olan çalışmada kısa mola düşülür (4 saat)'),
    ('mola_kisa_dk',           15, 'dakika', 'Mola (m.68): 4 saate kadar çalışmada düşülen mola'),
    ('mola_orta_sinir_dk',    450, 'dakika', 'Mola (m.68): bu süreye kadar olan çalışmada orta mola düşülür (7,5 saat)'),
    ('mola_orta_dk',           30, 'dakika', 'Mola (m.68): 4–7,5 saat çalışmada düşülen mola'),
    ('mola_uzun_dk',           60, 'dakika', 'Mola (m.68): 7,5 saatten uzun çalışmada düşülen mola'),
    ('esnek_gunluk_hedef_dk', 480, 'dakika', 'Esnek mesai: planlı her esnek gün için net çalışma hedefi (ay hedefi = gün sayısı × bu değer)'),
    ('oto_vardiya_esik_dk',    60, 'dakika', 'Otomatik vardiya tanıma: okutmalar başka bir vardiyanın başına ve sonuna bu kadar yakınsa öneri yapılır')
on conflict (anahtar) do nothing;

-- ---------------------------------------------------------------------
-- 1. Vardiyalar
-- ---------------------------------------------------------------------
alter table pdks.vardiya_tanim add column esnek boolean not null default false;
comment on column pdks.vardiya_tanim.esnek is
    'Esnek mesai: geç kalma / erken çıkış sayılmaz; ay sonunda aylık hedefe göre eksik / fazla hesaplanır.';

insert into pdks.vardiya_tanim (kod, ad, baslangic, bitis, pencere_once_dk, pencere_sonra_dk, esnek) values
    ('GUNDUZ_8', 'Gündüz (08-16)',                '08:00', '16:00', 120, 240, false),
    ('AKSAM_8',  'Akşam (16-24)',                 '16:00', '00:00', 120, 240, false),
    ('GECE_8',   'Gece (00-08)',                  '00:00', '08:00', 120, 240, false),
    ('BEYAZ',    'Beyaz yaka sabit (08:30-18:00)', '08:30', '18:00', 120, 240, false),
    ('ESNEK',    'Esnek mesai',                   '07:00', '19:00', 120, 240, true)
on conflict (kod) do nothing;

-- ---------------------------------------------------------------------
-- 2. Yeni alanlar
-- ---------------------------------------------------------------------
alter table pdks.gun_kaydi add column mola_dk integer check (mola_dk >= 0);
comment on column pdks.gun_kaydi.mola_dk is 'Çalışmadan düşülen yasal ara dinlenme (m.68), dakika.';

alter table pdks.puantaj_satiri
    add column mola_dk        integer not null default 0,
    add column esnek_hedef_dk integer not null default 0,
    add column esnek_fark_dk  integer not null default 0;
comment on column pdks.puantaj_satiri.esnek_fark_dk is
    'Esnek mesaide gerçekleşen − hedef (dakika). Eksi: hedefin altında. Fazlası kendiliğinden fazla mesai sayılmaz.';

alter table pdks.amir_sorusu
    add column onerilen_vardiya_id smallint references pdks.vardiya_tanim (id),
    add column onerilen_cikis      timestamptz;
comment on column pdks.amir_sorusu.onerilen_vardiya_id is
    'vardiya_uyusmazligi sorusunda okutmalara en uygun vardiya (öneri; amir onaylamadan uygulanmaz).';

-- ---------------------------------------------------------------------
-- 3. Yardımcılar
-- ---------------------------------------------------------------------

-- Brüt çalışmaya göre yasal mola
create function pdks.mola_suresi(p_brut_dk integer)
returns integer
language sql
stable
set search_path = pdks
as $$
    select case when coalesce(p_brut_dk, 0) <= 0 then 0
                when p_brut_dk <= pdks.ayar_al('mola_kisa_sinir_dk') then pdks.ayar_al('mola_kisa_dk')
                when p_brut_dk <= pdks.ayar_al('mola_orta_sinir_dk') then pdks.ayar_al('mola_orta_dk')
                else pdks.ayar_al('mola_uzun_dk') end;
$$;

-- Bir vardiyanın verilen iş günündeki başlangıç ve bitişi
create function pdks.vardiya_araligi(p_vardiya_id smallint, p_is_gunu date,
                                     out p_bas timestamptz, out p_bit timestamptz)
language sql
stable
set search_path = pdks
as $$
    select (p_is_gunu + baslangic) at time zone 'Europe/Istanbul',
           (p_is_gunu + case when gece_yarisini_asar then 1 else 0 end + bitis) at time zone 'Europe/Istanbul'
    from pdks.vardiya_tanim where id = p_vardiya_id;
$$;

-- Okutmalar planlı vardiyaya uymuyorsa en uygun başka vardiya.
-- Giriş vardiya başına, çıkış vardiya sonuna oto_vardiya_esik_dk içinde olmalı.
-- Arama aralığının PDKS dosyaları gelmediyse öneri yapılmaz.
create function pdks.vardiya_onerisi(p_gun_kaydi_id bigint,
                                     out vardiya_id smallint, out giris timestamptz, out cikis timestamptz)
language sql
stable
set search_path = pdks
as $$
    with g as (
        select gk.*, ((gk.is_gunu::timestamp - interval '6 hours') at time zone 'Europe/Istanbul') as ara_bas,
                     (((gk.is_gunu + 1)::timestamp + interval '12 hours') at time zone 'Europe/Istanbul') as ara_bit
        from pdks.gun_kaydi gk
        join pdks.vardiya_tanim pt on pt.id = gk.vardiya_id and not pt.esnek
        where gk.id = p_gun_kaydi_id
    ), okut as (
        select h.okutma_zamani as z, h.yon
        from g join pdks.ham_okutma h on h.okutma_zamani between g.ara_bas and g.ara_bit
        where pdks.okutma_sahibi(h.kart_no, h.okutma_zamani) = g.calisan_id
          and not pdks.okutma_gecersiz_mi(h.id)
    ), adaylar as (
        select t.id, a.p_bas, a.p_bit,
               (select o.z from okut o where o.yon is distinct from 'cikis'
                  and abs(extract(epoch from o.z - a.p_bas)) <= pdks.ayar_al('oto_vardiya_esik_dk') * 60
                order by abs(extract(epoch from o.z - a.p_bas)) limit 1) as giris,
               (select o.z from okut o where o.yon is distinct from 'giris'
                  and abs(extract(epoch from o.z - a.p_bit)) <= pdks.ayar_al('oto_vardiya_esik_dk') * 60
                order by abs(extract(epoch from o.z - a.p_bit)) limit 1) as cikis
        from g
        join pdks.vardiya_tanim t on t.aktif and not t.esnek and t.id <> g.vardiya_id
        cross join lateral pdks.vardiya_araligi(t.id, g.is_gunu) a
        where pdks.pdks_verisi_tam_mi(g.ara_bas, g.ara_bit)
    )
    select id, giris, cikis
    from adaylar
    where giris is not null and cikis is not null and cikis > giris
    order by abs(extract(epoch from giris - p_bas)) + abs(extract(epoch from cikis - p_bit)), id
    limit 1;
$$;

-- ---------------------------------------------------------------------
-- 4. Vardiya düzeltmesi planlı saatleri de günceller (önceden eski vardiyada kalıyordu)
-- ---------------------------------------------------------------------
create or replace function pdks.duzeltme_uygula(
    p_gun_kaydi_id   bigint,
    p_alan           text,
    p_yeni_deger     text,
    p_gerekce        text,
    p_kaynak         text,
    p_yapan_id       bigint  default null,
    p_kanit_kaydi_id bigint  default null,
    p_izin_id        bigint  default null,
    p_ariza_id       bigint  default null,
    p_soru_id        bigint  default null,
    p_itiraz_id      bigint  default null,
    p_aleyhine       boolean default false
)
returns bigint
language plpgsql
set search_path = pdks
as $$
declare
    v_gun   pdks.gun_kaydi;
    v_eski  text;
    v_id    bigint;
    v_fark  boolean;
    v_kayn  text := case when p_kaynak = 'gece_isi' then 'kanit' else p_kaynak end;
    v_ara   record;
begin
    select * into v_gun from pdks.gun_kaydi where id = p_gun_kaydi_id for update;
    if not found then
        raise exception 'Günlük kayıt bulunamadı: %', p_gun_kaydi_id;
    end if;

    v_eski := case p_alan
                when 'giris_zamani' then v_gun.giris_zamani::text
                when 'cikis_zamani' then v_gun.cikis_zamani::text
                when 'vardiya_id'   then v_gun.vardiya_id::text
                when 'durum'        then v_gun.durum
              end;

    p_yeni_deger := case p_alan
                when 'giris_zamani' then p_yeni_deger::timestamptz::text
                when 'cikis_zamani' then p_yeni_deger::timestamptz::text
                when 'vardiya_id'   then p_yeni_deger::smallint::text
                else p_yeni_deger
              end;

    insert into pdks.duzeltme (gun_kaydi_id, calisan_id, is_gunu, alan, eski_deger, yeni_deger,
                               gerekce, kaynak, yapan_id, calisan_aleyhine,
                               kanit_kaydi_id, izin_id, ariza_id, soru_id, itiraz_id, hedef_donem_id)
    values (p_gun_kaydi_id, v_gun.calisan_id, v_gun.is_gunu, p_alan, v_eski, p_yeni_deger,
            p_gerekce, p_kaynak, p_yapan_id, p_aleyhine,
            p_kanit_kaydi_id, p_izin_id, p_ariza_id, p_soru_id, p_itiraz_id, 0)
    returning id, fark_satiri into v_id, v_fark;

    if v_fark then
        return v_id;
    end if;

    perform set_config('pdks.duzeltme_id', v_id::text, true);
    case p_alan
        when 'giris_zamani' then
            update pdks.gun_kaydi set giris_zamani = p_yeni_deger::timestamptz, giris_kaynagi = v_kayn,
                                      hesap_tamam = false where id = p_gun_kaydi_id;
        when 'cikis_zamani' then
            update pdks.gun_kaydi set cikis_zamani = p_yeni_deger::timestamptz, cikis_kaynagi = v_kayn,
                                      hesap_tamam = false where id = p_gun_kaydi_id;
        when 'vardiya_id' then
            select * into v_ara from pdks.vardiya_araligi(p_yeni_deger::smallint, v_gun.is_gunu);
            update pdks.gun_kaydi set vardiya_id = p_yeni_deger::smallint,
                                      planli_baslangic = v_ara.p_bas, planli_bitis = v_ara.p_bit,
                                      hesap_tamam = false
            where id = p_gun_kaydi_id;
        when 'durum' then
            update pdks.gun_kaydi set durum = p_yeni_deger, hesap_tamam = false where id = p_gun_kaydi_id;
    end case;
    perform set_config('pdks.duzeltme_id', '', true);
    return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Tek hesap kuralı: esnek mesai ve mola eklendi
--    Esnek  : geç / erken yok; vardiya içi = giriş–çıkış; vardiya sonrası yok
--    Mola   : brüt çalışmadan düşülür (önce vardiya içi kısımdan); FM100 gününde FM100'den.
--             Gece çalışmasından molanın gece payı (gece / brüt oranında) düşülür.
--    p_vardiya_id verilmezse günün kayıttaki vardiyası kullanılır.
-- ---------------------------------------------------------------------
drop function pdks.gun_hesabi(bigint, date, timestamptz, timestamptz, timestamptz, timestamptz);

create function pdks.gun_hesabi(p_calisan_id bigint, p_is_gunu date,
                                p_bas timestamptz, p_bit timestamptz,
                                p_giris timestamptz, p_cikis timestamptz,
                                p_vardiya_id smallint default null,
                                out gec_kalma_dk integer, out erken_cikis_dk integer,
                                out calisma_dk integer, out fazla_mesai_dk integer,
                                out fm50_dk integer, out fm100_dk integer,
                                out gece_calisma_dk integer, out saatlik_izin_dk integer,
                                out onaysiz_fm_dk integer, out mola_dk integer)
language plpgsql
stable
set search_path = pdks
as $$
declare
    v_izin   tstzmultirange := pdks.saatlik_izin_araligi(p_calisan_id, p_is_gunu);
    v_yuv    integer := pdks.ayar_al('tolerans_yuvarlama_dk');
    v_onay   boolean := pdks.fm_onay_gecerli_mi(p_calisan_id, p_is_gunu);
    v_tatil  boolean := pdks.fm100_gunu_mu(p_is_gunu);
    v_esnek  boolean;
    v_plan   integer;
    v_havuz  integer;
    v_bas_is timestamptz;
    v_ici    integer;
    v_sonra  integer;
    v_ek     integer;
    v_brut   integer;
    v_gece   integer;
begin
    gec_kalma_dk := 0; erken_cikis_dk := 0; calisma_dk := 0; fazla_mesai_dk := 0;
    fm50_dk := 0; fm100_dk := 0; gece_calisma_dk := 0; saatlik_izin_dk := 0; onaysiz_fm_dk := 0; mola_dk := 0;
    if p_giris is null or p_cikis is null or p_bas is null or p_bit is null then
        return;
    end if;

    select t.esnek into v_esnek from pdks.vardiya_tanim t
    where t.id = coalesce(p_vardiya_id, (select g.vardiya_id from pdks.gun_kaydi g
                                         where g.calisan_id = p_calisan_id and g.is_gunu = p_is_gunu));
    if coalesce(v_esnek, false) then
        -- Esnek mesaide vardiya, çalışanın kendi giriş–çıkışıdır
        p_bas := p_giris;
        p_bit := p_cikis;
    end if;

    select planli_dk into v_plan from pdks.fazla_mesai_plani
    where calisan_id = p_calisan_id and is_gunu = p_is_gunu and durum = 'onaylandi';
    v_plan := case when v_onay then coalesce(v_plan, 0) else 0 end;

    select coalesce(sum(dakika), 0) into v_havuz from pdks.fazla_mesai_inceleme
    where calisan_id = p_calisan_id and is_gunu = p_is_gunu and durum = 'onaylandi';

    gec_kalma_dk   := pdks.tolerans_uygula(pdks.dakika_toplami(pdks.aralik(p_bas, p_giris) - v_izin),
                                           pdks.ayar_al('gec_kalma_tolerans_dk'), v_yuv);
    erken_cikis_dk := pdks.tolerans_uygula(pdks.dakika_toplami(pdks.aralik(p_cikis, p_bit) - v_izin),
                                           pdks.ayar_al('erken_cikis_tolerans_dk'), v_yuv);
    saatlik_izin_dk := pdks.dakika_toplami(pdks.aralik(p_bas, p_bit) * v_izin);

    v_bas_is := greatest(p_giris, p_bas);
    v_ici    := pdks.dakika_toplami(pdks.aralik(v_bas_is, least(p_cikis, p_bit)) - v_izin);
    v_sonra  := greatest(0, pdks.dakika(p_bit, p_cikis));

    if not v_tatil then
        v_ek := least(v_sonra, v_plan + v_havuz);
        fm50_dk := v_ek;
        v_brut := v_ici + v_ek;
        onaysiz_fm_dk := greatest(0, v_sonra - v_plan - v_havuz);
    elsif v_onay then
        v_ek := least(v_sonra, v_plan + v_havuz);
        fm100_dk := v_ici + v_ek;
        v_brut := fm100_dk;
        onaysiz_fm_dk := greatest(0, v_sonra - v_plan - v_havuz);
    else
        fm100_dk := least(v_ici + v_sonra, v_havuz);
        v_brut := fm100_dk;
        v_ek := greatest(0, fm100_dk - v_ici);
        onaysiz_fm_dk := greatest(0, v_ici + v_sonra - v_havuz);
    end if;

    -- Brüt çalışmanın gece dilimine düşen kısmı
    v_gece := least(v_brut,
        pdks.dakika_toplami((pdks.aralik(v_bas_is, least(p_cikis, p_bit + make_interval(mins => coalesce(v_ek, 0))))
                             - v_izin) * pdks.gece_araligi(p_is_gunu)));

    -- Mola (m.68)
    mola_dk := pdks.mola_suresi(v_brut);
    calisma_dk := v_brut - mola_dk;
    if v_tatil then
        fm100_dk := greatest(0, fm100_dk - mola_dk);
    elsif v_ici < mola_dk then
        fm50_dk := greatest(0, fm50_dk - (mola_dk - v_ici));
    end if;
    fazla_mesai_dk := fm50_dk + fm100_dk;
    gece_calisma_dk := case when v_brut > 0 then greatest(0, v_gece - round(mola_dk::numeric * v_gece / v_brut)::integer)
                            else 0 end;
end;
$$;

-- Hesabı yapılmış bir günün dakikalarını yeniden yazar (mola alanı eklendi)
create or replace function pdks.gun_hesabini_yenile(p_gun_kaydi_id bigint)
returns void
language plpgsql
set search_path = pdks
as $$
begin
    update pdks.gun_kaydi g
    set (gec_kalma_dk, erken_cikis_dk, calisma_dk, fazla_mesai_dk, fm50_dk, fm100_dk,
         gece_calisma_dk, saatlik_izin_dk, mola_dk) =
        (select h.gec_kalma_dk, h.erken_cikis_dk, h.calisma_dk, h.fazla_mesai_dk, h.fm50_dk, h.fm100_dk,
                h.gece_calisma_dk, h.saatlik_izin_dk, h.mola_dk
         from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                              g.giris_zamani, g.cikis_zamani, g.vardiya_id) h)
    where g.id = p_gun_kaydi_id and g.hesap_tamam and g.durum = 'tamam'
      and not pdks.donem_kilitli_mi(g.is_gunu);
end;
$$;

-- Hesap adımı (mola alanı eklendi)
create or replace function pdks.gece_isi_hesapla()
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_idler bigint[];
    v_id    bigint;
begin
    with h as (
        select g.id, x.*
        from pdks.gun_kaydi g
        cross join lateral pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                           g.giris_zamani, g.cikis_zamani, g.vardiya_id) x
        where not g.hesap_tamam
          and g.giris_zamani is not null and g.cikis_zamani is not null
          and g.planli_baslangic is not null
          and g.durum in ('eksik', 'tamam', 'soru_bekliyor')
          and not pdks.donem_kilitli_mi(g.is_gunu)
          and not exists (select 1 from pdks.amir_sorusu q
                          where q.gun_kaydi_id = g.id and q.durum in ('acik', 'eskale', 'ik_karari_bekliyor'))
    ), u as (
        update pdks.gun_kaydi g
        set gec_kalma_dk    = h.gec_kalma_dk,
            erken_cikis_dk  = h.erken_cikis_dk,
            fazla_mesai_dk  = h.fazla_mesai_dk,
            fm50_dk         = h.fm50_dk,
            fm100_dk        = h.fm100_dk,
            calisma_dk      = h.calisma_dk,
            gece_calisma_dk = h.gece_calisma_dk,
            saatlik_izin_dk = h.saatlik_izin_dk,
            mola_dk         = h.mola_dk,
            durum           = 'tamam',
            hesap_tamam     = true
        from h
        where g.id = h.id
        returning g.id
    )
    select coalesce(array_agg(id order by id), '{}') into v_idler from u;

    foreach v_id in array v_idler loop
        perform pdks.gun_sonrasi_kontroller(v_id);
    end loop;
    return coalesce(array_length(v_idler, 1), 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Gece işi: amire soru adımı. Okutmalar başka bir vardiyaya uyuyorsa
--    önce vardiya_uyusmazligi sorusu (öneriyle) açılır; diğer sorular sorulmaz.
-- ---------------------------------------------------------------------
create or replace function pdks.gece_isi_sorular(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_yurume  interval := make_interval(mins => pdks.ayar_al('yurume_payi_dk'));
    v_son     date     := p_gun + 1 + pdks.ayar_al('soru_eskalasyon_gun');
    v_say     integer  := 0;
    v_n       integer;
    v_gun     text     := to_char(p_gun, 'DD.MM.YYYY');
    g         record;
    k         record;
    o         record;
    v_kanit   boolean;
begin
    for g in
        select gk.*, w.p_bas, w.p_bit
        from pdks.gun_kaydi gk
        cross join lateral pdks.gun_penceresi(gk.id) w
        where gk.is_gunu = p_gun and gk.durum = 'eksik' and not pdks.donem_kilitli_mi(p_gun)
          and pdks.pdks_verisi_tam_mi(w.p_bas, w.p_bit)
        order by gk.id
    loop
        -- Otomatik vardiya tanıma
        select * into o from pdks.vardiya_onerisi(g.id);
        if o.vardiya_id is not null then
            insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, onerilen_zaman, onerilen_cikis,
                                          onerilen_vardiya_id, atanan_id, son_cevap_tarihi)
            values (g.id, 'vardiya_uyusmazligi',
                    format('%s: okutmalar planlı vardiyaya (%s) uymuyor; %s vardiyasına uyuyor (giriş %s, çıkış %s). Onaylarsanız vardiya ve saatler düzeltilir.',
                           v_gun, (select ad from pdks.vardiya_tanim where id = g.vardiya_id),
                           (select ad from pdks.vardiya_tanim where id = o.vardiya_id),
                           to_char(o.giris at time zone 'Europe/Istanbul', 'DD.MM HH24:MI'),
                           to_char(o.cikis at time zone 'Europe/Istanbul', 'DD.MM HH24:MI')),
                    o.giris, o.cikis, o.vardiya_id, pdks.soru_atanacak(g.calisan_id), v_son)
            on conflict do nothing;
            get diagnostics v_n = row_count;
            v_say := v_say + v_n;
            update pdks.gun_kaydi set durum = 'soru_bekliyor' where id = g.id;
            continue;
        end if;

        if g.giris_zamani is null and g.cikis_zamani is null then
            select exists (select 1 from pdks.kanit_kaydi kk
                           where kk.okutma_zamani between g.p_bas and g.p_bit
                             and pdks.okutma_sahibi(kk.kart_no, kk.okutma_zamani) = g.calisan_id)
              into v_kanit;
            if not v_kanit then
                insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
                values (g.id, 'hic_kayit_yok',
                        format('%s: vardiya planı var; izin ve hiçbir okutma (PDKS, kapı, servis, yemekhane) yok.', v_gun),
                        pdks.soru_atanacak(g.calisan_id), v_son)
                on conflict do nothing;
                get diagnostics v_n = row_count;
                v_say := v_say + v_n;
                update pdks.gun_kaydi set durum = 'soru_bekliyor' where id = g.id;
                continue;
            end if;
        end if;

        if g.giris_zamani is null then
            select * into k from pdks.gun_kaniti(g.id, 'giris');
            if k.p_kanit_id is not null then
                insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, onerilen_zaman, kanit_kaydi_id,
                                              atanan_id, son_cevap_tarihi)
                values (g.id, 'kanit_vardiya_sonrasi',
                        format('%s: PDKS girişi yok; %s kaydı %s (vardiya başından sonra). Giriş saatini onaylayın.',
                               v_gun, case k.p_kaynak when 'kapi' then 'kapı' else 'servis' end, to_char(k.p_zaman at time zone 'Europe/Istanbul', 'HH24:MI')),
                        k.p_zaman + v_yurume, k.p_kanit_id, pdks.soru_atanacak(g.calisan_id), v_son)
                on conflict do nothing;
            else
                insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
                values (g.id, 'giris_yok', format('%s: giriş okutması yok, kapı ya da servis kaydı da yok.', v_gun),
                        pdks.soru_atanacak(g.calisan_id), v_son)
                on conflict do nothing;
            end if;
            get diagnostics v_n = row_count;
            v_say := v_say + v_n;
        end if;

        if g.cikis_zamani is null then
            insert into pdks.amir_sorusu (gun_kaydi_id, soru_turu, aciklama, atanan_id, son_cevap_tarihi)
            values (g.id, 'cikis_yok', format('%s: çıkış okutması yok, kapı ya da servis kaydı da yok.', v_gun),
                    pdks.soru_atanacak(g.calisan_id), v_son)
            on conflict do nothing;
            get diagnostics v_n = row_count;
            v_say := v_say + v_n;
        end if;

        update pdks.gun_kaydi set durum = 'soru_bekliyor' where id = g.id;
    end loop;
    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Gece işi uyarıları: esnek mesaide vardiya sonu yoktur, plansız fazla mesai uyarısı çıkmaz
-- ---------------------------------------------------------------------
create or replace function pdks.gece_isi_uyarilar(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_esik    integer := pdks.ayar_al('fm_plansiz_esik_dk');
    v_gunluk  integer := pdks.ayar_al('gunluk_azami_calisma_dk');
    v_say     integer := 0;
    r         record;
begin
    for r in
        select g.id, g.calisan_id, g.giris_zamani, g.cikis_zamani, g.planli_baslangic, t.esnek,
               pdks.dakika(g.planli_bitis, g.cikis_zamani) as fazla,
               coalesce(p.planli_dk, 0) as plan,
               pdks.fm_onay_gecerli_mi(g.calisan_id, g.is_gunu) as onay
        from pdks.gun_kaydi g
        join pdks.vardiya_tanim t on t.id = g.vardiya_id
        left join pdks.fazla_mesai_plani p
          on p.calisan_id = g.calisan_id and p.is_gunu = g.is_gunu and p.durum = 'onaylandi'
        where g.is_gunu = p_gun and g.cikis_zamani is not null and g.planli_bitis is not null
    loop
        if not r.esnek and r.fazla - r.plan > v_esik then
            if r.plan = 0 and not r.onay then
                v_say := v_say + pdks.uyari_yaz('fm_onay_yok', 'fm:' || r.id,
                    format('%s: vardiya sonrası %s dk kaldı; yazılı fazla mesai onayı yok. Karar İK''da.',
                           to_char(p_gun, 'DD.MM.YYYY'), r.fazla), r.calisan_id);
            else
                v_say := v_say + pdks.uyari_yaz('fm_plansiz_calisma', 'fm:' || r.id,
                    format('%s: vardiya sonrası %s dk kaldı; onaylı plan %s dk. Fazlası puantaja yazılmadı, karar İK''da.',
                           to_char(p_gun, 'DD.MM.YYYY'), r.fazla, r.plan), r.calisan_id);
            end if;
        end if;

        if r.giris_zamani is not null
           and pdks.dakika(case when r.esnek then r.giris_zamani else greatest(r.giris_zamani, r.planli_baslangic) end,
                           r.cikis_zamani) > v_gunluk + v_esik then
            v_say := v_say + pdks.uyari_yaz('fm_gunluk_sinir_asildi', 'gunluk:' || r.id,
                format('%s: günlük çalışma %s dk; sınır %s dk (11 saat).', to_char(p_gun, 'DD.MM.YYYY'),
                       pdks.dakika(case when r.esnek then r.giris_zamani else greatest(r.giris_zamani, r.planli_baslangic) end,
                                   r.cikis_zamani), v_gunluk),
                r.calisan_id);
        end if;
    end loop;

    for r in
        select k from unnest(array['pdks', 'kapi', 'yemekhane', 'servis']) k
        where not exists (select 1 from pdks.aktarim a where a.kaynak = k and a.veri_tarihi = p_gun)
    loop
        v_say := v_say + pdks.uyari_yaz('dosya_gelmedi', r.k || ':' || p_gun,
            format('%s günü için %s dosyası yüklenmedi.', to_char(p_gun, 'DD.MM.YYYY'), r.k));
    end loop;

    v_say := v_say + coalesce(pdks.gecici_kart_kontrol(p_gun), 0);
    v_say := v_say + coalesce(pdks.kart_paylasim_kontrol(p_gun), 0);

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Amir cevabı: vardiya önerisini onaylamak (geldi_saat_dogru, saat girmeden)
--    vardiyayı ve saatleri öneriye göre düzeltir. Diğer cevaplar değişmedi.
-- ---------------------------------------------------------------------
create or replace function pdks.soru_cevapla(p_soru_id bigint, p_cevap text,
                                             p_giris timestamptz default null, p_cikis timestamptz default null,
                                             p_aciklama text default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben     bigint := pdks.yetki_gerekli('amir');
    v_soru    pdks.amir_sorusu;
    v_gun     pdks.gun_kaydi;
    v_giris   timestamptz;
    v_cikis   timestamptz;
    v_vardiya smallint;
begin
    select * into v_soru from pdks.amir_sorusu where id = p_soru_id for update;
    if not found or v_ben not in (v_soru.atanan_id, coalesce(v_soru.eskale_edilen_id, 0)) then
        raise exception 'Soru bulunamadı ya da size atanmamış.';
    end if;
    if v_soru.durum not in ('acik', 'eskale') then
        raise exception 'Bu soru zaten cevaplanmış.';
    end if;
    if p_cevap not in ('geldi_saat_dogru', 'geldi_saat_farkli', 'kart_unuttu', 'gelmedi', 'bilmiyorum') then
        raise exception 'Geçersiz cevap: %', p_cevap;
    end if;
    select * into v_gun from pdks.gun_kaydi where id = v_soru.gun_kaydi_id;

    if p_cevap = 'geldi_saat_farkli' and p_giris is null and p_cikis is null then
        raise exception 'Saat farklıysa giriş ya da çıkış saatini girin.';
    end if;

    if p_cevap in ('geldi_saat_dogru', 'kart_unuttu') and p_giris is null and p_cikis is null then
        if v_soru.soru_turu = 'vardiya_uyusmazligi' then
            if v_soru.onerilen_vardiya_id is null then
                raise exception 'Bu soru türünde saatleri girin.';
            end if;
            v_vardiya := v_soru.onerilen_vardiya_id;
            v_giris := v_soru.onerilen_zaman;
            v_cikis := v_soru.onerilen_cikis;
        end if;
        if v_soru.soru_turu in ('giris_yok', 'kanit_vardiya_sonrasi', 'ariza_kaniti_yok', 'hic_kayit_yok') then
            v_giris := coalesce(v_soru.onerilen_zaman, v_gun.planli_baslangic);
        end if;
        if v_soru.soru_turu = 'cikis_yok' then
            v_cikis := coalesce(v_soru.onerilen_zaman, v_gun.planli_bitis);
        end if;
        if v_soru.soru_turu = 'hic_kayit_yok' then
            v_cikis := v_gun.planli_bitis;
        end if;
    else
        v_giris := p_giris;
        v_cikis := p_cikis;
    end if;

    update pdks.amir_sorusu
    set cevap = p_cevap, cevap_giris = v_giris, cevap_cikis = v_cikis, cevap_aciklama = p_aciklama,
        cevaplayan_id = v_ben,
        durum = case when p_cevap in ('gelmedi', 'bilmiyorum') then 'ik_karari_bekliyor' else 'cevaplandi' end
    where id = p_soru_id;

    if p_cevap not in ('gelmedi', 'bilmiyorum') then
        if v_vardiya is not null then
            perform pdks.duzeltme_uygula(v_soru.gun_kaydi_id, 'vardiya_id', v_vardiya::text,
                'Amir cevabı: vardiya önerisi onaylandı' || coalesce(' (' || p_aciklama || ')', ''),
                'amir', v_ben, p_soru_id => p_soru_id);
        end if;
        perform pdks.saat_yaz(v_soru.gun_kaydi_id, v_giris, v_cikis,
                              'Amir cevabı: ' || p_cevap || coalesce(' (' || p_aciklama || ')', ''),
                              'amir', v_ben, p_soru_id => p_soru_id);
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Canlı puantaj ve esnek mesai görünümü
-- ---------------------------------------------------------------------
create or replace view pdks.v_puantaj_canli as
with g as (
    select g.*, coalesce(t.esnek, false) as esnek,
           coalesce(t.esnek, false) and g.durum not in ('izinli', 'raporlu', 'tatil', 'vardiya_yok') as esnek_hedefli
    from pdks.gun_kaydi g
    left join pdks.vardiya_tanim t on t.id = g.vardiya_id
)
select extract(year from g.is_gunu)::int  as yil,
       extract(month from g.is_gunu)::int as ay,
       g.calisan_id,
       count(*) filter (where g.durum = 'tamam')                 as calisilan_gun,
       coalesce(sum(g.calisma_dk), 0)                             as calisma_dk,
       coalesce(sum(g.gec_kalma_dk), 0)                           as gec_kalma_dk,
       coalesce(sum(g.erken_cikis_dk), 0)                         as erken_cikis_dk,
       count(*) filter (where g.durum = 'devamsiz')              as devamsiz_gun,
       count(*) filter (where g.durum = 'izinli')                as izinli_gun,
       count(*) filter (where g.durum = 'raporlu')               as raporlu_gun,
       count(*) filter (where g.durum = 'tatil')                 as tatil_gun,
       count(*) filter (where g.durum in ('eksik', 'soru_bekliyor', 'devamsiz_suphesi')
                           or not g.hesap_tamam)                  as bekleyen_gun,
       coalesce(sum(g.fazla_mesai_dk), 0)                         as fazla_mesai_dk,
       coalesce(sum(g.fm50_dk), 0)                                as fm50_dk,
       coalesce(sum(g.fm100_dk), 0)                               as fm100_dk,
       coalesce(sum(g.gece_calisma_dk), 0)                        as gece_calisma_dk,
       coalesce(sum(g.saatlik_izin_dk), 0)                        as saatlik_izin_dk,
       coalesce(sum(g.mola_dk), 0)                                as mola_dk,
       (count(*) filter (where g.esnek_hedefli) * pdks.ayar_al('esnek_gunluk_hedef_dk'))::int as esnek_hedef_dk,
       (coalesce(sum(g.calisma_dk) filter (where g.esnek and g.durum = 'tamam'), 0)
        - count(*) filter (where g.esnek_hedefli) * pdks.ayar_al('esnek_gunluk_hedef_dk'))::int as esnek_fark_dk
from g
group by 1, 2, 3;
alter view pdks.v_puantaj_canli set (security_invoker = true);

-- Esnek mesaili çalışanların aylık hedef durumu (İK ekranı)
create view pdks.v_esnek_mesai
with (security_invoker = true)
as
select extract(year from g.is_gunu)::int  as yil,
       extract(month from g.is_gunu)::int as ay,
       g.calisan_id,
       count(*) filter (where g.durum not in ('izinli', 'raporlu', 'tatil', 'vardiya_yok'))    as hedef_gun,
       (count(*) filter (where g.durum not in ('izinli', 'raporlu', 'tatil', 'vardiya_yok'))
        * pdks.ayar_al('esnek_gunluk_hedef_dk'))::int                                          as hedef_dk,
       coalesce(sum(g.calisma_dk) filter (where g.durum = 'tamam'), 0)::int                     as gerceklesen_dk,
       (coalesce(sum(g.calisma_dk) filter (where g.durum = 'tamam'), 0)
        - count(*) filter (where g.durum not in ('izinli', 'raporlu', 'tatil', 'vardiya_yok'))
          * pdks.ayar_al('esnek_gunluk_hedef_dk'))::int                                        as fark_dk,
       count(*) filter (where g.durum in ('eksik', 'soru_bekliyor', 'devamsiz_suphesi')
                           or (g.durum = 'tamam' and not g.hesap_tamam))                       as bekleyen_gun
from pdks.gun_kaydi g
join pdks.vardiya_tanim t on t.id = g.vardiya_id and t.esnek
group by 1, 2, 3;

comment on view pdks.v_esnek_mesai is
    'Esnek mesai: ay başına hedef (planlı esnek gün × esnek_gunluk_hedef_dk), gerçekleşen ve fark (dakika).';
grant select on pdks.v_esnek_mesai to authenticated;

-- ---------------------------------------------------------------------
-- 10. Günün puantaja katkısı (mola ve esnek alanları eklendi)
-- ---------------------------------------------------------------------
drop function pdks.gun_katkisi(bigint, bigint[]);

create function pdks.gun_katkisi(p_gun_kaydi_id bigint, p_duzeltmeler bigint[],
                                 out calisilan_gun numeric, out calisma_dk integer,
                                 out gec_kalma_dk integer, out erken_cikis_dk integer,
                                 out devamsiz_gun numeric, out izinli_gun numeric,
                                 out raporlu_gun numeric, out tatil_gun numeric,
                                 out fazla_mesai_dk integer, out fm50_dk integer, out fm100_dk integer,
                                 out gece_calisma_dk integer, out saatlik_izin_dk integer,
                                 out durum text, out mola_dk integer,
                                 out esnek_hedef_dk integer, out esnek_fark_dk integer)
language plpgsql
stable
set search_path = pdks
as $$
declare
    g        pdks.gun_kaydi;
    d        record;
    v_durum_duzeltildi boolean := false;
    v_ara    record;
    v_esnek  boolean;
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
                select * into v_ara from pdks.vardiya_araligi(g.vardiya_id, g.is_gunu);
                g.planli_baslangic := v_ara.p_bas;
                g.planli_bitis := v_ara.p_bit;
        end case;
    end loop;

    if not v_durum_duzeltildi and coalesce(array_length(p_duzeltmeler, 1), 0) > 0
       and g.durum in ('eksik', 'soru_bekliyor', 'devamsiz_suphesi')
       and g.giris_zamani is not null and g.cikis_zamani is not null then
        g.durum := 'tamam';
    end if;

    durum         := g.durum;
    calisilan_gun := case when g.durum = 'tamam'    then 1 else 0 end;
    devamsiz_gun  := case when g.durum = 'devamsiz' then 1 else 0 end;
    izinli_gun    := case when g.durum = 'izinli'   then 1 else 0 end;
    raporlu_gun   := case when g.durum = 'raporlu'  then 1 else 0 end;
    tatil_gun     := case when g.durum = 'tatil'    then 1 else 0 end;

    if g.durum = 'tamam' and g.giris_zamani is not null and g.cikis_zamani is not null
       and g.planli_baslangic is not null then
        select * into h from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                              g.giris_zamani, g.cikis_zamani, g.vardiya_id);
        calisma_dk := h.calisma_dk; gec_kalma_dk := h.gec_kalma_dk;
        erken_cikis_dk := h.erken_cikis_dk; fazla_mesai_dk := h.fazla_mesai_dk;
        fm50_dk := h.fm50_dk; fm100_dk := h.fm100_dk;
        gece_calisma_dk := h.gece_calisma_dk; saatlik_izin_dk := h.saatlik_izin_dk; mola_dk := h.mola_dk;
    else
        calisma_dk := 0; gec_kalma_dk := 0; erken_cikis_dk := 0; fazla_mesai_dk := 0;
        fm50_dk := 0; fm100_dk := 0; gece_calisma_dk := 0; saatlik_izin_dk := 0; mola_dk := 0;
    end if;

    select t.esnek into v_esnek from pdks.vardiya_tanim t where t.id = g.vardiya_id;
    if coalesce(v_esnek, false) and g.durum not in ('izinli', 'raporlu', 'tatil', 'vardiya_yok') then
        esnek_hedef_dk := pdks.ayar_al('esnek_gunluk_hedef_dk');
    else
        esnek_hedef_dk := 0;
    end if;
    esnek_fark_dk := case when coalesce(v_esnek, false) then calisma_dk else 0 end - esnek_hedef_dk;
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Kilitli dönemin puantajı (mola ve esnek sütunları eklendi; diğer kurallar aynı)
-- ---------------------------------------------------------------------
create or replace function pdks.puantaj_yaz(p_donem_id bigint)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_donem  pdks.donem;
    v_say    integer := 0;
    v_n      integer;
begin
    select * into v_donem from pdks.donem where id = p_donem_id;
    if v_donem.durum is distinct from 'kilitli' then
        raise exception 'Puantaj yalnızca kilitlenmiş döneme yazılır.';
    end if;

    insert into pdks.puantaj_satiri (donem_id, calisan_id, satir_turu, calisilan_gun, calisma_dk, gec_kalma_dk,
                                     erken_cikis_dk, devamsiz_gun, izinli_gun, raporlu_gun, tatil_gun, fazla_mesai_dk,
                                     fm50_dk, fm100_dk, gece_calisma_dk, saatlik_izin_dk,
                                     mola_dk, esnek_hedef_dk, esnek_fark_dk)
    select p_donem_id, v.calisan_id, 'normal', v.calisilan_gun, v.calisma_dk, v.gec_kalma_dk,
           v.erken_cikis_dk, v.devamsiz_gun, v.izinli_gun, v.raporlu_gun, v.tatil_gun, v.fazla_mesai_dk,
           v.fm50_dk, v.fm100_dk, v.gece_calisma_dk, v.saatlik_izin_dk,
           v.mola_dk, v.esnek_hedef_dk, v.esnek_fark_dk
    from pdks.v_puantaj_canli v
    where v.yil = v_donem.yil and v.ay = v_donem.ay;
    get diagnostics v_n = row_count;
    v_say := v_say + v_n;

    insert into pdks.puantaj_kalemi (puantaj_satiri_id, kod, gun, dakika)
    select s.id, k.kod, sum(k.gun), sum(k.dakika)
    from pdks.gun_kodlari_hesapla(v_donem.yil, v_donem.ay) k
    join pdks.puantaj_satiri s
      on s.donem_id = p_donem_id and s.calisan_id = k.calisan_id and s.satir_turu = 'normal'
    group by s.id, k.kod;

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
    ), gun_durumlari as (
        select g.calisan_id, g.is_gunu,
               pdks.donem_bul(date_trunc('month', g.is_gunu)::date) as kaynak_donem_id,
               o as once, s as sonra
        from gunler x
        join pdks.gun_kaydi g on g.id = x.gun_kaydi_id
        cross join lateral pdks.gun_katkisi(x.gun_kaydi_id, x.onceki) o
        cross join lateral pdks.gun_katkisi(x.gun_kaydi_id, x.onceki || x.bu_donem) s
    ), havuz as (
        select i.*, pdks.donem_bul(date_trunc('month', i.is_gunu)::date) as kaynak_donem_id
        from pdks.fazla_mesai_inceleme i
        where i.hedef_donem_id = p_donem_id and i.fark_satiri and i.durum = 'onaylandi'
    ), farklar as (
        select calisan_id, kaynak_donem_id,
               (sonra).calisilan_gun - (once).calisilan_gun     as calisilan_gun,
               (sonra).calisma_dk - (once).calisma_dk           as calisma_dk,
               (sonra).gec_kalma_dk - (once).gec_kalma_dk       as gec_kalma_dk,
               (sonra).erken_cikis_dk - (once).erken_cikis_dk   as erken_cikis_dk,
               (sonra).devamsiz_gun - (once).devamsiz_gun       as devamsiz_gun,
               (sonra).izinli_gun - (once).izinli_gun           as izinli_gun,
               (sonra).raporlu_gun - (once).raporlu_gun         as raporlu_gun,
               (sonra).tatil_gun - (once).tatil_gun             as tatil_gun,
               (sonra).fazla_mesai_dk - (once).fazla_mesai_dk   as fazla_mesai_dk,
               (sonra).fm50_dk - (once).fm50_dk                 as fm50_dk,
               (sonra).fm100_dk - (once).fm100_dk               as fm100_dk,
               (sonra).gece_calisma_dk - (once).gece_calisma_dk as gece_calisma_dk,
               (sonra).saatlik_izin_dk - (once).saatlik_izin_dk as saatlik_izin_dk,
               (sonra).mola_dk - (once).mola_dk                 as mola_dk,
               (sonra).esnek_hedef_dk - (once).esnek_hedef_dk   as esnek_hedef_dk,
               (sonra).esnek_fark_dk - (once).esnek_fark_dk     as esnek_fark_dk
        from gun_durumlari
        union all
        select calisan_id, kaynak_donem_id, 0, calisma_etki_dk, 0, 0, 0, 0, 0, 0,
               fm50_etki_dk + fm100_etki_dk, fm50_etki_dk, fm100_etki_dk, gece_etki_dk, 0, 0, 0, 0
        from havuz
    ), kod_farklari as (
        select calisan_id, kaynak_donem_id, kod, sum(gun) as gun, sum(dakika) as dakika
        from (
            select d.calisan_id, d.kaynak_donem_id, k.kod, k.gun, k.dakika
            from gun_durumlari d
            cross join lateral pdks.gun_kod_satirlari(d.calisan_id, d.is_gunu, (d.sonra).durum,
                                                      (d.sonra).calisma_dk, (d.sonra).fm50_dk, (d.sonra).fm100_dk) k
            union all
            select d.calisan_id, d.kaynak_donem_id, k.kod, -k.gun, -k.dakika
            from gun_durumlari d
            cross join lateral pdks.gun_kod_satirlari(d.calisan_id, d.is_gunu, (d.once).durum,
                                                      (d.once).calisma_dk, (d.once).fm50_dk, (d.once).fm100_dk) k
            union all
            select calisan_id, kaynak_donem_id, 'FM50', 0, fm50_etki_dk from havuz where fm50_etki_dk <> 0
            union all
            select calisan_id, kaynak_donem_id, 'FM100', 0, fm100_etki_dk from havuz where fm100_etki_dk <> 0
        ) x
        group by calisan_id, kaynak_donem_id, kod
        having sum(gun) <> 0 or sum(dakika) <> 0
    ), yeni as (
        insert into pdks.puantaj_satiri (donem_id, calisan_id, satir_turu, kaynak_donem_id, calisilan_gun, calisma_dk,
                                         gec_kalma_dk, erken_cikis_dk, devamsiz_gun, izinli_gun, raporlu_gun,
                                         tatil_gun, fazla_mesai_dk, fm50_dk, fm100_dk, gece_calisma_dk, saatlik_izin_dk,
                                         mola_dk, esnek_hedef_dk, esnek_fark_dk)
        select p_donem_id, calisan_id, 'fark', kaynak_donem_id,
               sum(calisilan_gun), sum(calisma_dk), sum(gec_kalma_dk), sum(erken_cikis_dk), sum(devamsiz_gun),
               sum(izinli_gun), sum(raporlu_gun), sum(tatil_gun), sum(fazla_mesai_dk),
               sum(fm50_dk), sum(fm100_dk), sum(gece_calisma_dk), sum(saatlik_izin_dk),
               sum(mola_dk), sum(esnek_hedef_dk), sum(esnek_fark_dk)
        from farklar
        group by calisan_id, kaynak_donem_id
        having sum(abs(calisilan_gun)) + sum(abs(calisma_dk)) + sum(abs(gec_kalma_dk)) + sum(abs(erken_cikis_dk))
             + sum(abs(devamsiz_gun)) + sum(abs(izinli_gun)) + sum(abs(raporlu_gun)) + sum(abs(tatil_gun))
             + sum(abs(fazla_mesai_dk)) + sum(abs(gece_calisma_dk)) + sum(abs(saatlik_izin_dk))
             + sum(abs(mola_dk)) + sum(abs(esnek_hedef_dk)) + sum(abs(esnek_fark_dk)) > 0
        returning id, calisan_id, kaynak_donem_id
    ), kalemler as (
        insert into pdks.puantaj_kalemi (puantaj_satiri_id, kod, gun, dakika)
        select y.id, k.kod, k.gun, k.dakika
        from yeni y
        join kod_farklari k on k.calisan_id = y.calisan_id and k.kaynak_donem_id = y.kaynak_donem_id
        returning 1
    )
    select count(*) into v_n from yeni;
    v_say := v_say + v_n;

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Yetkiler
-- ---------------------------------------------------------------------
revoke execute on function
    pdks.mola_suresi(integer), pdks.vardiya_araligi(smallint, date), pdks.vardiya_onerisi(bigint),
    pdks.gun_hesabi(bigint, date, timestamptz, timestamptz, timestamptz, timestamptz, smallint),
    pdks.gun_hesabini_yenile(bigint), pdks.gece_isi_hesapla(), pdks.gece_isi_sorular(date),
    pdks.gece_isi_uyarilar(date), pdks.gun_katkisi(bigint, bigint[]), pdks.puantaj_yaz(bigint)
from public, anon, authenticated;
