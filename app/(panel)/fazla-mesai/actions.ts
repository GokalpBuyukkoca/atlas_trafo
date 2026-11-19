"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { kararAl, metinAl, rpcCagir, sayiAl, sicildenCalisan, tarihAl } from "@/lib/supabase/rpc";
import { sunucuIstemcisi } from "@/lib/supabase/server";

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

// Çalışanın yıllık yazılı fazla mesai onayı (İş Kanunu m.41). Onay olmadan fazla mesai planlanamaz.
export async function yaziliOnayGir(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const yil = sayiAl(form, "yil");
  const imzaTarihi = tarihAl(form, "imza_tarihi");
  const belgeNo = metinAl(form, "belge_no");
  if (!yil || yil < 2000 || yil > 2100) return { durum: "hata", mesaj: "Yılı girin." };
  if (!imzaTarihi) return { durum: "hata", mesaj: "İmza tarihini girin." };
  if (Number(imzaTarihi.slice(0, 4)) > yil) return { durum: "hata", mesaj: "İmza tarihi onayın yılından sonra olamaz." };
  if (!belgeNo) return { durum: "hata", mesaj: "Belge numarasını girin." };

  const bulunan = await sicildenCalisan(form);
  if (!bulunan.tamam) return { durum: "hata", mesaj: bulunan.mesaj };

  const sonuc = await rpcCagir<number>("fazla_mesai_onayi_gir", {
    p_calisan_id: bulunan.calisan.id,
    p_yil: yil,
    p_imza_tarihi: imzaTarihi,
    p_belge_no: belgeNo,
  });
  if (!sonuc.tamam) {
    return { durum: "hata", mesaj: sonuc.mesaj === "Bu kayıt zaten var." ? `${bulunan.calisan.adSoyad} için ${yil} onayı zaten kayıtlı.` : sonuc.mesaj };
  }
  revalidatePath("/fazla-mesai");
  return { durum: "tamam", mesaj: `${bulunan.calisan.adSoyad} için ${yil} yazılı onayı kaydedildi.` };
}

// Çalışan onayını geri çekerse: bildirimden 30 gün sonra onay geçersiz olur.
export async function yaziliOnayGeriAl(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const yil = sayiAl(form, "yil");
  const bildirim = tarihAl(form, "bildirim_tarihi");
  if (!yil) return { durum: "hata", mesaj: "Yılı girin." };
  if (!bildirim) return { durum: "hata", mesaj: "Bildirim tarihini girin." };

  const bulunan = await sicildenCalisan(form);
  if (!bulunan.tamam) return { durum: "hata", mesaj: bulunan.mesaj };

  const supabase = await sunucuIstemcisi();
  const { data: onay } = await supabase
    .from("fazla_mesai_onayi")
    .select("id, geri_alma_bildirim_tarihi")
    .eq("calisan_id", bulunan.calisan.id)
    .eq("yil", yil)
    .maybeSingle();
  if (!onay) return { durum: "hata", mesaj: `${bulunan.calisan.adSoyad} için ${yil} yazılı onayı yok.` };
  if (onay.geri_alma_bildirim_tarihi) return { durum: "hata", mesaj: "Bu onay zaten geri alınmış." };

  const sonuc = await rpcCagir("fazla_mesai_onayi_geri_al", { p_onay_id: onay.id, p_bildirim_tarihi: bildirim });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };
  revalidatePath("/fazla-mesai");
  revalidatePath("/uyarilar");
  return { durum: "tamam", mesaj: `Onay geri alındı; 30 gün sonra geçersiz olacak.` };
}
