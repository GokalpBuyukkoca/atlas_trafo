-- =====================================================================
-- Geçici kart zimmeti: çakışma hatası çakışan zimmeti söyler
--
-- Kural aynı: bir geçici kartın ya da bir çalışanın zimmet aralıkları üst
-- üste binemez. Önceden hata yalnızca "başka bir zimmetle çakışıyor"
-- diyordu; güvenlik görevlisi hangi kayıt olduğunu bulamıyordu. Artık:
--   "GK-01 kartı Osman Doğan'a 24.11.2026 07:25'te verilmiş zimmetle
--    çakışıyor (henüz iade edilmedi)."
-- Türkçe ekler için iki küçük yardımcı:
--   pdks.yonelme_eki('Osman Doğan')   → 'Osman Doğan''a'
--   pdks.saat_eki(07:25)              → '07:25''te'  (okunuşun son sayısına göre)
-- =====================================================================

-- İsme yönelme hâli eki: son ünlüye göre a / e; ünlüyle biterse araya y
create function pdks.yonelme_eki(p_ad text)
returns text
language sql
immutable
as $$
    with s as (
        select lower(translate(trim(p_ad), 'IİÂÎÛ', 'ıiâîû')) as k
    ), son as (
        select k,
               (regexp_match(k, '([aıouâeiöüîû])[^aıouâeiöüîû]*$'))[1] as unlu,
               k ~ '[aıouâeiöüîû]$' as unluyle_biter
        from s
    )
    select trim(p_ad) || '''' ||
           case when unluyle_biter then 'y' else '' end ||
           case when unlu in ('e', 'i', 'ö', 'ü', 'î') then 'e' else 'a' end
    from son;
$$;

-- Saate bulunma hâli eki: "HH:MI" okunuşunun son sayısına göre 'da / 'de / 'ta / 'te
create function pdks.saat_eki(p_zaman timestamptz)
returns text
language sql
stable
as $$
    with z as (
        select to_char(p_zaman at time zone 'Europe/Istanbul', 'HH24:MI') as metin,
               extract(hour from p_zaman at time zone 'Europe/Istanbul')::int as sa,
               extract(minute from p_zaman at time zone 'Europe/Istanbul')::int as dk
    ), sayi as (
        -- Dakika sıfırsa okunan son sayı saattir ("yedi"), değilse dakikadır ("yirmi beş")
        select metin, case when dk = 0 then sa else dk end as n from z
    )
    select metin || '''' ||
           case
               when n = 0 then 'da'                                  -- sıfır
               when n % 10 = 0 then case n / 10 when 1 then 'da'    -- on
                                                 when 2 then 'de'    -- yirmi
                                                 when 3 then 'da'    -- otuz
                                                 when 4 then 'ta'    -- kırk
                                                 else 'de' end       -- elli
               else case n % 10 when 1 then 'de' when 2 then 'de'   -- bir, iki
                                when 3 then 'te' when 4 then 'te'   -- üç, dört
                                when 5 then 'te' when 6 then 'da'   -- beş, altı
                                when 7 then 'de' when 8 then 'de'   -- yedi, sekiz
                                else 'da' end                       -- dokuz
           end
    from sayi;
$$;

create or replace function pdks.gecici_kart_zimmet_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_rol      text;
    v_cakisan  record;
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
    select z.verilis_zamani, z.iade_zamani, gk.kart_no, c.ad || ' ' || c.soyad as ad_soyad
      into v_cakisan
    from pdks.gecici_kart_zimmet z
    join pdks.gecici_kart gk on gk.id = z.gecici_kart_id
    join pdks.calisan c on c.id = z.calisan_id
    where z.id <> coalesce(new.id, -1)
      and (z.gecici_kart_id = new.gecici_kart_id or z.calisan_id = new.calisan_id)
      and tstzrange(z.verilis_zamani, coalesce(z.iade_zamani, 'infinity'::timestamptz))
          && tstzrange(new.verilis_zamani, coalesce(new.iade_zamani, 'infinity'::timestamptz))
    order by z.verilis_zamani
    limit 1;

    if found then
        raise exception '% kartı % % % verilmiş zimmetle çakışıyor (%).',
            v_cakisan.kart_no,
            pdks.yonelme_eki(v_cakisan.ad_soyad),
            to_char(v_cakisan.verilis_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY'),
            pdks.saat_eki(v_cakisan.verilis_zamani),
            case when v_cakisan.iade_zamani is null then 'henüz iade edilmedi'
                 else 'iade: ' || to_char(v_cakisan.iade_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI') end;
    end if;

    return new;
end;
$$;

revoke execute on function pdks.yonelme_eki(text), pdks.saat_eki(timestamptz)
from public, anon, authenticated;
