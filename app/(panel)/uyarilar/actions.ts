"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { rpcCagir, sayiAl } from "@/lib/supabase/rpc";

// Uyarıyı "görüldü" yapar (yalnızca İK). Kim, ne zaman gördü veritabanında tutulur.
export async function uyariGoruldu(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const uyariId = sayiAl(form, "uyari_id");
  if (!uyariId) return { durum: "hata", mesaj: "Uyarı seçilmedi." };

  const sonuc = await rpcCagir("uyari_goruldu", { p_uyari_id: uyariId });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  revalidatePath("/uyarilar");
  revalidatePath("/");
  return { durum: "tamam", mesaj: "Uyarı görüldü olarak işaretlendi." };
}
