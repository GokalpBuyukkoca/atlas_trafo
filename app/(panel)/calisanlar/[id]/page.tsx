import Link from "next/link";
import { notFound } from "next/navigation";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { OzetIzgarasi, OzetKarti } from "@/components/panel/ozet-karti";
import { VardiyaEtiketi } from "@/components/panel/vardiya-etiketi";
import { tekDeger } from "@/lib/arama";
import { aylikDokum } from "@/lib/dokum";
import { bugun } from "@/lib/hafta";
import { rolGerekli } from "@/lib/oturum";
import { ayAdi, ayKaydir, saatDakika } from "@/lib/puantaj";
import { sunucuIstemcisi } from "@/lib/supabase/server";
import { cn } from "@/lib/utils";
import { PdfIndir } from "./pdf-indir";

export const metadata = { title: "Çalışan" };

export default async function CalisanSayfasi({ params, searchParams }: PageProps<"/calisanlar/[id]">) {
  const kullanici = await rolGerekli(["amir", "ik", "yonetici"]);
  const [{ id }, parametre] = await Promise.all([params, searchParams]);

  const calisanId = Number.parseInt(id, 10);
  if (!calisanId) notFound();
  const istenen = tekDeger(parametre.ay);
  const ay = /^\d{4}-(0[1-9]|1[0-2])$/.test(istenen) ? istenen : bugun().slice(0, 7);

  const supabase = await sunucuIstemcisi();
  // Amir başka bölümün çalışanını açmaya çalışırsa RLS satırı döndürmez → 404
  const dokum = await aylikDokum(supabase, calisanId, ay, kullanici.rol);
  if (!dokum) notFound();

  const { calisan, gunler, duzeltmeler, ozet } = dokum;
  const bugunTarih = bugun();
  const adres = (a: string) => `/calisanlar/${calisanId}?ay=${a}`;

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-2">
        <Link href="/calisanlar" className="self-start text-sm text-muted-foreground hover:text-foreground">← Çalışanlar</Link>
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h1 className="text-2xl font-semibold">{calisan.adSoyad}</h1>
          {!calisan.aktif && <Badge variant="outline">Ayrıldı</Badge>}
        </div>
        <p className="text-sm text-muted-foreground">
          Sicil <span className="font-mono">{calisan.sicil}</span> · {calisan.bolum} · İşe giriş {calisan.iseGiris}
          {calisan.kart && <> · Kart <span className="font-mono">{calisan.kart}</span></>}
        </p>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <nav aria-label="Ay" className="flex flex-wrap items-center gap-2">
          <Link href={adres(ayKaydir(ay, -1))} className={buttonVariants({ variant: "outline", size: "sm" })}>←</Link>
          <span className="min-w-28 text-center font-semibold">{ayAdi(ay)}</span>
          <Link href={adres(ayKaydir(ay, 1))} className={buttonVariants({ variant: "outline", size: "sm" })}>→</Link>
        </nav>
        {kullanici.rol === "ik" && <PdfIndir dokum={dokum} hazirlayan={kullanici.adSoyad} />}
      </div>

      <OzetIzgarasi>
        <OzetKarti baslik="Planlı gün" deger={ozet.planliGun} aciklama="İzinli günler hariç" />
        <OzetKarti baslik="İzinli gün" deger={ozet.izinliGun} />
        <OzetKarti baslik="Çalışma" deger={saatDakika(ozet.calismaDk)} aciklama={`Fazla mesai ${saatDakika(ozet.fazlaMesaiDk)} (sa:dk)`} />
        <OzetKarti baslik="Düzeltme" deger={duzeltmeler.length} aciklama="Bu ayın kayıtlarında" />
      </OzetIzgarasi>

      {ozet.gunKaydi === 0 && (
        <Alert>
          <AlertTitle>Bu ay için gün kaydı yok</AlertTitle>
          <AlertDescription>Giriş-çıkış saatleri gece işi çalışınca oluşur. Plan, izin ve fazla mesai bilgileri aşağıda.</AlertDescription>
        </Alert>
      )}

      <div className="rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Gün</TableHead>
              <TableHead>Plan</TableHead>
              <TableHead>Giriş</TableHead>
              <TableHead>Çıkış</TableHead>
              <TableHead className="text-right">Çalışma</TableHead>
              <TableHead>Durum</TableHead>
              <TableHead>Not</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {gunler.map((g) => {
              const notlar = [
                g.tatil && `Resmi tatil: ${g.tatil}`,
                g.planNotu,
                g.fazlaMesai && `Fazla mesai ${g.fazlaMesai}`,
                g.geciciKart && `Geçici kart ${g.geciciKart}`,
                g.gecKalmaDk ? `Geç kalma ${g.gecKalmaDk} dk` : null,
                g.erkenCikisDk ? `Erken çıkış ${g.erkenCikisDk} dk` : null,
              ].filter(Boolean);
              return (
                <TableRow key={g.tarih} className={cn(g.haftaSonu && !g.vardiya && "text-muted-foreground", g.tarih === bugunTarih && "bg-primary/5")}>
                  <TableCell className="tabular-nums whitespace-nowrap">
                    <span className="inline-block w-8">{g.gunAdi}</span> {g.tarihMetni}
                  </TableCell>
                  <TableCell>
                    {g.izin ? <Badge variant="outline">{g.izin}</Badge> : g.vardiyaKod ? <VardiyaEtiketi kod={g.vardiyaKod} /> : "—"}
                  </TableCell>
                  <TableCell className="tabular-nums">
                    {g.giris ?? "—"}
                    {g.girisKaynagi && g.girisKaynagi !== "PDKS" && <span className="ml-1 text-xs text-muted-foreground">({g.girisKaynagi})</span>}
                  </TableCell>
                  <TableCell className="tabular-nums">
                    {g.cikis ?? "—"}
                    {g.cikisKaynagi && g.cikisKaynagi !== "PDKS" && <span className="ml-1 text-xs text-muted-foreground">({g.cikisKaynagi})</span>}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{g.calismaDk != null ? saatDakika(g.calismaDk) : "—"}</TableCell>
                  <TableCell>{g.durum ?? "—"}</TableCell>
                  <TableCell className="max-w-80 whitespace-normal text-sm text-muted-foreground">{notlar.join(" · ") || ""}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>

      <section aria-labelledby="duzeltme-baslik" className="flex flex-col gap-3">
        <div className="flex flex-col gap-1">
          <h2 id="duzeltme-baslik" className="text-lg font-semibold">Düzeltmeler</h2>
          <p className="text-sm text-muted-foreground">Ham kayıt değiştirilmez; her düzeltme kim, ne zaman, eski-yeni değer ve gerekçesiyle saklanır.</p>
        </div>
        {duzeltmeler.length === 0 ? (
          <div className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">Bu ay düzeltme yok.</div>
        ) : (
          <div className="rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Gün</TableHead>
                  <TableHead>Alan</TableHead>
                  <TableHead>Eski</TableHead>
                  <TableHead>Yeni</TableHead>
                  <TableHead>Gerekçe</TableHead>
                  <TableHead>Yapan</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {duzeltmeler.map((d, i) => (
                  <TableRow key={i}>
                    <TableCell className="tabular-nums">{d.gun}</TableCell>
                    <TableCell>{d.alan}{d.aleyhine && <Badge variant="destructive" className="ml-2">Aleyhe</Badge>}</TableCell>
                    <TableCell className="tabular-nums">{d.eski}</TableCell>
                    <TableCell className="tabular-nums">{d.yeni}</TableCell>
                    <TableCell className="max-w-72 whitespace-normal">{d.gerekce}</TableCell>
                    <TableCell className="text-muted-foreground">{d.kaynak} · {d.yapan}<div className="text-xs">{d.zaman}</div></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>
    </div>
  );
}
