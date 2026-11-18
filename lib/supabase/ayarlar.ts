// Supabase bağlantı bilgileri .env.local dosyasından okunur.
// Değerler eksikse null döner; sayfalar bu durumda uyarı gösterir.
// Yalnızca NEXT_PUBLIC_ önekli (tarayıcıya gidebilen) değerler burada okunur.
// SUPABASE_SECRET_KEY buraya ASLA eklenmez.
export function supabaseAyarlari() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anahtar = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !anahtar) return null;
  return { url, anahtar };
}

// Bütün tablolar pdks şemasında. Supabase panelinde
// Project Settings > API > Exposed schemas listesine "pdks" eklenmiş olmalı.
export const SEMA = "pdks";
