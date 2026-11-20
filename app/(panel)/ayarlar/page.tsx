import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { IslemPenceresi } from "@/components/panel/islem-penceresi";
import { tarihSaat } from "@/lib/bicim";
import { rolGerekli } from "@/lib/oturum";
import { sunucuIstemcisi } from "@/lib/supabase/server";
import { ayarGuncelle } from "./actions";

export const metadata = { title: "Ayarlar" };

type Ayar = {
  anahtar: string;
  deger: number;
  birim: string;
  aciklama: string;
  guncelleme_zamani: string;
  guncelleyen: { ad_soyad: string } | null;
};
type Gecmis = { id: number; anahtar: string; eski_deger: number | null; yeni_deger: number; degisim_zamani: string; guncelleyen: { ad_soyad: string } | null };

// Kuralların eşikleri (tolerans, mola, fazla mesai sınırları…) koda değil bu tabloya yazılıdır.
// Yalnızca sistem yöneticisi değiştirir; her değişiklik geçmişe yazılır.
export default async function AyarlarSayfasi() {
  await rolGerekli(["admin"]);
  const supabase = await sunucuIstemcisi();

  const [ayarSonucu, gecmisSonucu] = await Promise.all([
    supabase.from("ayar").select("anahtar, deger, birim, aciklama, guncelleme_zamani, guncelleyen:kullanici!guncelleyen_id(ad_soyad)").order("anahtar"),
    supabase
      .from("ayar_gecmisi")
      .select("id, anahtar, eski_deger, yeni_deger, degisim_zamani, guncelleyen:kullanici!guncelleyen_id(ad_soyad)")
      .order("id", { ascending: false })
      .limit(20),
  ]);
  if (ayarSonucu.error) throw new Error(`Ayarlar okunamadı: ${ayarSonucu.error.message}`);

  const ayarlar = (ayarSonucu.data ?? []) as unknown as Ayar[];
  const gecmis = (gecmisSonucu.data ?? []) as unknown as Gecmis[];

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-2xl font-semibold">Ayarlar</h1>
        <p className="text-sm text-muted-foreground">
          Kuralların eşikleri. Değişiklik bir sonraki gece işinde ve hesapta kullanılır; kilitli ayları etkilemez.
        </p>
      </div>

      <div className="rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Ayar</TableHead>
              <TableHead className="text-right">Değer</TableHead>
              <TableHead>Son değişiklik</TableHead>
              <TableHead><span className="sr-only">İşlem</span></TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {ayarlar.map((a) => (
              <TableRow key={a.anahtar}>
                <TableCell className="max-w-96 whitespace-normal">
                  <div className="text-sm">{a.aciklama}</div>
                  <div className="font-mono text-xs text-muted-foreground">{a.anahtar}</div>
                </TableCell>
                <TableCell className="text-right tabular-nums whitespace-nowrap">
                  {a.deger.toLocaleString("tr-TR")} <span className="text-muted-foreground">{a.birim}</span>
                </TableCell>
                <TableCell className="text-sm text-muted-foreground">
                  {a.guncelleyen ? `${a.guncelleyen.ad_soyad}, ${tarihSaat(a.guncelleme_zamani)}` : "—"}
                </TableCell>
                <TableCell className="text-right">
                  <IslemPenceresi
                    dugme="Değiştir"
                    dugmeTuru="ghost"
                    baslik={a.aciklama}
                    aciklama={`Şu an: ${a.deger.toLocaleString("tr-TR")} ${a.birim}. Eski ve yeni değer geçmişe yazılır.`}
                    onay="Kaydet"
                    islem={ayarGuncelle}
                    gizli={{ anahtar: a.anahtar }}
                  >
                    <label htmlFor={`deger-${a.anahtar}`} className="text-sm font-medium">Yeni değer ({a.birim})</label>
                    <Input id={`deger-${a.anahtar}`} name="deger" type="number" min={0} step={1} required defaultValue={a.deger} />
                  </IslemPenceresi>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <section aria-labelledby="gecmis-baslik" className="flex flex-col gap-2">
        <h2 id="gecmis-baslik" className="text-lg font-semibold">Değişiklik geçmişi</h2>
        {gecmis.length === 0 ? (
          <p className="text-sm text-muted-foreground">Henüz değişiklik yok.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-sm text-muted-foreground">
            {gecmis.map((g) => (
              <li key={g.id}>
                <span className="tabular-nums">{tarihSaat(g.degisim_zamani)}</span> · <span className="font-mono">{g.anahtar}</span>:{" "}
                {g.eski_deger ?? "—"} → {g.yeni_deger} ({g.guncelleyen?.ad_soyad ?? "sistem"})
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
