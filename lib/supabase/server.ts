import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { SEMA, supabaseAyarlari } from "./ayarlar";

// Sunucuda (Server Component, Server Action) kullanılan Supabase istemcisi.
// Oturum çerezden okunur; hangi satırların görüneceğine veritabanındaki RLS karar verir.
// Her istekte yeniden oluşturulur, istekler arasında paylaşılmaz.
export async function sunucuIstemcisi() {
  // Önce çerezler okunur: böylece Next.js bu sayfayı build sırasında sabit
  // (statik) üretmeye çalışmaz, her istekte kullanıcıya göre üretir.
  const cerezler = await cookies();

  const ayar = supabaseAyarlari();
  if (!ayar) {
    throw new Error("Supabase ayarları eksik: .env.example dosyasını .env.local olarak kopyalayıp doldurun.");
  }

  return createServerClient(ayar.url, ayar.anahtar, {
    db: { schema: SEMA },
    cookies: {
      getAll: () => cerezler.getAll(),
      setAll(liste) {
        try {
          liste.forEach(({ name, value, options }) => cerezler.set(name, value, options));
        } catch {
          // Server Component içinden çerez yazılamaz. Sorun değil:
          // oturumu her istekte proxy.ts tazeler.
        }
      },
    },
  });
}
