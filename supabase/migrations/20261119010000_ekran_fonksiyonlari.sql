-- =====================================================================
-- Ekran fonksiyonları (RPC)
--
-- Uygulama ("authenticated" rolü) tablolara doğrudan yazamaz. Her yazma
-- işlemi buradaki fonksiyonlardan biriyle yapılır. Her fonksiyon:
--   1. İşlemi yapan kişiyi girişten (Supabase Auth) bulur; parametreyle almaz.
--   2. Rolünü kontrol eder (gerekiyorsa amirin kendi departmanını da).
--   3. İşi mevcut tablolara ve fonksiyonlara yaptırır; kuralları trigger'lar korur.
-- Fonksiyonlar tablo sahibi olarak çalışır (SECURITY DEFINER), bu yüzden
-- içlerindeki yetki kontrolleri zorunludur.
--
-- Ekrandan çağrı (supabase-js):
--   await supabase.schema('pdks').rpc('soru_cevapla', { p_soru_id: 12, p_cevap: 'geldi_saat_dogru' })
-- Ayrıntı ve tüm liste: docs/ekran_fonksiyonlari.md
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Ortak yardımcılar
-- ---------------------------------------------------------------------

-- Oturumdaki kullanıcı verilen rollerden biri değilse işlemi durdurur; id döner
create function pdks.yetki_gerekli(variadic p_roller text[])
returns bigint
language plpgsql
stable
security definer
set search_path = pdks
as $$
declare
    v_id  bigint := pdks.oturum_kullanici_id();
begin
    if v_id is null then
        raise exception 'Oturum bulunamadı ya da hesap bir çalışana bağlı değil.';
    end if;
    if not (pdks.oturum_rolu() = any (p_roller)) then
        raise exception 'Bu işlem için yetkiniz yok.';
    end if;
    return v_id;
end;
$$;

-- Amir yalnızca kendi departmanının çalışanında işlem yapar; İK herkeste
create function pdks.calisan_yetkisi(p_calisan_id bigint)
returns void
language plpgsql
stable
security definer
set search_path = pdks
as $$
begin
    if pdks.oturum_rolu() = 'amir' and not pdks.amirin_calisani_mi(p_calisan_id) then
        raise exception 'Bu çalışan sizin departmanınızda değil.';
    end if;
end;
$$;

-- Bir gün kaydının, soru türüne göre eksik saatini/saatlerini yazar
create function pdks.saat_yaz(p_gun_kaydi_id bigint, p_giris timestamptz, p_cikis timestamptz,
                              p_gerekce text, p_kaynak text, p_yapan_id bigint,
                              p_soru_id bigint default null, p_itiraz_id bigint default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
begin
    if p_giris is not null then
        perform pdks.duzeltme_uygula(p_gun_kaydi_id, 'giris_zamani', p_giris::text, p_gerekce, p_kaynak, p_yapan_id,
                                     p_soru_id => p_soru_id, p_itiraz_id => p_itiraz_id);
    end if;
    if p_cikis is not null then
        perform pdks.duzeltme_uygula(p_gun_kaydi_id, 'cikis_zamani', p_cikis::text, p_gerekce, p_kaynak, p_yapan_id,
                                     p_soru_id => p_soru_id, p_itiraz_id => p_itiraz_id);
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Amir
-- ---------------------------------------------------------------------

-- Amire gelen soruyu cevaplar.
--   geldi_saat_dogru  : önerilen saat (yoksa vardiyanın planlı saati) yazılır
--   geldi_saat_farkli : amirin girdiği saat(ler) yazılır
--   kart_unuttu       : amirin girdiği saat(ler) yazılır; yoksa geldi_saat_dogru gibi
--   gelmedi, bilmiyorum : kayıt değişmez, karar İK'ya geçer
create function pdks.soru_cevapla(p_soru_id bigint, p_cevap text,
                                  p_giris timestamptz default null, p_cikis timestamptz default null,
                                  p_aciklama text default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben    bigint := pdks.yetki_gerekli('amir');
    v_soru   pdks.amir_sorusu;
    v_gun    pdks.gun_kaydi;
    v_giris  timestamptz;
    v_cikis  timestamptz;
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
            raise exception 'Bu soru türünde saatleri girin.';
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
        perform pdks.saat_yaz(v_soru.gun_kaydi_id, v_giris, v_cikis,
                              'Amir cevabı: ' || p_cevap || coalesce(' (' || p_aciklama || ')', ''),
                              'amir', v_ben, p_soru_id => p_soru_id);
    end if;
end;
$$;

-- Çalışanın sözlü/yazılı itirazını sisteme girer (amir kendi departmanı için, İK herkes için)
create function pdks.itiraz_gir(p_gun_kaydi_id bigint, p_metin text)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben      bigint := pdks.yetki_gerekli('amir', 'ik');
    v_calisan  bigint;
    v_id       bigint;
begin
    select calisan_id into v_calisan from pdks.gun_kaydi where id = p_gun_kaydi_id;
    if v_calisan is null then
        raise exception 'Gün kaydı bulunamadı.';
    end if;
    perform pdks.calisan_yetkisi(v_calisan);
    if pdks.kullanici_calisani(v_ben) = v_calisan then
        raise exception 'Görevler ayrılığı: kendi itirazınızı giremezsiniz.';
    end if;
    insert into pdks.itiraz (calisan_id, gun_kaydi_id, metin)
    values (v_calisan, p_gun_kaydi_id, p_metin)
    returning id into v_id;
    return v_id;
end;
$$;

-- Fazla mesai talebi (amir kendi departmanı için, İK herkes için); vardiya plandan alınır
create function pdks.fazla_mesai_talep_et(p_calisan_id bigint, p_is_gunu date, p_planli_dk integer, p_gerekce text)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('amir', 'ik');
    v_id   bigint;
begin
    perform pdks.calisan_yetkisi(p_calisan_id);
    insert into pdks.fazla_mesai_plani (calisan_id, is_gunu, vardiya_id, planli_dk, gerekce, talep_eden_id)
    values (p_calisan_id, p_is_gunu,
            (select vardiya_id from pdks.vardiya_plani where calisan_id = p_calisan_id and tarih = p_is_gunu),
            p_planli_dk, p_gerekce, v_ben)
    returning id into v_id;
    return v_id;
end;
$$;

-- Vardiya planı girer ya da değiştirir. Geçmiş gün için girilen plan İK onayı bekler.
create function pdks.vardiya_plani_gir(p_calisan_id bigint, p_tarih date, p_vardiya_id smallint,
                                       p_aciklama text default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben     bigint := pdks.yetki_gerekli('amir', 'ik');
    v_geri    boolean := p_tarih < current_date;
    v_id      bigint;
begin
    perform pdks.calisan_yetkisi(p_calisan_id);
    if pdks.donem_kilitli_mi(p_tarih) then
        raise exception '% günü kilitli bir döneme ait.', p_tarih;
    end if;
    insert into pdks.vardiya_plani (calisan_id, tarih, vardiya_id, giren_id, giris_zamani,
                                    geriye_donuk, ik_onay_durumu, aciklama)
    values (p_calisan_id, p_tarih, p_vardiya_id, v_ben, now(),
            v_geri, case when v_geri then 'bekliyor' else 'gerekmez' end, p_aciklama)
    on conflict (calisan_id, tarih) do update
        set vardiya_id = excluded.vardiya_id, giren_id = excluded.giren_id, giris_zamani = excluded.giris_zamani,
            geriye_donuk = excluded.geriye_donuk, ik_onay_durumu = excluded.ik_onay_durumu,
            aciklama = excluded.aciklama
    returning id into v_id;
    return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Güvenlik
-- ---------------------------------------------------------------------

create function pdks.gecici_kart_ver(p_gecici_kart_id bigint, p_calisan_id bigint, p_aciklama text default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('guvenlik', 'ik');
    v_id   bigint;
begin
    insert into pdks.gecici_kart_zimmet (gecici_kart_id, calisan_id, verilis_zamani, veren_id, aciklama)
    values (p_gecici_kart_id, p_calisan_id, clock_timestamp(), v_ben, p_aciklama)
    returning id into v_id;
    return v_id;
end;
$$;

create function pdks.gecici_kart_iade_al(p_zimmet_id bigint)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('guvenlik', 'ik');
begin
    update pdks.gecici_kart_zimmet set iade_zamani = clock_timestamp(), iade_alan_id = v_ben
    where id = p_zimmet_id and iade_zamani is null;
    if not found then
        raise exception 'Açık zimmet bulunamadı.';
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. İK
-- ---------------------------------------------------------------------

create function pdks.uyari_goruldu(p_uyari_id bigint)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    update pdks.uyari set goruldu = true, goren_id = v_ben, gorulme_zamani = now()
    where id = p_uyari_id and not goruldu;
    if not found then
        raise exception 'Uyarı bulunamadı ya da zaten görülmüş.';
    end if;
end;
$$;

-- Amirin "gelmedi" ya da "bilmiyorum" dediği soruya İK kararı.
--   p_devamsiz = true  : gün "devamsız" olur (çalışan aleyhine karar, yalnızca İK)
--   p_devamsiz = false : verilen saat(ler) yazılır
create function pdks.soru_ik_karari(p_soru_id bigint, p_devamsiz boolean, p_gerekce text,
                                    p_giris timestamptz default null, p_cikis timestamptz default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben   bigint := pdks.yetki_gerekli('ik');
    v_soru  pdks.amir_sorusu;
begin
    select * into v_soru from pdks.amir_sorusu where id = p_soru_id for update;
    if not found or v_soru.durum <> 'ik_karari_bekliyor' then
        raise exception 'İK kararı bekleyen soru bulunamadı.';
    end if;
    if not p_devamsiz and p_giris is null and p_cikis is null then
        raise exception 'Devamsız değilse giriş ya da çıkış saatini girin.';
    end if;

    update pdks.amir_sorusu
    set durum = 'kapandi', cevaplayan_id = v_ben,
        cevap_aciklama = concat_ws(' | ', cevap_aciklama, 'İK: ' || p_gerekce)
    where id = p_soru_id;

    if p_devamsiz then
        perform pdks.duzeltme_uygula(v_soru.gun_kaydi_id, 'durum', 'devamsiz', p_gerekce, 'ik', v_ben,
                                     p_soru_id => p_soru_id, p_aleyhine => true);
    else
        perform pdks.saat_yaz(v_soru.gun_kaydi_id, p_giris, p_cikis, p_gerekce, 'ik', v_ben, p_soru_id => p_soru_id);
    end if;
end;
$$;

create function pdks.itiraz_incelemeye_al(p_itiraz_id bigint)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
begin
    perform pdks.yetki_gerekli('ik');
    update pdks.itiraz set durum = 'inceleniyor' where id = p_itiraz_id and durum = 'acik';
    if not found then
        raise exception 'Açık itiraz bulunamadı.';
    end if;
end;
$$;

-- İtiraz kararı. Kabulde kayıt düzeltmesi ayrıca kayit_duzelt(..., p_itiraz_id) ile yapılır.
create function pdks.itiraz_karar(p_itiraz_id bigint, p_kabul boolean, p_aciklama text)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    update pdks.itiraz
    set durum = case when p_kabul then 'kabul' else 'red' end, karar_veren_id = v_ben, karar_aciklama = p_aciklama
    where id = p_itiraz_id and durum in ('acik', 'inceleniyor');
    if not found then
        raise exception 'Karar bekleyen itiraz bulunamadı.';
    end if;
end;
$$;

-- İK'nın bir gün kaydını düzeltmesi. "devamsiz" yazmak çalışan aleyhine karar sayılır.
create function pdks.kayit_duzelt(p_gun_kaydi_id bigint, p_alan text, p_yeni_deger text, p_gerekce text,
                                  p_itiraz_id bigint default null, p_izin_id bigint default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    return pdks.duzeltme_uygula(p_gun_kaydi_id, p_alan, p_yeni_deger, p_gerekce, 'ik', v_ben,
                                p_izin_id => p_izin_id, p_itiraz_id => p_itiraz_id,
                                p_aleyhine => (p_alan = 'durum' and p_yeni_deger = 'devamsiz'));
end;
$$;

-- Geçmiş güne girilmiş vardiya planını onaylar ya da reddeder (planı giren kişi onaylayamaz)
create function pdks.vardiya_plani_onayla(p_plan_id bigint, p_onay boolean)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
    v_plan pdks.vardiya_plani;
begin
    select * into v_plan from pdks.vardiya_plani where id = p_plan_id for update;
    if not found or v_plan.ik_onay_durumu <> 'bekliyor' then
        raise exception 'Onay bekleyen plan bulunamadı.';
    end if;
    if v_plan.giren_id = v_ben then
        raise exception 'Görevler ayrılığı: kendi girdiğiniz planı onaylayamazsınız.';
    end if;
    update pdks.vardiya_plani set ik_onay_durumu = case when p_onay then 'onaylandi' else 'reddedildi' end
    where id = p_plan_id;
end;
$$;

create function pdks.izin_gir(p_calisan_id bigint, p_tur text, p_baslangic date, p_bitis date,
                              p_aciklama text default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
    v_id   bigint;
begin
    insert into pdks.izin (calisan_id, tur, baslangic, bitis, aciklama, giren_id)
    values (p_calisan_id, p_tur, p_baslangic, p_bitis, p_aciklama, v_ben)
    returning id into v_id;
    return v_id;
end;
$$;

create function pdks.fazla_mesai_karar(p_plan_id bigint, p_onay boolean, p_aciklama text default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    update pdks.fazla_mesai_plani
    set durum = case when p_onay then 'onaylandi' else 'reddedildi' end,
        karar_veren_id = v_ben, karar_zamani = now(), karar_aciklama = p_aciklama
    where id = p_plan_id and durum = 'talep';
    if not found then
        raise exception 'Karar bekleyen fazla mesai talebi bulunamadı.';
    end if;
end;
$$;

create function pdks.fazla_mesai_onayi_gir(p_calisan_id bigint, p_yil smallint, p_imza_tarihi date, p_belge_no text)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
    v_id   bigint;
begin
    insert into pdks.fazla_mesai_onayi (calisan_id, yil, imza_tarihi, belge_no, giren_id)
    values (p_calisan_id, p_yil, p_imza_tarihi, p_belge_no, v_ben)
    returning id into v_id;
    return v_id;
end;
$$;

create function pdks.fazla_mesai_onayi_geri_al(p_onay_id bigint, p_bildirim_tarihi date)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    update pdks.fazla_mesai_onayi
    set geri_alma_bildirim_tarihi = p_bildirim_tarihi, geri_alma_giren_id = v_ben
    where id = p_onay_id;
    if not found then
        raise exception 'Yazılı onay bulunamadı.';
    end if;
end;
$$;

create function pdks.kart_iptal_et(p_kart_id bigint, p_neden text)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    update pdks.kart set durum = 'iptal', iptal_nedeni = p_neden, iptal_zamani = now(), iptal_eden_id = v_ben
    where id = p_kart_id and durum = 'aktif';
    if not found then
        raise exception 'Aktif kart bulunamadı.';
    end if;
end;
$$;

create function pdks.kart_tanimla(p_calisan_id bigint, p_kart_no text)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_id  bigint;
begin
    perform pdks.yetki_gerekli('ik');
    if exists (select 1 from pdks.kart where calisan_id = p_calisan_id and durum = 'aktif') then
        raise exception 'Çalışanın aktif kartı var; önce iptal edin.';
    end if;
    insert into pdks.kart (kart_no, calisan_id) values (p_kart_no, p_calisan_id)
    returning id into v_id;
    return v_id;
end;
$$;

create function pdks.ariza_gir(p_okuyucu_id smallint, p_baslangic timestamptz, p_bitis timestamptz default null,
                               p_aciklama text default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
    v_id   bigint;
begin
    insert into pdks.ariza (okuyucu_id, baslangic, bitis, kaynak, durum, aciklama, giren_id)
    values (p_okuyucu_id, p_baslangic, p_bitis, 'manuel', 'onaylandi', p_aciklama, v_ben)
    returning id into v_id;
    return v_id;
end;
$$;

-- Gece işinin bulduğu arıza şüphesini onaylar ya da reddeder
create function pdks.ariza_karar(p_ariza_id bigint, p_onay boolean)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    update pdks.ariza set durum = case when p_onay then 'onaylandi' else 'reddedildi' end, giren_id = v_ben
    where id = p_ariza_id and durum = 'suphe';
    if not found then
        raise exception 'Şüphe durumunda arıza bulunamadı.';
    end if;
end;
$$;

create function pdks.ay_kilitle(p_yil smallint, p_ay smallint, p_zorla boolean default false)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('ik');
begin
    perform pdks.donem_kilitle(pdks.donem_bul(make_date(p_yil, p_ay, 1)), v_ben, p_zorla);
end;
$$;

-- Okutma dosyasını yükler. Satırlar JSON dizisidir:
--   [{"okuyucu": "PDKS-1", "kart_no": "K1001", "zaman": "2026-11-02T07:51:12+03:00", "yon": "giris"}, ...]
-- Aynı içerik ikinci kez yüklenemez (dosya özeti satırlardan hesaplanır).
create function pdks.dosya_yukle(p_kaynak text, p_dosya_adi text, p_veri_tarihi date, p_satirlar jsonb)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_aktarim  bigint;
    v_ozet     text := md5(p_satirlar::text);
    v_hatali   text;
begin
    perform pdks.yetki_gerekli('ik');
    if jsonb_typeof(p_satirlar) <> 'array' or jsonb_array_length(p_satirlar) = 0 then
        raise exception 'Dosyada satır yok.';
    end if;
    if exists (select 1 from pdks.aktarim where kaynak = p_kaynak and dosya_ozeti = v_ozet) then
        raise exception 'Bu dosya daha önce yüklenmiş.';
    end if;

    select s ->> 'okuyucu' into v_hatali
    from jsonb_array_elements(p_satirlar) s
    left join pdks.okuyucu r on r.kod = s ->> 'okuyucu' and r.sistem = p_kaynak
    where r.id is null
    limit 1;
    if found then
        raise exception 'Okuyucu tanımlı değil ya da bu kaynağa ait değil: %', coalesce(v_hatali, '(boş)');
    end if;

    insert into pdks.aktarim (kaynak, dosya_adi, dosya_ozeti, veri_tarihi, satir_sayisi)
    values (p_kaynak, p_dosya_adi, v_ozet, p_veri_tarihi, jsonb_array_length(p_satirlar))
    returning id into v_aktarim;

    if p_kaynak = 'pdks' then
        insert into pdks.ham_okutma (aktarim_id, okuyucu_id, kart_no, okutma_zamani, yon)
        select v_aktarim, r.id, s ->> 'kart_no', (s ->> 'zaman')::timestamptz, nullif(s ->> 'yon', '')
        from jsonb_array_elements(p_satirlar) s
        join pdks.okuyucu r on r.kod = s ->> 'okuyucu'
        on conflict (okuyucu_id, kart_no, okutma_zamani) do nothing;
    else
        insert into pdks.kanit_kaydi (aktarim_id, okuyucu_id, kaynak, kart_no, okutma_zamani, yon)
        select v_aktarim, r.id, p_kaynak, s ->> 'kart_no', (s ->> 'zaman')::timestamptz, nullif(s ->> 'yon', '')
        from jsonb_array_elements(p_satirlar) s
        join pdks.okuyucu r on r.kod = s ->> 'okuyucu'
        on conflict (okuyucu_id, kart_no, okutma_zamani) do nothing;
    end if;

    return v_aktarim;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Yetkiler: yalnızca giriş yapmış kullanıcılar çağırabilir
-- ---------------------------------------------------------------------
revoke execute on all functions in schema pdks from public, anon;

grant execute on function
    pdks.soru_cevapla(bigint, text, timestamptz, timestamptz, text),
    pdks.itiraz_gir(bigint, text),
    pdks.fazla_mesai_talep_et(bigint, date, integer, text),
    pdks.vardiya_plani_gir(bigint, date, smallint, text),
    pdks.gecici_kart_ver(bigint, bigint, text),
    pdks.gecici_kart_iade_al(bigint),
    pdks.uyari_goruldu(bigint),
    pdks.soru_ik_karari(bigint, boolean, text, timestamptz, timestamptz),
    pdks.itiraz_incelemeye_al(bigint),
    pdks.itiraz_karar(bigint, boolean, text),
    pdks.kayit_duzelt(bigint, text, text, text, bigint, bigint),
    pdks.vardiya_plani_onayla(bigint, boolean),
    pdks.izin_gir(bigint, text, date, date, text),
    pdks.fazla_mesai_karar(bigint, boolean, text),
    pdks.fazla_mesai_onayi_gir(bigint, smallint, date, text),
    pdks.fazla_mesai_onayi_geri_al(bigint, date),
    pdks.kart_iptal_et(bigint, text),
    pdks.kart_tanimla(bigint, text),
    pdks.ariza_gir(smallint, timestamptz, timestamptz, text),
    pdks.ariza_karar(bigint, boolean),
    pdks.ay_kilitle(smallint, smallint, boolean),
    pdks.dosya_yukle(text, text, date, jsonb)
to authenticated;
