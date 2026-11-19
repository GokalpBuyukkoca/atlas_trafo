"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { metinAl, rpcCagir, sayiAl } from "@/lib/supabase/rpc";

// Sistem yöneticisi bir ayarın değerini değiştirir (tolerans, eşikler…).
// Eski / yeni değer ve değiştiren ayar_gecmisi tablosuna veritabanı tarafından yazılır.
export async function ayarGuncelle(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const anahtar = metinAl(form, "anahtar");
  const deger = sayiAl(form, "deger");
  if (!anahtar) return { durum: "hata", mesaj: "Ayar seçilmedi." };
  if (deger === null) return { durum: "hata", mesaj: "Değer 0 ya da daha büyük bir tam sayı olmalı." };

  const sonuc = await rpcCagir("ayar_guncelle", { p_anahtar: anahtar, p_deger: deger });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };
  revalidatePath("/ayarlar");
  return { durum: "tamam", mesaj: "Ayar güncellendi. Yeni değer bir sonraki hesapta kullanılır." };
}
