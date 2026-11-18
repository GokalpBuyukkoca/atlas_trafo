import Image from "next/image";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { supabaseAyarlari } from "@/lib/supabase/ayarlar";
import { GirisFormu } from "./giris-formu";

export const metadata = { title: "Giriş" };

export default function GirisSayfasi() {
  const ayarlarHazir = supabaseAyarlari() !== null;

  return (
    <main className="flex flex-1 items-center justify-center bg-muted/40 px-4 py-12">
      <Card className="w-full max-w-sm">
        <CardHeader className="items-center gap-3 text-center">
          <Image
            src="/logo/atlas_isaret_lacivert.png"
            alt="Atlas Trafo"
            width={405}
            height={102}
            className="mx-auto h-auto w-32"
            priority
          />
          <CardTitle className="text-xl">PDKS Kayıt Düzeltme</CardTitle>
          <CardDescription>Kurum e-postanız ve şifrenizle giriş yapın.</CardDescription>
        </CardHeader>
        <CardContent>
          {ayarlarHazir ? (
            <GirisFormu />
          ) : (
            <Alert>
              <AlertTitle>Supabase ayarları eksik</AlertTitle>
              <AlertDescription>
                <code>.env.example</code> dosyasını <code>.env.local</code> olarak kopyalayın, değerleri
                doldurun ve geliştirme sunucusunu yeniden başlatın.
              </AlertDescription>
            </Alert>
          )}
        </CardContent>
      </Card>
    </main>
  );
}
