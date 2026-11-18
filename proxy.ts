import type { NextRequest } from "next/server";
import { oturumuTazele } from "@/lib/supabase/proxy";

// Next.js 16'da "middleware" adı "proxy" oldu. Her sayfa isteğinden önce çalışır.
export async function proxy(request: NextRequest) {
  return oturumuTazele(request);
}

export const config = {
  // Next.js dosyaları ve görseller hariç her yol
  matcher: ["/((?!_next/static|_next/image|icon.png|logo/|.*\\.(?:png|jpg|jpeg|svg|ico|webp)$).*)"],
};
