import Image from "next/image";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { cikisYap } from "@/app/giris/actions";
import { MenuBaglantisi } from "@/components/panel/menu-baglantisi";
import { MENU } from "@/lib/menu";
import { ROL_ADI, oturumKullanicisi } from "@/lib/oturum";

// (panel) klasörü bir "route group": adresi değiştirmez, yalnızca giriş
// gerektiren sayfaları bu ortak düzenin (kenar çubuğu + üst bar) altında toplar.
export default async function PanelDuzeni({ children }: LayoutProps<"/">) {
  const kullanici = await oturumKullanicisi();

  if (!kullanici) {
    return (
      <main className="flex flex-1 items-center justify-center px-4">
        <div className="flex w-full max-w-md flex-col gap-4">
          <Alert>
            <AlertTitle>Hesabınız sisteme bağlı değil</AlertTitle>
            <AlertDescription>
              Giriş yaptınız, ancak hesabınız bir PDKS kullanıcısına bağlı değil ya da pasif. İK ile görüşün.
            </AlertDescription>
          </Alert>
          <form action={cikisYap}>
            <Button type="submit" variant="outline">Çıkış yap</Button>
          </form>
        </div>
      </main>
    );
  }

  return (
    <div className="flex min-h-svh flex-1">
      <aside className="hidden w-60 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground md:flex">
        <div className="flex items-center gap-3 border-b px-5 py-4">
          <Image src="/logo/atlas_simge.png" alt="Atlas Trafo" width={163} height={163} className="size-9" />
          <div className="leading-tight">
            <div className="font-semibold">Atlas Trafo</div>
            <div className="text-xs text-muted-foreground">PDKS Kayıt Düzeltme</div>
          </div>
        </div>
        <nav aria-label="Ana menü" className="flex flex-col gap-1 p-3">
          {MENU[kullanici.rol].map((oge) => (
            <MenuBaglantisi key={oge.yol} {...oge} />
          ))}
        </nav>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center justify-between gap-4 border-b px-4 py-3 md:px-6">
          <div className="flex items-center gap-2 md:hidden">
            <Image src="/logo/atlas_simge.png" alt="Atlas Trafo" width={163} height={163} className="size-8" />
            <span className="font-semibold">Atlas Trafo</span>
          </div>
          <div className="ml-auto flex items-center gap-4">
            <div className="text-right leading-tight">
              <div className="text-sm font-medium">{kullanici.adSoyad}</div>
              <div className="text-xs text-muted-foreground">{ROL_ADI[kullanici.rol]}</div>
            </div>
            <form action={cikisYap}>
              <Button type="submit" variant="outline" size="sm">Çıkış</Button>
            </form>
          </div>
        </header>
        {/* Dar ekranda kenar çubuğu gizli; menü üst barın altında yatay durur. */}
        <nav aria-label="Ana menü" className="flex gap-1 overflow-x-auto border-b px-3 py-2 md:hidden">
          {MENU[kullanici.rol].map((oge) => (
            <MenuBaglantisi key={oge.yol} {...oge} yatay />
          ))}
        </nav>
        <main className="flex-1 p-4 md:p-6">{children}</main>
      </div>
    </div>
  );
}
