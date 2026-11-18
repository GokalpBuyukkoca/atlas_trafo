import { createBrowserClient } from "@supabase/ssr";
import { SEMA, supabaseAyarlari } from "./ayarlar";

// Tarayıcıda ("use client" bileşenlerinde) kullanılan Supabase istemcisi.
// Yalnızca yayınlanabilir anahtarı kullanır; yetkiyi RLS belirler.
export function tarayiciIstemcisi() {
  const ayar = supabaseAyarlari();
  if (!ayar) {
    throw new Error("Supabase ayarları eksik: .env.local dosyasını doldurun.");
  }
  return createBrowserClient(ayar.url, ayar.anahtar, { db: { schema: SEMA } });
}
