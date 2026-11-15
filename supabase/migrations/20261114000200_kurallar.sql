-- =====================================================================
-- 2/4: Kurallar (trigger'lar ve fonksiyonlar)
--
--  * Ham kayıtlar ve düzeltme izi değiştirilemez / silinemez  (sorun 12)
--  * gun_kaydi'nda giriş, çıkış, vardiya ve "devamsız" yalnızca
--    eşleşen bir düzeltme satırıyla değişebilir                 (sorun 12)
--  * Kilitli ay değişmez, sonraki düzeltme "fark" olur        (sorun 11)
--  * Çalışan aleyhine kararı yalnızca İK verir
--  * Kiosk PIN kontrolü ve kilitlenme                          (sorun 17)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Yardımcı fonksiyonlar
-- ---------------------------------------------------------------------

create or replace function pdks.ayar_al(p_anahtar text)
returns integer
language sql stable
set search_path = pdks
as $$
    select deger from pdks.ayar where anahtar = p_anahtar;
$$;

-- Verilen günün dönemini döndürür, yoksa açık olarak oluşturur
create or replace function pdks.donem_bul(p_tarih date)
returns bigint
language plpgsql
set search_path = pdks
as $$
declare
    v_id bigint;
begin
    insert into pdks.donem (yil, ay)
    values (extract(year from p_tarih), extract(month from p_tarih))
    on conflict (yil, ay) do nothing;

    select id into v_id from pdks.donem
    where yil = extract(year from p_tarih) and ay = extract(month from p_tarih);
    return v_id;
end;
$$;

create or replace function pdks.donem_kilitli_mi(p_tarih date)
returns boolean
language sql stable
set search_path = pdks
as $$
    select coalesce((select durum = 'kilitli' from pdks.donem
                     where yil = extract(year from p_tarih)
                       and ay = extract(month from p_tarih)), false);
$$;

create or replace function pdks.kullanici_rolu(p_id bigint)
returns text
language sql stable
set search_path = pdks
as $$
    select rol from pdks.kullanici where id = p_id and aktif;
$$;

-- ---------------------------------------------------------------------
-- Silinemez / değiştirilemez tablolar
-- ---------------------------------------------------------------------

create or replace function pdks.degistirilemez()
returns trigger
language plpgsql
as $$
begin
    raise exception '% tablosu değiştirilemez ve silinemez (yalnızca ekleme yapılır).', tg_table_name
        using errcode = 'insufficient_privilege';
end;
$$;

do $$
declare
    t text;
begin
    foreach t in array array['aktarim', 'ham_okutma', 'kanit_kaydi', 'okutma_isareti',
                             'duzeltme', 'puantaj_satiri', 'ayar_gecmisi']
    loop
        execute format('create trigger %I before update or delete on pdks.%I
                        for each row execute function pdks.degistirilemez()',
                       t || '_degistirilemez', t);
        execute format('create trigger %I before truncate on pdks.%I
                        for each statement execute function pdks.degistirilemez()',
                       t || '_bosaltilamaz', t);
    end loop;
end;
$$;

-- Ayar değişince eski-yeni değer ayar_gecmisi'ne yazılır
create or replace function pdks.ayar_iz()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'Ayar silinemez, yalnızca değeri değiştirilir.';
    end if;
    if tg_op = 'INSERT' or new.deger is distinct from old.deger then
        insert into pdks.ayar_gecmisi (anahtar, eski_deger, yeni_deger, guncelleyen_id)
        values (new.anahtar, case when tg_op = 'UPDATE' then old.deger end, new.deger, new.guncelleyen_id);
    end if;
    new.guncelleme_zamani := now();
    return new;
end;
$$;
create trigger ayar_iz before insert or update or delete on pdks.ayar
    for each row execute function pdks.ayar_iz();

-- ---------------------------------------------------------------------
-- Dönem kilidi (sorun 11): kilit geri açılamaz
-- ---------------------------------------------------------------------

create or replace function pdks.donem_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'Dönem silinemez.';
    end if;
    if old.durum = 'kilitli' then
        raise exception '%/% dönemi kilitli; değiştirilemez.', old.ay, old.yil;
    end if;
    if new.durum = 'kilitli' then
        if pdks.kullanici_rolu(new.kilitleyen_id) is distinct from 'ik' then
            raise exception 'Dönemi yalnızca İK kilitleyebilir.';
        end if;
        new.kilit_zamani := now();
    end if;
    return new;
end;
$$;
create trigger donem_kontrol before update or delete on pdks.donem
    for each row execute function pdks.donem_kontrol();

-- İK ay kilitleme fonksiyonu. Açık soru / itiraz varsa durur (p_zorla ile geçilebilir).
create or replace function pdks.donem_kilitle(p_donem_id bigint, p_kullanici_id bigint, p_zorla boolean default false)
returns void
language plpgsql
set search_path = pdks
as $$
declare
    v_donem   pdks.donem;
    v_acik    integer;
begin
    select * into v_donem from pdks.donem where id = p_donem_id for update;
    if not found then
        raise exception 'Dönem bulunamadı: %', p_donem_id;
    end if;

    select count(*) into v_acik
    from pdks.gun_kaydi g
    where extract(year from g.is_gunu) = v_donem.yil
      and extract(month from g.is_gunu) = v_donem.ay
      and (exists (select 1 from pdks.amir_sorusu s
                   where s.gun_kaydi_id = g.id and s.durum in ('acik', 'eskale', 'ik_karari_bekliyor'))
        or exists (select 1 from pdks.itiraz i
                   where i.gun_kaydi_id = g.id and i.durum in ('acik', 'inceleniyor')));

    if v_acik > 0 and not p_zorla then
        raise exception '%/% döneminde açık soru veya itirazı olan % gün var.', v_donem.ay, v_donem.yil, v_acik;
    end if;

    update pdks.donem set durum = 'kilitli', kilitleyen_id = p_kullanici_id where id = p_donem_id;
end;
$$;

-- Puantaj satırı yalnızca kilitli döneme yazılır (kilitli ayın fotoğrafıdır)
create or replace function pdks.puantaj_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if not exists (select 1 from pdks.donem where id = new.donem_id and durum = 'kilitli') then
        raise exception 'Puantaj yalnızca kilitlenmiş döneme yazılır.';
    end if;
    return new;
end;
$$;
create trigger puantaj_kontrol before insert on pdks.puantaj_satiri
    for each row execute function pdks.puantaj_kontrol();

-- ---------------------------------------------------------------------
-- Düzeltme izi: hedef dönem ve fark satırı otomatik belirlenir
-- ---------------------------------------------------------------------

create or replace function pdks.duzeltme_hazirla()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_gun  pdks.gun_kaydi;
    v_rol  text;
    v_ay   date;
begin
    select * into v_gun from pdks.gun_kaydi where id = new.gun_kaydi_id;
    new.calisan_id := v_gun.calisan_id;
    new.is_gunu := v_gun.is_gunu;
    new.yapilma_zamani := now();

    -- Kaynak ile kişinin rolü uyuşmalı (amir İK adına düzeltme yapamaz)
    if new.kaynak <> 'gece_isi' then
        v_rol := pdks.kullanici_rolu(new.yapan_id);
        if v_rol is null then
            raise exception 'Düzeltmeyi yapan kullanıcı bulunamadı ya da pasif.';
        end if;
        if new.kaynak = 'ik' and v_rol <> 'ik' then
            raise exception 'İK kaynaklı düzeltmeyi yalnızca İK rolü yapabilir.';
        end if;
        if new.kaynak = 'amir' and v_rol not in ('amir', 'ik') then
            raise exception 'Amir kaynaklı düzeltmeyi yalnızca amir yapabilir.';
        end if;
    end if;

    -- "devamsız" kararı çalışan aleyhinedir: yalnızca İK
    if new.alan = 'durum' and new.yeni_deger = 'devamsiz' then
        new.calisan_aleyhine := true;
        if new.kaynak <> 'ik' then
            raise exception 'Devamsızlık kararını yalnızca İK verebilir.';
        end if;
    end if;

    -- Sorun 11: kilitli aya ait düzeltme sonraki açık aya fark olarak yazılır
    if pdks.donem_kilitli_mi(v_gun.is_gunu) then
        new.fark_satiri := true;
        v_ay := date_trunc('month', v_gun.is_gunu)::date;
        loop
            v_ay := (v_ay + interval '1 month')::date;
            exit when not pdks.donem_kilitli_mi(v_ay);
        end loop;
        new.hedef_donem_id := pdks.donem_bul(v_ay);
    else
        new.fark_satiri := false;
        new.hedef_donem_id := pdks.donem_bul(v_gun.is_gunu);
    end if;
    return new;
end;
$$;
create trigger duzeltme_hazirla before insert on pdks.duzeltme
    for each row execute function pdks.duzeltme_hazirla();

-- ---------------------------------------------------------------------
-- gun_kaydi koruması
-- Giriş, çıkış, vardiya ya da "devamsız" durumu değişecekse, AYNI işlemde
-- (transaction) yazılmış ve değeri birebir tutan bir düzeltme satırı olmalı.
-- Bu satır pdks.duzeltme_id oturum değişkeniyle gösterilir; duzeltme_uygula()
-- bunu kendisi yapar. Böylece izsiz değişiklik veritabanı seviyesinde imkânsız.
-- ---------------------------------------------------------------------

create or replace function pdks.gun_kaydi_koru()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_alan   text;
    v_yeni   text;
    v_did    bigint;
begin
    if tg_op = 'DELETE' then
        raise exception 'Günlük kayıt silinemez.';
    end if;

    -- Kilitli ay değişmez
    if pdks.donem_kilitli_mi(new.is_gunu)
       or (tg_op = 'UPDATE' and pdks.donem_kilitli_mi(old.is_gunu)) then
        raise exception '% günü kilitli bir döneme ait; değişiklik sonraki aya fark olarak yazılır.', new.is_gunu;
    end if;

    if tg_op = 'INSERT' then
        -- İlk hesap yalnızca ham PDKS okutmasından gelir; kanıtla doldurma bir düzeltmedir.
        if coalesce(new.giris_kaynagi, 'pdks') <> 'pdks' or coalesce(new.cikis_kaynagi, 'pdks') <> 'pdks' then
            raise exception 'Yeni günlük kayıtta saat yalnızca PDKS kaynaklı olabilir; diğerleri düzeltme ile girilir.';
        end if;
        if new.durum = 'devamsiz' then
            raise exception 'Devamsızlık kararını yalnızca İK, düzeltme ile verebilir.';
        end if;
        return new;
    end if;

    if new.calisan_id <> old.calisan_id or new.is_gunu <> old.is_gunu then
        raise exception 'Günlük kaydın çalışanı veya günü değiştirilemez.';
    end if;

    if new.giris_zamani is distinct from old.giris_zamani then
        v_alan := 'giris_zamani'; v_yeni := new.giris_zamani::text;
    end if;
    if new.cikis_zamani is distinct from old.cikis_zamani then
        if v_alan is not null then raise exception 'Tek seferde tek alan düzeltilir.'; end if;
        v_alan := 'cikis_zamani'; v_yeni := new.cikis_zamani::text;
    end if;
    if new.vardiya_id is distinct from old.vardiya_id then
        if v_alan is not null then raise exception 'Tek seferde tek alan düzeltilir.'; end if;
        v_alan := 'vardiya_id'; v_yeni := new.vardiya_id::text;
    end if;
    if new.durum is distinct from old.durum and 'devamsiz' in (new.durum, old.durum) then
        if v_alan is not null then raise exception 'Tek seferde tek alan düzeltilir.'; end if;
        v_alan := 'durum'; v_yeni := new.durum;
    end if;

    if v_alan is not null then
        v_did := nullif(current_setting('pdks.duzeltme_id', true), '')::bigint;
        if v_did is null or not exists (
            select 1 from pdks.duzeltme d
            where d.id = v_did
              and d.gun_kaydi_id = new.id
              and d.alan = v_alan
              and d.yeni_deger is not distinct from v_yeni
              and d.yapilma_zamani = now()          -- aynı işlemde yazılmış olmalı
        ) then
            raise exception '% alanı yalnızca pdks.duzeltme_uygula() ile değiştirilebilir.', v_alan
                using errcode = 'insufficient_privilege';
        end if;
    end if;

    new.guncelleme_zamani := now();
    return new;
end;
$$;
create trigger gun_kaydi_koru before insert or update or delete on pdks.gun_kaydi
    for each row execute function pdks.gun_kaydi_koru();

-- ---------------------------------------------------------------------
-- TEK düzeltme kapısı: önce iz yazılır, sonra kayıt değişir.
-- Kilitli ayda yalnızca iz (fark) yazılır, kayıt değişmez.
-- Örnek: select pdks.duzeltme_uygula(15, 'giris_zamani', '2026-11-13 08:00+03',
--               'Kapı kaydı 07:50, vardiya öncesi', 'gece_isi', p_kanit_kaydi_id => 991);
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

    -- Değeri Postgres'in kendi biçimine çevir (iz ile kayıt birebir tutsun)
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
            p_kanit_kaydi_id, p_izin_id, p_ariza_id, p_soru_id, p_itiraz_id, 0)  -- 0: trigger doldurur
    returning id, fark_satiri into v_id, v_fark;

    if v_fark then
        return v_id;   -- kilitli ay: kayıt değişmez, fark sonraki ayın puantajına girer
    end if;

    perform set_config('pdks.duzeltme_id', v_id::text, true);  -- yalnızca bu işlem için
    case p_alan
        when 'giris_zamani' then
            update pdks.gun_kaydi set giris_zamani = p_yeni_deger::timestamptz, giris_kaynagi = v_kayn,
                                      hesap_tamam = false where id = p_gun_kaydi_id;
        when 'cikis_zamani' then
            update pdks.gun_kaydi set cikis_zamani = p_yeni_deger::timestamptz, cikis_kaynagi = v_kayn,
                                      hesap_tamam = false where id = p_gun_kaydi_id;
        when 'vardiya_id' then
            update pdks.gun_kaydi set vardiya_id = p_yeni_deger::smallint, hesap_tamam = false
            where id = p_gun_kaydi_id;
        when 'durum' then
            update pdks.gun_kaydi set durum = p_yeni_deger, hesap_tamam = false where id = p_gun_kaydi_id;
    end case;
    perform set_config('pdks.duzeltme_id', '', true);
    return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Çalışan aleyhine kararlar İK'da
-- ---------------------------------------------------------------------

-- Amir "gelmedi" derse soru kapanmaz, İK kararına gider
create or replace function pdks.amir_sorusu_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if new.cevap is not null and old.cevap is null then
        new.cevap_zamani := now();
        if new.cevap = 'gelmedi' and pdks.kullanici_rolu(new.cevaplayan_id) is distinct from 'ik' then
            new.durum := 'ik_karari_bekliyor';
        end if;
    end if;
    if new.durum = 'kapandi' and old.durum = 'ik_karari_bekliyor'
       and pdks.kullanici_rolu(new.cevaplayan_id) is distinct from 'ik' then
        raise exception 'Bu soruyu yalnızca İK kapatabilir.';
    end if;
    return new;
end;
$$;
create trigger amir_sorusu_kontrol before update on pdks.amir_sorusu
    for each row execute function pdks.amir_sorusu_kontrol();

-- İtirazı reddetmek çalışan aleyhinedir: yalnızca İK
create or replace function pdks.itiraz_kontrol()
returns trigger
language plpgsql
set search_path = pdks
as $$
begin
    if new.durum in ('kabul', 'red') and old.durum not in ('kabul', 'red') then
        if new.durum = 'red' and pdks.kullanici_rolu(new.karar_veren_id) is distinct from 'ik' then
            raise exception 'İtirazı yalnızca İK reddedebilir.';
        end if;
        if pdks.kullanici_rolu(new.karar_veren_id) is null then
            raise exception 'Karar veren kullanıcı belirtilmeli.';
        end if;
        new.karar_zamani := now();
    elsif old.durum in ('kabul', 'red') then
        raise exception 'Karara bağlanmış itiraz değiştirilemez.';
    end if;
    return new;
end;
$$;
create trigger itiraz_kontrol before update on pdks.itiraz
    for each row execute function pdks.itiraz_kontrol();

-- ---------------------------------------------------------------------
-- Kiosk PIN (sorun 17)
-- Dönen değer: 'tamam' | 'pin_degismeli' | 'hatali' | 'kilitli' | 'yok'
-- ---------------------------------------------------------------------

create or replace function pdks.kiosk_giris(p_sicil_no text, p_pin text)
returns text
language plpgsql
set search_path = pdks, extensions
as $$
declare
    v_c  pdks.calisan;
begin
    select * into v_c from pdks.calisan where sicil_no = p_sicil_no and aktif for update;
    if not found or v_c.pin_ozeti is null then
        return 'yok';
    end if;
    if v_c.kilitli_mi then
        return 'kilitli';
    end if;
    if extensions.crypt(p_pin, v_c.pin_ozeti) = v_c.pin_ozeti then
        update pdks.calisan set hatali_pin_sayisi = 0 where id = v_c.id;
        return case when v_c.pin_degismeli then 'pin_degismeli' else 'tamam' end;
    end if;

    update pdks.calisan set hatali_pin_sayisi = hatali_pin_sayisi + 1,
                            kilitli_mi = (hatali_pin_sayisi + 1 >= pdks.ayar_al('pin_hatali_deneme_siniri'))
    where id = v_c.id
    returning * into v_c;
    if v_c.kilitli_mi then
        -- Başkası bilerek kilitlemiş olabilir: İK'ya bildir
        insert into pdks.uyari (tur, calisan_id, mesaj)
        values ('pin_kilitlendi', v_c.id, 'Kiosk hesabı hatalı PIN denemeleri nedeniyle kilitlendi.');
        return 'kilitli';
    end if;
    return 'hatali';
end;
$$;

create or replace function pdks.kiosk_pin_degistir(p_sicil_no text, p_eski_pin text, p_yeni_pin text)
returns boolean
language plpgsql
set search_path = pdks, extensions
as $$
begin
    if p_yeni_pin !~ '^[0-9]{4,8}$' then
        raise exception 'PIN 4-8 haneli rakam olmalı.';
    end if;
    if pdks.kiosk_giris(p_sicil_no, p_eski_pin) not in ('tamam', 'pin_degismeli') then
        return false;
    end if;
    update pdks.calisan
    set pin_ozeti = extensions.crypt(p_yeni_pin, extensions.gen_salt('bf')), pin_degismeli = false
    where sicil_no = p_sicil_no;
    return true;
end;
$$;

-- İK: geçici PIN verir ve kilidi açar (çalışan ilk girişte değiştirmek zorunda)
create or replace function pdks.pin_sifirla(p_calisan_id bigint, p_gecici_pin text, p_ik_id bigint)
returns void
language plpgsql
set search_path = pdks, extensions
as $$
begin
    if pdks.kullanici_rolu(p_ik_id) is distinct from 'ik' then
        raise exception 'PIN''i yalnızca İK sıfırlayabilir.';
    end if;
    update pdks.calisan
    set pin_ozeti = extensions.crypt(p_gecici_pin, extensions.gen_salt('bf')),
        pin_degismeli = true, hatali_pin_sayisi = 0, kilitli_mi = false
    where id = p_calisan_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Görünümler (view)
-- ---------------------------------------------------------------------

-- Sorun 17: kiosk ekranı. Uygulama "where calisan_id = ?" ile süzer.
create or replace view pdks.v_kiosk_kayitlar as
select g.calisan_id, g.is_gunu, v.ad as vardiya, g.giris_zamani, g.cikis_zamani,
       g.giris_kaynagi, g.cikis_kaynagi, g.durum, g.gec_kalma_dk, g.erken_cikis_dk, g.calisma_dk,
       (select count(*) from pdks.duzeltme d where d.gun_kaydi_id = g.id) as duzeltme_sayisi,
       (select i.durum from pdks.itiraz i where i.gun_kaydi_id = g.id
        order by i.olusturma_zamani desc limit 1) as son_itiraz_durumu
from pdks.gun_kaydi g
left join pdks.vardiya_tanim v on v.id = g.vardiya_id
where g.is_gunu >= current_date - pdks.ayar_al('kiosk_gun_sayisi');

-- Sorun 14: amir izin türünü görmez ("rapor" sağlık verisi)
create or replace view pdks.v_izin_amir as
select id, calisan_id, baslangic, bitis, 'izinli'::text as tur
from pdks.izin;

-- Açık ayın canlı puantajı (kilitlenince puantaj_satiri'na yazılır)
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
                           or not g.hesap_tamam)                  as bekleyen_gun
from pdks.gun_kaydi g
group by 1, 2, 3;

-- Sorun 13: İK sabah ekranı - dün gece işi başarıyla çalıştı mı?
create or replace view pdks.v_gece_isi_durumu as
select current_date - 1 as gun,
       exists (select 1 from pdks.gece_isi
               where islenen_gun = current_date - 1 and durum = 'basarili') as calisti;
