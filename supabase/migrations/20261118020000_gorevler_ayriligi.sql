-- =====================================================================
-- Görevler ayrılığı: kimse kendi kaydında işlem yapamaz
--
-- Sisteme giren her kullanıcı aynı zamanda kart basan bir çalışandır.
-- kullanici.calisan_id bu bağı kurar. Bağ kurulunca:
--   - İK kendi gün kaydını düzeltemez, kendi itirazına karar veremez,
--     kendi iznini / vardiyasını / yazılı fazla mesai onayını giremez,
--     kendisiyle ilgili uyarıyı "görüldü" yapamaz, kendi kartını iptal edemez.
--   - Amir kendi hakkındaki soruyu cevaplayamaz (soru üst amirine gider),
--     kendi fazla mesaisini talep edemez ve onaylayamaz.
--   - Güvenlik kendine geçici kart veremez, kendi iadesini alamaz.
-- Fazla mesaide talep eden ile onaylayan da aynı kişi olamaz.
--
-- Kurallar trigger olduğu için ekran atlansa da delinemez.
-- Çalışana bağlı olmayan kullanıcı sisteme giriş yapamaz
-- (bkz. 20261118030000_giris_ve_yetki.sql, pdks.oturum_kullanici_id).
-- =====================================================================

alter table pdks.kullanici
    add column calisan_id bigint unique references pdks.calisan (id);

comment on column pdks.kullanici.calisan_id is
    'Kullanıcının çalışan kaydı. Görevler ayrılığı bu bağ üzerinden kontrol edilir.';

-- Kullanıcının çalışan kaydı (yoksa null)
create function pdks.kullanici_calisani(p_kullanici_id bigint)
returns bigint
language sql
stable
set search_path = pdks
as $$
    select calisan_id from pdks.kullanici where id = p_kullanici_id;
$$;

-- ---------------------------------------------------------------------
-- Genel kural: işlemi yapan kişinin çalışan kaydı, işlem yapılan kayıttaki
-- çalışanla aynıysa işlem reddedilir.
--   TG_ARGV[0]  : çalışanın nereden okunacağı
--                 'calisan'   -> satırdaki calisan_id
--                 'gun_kaydi' -> satırdaki gun_kaydi_id üzerinden
--   TG_ARGV[1..]: işlemi yapan kişiyi tutan sütunlar (kullanici.id)
-- Yalnızca yeni yazılan ya da değişen kişi sütunu kontrol edilir.
-- ---------------------------------------------------------------------
create function pdks.kendi_kaydi_engelle()
returns trigger
language plpgsql
set search_path = pdks
as $$
declare
    v_yeni     jsonb := to_jsonb(new);
    v_eski     jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
    v_calisan  bigint;
    v_sutun    text;
    v_kisi     bigint;
    i          int;
begin
    if tg_argv[0] = 'gun_kaydi' then
        select calisan_id into v_calisan
        from pdks.gun_kaydi where id = (v_yeni ->> 'gun_kaydi_id')::bigint;
    else
        v_calisan := (v_yeni ->> 'calisan_id')::bigint;
    end if;

    if v_calisan is null then
        return new;
    end if;

    for i in 1 .. tg_nargs - 1 loop
        v_sutun := tg_argv[i];
        v_kisi  := (v_yeni ->> v_sutun)::bigint;
        if v_kisi is not null
           and (tg_op = 'INSERT' or v_kisi is distinct from (v_eski ->> v_sutun)::bigint)
           and pdks.kullanici_calisani(v_kisi) = v_calisan then
            raise exception 'Görevler ayrılığı: kimse kendi kaydında işlem yapamaz (%.%).',
                tg_table_name, v_sutun;
        end if;
    end loop;

    return new;
end;
$$;

create trigger duzeltme_gorev_ayriligi before insert on pdks.duzeltme
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'yapan_id');

create trigger itiraz_gorev_ayriligi before insert or update on pdks.itiraz
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'karar_veren_id');

create trigger fazla_mesai_plani_gorev_ayriligi before insert or update on pdks.fazla_mesai_plani
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'talep_eden_id', 'karar_veren_id');

create trigger fazla_mesai_onayi_gorev_ayriligi before insert or update on pdks.fazla_mesai_onayi
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'giren_id', 'geri_alma_giren_id');

create trigger gecici_kart_zimmet_gorev_ayriligi before insert or update on pdks.gecici_kart_zimmet
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'veren_id', 'iade_alan_id');

create trigger izin_gorev_ayriligi before insert or update on pdks.izin
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'giren_id');

create trigger vardiya_plani_gorev_ayriligi before insert or update on pdks.vardiya_plani
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'giren_id');

create trigger uyari_gorev_ayriligi before insert or update on pdks.uyari
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'goren_id');

create trigger kart_gorev_ayriligi before insert or update on pdks.kart
    for each row execute function pdks.kendi_kaydi_engelle('calisan', 'iptal_eden_id');

create trigger amir_sorusu_gorev_ayriligi before insert or update on pdks.amir_sorusu
    for each row execute function pdks.kendi_kaydi_engelle('gun_kaydi', 'atanan_id', 'eskale_edilen_id', 'cevaplayan_id');

-- ---------------------------------------------------------------------
-- Amir kendi hakkındaki soruya atanırsa soru üst amirine yönlendirilir.
-- (Trigger adı "amir_sorusu_a..." ile başlar; genel kuraldan önce çalışır.)
-- ---------------------------------------------------------------------
create function pdks.amir_sorusu_yonlendir()
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
        if v_ust is null then
            raise exception 'Soru amirin kendisiyle ilgili ve üst amiri tanımlı değil.';
        end if;
        new.atanan_id := v_ust;
    end if;
    return new;
end;
$$;

create trigger amir_sorusu_a_yonlendir before insert on pdks.amir_sorusu
    for each row execute function pdks.amir_sorusu_yonlendir();

-- Fazla mesaide talep eden ile onaylayan aynı kişi olamaz
alter table pdks.fazla_mesai_plani
    add constraint fazla_mesai_talep_onay_farkli
    check (karar_veren_id is null or talep_eden_id is null or karar_veren_id <> talep_eden_id) not valid;

revoke execute on function pdks.kullanici_calisani(bigint), pdks.kendi_kaydi_engelle(),
                           pdks.amir_sorusu_yonlendir()
       from public;
