import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { supabaseAyarlari } from "./ayarlar";

// Giriş yapmadan açılabilen sayfalar
const ACIK_YOLLAR = ["/giris"];

// Her istekte çalışır (bkz. kökteki proxy.ts):
// 1) Süresi dolmak üzere olan oturumu tazeler ve yeni çerezi yanıta yazar.
// 2) Giriş yapmamış kullanıcıyı /giris sayfasına, giriş yapmışı ana sayfaya yönlendirir.
// Bu yalnızca hızlı bir ön kontrol; asıl yetki kontrolü veritabanında (RLS).
export async function oturumuTazele(request: NextRequest) {
  let yanit = NextResponse.next({ request });

  const ayar = supabaseAyarlari();
  if (!ayar) return yanit; // Ayarlar eksik: giriş sayfası uyarı gösterir.

  const supabase = createServerClient(ayar.url, ayar.anahtar, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(liste, basliklar) {
        liste.forEach(({ name, value }) => request.cookies.set(name, value));
        yanit = NextResponse.next({ request });
        liste.forEach(({ name, value, options }) => yanit.cookies.set(name, value, options));
        // Oturum çerezi içeren yanıt önbelleğe alınmamalı
        Object.entries(basliklar).forEach(([ad, deger]) => yanit.headers.set(ad, deger));
      },
    },
  });

  // getClaims oturum jetonunu doğrular ve gerekirse tazeler.
  // Bu satırla createServerClient arasına başka kod eklemeyin.
  const { data } = await supabase.auth.getClaims();
  const girisYapti = Boolean(data?.claims);

  const yol = request.nextUrl.pathname;
  const acikYol = ACIK_YOLLAR.some((a) => yol === a || yol.startsWith(`${a}/`));

  if (!girisYapti && !acikYol) return yonlendir(request, "/giris", yanit);
  if (girisYapti && acikYol) return yonlendir(request, "/", yanit);

  return yanit;
}

// Yönlendirirken tazelenmiş oturum çerezlerini kaybetmemek için onları da taşır.
function yonlendir(request: NextRequest, hedef: string, yanit: NextResponse) {
  const url = request.nextUrl.clone();
  url.pathname = hedef;
  url.search = "";
  const yonlendirme = NextResponse.redirect(url);
  yanit.cookies.getAll().forEach((c) => yonlendirme.cookies.set(c));
  yanit.headers.forEach((deger, ad) => {
    if (ad.toLowerCase() !== "set-cookie") yonlendirme.headers.set(ad, deger);
  });
  return yonlendirme;
}
