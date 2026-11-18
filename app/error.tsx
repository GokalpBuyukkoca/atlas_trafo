"use client";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";

// Beklenmeyen bir hata olursa (ör. veritabanına ulaşılamadı) bu ekran görünür.
// Kökte duruyor ki (panel)/layout.tsx içindeki hataları da yakalasın.
// Yayında (production) Next.js hata ayrıntısını tarayıcıya göndermez; yalnızca genel mesaj görünür.
export default function Hata({ error, retry }: { error: unknown; retry: () => void }) {
  const mesaj = error instanceof Error && error.message ? error.message : "Sayfa yüklenemedi.";

  return (
    <main className="flex flex-1 items-center justify-center px-4">
      <div className="flex w-full max-w-xl flex-col gap-4">
        <Alert variant="destructive">
          <AlertTitle>Bir sorun oluştu</AlertTitle>
          <AlertDescription>{mesaj}</AlertDescription>
        </Alert>
        <Button variant="outline" onClick={() => retry()} className="self-start">
          Tekrar dene
        </Button>
      </div>
    </main>
  );
}
