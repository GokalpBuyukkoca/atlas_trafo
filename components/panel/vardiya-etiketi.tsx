import { cn } from "@/lib/utils";

// Vardiyalar renkle ayrılır; renk tek başına anlam taşımasın diye etikette kod da yazar.
const VARDIYA_RENGI: Record<string, string> = {
  GUNDUZ: "bg-sky-100 text-sky-900 dark:bg-sky-950 dark:text-sky-200",
  V1: "bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200",
  V2: "bg-violet-100 text-violet-900 dark:bg-violet-950 dark:text-violet-200",
  V3: "bg-slate-800 text-slate-50 dark:bg-slate-700",
};
const VARDIYA_KISA: Record<string, string> = { GUNDUZ: "Gündüz" };

export function vardiyaAdi(kod: string): string {
  return VARDIYA_KISA[kod] ?? kod;
}

export function VardiyaEtiketi({ kod, ustuCizili = false }: { kod: string; ustuCizili?: boolean }) {
  return (
    <span
      className={cn(
        "inline-flex min-w-14 justify-center rounded px-1.5 py-0.5 text-xs font-semibold",
        VARDIYA_RENGI[kod] ?? "bg-secondary text-secondary-foreground",
        ustuCizili && "line-through opacity-60",
      )}
    >
      {vardiyaAdi(kod)}
    </span>
  );
}
