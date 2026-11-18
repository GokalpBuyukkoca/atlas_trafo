import type { Rol } from "@/lib/oturum";

export type MenuOgesi = { baslik: string; yol: string };

const ANA_SAYFA: MenuOgesi = { baslik: "Ana sayfa", yol: "/" };
const SORULAR: MenuOgesi = { baslik: "Sorular", yol: "/sorular" };
const SORULARIM: MenuOgesi = { baslik: "Sorularım", yol: "/sorular" };
const UYARILAR: MenuOgesi = { baslik: "Uyarılar", yol: "/uyarilar" };
const ITIRAZLAR: MenuOgesi = { baslik: "İtirazlar", yol: "/itirazlar" };
const PUANTAJ: MenuOgesi = { baslik: "Puantaj", yol: "/puantaj" };
const VARDIYA_PLANI: MenuOgesi = { baslik: "Vardiya planı", yol: "/vardiya-plani" };
const FAZLA_MESAI: MenuOgesi = { baslik: "Fazla mesai", yol: "/fazla-mesai" };
const CALISANLAR: MenuOgesi = { baslik: "Çalışanlar", yol: "/calisanlar" };
const GECICI_KARTLAR: MenuOgesi = { baslik: "Geçici kartlar", yol: "/gecici-kartlar" };
const VERI_AKTARIMI: MenuOgesi = { baslik: "Veri aktarımı", yol: "/veri-aktarimi" };

// Her rol yalnızca kendi menüsünü görür. Yeni ekran eklendikçe buraya satır eklenir.
// Sayfaların kendisi de rolGerekli(...) ile aynı listeyi kontrol eder.
// Not: menüde görünmemek yetki değildir; asıl kontrol veritabanında (RLS) yapılır.
export const MENU: Record<Rol, MenuOgesi[]> = {
  amir: [ANA_SAYFA, SORULARIM, ITIRAZLAR, VARDIYA_PLANI, FAZLA_MESAI, CALISANLAR],
  ik: [ANA_SAYFA, UYARILAR, SORULAR, ITIRAZLAR, PUANTAJ, VARDIYA_PLANI, FAZLA_MESAI, CALISANLAR, GECICI_KARTLAR, VERI_AKTARIMI],
  guvenlik: [ANA_SAYFA, GECICI_KARTLAR, CALISANLAR],
  yonetici: [ANA_SAYFA, UYARILAR, SORULAR, ITIRAZLAR, VARDIYA_PLANI, FAZLA_MESAI, CALISANLAR, GECICI_KARTLAR, VERI_AKTARIMI],
};
