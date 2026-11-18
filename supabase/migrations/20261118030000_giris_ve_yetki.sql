-- =====================================================================
-- Giriş ve yetki: Supabase Auth + RLS
--
-- Erişim modeli
--   - Kullanıcı Supabase Auth ile giriş yapar. pdks.kullanici satırı
--     auth_kullanici_id ile Auth kullanıcısına, calisan_id ile çalışan
--     kaydına bağlıdır. İkisi de bağlı ve aktif değilse kullanıcı hiçbir
--     satır göremez.
--   - Next.js uygulaması "authenticated" rolüyle bağlanır. Bu rol tabloları
--     yalnızca OKUR; hangi satırları göreceğine RLS politikaları karar verir.
--   - Yazma işlemleri ekran fonksiyonlarıyla (RPC) yapılır; bu dosyada
--     doğrudan yazma yetkisi verilmez.
--   - Gece işi pg_cron ile veritabanı içinde, tablo sahibi olarak çalışır.
--
-- Rol bazında okuma
--   ik, yonetici : tüm tablolar
--   amir         : amiri ya da vekil amiri olduğu departmanların çalışanları,
--                  gün kayıtları, düzeltmeleri, itirazları, vardiya planları,
--                  fazla mesaileri; kendisine gelen sorular. İzni yalnızca
--                  v_izin_amir görünümünden "izinli" olarak görür.
--   guvenlik     : çalışan listesi, geçici kartlar ve zimmetleri
--   herkes       : kendi kullanıcı satırı, departmanlar, vardiya tanımları,
--                  resmi tatiller, dönemler
--
-- Not: pdks şemasının API'den görünmesi için Supabase panelinde
-- Project Settings > API > Exposed schemas listesine "pdks" eklenir.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Oturum yardımcıları
--    SECURITY DEFINER: tablo sahibi olarak çalışır, RLS'ye takılmaz.
--    Böylece politikalar kendi kendini çağırıp döngüye girmez.
-- ---------------------------------------------------------------------
create function pdks.oturum_kullanici_id()
returns bigint
language sql
stable
security definer
set search_path = pdks
as $$
    select id
    from pdks.kullanici
    where auth_kullanici_id = auth.uid()
      and aktif
      and calisan_id is not null;
$$;

create function pdks.oturum_rolu()
returns text
language sql
stable
security definer
set search_path = pdks
as $$
    select rol from pdks.kullanici where id = pdks.oturum_kullanici_id();
$$;

-- Oturumdaki amirin (asıl ya da vekil) sorumlu olduğu departmanlar
create function pdks.oturum_departmanlari()
returns smallint[]
language sql
stable
security definer
set search_path = pdks
as $$
    select coalesce(array_agg(id), '{}')
    from pdks.departman
    where pdks.oturum_rolu() = 'amir'
      and pdks.oturum_kullanici_id() in (amir_id, vekil_amir_id);
$$;

-- Çalışan, oturumdaki amirin departmanında mı?
create function pdks.amirin_calisani_mi(p_calisan_id bigint)
returns boolean
language sql
stable
security definer
set search_path = pdks
as $$
    select exists (
        select 1 from pdks.calisan
        where id = p_calisan_id
          and departman_id = any (pdks.oturum_departmanlari())
    );
$$;

create function pdks.tum_veriyi_gorur()
returns boolean
language sql
stable
security definer
set search_path = pdks
as $$
    select coalesce(pdks.oturum_rolu() in ('ik', 'yonetici'), false);
$$;

revoke execute on function pdks.oturum_kullanici_id(), pdks.oturum_rolu(), pdks.oturum_departmanlari(),
                           pdks.amirin_calisani_mi(bigint), pdks.tum_veriyi_gorur()
       from public;
grant execute on function pdks.oturum_kullanici_id(), pdks.oturum_rolu(), pdks.oturum_departmanlari(),
                          pdks.amirin_calisani_mi(bigint), pdks.tum_veriyi_gorur()
      to authenticated;

-- ---------------------------------------------------------------------
-- 2. Yetkiler: authenticated yalnızca okur
-- ---------------------------------------------------------------------
grant usage on schema pdks to authenticated;
grant select on all tables in schema pdks to authenticated;

-- ---------------------------------------------------------------------
-- 3. RLS: her tabloda açık; ik ve yönetici her şeyi görür
-- ---------------------------------------------------------------------
do $$
declare
    t text;
begin
    for t in select tablename from pg_tables where schemaname = 'pdks'
    loop
        execute format('alter table pdks.%I enable row level security', t);
        execute format(
            'create policy ik_yonetici_okur on pdks.%I for select to authenticated using (pdks.tum_veriyi_gorur())', t);
    end loop;
end;
$$;

-- Herkes: kendi kullanıcı satırı ve ortak tanımlar
create policy kendi_satiri on pdks.kullanici for select to authenticated
    using (id = pdks.oturum_kullanici_id());

create policy oturum_acan_okur on pdks.departman     for select to authenticated using (pdks.oturum_kullanici_id() is not null);
create policy oturum_acan_okur on pdks.vardiya_tanim for select to authenticated using (pdks.oturum_kullanici_id() is not null);
create policy oturum_acan_okur on pdks.resmi_tatil   for select to authenticated using (pdks.oturum_kullanici_id() is not null);
create policy oturum_acan_okur on pdks.donem         for select to authenticated using (pdks.oturum_kullanici_id() is not null);

-- Amir: kendi departmanları
create policy amir_okur on pdks.calisan for select to authenticated
    using (departman_id = any (pdks.oturum_departmanlari()));
create policy amir_okur on pdks.gun_kaydi         for select to authenticated using (pdks.amirin_calisani_mi(calisan_id));
create policy amir_okur on pdks.duzeltme          for select to authenticated using (pdks.amirin_calisani_mi(calisan_id));
create policy amir_okur on pdks.itiraz            for select to authenticated using (pdks.amirin_calisani_mi(calisan_id));
create policy amir_okur on pdks.vardiya_plani     for select to authenticated using (pdks.amirin_calisani_mi(calisan_id));
create policy amir_okur on pdks.fazla_mesai_plani for select to authenticated using (pdks.amirin_calisani_mi(calisan_id));
create policy amir_okur on pdks.amir_sorusu       for select to authenticated
    using (pdks.oturum_rolu() = 'amir'
           and pdks.oturum_kullanici_id() in (atanan_id, eskale_edilen_id));

-- Güvenlik: çalışan listesi ve geçici kartlar
create policy guvenlik_okur on pdks.calisan            for select to authenticated using (pdks.oturum_rolu() = 'guvenlik');
create policy guvenlik_okur on pdks.gecici_kart        for select to authenticated using (pdks.oturum_rolu() = 'guvenlik');
create policy guvenlik_okur on pdks.gecici_kart_zimmet for select to authenticated using (pdks.oturum_rolu() = 'guvenlik');

-- ---------------------------------------------------------------------
-- 4. Görünümler
--    Görünümler varsayılan olarak sahibinin yetkisiyle çalışır ve RLS'yi
--    atlar. Üç görünüm çağıranın yetkisiyle çalışacak şekilde ayarlanır.
--    v_izin_amir, izin türünü gizlemek için sahibin yetkisiyle çalışır;
--    satırları kendi içinde süzer.
-- ---------------------------------------------------------------------
alter view pdks.v_puantaj_canli      set (security_invoker = true);
alter view pdks.v_fazla_mesai_yillik set (security_invoker = true);
alter view pdks.v_gece_isi_durumu    set (security_invoker = true);

create or replace view pdks.v_izin_amir as
select id, calisan_id, baslangic, bitis, 'izinli'::text as tur
from pdks.izin
where pdks.tum_veriyi_gorur()
   or pdks.amirin_calisani_mi(calisan_id);

grant select on pdks.v_izin_amir to authenticated;

-- ---------------------------------------------------------------------
-- 5. Eski doğrudan bağlantı rolleri
--    Erişim artık Supabase Auth ve RLS ile yapılır.
-- ---------------------------------------------------------------------
do $$
declare
    r text;
begin
    foreach r in array array['pdks_uygulama', 'pdks_gece_isi']
    loop
        if exists (select 1 from pg_roles where rolname = r) then
            execute format('revoke all on all tables in schema pdks from %I', r);
            execute format('revoke all on all sequences in schema pdks from %I', r);
            execute format('revoke all on all functions in schema pdks from %I', r);
            execute format('revoke all on schema pdks from %I', r);
            execute format('revoke all on schema extensions from %I', r);
            execute format('drop role %I', r);
        end if;
    end loop;
end;
$$;

-- Yeni fonksiyonlar herkese açık olmasın (Supabase varsayılanı)
revoke execute on all functions in schema pdks from public, anon;
grant execute on function pdks.oturum_kullanici_id(), pdks.oturum_rolu(), pdks.oturum_departmanlari(),
                          pdks.amirin_calisani_mi(bigint), pdks.tum_veriyi_gorur()
      to authenticated;
