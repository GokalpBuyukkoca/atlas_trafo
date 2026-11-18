// Ekranlarda tarih ve saat hep Türkiye saatiyle gösterilir.
// Veritabanı zamanı UTC tutar; sunucu (ör. Vercel) da UTC'de çalışır.
// Bu yüzden saat dilimi açıkça verilir, yoksa saatler 3 saat kayık görünür.
const SAAT_DILIMI = "Europe/Istanbul";

const tarihBicimi = new Intl.DateTimeFormat("tr-TR", {
  timeZone: SAAT_DILIMI,
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
});

const tarihSaatBicimi = new Intl.DateTimeFormat("tr-TR", {
  timeZone: SAAT_DILIMI,
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

const uzunTarihBicimi = new Intl.DateTimeFormat("tr-TR", {
  timeZone: SAAT_DILIMI,
  weekday: "long",
  day: "numeric",
  month: "long",
  year: "numeric",
});

// "18 Kasım 2026 Çarşamba"
export function uzunTarih(deger: string): string {
  return uzunTarihBicimi.format(new Date(`${deger}T12:00:00Z`));
}

// "2026-11-10" (date) ya da "2026-11-10T05:12:00+00" (timestamptz) alır.
export function tarih(deger: string | null | undefined): string {
  if (!deger) return "—";
  // Yalnızca tarih ise gün kaymasın diye öğlen saatiyle okunur.
  const d = deger.length === 10 ? new Date(`${deger}T12:00:00Z`) : new Date(deger);
  return tarihBicimi.format(d);
}

export function tarihSaat(deger: string | null | undefined): string {
  if (!deger) return "—";
  return tarihSaatBicimi.format(new Date(deger));
}

const saatBicimi = new Intl.DateTimeFormat("tr-TR", { timeZone: SAAT_DILIMI, hour: "2-digit", minute: "2-digit" });

// "07:52" (Türkiye saati)
export function saat(deger: string | null | undefined): string {
  if (!deger) return "—";
  return saatBicimi.format(new Date(deger));
}

// İki zaman arasındaki süre: "3 sa 20 dk" / "2 gün 4 sa"
export function sure(baslangic: string, bitis: string | null | undefined, simdi = new Date()): string {
  const dk = Math.max(0, Math.round(((bitis ? new Date(bitis) : simdi).getTime() - new Date(baslangic).getTime()) / 60000));
  const gun = Math.floor(dk / 1440);
  const sa = Math.floor((dk % 1440) / 60);
  const kalanDk = dk % 60;
  if (gun > 0) return `${gun} gün ${sa} sa`;
  if (sa > 0) return `${sa} sa ${kalanDk} dk`;
  return `${kalanDk} dk`;
}
