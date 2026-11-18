"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";

// Menüdeki bir bağlantı. Açık olan sayfa vurgulanır.
// usePathname tarayıcıdaki adresi okuduğu için bu bileşen "use client".
export function MenuBaglantisi({ yol, baslik, yatay = false }: { yol: string; baslik: string; yatay?: boolean }) {
  const adres = usePathname();
  const acik = yol === "/" ? adres === "/" : adres === yol || adres.startsWith(`${yol}/`);

  return (
    <Link
      href={yol}
      aria-current={acik ? "page" : undefined}
      className={cn(
        "rounded-md px-3 py-2 text-sm font-medium whitespace-nowrap transition-colors",
        "hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
        acik && "bg-sidebar-accent text-sidebar-accent-foreground",
        yatay && "py-1.5",
      )}
    >
      {baslik}
    </Link>
  );
}
