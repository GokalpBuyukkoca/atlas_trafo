-- =====================================================================
-- Gece işi: bir günün PDKS kayıtlarını işler
--
--   pdks.gece_isi_calistir(gün)  → tek kapı. Adımlar sırayla:
--     1. İşaretleme      : mükerrer, iptal kart, bilinmeyen kart okutmaları
--     2. Gün kaydı       : vardiya planı olan herkese PDKS'den giriş/çıkış
--     3. Arıza şüphesi   : PDKS okuyucusu sessizken kapı kayıtları var
--     4. Kanıtla düzeltme: kapı/servis kaydı varsa eksik saat duzeltme_uygula() ile yazılır
--     5. Amire soru      : kanıt yoksa (ya da giriş kanıtı vardiya başından sonraysa)
--     6. Eskalasyon      : süresi geçen soru üst amire, yoksa İK'ya gider
--     7. Hesap           : geç kalma, erken çıkış, çalışma ve fazla mesai dakikası
--     8. Uyarılar        : fazla mesai, 11 saat, gelmeyen dosya, geçici kart, kart paylaşımı
--   Sistem yalnızca kanıtla düzeltir, soru ve uyarı üretir; devamsızlık kararı vermez.
--
--   Tekrar çalıştırmak güvenlidir: var olan kayıt bozulmaz, yalnızca eksikler eklenir.
--   Bir adımda hata olursa o günün hiçbir değişikliği kalmaz; gece_isi satırı "hatali" olur.
--
--   Veri tamlığı: Bir vardiyanın penceresi ertesi güne taşıyorsa (V2, V3) o günün
--   PDKS dosyası gelmeden gün kaydı açılmaz ve soru sorulmaz. Bu yüzden zamanlama
--   her gece hem dünü hem önceki günü işler.
--
--   pdks.gece_isi_tetikle(başlangıç, bitiş) → demo düğmesi (yalnızca İK)
--   pg_cron: her gece 06:30 (Türkiye) = 03:30 UTC
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Ayar
-- ---------------------------------------------------------------------
insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('ariza_suphe_kisi', 3, 'kişi',
     'Aynı gün bir PDKS okuyucusunda okutması olmayan ama kapı kaydı olan bu kadar kişi varsa arıza şüphesi')
on conflict (anahtar) do nothing;

-- ---------------------------------------------------------------------
-- 1. Soru kime gider?
-- ---------------------------------------------------------------------

-- Konuyla ilgili çalışan dışındaki ilk aktif İK kullanıcısı (görevler ayrılığı)
create function pdks.ik_sorumlusu(p_calisan_id bigint)
returns bigint
language sql
stable
set search_path = pdks
as $$
    select id from pdks.kullanici
    where rol = 'ik' and aktif and calisan_id is distinct from p_calisan_id
    order by id
    limit 1;
$$;

-- Çalışanın departman amiri; amir izinliyse vekili; ikisi de yoksa İK
create function pdks.soru_atanacak(p_calisan_id bigint)
returns bigint
language sql
stable
set search_path = pdks
as $$
    select coalesce(
        (select case when a.izinli_mi and d.vekil_amir_id is not null then d.vekil_amir_id else d.amir_id end
         from pdks.calisan c
         join pdks.departman d on d.id = c.departman_id
         left join pdks.kullanici a on a.id = d.amir_id
         where c.id = p_calisan_id),
        pdks.ik_sorumlusu(p_calisan_id));
$$;

-- Amir kendi hakkındaki soruya atanırsa soru üst amirine gider;
-- üst amiri yoksa İK'ya gider (önceden hata veriyordu).
create or replace function pdks.amir_sorusu_yonlendir()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_calisan bigint;
    v_ust     bigint;
begin
    select calisan_id into v_calisan from pdks.gun_kaydi where id = new.gun_kaydi_id;
    if pdks.kullanici_calisani(new.atanan_id) = v_calisan then
        select ust_amir_id into v_ust from pdks.kullanici where id = new.atanan_id;
        if v_ust is null or pdks.kullanici_calisani(v_ust) = v_calisan then
            v_ust := pdks.ik_sorumlusu(v_calisan);
        end if;
        if v_ust is null then
            raise exception 'Soru amirin kendisiyle ilgili; üst amiri ve İK kullanıcısı tanımlı değil.';
        end if;
        new.atanan_id := v_ust;
    end if;
    return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Yardımcılar
-- ---------------------------------------------------------------------

-- İki an arasındaki tam dakika
create function pdks.dakika(p_bas timestamptz, p_bit timestamptz)
returns integer
language sql
immutable
as $$
    select floor(extract(epoch from (p_bit - p_bas)) / 60)::integer;
$$;

-- Bir zaman aralığının kapsadığı her gün için PDKS dosyası yüklenmiş mi?
create function pdks.pdks_verisi_tam_mi(p_bas timestamptz, p_bit timestamptz)
returns boolean
language sql
stable
set search_path = pdks
as $$
    select not exists (
        select 1
        from generate_series((p_bas at time zone 'Europe/Istanbul')::date,
                             (p_bit at time zone 'Europe/Istanbul')::date,
                             interval '1 day') g
        where not exists (select 1 from pdks.aktarim a
                          where a.kaynak = 'pdks' and a.veri_tarihi = g::date));
$$;

-- İşlenecek gün kayıtlarının vardiya penceresi: [başlangıç - önce, bitiş + sonra]
create function pdks.gun_penceresi(p_gun_kaydi_id bigint, out p_bas timestamptz, out p_bit timestamptz)
language sql
stable
set search_path = pdks
as $$
    select g.planli_baslangic - make_interval(mins => t.pencere_once_dk),
           g.planli_bitis     + make_interval(mins => t.pencere_sonra_dk)
    from pdks.gun_kaydi g
    join pdks.vardiya_tanim t on t.id = g.vardiya_id
    where g.id = p_gun_kaydi_id;
$$;

-- Okutma işaretli mi (hesaba katılmayacak okutmalar)
create function pdks.okutma_gecersiz_mi(p_ham_okutma_id bigint)
returns boolean
language sql
stable
set search_path = pdks
as $$
    select exists (select 1 from pdks.okutma_isareti
                   where ham_okutma_id = p_ham_okutma_id
                     and isaret in ('mukerrer', 'iptal_kart', 'bilinmeyen_kart'));
$$;

-- Çalışanın son iki haftada en çok kullandığı PDKS okuyucusu
create function pdks.calisan_pdks_okuyucusu(p_calisan_id bigint, p_gun date)
returns smallint
language sql
stable
set search_path = pdks
as $$
    select h.okuyucu_id
    from pdks.ham_okutma h
    where h.okutma_zamani >= ((p_gun - 14)::timestamp at time zone 'Europe/Istanbul')
      and h.okutma_zamani <  ((p_gun + 2)::timestamp at time zone 'Europe/Istanbul')
      and pdks.okutma_sahibi(h.kart_no, h.okutma_zamani) = p_calisan_id
    group by h.okuyucu_id
    order by count(*) desc, h.okuyucu_id
    limit 1;
$$;

-- Gün kaydı penceresindeki en uygun kanıt (önce kapı, sonra servis)
--   giriş: penceredeki ilk giriş kanıtı; çıkış: p_sonra'dan sonraki ilk çıkış kanıtı
create function pdks.gun_kaniti(p_gun_kaydi_id bigint, p_yon text, p_sonra timestamptz default null,
                                out p_kanit_id bigint, out p_zaman timestamptz, out p_kaynak text)
language sql
stable
set search_path = pdks
as $$
    select k.id, k.okutma_zamani, k.kaynak
    from pdks.gun_kaydi g
    cross join lateral pdks.gun_penceresi(g.id) w
    join pdks.kanit_kaydi k
      on k.okutma_zamani between w.p_bas and w.p_bit
     and k.yon = p_yon
     and k.kaynak in ('kapi', 'servis')
     and (p_sonra is null or k.okutma_zamani > p_sonra)
    where g.id = p_gun_kaydi_id
      and pdks.okutma_sahibi(k.kart_no, k.okutma_zamani) = g.calisan_id
    order by (k.kaynak = 'kapi') desc, k.okutma_zamani
    limit 1;
$$;

-- Tekrarlanmayan uyarı yazar; yeni yazıldıysa 1 döner
create function pdks.uyari_yaz(p_tur text, p_anahtar text, p_mesaj text,
                               p_calisan_id bigint default null, p_okuyucu_id smallint default null)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_n integer;
begin
    insert into pdks.uyari (tur, calisan_id, okuyucu_id, mesaj, tekillik_anahtari)
    values (p_tur, p_calisan_id, p_okuyucu_id, p_mesaj, p_anahtar)
    on conflict (tur, tekillik_anahtari) where tekillik_anahtari is not null do nothing;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Adım 1: İşaretleme (sorun 3, 4)
--    Gece vardiyası penceresi iki güne yayıldığı için önceki ve sonraki gün de taranır.
-- ---------------------------------------------------------------------
create function pdks.gece_isi_isaretle(p_gun date, p_gece_isi_id bigint)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_bas   timestamptz := ((p_gun - 1)::timestamp at time zone 'Europe/Istanbul');
    v_bit   timestamptz := ((p_gun + 2)::timestamp at time zone 'Europe/Istanbul');
    v_esik  interval    := make_interval(mins => pdks.ayar_al('mukerrer_esik_dk'));
    v_say   integer := 0;
    v_n     integer;
    r       record;
begin
    -- Mükerrer: aynı kart, aynı yön, eşik süresi içinde tekrar
    insert into pdks.okutma_isareti (ham_okutma_id, isaret, aciklama, gece_isi_id)
    select x.id, 'mukerrer',
           format('%s sn önce aynı kart aynı yönde okutulmuş', extract(epoch from x.okutma_zamani - x.onceki)::int),
           p_gece_isi_id
    from (select h.id, h.okutma_zamani,
                 lag(h.okutma_zamani) over (partition by h.kart_no, h.yon order by h.okutma_zamani, h.id) as onceki
          from pdks.ham_okutma h
          where h.okutma_zamani >= v_bas - v_esik and h.okutma_zamani < v_bit) x
    where x.onceki is not null
      and x.okutma_zamani - x.onceki <= v_esik
      and x.okutma_zamani >= v_bas
    on conflict (ham_okutma_id, isaret) do nothing;
    get diagnostics v_n = row_count;
    v_say := v_say + v_n;

    -- İptal edilmiş kartla okutma (+ İK'ya uyarı)
    for r in
        select h.id, h.okuyucu_id, h.kart_no, h.okutma_zamani, k.calisan_id
        from pdks.ham_okutma h
        join pdks.kart k on k.kart_no = h.kart_no
        where k.durum = 'iptal' and h.okutma_zamani >= k.iptal_zamani
          and h.okutma_zamani >= v_bas and h.okutma_zamani < v_bit
    loop
        insert into pdks.okutma_isareti (ham_okutma_id, isaret, aciklama, gece_isi_id)
        values (r.id, 'iptal_kart', 'Kart bu okutmadan önce iptal edilmişti', p_gece_isi_id)
        on conflict (ham_okutma_id, isaret) do nothing;
        get diagnostics v_n = row_count;
        v_say := v_say + v_n;
        perform pdks.uyari_yaz('iptal_kart_okutma', 'ham:' || r.id,
            format('İptal edilmiş kart %s, %s tarihinde okutuldu.', r.kart_no,
                   to_char(r.okutma_zamani at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')),
            r.calisan_id, r.okuyucu_id);
    end loop;

    -- Bilinmeyen kart: okutma anında kimseye ait değil (tanımsız kart ya da zimmetsiz geçici kart)
    insert into pdks.okutma_isareti (ham_okutma_id, isaret, aciklama, gece_isi_id)
    select h.id, 'bilinmeyen_kart', 'Okutma anında bu kart kimseye ait değil', p_gece_isi_id
    from pdks.ham_okutma h
    where h.okutma_zamani >= v_bas and h.okutma_zamani < v_bit
      and pdks.okutma_sahibi(h.kart_no, h.okutma_zamani) is null
    on conflict (ham_okutma_id, isaret) do nothing;
    get diagnostics v_n = row_count;
    v_say := v_say + v_n;

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Adım 2: Gün kaydı (sorun 7, 14)
--    Saatler yalnızca PDKS'den; ilk giriş ve son çıkış. Vardiya penceresinin
--    kapsadığı günlerin PDKS dosyası gelmediyse kayıt bir sonraki çalıştırmaya kalır.
-- ---------------------------------------------------------------------
create function pdks.gece_isi_gun_kayitlari(p_gun date, p_gece_isi_id bigint)
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

-- ---------------------------------------------------------------------
-- 5. Adım 3: Arıza şüphesi (sorun 5)
--    Bir PDKS okuyucusunda, aynı gün "PDKS okutması eksik ama kapı kaydı var"
--    durumundaki kişi sayısı eşiği geçerse otomatik arıza şüphesi açılır.
--    Aynı okuyucunun yakın zamanlı şüphesi varsa yenisi açılmaz, aralığı genişletilir.
-- ---------------------------------------------------------------------
create function pdks.gece_isi_ariza_suphesi(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_esik   integer  := pdks.ayar_al('ariza_suphe_kisi');
    v_pay    interval := make_interval(mins => pdks.ayar_al('ariza_suphe_dk'));
    v_ariza  bigint;
    v_say    integer := 0;
    r        record;
begin
    for r in
        with eksik as (
            select g.id, g.calisan_id,
                   pdks.calisan_pdks_okuyucusu(g.calisan_id, p_gun) as okuyucu_id,
                   case when g.giris_zamani is null then (pdks.gun_kaniti(g.id, 'giris')).p_zaman end as kanit_giris,
                   case when g.cikis_zamani is null then
                       (pdks.gun_kaniti(g.id, 'cikis', coalesce(g.giris_zamani, g.planli_baslangic))).p_zaman end as kanit_cikis
            from pdks.gun_kaydi g
            where g.is_gunu = p_gun and g.durum = 'eksik'
        ), zamanlar as (
            select okuyucu_id, calisan_id, z
            from eksik, unnest(array[kanit_giris, kanit_cikis]) z
            where z is not null and okuyucu_id is not null
        )
        select okuyucu_id, min(z) as bas, max(z) as bit, count(distinct calisan_id) as kisi
        from zamanlar
        group by okuyucu_id
        having count(distinct calisan_id) >= v_esik
    loop
        -- Kanıt zamanında okuyucu gerçekten sessiz miydi? Aralıkta okutma varsa şüphe yok.
        continue when exists (select 1 from pdks.ham_okutma h
                              where h.okuyucu_id = r.okuyucu_id and h.okutma_zamani between r.bas and r.bit);

        select id into v_ariza from pdks.ariza a
        where a.okuyucu_id = r.okuyucu_id and a.kaynak = 'otomatik_suphe' and a.durum <> 'reddedildi'
          and tstzrange(a.baslangic - v_pay, coalesce(a.bitis, a.baslangic) + v_pay) && tstzrange(r.bas, r.bit, '[]')
        order by a.id limit 1;

        if v_ariza is null then
            insert into pdks.ariza (okuyucu_id, baslangic, bitis, kaynak, durum, aciklama)
            values (r.okuyucu_id, r.bas, greatest(r.bit, r.bas + interval '1 minute'), 'otomatik_suphe', 'suphe',
                    format('%s kişinin PDKS okutması yok ama kapı kaydı var; okuyucu bu aralıkta sessiz.', r.kisi))
            returning id into v_ariza;
        else
            update pdks.ariza
            set baslangic = least(baslangic, r.bas),
                bitis     = greatest(coalesce(bitis, baslangic), r.bit, least(baslangic, r.bas) + interval '1 minute')
            where id = v_ariza;
        end if;

        v_say := v_say + pdks.uyari_yaz('ariza_suphesi', 'ariza:' || v_ariza,
            format('%s okuyucusu %s civarında okutma almamış olabilir; İK onayı bekliyor.',
                   (select kod from pdks.okuyucu where id = r.okuyucu_id),
                   to_char(r.bas at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')),
            null, r.okuyucu_id);
    end loop;
    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Adım 4: Kanıtla düzeltme (sorun 1, 2, 5)
--    Giriş: kanıt + yürüme payı vardiya başından önce ya da eşitse giriş = vardiya başı.
--           Sonraysa düzeltme yapılmaz; soru adımı amire sorar.
--    Çıkış: kanıttaki saat yazılır.
-- ---------------------------------------------------------------------
create function pdks.gece_isi_kanitla_duzelt(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_yurume  interval := make_interval(mins => pdks.ayar_al('yurume_payi_dk'));
    v_say     integer := 0;
    v_ariza   bigint;
    g         record;
    k         record;
begin
    for g in
        select * from pdks.gun_kaydi
        where is_gunu = p_gun and durum = 'eksik' and not pdks.donem_kilitli_mi(p_gun)
        order by id
    loop
        if g.giris_zamani is null then
            select * into k from pdks.gun_kaniti(g.id, 'giris');
            if k.p_kanit_id is not null and k.p_zaman + v_yurume <= g.planli_baslangic then
                select a.id into v_ariza from pdks.ariza a
                where a.okuyucu_id = pdks.calisan_pdks_okuyucusu(g.calisan_id, p_gun)
                  and a.durum <> 'reddedildi' and k.p_zaman between a.baslangic and coalesce(a.bitis, 'infinity')
                limit 1;
                perform pdks.duzeltme_uygula(g.id, 'giris_zamani', g.planli_baslangic::text,
                    format('%s kaydı %s, vardiya başından önce; giriş vardiya başı olarak yazıldı',
                           case k.p_kaynak when 'kapi' then 'Kapı' else 'Servis' end, to_char(k.p_zaman at time zone 'Europe/Istanbul', 'HH24:MI')),
                    'gece_isi', p_kanit_kaydi_id => k.p_kanit_id, p_ariza_id => v_ariza);
                v_say := v_say + 1;
                g.giris_zamani := g.planli_baslangic;
            end if;
        end if;

        if g.cikis_zamani is null then
            select * into k from pdks.gun_kaniti(g.id, 'cikis', coalesce(g.giris_zamani, g.planli_baslangic));
            if k.p_kanit_id is not null then
                select a.id into v_ariza from pdks.ariza a
                where a.okuyucu_id = pdks.calisan_pdks_okuyucusu(g.calisan_id, p_gun)
                  and a.durum <> 'reddedildi' and k.p_zaman between a.baslangic and coalesce(a.bitis, 'infinity')
                limit 1;
                perform pdks.duzeltme_uygula(g.id, 'cikis_zamani', k.p_zaman::text,
                    format('%s kaydı %s; çıkış kanıttaki saat olarak yazıldı',
                           case k.p_kaynak when 'kapi' then 'Kapı' else 'Servis' end, to_char(k.p_zaman at time zone 'Europe/Istanbul', 'HH24:MI')),
                    'gece_isi', p_kanit_kaydi_id => k.p_kanit_id, p_ariza_id => v_ariza);
                v_say := v_say + 1;
            end if;
        end if;
    end loop;
    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Adım 5: Amire soru (sorun 1, 2, 4, 13)
-- ---------------------------------------------------------------------
create function pdks.gece_isi_sorular(p_gun date)
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
        if g.giris_zamani is null and g.cikis_zamani is null then
            -- Gün boyu hiçbir iz var mı? (kapı, servis, yemekhane)
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
-- 8. Adım 6: Eskalasyon (sorun 13)
--    Son cevap tarihi geçmiş açık soru üst amire gider; üst amir yoksa ya da
--    soru onun kendi kaydıysa İK'ya gider. İK'ya uyarı yazılır.
-- ---------------------------------------------------------------------
create function pdks.gece_isi_eskale(p_gun date)
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_say  integer := 0;
    v_hedef bigint;
    s      record;
begin
    for s in
        select q.id, q.atanan_id, g.calisan_id, g.is_gunu
        from pdks.amir_sorusu q
        join pdks.gun_kaydi g on g.id = q.gun_kaydi_id
        where q.durum = 'acik' and q.son_cevap_tarihi <= p_gun
        order by q.id
    loop
        select ust_amir_id into v_hedef from pdks.kullanici where id = s.atanan_id;
        if v_hedef is null or pdks.kullanici_calisani(v_hedef) = s.calisan_id then
            v_hedef := pdks.ik_sorumlusu(s.calisan_id);
        end if;
        update pdks.amir_sorusu
        set durum = 'eskale', eskale_zamani = now(), eskale_edilen_id = v_hedef
        where id = s.id;
        v_say := v_say + 1;
        perform pdks.uyari_yaz('soru_eskale', 'soru:' || s.id,
            format('%s tarihli soru süresinde cevaplanmadı; üst amire / İK''ya gitti.', to_char(s.is_gunu, 'DD.MM.YYYY')),
            s.calisan_id);
    end loop;
    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Adım 7: Hesap (sorun 9, 10)
--    Giriş ve çıkışı belli, hesabı yapılmamış her gün (sonradan cevaplananlar dahil).
--    Fazla mesai yalnızca onaylı plan kadar puantaja girer.
-- ---------------------------------------------------------------------
create function pdks.gece_isi_hesapla()
returns integer
language plpgsql
set search_path = pdks
as $$
declare
    v_gec_tol  integer := pdks.ayar_al('gec_kalma_tolerans_dk');
    v_erk_tol  integer := pdks.ayar_al('erken_cikis_tolerans_dk');
    v_n        integer;
begin
    with h as (
        select g.id,
               pdks.dakika(g.planli_baslangic, g.giris_zamani) as gec,
               pdks.dakika(g.cikis_zamani, g.planli_bitis) as erken,
               case when p.planli_dk is not null and pdks.fm_onay_gecerli_mi(g.calisan_id, g.is_gunu)
                    then least(p.planli_dk, greatest(0, pdks.dakika(g.planli_bitis, g.cikis_zamani)))
                    else 0 end as fm
        from pdks.gun_kaydi g
        left join pdks.fazla_mesai_plani p
          on p.calisan_id = g.calisan_id and p.is_gunu = g.is_gunu and p.durum = 'onaylandi'
        where not g.hesap_tamam
          and g.giris_zamani is not null and g.cikis_zamani is not null
          and g.planli_baslangic is not null
          and g.durum in ('eksik', 'tamam', 'soru_bekliyor')
          and not pdks.donem_kilitli_mi(g.is_gunu)
          and not exists (select 1 from pdks.amir_sorusu q
                          where q.gun_kaydi_id = g.id and q.durum in ('acik', 'eskale', 'ik_karari_bekliyor'))
    )
    update pdks.gun_kaydi g
    set gec_kalma_dk   = case when h.gec > v_gec_tol then h.gec else 0 end,
        erken_cikis_dk = case when h.erken > v_erk_tol then h.erken else 0 end,
        fazla_mesai_dk = h.fm,
        calisma_dk     = greatest(0, pdks.dakika(greatest(g.giris_zamani, g.planli_baslangic),
                                                 least(g.cikis_zamani, g.planli_bitis + make_interval(mins => h.fm)))),
        durum          = 'tamam',
        hesap_tamam    = true
    from h
    where g.id = h.id;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Adım 8: Uyarılar (sorun 4, 6, 10, 16)
-- ---------------------------------------------------------------------
create function pdks.gece_isi_uyarilar(p_gun date)
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
    -- Fazla mesai: vardiya sonrası onaylı plandan fazla kalan
    for r in
        select g.id, g.calisan_id, g.giris_zamani, g.cikis_zamani, g.planli_baslangic,
               pdks.dakika(g.planli_bitis, g.cikis_zamani) as fazla,
               coalesce(p.planli_dk, 0) as plan,
               pdks.fm_onay_gecerli_mi(g.calisan_id, g.is_gunu) as onay
        from pdks.gun_kaydi g
        left join pdks.fazla_mesai_plani p
          on p.calisan_id = g.calisan_id and p.is_gunu = g.is_gunu and p.durum = 'onaylandi'
        where g.is_gunu = p_gun and g.cikis_zamani is not null and g.planli_bitis is not null
    loop
        if r.fazla - r.plan > v_esik then
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
           and pdks.dakika(greatest(r.giris_zamani, r.planli_baslangic), r.cikis_zamani) > v_gunluk + v_esik then
            v_say := v_say + pdks.uyari_yaz('fm_gunluk_sinir_asildi', 'gunluk:' || r.id,
                format('%s: günlük çalışma %s dk; sınır %s dk (11 saat).', to_char(p_gun, 'DD.MM.YYYY'),
                       pdks.dakika(greatest(r.giris_zamani, r.planli_baslangic), r.cikis_zamani), v_gunluk),
                r.calisan_id);
        end if;
    end loop;

    -- Gelmeyen dosya (sorun 16)
    for r in
        select k from unnest(array['pdks', 'kapi', 'yemekhane', 'servis']) k
        where not exists (select 1 from pdks.aktarim a where a.kaynak = k and a.veri_tarihi = p_gun)
    loop
        v_say := v_say + pdks.uyari_yaz('dosya_gelmedi', r.k || ':' || p_gun,
            format('%s günü için %s dosyası yüklenmedi.', to_char(p_gun, 'DD.MM.YYYY'), r.k));
    end loop;

    -- Mevcut kontroller: geçici kart (sorun 4) ve kart paylaşımı (sorun 6)
    v_say := v_say + coalesce(pdks.gecici_kart_kontrol(p_gun), 0);
    v_say := v_say + coalesce(pdks.kart_paylasim_kontrol(p_gun), 0);

    return v_say;
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Tek kapı
-- ---------------------------------------------------------------------
create function pdks.gece_isi_calistir(p_gun date)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_id    bigint;
    v_ozet  jsonb;
begin
    -- Dün her zaman işlenebilir; daha ileri bir gün ancak PDKS dosyası yüklendiyse
    -- (ör. demo verisi). Eksik veriyle yarım iş yapılmasını pdks_verisi_tam_mi() önler.
    if p_gun is null or p_gun > greatest(current_date - 1,
            (select max(veri_tarihi) from pdks.aktarim where kaynak = 'pdks')) then
        raise exception 'Bu gün için henüz veri yok: %', p_gun;
    end if;

    -- Aynı anda iki gece işi çalışmasın
    perform pg_advisory_xact_lock(hashtext('pdks.gece_isi'));

    insert into pdks.gece_isi (islenen_gun) values (p_gun) returning id into v_id;

    begin
        v_ozet := jsonb_build_object('isaret',    pdks.gece_isi_isaretle(p_gun, v_id));
        v_ozet := v_ozet || jsonb_build_object('gun_kaydi', pdks.gece_isi_gun_kayitlari(p_gun, v_id));
        v_ozet := v_ozet || jsonb_build_object('ariza',     pdks.gece_isi_ariza_suphesi(p_gun));
        v_ozet := v_ozet || jsonb_build_object('duzeltme',  pdks.gece_isi_kanitla_duzelt(p_gun));
        v_ozet := v_ozet || jsonb_build_object('soru',      pdks.gece_isi_sorular(p_gun));
        v_ozet := v_ozet || jsonb_build_object('eskale',    pdks.gece_isi_eskale(p_gun));
        v_ozet := v_ozet || jsonb_build_object('hesap',     pdks.gece_isi_hesapla());
        v_ozet := v_ozet || jsonb_build_object('uyari',     pdks.gece_isi_uyarilar(p_gun));

        update pdks.gece_isi set durum = 'basarili', bitis = clock_timestamp(), ozet = v_ozet where id = v_id;
    exception when others then
        -- Bu bloktaki tüm değişiklikler geri alınır; yalnızca hata kaydı kalır
        update pdks.gece_isi set durum = 'hatali', bitis = clock_timestamp(), hata_mesaji = sqlerrm where id = v_id;
    end;
    return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Demo düğmesi: bir tarih aralığını gün gün işler (yalnızca İK)
-- ---------------------------------------------------------------------
create function pdks.gece_isi_tetikle(p_baslangic date, p_bitis date default null)
returns table (gun date, durum text, ozet jsonb, hata_mesaji text)
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_bitis date := coalesce(p_bitis, p_baslangic);
    v_id    bigint;
    v_gun   date;
begin
    perform pdks.yetki_gerekli('ik');
    if p_baslangic is null or v_bitis < p_baslangic then
        raise exception 'Tarih aralığı geçersiz.';
    end if;
    if v_bitis - p_baslangic > 62 then
        raise exception 'Bir seferde en fazla 62 gün işlenebilir.';
    end if;

    for v_gun in select g::date from generate_series(p_baslangic, v_bitis, interval '1 day') g loop
        v_id := pdks.gece_isi_calistir(v_gun);
        return query select gi.islenen_gun, gi.durum, gi.ozet, gi.hata_mesaji from pdks.gece_isi gi where gi.id = v_id;
    end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 13. Yetkiler: iç adımlar kimseye açık değil; demo düğmesi giriş yapmış kullanıcıya
--     açık, içeride yalnızca İK'ya izin verir.
-- ---------------------------------------------------------------------
revoke execute on function
    pdks.ik_sorumlusu(bigint), pdks.soru_atanacak(bigint), pdks.dakika(timestamptz, timestamptz),
    pdks.pdks_verisi_tam_mi(timestamptz, timestamptz), pdks.gun_penceresi(bigint),
    pdks.okutma_gecersiz_mi(bigint), pdks.calisan_pdks_okuyucusu(bigint, date),
    pdks.gun_kaniti(bigint, text, timestamptz), pdks.uyari_yaz(text, text, text, bigint, smallint),
    pdks.gece_isi_isaretle(date, bigint), pdks.gece_isi_gun_kayitlari(date, bigint),
    pdks.gece_isi_ariza_suphesi(date), pdks.gece_isi_kanitla_duzelt(date), pdks.gece_isi_sorular(date),
    pdks.gece_isi_eskale(date), pdks.gece_isi_hesapla(), pdks.gece_isi_uyarilar(date),
    pdks.gece_isi_calistir(date), pdks.gece_isi_tetikle(date, date)
from public, anon, authenticated;

grant execute on function pdks.gece_isi_tetikle(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 14. Zamanlama (pg_cron): her gece 06:30 Türkiye = 03:30 UTC.
--     Önceki gün ve dünü işler; ertesi gün dosyası gelmeyen gece vardiyaları
--     ikinci çalıştırmada tamamlanır. Tekrar çalıştırmak güvenlidir.
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
    'pdks-gece-isi',
    '30 3 * * *',
    $cron$select pdks.gece_isi_calistir(current_date - 2); select pdks.gece_isi_calistir(current_date - 1);$cron$
);
