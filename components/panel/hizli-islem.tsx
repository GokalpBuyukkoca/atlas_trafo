"use client";

import { useActionState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { BOS_SONUC, type Islem } from "@/lib/islem-sonucu";

// Pencere açmadan tek tıkla yapılan, geri dönüşü önemsiz işlemler için düğme
// (ör. uyarıyı "görüldü" yapmak, itirazı incelemeye almak). Sonuç bildirim olarak çıkar.
export function HizliIslem({
  dugme,
  islem,
  gizli,
  dugmeTuru = "outline",
}: {
  dugme: string;
  islem: Islem;
  gizli: Record<string, string | number>;
  dugmeTuru?: "default" | "outline" | "secondary" | "ghost";
}) {
  const [, gonder, bekliyor] = useActionState(async (onceki: Parameters<Islem>[0], form: FormData) => {
    const sonuc = await islem(onceki, form);
    if (sonuc.durum === "tamam") toast.success(sonuc.mesaj);
    if (sonuc.durum === "hata") toast.error(sonuc.mesaj);
    return sonuc;
  }, BOS_SONUC);

  return (
    <form action={gonder}>
      {Object.entries(gizli).map(([ad, deger]) => (
        <input key={ad} type="hidden" name={ad} value={deger} />
      ))}
      <Button type="submit" size="sm" variant={dugmeTuru} disabled={bekliyor}>
        {bekliyor ? "…" : dugme}
      </Button>
    </form>
  );
}
