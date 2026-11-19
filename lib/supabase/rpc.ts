import "server-only";
import type { PostgrestError } from "@supabase/supabase-js";
import { sunucuIstemcisi } from "./server";

// Ekranlar veritabanına yalnızca RPC fonksiyonlarıyla yazar (docs/ekran_fonksiyonlari.md).
// Fonksiyon oturumdaki kullanıcıyı kendisi bulur, rolü ve görevler ayrılığını kendisi denetler;
// buradan "kim yaptı" bilgisi gönderilmez.
export type RpcSonucu<T> = { tamam: true; veri: T } | { tamam: false; mesaj: string };

export async function rpcCagir<T = unknown>(ad: string, parametreler: Record<string, unknown>): Promise<RpcSonucu<T>> {
  try {
    const supabase = await sunucuIstemcisi();
    const { data, error } = await supabase.rpc(ad, parametreler);
    if (error) return { tamam: false, mesaj: hataMesaji(error) };
    return { tamam: true, veri: data as T };
  } catch {
    return { tamam: false, mesaj: "Veritabanına ulaşılamadı. Bağlantıyı kontrol edip tekrar deneyin." };
  }
}

// Fonksiyonların kendi hataları (raise exception) Türkçedir ve olduğu gibi gösterilir.
// PostgreSQL'in kendi hataları İngilizce gelir; onlar sade bir Türkçe cümleye çevrilir.
function hataMesaji(hata: PostgrestError): string {
  switch (hata.code) {
    case "P0001": // raise exception: fonksiyonun Türkçe mesajı
      return sadelestir(hata.message);
    case "42501":
      return "Bu işlem için yetkiniz yok.";
    case "23505":
      return "Bu kayıt zaten var.";
    case "23503":
      return "İlgili kayıt bulunamadı.";
    case "23514":
    case "22P02":
    case "22007":
    case "22008":
      return "Girilen değer geçersiz.";
    case "PGRST202":
      return "Veritabanı fonksiyonu bulunamadı. Migration canlıya uygulanmamış olabilir.";
    default:
      // Türkçe karakter içeren mesaj büyük ihtimalle bizim fonksiyonlarımızdan gelir
      return /[çğıöşüÇĞİÖŞÜ]/.test(hata.message) ? sadelestir(hata.message) : "İşlem yapılamadı. Lütfen tekrar deneyin.";
  }
}

// Mesajın sonundaki teknik ek (ör. "(gecici_kart_zimmet.veren_id)") kullanıcıya gösterilmez
function sadelestir(mesaj: string): string {
  return mesaj.replace(/\s*\([a-z_]+\.[a-z_]+\)\.?$/, ".");
}

// Form alanlarını okuma yardımcıları. Boş metin null olur; sayı değilse null döner.
export function metinAl(form: FormData, ad: string): string | null {
  const deger = form.get(ad);
  if (typeof deger !== "string") return null;
  const temiz = deger.trim();
  return temiz === "" ? null : temiz;
}

export function sayiAl(form: FormData, ad: string): number | null {
  const metin = metinAl(form, ad);
  if (metin === null || !/^\d+$/.test(metin)) return null;
  return Number(metin);
}
