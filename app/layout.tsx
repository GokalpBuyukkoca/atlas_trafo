import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { Toaster } from "@/components/ui/sonner";
import "./globals.css";

// latin-ext: ğ, ş, ı, İ gibi Türkçe harfler için gerekli
const geistSans = Geist({
  variable: "--font-sans",
  subsets: ["latin", "latin-ext"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin", "latin-ext"],
});

export const metadata: Metadata = {
  title: { default: "Atlas Trafo PDKS", template: "%s · Atlas Trafo PDKS" },
  description: "PDKS kayıt düzeltme sistemi",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="tr" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="flex min-h-full flex-col">
        {children}
        {/* Yazma işlemlerinden sonra çıkan kısa bildirimler */}
        <Toaster position="top-right" />
      </body>
    </html>
  );
}
