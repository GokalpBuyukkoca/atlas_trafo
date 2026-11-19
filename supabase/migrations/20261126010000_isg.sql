-- =====================================================================
-- İSG: bölge yetkisi ve İSG belgeleri (kapı kilitlenmez, yalnızca uyarı)
--
--   1. Bölge: okuyucuya bölge atanır (ör. YG Test Laboratuvarı, Boyahane).
--      bolge_yetkisi hangi departmanın hangi bölgeye girebileceğini tutar.
--      Yetkisiz departmandan bir çalışan bölge okuyucusunda okutursa gece işi
--      İK'ya ve İSG uzmanına uyarı yazar (yetkisiz_bolge_okutmasi).
--      Bölge okuyucuları yönsüz kayıt verir: giriş / çıkış saati olarak
--      kullanılmaz, yalnızca "çalışan buradaydı" izi sayılır.
--   2. İSG belgesi (isg_belge): İSG eğitimi ve periyodik sağlık muayenesinin
--      yalnızca geçerlilik bitiş tarihi tutulur; muayene sonucu / teşhis tutulmaz.
--      Yalnızca isg rolü girer; silinmez, değişmez. Yanlış girilen kaydın yerine
--      yeni kayıt girilir: her tür için en son girilen kayıt geçerlidir.
--      Mavi yaka çalışan için gece işi uyarıları:
--        isg_belgesi_yok             : hiç kayıt yokken okuttu
--        isg_belgesi_suresi_dolmus   : süresi dolmuşken okuttu
--        isg_belgesi_suresi_doluyor  : isg_uyari_gun (30) gün içinde dolacak
--   Sistem kimseyi kapıda durdurmaz; karar İK ve İSG uzmanındadır.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Ayar ve uyarı türleri
-- ---------------------------------------------------------------------
insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('isg_uyari_gun', 30, 'gün', 'İSG eğitimi / sağlık muayenesi bitişine bu kadar gün kala uyarı')
on conflict (anahtar) do nothing;

create or replace function pg_temp.kisit_genislet(p_tablo regclass, p_kisit text, p_kolon text, p_yeni text[])
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
    array['isg_belgesi_yok', 'isg_belgesi_suresi_dolmus', 'isg_belgesi_suresi_doluyor', 'yetkisiz_bolge_okutmasi']);
drop function pg_temp.kisit_genislet(regclass, text, text, text[]);

-- ---------------------------------------------------------------------
-- 1. Bölgeler ve bölge yetkisi
-- ---------------------------------------------------------------------
create table pdks.bolge (
    id    smallint generated always as identity primary key,
    kod   text not null unique,
    ad    text not null,
    aktif boolean not null default true
);
comment on table pdks.bolge is 'Giriş yetkisi olan alan (ör. YG Test Laboratuvarı, Boyahane).';

alter table pdks.okuyucu add column bolge_id smallint references pdks.bolge (id);
comment on column pdks.okuyucu.bolge_id is 'Doluysa okuyucu bir bölgenin kapısıdır; okutmalar bölge yetkisiyle karşılaştırılır.';

create table pdks.bolge_yetkisi (
    bolge_id       smallint not null references pdks.bolge (id),
    departman_id   smallint not null references pdks.departman (id),
    veren_id       bigint not null references pdks.kullanici (id),
    verilis_zamani timestamptz not null default now(),
    primary key (bolge_id, departman_id)
);
comment on table pdks.bolge_yetkisi is 'Hangi departmanın hangi bölgeye girebileceği. İSG uzmanı verir / kaldırır.';

-- ---------------------------------------------------------------------
-- 2. İSG belgeleri (yalnızca geçerlilik tarihi)
-- ---------------------------------------------------------------------
create table pdks.isg_belge (
    id                bigint generated always as identity primary key,
    calisan_id        bigint not null references pdks.calisan (id),
    tur               text not null check (tur in ('isg_egitimi', 'saglik_muayenesi')),
    gecerlilik_bitis  date not null,
    belge_no          text,
    giren_id          bigint not null references pdks.kullanici (id),
    giris_zamani      timestamptz not null default now()
);
create index isg_belge_calisan on pdks.isg_belge (calisan_id, tur, id desc);
comment on table pdks.isg_belge is
    'İSG eğitimi / periyodik sağlık muayenesi geçerlilik tarihi. Sonuç ya da teşhis tutulmaz. Her tür için en son girilen geçerlidir. Silinmez.';

create function pdks.isg_belge_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if pdks.kullanici_rolu(new.giren_id) is distinct from 'isg' then
        raise exception 'İSG belgesini yalnızca İSG uzmanı girer.';
    end if;
    new.giris_zamani := now();
    return new;
end;
$$;
create trigger isg_belge_kontrol before insert on pdks.isg_belge
    for each row execute function pdks.isg_belge_kontrol();
create trigger isg_belge_gorev_ayriligi before insert on pdks.isg_belge
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'giren_id');
create trigger isg_belge_degistirilemez before update or delete on pdks.isg_belge
    for each row execute function pdks.degistirilemez();
create trigger isg_belge_bosaltilamaz before truncate on pdks.isg_belge
    for each statement execute function pdks.degistirilemez();

-- Çalışanın her tür için geçerli (en son girilen) belgesi
create view pdks.v_isg_durum
with (security_invoker = true)
as
select c.id as calisan_id, c.sicil_no, d.id as departman_id, d.yaka, t.tur,
       b.id as belge_id, b.gecerlilik_bitis,
       case when b.id is null then 'yok'
            when b.gecerlilik_bitis < current_date then 'dolmus'
            when b.gecerlilik_bitis < current_date + pdks.ayar_al('isg_uyari_gun') then 'doluyor'
            else 'gecerli' end as durum
from pdks.calisan c
join pdks.departman d on d.id = c.departman_id
cross join (values ('isg_egitimi'), ('saglik_muayenesi')) t(tur)
left join lateral (select * from pdks.isg_belge b
                   where b.calisan_id = c.id and b.tur = t.tur
                   order by b.id desc limit 1) b on true
where c.aktif
  -- Belgeyi göremeyen rol (amir, admin) herkesi "yok" görmesin
  and (pdks.tum_veriyi_gorur() or pdks.oturum_rolu() = 'isg');
comment on view pdks.v_isg_durum is 'Çalışan başına İSG eğitimi ve sağlık muayenesi durumu: yok / dolmus / doluyor / gecerli.';

-- ---------------------------------------------------------------------
-- 3. Gece işi kontrolleri
-- ---------------------------------------------------------------------

-- O gün okutması olan mavi yaka çalışanların İSG belgeleri + 30 gün kala uyarı
create function pdks.isg_kontrol(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_bas  timestamptz := (p_gun::timestamp at time zone 'Europe/Istanbul');
    v_bit  timestamptz := ((p_gun + 1)::timestamp at time zone 'Europe/Istanbul');
    v_say  integer := 0;
    v_ad   text;
    r      record;
begin
    for r in
        with okutan as (
            select distinct pdks.okutma_sahibi(h.kart_no, h.okutma_zamani) as calisan_id
            from pdks.ham_okutma h
            where h.okutma_zamani >= v_bas and h.okutma_zamani < v_bit and not pdks.okutma_gecersiz_mi(h.id)
            union
            select distinct pdks.okutma_sahibi(k.kart_no, k.okutma_zamani)
            from pdks.kanit_kaydi k
            where k.okutma_zamani >= v_bas and k.okutma_zamani < v_bit
        )
        select c.id as calisan_id, c.sicil_no, t.tur, b.id as belge_id, b.gecerlilik_bitis
        from okutan o
        join pdks.calisan c on c.id = o.calisan_id
        join pdks.departman d on d.id = c.departman_id and d.yaka = 'mavi'
        cross join (values ('isg_egitimi'), ('saglik_muayenesi')) t(tur)
        left join lateral (select * from pdks.isg_belge b
                           where b.calisan_id = c.id and b.tur = t.tur
                           order by b.id desc limit 1) b on true
        where b.id is null or b.gecerlilik_bitis < p_gun
    loop
        v_ad := case r.tur when 'isg_egitimi' then 'İSG eğitimi' else 'periyodik sağlık muayenesi' end;
        if r.belge_id is null then
            v_say := v_say + pdks.uyari_yaz('isg_belgesi_yok', 'isg_yok:' || r.calisan_id || ':' || r.tur,
                format('%s: %s kaydı yok; çalışan %s günü okuttu. Kapı kilitlenmedi.',
                       r.sicil_no, v_ad, to_char(p_gun, 'DD.MM.YYYY')), r.calisan_id);
        else
            v_say := v_say + pdks.uyari_yaz('isg_belgesi_suresi_dolmus', 'isg_dolmus:' || r.belge_id,
                format('%s: %s süresi %s tarihinde doldu; çalışan %s günü okuttu. Kapı kilitlenmedi.',
                       r.sicil_no, v_ad, to_char(r.gecerlilik_bitis, 'DD.MM.YYYY'), to_char(p_gun, 'DD.MM.YYYY')),
                r.calisan_id);
        end if;
    end loop;

    -- Süresi yakında dolacaklar (okutma gerekmez)
    for r in
        select c.id as calisan_id, c.sicil_no, b.tur, b.id as belge_id, b.gecerlilik_bitis
        from pdks.calisan c
        join pdks.departman d on d.id = c.departman_id and d.yaka = 'mavi'
        cross join lateral (select distinct on (x.tur) x.* from pdks.isg_belge x
                            where x.calisan_id = c.id order by x.tur, x.id desc) b
        where c.aktif
          and b.gecerlilik_bitis >= p_gun and b.gecerlilik_bitis < p_gun + pdks.ayar_al('isg_uyari_gun')
    loop
        v_say := v_say + pdks.uyari_yaz('isg_belgesi_suresi_doluyor', 'isg_doluyor:' || r.belge_id,
            format('%s: %s %s tarihinde doluyor.', r.sicil_no,
                   case r.tur when 'isg_egitimi' then 'İSG eğitimi' else 'periyodik sağlık muayenesi' end,
                   to_char(r.gecerlilik_bitis, 'DD.MM.YYYY')),
            r.calisan_id);
    end loop;
    return v_say;
end;
$$;

-- Bölge okuyucusunda, departmanının yetkisi olmayan çalışanın okutması
create function pdks.bolge_kontrol(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_bas  timestamptz := (p_gun::timestamp at time zone 'Europe/Istanbul');
    v_bit  timestamptz := ((p_gun + 1)::timestamp at time zone 'Europe/Istanbul');
    v_say  integer := 0;
    r      record;
begin
    for r in
        with okutmalar as (
            select 'ham:' || h.id as anahtar, h.okuyucu_id, h.kart_no, h.okutma_zamani
            from pdks.ham_okutma h
            where h.okutma_zamani >= v_bas and h.okutma_zamani < v_bit
            union all
            select 'kanit:' || k.id, k.okuyucu_id, k.kart_no, k.okutma_zamani
            from pdks.kanit_kaydi k
            where k.okutma_zamani >= v_bas and k.okutma_zamani < v_bit
        )
        select o.anahtar, o.okuyucu_id, o.okutma_zamani, c.id as calisan_id, c.sicil_no, b.ad as bolge
        from okutmalar o
        join pdks.okuyucu ok on ok.id = o.okuyucu_id and ok.bolge_id is not null
        join pdks.bolge b on b.id = ok.bolge_id and b.aktif
        join pdks.calisan c on c.id = pdks.okutma_sahibi(o.kart_no, o.okutma_zamani)
        where not exists (select 1 from pdks.bolge_yetkisi y
                          where y.bolge_id = ok.bolge_id and y.departman_id = c.departman_id)
    loop
        v_say := v_say + pdks.uyari_yaz('yetkisiz_bolge_okutmasi', 'bolge:' || r.anahtar,
            format('%s: %s bölgesine yetkisi olmadan okuttu (%s). Kapı kilitlenmedi.',
                   r.sicil_no, r.bolge, to_char(r.okutma_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')),
            r.calisan_id, r.okuyucu_id);
    end loop;
    return v_say;
end;
$$;

-- Gece işi uyarı adımına İSG ve bölge kontrolleri eklendi (diğer kurallar aynı)
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
    v_say := v_say + coalesce(pdks.isg_kontrol(p_gun), 0);
    v_say := v_say + coalesce(pdks.bolge_kontrol(p_gun), 0);

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Ekran fonksiyonları (İSG uzmanı)
-- ---------------------------------------------------------------------
create function pdks.isg_belge_gir(p_calisan_id bigint, p_tur text, p_gecerlilik_bitis date,
                                   p_belge_no text default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('isg');
    v_id   bigint;
begin
    if p_tur not in ('isg_egitimi', 'saglik_muayenesi') then
        raise exception 'Geçersiz belge türü: % (isg_egitimi / saglik_muayenesi)', p_tur;
    end if;
    if p_gecerlilik_bitis is null then
        raise exception 'Geçerlilik bitiş tarihi girilmeli.';
    end if;
    if not exists (select 1 from pdks.calisan where id = p_calisan_id and aktif) then
        raise exception 'Çalışan bulunamadı ya da aktif değil.';
    end if;
    insert into pdks.isg_belge (calisan_id, tur, gecerlilik_bitis, belge_no, giren_id)
    values (p_calisan_id, p_tur, p_gecerlilik_bitis, nullif(trim(p_belge_no), ''), v_ben)
    returning id into v_id;
    return v_id;
end;
$$;

create function pdks.bolge_yetkisi_ver(p_bolge_id smallint, p_departman_id smallint)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('isg');
begin
    if not exists (select 1 from pdks.bolge where id = p_bolge_id) then
        raise exception 'Bölge bulunamadı.';
    end if;
    if not exists (select 1 from pdks.departman where id = p_departman_id) then
        raise exception 'Departman bulunamadı.';
    end if;
    insert into pdks.bolge_yetkisi (bolge_id, departman_id, veren_id)
    values (p_bolge_id, p_departman_id, v_ben)
    on conflict (bolge_id, departman_id) do nothing;
end;
$$;

create function pdks.bolge_yetkisi_kaldir(p_bolge_id smallint, p_departman_id smallint)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('isg');
begin
    delete from pdks.bolge_yetkisi where bolge_id = p_bolge_id and departman_id = p_departman_id;
    if not found then
        raise exception 'Bu departmanın bu bölgede yetkisi yok.';
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. RLS ve yetkiler
--    İK ve yönetici her şeyi görür. İSG uzmanı bölgeleri, okuyucuları, İSG
--    belgelerini ve İSG / bölge uyarılarını görür. Herkes bölge listesini görür.
-- ---------------------------------------------------------------------
alter table pdks.bolge         enable row level security;
alter table pdks.bolge_yetkisi enable row level security;
alter table pdks.isg_belge     enable row level security;

create policy ik_yonetici_okur on pdks.bolge         for select to authenticated using (pdks.tum_veriyi_gorur());
create policy ik_yonetici_okur on pdks.bolge_yetkisi for select to authenticated using (pdks.tum_veriyi_gorur());
create policy ik_yonetici_okur on pdks.isg_belge     for select to authenticated using (pdks.tum_veriyi_gorur());
create policy oturum_acan_okur on pdks.bolge for select to authenticated using (pdks.oturum_kullanici_id() is not null);

create policy isg_okur on pdks.bolge_yetkisi for select to authenticated using (pdks.oturum_rolu() = 'isg');
create policy isg_okur on pdks.isg_belge     for select to authenticated using (pdks.oturum_rolu() = 'isg');
create policy isg_okur on pdks.okuyucu       for select to authenticated using (pdks.oturum_rolu() = 'isg');
create policy isg_okur on pdks.uyari         for select to authenticated
    using (pdks.oturum_rolu() = 'isg'
           and tur in ('isg_belgesi_yok', 'isg_belgesi_suresi_dolmus', 'isg_belgesi_suresi_doluyor',
                       'yetkisiz_bolge_okutmasi'));
create policy admin_okur on pdks.bolge_yetkisi for select to authenticated using (pdks.oturum_rolu() = 'admin');

grant select on pdks.bolge, pdks.bolge_yetkisi, pdks.isg_belge, pdks.v_isg_durum to authenticated;

revoke execute on function
    pdks.isg_belge_kontrol(), pdks.isg_kontrol(date), pdks.bolge_kontrol(date), pdks.gece_isi_uyarilar(date)
from public, anon, authenticated;

revoke execute on function
    pdks.isg_belge_gir(bigint, text, date, text),
    pdks.bolge_yetkisi_ver(smallint, smallint),
    pdks.bolge_yetkisi_kaldir(smallint, smallint)
from public, anon;
grant execute on function
    pdks.isg_belge_gir(bigint, text, date, text),
    pdks.bolge_yetkisi_ver(smallint, smallint),
    pdks.bolge_yetkisi_kaldir(smallint, smallint)
to authenticated;
