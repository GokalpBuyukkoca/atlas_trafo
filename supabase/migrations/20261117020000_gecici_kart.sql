-- =====================================================================
-- Geçici kart ve zimmet (sorun 4, İK'nın 6. maddesi: kart unutmada
-- alternatif doğrulama)
--
-- Kartını unutan çalışan güvenliğe gider; güvenlik ona kayıtlı (zimmetli)
-- bir geçici kart verir. Gün boyu PDKS, kapı ve yemekhanede bu kartla okutur.
-- Gece işi geçici kartın okutmalarını zimmet kaydına bakarak doğru çalışana
-- bağlar; amire soru gitmez. Akşam kart iade edilir.
--
-- Kurallar (veritabanı zorlar):
--   * Geçici kart numarası asıl kart numaralarıyla çakışamaz.
--   * İade edilmemiş geçici kart başkasına verilemez.
--   * Bir çalışanda aynı anda tek geçici kart olur.
--   * Zimmet aralıkları üst üste binemez (geriye dönük girişte de).
--   * Zimmeti yalnızca güvenlik ya da İK verir ve iade alır.
--   * Zimmet kaydı silinemez; yalnızca iade bilgisi bir kez yazılır.
--
-- Uyarılar (gece işi pdks.gecici_kart_kontrol(gün) ile üretir, ceza yok):
--   * gecici_kart_cakisma        : geçici kart zimmetliyken çalışanın asıl kartı da okutuldu
--   * gecici_kart_zimmetsiz      : geçici kart, zimmet dışındaki bir saatte okutuldu
--   * gecici_kart_iade_edilmedi  : zimmet ayardaki saatten uzun süredir açık
--   * sik_kart_unutma (mevcut)   : çalışan ayda eşik kadar ya da fazla geçici kart aldı
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Yardımcı: CHECK listesine değer ekleme
--    Kısıtın güncel hâli okunur; yalnızca yeni değerler eklenir. Böylece
--    başka migration'ların eklediği değerler korunur. İş bitince silinir.
-- ---------------------------------------------------------------------
create function pdks.gecici_kisit_genislet(p_tablo regclass, p_kisit text, p_kolon text, p_yeni text[])
returns void
language plpgsql
as $$
declare
    v_tanim   text;
    v_degerler text[];
begin
    select pg_get_constraintdef(oid) into v_tanim
    from pg_constraint where conrelid = p_tablo and conname = p_kisit;
    if v_tanim is null then
        raise exception '% kısıtı bulunamadı', p_kisit;
    end if;
    select array_agg(m[1] order by ord) into v_degerler
    from regexp_matches(v_tanim, '''([a-z_]+)''', 'g') with ordinality as r(m, ord);
    if coalesce(array_length(v_degerler, 1), 0) < 2 then
        raise exception '% kısıtı okunamadı: %', p_kisit, v_tanim;
    end if;
    select array_agg(d) into v_degerler
    from (select unnest(v_degerler) as d
          union
          select unnest(p_yeni)) x;
    execute format('alter table %s drop constraint %I', p_tablo, p_kisit);
    execute format('alter table %s add constraint %I check (%I in (%s))',
                   p_tablo, p_kisit, p_kolon,
                   (select string_agg(quote_literal(d), ', ' order by d) from unnest(v_degerler) d));
end;
$$;

-- Güvenlik görevlisi rolü (zimmeti verir ve iade alır)
select pdks.gecici_kisit_genislet('pdks.kullanici', 'kullanici_rol_check', 'rol', array['guvenlik']);

-- Yeni uyarı türleri (kart paylaşımı türü bir sonraki migration'da eklenir)
select pdks.gecici_kisit_genislet('pdks.uyari', 'uyari_tur_check', 'tur',
    array['gecici_kart_cakisma', 'gecici_kart_zimmetsiz', 'gecici_kart_iade_edilmedi']);

drop function pdks.gecici_kisit_genislet(regclass, text, text, text[]);

-- ---------------------------------------------------------------------
-- 1) Uyarıların tekrar yazılmaması için tekillik anahtarı
--    Gece işi aynı günü iki kez işlerse aynı uyarı ikinci kez oluşmaz.
--    (Eski uyarılarda boş kalır; kısıt yalnızca dolu olanlara uygulanır.)
-- ---------------------------------------------------------------------
alter table pdks.uyari add column tekillik_anahtari text;
create unique index uyari_tekil on pdks.uyari (tur, tekillik_anahtari)
    where tekillik_anahtari is not null;

-- ---------------------------------------------------------------------
-- 2) Geçici kartlar
-- ---------------------------------------------------------------------
create table pdks.gecici_kart (
    id                bigint generated always as identity primary key,
    kart_no           text not null unique check (length(trim(kart_no)) > 0),
    durum             text not null default 'aktif' check (durum in ('aktif', 'kayip', 'iptal')),
    olusturma_zamani  timestamptz not null default now()
);
comment on table pdks.gecici_kart is
    'Güvenlikte duran geçici kartlar (ör. GK-03). Belirli bir kişiye ait değildir; kimde olduğu zimmetten bulunur.';

-- Geçici kart numarası asıl kart numarasıyla çakışamaz (iki yönde de)
create function pdks.kart_no_cakisma_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if tg_table_name = 'gecici_kart'
       and exists (select 1 from pdks.kart where kart_no = new.kart_no) then
        raise exception '% numarası bir çalışanın asıl kartı; geçici kart olamaz.', new.kart_no;
    end if;
    if tg_table_name = 'kart'
       and exists (select 1 from pdks.gecici_kart where kart_no = new.kart_no) then
        raise exception '% numarası geçici kart olarak kayıtlı; asıl kart olamaz.', new.kart_no;
    end if;
    return new;
end;
$$;
create trigger gecici_kart_no_kontrol before insert or update of kart_no on pdks.gecici_kart
    for each row execute function pdks.kart_no_cakisma_kontrol();
create trigger kart_no_gecici_kontrol before insert or update of kart_no on pdks.kart
    for each row execute function pdks.kart_no_cakisma_kontrol();

-- ---------------------------------------------------------------------
-- 3) Zimmet: hangi geçici kart, kime, kim verdi, ne zaman, ne zaman iade
-- ---------------------------------------------------------------------
create table pdks.gecici_kart_zimmet (
    id               bigint generated always as identity primary key,
    gecici_kart_id   bigint not null references pdks.gecici_kart (id),
    calisan_id       bigint not null references pdks.calisan (id),
    verilis_zamani   timestamptz not null default now(),
    veren_id         bigint not null references pdks.kullanici (id),
    iade_zamani      timestamptz,
    iade_alan_id     bigint references pdks.kullanici (id),
    aciklama         text,
    check ((iade_zamani is null) = (iade_alan_id is null)),
    check (iade_zamani is null or iade_zamani > verilis_zamani)
);
comment on table pdks.gecici_kart_zimmet is
    'Geçici kart zimmeti. Silinemez; iade bilgisi yalnızca bir kez yazılır.';

-- İade edilmemiş kart başkasına verilemez; bir çalışanda aynı anda tek geçici kart
create unique index zimmet_acik_kart on pdks.gecici_kart_zimmet (gecici_kart_id) where iade_zamani is null;
create unique index zimmet_acik_calisan on pdks.gecici_kart_zimmet (calisan_id) where iade_zamani is null;
create index zimmet_kart_zaman on pdks.gecici_kart_zimmet (gecici_kart_id, verilis_zamani);
create index zimmet_calisan_zaman on pdks.gecici_kart_zimmet (calisan_id, verilis_zamani);

create function pdks.gecici_kart_zimmet_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_rol text;
begin
    if tg_op = 'DELETE' then
        raise exception 'Zimmet kaydı silinemez.';
    end if;

    if tg_op = 'INSERT' then
        v_rol := pdks.kullanici_rolu(new.veren_id);
        if v_rol is null or v_rol not in ('guvenlik', 'ik') then
            raise exception 'Geçici kartı yalnızca güvenlik ya da İK verebilir.';
        end if;
        if (select durum from pdks.gecici_kart where id = new.gecici_kart_id) <> 'aktif' then
            raise exception 'Bu geçici kart kayıp ya da iptal; verilemez.';
        end if;
        if new.iade_zamani is not null then
            raise exception 'Zimmet iade edilmiş olarak girilemez; önce verilir, sonra iade alınır.';
        end if;
    end if;

    if tg_op = 'UPDATE' then
        if old.iade_zamani is not null then
            raise exception 'İade edilmiş zimmet değiştirilemez.';
        end if;
        if new.gecici_kart_id is distinct from old.gecici_kart_id
           or new.calisan_id is distinct from old.calisan_id
           or new.verilis_zamani is distinct from old.verilis_zamani
           or new.veren_id is distinct from old.veren_id then
            raise exception 'Zimmetin kendisi değiştirilemez; yalnızca iade bilgisi yazılır.';
        end if;
        if new.iade_zamani is not null then
            v_rol := pdks.kullanici_rolu(new.iade_alan_id);
            if v_rol is null or v_rol not in ('guvenlik', 'ik') then
                raise exception 'Geçici kartın iadesini yalnızca güvenlik ya da İK alabilir.';
            end if;
        end if;
    end if;

    -- Zimmet aralıkları üst üste binemez (aynı kart ya da aynı çalışan için)
    if exists (
        select 1 from pdks.gecici_kart_zimmet z
        where z.id <> coalesce(new.id, -1)
          and (z.gecici_kart_id = new.gecici_kart_id or z.calisan_id = new.calisan_id)
          and tstzrange(z.verilis_zamani, coalesce(z.iade_zamani, 'infinity'::timestamptz))
              && tstzrange(new.verilis_zamani, coalesce(new.iade_zamani, 'infinity'::timestamptz))
    ) then
        raise exception 'Bu zimmet, aynı kartın ya da aynı çalışanın başka bir zimmetiyle çakışıyor.';
    end if;

    return new;
end;
$$;
create trigger gecici_kart_zimmet_kontrol
    before insert or update or delete on pdks.gecici_kart_zimmet
    for each row execute function pdks.gecici_kart_zimmet_kontrol();
create trigger gecici_kart_zimmet_truncate
    before truncate on pdks.gecici_kart_zimmet
    for each statement execute function pdks.degistirilemez();

-- ---------------------------------------------------------------------
-- 4) Okutmanın sahibi: kart numarası + zaman → çalışan
--    Asıl kartsa sahibi; geçici kartsa o anda zimmetli olduğu çalışan.
--    Gece işi PDKS ve kanıt okutmalarını çalışana bu fonksiyonla bağlar.
-- ---------------------------------------------------------------------
create function pdks.okutma_sahibi(p_kart_no text, p_zaman timestamptz)
returns bigint
language sql
stable
set search_path = pdks
as $$
    select coalesce(
        (select k.calisan_id from pdks.kart k where k.kart_no = p_kart_no),
        (select z.calisan_id
         from pdks.gecici_kart g
         join pdks.gecici_kart_zimmet z on z.gecici_kart_id = g.id
         where g.kart_no = p_kart_no
           and p_zaman >= z.verilis_zamani
           and (z.iade_zamani is null or p_zaman < z.iade_zamani))
    );
$$;

-- ---------------------------------------------------------------------
-- 5) Gece işi kontrolü: bir günün geçici kart uyarıları
--    Tekrar çalıştırılınca aynı uyarıyı ikinci kez yazmaz. Yazdığı uyarı sayısını döner.
-- ---------------------------------------------------------------------
create function pdks.gecici_kart_kontrol(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_bas    timestamptz := (p_gun::timestamp at time zone 'Europe/Istanbul');
    v_bit    timestamptz := ((p_gun + 1)::timestamp at time zone 'Europe/Istanbul');
    v_say    integer := 0;
    v_n      integer;
    v_esik   integer := pdks.ayar_al('sik_kart_unutma_esigi');
    v_iade_s integer := pdks.ayar_al('gecici_kart_iade_saat');
begin
    -- a) Geçici kart zimmetliyken çalışanın asıl kartı da okutuldu (PDKS ya da kanıt)
    insert into pdks.uyari (tur, calisan_id, okuyucu_id, mesaj, tekillik_anahtari)
    select distinct on (z.id)
           'gecici_kart_cakisma', z.calisan_id, o.okuyucu_id,
           format('Çalışanın geçici kartı (%s) zimmetliyken asıl kartı (%s) %s saatinde okutuldu. Kartı başkası kullanıyor olabilir; İK incelemeli.',
                  g.kart_no, k.kart_no, to_char(o.okutma_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')),
           'zimmet:' || z.id
    from pdks.gecici_kart_zimmet z
    join pdks.gecici_kart g on g.id = z.gecici_kart_id
    join pdks.kart k on k.calisan_id = z.calisan_id
    join (select okuyucu_id, kart_no, okutma_zamani from pdks.ham_okutma
          union all
          select okuyucu_id, kart_no, okutma_zamani from pdks.kanit_kaydi) o
      on o.kart_no = k.kart_no
     and o.okutma_zamani >= z.verilis_zamani
     and (z.iade_zamani is null or o.okutma_zamani < z.iade_zamani)
    where o.okutma_zamani >= v_bas and o.okutma_zamani < v_bit
    order by z.id, o.okutma_zamani
    on conflict (tur, tekillik_anahtari) where tekillik_anahtari is not null do nothing;
    get diagnostics v_n = row_count; v_say := v_say + v_n;

    -- b) Geçici kart zimmet dışındaki bir saatte okutuldu
    insert into pdks.uyari (tur, okuyucu_id, mesaj, tekillik_anahtari)
    select 'gecici_kart_zimmetsiz', o.okuyucu_id,
           format('Geçici kart %s, kimseye zimmetli değilken %s saatinde okutuldu.',
                  o.kart_no, to_char(o.okutma_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')),
           'okutma:' || o.kaynak || ':' || o.id
    from (select 'pdks' as kaynak, id, okuyucu_id, kart_no, okutma_zamani from pdks.ham_okutma
          union all
          select 'kanit', id, okuyucu_id, kart_no, okutma_zamani from pdks.kanit_kaydi) o
    join pdks.gecici_kart g on g.kart_no = o.kart_no
    where o.okutma_zamani >= v_bas and o.okutma_zamani < v_bit
      and pdks.okutma_sahibi(o.kart_no, o.okutma_zamani) is null
    on conflict (tur, tekillik_anahtari) where tekillik_anahtari is not null do nothing;
    get diagnostics v_n = row_count; v_say := v_say + v_n;

    -- c) Zimmet, ayardaki saatten uzun süredir iade edilmedi (gün sonuna göre)
    insert into pdks.uyari (tur, calisan_id, mesaj, tekillik_anahtari)
    select 'gecici_kart_iade_edilmedi', z.calisan_id,
           format('Geçici kart %s, %s tarihinden beri iade edilmedi.',
                  g.kart_no, to_char(z.verilis_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')),
           'zimmet:' || z.id
    from pdks.gecici_kart_zimmet z
    join pdks.gecici_kart g on g.id = z.gecici_kart_id
    where z.iade_zamani is null
      and z.verilis_zamani < v_bit - make_interval(hours => v_iade_s)
    on conflict (tur, tekillik_anahtari) where tekillik_anahtari is not null do nothing;
    get diagnostics v_n = row_count; v_say := v_say + v_n;

    -- d) Ayda eşik kadar ya da fazla geçici kart alan çalışan (bilgi, ceza değil)
    insert into pdks.uyari (tur, calisan_id, mesaj, tekillik_anahtari)
    select 'sik_kart_unutma', z.calisan_id,
           format('Çalışan %s ayında %s kez geçici kart aldı (eşik %s). Bilgi amaçlıdır.',
                  to_char(p_gun, 'MM.YYYY'), count(*), v_esik),
           'gecici:' || to_char(p_gun, 'YYYY-MM') || ':' || z.calisan_id
    from pdks.gecici_kart_zimmet z
    where z.verilis_zamani >= (date_trunc('month', p_gun)::timestamp at time zone 'Europe/Istanbul')
      and z.verilis_zamani < v_bit
    group by z.calisan_id
    having count(*) >= v_esik
    on conflict (tur, tekillik_anahtari) where tekillik_anahtari is not null do nothing;
    get diagnostics v_n = row_count; v_say := v_say + v_n;

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 6) Ayar
-- ---------------------------------------------------------------------
insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('gecici_kart_iade_saat', 16, 'saat', 'Sorun 4: geçici kart bu kadar saattir iade edilmediyse İK''ya uyarı');

-- ---------------------------------------------------------------------
-- 7) Yetkiler
--    Yeni tablolara 0300'deki "tümünü okur" yetkisi kendiliğinden geçmez.
-- ---------------------------------------------------------------------
grant select on pdks.gecici_kart, pdks.gecici_kart_zimmet to pdks_uygulama, pdks_gece_isi;
grant insert, update on pdks.gecici_kart, pdks.gecici_kart_zimmet to pdks_uygulama;
grant execute on function pdks.okutma_sahibi(text, timestamptz) to pdks_uygulama, pdks_gece_isi;
grant execute on function pdks.gecici_kart_kontrol(date) to pdks_gece_isi;
grant execute on function pdks.kart_no_cakisma_kontrol(), pdks.gecici_kart_zimmet_kontrol()
    to pdks_uygulama, pdks_gece_isi;
