"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { metinAl, rpcCagir, sayiAl } from "@/lib/supabase/rpc";
import { sunucuIstemcisi } from "@/lib/supabase/server";

// Server Action: tarayıcıdaki form gönderilince sunucuda çalışan fonksiyon.
// Yetki burada değil veritabanında denetlenir: gecici_kart_ver yalnızca güvenlik ve İK'ya açıktır,
// kimse kendine kart veremez (görevler ayrılığı), kayıp/iptal ya da zimmetli kart verilemez.

function yenile() {
  revalidatePath("/gecici-kartlar");
  revalidatePath("/"); // ana sayfadaki geçici kart sayıları
}

export async function kartVer(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const kartId = sayiAl(form, "kart_id");
  const kartNo = metinAl(form, "kart_no") ?? "Geçici kart";
  // Listeden seçilince alanda "1001" yazar; elle "1001 Ahmet" yazılırsa ilk parça alınır
  const sicil = metinAl(form, "sicil")?.split(/\s+/)[0] ?? null;
  const aciklama = metinAl(form, "aciklama");

  if (!kartId) return { durum: "hata", mesaj: "Kart seçilmedi." };
  if (!sicil) return { durum: "hata", mesaj: "Çalışanın sicil numarasını yazın." };

  const supabase = await sunucuIstemcisi();
  const { data: calisan, error } = await supabase
    .from("calisan")
    .select("id, ad, soyad, aktif")
    .eq("sicil_no", sicil)
    .maybeSingle();
  if (error) return { durum: "hata", mesaj: "Çalışan aranamadı. Lütfen tekrar deneyin." };
  if (!calisan) return { durum: "hata", mesaj: `${sicil} sicil numaralı çalışan bulunamadı.` };
  if (!calisan.aktif) return { durum: "hata", mesaj: `${calisan.ad} ${calisan.soyad} aktif çalışan değil.` };

  const sonuc = await rpcCagir<number>("gecici_kart_ver", {
    p_gecici_kart_id: kartId,
    p_calisan_id: calisan.id,
    p_aciklama: aciklama,
  });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  yenile();
  return { durum: "tamam", mesaj: `${kartNo} kartı ${calisan.ad} ${calisan.soyad} adına verildi.` };
}

export async function kartIadeAl(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const zimmetId = sayiAl(form, "zimmet_id");
  const kartNo = metinAl(form, "kart_no") ?? "Geçici kart";
  if (!zimmetId) return { durum: "hata", mesaj: "Zimmet seçilmedi." };

  const sonuc = await rpcCagir("gecici_kart_iade_al", { p_zimmet_id: zimmetId });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  yenile();
  return { durum: "tamam", mesaj: `${kartNo} kartı iade alındı.` };
}
