"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { metinAl, rpcCagir, sayiAl, zamanAl } from "@/lib/supabase/rpc";

const ALANLAR = ["giris_zamani", "cikis_zamani", "durum"] as const;
const DURUMLAR = ["tamam", "devamsiz", "izinli", "raporlu", "tatil", "vardiya_yok"];

// İK gün kaydında tek alanı düzeltir (kayit_duzelt). Eski / yeni değer, gerekçe ve yapan
// silinemeyen duzeltme tablosuna yazılır; isteğe bağlı olarak bir itiraza bağlanır.
export async function kayitDuzelt(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const gunKaydiId = sayiAl(form, "gun_kaydi_id");
  const alan = metinAl(form, "alan") as (typeof ALANLAR)[number] | null;
  const gerekce = metinAl(form, "gerekce");
  if (!gunKaydiId) return { durum: "hata", mesaj: "Gün seçilmedi." };
  if (!alan || !ALANLAR.includes(alan)) return { durum: "hata", mesaj: "Düzeltilecek alanı seçin." };
  if (!gerekce || gerekce.length < 5) return { durum: "hata", mesaj: "Gerekçeyi yazın." };

  const yeniDeger = alan === "durum" ? metinAl(form, "yeni_deger") : zamanAl(form, "yeni_deger");
  if (!yeniDeger || (alan === "durum" && !DURUMLAR.includes(yeniDeger))) {
    return { durum: "hata", mesaj: "Yeni değeri girin." };
  }

  const sonuc = await rpcCagir<number>("kayit_duzelt", {
    p_gun_kaydi_id: gunKaydiId,
    p_alan: alan,
    p_yeni_deger: yeniDeger,
    p_gerekce: gerekce,
    p_itiraz_id: sayiAl(form, "itiraz_id"),
  });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  revalidatePath("/calisanlar", "layout");
  revalidatePath("/puantaj");
  revalidatePath("/");
  return { durum: "tamam", mesaj: `Düzeltme kaydedildi (no ${sonuc.veri}).` };
}

// Çalışan itirazını sözlü ya da yazılı olarak amire veya İK'ya iletir; onlar sisteme girer.
// Veritabanı (itiraz_gir) denetler: amir yalnızca kendi bölümünün çalışanı için girebilir,
// kimse kendi itirazını giremez. Kabul / red kararı İK'dadır.
export async function itirazGir(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const gunKaydiId = sayiAl(form, "gun_kaydi_id");
  const metin = metinAl(form, "metin");
  if (!gunKaydiId) return { durum: "hata", mesaj: "Gün seçilmedi." };
  if (!metin || metin.length < 5) return { durum: "hata", mesaj: "Çalışanın itirazını en az birkaç kelimeyle yazın." };

  const sonuc = await rpcCagir<number>("itiraz_gir", { p_gun_kaydi_id: gunKaydiId, p_metin: metin });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  revalidatePath("/itirazlar");
  revalidatePath("/calisanlar", "layout");
  revalidatePath("/");
  return { durum: "tamam", mesaj: `İtiraz kaydedildi (no ${sonuc.veri}). Kararı İK verecek.` };
}
