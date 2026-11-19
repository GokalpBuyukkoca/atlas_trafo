-- =====================================================================
-- Puantaj ve fazla mesai kuralları
--
--   1. Tolerans: geç kalma 10 dk, erken çıkış 5 dk. Tolerans aşılınca
--      isteğe bağlı yuvarlama (tolerans_yuvarlama_dk, 0 = kapalı).
--   2. Onaysız fazla mesai havuzu (fazla_mesai_inceleme): planı olmayan
--      geç çıkış puantaja yansımaz, İK kararını bekler. İK onaylarsa girer;
--      kilitli aya ait onay sonraki açık aya fark satırı olur.
--   3. FM50 / FM100: FM100 = Pazar + resmi tatil (cumartesi_hafta_sonu = 1
--      ise Cumartesi de). Diğer günlerde vardiyayı aşan onaylı kısım FM50.
--      Gün türüne vardiyanın başladığı gün (is_gunu) bakılır.
--   4. Gece çalışması (20:00–06:00, İş Kanunu m.69): gece_calisma_dk;
--      gece_calisma_sinir_dk aşılırsa İK'ya uyarı. Ücret hesaplanmaz.
--   5. Puantaj kodları: NÇ, FM50, FM100, Yİ, RPR, MZR, ÜCSZ, Dİ, DVMSZ, RT, HT.
--      gun_kodlari(yıl, ay) her gün için, puantaj_kalemi her puantaj satırı için.
--   6. Saatlik izin (vizite dahil): o süre geç kalma, erken çıkış ya da
--      devamsızlık sayılmaz; çalışma dakikasına da eklenmez.
--
--   Günün hesabı yine tek yerde: pdks.gun_hesabi().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Ayarlar
-- ---------------------------------------------------------------------
update pdks.ayar set deger = 10 where anahtar = 'gec_kalma_tolerans_dk';

insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('tolerans_yuvarlama_dk', 0, 'dakika',
     'Tolerans aşılınca geç kalma / erken çıkış bu dakikalık dilimlere yukarı yuvarlanır (0 = kapalı)'),
    ('cumartesi_hafta_sonu', 0, 'evet/hayır',
     '1 ise Cumartesi çalışması FM100 sayılır; 0 ise Cumartesi normal iş günüdür (vardiyayı aşan kısım FM50)'),
    ('gece_calisma_sinir_dk', 450, 'dakika',
     'Gece çalışması (20:00–06:00) bu süreyi aşarsa İK''ya uyarı (İş Kanunu m.69: 7,5 saat)')
on conflict (anahtar) do nothing;

-- ---------------------------------------------------------------------
-- 1. Yeni uyarı türleri (check kısıtı eski değerler korunarak genişletilir)
-- ---------------------------------------------------------------------
create function pg_temp.kisit_genislet(p_tablo regclass, p_kisit text, p_kolon text, p_yeni text[])
returns void
language plpgsql
as $$
declare
    v_degerler text[];
begin
    select array_agg(m[1] order by ord) into v_degerler
    from pg_constraint c,
         regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') with ordinality as r(m, ord)
    where c.conrelid = p_tablo and c.conname = p_kisit;
    if coalesce(array_length(v_degerler, 1), 0) < 2 then
        raise exception '% kısıtı okunamadı', p_kisit;
    end if;
    select array_agg(distinct d) into v_degerler from unnest(v_degerler || p_yeni) d;
    execute format('alter table %s drop constraint %I', p_tablo, p_kisit);
    execute format('alter table %s add constraint %I check (%I in (%s))', p_tablo, p_kisit, p_kolon,
                   (select string_agg(quote_literal(d), ', ' order by d) from unnest(v_degerler) d));
end;
$$;

select pg_temp.kisit_genislet('pdks.uyari', 'uyari_tur_check', 'tur',
    array['gece_calisma_siniri_asildi', 'fm_yillik_sinir_asildi']);

-- ---------------------------------------------------------------------
-- 2. Yeni alanlar
-- ---------------------------------------------------------------------
alter table pdks.gun_kaydi
    add column fm50_dk          integer check (fm50_dk >= 0),
    add column fm100_dk         integer check (fm100_dk >= 0),
    add column gece_calisma_dk  integer check (gece_calisma_dk >= 0),
    add column saatlik_izin_dk  integer check (saatlik_izin_dk >= 0),
    add constraint gun_kaydi_fm_toplam check (
        (fm50_dk is null and fm100_dk is null)
        or coalesce(fazla_mesai_dk, 0) = coalesce(fm50_dk, 0) + coalesce(fm100_dk, 0));

comment on column pdks.gun_kaydi.fm50_dk is 'Fazla mesainin %50 kısmı (dakika): normal iş gününde vardiyayı aşan onaylı süre.';
comment on column pdks.gun_kaydi.fm100_dk is 'Fazla mesainin %100 kısmı (dakika): Pazar / resmi tatil çalışması.';
comment on column pdks.gun_kaydi.gece_calisma_dk is 'Sayılan çalışmanın 20:00–06:00 arasına düşen dakikası (m.69).';
comment on column pdks.gun_kaydi.saatlik_izin_dk is 'Vardiya içindeki saatlik izin (vizite dahil) dakikası.';

alter table pdks.puantaj_satiri
    add column fm50_dk          integer not null default 0,
    add column fm100_dk         integer not null default 0,
    add column gece_calisma_dk  integer not null default 0,
    add column saatlik_izin_dk  integer not null default 0,
    add constraint puantaj_satiri_yeni_alanlar_check check (
        satir_turu = 'fark'
        or (fm50_dk >= 0 and fm100_dk >= 0 and gece_calisma_dk >= 0 and saatlik_izin_dk >= 0));

-- ---------------------------------------------------------------------
-- 3. Saatlik izin (vizite dahil). Yalnızca İK girer; silinmez, değişmez.
--    tur = 'vizite' sağlık bilgisidir: amir yalnızca v_saatlik_izin_amir'i görür.
-- ---------------------------------------------------------------------
create table pdks.saatlik_izin (
    id            bigint generated always as identity primary key,
    calisan_id    bigint not null references pdks.calisan (id),
    tarih         date not null,                 -- iş günü (gun_kaydi.is_gunu)
    baslangic     timestamptz not null,
    bitis         timestamptz not null,
    tur           text not null check (tur in ('vizite', 'mazeret', 'diger')),
    aciklama      text,
    giren_id      bigint not null references pdks.kullanici (id),
    giris_zamani  timestamptz not null default now(),
    check (bitis > baslangic),
    check (bitis - baslangic <= interval '12 hours')
);
create index saatlik_izin_calisan_tarih on pdks.saatlik_izin (calisan_id, tarih);

comment on table pdks.saatlik_izin is
    'Gün içinde saat aralıklı izin (vizite dahil). Yalnızca İK girer; silinmez, değiştirilmez.';

create function pdks.saatlik_izin_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if pdks.kullanici_rolu(new.giren_id) is distinct from 'ik' then
        raise exception 'Saatlik izni yalnızca İK girer.';
    end if;
    if pdks.donem_kilitli_mi(new.tarih) then
        raise exception '% günü kilitli bir döneme ait; saatlik izin girilemez.', new.tarih;
    end if;
    -- İzin iş gününe ya da (gece vardiyasında) ertesi güne düşer
    if new.baslangic < (new.tarih::timestamp at time zone 'Europe/Istanbul')
       or new.baslangic >= ((new.tarih + 2)::timestamp at time zone 'Europe/Istanbul') then
        raise exception 'İzin saati % iş günüyle uyuşmuyor.', new.tarih;
    end if;
    new.giris_zamani := now();
    return new;
end;
$$;
create trigger saatlik_izin_kontrol before insert on pdks.saatlik_izin
    for each row execute function pdks.saatlik_izin_kontrol();
create trigger saatlik_izin_gorev_ayriligi before insert on pdks.saatlik_izin
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'giren_id');
create trigger saatlik_izin_degistirilemez before update or delete on pdks.saatlik_izin
    for each row execute function pdks.degistirilemez();
create trigger saatlik_izin_bosaltilamaz before truncate on pdks.saatlik_izin
    for each statement execute function pdks.degistirilemez();

-- ---------------------------------------------------------------------
-- 4. Onaysız fazla mesai havuzu
--    Gece işi yazar (inceleme_bekliyor); kararı yalnızca İK verir.
--      vardiya_sonrasi  : vardiya bitişinden sonra onaylı plandan fazla kalınan süre
--      tatil_calismasi  : yazılı onayı olmayan çalışanın Pazar / resmi tatil çalışması
--    Karar verilen kayıt değişmez. Silinmez.
-- ---------------------------------------------------------------------
create table pdks.fazla_mesai_inceleme (
    id                 bigint generated always as identity primary key,
    gun_kaydi_id       bigint not null unique references pdks.gun_kaydi (id),
    calisan_id         bigint not null references pdks.calisan (id),
    is_gunu            date not null,
    tur                text not null check (tur in ('vardiya_sonrasi', 'tatil_calismasi')),
    dakika             integer not null check (dakika > 0),
    durum              text not null default 'inceleme_bekliyor'
                       check (durum in ('inceleme_bekliyor', 'onaylandi', 'reddedildi')),
    olusturma_zamani   timestamptz not null default now(),
    guncelleme_zamani  timestamptz not null default now(),
    karar_veren_id     bigint references pdks.kullanici (id),
    karar_zamani       timestamptz,
    karar_aciklama     text,
    -- Onayın puantaja etkisi (onay anında hesaplanır)
    fm50_etki_dk       integer not null default 0,
    fm100_etki_dk      integer not null default 0,
    calisma_etki_dk    integer not null default 0,
    gece_etki_dk       integer not null default 0,
    -- Kilitli aya ait onay sonraki açık ayın puantajına fark olarak girer
    fark_satiri        boolean not null default false,
    hedef_donem_id     bigint references pdks.donem (id),
    check ((durum = 'inceleme_bekliyor') = (karar_zamani is null)),
    check ((durum = 'inceleme_bekliyor') = (karar_veren_id is null)),
    check (durum <> 'reddedildi' or length(trim(karar_aciklama)) >= 5)
);
create index fazla_mesai_inceleme_bekleyen on pdks.fazla_mesai_inceleme (is_gunu)
    where durum = 'inceleme_bekliyor';
create index fazla_mesai_inceleme_fark on pdks.fazla_mesai_inceleme (hedef_donem_id) where fark_satiri;

comment on table pdks.fazla_mesai_inceleme is
    'Onaysız fazla mesai havuzu: planı olmayan çalışma İK kararına kadar puantaja girmez. Silinmez.';

create function pdks.fazla_mesai_inceleme_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'Fazla mesai inceleme kaydı silinemez.';
    end if;
    if tg_op = 'INSERT' then
        if new.durum <> 'inceleme_bekliyor' then
            raise exception 'Yeni kayıt "inceleme_bekliyor" olarak girilir; kararı İK verir.';
        end if;
        new.olusturma_zamani := now();
        new.guncelleme_zamani := now();
        return new;
    end if;

    if (new.gun_kaydi_id, new.calisan_id, new.is_gunu) is distinct from (old.gun_kaydi_id, old.calisan_id, old.is_gunu) then
        raise exception 'İnceleme kaydının günü ve çalışanı değiştirilemez.';
    end if;

    if old.durum <> 'inceleme_bekliyor' then
        -- Karar anında (aynı işlemde) yalnızca puantaj etkisi yazılabilir
        if old.karar_zamani = now()
           and (new.durum, new.dakika, new.tur, new.karar_veren_id, new.karar_zamani, new.karar_aciklama)
               is not distinct from
               (old.durum, old.dakika, old.tur, old.karar_veren_id, old.karar_zamani, old.karar_aciklama) then
            return new;
        end if;
        raise exception 'Karara bağlanmış inceleme kaydı değiştirilemez.';
    end if;

    if new.durum = 'inceleme_bekliyor' then
        -- Gece işi süreyi yeniden hesaplayabilir
        if new.karar_veren_id is not null or new.karar_aciklama is not null then
            raise exception 'Karar bilgisi durumla birlikte girilir.';
        end if;
        new.guncelleme_zamani := now();
        return new;
    end if;

    if pdks.kullanici_rolu(new.karar_veren_id) is distinct from 'ik' then
        raise exception 'Onaysız fazla mesaiye yalnızca İK karar verir.';
    end if;
    if new.dakika <> old.dakika or new.tur <> old.tur then
        raise exception 'Karar verilirken süre değiştirilemez.';
    end if;
    new.karar_zamani := now();
    new.guncelleme_zamani := now();
    return new;
end;
$$;
create trigger fazla_mesai_inceleme_kontrol before insert or update or delete on pdks.fazla_mesai_inceleme
    for each row execute function pdks.fazla_mesai_inceleme_kontrol();
create trigger fazla_mesai_inceleme_gorev_ayriligi before insert or update on pdks.fazla_mesai_inceleme
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'karar_veren_id');
create trigger fazla_mesai_inceleme_bosaltilamaz before truncate on pdks.fazla_mesai_inceleme
    for each statement execute function pdks.degistirilemez();

-- ---------------------------------------------------------------------
-- 5. Puantaj kalemleri: her puantaj satırının kod kırılımı (ERP'ye gider)
--    Ay kilitlenince yazılır; silinmez, değişmez.
-- ---------------------------------------------------------------------
create table pdks.puantaj_kalemi (
    id                 bigint generated always as identity primary key,
    puantaj_satiri_id  bigint not null references pdks.puantaj_satiri (id),
    kod                text not null check (kod in ('NÇ', 'FM50', 'FM100', 'Yİ', 'RPR', 'MZR',
                                                    'ÜCSZ', 'Dİ', 'DVMSZ', 'RT', 'HT')),
    gun                numeric(5,1) not null default 0,
    dakika             integer not null default 0,
    unique (puantaj_satiri_id, kod)
);

comment on table pdks.puantaj_kalemi is
    'Puantaj satırının kod kırılımı (NÇ, FM50, FM100, Yİ, RPR, MZR, ÜCSZ, Dİ, DVMSZ, RT, HT). Silinmez, değişmez.';

create trigger puantaj_kalemi_degistirilemez before update or delete on pdks.puantaj_kalemi
    for each row execute function pdks.degistirilemez();
create trigger puantaj_kalemi_bosaltilamaz before truncate on pdks.puantaj_kalemi
    for each statement execute function pdks.degistirilemez();

-- ---------------------------------------------------------------------
-- 6. Yardımcılar
-- ---------------------------------------------------------------------

-- FM100 günü mü? Pazar, tam gün resmi tatil; ayar açıksa Cumartesi
create function pdks.fm100_gunu_mu(p_gun date)
returns boolean
language sql
stable
set search_path = pdks
as $$
    select extract(isodow from p_gun) = 7
        or (extract(isodow from p_gun) = 6 and coalesce(pdks.ayar_al('cumartesi_hafta_sonu'), 0) = 1)
        or exists (select 1 from pdks.resmi_tatil where tarih = p_gun and not yarim_gun);
$$;

-- Bir zaman kümesinin toplam süresi (tam dakika)
create function pdks.dakika_toplami(p tstzmultirange)
returns integer
language sql
immutable
as $$
    select coalesce(floor(sum(extract(epoch from upper(r) - lower(r))) / 60), 0)::integer
    from unnest(p) r;
$$;

-- İki an arasındaki aralık; bitiş başlangıçtan önceyse boş
create function pdks.aralik(p_bas timestamptz, p_bit timestamptz)
returns tstzmultirange
language sql
immutable
as $$
    select case when p_bas is null or p_bit is null or p_bit <= p_bas then '{}'::tstzmultirange
                else tstzmultirange(tstzrange(p_bas, p_bit)) end;
$$;

-- Çalışanın o iş günündeki saatlik izinleri
create function pdks.saatlik_izin_araligi(p_calisan_id bigint, p_is_gunu date)
returns tstzmultirange
language sql
stable
set search_path = pdks
as $$
    select coalesce(range_agg(tstzrange(baslangic, bitis)), '{}'::tstzmultirange)
    from pdks.saatlik_izin
    where calisan_id = p_calisan_id and tarih = p_is_gunu;
$$;

-- Gece dilimleri (20:00–06:00), iş gününün bir gün öncesinden bir gün sonrasına
create function pdks.gece_araligi(p_is_gunu date)
returns tstzmultirange
language sql
stable
as $$
    select range_agg(tstzrange(((d + time '20:00') at time zone 'Europe/Istanbul'),
                               (((d + 1) + time '06:00') at time zone 'Europe/Istanbul')))
    from generate_series(p_is_gunu - 1, p_is_gunu + 1, interval '1 day') g(d0),
         lateral (select g.d0::date as d) x;
$$;

-- Tolerans aşılınca yuvarlama (0 = kapalı)
create function pdks.tolerans_uygula(p_dk integer, p_tolerans integer, p_yuvarlama integer)
returns integer
language sql
immutable
as $$
    select case when p_dk <= p_tolerans then 0
                when coalesce(p_yuvarlama, 0) > 0 then (ceil(p_dk::numeric / p_yuvarlama) * p_yuvarlama)::integer
                else p_dk end;
$$;

-- Kilitli değilse günün dönemi, kilitliyse sonraki ilk açık dönem
create function pdks.hedef_donem(p_gun date)
returns bigint
language plpgsql
set search_path = pdks
as $$
declare
    v_ay date := date_trunc('month', p_gun)::date;
begin
    while pdks.donem_kilitli_mi(v_ay) loop
        v_ay := (v_ay + interval '1 month')::date;
    end loop;
    return pdks.donem_bul(v_ay);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Tek hesap kuralı (genişletildi)
--    gec / erken      : saatlik izin süresi düşülür; tolerans aşılınca tam dakika
--                       (yuvarlama ayarı açıksa yukarı yuvarlanır)
--    normal iş günü   : vardiya içi + onaylı fazla mesai (plan + İK'nın havuzdan onayı) = FM50
--    FM100 günü       : yazılı onay varsa tüm çalışma FM100; yoksa yalnızca İK'nın
--                       havuzdan onayladığı kadarı
--    onaysiz_fm_dk    : puantaja girmeyen, İK kararı bekleyecek süre
-- ---------------------------------------------------------------------
drop function pdks.gun_hesabi(bigint, date, timestamptz, timestamptz, timestamptz, timestamptz);

create function pdks.gun_hesabi(p_calisan_id bigint, p_is_gunu date,
                                p_bas timestamptz, p_bit timestamptz,
                                p_giris timestamptz, p_cikis timestamptz,
                                out gec_kalma_dk integer, out erken_cikis_dk integer,
                                out calisma_dk integer, out fazla_mesai_dk integer,
                                out fm50_dk integer, out fm100_dk integer,
                                out gece_calisma_dk integer, out saatlik_izin_dk integer,
                                out onaysiz_fm_dk integer)
language plpgsql
stable
set search_path = pdks
as $$
declare
    v_izin   tstzmultirange := pdks.saatlik_izin_araligi(p_calisan_id, p_is_gunu);
    v_yuv    integer := pdks.ayar_al('tolerans_yuvarlama_dk');
    v_onay   boolean := pdks.fm_onay_gecerli_mi(p_calisan_id, p_is_gunu);
    v_tatil  boolean := pdks.fm100_gunu_mu(p_is_gunu);
    v_plan   integer;
    v_havuz  integer;
    v_bas_is timestamptz;
    v_ici    integer;
    v_sonra  integer;
    v_ek     integer;
begin
    gec_kalma_dk := 0; erken_cikis_dk := 0; calisma_dk := 0; fazla_mesai_dk := 0;
    fm50_dk := 0; fm100_dk := 0; gece_calisma_dk := 0; saatlik_izin_dk := 0; onaysiz_fm_dk := 0;
    if p_giris is null or p_cikis is null or p_bas is null or p_bit is null then
        return;
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
        calisma_dk := v_ici + v_ek;
        onaysiz_fm_dk := greatest(0, v_sonra - v_plan - v_havuz);
    elsif v_onay then
        v_ek := least(v_sonra, v_plan + v_havuz);
        fm100_dk := v_ici + v_ek;
        calisma_dk := fm100_dk;
        onaysiz_fm_dk := greatest(0, v_sonra - v_plan - v_havuz);
    else
        fm100_dk := least(v_ici + v_sonra, v_havuz);
        calisma_dk := fm100_dk;
        v_ek := greatest(0, fm100_dk - v_ici);
        onaysiz_fm_dk := greatest(0, v_ici + v_sonra - v_havuz);
    end if;
    fazla_mesai_dk := fm50_dk + fm100_dk;

    -- Sayılan çalışmanın gece dilimine düşen kısmı (en fazla çalışma kadar)
    gece_calisma_dk := least(calisma_dk,
        pdks.dakika_toplami((pdks.aralik(v_bas_is, least(p_cikis, p_bit + make_interval(mins => coalesce(v_ek, 0))))
                             - v_izin) * pdks.gece_araligi(p_is_gunu)));
end;
$$;

-- Hesabı yapılmış bir günün dakikalarını yeniden yazar (izin / karar sonrası)
create function pdks.gun_hesabini_yenile(p_gun_kaydi_id bigint)
returns void
language plpgsql
set search_path = pdks
as $$
begin
    update pdks.gun_kaydi g
    set (gec_kalma_dk, erken_cikis_dk, calisma_dk, fazla_mesai_dk, fm50_dk, fm100_dk,
         gece_calisma_dk, saatlik_izin_dk) =
        (select h.gec_kalma_dk, h.erken_cikis_dk, h.calisma_dk, h.fazla_mesai_dk, h.fm50_dk, h.fm100_dk,
                h.gece_calisma_dk, h.saatlik_izin_dk
         from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                              g.giris_zamani, g.cikis_zamani) h)
    where g.id = p_gun_kaydi_id and g.hesap_tamam and g.durum = 'tamam'
      and not pdks.donem_kilitli_mi(g.is_gunu);
end;
$$;

-- Havuz kaydını açar ya da (karar bekliyorsa) süresini günceller; gece sınırı uyarısını yazar
create function pdks.gun_sonrasi_kontroller(p_gun_kaydi_id bigint)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    g       pdks.gun_kaydi;
    h       record;
    v_mevcut pdks.fazla_mesai_inceleme;
    v_tur   text;
    v_say   integer := 0;
begin
    select * into g from pdks.gun_kaydi where id = p_gun_kaydi_id;
    if not g.hesap_tamam or g.durum <> 'tamam' then
        return 0;
    end if;
    select * into h from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                         g.giris_zamani, g.cikis_zamani);
    v_tur := case when pdks.fm100_gunu_mu(g.is_gunu) and not pdks.fm_onay_gecerli_mi(g.calisan_id, g.is_gunu)
                  then 'tatil_calismasi' else 'vardiya_sonrasi' end;

    select * into v_mevcut from pdks.fazla_mesai_inceleme where gun_kaydi_id = g.id;
    if h.onaysiz_fm_dk > pdks.ayar_al('fm_plansiz_esik_dk') then
        if v_mevcut.id is null then
            insert into pdks.fazla_mesai_inceleme (gun_kaydi_id, calisan_id, is_gunu, tur, dakika)
            values (g.id, g.calisan_id, g.is_gunu, v_tur, h.onaysiz_fm_dk);
            v_say := v_say + 1;
        elsif v_mevcut.durum = 'inceleme_bekliyor' and (v_mevcut.dakika, v_mevcut.tur) <> (h.onaysiz_fm_dk, v_tur) then
            update pdks.fazla_mesai_inceleme set dakika = h.onaysiz_fm_dk, tur = v_tur where id = v_mevcut.id;
        end if;
    end if;

    if g.gece_calisma_dk > pdks.ayar_al('gece_calisma_sinir_dk') then
        v_say := v_say + pdks.uyari_yaz('gece_calisma_siniri_asildi', 'gece:' || g.id,
            format('%s: gece çalışması (20:00–06:00) %s dk; sınır %s dk (7,5 saat).',
                   to_char(g.is_gunu, 'DD.MM.YYYY'), g.gece_calisma_dk, pdks.ayar_al('gece_calisma_sinir_dk')),
            g.calisan_id);
    end if;
    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Gerçekleşen fazla mesai kontrolü (genişletildi)
--    İzin verilen = onaylı plan (yazılı onay varsa) + İK'nın havuzdan onayı
--                   + FM100 gününde vardiya süresi (yazılı onay varsa)
-- ---------------------------------------------------------------------
create or replace function pdks.gun_kaydi_fazla_mesai_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_plan    integer;
    v_onay    boolean;
    v_havuz   integer;
    v_izinli  integer;
begin
    if coalesce(new.fazla_mesai_dk, 0) = 0 then
        return new;
    end if;
    select planli_dk into v_plan from pdks.fazla_mesai_plani
    where calisan_id = new.calisan_id and is_gunu = new.is_gunu and durum = 'onaylandi';
    v_onay := pdks.fm_onay_gecerli_mi(new.calisan_id, new.is_gunu);
    select coalesce(sum(dakika), 0) into v_havuz from pdks.fazla_mesai_inceleme
    where calisan_id = new.calisan_id and is_gunu = new.is_gunu and durum = 'onaylandi';

    v_izinli := case when v_onay then coalesce(v_plan, 0) else 0 end + v_havuz
              + case when v_onay and pdks.fm100_gunu_mu(new.is_gunu) and new.vardiya_id is not null
                     then pdks.vardiya_suresi_dk(new.vardiya_id) else 0 end;

    if v_izinli = 0 then
        if v_plan is null then
            raise exception '% günü için onaylı fazla mesai planı yok; plansız çalışma puantaja yazılmaz (İK''ya uyarı verilir).',
                new.is_gunu;
        end if;
        raise exception '% günü için geçerli yazılı fazla mesai onayı yok.', new.is_gunu;
    end if;
    if new.fazla_mesai_dk > v_izinli then
        raise exception 'Fazla mesai % dk, izin verilen % dk (onaylı plan ve İK onayı); fazlası puantaja yazılmaz.',
            new.fazla_mesai_dk, v_izinli;
    end if;
    return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Gece işi: resmi tatilde okutma varsa gün çalışılmış sayılır (FM100);
--    okutma yoksa "tatil" (RT). Diğer kurallar aynı.
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
               case when o.giris is null or o.cikis > o.giris then o.cikis end as cikis,
               (select i.tur from pdks.izin i
                where i.calisan_id = t.calisan_id and p_gun between i.baslangic and i.bitis
                  and i.iptal_zamani is null
                order by i.id limit 1) as izin_turu,
               -- Resmi tatil yalnızca hiç okutma yoksa "tatil"dir; okutma varsa çalışılmış gün işlenir
               exists (select 1 from pdks.resmi_tatil r where r.tarih = p_gun and not r.yarim_gun)
                   and o.giris is null and o.cikis is null as tatil
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

-- Hesap adımı: yeni alanlar + her hesaplanan gün için havuz ve gece sınırı kontrolü
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
                                           g.giris_zamani, g.cikis_zamani) x
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
-- 10. Puantaj kodları
--     Gün kaydı yok / vardiya yok : RT (tam gün resmi tatil) ya da HT (hafta tatili)
--     tatil                       : RT
--     izinli                      : Yİ (yıllık), MZR (mazeret), ÜCSZ (ücretsiz), Dİ (diğer)
--     raporlu                     : RPR       devamsiz : DVMSZ
--     tamam, normal gün           : NÇ (çalışma − FM50) + FM50
--     tamam, FM100 günü           : FM100 (gün 1, tüm sayılan çalışma)
--     eksik / soru / şüphe        : kod yok (karar bekliyor)
-- ---------------------------------------------------------------------
create function pdks.gun_kod_satirlari(p_calisan_id bigint, p_gun date, p_durum text,
                                       p_calisma_dk integer, p_fm50_dk integer, p_fm100_dk integer)
returns table (kod text, gun numeric, dakika integer)
language plpgsql
stable
set search_path = pdks
as $$
declare
    v_izin text;
begin
    if p_durum is null or p_durum = 'vardiya_yok' then
        return query select case when exists (select 1 from pdks.resmi_tatil r where r.tarih = p_gun and not r.yarim_gun)
                                 then 'RT' else 'HT' end, 1::numeric, 0;
    elsif p_durum = 'tatil' then
        return query select 'RT'::text, 1::numeric, 0;
    elsif p_durum = 'raporlu' then
        return query select 'RPR'::text, 1::numeric, 0;
    elsif p_durum = 'devamsiz' then
        return query select 'DVMSZ'::text, 1::numeric, 0;
    elsif p_durum = 'izinli' then
        select i.tur into v_izin from pdks.izin i
        where i.calisan_id = p_calisan_id and p_gun between i.baslangic and i.bitis and i.iptal_zamani is null
        order by i.id limit 1;
        return query select case v_izin when 'yillik' then 'Yİ' when 'mazeret' then 'MZR'
                                        when 'ucretsiz' then 'ÜCSZ' when 'rapor' then 'RPR' else 'Dİ' end,
                            1::numeric, 0;
    elsif p_durum = 'tamam' then
        if pdks.fm100_gunu_mu(p_gun) then
            return query select 'FM100'::text, 1::numeric, coalesce(p_fm100_dk, 0);
        else
            return query select 'NÇ'::text, 1::numeric, coalesce(p_calisma_dk, 0) - coalesce(p_fm50_dk, 0);
            if coalesce(p_fm50_dk, 0) <> 0 then
                return query select 'FM50'::text, 0::numeric, p_fm50_dk;
            end if;
        end if;
    end if;
end;
$$;

-- Ayın gün gün kodları (iç kullanım): ay içinde gün kaydı olan çalışanlar, çalıştıkları tarihler
create function pdks.gun_kodlari_hesapla(p_yil integer, p_ay integer)
returns table (calisan_id bigint, tarih date, kod text, gun numeric, dakika integer)
language sql
stable
set search_path = pdks
as $$
    with ay as (
        select make_date(p_yil, p_ay, 1) as bas,
               (make_date(p_yil, p_ay, 1) + interval '1 month - 1 day')::date as bit
    ), kisiler as (
        select distinct g.calisan_id from pdks.gun_kaydi g, ay
        where g.is_gunu between ay.bas and ay.bit
    )
    select k.calisan_id, d::date, x.kod, x.gun, x.dakika
    from kisiler k
    join pdks.calisan c on c.id = k.calisan_id
    cross join ay
    cross join generate_series(ay.bas, ay.bit, interval '1 day') d
    left join pdks.gun_kaydi g on g.calisan_id = k.calisan_id and g.is_gunu = d::date
    cross join lateral pdks.gun_kod_satirlari(
        k.calisan_id, d::date,
        case when g.durum = 'tamam' and not g.hesap_tamam then 'eksik' else g.durum end,
        g.calisma_dk, g.fm50_dk, g.fm100_dk) x
    where d::date >= c.ise_giris_tarihi
      and (c.isten_cikis_tarihi is null or d::date <= c.isten_cikis_tarihi);
$$;

-- Ekran: ayın gün gün puantaj kodları (yalnızca İK ve yönetici; izin türü içerir)
create function pdks.gun_kodlari(p_yil integer, p_ay integer)
returns table (calisan_id bigint, tarih date, kod text, gun numeric, dakika integer)
language plpgsql
stable
security definer
set search_path = pdks
as $$
begin
    if not pdks.tum_veriyi_gorur() then
        raise exception 'Bu işlem için yetkiniz yok.';
    end if;
    return query select * from pdks.gun_kodlari_hesapla(p_yil, p_ay);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Canlı puantaj: yeni sütunlar sona eklenir
-- ---------------------------------------------------------------------
create or replace view pdks.v_puantaj_canli as
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
       coalesce(sum(g.saatlik_izin_dk), 0)                        as saatlik_izin_dk
from pdks.gun_kaydi g
group by 1, 2, 3;
alter view pdks.v_puantaj_canli set (security_invoker = true);

-- Amir saatlik izni yalnızca "saatlik izin" olarak görür (tür sağlık bilgisi olabilir)
create view pdks.v_saatlik_izin_amir as
select id, calisan_id, tarih, baslangic, bitis, 'saatlik_izin'::text as tur
from pdks.saatlik_izin
where pdks.tum_veriyi_gorur() or pdks.amirin_calisani_mi(calisan_id);

comment on view pdks.v_saatlik_izin_amir is 'Amirin saatlik izin görünümü: izin türü gizlidir.';

-- ---------------------------------------------------------------------
-- 12. Günün puantaja katkısı (yeni alanlar ve durum da döner)
-- ---------------------------------------------------------------------
drop function pdks.gun_katkisi(bigint, bigint[]);

create function pdks.gun_katkisi(p_gun_kaydi_id bigint, p_duzeltmeler bigint[],
                                 out calisilan_gun numeric, out calisma_dk integer,
                                 out gec_kalma_dk integer, out erken_cikis_dk integer,
                                 out devamsiz_gun numeric, out izinli_gun numeric,
                                 out raporlu_gun numeric, out tatil_gun numeric,
                                 out fazla_mesai_dk integer, out fm50_dk integer, out fm100_dk integer,
                                 out gece_calisma_dk integer, out saatlik_izin_dk integer,
                                 out durum text)
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
                                              g.giris_zamani, g.cikis_zamani);
        calisma_dk := h.calisma_dk; gec_kalma_dk := h.gec_kalma_dk;
        erken_cikis_dk := h.erken_cikis_dk; fazla_mesai_dk := h.fazla_mesai_dk;
        fm50_dk := h.fm50_dk; fm100_dk := h.fm100_dk;
        gece_calisma_dk := h.gece_calisma_dk; saatlik_izin_dk := h.saatlik_izin_dk;
    else
        calisma_dk := 0; gec_kalma_dk := 0; erken_cikis_dk := 0; fazla_mesai_dk := 0;
        fm50_dk := 0; fm100_dk := 0; gece_calisma_dk := 0; saatlik_izin_dk := 0;
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Kilitli dönemin puantajı: satırlar + kod kalemleri
--     Fark satırları: (a) kilitli aylara sonradan gelen düzeltmeler,
--                     (b) kilitli aya ait, sonradan onaylanan onaysız fazla mesai
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

    -- Normal satırlar: kilit anındaki canlı puantajın aynısı
    insert into pdks.puantaj_satiri (donem_id, calisan_id, satir_turu, calisilan_gun, calisma_dk, gec_kalma_dk,
                                     erken_cikis_dk, devamsiz_gun, izinli_gun, raporlu_gun, tatil_gun, fazla_mesai_dk,
                                     fm50_dk, fm100_dk, gece_calisma_dk, saatlik_izin_dk)
    select p_donem_id, v.calisan_id, 'normal', v.calisilan_gun, v.calisma_dk, v.gec_kalma_dk,
           v.erken_cikis_dk, v.devamsiz_gun, v.izinli_gun, v.raporlu_gun, v.tatil_gun, v.fazla_mesai_dk,
           v.fm50_dk, v.fm100_dk, v.gece_calisma_dk, v.saatlik_izin_dk
    from pdks.v_puantaj_canli v
    where v.yil = v_donem.yil and v.ay = v_donem.ay;
    get diagnostics v_n = row_count;
    v_say := v_say + v_n;

    -- Normal satırların kod kalemleri
    insert into pdks.puantaj_kalemi (puantaj_satiri_id, kod, gun, dakika)
    select s.id, k.kod, sum(k.gun), sum(k.dakika)
    from pdks.gun_kodlari_hesapla(v_donem.yil, v_donem.ay) k
    join pdks.puantaj_satiri s
      on s.donem_id = p_donem_id and s.calisan_id = k.calisan_id and s.satir_turu = 'normal'
    group by s.id, k.kod;

    -- Fark satırları ve kalemleri
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
               (sonra).saatlik_izin_dk - (once).saatlik_izin_dk as saatlik_izin_dk
        from gun_durumlari
        union all
        select calisan_id, kaynak_donem_id, 0, calisma_etki_dk, 0, 0, 0, 0, 0, 0,
               fm50_etki_dk + fm100_etki_dk, fm50_etki_dk, fm100_etki_dk, gece_etki_dk, 0
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
                                         tatil_gun, fazla_mesai_dk, fm50_dk, fm100_dk, gece_calisma_dk, saatlik_izin_dk)
        select p_donem_id, calisan_id, 'fark', kaynak_donem_id,
               sum(calisilan_gun), sum(calisma_dk), sum(gec_kalma_dk), sum(erken_cikis_dk), sum(devamsiz_gun),
               sum(izinli_gun), sum(raporlu_gun), sum(tatil_gun), sum(fazla_mesai_dk),
               sum(fm50_dk), sum(fm100_dk), sum(gece_calisma_dk), sum(saatlik_izin_dk)
        from farklar
        group by calisan_id, kaynak_donem_id
        -- Etkisi olmayan düzeltme (ör. aynı değer) satır üretmez
        having sum(abs(calisilan_gun)) + sum(abs(calisma_dk)) + sum(abs(gec_kalma_dk)) + sum(abs(erken_cikis_dk))
             + sum(abs(devamsiz_gun)) + sum(abs(izinli_gun)) + sum(abs(raporlu_gun)) + sum(abs(tatil_gun))
             + sum(abs(fazla_mesai_dk)) + sum(abs(gece_calisma_dk)) + sum(abs(saatlik_izin_dk)) > 0
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
-- 14. Ay kilidi: İK kararı bekleyen onaysız fazla mesai de kilidi durdurur
-- ---------------------------------------------------------------------
create or replace function pdks.ay_kilitle(p_yil smallint, p_ay smallint, p_zorla boolean default false)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben     bigint := pdks.yetki_gerekli('ik');
    v_donem   bigint := pdks.donem_bul(make_date(p_yil, p_ay, 1));
    v_bekleyen integer;
begin
    select count(*) into v_bekleyen
    from pdks.fazla_mesai_inceleme
    where durum = 'inceleme_bekliyor'
      and is_gunu between make_date(p_yil, p_ay, 1) and (make_date(p_yil, p_ay, 1) + interval '1 month - 1 day')::date;
    if v_bekleyen > 0 and not p_zorla then
        raise exception '%/% döneminde İK kararı bekleyen % onaysız fazla mesai var.', p_ay, p_yil, v_bekleyen;
    end if;
    perform pdks.donem_kilitle(v_donem, v_ben, p_zorla);
    perform pdks.puantaj_yaz(v_donem);
end;
$$;

-- ---------------------------------------------------------------------
-- 15. Ekran fonksiyonları (İK)
-- ---------------------------------------------------------------------

-- Onaysız fazla mesaiye karar: onay puantaja girer (kilitli ayda sonraki aya fark),
-- ret çalışan aleyhine olduğu için gerekçe zorunlu. Sınır aşılsa da onay engellenmez
-- (iş yapılmıştır); yıllık sınır aşılırsa İK'ya uyarı yazılır.
create function pdks.fazla_mesai_inceleme_karar(p_inceleme_id bigint, p_onay boolean, p_aciklama text default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben     bigint := pdks.yetki_gerekli('ik');
    v_kayit   pdks.fazla_mesai_inceleme;
    g         pdks.gun_kaydi;
    v_once    record;
    v_sonra   record;
    v_kilitli boolean;
    v_toplam  integer;
begin
    select * into v_kayit from pdks.fazla_mesai_inceleme where id = p_inceleme_id for update;
    if not found then
        raise exception 'İnceleme kaydı bulunamadı.';
    end if;
    if v_kayit.durum <> 'inceleme_bekliyor' then
        raise exception 'Bu kayıt zaten karara bağlanmış.';
    end if;
    if p_onay is null then
        raise exception 'Karar (onay / ret) belirtilmeli.';
    end if;

    if not p_onay then
        if p_aciklama is null or length(trim(p_aciklama)) < 5 then
            raise exception 'Ret gerekçesi yazılmalı (en az 5 karakter).';
        end if;
        update pdks.fazla_mesai_inceleme
        set durum = 'reddedildi', karar_veren_id = v_ben, karar_aciklama = trim(p_aciklama)
        where id = p_inceleme_id;
        return;
    end if;

    select * into g from pdks.gun_kaydi where id = v_kayit.gun_kaydi_id;
    select * into v_once from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                              g.giris_zamani, g.cikis_zamani);
    update pdks.fazla_mesai_inceleme
    set durum = 'onaylandi', karar_veren_id = v_ben, karar_aciklama = nullif(trim(p_aciklama), '')
    where id = p_inceleme_id;
    select * into v_sonra from pdks.gun_hesabi(g.calisan_id, g.is_gunu, g.planli_baslangic, g.planli_bitis,
                                               g.giris_zamani, g.cikis_zamani);

    v_kilitli := pdks.donem_kilitli_mi(g.is_gunu);
    update pdks.fazla_mesai_inceleme
    set fm50_etki_dk    = v_sonra.fm50_dk - v_once.fm50_dk,
        fm100_etki_dk   = v_sonra.fm100_dk - v_once.fm100_dk,
        calisma_etki_dk = v_sonra.calisma_dk - v_once.calisma_dk,
        gece_etki_dk    = v_sonra.gece_calisma_dk - v_once.gece_calisma_dk,
        fark_satiri     = v_kilitli,
        hedef_donem_id  = pdks.hedef_donem(g.is_gunu)
    where id = p_inceleme_id;

    if not v_kilitli then
        perform pdks.gun_hesabini_yenile(g.id);
    end if;

    -- Yıllık sınır: onaylı planlar + onaylanan havuz kayıtları
    select coalesce((select sum(planli_dk) from pdks.fazla_mesai_plani
                     where calisan_id = g.calisan_id and durum = 'onaylandi'
                       and extract(year from is_gunu) = extract(year from g.is_gunu)), 0)
         + coalesce((select sum(dakika) from pdks.fazla_mesai_inceleme
                     where calisan_id = g.calisan_id and durum = 'onaylandi'
                       and extract(year from is_gunu) = extract(year from g.is_gunu)), 0)
      into v_toplam;
    if v_toplam > pdks.ayar_al('fm_yillik_sinir_dk') then
        perform pdks.uyari_yaz('fm_yillik_sinir_asildi', 'havuz:' || p_inceleme_id,
            format('%s yılı onaylı fazla mesai %s dk; yıllık sınır %s dk (270 saat).',
                   extract(year from g.is_gunu), v_toplam, pdks.ayar_al('fm_yillik_sinir_dk')),
            g.calisan_id);
    end if;
end;
$$;

-- Saatlik izin girer (vizite dahil); hesabı yapılmış gün yeniden hesaplanır
create function pdks.saatlik_izin_gir(p_calisan_id bigint, p_tarih date, p_baslangic timestamptz,
                                      p_bitis timestamptz, p_tur text, p_aciklama text default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
    v_id   bigint;
    v_gun  bigint;
begin
    if p_baslangic is null or p_bitis is null or p_bitis <= p_baslangic then
        raise exception 'İzin bitişi başlangıçtan sonra olmalı.';
    end if;
    if exists (select 1 from pdks.saatlik_izin
               where calisan_id = p_calisan_id and tarih = p_tarih
                 and tstzrange(baslangic, bitis) && tstzrange(p_baslangic, p_bitis)) then
        raise exception 'Bu saat aralığında başka bir saatlik izin var.';
    end if;

    insert into pdks.saatlik_izin (calisan_id, tarih, baslangic, bitis, tur, aciklama, giren_id)
    values (p_calisan_id, p_tarih, p_baslangic, p_bitis, p_tur, nullif(trim(p_aciklama), ''), v_ben)
    returning id into v_id;

    select id into v_gun from pdks.gun_kaydi where calisan_id = p_calisan_id and is_gunu = p_tarih;
    if v_gun is not null then
        perform pdks.gun_hesabini_yenile(v_gun);
        perform pdks.gun_sonrasi_kontroller(v_gun);
    end if;
    return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 16. RLS ve yetkiler
-- ---------------------------------------------------------------------
alter table pdks.saatlik_izin          enable row level security;
alter table pdks.fazla_mesai_inceleme  enable row level security;
alter table pdks.puantaj_kalemi        enable row level security;

create policy ik_yonetici_okur on pdks.saatlik_izin         for select to authenticated using (pdks.tum_veriyi_gorur());
create policy ik_yonetici_okur on pdks.fazla_mesai_inceleme for select to authenticated using (pdks.tum_veriyi_gorur());
create policy ik_yonetici_okur on pdks.puantaj_kalemi       for select to authenticated using (pdks.tum_veriyi_gorur());
create policy amir_okur on pdks.fazla_mesai_inceleme for select to authenticated
    using (pdks.amirin_calisani_mi(calisan_id));

grant select on pdks.saatlik_izin, pdks.fazla_mesai_inceleme, pdks.puantaj_kalemi,
                pdks.v_saatlik_izin_amir to authenticated;

revoke execute on function
    pdks.saatlik_izin_kontrol(), pdks.fazla_mesai_inceleme_kontrol(),
    pdks.fm100_gunu_mu(date), pdks.dakika_toplami(tstzmultirange), pdks.aralik(timestamptz, timestamptz),
    pdks.saatlik_izin_araligi(bigint, date), pdks.gece_araligi(date),
    pdks.tolerans_uygula(integer, integer, integer), pdks.hedef_donem(date),
    pdks.gun_hesabi(bigint, date, timestamptz, timestamptz, timestamptz, timestamptz),
    pdks.gun_hesabini_yenile(bigint), pdks.gun_sonrasi_kontroller(bigint),
    pdks.gun_kod_satirlari(bigint, date, text, integer, integer, integer),
    pdks.gun_kodlari_hesapla(integer, integer),
    pdks.gun_katkisi(bigint, bigint[]), pdks.puantaj_yaz(bigint),
    pdks.gece_isi_gun_kayitlari(date, bigint), pdks.gece_isi_hesapla()
from public, anon, authenticated;

revoke execute on function
    pdks.gun_kodlari(integer, integer),
    pdks.fazla_mesai_inceleme_karar(bigint, boolean, text),
    pdks.saatlik_izin_gir(bigint, date, timestamptz, timestamptz, text, text)
from public, anon;
grant execute on function
    pdks.gun_kodlari(integer, integer),
    pdks.fazla_mesai_inceleme_karar(bigint, boolean, text),
    pdks.saatlik_izin_gir(bigint, date, timestamptz, timestamptz, text, text)
to authenticated;
