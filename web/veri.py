"""Ekranların kullandığı veri katmanı.

Veritabanı hazır olana kadar ekranlar buradaki örnek verilerle çalışır ve
veriler tarayıcı oturumunda (st.session_state) tutulur; sayfa yenilenince sıfırlanır.
Veritabanına geçildiğinde yalnızca bu dosyadaki fonksiyonların içi değişir,
ekran dosyalarına (sayfalar/) dokunmak gerekmez.

Proje kuralları burada da geçerlidir:
- Ham kayıt (ham_giris / ham_cikis) hiçbir zaman değiştirilmez; kararlar
  son_giris / son_cikis alanlarına yazılır.
- Her karar denetim kaydına eklenir; denetim kaydından silme yapılmaz.
"""

from datetime import date, datetime, timedelta

import streamlit as st

# Giriş sistemi gelene kadar her ekranı sabit bir kullanıcı kullanıyor.
AMIR = "Mehmet Yılmaz (Sargı Bölümü Amiri)"
IK = "Ayşe Demir (İK Uzmanı)"

DURUM_AMIR = "Amir bekliyor"
DURUM_IK = "İK bekliyor"
DURUM_KAPALI = "Kapandı"

ITIRAZ_ACIK = "Açık"
ITIRAZ_SONUC = "Sonuçlandı"

ITIRAZ_KONULARI = [
    "Eksik giriş / çıkış",
    "Yanlış saat",
    "Devamsız sayılma",
    "Fazla mesai eksik",
    "Diğer",
]
BASVURU_SEKILLERI = ["Sözlü", "Dilekçe", "E-posta"]

CALISANLAR = {
    1043: ("Ali Kaya", "Sargı"),
    1057: ("Zeynep Arslan", "Sargı"),
    1088: ("Hasan Çelik", "Montaj"),
    1102: ("Elif Şahin", "Montaj"),
    1121: ("Murat Öztürk", "Test"),
    1135: ("Fatma Aydın", "Kalite"),
    1149: ("Emre Koç", "Sargı"),
    1163: ("Seda Yıldız", "Depo"),
}


def _ornek_kayitlar():
    """Gece işinin kanıt bulamayıp amire bıraktığı kayıtların örnekleri."""
    bugun = date.today()
    # sicil, kaç gün önce, sorun, ham giriş, ham çıkış, kanıt, öneri,
    # önerilen giriş, önerilen çıkış, öneri çalışan aleyhine mi
    ham = [
        (1043, 1, "Çıkış okutması yok", "07:56", None,
         "Kapı ve yemekhane kaydında çıkış yok",
         "Vardiya sonu (16:00) çıkış kabul edilsin", "07:56", "16:00", False),
        (1057, 1, "Giriş okutması yok", None, "16:04",
         "Yemekhane 12:01 — çalışan o gün fabrikada",
         "Vardiya başı (08:00) giriş kabul edilsin", "08:00", "16:04", False),
        (1088, 1, "Gün boyu hiç okutma yok", None, None,
         "Kapı ve yemekhane kaydı yok",
         "Devamsız sayılsın", None, None, True),
        (1102, 2, "Aynı yönde çift okutma", "07:49", "07:52",
         "Kapı kaydı yok",
         "İkinci okutma mükerrer sayılsın, çıkış vardiya sonu (16:00)", "07:49", "16:00", False),
        (1121, 2, "Çıkış saati girişten önce", "16:02", "07:58",
         "Kapı kaydı yok",
         "Giriş ve çıkış yer değiştirmiş, düzeltilsin", "07:58", "16:02", False),
        (1135, 3, "14 saatlik çalışma (olağan dışı)", "07:55", "21:58",
         "Fazla mesai onayı bulunamadı",
         "Çıkış vardiya sonuna (16:00) çekilsin", "07:55", "16:00", True),
        (1149, 3, "Çıkış okutması yok", "08:02", None,
         "Kapı kaydı yok, yemekhane 12:15",
         "Vardiya sonu (16:00) çıkış kabul edilsin", "08:02", "16:00", False),
        (1163, 4, "Geç giriş (47 dk)", "08:47", "16:01",
         "Kapı: 08:45 giriş",
         "Geç giriş olarak işlensin", "08:47", "16:01", True),
    ]
    kayitlar = []
    for no, (sicil, gun, sorun, hg, hc, kanit, oneri, og, oc, aleyhine) in enumerate(ham, start=1):
        ad, bolum = CALISANLAR[sicil]
        kayitlar.append({
            "id": no,
            "sicil": sicil,
            "ad_soyad": ad,
            "bolum": bolum,
            "tarih": bugun - timedelta(days=gun),
            "sorun": sorun,
            "ham_giris": hg,
            "ham_cikis": hc,
            "kanit": kanit,
            "oneri": oneri,
            "onerilen_giris": og,
            "onerilen_cikis": oc,
            "aleyhine": aleyhine,
            "durum": DURUM_AMIR,
            "son_giris": None,
            "son_cikis": None,
            "amir_notu": None,
        })
    return kayitlar


def baslat():
    """Oturumda veri yoksa örnek veriyi yükler. Her sayfanın başında çağrılır."""
    if "kayitlar" not in st.session_state:
        st.session_state.kayitlar = _ornek_kayitlar()
        st.session_state.itirazlar = []
        st.session_state.denetim = []


# --- Okuma -----------------------------------------------------------------

def kayitlar(durum=None):
    return [k for k in st.session_state.kayitlar if durum is None or k["durum"] == durum]


def kayit(kayit_id):
    return next(k for k in st.session_state.kayitlar if k["id"] == kayit_id)


def itirazlar(durum=None):
    return [i for i in st.session_state.itirazlar if durum is None or i["durum"] == durum]


def itiraz(itiraz_id):
    return next(i for i in st.session_state.itirazlar if i["id"] == itiraz_id)


def denetim_kaydi():
    return list(st.session_state.denetim)


# --- Yazma -----------------------------------------------------------------

def _saat(giris, cikis):
    return f"{giris or '—'} – {cikis or '—'}"


def _denetime_yaz(kullanici, nesne, islem, eski, yeni, gerekce):
    st.session_state.denetim.append({
        "zaman": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
        "kullanici": kullanici,
        "nesne": nesne,
        "islem": islem,
        "eski": eski,
        "yeni": yeni,
        "gerekce": gerekce,
    })


def kayit_karar(kayit_id, kullanici, islem, gerekce, yeni_durum, giris=None, cikis=None):
    """Bir kayda karar uygular. Ham saatlere dokunmaz."""
    k = kayit(kayit_id)
    eski = f"{k['durum']} | {_saat(k['son_giris'] or k['ham_giris'], k['son_cikis'] or k['ham_cikis'])}"
    k["durum"] = yeni_durum
    if yeni_durum == DURUM_KAPALI:
        k["son_giris"], k["son_cikis"] = giris, cikis
    if yeni_durum == DURUM_IK:
        k["amir_notu"] = gerekce
    yeni = f"{yeni_durum} | {_saat(giris, cikis)}" if yeni_durum == DURUM_KAPALI else yeni_durum
    _denetime_yaz(kullanici, f"Kayıt #{kayit_id} ({k['sicil']})", islem, eski, yeni, gerekce)


def itiraz_ekle(kullanici, sicil, tarih, konu, basvuru_sekli, beyan):
    """İK'nın çalışan adına girdiği itirazı kaydeder; o güne ait kayıt varsa bağlar."""
    no = len(st.session_state.itirazlar) + 1
    ilgili = next(
        (k["id"] for k in st.session_state.kayitlar if k["sicil"] == sicil and k["tarih"] == tarih),
        None,
    )
    ad, bolum = CALISANLAR[sicil]
    st.session_state.itirazlar.append({
        "id": no,
        "sicil": sicil,
        "ad_soyad": ad,
        "bolum": bolum,
        "tarih": tarih,
        "konu": konu,
        "basvuru_sekli": basvuru_sekli,
        "beyan": beyan,
        "ilgili_kayit": ilgili,
        "kaydeden": kullanici,
        "kayit_zamani": datetime.now().strftime("%d.%m.%Y %H:%M"),
        "durum": ITIRAZ_ACIK,
        "sonuc": None,
        "sonuc_aciklama": None,
    })
    _denetime_yaz(kullanici, f"İtiraz #{no} ({sicil})", "İtiraz kaydedildi", "—",
                  f"{konu} · {tarih:%d.%m.%Y} · {basvuru_sekli}", beyan)
    return no


def itiraz_sonuclandir(itiraz_id, kullanici, sonuc, aciklama):
    i = itiraz(itiraz_id)
    i["durum"], i["sonuc"], i["sonuc_aciklama"] = ITIRAZ_SONUC, sonuc, aciklama
    _denetime_yaz(kullanici, f"İtiraz #{itiraz_id} ({i['sicil']})", "İtiraz sonuçlandı",
                  ITIRAZ_ACIK, f"{ITIRAZ_SONUC}: {sonuc}", aciklama)


# --- Ekran yardımcıları ----------------------------------------------------

def kayit_etiketi(kayit_id):
    k = kayit(kayit_id)
    return f"#{k['id']} · {k['tarih']:%d.%m} · {k['sicil']} {k['ad_soyad']} · {k['sorun']}"


def calisan_etiketi(sicil):
    ad, bolum = CALISANLAR[sicil]
    return f"{sicil} · {ad} ({bolum})"


def kayit_tablosu(liste):
    return [{
        "No": k["id"],
        "Tarih": k["tarih"].strftime("%d.%m.%Y"),
        "Sicil": k["sicil"],
        "Ad Soyad": k["ad_soyad"],
        "Bölüm": k["bolum"],
        "Sorun": k["sorun"],
        "Ham saat": _saat(k["ham_giris"], k["ham_cikis"]),
        "Öneri": k["oneri"],
        "Aleyhine": "Evet" if k["aleyhine"] else "",
    } for k in liste]


def mesaj_birak(metin):
    """Bir sonraki çalıştırmada gösterilecek başarı mesajı bırakır."""
    st.session_state.mesaj = metin


def mesaj_goster():
    # Kutu her çalıştırmada aynı yerde oluşturulur; böylece mesaj çıkınca
    # altındaki sekmeler kaymaz ve kullanıcı bulunduğu sekmede kalır.
    kutu = st.container()
    metin = st.session_state.pop("mesaj", None)
    if metin:
        kutu.success(metin, icon=":material/check_circle:")
