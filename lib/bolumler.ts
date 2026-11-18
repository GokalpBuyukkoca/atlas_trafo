import "server-only";
import type { Rol } from "@/lib/oturum";
import type { sunucuIstemcisi } from "@/lib/supabase/server";

type Istemci = Awaited<ReturnType<typeof sunucuIstemcisi>>;
export type Bolum = { id: number; ad: string };

// Süzgeçlerde gösterilecek bölümler. Bölüm tablosunu herkes okuyabilir;
// amire yalnızca asıl ya da vekil amiri olduğu bölümler gösterilir.
// (Başka bölümü adresten seçse bile RLS o bölümün satırlarını zaten döndürmez.)
export async function gorunurBolumler(supabase: Istemci, rol: Rol): Promise<Bolum[]> {
  const [bolumSonucu, amirSonucu] = await Promise.all([
    supabase.from("departman").select("id, ad").order("ad"),
    rol === "amir" ? supabase.rpc("oturum_departmanlari") : Promise.resolve(null),
  ]);
  if (bolumSonucu.error) throw new Error(`Bölümler okunamadı: ${bolumSonucu.error.message}`);
  if (amirSonucu?.error) throw new Error(`Bölümler okunamadı: ${amirSonucu.error.message}`);

  const bolumler = (bolumSonucu.data ?? []) as Bolum[];
  const amirIdleri = (amirSonucu?.data ?? null) as number[] | null;
  return amirIdleri ? bolumler.filter((b) => amirIdleri.includes(b.id)) : bolumler;
}

// Adresten gelen bölüm numarası (geçersizse null)
export function bolumNumarasi(deger: string): number | null {
  return Number.parseInt(deger, 10) || null;
}
