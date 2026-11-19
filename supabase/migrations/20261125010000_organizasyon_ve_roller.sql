-- =====================================================================
-- Organizasyon ve roller
--
--   1. departman.yaka: mavi (üretim / saha) ya da beyaz (ofis)
--   2. Yeni roller:
--        isg   : İSG uzmanı. Çalışan listesini ve departmanları görür; İSG
--                kayıtları ve uyarıları ayrı migration'da eklenir.
--        admin : sistem yöneticisi. Kullanıcıları ve ayarları yönetir
--                (kullanici_ekle, kullanici_guncelle, ayar_guncelle). Gün kaydı,
--                izin, düzeltme, puantaj gibi çalışan kayıtlarını göremez ve
--                bunlar üzerinde karar veremez (karar fonksiyonları yalnızca
--                amir / İK kabul eder).
--   3. Ayar değişikliği artık yalnızca admin'in ekran fonksiyonuyla yapılır;
--      değişiklik kim tarafından yapıldığıyla ayar_gecmisi'ne yazılır.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Yaka
-- ---------------------------------------------------------------------
alter table pdks.departman
    add column yaka text not null default 'mavi' check (yaka in ('mavi', 'beyaz'));
comment on column pdks.departman.yaka is 'mavi: üretim / saha, beyaz: yönetim / ofis.';

-- ---------------------------------------------------------------------
-- 2. Roller (check kısıtı eski değerler korunarak genişletilir)
--    Migration'lar aynı oturumda çalışabildiği için geçici yardımcı
--    "create or replace" ile tanımlanır ve işi bitince silinir.
-- ---------------------------------------------------------------------
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

select pg_temp.kisit_genislet('pdks.kullanici', 'kullanici_rol_check', 'rol', array['isg', 'admin']);
drop function pg_temp.kisit_genislet(regclass, text, text, text[]);

comment on column pdks.kullanici.rol is
    'amir, ik, guvenlik, yonetici, isg (İSG uzmanı), admin (sistem yöneticisi: kullanıcı ve ayar; çalışan kayıtlarını görmez).';

-- ---------------------------------------------------------------------
-- 3. Okuma yetkileri (RLS)
-- ---------------------------------------------------------------------
create policy isg_okur on pdks.calisan for select to authenticated using (pdks.oturum_rolu() = 'isg');

create policy admin_okur on pdks.kullanici    for select to authenticated using (pdks.oturum_rolu() = 'admin');
create policy admin_okur on pdks.calisan      for select to authenticated using (pdks.oturum_rolu() = 'admin');
create policy admin_okur on pdks.ayar         for select to authenticated using (pdks.oturum_rolu() = 'admin');
create policy admin_okur on pdks.ayar_gecmisi for select to authenticated using (pdks.oturum_rolu() = 'admin');
create policy admin_okur on pdks.okuyucu      for select to authenticated using (pdks.oturum_rolu() = 'admin');
create policy admin_okur on pdks.gece_isi     for select to authenticated using (pdks.oturum_rolu() = 'admin');

-- ---------------------------------------------------------------------
-- 4. Ekran fonksiyonları (yalnızca admin)
-- ---------------------------------------------------------------------

-- Supabase Auth'ta aynı e-postayla açılmış hesap varsa kullanıcıya bağlar
create function pdks.auth_hesabi_bagla(p_kullanici_id bigint)
returns void
language sql
security definer
set search_path = pdks
as $$
    update pdks.kullanici k
    set auth_kullanici_id = u.id
    from auth.users u
    where k.id = p_kullanici_id and k.auth_kullanici_id is null
      and lower(u.email) = lower(k.eposta)
      and not exists (select 1 from pdks.kullanici x where x.auth_kullanici_id = u.id);
$$;

-- Yeni kullanıcı (sisteme giren kişi) tanımlar. Giriş hesabı Supabase Auth'ta aynı e-postayla
-- açılır; hesap varsa hemen, yoksa kullanici_guncelle çağrıldığında bağlanır.
create function pdks.kullanici_ekle(p_ad_soyad text, p_eposta text, p_rol text, p_calisan_id bigint,
                                    p_ust_amir_id bigint default null)
returns bigint
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('admin');
    v_id   bigint;
begin
    if p_ad_soyad is null or length(trim(p_ad_soyad)) < 3 then
        raise exception 'Ad soyad yazılmalı.';
    end if;
    if p_eposta is null or p_eposta !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        raise exception 'Geçerli bir e-posta yazılmalı.';
    end if;
    if p_rol not in ('amir', 'ik', 'guvenlik', 'yonetici', 'isg', 'admin') then
        raise exception 'Geçersiz rol: %', p_rol;
    end if;
    if not exists (select 1 from pdks.calisan where id = p_calisan_id and aktif) then
        raise exception 'Çalışan bulunamadı ya da aktif değil.';
    end if;
    if p_calisan_id = pdks.kullanici_calisani(v_ben) then
        raise exception 'Görevler ayrılığı: kendinize hesap açamazsınız.';
    end if;
    if exists (select 1 from pdks.kullanici where calisan_id = p_calisan_id) then
        raise exception 'Bu çalışanın zaten bir kullanıcı hesabı var.';
    end if;
    if exists (select 1 from pdks.kullanici where lower(eposta) = lower(trim(p_eposta))) then
        raise exception 'Bu e-posta başka bir kullanıcıda kayıtlı.';
    end if;
    if p_ust_amir_id is not null
       and not exists (select 1 from pdks.kullanici where id = p_ust_amir_id and aktif) then
        raise exception 'Üst amir bulunamadı ya da aktif değil.';
    end if;

    insert into pdks.kullanici (ad_soyad, eposta, rol, calisan_id, ust_amir_id)
    values (trim(p_ad_soyad), lower(trim(p_eposta)), p_rol, p_calisan_id, p_ust_amir_id)
    returning id into v_id;
    perform pdks.auth_hesabi_bagla(v_id);
    return v_id;
end;
$$;

-- Kullanıcının rolünü, üst amirini ya da aktifliğini değiştirir (boş bırakılan değişmez).
-- Admin kendi hesabını değiştiremez.
create function pdks.kullanici_guncelle(p_kullanici_id bigint, p_rol text default null,
                                        p_ust_amir_id bigint default null, p_aktif boolean default null)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('admin');
begin
    if p_kullanici_id = v_ben then
        raise exception 'Görevler ayrılığı: kendi hesabınızı değiştiremezsiniz.';
    end if;
    if not exists (select 1 from pdks.kullanici where id = p_kullanici_id) then
        raise exception 'Kullanıcı bulunamadı.';
    end if;
    if p_rol is not null and p_rol not in ('amir', 'ik', 'guvenlik', 'yonetici', 'isg', 'admin') then
        raise exception 'Geçersiz rol: %', p_rol;
    end if;
    if p_ust_amir_id is not null then
        if p_ust_amir_id = p_kullanici_id then
            raise exception 'Kullanıcı kendisinin üst amiri olamaz.';
        end if;
        if not exists (select 1 from pdks.kullanici where id = p_ust_amir_id and aktif) then
            raise exception 'Üst amir bulunamadı ya da aktif değil.';
        end if;
    end if;

    update pdks.kullanici
    set rol         = coalesce(p_rol, rol),
        ust_amir_id = coalesce(p_ust_amir_id, ust_amir_id),
        aktif       = coalesce(p_aktif, aktif)
    where id = p_kullanici_id;
    perform pdks.auth_hesabi_bagla(p_kullanici_id);
end;
$$;

-- Ayar değerini değiştirir; eski / yeni değer ve değiştiren ayar_gecmisi'ne yazılır
create function pdks.ayar_guncelle(p_anahtar text, p_deger integer)
returns void
language plpgsql
security definer
set search_path = pdks
as $$
declare
    v_ben  bigint := pdks.yetki_gerekli('admin');
begin
    if not exists (select 1 from pdks.ayar where anahtar = p_anahtar) then
        raise exception 'Ayar bulunamadı: %', p_anahtar;
    end if;
    if p_deger is null or p_deger < 0 then
        raise exception 'Ayar değeri 0 ya da daha büyük olmalı.';
    end if;
    update pdks.ayar set deger = p_deger, guncelleyen_id = v_ben where anahtar = p_anahtar;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Yetkiler
-- ---------------------------------------------------------------------
revoke execute on function pdks.auth_hesabi_bagla(bigint) from public, anon, authenticated;

revoke execute on function
    pdks.kullanici_ekle(text, text, text, bigint, bigint),
    pdks.kullanici_guncelle(bigint, text, bigint, boolean),
    pdks.ayar_guncelle(text, integer)
from public, anon;
grant execute on function
    pdks.kullanici_ekle(text, text, text, bigint, bigint),
    pdks.kullanici_guncelle(bigint, text, bigint, boolean),
    pdks.ayar_guncelle(text, integer)
to authenticated;
