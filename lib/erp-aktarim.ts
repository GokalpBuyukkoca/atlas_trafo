// ERP aktarımı: kilitli ayın puantaj kalemleri (pdks.v_puantaj_aktarim) standart CSV ve XML biçimine çevrilir.
// Her satır bir çalışanın bir puantaj kodudur. Ücret yoktur; yalnızca gün ve dakika.
// Bu dosyadaki fonksiyonlar tarayıcıya ya da sunucuya bağlı değildir: aynı girdi her zaman aynı metni verir.

export type ErpSatiri = {
  donem: string; // "2026-11"
  sicil: string;
  satirTuru: "normal" | "fark";
  kaynakDonem: string | null; // fark satırında düzeltmenin ait olduğu ay
  kod: string; // NÇ, FM50, FM100, Yİ, RPR, MZR, ÜCSZ, Dİ, DVMSZ, RT, HT
  gun: number;
  dakika: number;
};

export const ERP_SUTUNLARI = ["sicil", "donem", "satir_turu", "kaynak_donem", "kod", "gun", "dakika"] as const;

// Sayılar makinenin okuyacağı biçimde: ondalık ayırıcı nokta, binlik ayırıcı yok
function sayi(n: number): string {
  return Number.isInteger(n) ? String(n) : String(Math.round(n * 10) / 10);
}

// Alan ayırıcıyı (;), tırnağı ya da satır sonunu içeren değer tırnağa alınır
function csvAlani(deger: string): string {
  return /[;"\r\n]/.test(deger) ? `"${deger.replace(/"/g, '""')}"` : deger;
}

// CSV: ayırıcı noktalı virgül, satır sonu CRLF. Dosyaya yazılırken başına UTF-8 BOM eklenir
// (Excel Türkçe karakterleri ancak böyle doğru açar).
export function csvMetni(satirlar: ErpSatiri[]): string {
  const govde = satirlar.map((s) =>
    [s.sicil, s.donem, s.satirTuru, s.kaynakDonem ?? "", s.kod, sayi(s.gun), sayi(s.dakika)].map(csvAlani).join(";"),
  );
  return [ERP_SUTUNLARI.join(";"), ...govde].join("\r\n") + "\r\n";
}

function xmlKacis(deger: string): string {
  return deger
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

// XML: bir <Satir> = bir çalışanın bir puantaj satırı (normal ya da fark), içinde kod kalemleri.
// Biçim bu projenin tanımladığı sade bir standarttır; belirli bir ERP ürününe özel değildir.
export function xmlMetni(donem: string, satirlar: ErpSatiri[], olusturma: string): string {
  const gruplar = new Map<string, ErpSatiri[]>();
  for (const s of satirlar) {
    const anahtar = `${s.sicil}|${s.satirTuru}|${s.kaynakDonem ?? ""}`;
    const grup = gruplar.get(anahtar);
    if (grup) grup.push(s);
    else gruplar.set(anahtar, [s]);
  }

  const satirXml = [...gruplar.values()].map((grup) => {
    const ilk = grup[0];
    const kaynak = ilk.kaynakDonem ? ` kaynakDonem="${xmlKacis(ilk.kaynakDonem)}"` : "";
    const kalemler = grup
      .map((k) => `    <Kalem kod="${xmlKacis(k.kod)}" gun="${sayi(k.gun)}" dakika="${sayi(k.dakika)}"/>`)
      .join("\n");
    return `  <Satir sicil="${xmlKacis(ilk.sicil)}" satirTuru="${ilk.satirTuru}"${kaynak}>\n${kalemler}\n  </Satir>`;
  });

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<PuantajIcmali donem="${xmlKacis(donem)}" olusturma="${xmlKacis(olusturma)}" birim="dakika">`,
    ...satirXml,
    "</PuantajIcmali>",
    "",
  ].join("\n");
}
