import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { ROL_ADI, oturumKullanicisi, type Rol } from "@/lib/oturum";

const ROL_ACIKLAMASI: Record<Rol, string> = {
  amir: "Bölümünüzde kanıt bulunamayan kayıtlar için gelen soruları cevaplar, çalışan itirazlarını girersiniz.",
  ik: "Uyarıları ve itirazları sonuçlandırır, ayı kilitler, puantajı alırsınız.",
  guvenlik: "Kartını unutan çalışana geçici kart verir, iadesini alırsınız.",
  yonetici: "Fabrika genelindeki kayıtları ve raporları görürsünüz (yalnızca okuma).",
};

export default async function AnaSayfa() {
  // Layout zaten kontrol etti; cache() sayesinde veritabanına tekrar gidilmez.
  const kullanici = await oturumKullanicisi();
  if (!kullanici) return null;

  return (
    <div className="flex max-w-3xl flex-col gap-6">
      <h1 className="text-2xl font-semibold">Hoş geldiniz, {kullanici.adSoyad}</h1>
      <Card>
        <CardHeader>
          <CardTitle>{ROL_ADI[kullanici.rol]}</CardTitle>
          <CardDescription>{ROL_ACIKLAMASI[kullanici.rol]}</CardDescription>
        </CardHeader>
      </Card>
    </div>
  );
}
