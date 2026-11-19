"use server";

import { revalidatePath } from "next/cache";
import type { IslemSonucu } from "@/lib/islem-sonucu";
import { rpcCagir, tarihAl } from "@/lib/supabase/rpc";

type GunSonucu = { gun: string; durum: "basarili" | "hatali" | "calisiyor"; ozet: Record<string, unknown> | null; hata_mesaji: string | null };

// Özet alanlarının ekrandaki adları (gece_isi.ozet)
const OZET_ADI: Record<string, string> = {
  gun_kaydi: "gün kaydı",
  duzeltme: "kanıtla düzeltme",
  soru: "amire soru",
  eskale: "üst amire giden",
  uyari: "uyarı",
};

// Demo düğmesi: tarih aralığını gün gün gece işinden geçirir (normalde pg_cron her gece yapar).
// Tekrar çalıştırmak güvenlidir; var olan kayıtlar bozulmaz, yalnızca eksikler eklenir.
export async function geceIsiTetikle(_onceki: IslemSonucu, form: FormData): Promise<IslemSonucu> {
  const baslangic = tarihAl(form, "baslangic");
  const bitis = tarihAl(form, "bitis") ?? baslangic;
  if (!baslangic || !bitis) return { durum: "hata", mesaj: "Başlangıç gününü seçin." };
  if (bitis < baslangic) return { durum: "hata", mesaj: "Bitiş günü başlangıçtan önce olamaz." };

  const sonuc = await rpcCagir<GunSonucu[]>("gece_isi_tetikle", { p_baslangic: baslangic, p_bitis: bitis });
  if (!sonuc.tamam) return { durum: "hata", mesaj: sonuc.mesaj };

  const gunler = sonuc.veri ?? [];
  const hatali = gunler.filter((g) => g.durum === "hatali");
  const toplam = new Map<string, number>();
  for (const g of gunler) {
    for (const [anahtar, deger] of Object.entries(g.ozet ?? {})) {
      if (typeof deger === "number") toplam.set(anahtar, (toplam.get(anahtar) ?? 0) + deger);
    }
  }
  const ozet = Object.entries(OZET_ADI)
    .filter(([k]) => toplam.get(k))
    .map(([k, ad]) => `${toplam.get(k)} ${ad}`)
    .join(", ");

  // Gece işi neredeyse her ekranı etkiler
  revalidatePath("/", "layout");

  if (hatali.length) {
    return {
      durum: "hata",
      mesaj: `${gunler.length} günün ${hatali.length} tanesi hatalı: ${hatali[0].gun} · ${hatali[0].hata_mesaji ?? "bilinmeyen hata"}`,
    };
  }
  return { durum: "tamam", mesaj: `${gunler.length} gün işlendi${ozet ? `: ${ozet}` : ""}.` };
}
