"use client";

import { useState } from "react";
import { Textarea } from "@/components/ui/textarea";

type Ozellikler = {
  onayAdi?: string; // ör. "Kabul et"
  retAdi?: string; // ör. "Reddet"
  // Gerekçe ne zaman zorunlu: çalışan aleyhine kararlarda (ret) gerekçe hep istenir
  gerekceZorunlu?: "ret" | "her_zaman";
  retUyarisi?: string; // ret seçilince gösterilen not
};

// Onay / ret kararı veren pencerelerin ortak alanları: "karar" (onay | ret) ve "aciklama".
// Server Action bu iki alanı okur; zorunluluğu veritabanı da ayrıca denetler.
export function KararAlanlari({ onayAdi = "Onayla", retAdi = "Reddet", gerekceZorunlu = "ret", retUyarisi }: Ozellikler) {
  const [karar, setKarar] = useState<"" | "onay" | "ret">("");
  const zorunlu = gerekceZorunlu === "her_zaman" || karar === "ret";

  return (
    <>
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-1 text-sm font-medium">Karar</legend>
        <label className="flex items-center gap-2 text-sm">
          <input type="radio" name="karar" value="onay" required checked={karar === "onay"} onChange={() => setKarar("onay")} />
          {onayAdi}
        </label>
        <label className="flex items-center gap-2 text-sm">
          <input type="radio" name="karar" value="ret" required checked={karar === "ret"} onChange={() => setKarar("ret")} />
          {retAdi}
        </label>
      </fieldset>
      {karar === "ret" && retUyarisi && <p className="rounded-lg bg-muted p-3 text-sm">{retUyarisi}</p>}
      <div className="flex flex-col gap-1.5">
        <label htmlFor="aciklama" className="text-sm font-medium">
          Gerekçe{zorunlu ? "" : " (isteğe bağlı)"}
        </label>
        <Textarea id="aciklama" name="aciklama" rows={2} maxLength={1000} required={zorunlu} minLength={zorunlu ? 5 : undefined} />
      </div>
    </>
  );
}
