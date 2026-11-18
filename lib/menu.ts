import type { Rol } from "@/lib/oturum";

export type MenuOgesi = { baslik: string; yol: string };

const ANA_SAYFA: MenuOgesi = { baslik: "Ana sayfa", yol: "/" };
const CALISANLAR: MenuOgesi = { baslik: "Çalışanlar", yol: "/calisanlar" };
const GECICI_KARTLAR: MenuOgesi = { baslik: "Geçici kartlar", yol: "/gecici-kartlar" };
const VARDIYA_PLANI: MenuOgesi = { baslik: "Vardiya planı", yol: "/vardiya-plani" };
const FAZLA_MESAI: MenuOgesi = { baslik: "Fazla mesai", yol: "/fazla-mesai" };

// Her rol yalnızca kendi menüsünü görür. Yeni ekran eklendikçe buraya satır eklenir.
// Sayfaların kendisi de rolGerekli(...) ile aynı listeyi kontrol eder.
// Not: menüde görünmemek yetki değildir; asıl kontrol veritabanında (RLS) yapılır.
export const MENU: Record<Rol, MenuOgesi[]> = {
  amir: [ANA_SAYFA, VARDIYA_PLANI, FAZLA_MESAI, CALISANLAR],
  ik: [ANA_SAYFA, VARDIYA_PLANI, FAZLA_MESAI, CALISANLAR, GECICI_KARTLAR],
  guvenlik: [ANA_SAYFA, GECICI_KARTLAR, CALISANLAR],
  yonetici: [ANA_SAYFA, VARDIYA_PLANI, FAZLA_MESAI, CALISANLAR, GECICI_KARTLAR],
};
