import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";

// Liste boşken gösterilen kutu
export function BosDurum({ children }: { children: ReactNode }) {
  return <div className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">{children}</div>;
}

// Henüz yazılmamış bir veritabanı fonksiyonunu (RPC) bekleyen eylem
export function RpcBekliyor({ dugme, aciklama }: { dugme: string; aciklama: ReactNode }) {
  return (
    <div className="flex flex-col gap-2 rounded-lg border border-dashed p-4">
      <Button disabled className="self-start">{dugme}</Button>
      <p className="text-sm text-muted-foreground">{aciklama}</p>
    </div>
  );
}
