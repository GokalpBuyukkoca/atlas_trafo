-- =====================================================================
-- 5: Fazla mesai (İş Kanunu m.41, Fazla Çalışma Yönetmeliği, m.69)
--
--  * Çalışanın o yıl için YAZILI ONAYI yoksa fazla mesai planlanamaz.
--    Onay geri alınabilir; bildirimden 30 gün sonra geçersiz olur.
--  * Fazla mesai önceden planlanır: amir talep eder, İK onaylar/reddeder.
--  * Onay anında sınırlar veritabanında kontrol edilir:
--      - günlük toplam çalışma (vardiya + fazla mesai) <= 11 saat
--      - yıllık onaylı fazla mesai <= 270 saat (takvim yılı)
--      - gece vardiyasına (gece yarısını aşan vardiya) fazla mesai yok (m.69)
--  * Fazla mesai = planlı vardiya bitişinden sonra çalışılan süre (basit tanım;
--    haftalık 45 saat hesabı bu projenin kapsamı dışında).
--  * gun_kaydi.fazla_mesai_dk yalnızca onaylı plan kadar olabilir.
--    Plansız ya da planı aşan çalışma puantaja girmez; gece işi İK'ya uyarı yazar.
--  * Ücret hesaplanmaz; yalnızca dakika tutulur.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Ayarlar (İK ekranından değişir, değişiklik ayar_gecmisi'ne yazılır)
-- ---------------------------------------------------------------------
insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('fm_yillik_sinir_dk',       16200, 'dakika', 'Fazla mesai: yıllık en fazla onaylı fazla mesai (270 saat)'),
    ('gunluk_azami_calisma_dk',  660,   'dakika', 'Fazla mesai: vardiya + fazla mesai günlük toplamı (11 saat)'),
    ('fm_yaklasma_uyari_yuzde',  80,    'yüzde',  'Fazla mesai: yıllık sınırın bu yüzdesine gelince İK''ya uyarı'),
    ('fm_plansiz_esik_dk',       15,    'dakika', 'Fazla mesai: vardiya sonrası bu kadar kalmak plansız çalışma uyarısı sayılmaz');

-- ---------------------------------------------------------------------
-- Yeni uyarı türleri
-- uyari.tur üzerindeki CHECK kısıtını silip genişletilmiş haliyle yeniden ekleriz.
-- (Eski migration dosyasına dokunmadan tabloyu değiştirmenin yolu budur.)
-- ---------------------------------------------------------------------
alter table pdks.uyari drop constraint uyari_tur_check;
alter table pdks.uyari add constraint uyari_tur_check check (tur in (
    'iptal_kart_okutma', 'sik_kart_unutma', 'ariza_suphesi', 'soru_eskale',
    'gece_isi_calismadi', 'dosya_gelmedi', 'pin_kilitlendi', 'geriye_donuk_vardiya',
    'fm_onay_yok',               -- yazılı onayı olmayan çalışan vardiya sonrası kaldı (gece işi)
    'fm_plansiz_calisma',        -- onaylı plan yok ya da plan aşıldı (gece işi)
    'fm_gunluk_sinir_asildi',    -- fiili çalışma 11 saati geçti (gece işi)
    'fm_yillik_sinir_yaklasti',  -- onaylı toplam yıllık sınırın %80'ine geldi (veritabanı)
    'fm_onay_geri_alindi'        -- çalışan yazılı onayını geri aldı (veritabanı)
));

-- ---------------------------------------------------------------------
-- 1) Yıllık yazılı onay
-- Kâğıt onay İK'da saklanır; burada yalnızca arşiv/belge numarası tutulur.
-- ---------------------------------------------------------------------
create table pdks.fazla_mesai_onayi (
    id                         bigint generated always as identity primary key,
    calisan_id                 bigint not null references pdks.calisan (id),
    yil                        smallint not null check (yil between 2000 and 2100),
    imza_tarihi                date not null,
    belge_no                   text not null check (length(trim(belge_no)) > 0),
    giren_id                   bigint not null references pdks.kullanici (id),
    giris_zamani               timestamptz not null default now(),
    -- Geri alma: çalışan 30 gün önceden yazılı bildirir
    geri_alma_bildirim_tarihi  date,
    gecerlilik_bitisi          date generated always as (geri_alma_bildirim_tarihi + 30) stored,
    geri_alma_giren_id         bigint references pdks.kullanici (id),
    unique (calisan_id, yil),
    check (extract(year from imza_tarihi) <= yil),
    check ((geri_alma_bildirim_tarihi is null) = (geri_alma_giren_id is null)),
    check (geri_alma_bildirim_tarihi is null or geri_alma_bildirim_tarihi >= imza_tarihi)
);

-- Verilen gün için geçerli bir yazılı onay var mı?
create or replace function pdks.fm_onay_gecerli_mi(p_calisan_id bigint, p_tarih date)
returns boolean
language sql stable
set search_path = pdks
as $$
    select exists (
        select 1 from pdks.fazla_mesai_onayi o
        where o.calisan_id = p_calisan_id
          and o.yil = extract(year from p_tarih)
          and o.imza_tarihi <= p_tarih
          and (o.gecerlilik_bitisi is null or p_tarih < o.gecerlilik_bitisi)
    );
$$;

create or replace function pdks.fazla_mesai_onayi_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'Yazılı onay silinemez; geri alınır.';
    end if;

    if tg_op = 'INSERT' then
        if pdks.kullanici_rolu(new.giren_id) is distinct from 'ik' then
            raise exception 'Yazılı fazla mesai onayını yalnızca İK girer.';
        end if;
        if new.geri_alma_bildirim_tarihi is not null then
            raise exception 'Onay geri alınmış olarak girilemez; önce onay girilir, sonra geri alınır.';
        end if;
        new.giris_zamani := now();
        return new;
    end if;

    -- UPDATE: yalnızca bir kez, yalnızca geri alma bilgisi girilebilir
    if old.geri_alma_bildirim_tarihi is not null then
        raise exception 'Geri alınmış onay değiştirilemez.';
    end if;
    if (new.calisan_id, new.yil, new.imza_tarihi, new.belge_no, new.giren_id, new.giris_zamani)
       is distinct from
       (old.calisan_id, old.yil, old.imza_tarihi, old.belge_no, old.giren_id, old.giris_zamani) then
        raise exception 'Onayın kendisi değiştirilemez; yalnızca geri alma bilgisi girilir.';
    end if;
    if new.geri_alma_bildirim_tarihi is not null
       and pdks.kullanici_rolu(new.geri_alma_giren_id) is distinct from 'ik' then
        raise exception 'Onayın geri alındığını yalnızca İK girer.';
    end if;
    return new;
end;
$$;
create trigger fazla_mesai_onayi_kontrol before insert or update or delete on pdks.fazla_mesai_onayi
    for each row execute function pdks.fazla_mesai_onayi_kontrol();
create trigger fazla_mesai_onayi_bosaltilamaz before truncate on pdks.fazla_mesai_onayi
    for each statement execute function pdks.degistirilemez();

-- ---------------------------------------------------------------------
-- 2) Fazla mesai planı: amir talep eder, İK onaylar
-- ---------------------------------------------------------------------
create table pdks.fazla_mesai_plani (
    id              bigint generated always as identity primary key,
    calisan_id      bigint not null references pdks.calisan (id),
    is_gunu         date not null,                 -- gun_kaydi.is_gunu ile aynı anlam
    vardiya_id      smallint not null references pdks.vardiya_tanim (id),  -- trigger vardiya_plani'ndan doldurur
    planli_dk       integer not null check (planli_dk > 0),
    gerekce         text not null check (length(trim(gerekce)) >= 5),
    talep_eden_id   bigint not null references pdks.kullanici (id),
    talep_zamani    timestamptz not null default now(),
    durum           text not null default 'talep'
                    check (durum in ('talep', 'onaylandi', 'reddedildi', 'iptal')),
    karar_veren_id  bigint references pdks.kullanici (id),  -- sistem iptalinde boş
    karar_zamani    timestamptz,
    karar_aciklama  text,
    check ((durum = 'talep') = (karar_zamani is null))
);
-- Bir çalışanın bir gününde tek etkin (talep/onaylı) plan olur
create unique index fazla_mesai_plani_tek_etkin on pdks.fazla_mesai_plani (calisan_id, is_gunu)
    where durum in ('talep', 'onaylandi');

-- Vardiyanın süresi (dakika). Gece yarısını aşan vardiyada 24 saat eklenir.
create or replace function pdks.vardiya_suresi_dk(p_vardiya_id smallint)
returns integer
language sql stable
set search_path = pdks
as $$
    select (extract(epoch from (bitis - baslangic)) / 60)::integer
           + case when gece_yarisini_asar then 1440 else 0 end
    from pdks.vardiya_tanim where id = p_vardiya_id;
$$;

-- Yasal kontroller. Hata varsa durur; yoksa bu planla birlikte yıllık onaylı toplamı döndürür.
create or replace function pdks.fm_plan_denetle(
    p_calisan_id  bigint,
    p_is_gunu     date,
    p_vardiya_id  smallint,
    p_planli_dk   integer,
    p_plan_id     bigint
)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_gunluk  integer;
    v_toplam  integer;
    v_sinir   integer := pdks.ayar_al('fm_yillik_sinir_dk');
begin
    -- Aynı çalışan için iki onay aynı anda gelirse ikisi de sınırı göremeden geçmesin:
    -- çalışan satırını kilitleyerek işlemleri sıraya sokarız.
    perform 1 from pdks.calisan where id = p_calisan_id for update;

    if not pdks.fm_onay_gecerli_mi(p_calisan_id, p_is_gunu) then
        raise exception 'Çalışanın % günü için geçerli yazılı fazla mesai onayı yok.', p_is_gunu;
    end if;

    if (select gece_yarisini_asar from pdks.vardiya_tanim where id = p_vardiya_id) then
        raise exception 'Gece vardiyasına fazla mesai planlanamaz (İş Kanunu m.69: gece çalışması 7,5 saati geçemez).';
    end if;

    v_gunluk := pdks.vardiya_suresi_dk(p_vardiya_id) + p_planli_dk;
    if v_gunluk > pdks.ayar_al('gunluk_azami_calisma_dk') then
        raise exception 'Günlük çalışma % dakika olur; sınır % dakika (11 saat).',
            v_gunluk, pdks.ayar_al('gunluk_azami_calisma_dk');
    end if;

    select coalesce(sum(planli_dk), 0) into v_toplam
    from pdks.fazla_mesai_plani
    where calisan_id = p_calisan_id
      and extract(year from is_gunu) = extract(year from p_is_gunu)
      and durum = 'onaylandi'
      and id is distinct from p_plan_id;

    if v_toplam + p_planli_dk > v_sinir then
        raise exception 'Yıllık fazla mesai sınırı aşılır: onaylı % dk + % dk > % dk (kalan % dk).',
            v_toplam, p_planli_dk, v_sinir, v_sinir - v_toplam;
    end if;
    return v_toplam + p_planli_dk;
end;
$$;

create or replace function pdks.fazla_mesai_plani_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_toplam  integer;
    v_esik    integer;
begin
    if tg_op = 'DELETE' then
        raise exception 'Fazla mesai planı silinemez; iptal edilir.';
    end if;

    if pdks.donem_kilitli_mi(case when tg_op = 'INSERT' then new.is_gunu else old.is_gunu end) then
        raise exception '% günü kilitli bir döneme ait; fazla mesai planı değişmez.', new.is_gunu;
    end if;

    -- Yeni talep -------------------------------------------------------
    if tg_op = 'INSERT' then
        if new.durum <> 'talep' then
            raise exception 'Yeni plan "talep" olarak girilir; onayı İK verir.';
        end if;
        if pdks.kullanici_rolu(new.talep_eden_id) not in ('amir', 'ik')
           or pdks.kullanici_rolu(new.talep_eden_id) is null then
            raise exception 'Fazla mesaiyi yalnızca amir ya da İK talep eder.';
        end if;
        select vardiya_id into new.vardiya_id
        from pdks.vardiya_plani where calisan_id = new.calisan_id and tarih = new.is_gunu;
        if new.vardiya_id is null then
            raise exception 'Çalışanın % günü için vardiya planı yok.', new.is_gunu;
        end if;
        new.talep_zamani := now();
        new.karar_veren_id := null;
        new.karar_aciklama := null;
        perform pdks.fm_plan_denetle(new.calisan_id, new.is_gunu, new.vardiya_id, new.planli_dk, new.id);
        return new;
    end if;

    -- Güncelleme: yalnızca durum geçişi ------------------------------
    if (new.calisan_id, new.is_gunu, new.vardiya_id, new.planli_dk, new.gerekce,
        new.talep_eden_id, new.talep_zamani)
       is distinct from
       (old.calisan_id, old.is_gunu, old.vardiya_id, old.planli_dk, old.gerekce,
        old.talep_eden_id, old.talep_zamani) then
        raise exception 'Planın içeriği değiştirilemez; iptal edip yeni talep girin.';
    end if;
    if new.durum = old.durum then
        if new is distinct from old then
            raise exception 'Plan kararı değiştirilemez.';
        end if;
        return new;
    end if;
    if old.durum in ('reddedildi', 'iptal') then
        raise exception 'Karara bağlanmış plan değiştirilemez.';
    end if;
    if old.durum = 'onaylandi' and new.durum <> 'iptal' then
        raise exception 'Onaylı plan yalnızca iptal edilebilir.';
    end if;

    if new.durum in ('onaylandi', 'reddedildi') then
        if pdks.kullanici_rolu(new.karar_veren_id) is distinct from 'ik' then
            raise exception 'Fazla mesai planını yalnızca İK onaylar veya reddeder.';
        end if;
        if new.durum = 'onaylandi' then
            v_toplam := pdks.fm_plan_denetle(new.calisan_id, new.is_gunu, new.vardiya_id, new.planli_dk, new.id);
            v_esik := pdks.ayar_al('fm_yillik_sinir_dk') * pdks.ayar_al('fm_yaklasma_uyari_yuzde') / 100;
            -- Eşiği bu onayla geçtiyse bir kez uyar
            if v_toplam >= v_esik and v_toplam - new.planli_dk < v_esik then
                insert into pdks.uyari (tur, calisan_id, mesaj)
                values ('fm_yillik_sinir_yaklasti', new.calisan_id,
                        format('Yıllık onaylı fazla mesai %s / %s dakikaya ulaştı.',
                               v_toplam, pdks.ayar_al('fm_yillik_sinir_dk')));
            end if;
        end if;
    elsif new.durum = 'iptal' then
        if new.karar_veren_id is null then
            -- Kişisiz (sistem) iptal yalnızca yazılı onay o gün için geçersizse olur
            if pdks.fm_onay_gecerli_mi(new.calisan_id, new.is_gunu) then
                raise exception 'İptal eden kullanıcı belirtilmeli.';
            end if;
        else
            if pdks.kullanici_rolu(new.karar_veren_id) not in ('amir', 'ik')
               or pdks.kullanici_rolu(new.karar_veren_id) is null then
                raise exception 'Planı yalnızca amir ya da İK iptal eder.';
            end if;
            if old.durum = 'onaylandi' and old.is_gunu < current_date then
                raise exception 'Geçmiş bir günün onaylı planı iptal edilemez.';
            end if;
        end if;
    else
        raise exception 'Geçersiz durum geçişi: % -> %', old.durum, new.durum;
    end if;

    new.karar_zamani := now();
    return new;
end;
$$;
create trigger fazla_mesai_plani_kontrol before insert or update or delete on pdks.fazla_mesai_plani
    for each row execute function pdks.fazla_mesai_plani_kontrol();
create trigger fazla_mesai_plani_bosaltilamaz before truncate on pdks.fazla_mesai_plani
    for each statement execute function pdks.degistirilemez();

-- Onay geri alınınca geçersiz günlerdeki planlar iptal olur, İK'ya uyarı gider
create or replace function pdks.fazla_mesai_onayi_geri_alindi()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_say integer;
begin
    update pdks.fazla_mesai_plani
    set durum = 'iptal',
        karar_aciklama = format('Yazılı onay geri alındı (bildirim %s)', new.geri_alma_bildirim_tarihi)
    where calisan_id = new.calisan_id
      and extract(year from is_gunu) = new.yil
      and is_gunu >= new.gecerlilik_bitisi
      and durum in ('talep', 'onaylandi');
    get diagnostics v_say = row_count;

    insert into pdks.uyari (tur, calisan_id, mesaj)
    values ('fm_onay_geri_alindi', new.calisan_id,
            format('Fazla mesai onayı geri alındı; %s tarihinden itibaren geçersiz. %s plan iptal edildi.',
                   new.gecerlilik_bitisi, v_say));
    return null;
end;
$$;
create trigger fazla_mesai_onayi_geri_alindi after update on pdks.fazla_mesai_onayi
    for each row
    when (old.geri_alma_bildirim_tarihi is null and new.geri_alma_bildirim_tarihi is not null)
    execute function pdks.fazla_mesai_onayi_geri_alindi();

-- ---------------------------------------------------------------------
-- 3) Gerçekleşen fazla mesai: gun_kaydi ve puantaj
-- fazla_mesai_dk, gec_kalma_dk gibi gece işinin hesapladığı bir alandır.
-- Veritabanı yalnızca "onaylı plandan fazla olamaz" kuralını korur.
-- ---------------------------------------------------------------------
alter table pdks.gun_kaydi
    add column fazla_mesai_dk integer check (fazla_mesai_dk >= 0);

create or replace function pdks.gun_kaydi_fazla_mesai_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_plan_dk integer;
begin
    if coalesce(new.fazla_mesai_dk, 0) = 0 then
        return new;
    end if;
    select planli_dk into v_plan_dk
    from pdks.fazla_mesai_plani
    where calisan_id = new.calisan_id and is_gunu = new.is_gunu and durum = 'onaylandi';
    if v_plan_dk is null then
        raise exception '% günü için onaylı fazla mesai planı yok; plansız çalışma puantaja yazılmaz (İK''ya uyarı verilir).',
            new.is_gunu;
    end if;
    if new.fazla_mesai_dk > v_plan_dk then
        raise exception 'Fazla mesai % dk, onaylı plan % dk; fazlası puantaja yazılmaz (İK''ya uyarı verilir).',
            new.fazla_mesai_dk, v_plan_dk;
    end if;
    if not pdks.fm_onay_gecerli_mi(new.calisan_id, new.is_gunu) then
        raise exception '% günü için geçerli yazılı fazla mesai onayı yok.', new.is_gunu;
    end if;
    return new;
end;
$$;
create trigger gun_kaydi_fazla_mesai_kontrol before insert or update of fazla_mesai_dk on pdks.gun_kaydi
    for each row execute function pdks.gun_kaydi_fazla_mesai_kontrol();

alter table pdks.puantaj_satiri
    add column fazla_mesai_dk integer not null default 0 check (fazla_mesai_dk >= 0);

-- Canlı puantaja fazla mesai sütunu eklenir. CREATE OR REPLACE VIEW yalnızca
-- SONA sütun eklemeye izin verir; bu yüzden eski sütunlar aynı sırada kalır.
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
       coalesce(sum(g.fazla_mesai_dk), 0)                         as fazla_mesai_dk
from pdks.gun_kaydi g
group by 1, 2, 3;

-- İK ekranı: çalışan başına yıllık fazla mesai durumu
create or replace view pdks.v_fazla_mesai_yillik as
select p.calisan_id,
       extract(year from p.is_gunu)::int                          as yil,
       sum(p.planli_dk)::int                                      as onayli_plan_dk,
       coalesce(sum(g.fazla_mesai_dk), 0)::int                    as gerceklesen_dk,
       pdks.ayar_al('fm_yillik_sinir_dk') - sum(p.planli_dk)::int as kalan_dk
from pdks.fazla_mesai_plani p
left join pdks.gun_kaydi g on g.calisan_id = p.calisan_id and g.is_gunu = p.is_gunu
where p.durum = 'onaylandi'
group by 1, 2;

-- ---------------------------------------------------------------------
-- Yetkiler (yeni tablo ve fonksiyonlar 3. dosyadaki "all tables" yetkisine girmez)
-- ---------------------------------------------------------------------
grant select on pdks.fazla_mesai_onayi, pdks.fazla_mesai_plani, pdks.v_fazla_mesai_yillik
      to pdks_uygulama, pdks_gece_isi;
grant insert, update on pdks.fazla_mesai_onayi, pdks.fazla_mesai_plani to pdks_uygulama;
-- Silme ve boşaltma yetkisi hiç verilmez

grant execute on function pdks.fm_onay_gecerli_mi(bigint, date),
                          pdks.vardiya_suresi_dk(smallint),
                          pdks.fm_plan_denetle(bigint, date, smallint, integer, bigint),
                          pdks.fazla_mesai_onayi_kontrol(),
                          pdks.fazla_mesai_plani_kontrol(),
                          pdks.fazla_mesai_onayi_geri_alindi(),
                          pdks.gun_kaydi_fazla_mesai_kontrol()
      to pdks_uygulama, pdks_gece_isi;
