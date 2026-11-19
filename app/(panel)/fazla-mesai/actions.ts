"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { kararAl, metinAl, rpcCagir, sayiAl, sicildenCalisan, tarihAl } from "@/lib/supabase/rpc";

// Amir (ya da İK) fazla mesai talebi açar; İK onaylar. Veritabanı denetler: çalışan amirin bölümünde mi,
// yazılı onayı var mı, günlük 11 saat ve yıllık sınır aşılıyor mu, kimse kendine talep açamaz.
export async function fazlaMesaiTalepEt(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const isGunu = tarihAl(form, "is_gunu");
  const saatMetni = metinAl(form, "saat")?.replace(",", ".");
  const saat = saatMetni ? Number(saatMetni) : NaN;
  const gerekce = metinAl(form, "gerekce");

  if (!isGunu) return { durum: "hata", mesaj: "Fazla mesai gününü seçin." };
  if (!Number.isFinite(saat) || saat <= 0 || saat > 11) return { durum: "hata", mesaj: "Süreyi 0,5 ile 11 saat arasında girin." };
  if (!gerekce || gerekce.length < 5) return { durum: "hata", mesaj: "Gerekçeyi yazın (ör. sipariş teslimi)." };

  const bulunan = await sicildenCalisan(form);
  if (!bulunan.tamam) return { durum: "hata", mesaj: bulunan.mesaj };

  const sonuc = await rpcCagir<number>("fazla_mesai_talep_et", {
    p_calisan_id: bulunan.calisan.id,
    p_is_gunu: isGunu,
    p_planli_dk: Math.round(saat * 60),
    p_gerekce: gerekce,
  });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  revalidatePath("/fazla-mesai");
  revalidatePath("/vardiya-plani");
  revalidatePath("/");
  return { durum: "tamam", mesaj: `${bulunan.calisan.adSoyad} için fazla mesai talebi açıldı. Kararı İK verecek.` };
}

// İK, amirin önceden açtığı fazla mesai talebini onaylar ya da reddeder.
export async function fazlaMesaiKarar(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const planId = sayiAl(form, "plan_id");
  const onay = kararAl(form);
  const aciklama = metinAl(form, "aciklama");
  if (!planId) return { durum: "hata", mesaj: "Talep seçilmedi." };
  if (onay === null) return { durum: "hata", mesaj: "Onay ya da red seçin." };
  if (!onay && (!aciklama || aciklama.length < 5)) return { durum: "hata", mesaj: "Red gerekçesini yazın." };

  const sonuc = await rpcCagir("fazla_mesai_karar", { p_plan_id: planId, p_onay: onay, p_aciklama: aciklama });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };
  revalidatePath("/fazla-mesai");
  revalidatePath("/vardiya-plani");
  revalidatePath("/");
  return { durum: "tamam", mesaj: onay ? "Fazla mesai talebi onaylandı." : "Fazla mesai talebi reddedildi." };
}

// Onaysız fazla mesai havuzu: plansız çalışılan süre İK kararına kadar puantaja girmez.
// Onay puantaja ekler (kilitli aya aitse sonraki aya fark olur); ret için gerekçe zorunlu.
export async function havuzKarari(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const incelemeId = sayiAl(form, "inceleme_id");
  const onay = kararAl(form);
  const aciklama = metinAl(form, "aciklama");
  if (!incelemeId) return { durum: "hata", mesaj: "Kayıt seçilmedi." };
  if (onay === null) return { durum: "hata", mesaj: "Onay ya da red seçin." };

  const sonuc = await rpcCagir("fazla_mesai_inceleme_karar", { p_inceleme_id: incelemeId, p_onay: onay, p_aciklama: aciklama });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };
  revalidatePath("/fazla-mesai");
  revalidatePath("/puantaj");
  revalidatePath("/");
  return { durum: "tamam", mesaj: onay ? "Fazla çalışma onaylandı, puantaja eklendi." : "Fazla çalışma reddedildi; puantaja girmez." };
}
