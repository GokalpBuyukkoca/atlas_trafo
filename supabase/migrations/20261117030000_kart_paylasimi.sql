-- =====================================================================
-- Kart paylaşımı şüphesi (sorun 6, İK'nın 2. maddesi: kartı birbirinin
-- yerine okutma)
--
-- Senaryo: Veli işe gelmez; Ali, Veli'nin kartını kendi kartının hemen
-- ardından okutur. Tek seferlik ardışık okutma şüphe DEĞİLDİR (vardiya
-- başında okuyucuda sıra olur). Şüphe, aynı iki kişinin kartlarının ay
-- içinde birçok farklı günde arka arkaya okutulmasıdır.
--
-- Kural:
--   Aynı PDKS okuyucusunda, aradaki fark en fazla N saniye olan iki ardışık
--   okutma, iki FARKLI çalışana aitse "ardışık çift" sayılır.
--   Aynı iki çalışan ay içinde en az K farklı günde ardışık çift oluşturursa
--   İK'ya 'kart_paylasim_suphesi' uyarısı gider.
--   N = ayar.kart_paylasim_sn, K = ayar.kart_paylasim_gun
--
-- Kartın sahibi pdks.okutma_sahibi() ile bulunur: geçici kartla okutma da
-- zimmetli çalışana sayılır. Sahibi bulunamayan kartlar dikkate alınmaz.
-- Sistem ceza vermez, kaydı değiştirmez; inceleme ve karar İK'nındır.
-- =====================================================================

-- Uyarı türü (kısıtın güncel listesi korunarak eklenir)
do $$
declare
    v_tanim    text;
    v_degerler text[];
begin
    select pg_get_constraintdef(oid) into v_tanim
    from pg_constraint where conrelid = 'pdks.uyari'::regclass and conname = 'uyari_tur_check';
    select array_agg(d) into v_degerler
    from (select m[1] as d from regexp_matches(v_tanim, '''([a-z_]+)''', 'g') as r(m)
          union
          select 'kart_paylasim_suphesi') x;
    if array_length(v_degerler, 1) < 10 then
        raise exception 'uyari_tur_check kısıtı okunamadı: %', v_tanim;
    end if;
    alter table pdks.uyari drop constraint uyari_tur_check;
    execute format('alter table pdks.uyari add constraint uyari_tur_check check (tur in (%s))',
                   (select string_agg(quote_literal(d), ', ' order by d) from unnest(v_degerler) d));
end;
$$;

insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('kart_paylasim_sn',  5, 'saniye', 'Sorun 6: aynı okuyucuda bu kadar saniye içindeki iki farklı kart "ardışık çift" sayılır'),
    ('kart_paylasim_gun', 5, 'gün',    'Sorun 6: aynı iki çalışan ayda bu kadar farklı günde ardışık çift oluşturursa İK''ya uyarı');

-- ---------------------------------------------------------------------
-- Gece işi kontrolü: verilen günün ayı için ardışık çiftleri sayar.
-- Ay boyunca her gece çalıştırılabilir; aynı çift için ayda tek uyarı yazılır.
-- Yazdığı uyarı sayısını döner.
-- ---------------------------------------------------------------------
create function pdks.kart_paylasim_kontrol(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_ay_bas timestamptz := (date_trunc('month', p_gun)::timestamp at time zone 'Europe/Istanbul');
    v_bit    timestamptz := ((p_gun + 1)::timestamp at time zone 'Europe/Istanbul');
    v_sn     integer := pdks.ayar_al('kart_paylasim_sn');
    v_gun    integer := pdks.ayar_al('kart_paylasim_gun');
    v_say    integer;
begin
    with okutma as (
        select h.okuyucu_id, h.kart_no, h.okutma_zamani,
               pdks.okutma_sahibi(h.kart_no, h.okutma_zamani) as calisan_id
        from pdks.ham_okutma h
        join pdks.okuyucu o on o.id = h.okuyucu_id and o.sistem = 'pdks'
        where h.okutma_zamani >= v_ay_bas and h.okutma_zamani < v_bit
          -- mükerrer işaretli okutmalar sayılmaz
          and not exists (select 1 from pdks.okutma_isareti i
                          where i.ham_okutma_id = h.id and i.isaret = 'mukerrer')
    ),
    sirali as (
        select okuyucu_id, okutma_zamani, calisan_id,
               lag(calisan_id)    over w as onceki_calisan,
               lag(okutma_zamani) over w as onceki_zaman
        from okutma
        window w as (partition by okuyucu_id order by okutma_zamani)
    ),
    ciftler as (
        select least(calisan_id, onceki_calisan)    as a,
               greatest(calisan_id, onceki_calisan) as b,
               (okutma_zamani at time zone 'Europe/Istanbul')::date as gun
        from sirali
        where calisan_id is not null and onceki_calisan is not null
          and calisan_id <> onceki_calisan
          and okutma_zamani - onceki_zaman <= make_interval(secs => v_sn)
    ),
    supheli as (
        select a, b, count(distinct gun) as gun_sayisi
        from ciftler
        group by a, b
        having count(distinct gun) >= v_gun
    )
    insert into pdks.uyari (tur, calisan_id, mesaj, tekillik_anahtari)
    select 'kart_paylasim_suphesi', s.a,
           format('Kart paylaşımı şüphesi: %s (%s %s) ve %s (%s %s) kartları %s ayında %s farklı günde %s saniye içinde arka arkaya okutuldu. Ceza değildir; İK incelemeli.',
                  c1.sicil_no, c1.ad, c1.soyad, c2.sicil_no, c2.ad, c2.soyad,
                  to_char(p_gun, 'MM.YYYY'), s.gun_sayisi, v_sn),
           'ay:' || to_char(p_gun, 'YYYY-MM') || ':' || s.a || '-' || s.b
    from supheli s
    join pdks.calisan c1 on c1.id = s.a
    join pdks.calisan c2 on c2.id = s.b
    on conflict (tur, tekillik_anahtari) where tekillik_anahtari is not null do nothing;

    get diagnostics v_say = row_count;
    return v_say;
end;
$$;

grant execute on function pdks.kart_paylasim_kontrol(date) to pdks_gece_isi;

-- ---------------------------------------------------------------------
-- Fonksiyon yetkisi temizliği
-- PostgreSQL yeni fonksiyonları varsayılan olarak herkese (PUBLIC) açar.
-- 0300'deki temizlik yalnızca o anki fonksiyonları kapsıyordu; sonradan
-- eklenenler (0500 ve sonrası) için yeniden yapılır. Rollere verilen
-- yetkiler etkilenmez.
-- ---------------------------------------------------------------------
revoke execute on all functions in schema pdks from public;
