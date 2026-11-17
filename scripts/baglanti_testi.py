"""Supabase bağlantı testi.

.env dosyasındaki iki adresle (uygulama ve gece işi) veritabanına bağlanır ve:
  1. bağlanabiliyor mu,
  2. pdks şemasındaki tabloları görebiliyor mu,
  3. silinemez bir tabloyu silmeye çalışınca engelleniyor mu
kontrol eder. Hiçbir veriyi değiştirmez. Şifreyi ve adresi ASLA ekrana yazmaz.

Çalıştırma (proje klasöründe):
    .venv/bin/python scripts/baglanti_testi.py
"""

import os
import sys

import psycopg
from dotenv import load_dotenv

# Kontrol edilecek bağlantılar: (.env'deki değişken adı, ekranda görünecek ad)
BAGLANTILAR = [
    ("PDKS_UYGULAMA_DB_URL", "Streamlit uygulaması"),
    ("PDKS_GECE_ISI_DB_URL", "Gece işi"),
]
BEKLENEN_TABLO_SAYISI = 26


def baglanti_dene(degisken: str, ad: str) -> bool:
    """Tek bir bağlantıyı dener. Her şey yolundaysa True döner."""
    print(f"\n--- {ad} ({degisken}) ---")

    adres = os.getenv(degisken)
    if not adres:
        print("  HATA: .env dosyasında bu satır boş ya da yok.")
        return False
    if "[YOUR-PASSWORD]" in adres or "[" in adres:
        print("  HATA: Adreste hâlâ [YOUR-PASSWORD] ya da köşeli parantez var.")
        return False

    try:
        # "with" bloğu bitince bağlantı kendiliğinden kapanır
        with psycopg.connect(adres, connect_timeout=10) as baglanti:
            with baglanti.cursor() as imlec:
                # 1) Kim olarak bağlandık?
                imlec.execute("select current_user")
                kullanici = imlec.fetchone()[0]
                print(f"  Bağlandı. Veritabanı kullanıcısı: {kullanici}")

                # 2) Kaç tablo görüyoruz?
                imlec.execute(
                    "select count(*) from information_schema.tables "
                    "where table_schema = %s and table_type = 'BASE TABLE'",
                    ("pdks",),  # parametreli sorgu: değer SQL metnine eklenmez
                )
                tablo_sayisi = imlec.fetchone()[0]
                durum = "tamam" if tablo_sayisi == BEKLENEN_TABLO_SAYISI else "BEKLENMEDİK"
                print(f"  pdks şemasında {tablo_sayisi} tablo görüyor ({durum}).")

            # 3) Güvenlik: düzeltme izi silinebiliyor mu? Silinememeli.
            try:
                with baglanti.cursor() as imlec:
                    imlec.execute("delete from pdks.duzeltme")
                print("  GÜVENLİK SORUNU: düzeltme tablosundan silme engellenmedi!")
                baglanti.rollback()
                return False
            except psycopg.errors.InsufficientPrivilege:
                baglanti.rollback()
                print("  Güvenlik tamam: düzeltme izi silinemiyor (yetki yok).")

            return tablo_sayisi == BEKLENEN_TABLO_SAYISI

    except psycopg.OperationalError as hata:
        # Hata mesajında şifre olmaz; yalnızca kullanıcı adı ve sunucu görünür
        print("  BAĞLANAMADI.")
        print(f"  Ayrıntı: {str(hata).strip().splitlines()[-1]}")
        print("  İpucu: şifre doğru mu? Kullanıcı adı 'pdks_...' ile mi başlıyor?")
        return False


def main() -> int:
    load_dotenv()  # proje klasöründeki .env dosyasını okur
    sonuclar = [baglanti_dene(degisken, ad) for degisken, ad in BAGLANTILAR]

    if all(sonuclar):
        print("\nSONUÇ: İki bağlantı da çalışıyor.")
        return 0
    print("\nSONUÇ: En az bir bağlantıda sorun var (yukarıya bak).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
