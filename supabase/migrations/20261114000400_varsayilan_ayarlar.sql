-- =====================================================================
-- 4/4: Varsayılan ayarlar ve örnek vardiyalar
-- Değerler İK ayar ekranından değiştirilebilir (değişiklik ayar_gecmisi'ne yazılır).
-- =====================================================================

insert into pdks.ayar (anahtar, deger, birim, aciklama) values
    ('yurume_payi_dk',            5,   'dakika', 'Sorun 1: kapı ile PDKS okuyucu arası yürüme payı'),
    ('mukerrer_esik_dk',          3,   'dakika', 'Sorun 3: bu süre içindeki aynı yönlü okutmalar tek sayılır'),
    ('gec_kalma_tolerans_dk',     5,   'dakika', 'Sorun 9: bu kadar geç kalma geç sayılmaz'),
    ('erken_cikis_tolerans_dk',   5,   'dakika', 'Sorun 9: bu kadar erken çıkış erken sayılmaz'),
    ('ariza_suphe_dk',            120, 'dakika', 'Sorun 5: diğerleri çalışırken bu kadar sessiz kalan okuyucu için arıza şüphesi'),
    ('soru_eskalasyon_gun',       3,   'gün',    'Sorun 13: cevapsız soru bu kadar gün sonra üst amire ve İK''ya gider'),
    ('sik_kart_unutma_esigi',     3,   'adet',   'Sorun 4: ayda bu kadar kart unutmada İK''ya bilgi raporu'),
    ('kiosk_gun_sayisi',          14,  'gün',    'Sorun 17: kioskta gösterilen geçmiş gün sayısı'),
    ('pin_hatali_deneme_siniri',  5,   'adet',   'Sorun 17: bu kadar hatalı PIN denemesinde hesap kilitlenir');

insert into pdks.vardiya_tanim (kod, ad, baslangic, bitis, pencere_once_dk, pencere_sonra_dk) values
    ('GUNDUZ', 'Gündüz (08-17)', '08:00', '17:00', 120, 240),
    ('V1',     'Sabah (06-14)',  '06:00', '14:00', 120, 240),
    ('V2',     'Akşam (14-22)',  '14:00', '22:00', 120, 240),
    ('V3',     'Gece (22-06)',   '22:00', '06:00', 120, 240);
