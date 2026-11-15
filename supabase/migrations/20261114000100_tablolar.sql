-- =====================================================================
-- Atlas Trafo PDKS Kayıt Düzeltme Sistemi
-- 1/4: Şema ve tablolar
--
-- Tablolar "pdks" şemasında durur. Supabase'in otomatik REST API'si
-- yalnızca "public" şemasını açar; böylece tablolar internete açılmaz.
-- Streamlit ve gece işi veritabanına kendi rolleriyle doğrudan bağlanır
-- (bkz. 20261114000300_roller_ve_yetkiler.sql).
-- Tüm zamanlar timestamptz (saat dilimli), Türkiye saati: Europe/Istanbul.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;  -- PIN özeti (hash) için

create schema if not exists pdks;
comment on schema pdks is 'Atlas Trafo PDKS kayıt düzeltme sistemi';

-- ---------------------------------------------------------------------
-- Ana veriler: kullanıcılar, departmanlar, çalışanlar, kartlar
-- ---------------------------------------------------------------------

-- Sistemi kullanan amir / İK / yönetici hesapları
create table pdks.kullanici (
    id                 bigint generated always as identity primary key,
    ad_soyad           text not null,
    eposta             text not null unique,
    rol                text not null check (rol in ('amir', 'ik', 'yonetici')),
    ust_amir_id        bigint references pdks.kullanici (id),   -- sorun 13: 3 gün cevapsız soru buraya gider
    izinli_mi          boolean not null default false,          -- sorun 13: izinliyse soru vekile gider
    auth_kullanici_id  uuid unique,                             -- ileride Supabase Auth ile eşlemek için
    aktif              boolean not null default true,
    olusturma_zamani   timestamptz not null default now()
);

create table pdks.departman (
    id             smallint generated always as identity primary key,
    ad             text not null unique,
    amir_id        bigint references pdks.kullanici (id),
    vekil_amir_id  bigint references pdks.kullanici (id)
);

create table pdks.calisan (
    id                  bigint generated always as identity primary key,
    sicil_no            text not null unique,
    ad                  text not null,
    soyad               text not null,
    departman_id        smallint not null references pdks.departman (id),
    ise_giris_tarihi    date not null,
    isten_cikis_tarihi  date,
    aktif               boolean not null default true,
    -- Kiosk girişi (sorun 17). PIN açık yazılmaz, yalnızca özeti tutulur.
    pin_ozeti           text,
    pin_degismeli       boolean not null default true,   -- ilk girişte PIN değişimi zorunlu
    hatali_pin_sayisi   smallint not null default 0,
    kilitli_mi          boolean not null default false,
    olusturma_zamani    timestamptz not null default now()
);

-- Sorun 4: kayıp / unutulan kart. Kart iptal edilir, yenisi verilir.
create table pdks.kart (
    id              bigint generated always as identity primary key,
    kart_no         text not null unique,
    calisan_id      bigint not null references pdks.calisan (id),
    durum           text not null default 'aktif' check (durum in ('aktif', 'iptal')),
    iptal_nedeni    text check (iptal_nedeni in ('kayip', 'yenilendi', 'isten_cikis', 'diger')),
    verilis_tarihi  date not null default current_date,
    iptal_zamani    timestamptz,
    iptal_eden_id   bigint references pdks.kullanici (id),
    check ((durum = 'aktif') = (iptal_zamani is null))
);
-- Bir çalışanın aynı anda tek aktif kartı olur
create unique index kart_tek_aktif on pdks.kart (calisan_id) where durum = 'aktif';

-- Sorun 5 ve 16: okuyucular ayrı tabloda. PDKS, kapı, yemekhane ve servis okuyucuları.
create table pdks.okuyucu (
    id      smallint generated always as identity primary key,
    kod     text not null unique,
    ad      text not null,
    sistem  text not null check (sistem in ('pdks', 'kapi', 'yemekhane', 'servis')),
    konum   text,
    aktif   boolean not null default true
);

-- ---------------------------------------------------------------------
-- Vardiya, izin, tatil, ayarlar
-- ---------------------------------------------------------------------

-- Sorun 7: vardiya penceresi sayıyla tanımlanır.
create table pdks.vardiya_tanim (
    id                smallint generated always as identity primary key,
    kod               text not null unique,
    ad                text not null,
    baslangic         time not null,
    bitis             time not null,
    gece_yarisini_asar boolean generated always as (bitis <= baslangic) stored,
    pencere_once_dk   integer not null default 120 check (pencere_once_dk >= 0),  -- başlangıçtan önce
    pencere_sonra_dk  integer not null default 240 check (pencere_sonra_dk >= 0), -- bitişten sonra
    aktif             boolean not null default true
);

-- Sorun 8 (basit hali): vardiya planı çalışan + gün bazında.
create table pdks.vardiya_plani (
    id                bigint generated always as identity primary key,
    calisan_id        bigint not null references pdks.calisan (id),
    tarih             date not null,
    vardiya_id        smallint not null references pdks.vardiya_tanim (id),
    geriye_donuk      boolean not null default false,  -- geçmiş bir gün için girildiyse İK onayı gerekir
    ik_onay_durumu    text not null default 'gerekmez'
                      check (ik_onay_durumu in ('gerekmez', 'bekliyor', 'onaylandi', 'reddedildi')),
    giren_id          bigint references pdks.kullanici (id),
    giris_zamani      timestamptz not null default now(),
    aciklama          text,
    unique (calisan_id, tarih)
);

-- Sorun 14 (basit hali): izin ve rapor. "rapor" sağlık verisidir, yalnızca İK görür
-- (amir ekranı v_izin_amir görünümünü kullanır).
create table pdks.izin (
    id            bigint generated always as identity primary key,
    calisan_id    bigint not null references pdks.calisan (id),
    tur           text not null check (tur in ('yillik', 'rapor', 'mazeret', 'ucretsiz', 'diger')),
    baslangic     date not null,
    bitis         date not null,
    aciklama      text,
    giren_id      bigint not null references pdks.kullanici (id),
    giris_zamani  timestamptz not null default now(),
    check (bitis >= baslangic)
);
create index izin_calisan_tarih on pdks.izin (calisan_id, baslangic, bitis);

-- Sorun 9: resmi tatil takvimi
create table pdks.resmi_tatil (
    tarih      date primary key,
    ad         text not null,
    yarim_gun  boolean not null default false
);

-- İK ayar ekranı: yürüme payı, mükerrer eşiği, tolerans vb. (değerler dakika/gün/adet)
create table pdks.ayar (
    anahtar            text primary key,
    deger              integer not null,
    birim              text not null,
    aciklama           text not null,
    guncelleyen_id     bigint references pdks.kullanici (id),
    guncelleme_zamani  timestamptz not null default now()
);

-- Ayar değişikliklerinin izi (silinemez)
create table pdks.ayar_gecmisi (
    id                 bigint generated always as identity primary key,
    anahtar            text not null,
    eski_deger         integer,
    yeni_deger         integer not null,
    guncelleyen_id     bigint references pdks.kullanici (id),
    degisim_zamani     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Ham veriler (her gece içeri alınır, ASLA değiştirilmez)
-- ---------------------------------------------------------------------

-- Sorun 16: aynı dosya iki kez yüklenirse kayıtlar ikiye katlanmasın
create table pdks.aktarim (
    id              bigint generated always as identity primary key,
    kaynak          text not null check (kaynak in ('pdks', 'kapi', 'yemekhane', 'servis')),
    dosya_adi       text not null,
    dosya_ozeti     text not null,          -- dosyanın SHA-256 özeti
    veri_tarihi     date not null,          -- dosyanın ait olduğu gün
    satir_sayisi    integer not null default 0,
    aktarim_zamani  timestamptz not null default now(),
    unique (kaynak, dosya_ozeti)
);

-- Kartlı PDKS okutmaları
create table pdks.ham_okutma (
    id              bigint generated always as identity primary key,
    aktarim_id      bigint not null references pdks.aktarim (id),
    okuyucu_id      smallint not null references pdks.okuyucu (id),
    kart_no         text not null,           -- bilinmeyen kart da gelebilir, bu yüzden FK yok
    okutma_zamani   timestamptz not null,
    yon             text check (yon in ('giris', 'cikis')),  -- okuyucu yön vermiyorsa boş
    alinma_zamani   timestamptz not null default now(),
    unique (okuyucu_id, kart_no, okutma_zamani)
);
create index ham_okutma_kart_zaman on pdks.ham_okutma (kart_no, okutma_zamani);

-- Kanıt kayıtları: tesis kapısı, yemekhane, servis (sorun 1, 2, 5, 16)
create table pdks.kanit_kaydi (
    id              bigint generated always as identity primary key,
    aktarim_id      bigint not null references pdks.aktarim (id),
    okuyucu_id      smallint not null references pdks.okuyucu (id),
    kaynak          text not null check (kaynak in ('kapi', 'yemekhane', 'servis')),
    kart_no         text not null,
    okutma_zamani   timestamptz not null,
    yon             text check (yon in ('giris', 'cikis')),
    alinma_zamani   timestamptz not null default now(),
    unique (okuyucu_id, kart_no, okutma_zamani)
);
create index kanit_kart_zaman on pdks.kanit_kaydi (kart_no, okutma_zamani);

-- Sorun 3 ve 4: ham kayıt silinmez, yalnızca işaretlenir
create table pdks.okutma_isareti (
    id              bigint generated always as identity primary key,
    ham_okutma_id   bigint not null references pdks.ham_okutma (id),
    isaret          text not null check (isaret in ('mukerrer', 'iptal_kart', 'bilinmeyen_kart', 'pencere_disi')),
    aciklama        text,
    gece_isi_id     bigint,                  -- FK aşağıda eklenir
    olusturma_zamani timestamptz not null default now(),
    unique (ham_okutma_id, isaret)
);

-- ---------------------------------------------------------------------
-- Gece işi, arıza, uyarılar
-- ---------------------------------------------------------------------

-- Sorun 13: gece işi çalışmazsa sabah "dün iş çalışmadı" uyarısı
create table pdks.gece_isi (
    id           bigint generated always as identity primary key,
    islenen_gun  date not null,
    baslangic    timestamptz not null default now(),
    bitis        timestamptz,
    durum        text not null default 'calisiyor' check (durum in ('calisiyor', 'basarili', 'hatali')),
    ozet         jsonb not null default '{}'::jsonb,   -- ör. {"duzeltilen": 12, "soru": 4}
    hata_mesaji  text
);
alter table pdks.okutma_isareti
    add foreign key (gece_isi_id) references pdks.gece_isi (id);

-- Sorun 5: okuyucu arıza aralığı (elle girilir ya da sistem şüphe olarak açar)
create table pdks.ariza (
    id            bigint generated always as identity primary key,
    okuyucu_id    smallint not null references pdks.okuyucu (id),
    baslangic     timestamptz not null,
    bitis         timestamptz,
    kaynak        text not null check (kaynak in ('manuel', 'otomatik_suphe')),
    durum         text not null default 'onaylandi' check (durum in ('suphe', 'onaylandi', 'reddedildi')),
    aciklama      text,
    giren_id      bigint references pdks.kullanici (id),
    olusturma_zamani timestamptz not null default now(),
    check (bitis is null or bitis > baslangic)
);

-- İK ekranına düşen uyarılar
create table pdks.uyari (
    id               bigint generated always as identity primary key,
    tur              text not null check (tur in (
                        'iptal_kart_okutma',    -- sorun 4
                        'sik_kart_unutma',      -- sorun 4 (bilgi, ceza değil)
                        'ariza_suphesi',        -- sorun 5
                        'soru_eskale',          -- sorun 13
                        'gece_isi_calismadi',   -- sorun 13
                        'dosya_gelmedi',        -- sorun 16
                        'pin_kilitlendi',       -- sorun 17
                        'geriye_donuk_vardiya'  -- sorun 8
                     )),
    calisan_id       bigint references pdks.calisan (id),
    okuyucu_id       smallint references pdks.okuyucu (id),
    mesaj            text not null,
    olusturma_zamani timestamptz not null default now(),
    goruldu          boolean not null default false,
    goren_id         bigint references pdks.kullanici (id),
    gorulme_zamani   timestamptz
);

-- ---------------------------------------------------------------------
-- Dönem (ay), günlük kayıt, düzeltme, soru, itiraz, puantaj
-- ---------------------------------------------------------------------

-- Sorun 11: ay sonu kilidi
create table pdks.donem (
    id             bigint generated always as identity primary key,
    yil            smallint not null check (yil between 2000 and 2100),
    ay             smallint not null check (ay between 1 and 12),
    durum          text not null default 'acik' check (durum in ('acik', 'kilitli')),
    kilitleyen_id  bigint references pdks.kullanici (id),
    kilit_zamani   timestamptz,
    unique (yil, ay)
);

-- Bir çalışanın bir iş günü (gece işinin hesapladığı sonuç).
-- is_gunu: vardiyanın BAŞLADIĞI gün (sorun 7). Gece vardiyası tek satırdır.
-- Giriş/çıkış/vardiya/devamsız değişikliği yalnızca pdks.duzeltme_uygula() ile yapılır.
create table pdks.gun_kaydi (
    id                  bigint generated always as identity primary key,
    calisan_id          bigint not null references pdks.calisan (id),
    is_gunu             date not null,
    vardiya_id          smallint references pdks.vardiya_tanim (id),
    planli_baslangic    timestamptz,
    planli_bitis        timestamptz,
    giris_zamani        timestamptz,
    cikis_zamani        timestamptz,
    giris_kaynagi       text check (giris_kaynagi in ('pdks', 'kanit', 'amir', 'ik')),
    cikis_kaynagi       text check (cikis_kaynagi in ('pdks', 'kanit', 'amir', 'ik')),
    durum               text not null check (durum in (
                            'tamam',             -- giriş ve çıkış belli
                            'eksik',             -- giriş ya da çıkış yok, işlenecek
                            'soru_bekliyor',     -- amire soruldu
                            'izinli',
                            'raporlu',
                            'tatil',
                            'vardiya_yok',       -- o gün plan yok (hafta tatili vb.)
                            'devamsiz_suphesi',  -- sistem en fazla bunu söyler
                            'devamsiz'           -- kesin karar: YALNIZCA İK (düzeltme ile)
                        )),
    -- Sorun 9: hesap ancak tüm düzeltmeler bitince yapılır (hesap_tamam = true)
    gec_kalma_dk        integer check (gec_kalma_dk >= 0),
    erken_cikis_dk      integer check (erken_cikis_dk >= 0),
    calisma_dk          integer check (calisma_dk >= 0),
    hesap_tamam         boolean not null default false,
    gece_isi_id         bigint references pdks.gece_isi (id),
    guncelleme_zamani   timestamptz not null default now(),
    unique (calisan_id, is_gunu),
    check (cikis_zamani is null or giris_zamani is null or cikis_zamani > giris_zamani)
);
create index gun_kaydi_tarih on pdks.gun_kaydi (is_gunu);

-- Amire sabah sorulan sorular (sorun 1, 2, 4, 5, 8, 13)
create table pdks.amir_sorusu (
    id                  bigint generated always as identity primary key,
    gun_kaydi_id        bigint not null references pdks.gun_kaydi (id),
    soru_turu           text not null check (soru_turu in (
                            'giris_yok',              -- sorun 1, kanıt yok
                            'kanit_vardiya_sonrasi',  -- sorun 1: kanıt vardiya başından sonra, saat yazılmadı
                            'cikis_yok',              -- sorun 2
                            'hic_kayit_yok',          -- sorun 4
                            'ariza_kaniti_yok',       -- sorun 5
                            'vardiya_uyusmazligi'     -- sorun 8: okutmalar başka vardiyaya uyuyor
                        )),
    aciklama            text not null,
    onerilen_zaman      timestamptz,             -- varsa kanıttaki saat (amire bilgi olarak)
    kanit_kaydi_id      bigint references pdks.kanit_kaydi (id),
    ariza_id            bigint references pdks.ariza (id),
    atanan_id           bigint not null references pdks.kullanici (id),
    durum               text not null default 'acik' check (durum in (
                            'acik', 'eskale', 'cevaplandi', 'ik_karari_bekliyor', 'kapandi')),
    olusturma_zamani    timestamptz not null default now(),
    son_cevap_tarihi    date not null,           -- olusturma + soru_eskalasyon_gun
    eskale_zamani       timestamptz,
    eskale_edilen_id    bigint references pdks.kullanici (id),
    cevap               text check (cevap in (
                            'geldi_saat_dogru',   -- önerilen saati onayla
                            'geldi_saat_farkli',  -- amir saati kendisi girer
                            'kart_unuttu',        -- sorun 4
                            'gelmedi',            -- çalışan aleyhine: İK'ya gider
                            'bilmiyorum')),
    cevap_giris         timestamptz,
    cevap_cikis         timestamptz,
    cevap_aciklama      text,
    cevaplayan_id       bigint references pdks.kullanici (id),
    cevap_zamani        timestamptz,
    check ((cevap is null) = (cevap_zamani is null))
);
-- Aynı gün için aynı türde tek açık soru
create unique index amir_sorusu_tek_acik on pdks.amir_sorusu (gun_kaydi_id, soru_turu)
    where durum in ('acik', 'eskale', 'ik_karari_bekliyor');
create index amir_sorusu_atanan on pdks.amir_sorusu (atanan_id, durum);

-- Sorun 17: çalışanın kiosktan itirazı
create table pdks.itiraz (
    id                bigint generated always as identity primary key,
    calisan_id        bigint not null references pdks.calisan (id),
    gun_kaydi_id      bigint not null references pdks.gun_kaydi (id),
    metin             text not null check (length(trim(metin)) > 0),
    durum             text not null default 'acik' check (durum in ('acik', 'inceleniyor', 'kabul', 'red')),
    olusturma_zamani  timestamptz not null default now(),
    karar_veren_id    bigint references pdks.kullanici (id),
    karar_aciklama    text,
    karar_zamani      timestamptz,
    check ((durum in ('kabul', 'red')) = (karar_zamani is not null))
);

-- Sorun 12: DÜZELTME İZİ. Silinemez, değiştirilemez (bkz. 2. dosya).
-- Kim (yapan_id / kaynak), ne zaman (yapilma_zamani), eski-yeni değer, gerekçe.
create table pdks.duzeltme (
    id                 bigint generated always as identity primary key,
    gun_kaydi_id       bigint not null references pdks.gun_kaydi (id),
    calisan_id         bigint not null references pdks.calisan (id),
    is_gunu            date not null,
    alan               text not null check (alan in ('giris_zamani', 'cikis_zamani', 'vardiya_id', 'durum')),
    eski_deger         text,
    yeni_deger         text,
    gerekce            text not null check (length(trim(gerekce)) >= 5),
    kaynak             text not null check (kaynak in ('gece_isi', 'amir', 'ik')),
    yapan_id           bigint references pdks.kullanici (id),   -- gece işinde boş
    calisan_aleyhine   boolean not null default false,
    -- Neye dayanarak?
    kanit_kaydi_id     bigint references pdks.kanit_kaydi (id),
    izin_id            bigint references pdks.izin (id),
    ariza_id           bigint references pdks.ariza (id),
    soru_id            bigint references pdks.amir_sorusu (id),
    itiraz_id          bigint references pdks.itiraz (id),
    -- Sorun 11: kilitli aya ait düzeltme sonraki açık aya "fark" olarak yazılır
    hedef_donem_id     bigint not null references pdks.donem (id),
    fark_satiri        boolean not null default false,
    yapilma_zamani     timestamptz not null default now(),
    -- Gece işi kişi değildir; insan düzeltmesinde kişi zorunlu
    check ((kaynak = 'gece_isi') = (yapan_id is null)),
    -- Gece işi yalnızca kanıta (kapı/yemekhane/servis kaydı ya da izin) dayanarak düzeltir
    check (kaynak <> 'gece_isi' or kanit_kaydi_id is not null or izin_id is not null),
    -- Çalışan aleyhine kararı sistem ya da amir vermez, İK verir
    check (not calisan_aleyhine or kaynak = 'ik')
);
create index duzeltme_gun on pdks.duzeltme (gun_kaydi_id);
create index duzeltme_donem on pdks.duzeltme (hedef_donem_id) where fark_satiri;

-- Ay sonu bordroya hazır puantaj. Ay kilitlenince yazılır, sonra değişmez.
create table pdks.puantaj_satiri (
    id                bigint generated always as identity primary key,
    donem_id          bigint not null references pdks.donem (id),
    calisan_id        bigint not null references pdks.calisan (id),
    satir_turu        text not null check (satir_turu in ('normal', 'fark')),
    kaynak_donem_id   bigint references pdks.donem (id),   -- fark satırında: hangi aya ait düzeltme
    calisilan_gun     numeric(4,1) not null default 0,
    calisma_dk        integer not null default 0,
    gec_kalma_dk      integer not null default 0,
    erken_cikis_dk    integer not null default 0,
    devamsiz_gun      numeric(4,1) not null default 0,
    izinli_gun        numeric(4,1) not null default 0,
    raporlu_gun       numeric(4,1) not null default 0,
    tatil_gun         numeric(4,1) not null default 0,
    olusturma_zamani  timestamptz not null default now(),
    check ((satir_turu = 'fark') = (kaynak_donem_id is not null)),
    unique nulls not distinct (donem_id, calisan_id, satir_turu, kaynak_donem_id)
);
