"use client";

import { useState } from "react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { OzetIzgarasi, OzetKarti } from "@/components/panel/ozet-karti";
import { Secim } from "@/components/panel/secim";
import { KAYNAK_ADI, dosyaOzeti, dosyayiDenetle, type DenetimSonucu, type Kaynak, type Okuyucu } from "@/lib/aktarim/denetim";
import { tarih, tarihSaat } from "@/lib/bicim";
import { tarayiciIstemcisi } from "@/lib/supabase/client";

const EN_BUYUK_DOSYA = 20 * 1024 * 1024; // 20 MB
const ONIZLEME_SATIRI = 10;

type Durum =
  | { tur: "bos" }
  | { tur: "okunuyor" }
  | { tur: "hata"; mesaj: string }
  | { tur: "hazir"; dosyaAdi: string; sonuc: DenetimSonucu; ozet: string; onceki: { aktarim_zamani: string } | null };

// Dosya adı "pdks_20261126.csv" gibiyse türü adından tahmin eder
function kaynakTahmini(dosyaAdi: string): Kaynak | null {
  const on = dosyaAdi.toLowerCase().split(/[_\-.\s]/)[0];
  return (["pdks", "kapi", "yemekhane", "servis"] as const).find((k) => k === on) ?? null;
}

// Türkçe Excel CSV'yi çoğu zaman Windows-1254 ile kaydeder; UTF-8 okunamazsa ona düşülür.
function metneCevir(icerik: ArrayBuffer): string {
  const utf8 = new TextDecoder("utf-8").decode(icerik);
  return utf8.includes("�") ? new TextDecoder("windows-1254").decode(icerik) : utf8;
}

export function AktarimFormu({ okuyucular }: { okuyucular: Okuyucu[] }) {
  const [kaynak, setKaynak] = useState<Kaynak>("pdks");
  const [dosya, setDosya] = useState<File | null>(null);
  const [durum, setDurum] = useState<Durum>({ tur: "bos" });

  async function denetle(secilen: File, secilenKaynak: Kaynak) {
    if (secilen.size > EN_BUYUK_DOSYA) {
      setDurum({ tur: "hata", mesaj: "Dosya 20 MB'tan büyük. Günlük dosyalar bundan küçük olmalı." });
      return;
    }
    setDurum({ tur: "okunuyor" });
    try {
      const icerik = await secilen.arrayBuffer();
      const [ozet, sonuc] = await Promise.all([
        dosyaOzeti(icerik),
        Promise.resolve(dosyayiDenetle(metneCevir(icerik), secilen.name, secilenKaynak, okuyucular)),
      ]);
      // Aynı dosya daha önce yüklendiyse veritabanı reddeder; kullanıcıya baştan söylenir.
      const { data, error } = await tarayiciIstemcisi()
        .from("aktarim")
        .select("aktarim_zamani")
        .eq("kaynak", secilenKaynak)
        .eq("dosya_ozeti", ozet)
        .maybeSingle();
      if (error) throw new Error(error.message);
      setDurum({ tur: "hazir", dosyaAdi: secilen.name, sonuc, ozet, onceki: data });
    } catch (e) {
      setDurum({ tur: "hata", mesaj: `Dosya okunamadı: ${e instanceof Error ? e.message : String(e)}` });
    }
  }

  function dosyaSecildi(secilen: File | null) {
    setDosya(secilen);
    if (!secilen) return setDurum({ tur: "bos" });
    const tahmin = kaynakTahmini(secilen.name);
    const k = tahmin ?? kaynak;
    if (tahmin) setKaynak(tahmin);
    void denetle(secilen, k);
  }

  function kaynakDegisti(k: Kaynak) {
    setKaynak(k);
    if (dosya) void denetle(dosya, k);
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-end gap-3">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="kaynak" className="text-sm font-medium">Dosya türü</label>
          <Secim id="kaynak" value={kaynak} onChange={(e) => kaynakDegisti(e.target.value as Kaynak)}>
            {(Object.keys(KAYNAK_ADI) as Kaynak[]).map((k) => (
              <option key={k} value={k}>{KAYNAK_ADI[k]}</option>
            ))}
          </Secim>
        </div>
        <div className="flex min-w-64 flex-1 flex-col gap-1.5 sm:max-w-md">
          <label htmlFor="dosya" className="text-sm font-medium">CSV dosyası</label>
          <Input
            id="dosya"
            type="file"
            accept=".csv,text/csv"
            onChange={(e) => dosyaSecildi(e.target.files?.[0] ?? null)}
          />
        </div>
      </div>

      {durum.tur === "okunuyor" && <p className="text-sm text-muted-foreground" aria-live="polite">Dosya denetleniyor…</p>}

      {durum.tur === "hata" && (
        <Alert variant="destructive">
          <AlertDescription>{durum.mesaj}</AlertDescription>
        </Alert>
      )}

      {durum.tur === "hazir" && <Sonuc durum={durum} kaynak={kaynak} />}
    </div>
  );
}

function Sonuc({ durum, kaynak }: { durum: Extract<Durum, { tur: "hazir" }>; kaynak: Kaynak }) {
  const { sonuc, onceki } = durum;
  const yuklenebilir = sonuc.hatalar.length === 0 && !onceki && sonuc.satirlar.length > 0;

  return (
    <div className="flex flex-col gap-5" aria-live="polite">
      <OzetIzgarasi>
        <OzetKarti baslik="Dosyadaki satır" deger={sonuc.toplamSatir} aciklama={durum.dosyaAdi} />
        <OzetKarti baslik="Yüklenecek satır" deger={sonuc.satirlar.length} aciklama={KAYNAK_ADI[kaynak]} ton={sonuc.satirlar.length ? "iyi" : "notr"} />
        <OzetKarti
          baslik="Hata"
          deger={sonuc.hatalar.length}
          aciklama={sonuc.hatalar.length ? "Düzeltilmeden yüklenemez" : "Hata yok"}
          ton={sonuc.hatalar.length ? "dikkat" : "iyi"}
        />
        <OzetKarti baslik="Verinin günü" deger={sonuc.veriTarihi ? tarih(sonuc.veriTarihi) : "—"} aciklama="Dosya adından ya da satırlardan" />
      </OzetIzgarasi>

      {onceki && (
        <Alert variant="destructive">
          <AlertTitle>Bu dosya daha önce yüklenmiş</AlertTitle>
          <AlertDescription>
            Aynı içerikteki {KAYNAK_ADI[kaynak]} dosyası {tarihSaat(onceki.aktarim_zamani)} tarihinde aktarılmış. Aynı dosya ikinci
            kez yüklenemez.
          </AlertDescription>
        </Alert>
      )}

      {sonuc.uyarilar.length > 0 && (
        <Alert>
          <AlertTitle>Uyarılar</AlertTitle>
          <AlertDescription>
            <ul className="list-disc pl-5">
              {sonuc.uyarilar.map((u, i) => <li key={i}>{u.mesaj}</li>)}
            </ul>
          </AlertDescription>
        </Alert>
      )}

      {sonuc.hatalar.length > 0 && (
        <section aria-labelledby="hata-baslik" className="flex flex-col gap-2">
          <h3 id="hata-baslik" className="font-semibold">Hatalar</h3>
          <div className="max-h-80 overflow-auto rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-20">Satır</TableHead>
                  <TableHead>Sorun</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {sonuc.hatalar.map((h, i) => (
                  <TableRow key={i}>
                    <TableCell className="tabular-nums">{h.satirNo ?? "—"}</TableCell>
                    <TableCell className="whitespace-normal">{h.mesaj}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
          {sonuc.hatalar.length >= 200 && <p className="text-sm text-muted-foreground">İlk 200 hata gösteriliyor.</p>}
        </section>
      )}

      {sonuc.satirlar.length > 0 && (
        <section aria-labelledby="onizleme-baslik" className="flex flex-col gap-2">
          <h3 id="onizleme-baslik" className="font-semibold">Önizleme (ilk {Math.min(ONIZLEME_SATIRI, sonuc.satirlar.length)} satır)</h3>
          <div className="rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-20">Satır</TableHead>
                  <TableHead>Okuyucu</TableHead>
                  <TableHead>Kart</TableHead>
                  <TableHead>Zaman</TableHead>
                  <TableHead>Yön</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {sonuc.satirlar.slice(0, ONIZLEME_SATIRI).map((s) => (
                  <TableRow key={s.satirNo}>
                    <TableCell className="tabular-nums">{s.satirNo}</TableCell>
                    <TableCell className="font-mono">{s.okuyucuKod}</TableCell>
                    <TableCell className="font-mono">{s.kartNo}</TableCell>
                    <TableCell className="tabular-nums">{tarihSaat(s.zaman)}</TableCell>
                    <TableCell>{s.yon === "giris" ? "Giriş" : s.yon === "cikis" ? "Çıkış" : <Badge variant="outline">Yok</Badge>}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </section>
      )}

      <div className="flex flex-col gap-2 rounded-lg border border-dashed p-4">
        <Button disabled className="self-start">
          {yuklenebilir ? `${sonuc.satirlar.length} satırı yükle` : "Yükle"}
        </Button>
        <p className="text-sm text-muted-foreground">
          {yuklenebilir
            ? "Dosya yüklemeye hazır. Yükleme, veritabanındaki aktarım fonksiyonu (RPC) yazılınca açılacak."
            : "Hatalar giderilince ve aktarım fonksiyonu (RPC) yazılınca yükleme açılacak."}
        </p>
      </div>
    </div>
  );
}
