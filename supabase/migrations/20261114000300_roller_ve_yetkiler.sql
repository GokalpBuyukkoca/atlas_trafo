-- =====================================================================
-- 3/4: Roller ve yetkiler (sorun 12)
--
-- Gece işi ve Streamlit uygulaması veritabanına AYRI kullanıcılarla bağlanır.
-- Roller burada şifresiz (NOLOGIN) oluşturulur. Şifre koda yazılmaz;
-- Supabase SQL Editor'de elle verilir (bkz. docs/veritabani.md):
--     alter role pdks_uygulama with login password '...';
--     alter role pdks_gece_isi with login password '...';
--
-- Silinemez tablolarda iki kat koruma var:
--   1) Bu dosya: UPDATE / DELETE / TRUNCATE yetkisi hiç verilmez.
--   2) 2. dosya: yetkisi olan biri (ör. postgres) denese bile trigger engeller.
-- =====================================================================

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'pdks_uygulama') then
        create role pdks_uygulama nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'pdks_gece_isi') then
        create role pdks_gece_isi nologin;
    end if;
end;
$$;

-- Supabase'in internete açık API rolleri pdks şemasına hiç erişemez
revoke all on schema pdks from public;
revoke execute on all functions in schema pdks from public;
alter default privileges in schema pdks revoke execute on functions from public;
do $$
declare
    r text;
begin
    foreach r in array array['anon', 'authenticated']
    loop
        if exists (select 1 from pg_roles where rolname = r) then
            execute format('revoke all on schema pdks from %I', r);
            execute format('revoke all on all tables in schema pdks from %I', r);
            execute format('revoke all on all functions in schema pdks from %I', r);
        end if;
    end loop;
end;
$$;

grant usage on schema pdks to pdks_uygulama, pdks_gece_isi;
grant usage on schema extensions to pdks_uygulama, pdks_gece_isi;

-- Herkes her şeyi okuyabilir (ekranlar ve raporlar için)
grant select on all tables in schema pdks to pdks_uygulama, pdks_gece_isi;

-- ---------------------------------------------------------------------
-- Gece işi (Python betiği, Windows Görev Zamanlayıcı)
-- ---------------------------------------------------------------------
grant insert on pdks.aktarim, pdks.ham_okutma, pdks.kanit_kaydi, pdks.okutma_isareti,
                pdks.gece_isi, pdks.gun_kaydi, pdks.amir_sorusu, pdks.ariza, pdks.uyari,
                pdks.duzeltme, pdks.donem
      to pdks_gece_isi;
grant update on pdks.gece_isi, pdks.gun_kaydi, pdks.amir_sorusu, pdks.ariza
      to pdks_gece_isi;

-- ---------------------------------------------------------------------
-- Streamlit uygulaması (amir, İK ve kiosk ekranları)
-- ---------------------------------------------------------------------
grant insert, update on pdks.kullanici, pdks.departman, pdks.calisan, pdks.kart, pdks.okuyucu,
                        pdks.vardiya_tanim, pdks.vardiya_plani, pdks.izin, pdks.resmi_tatil,
                        pdks.ariza, pdks.amir_sorusu, pdks.itiraz, pdks.uyari
      to pdks_uygulama;
grant update on pdks.ayar, pdks.gun_kaydi, pdks.donem to pdks_uygulama;
grant insert on pdks.duzeltme, pdks.puantaj_satiri, pdks.donem, pdks.ayar_gecmisi to pdks_uygulama;
-- Yanlış girilen plan/tatil silinebilir; geri kalan hiçbir tabloda silme yok
grant delete on pdks.vardiya_plani, pdks.resmi_tatil to pdks_uygulama;

-- Silinemez tablolarda kesinlikle UPDATE / DELETE / TRUNCATE yok
revoke update, delete, truncate on pdks.aktarim, pdks.ham_okutma, pdks.kanit_kaydi,
                                  pdks.okutma_isareti, pdks.duzeltme, pdks.puantaj_satiri,
                                  pdks.ayar_gecmisi
       from pdks_uygulama, pdks_gece_isi;

-- ---------------------------------------------------------------------
-- Fonksiyonlar
-- ---------------------------------------------------------------------
grant execute on function pdks.ayar_al(text), pdks.donem_bul(date), pdks.donem_kilitli_mi(date),
                          pdks.kullanici_rolu(bigint),
                          pdks.duzeltme_uygula(bigint, text, text, text, text, bigint, bigint,
                                               bigint, bigint, bigint, bigint, boolean)
      to pdks_uygulama, pdks_gece_isi;
grant execute on function pdks.donem_kilitle(bigint, bigint, boolean),
                          pdks.kiosk_giris(text, text),
                          pdks.kiosk_pin_degistir(text, text, text),
                          pdks.pin_sifirla(bigint, text, bigint)
      to pdks_uygulama;
-- Tetikleyici fonksiyonları tablo işlemleri sırasında zaten çalışır
grant execute on function pdks.degistirilemez(), pdks.ayar_iz(), pdks.donem_kontrol(),
                          pdks.puantaj_kontrol(), pdks.duzeltme_hazirla(), pdks.gun_kaydi_koru(),
                          pdks.amir_sorusu_kontrol(), pdks.itiraz_kontrol()
      to pdks_uygulama, pdks_gece_isi;
grant execute on function extensions.crypt(text, text), extensions.gen_salt(text)
      to pdks_uygulama;
