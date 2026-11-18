import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { KAYNAK_ADI, type Kaynak, type Okuyucu } from "@/lib/aktarim/denetim";
import { tarih, tarihSaat } from "@/lib/bicim";
import { bugun, gunEkle } from "@/lib/hafta";
import { rolGerekli } from "@/lib/oturum";
import { tumSatirlar } from "@/lib/supabase/sayfali";
import { sunucuIstemcisi } from "@/lib/supabase/server";
import { AktarimFormu } from "./aktarim-formu";

export const metadata = { title: "Veri aktarımı" };

type Aktarim = { id: number; kaynak: Kaynak; dosya_adi: string; veri_tarihi: string; satir_sayisi: number; aktarim_zamani: string };

const KAYNAKLAR = Object.keys(KAYNAK_ADI) as Kaynak[];
const SON_AKTARIM_SAYISI = 20;

export default async function VeriAktarimiSayfasi() {
  const kullanici = await rolGerekli(["ik", "yonetici"]);
  const supabase = await sunucuIstemcisi();

  const bugunTarih = bugun();
  const ayBasi = `${bugunTarih.slice(0, 7)}-01`;
  // Ayın 1'ine 31 gün eklemek her zaman sonraki aya düşer
  const sonrakiAyBasi = `${gunEkle(ayBasi, 31).slice(0, 7)}-01`;
  const ayAdi = new Intl.DateTimeFormat("tr-TR", { month: "long", year: "numeric", timeZone: "UTC" }).format(
    new Date(`${ayBasi}T00:00:00Z`),
  );

  const [okuyucuSonucu, buAy, sonlar] = await Promise.all([
    supabase.from("okuyucu").select("id, kod, ad, sistem, aktif").order("kod"),
    tumSatirlar<Aktarim>((bas, son) =>
      supabase
        .from("aktarim")
        .select("id, kaynak, dosya_adi, veri_tarihi, satir_sayisi, aktarim_zamani")
        .gte("veri_tarihi", ayBasi)
        .lt("veri_tarihi", sonrakiAyBasi)
        .order("id")
        .range(bas, son),
    ),
    supabase
      .from("aktarim")
      .select("id, kaynak, dosya_adi, veri_tarihi, satir_sayisi, aktarim_zamani")
      .order("veri_tarihi", { ascending: false })
      .order("kaynak")
      .limit(SON_AKTARIM_SAYISI),
  ]);
  if (okuyucuSonucu.error) throw new Error(`Okuyucular okunamadı: ${okuyucuSonucu.error.message}`);
  if (sonlar.error) throw new Error(`Aktarımlar okunamadı: ${sonlar.error.message}`);

  const okuyucular = (okuyucuSonucu.data ?? []) as Okuyucu[];
  const sonAktarimlar = (sonlar.data ?? []) as Aktarim[];

  // Bu ay gelmeyen dosyalar: ayın ilk gününden, gelen en son dosyanın gününe kadar her gün
  // her kaynaktan bir dosya beklenir. (Gece işi de eksik dosya için "dosya_gelmedi" uyarısı üretir.)
  const gelen = new Set(buAy.map((a) => `${a.kaynak}|${a.veri_tarihi}`));
  const sonGun = buAy.reduce((enSon, a) => (a.veri_tarihi > enSon ? a.veri_tarihi : enSon), "");
  const eksikler: { gun: string; kaynak: Kaynak }[] = [];
  for (let g = ayBasi; sonGun && g <= sonGun; g = gunEkle(g, 1)) {
    for (const k of KAYNAKLAR) if (!gelen.has(`${k}|${g}`)) eksikler.push({ gun: g, kaynak: k });
  }

  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-1">
        <h1 className="text-2xl font-semibold">Veri aktarımı</h1>
        <p className="text-sm text-muted-foreground">
          PDKS, kapı, yemekhane ve servis sistemlerinin günlük dosyaları buradan alınır. Ham kayıtlar bir kez yazılır;
          değiştirilemez ve silinemez.
        </p>
      </div>

      {kullanici.rol === "ik" && (
        <section aria-labelledby="yukle-baslik" className="flex flex-col gap-3">
          <div className="flex flex-col gap-1">
            <h2 id="yukle-baslik" className="text-lg font-semibold">Dosya denetle</h2>
            <p className="text-sm text-muted-foreground">
              Biçim: başlık satırı <code className="font-mono">okuyucu;kart_no;zaman;yon</code>, zaman Türkiye saatiyle
              (<code className="font-mono">2026-11-26 08:01</code>). Dosya adına günü yazın:{" "}
              <code className="font-mono">pdks_20261126.csv</code>.{" "}
              <a href="/ornek/pdks_20261201.csv" download className="text-primary underline-offset-4 hover:underline">
                Örnek dosyayı indir
              </a>
            </p>
          </div>
          <AktarimFormu okuyucular={okuyucular} />
        </section>
      )}

      <section aria-labelledby="eksik-baslik" className="flex flex-col gap-3">
        <div className="flex flex-col gap-1">
          <h2 id="eksik-baslik" className="text-lg font-semibold">Gelmeyen dosyalar · {ayAdi}</h2>
          <p className="text-sm text-muted-foreground">
            {sonGun ? `${tarih(ayBasi)} – ${tarih(sonGun)} arasında her gün her sistemden bir dosya beklenir.` : "Bu ay henüz dosya gelmedi."}
          </p>
        </div>
        {sonGun && eksikler.length === 0 ? (
          <div className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">Eksik dosya yok.</div>
        ) : (
          <ul className="flex flex-wrap gap-2">
            {eksikler.map((e) => (
              <li key={`${e.kaynak}|${e.gun}`}>
                <Badge variant="destructive">{tarih(e.gun)} · {KAYNAK_ADI[e.kaynak]}</Badge>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="son-baslik" className="flex flex-col gap-3">
        <h2 id="son-baslik" className="text-lg font-semibold">Son aktarımlar</h2>
        {sonAktarimlar.length === 0 ? (
          <div className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">Henüz aktarım yok.</div>
        ) : (
          <div className="rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Verinin günü</TableHead>
                  <TableHead>Tür</TableHead>
                  <TableHead>Dosya</TableHead>
                  <TableHead className="text-right">Satır</TableHead>
                  <TableHead>Aktarım zamanı</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {sonAktarimlar.map((a) => (
                  <TableRow key={a.id}>
                    <TableCell className="tabular-nums">{tarih(a.veri_tarihi)}</TableCell>
                    <TableCell>{KAYNAK_ADI[a.kaynak]}</TableCell>
                    <TableCell className="font-mono text-xs">{a.dosya_adi}</TableCell>
                    <TableCell className="text-right tabular-nums">{a.satir_sayisi.toLocaleString("tr-TR")}</TableCell>
                    <TableCell className="tabular-nums text-muted-foreground">{tarihSaat(a.aktarim_zamani)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>

      <section aria-labelledby="okuyucu-baslik" className="flex flex-col gap-3">
        <h2 id="okuyucu-baslik" className="text-lg font-semibold">Okuyucular</h2>
        <div className="rounded-lg border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Kod</TableHead>
                <TableHead>Ad</TableHead>
                <TableHead>Sistem</TableHead>
                <TableHead>Durum</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {okuyucular.map((o) => (
                <TableRow key={o.id}>
                  <TableCell className="font-mono">{o.kod}</TableCell>
                  <TableCell>{o.ad}</TableCell>
                  <TableCell>{KAYNAK_ADI[o.sistem]}</TableCell>
                  <TableCell>{o.aktif ? <Badge variant="secondary">Aktif</Badge> : <Badge variant="outline">Pasif</Badge>}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </section>
    </div>
  );
}
