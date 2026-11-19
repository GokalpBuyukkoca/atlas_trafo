"use client";

import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";

// Amirin "gelmedi / bilmiyorum" dediği soruda İK kararı: devamsız say ya da saat yaz.
// Devamsızlık çalışan aleyhine karardır (KVKK m.11); gerekçe her zaman zorunludur.
export function IkKararAlanlari({ girisVarsayilan, cikisVarsayilan }: { girisVarsayilan: string; cikisVarsayilan: string }) {
  const [karar, setKarar] = useState<"" | "devamsiz" | "geldi">("");

  return (
    <>
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-1 text-sm font-medium">Karar</legend>
        <label className="flex items-center gap-2 text-sm">
          <input type="radio" name="karar" value="geldi" required checked={karar === "geldi"} onChange={() => setKarar("geldi")} />
          Çalışmış: saati yaz
        </label>
        <label className="flex items-center gap-2 text-sm">
          <input type="radio" name="karar" value="devamsiz" required checked={karar === "devamsiz"} onChange={() => setKarar("devamsiz")} />
          Devamsız say
        </label>
      </fieldset>

      {karar === "geldi" && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="flex flex-col gap-1.5">
            <label htmlFor="giris" className="text-sm font-medium">Giriş</label>
            <Input id="giris" name="giris" type="datetime-local" defaultValue={girisVarsayilan} />
          </div>
          <div className="flex flex-col gap-1.5">
            <label htmlFor="cikis" className="text-sm font-medium">Çıkış</label>
            <Input id="cikis" name="cikis" type="datetime-local" defaultValue={cikisVarsayilan} />
          </div>
        </div>
      )}
      {karar === "devamsiz" && (
        <p className="rounded-lg bg-destructive/10 p-3 text-sm text-destructive">
          Gün &quot;devamsız&quot; olur ve düzeltme çalışan aleyhine işaretlenir. Bu karar geri alınmaz; gerekirse sonradan itirazla düzeltilir.
        </p>
      )}

      <div className="flex flex-col gap-1.5">
        <label htmlFor="gerekce" className="text-sm font-medium">Gerekçe</label>
        <Textarea id="gerekce" name="gerekce" rows={2} required minLength={5} maxLength={1000} placeholder="ör. Çalışanla görüşüldü, mazeret belgesi yok" />
      </div>
    </>
  );
}
