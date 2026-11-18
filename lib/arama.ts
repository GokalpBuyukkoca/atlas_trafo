// Adres çubuğundan gelen değer tek ya da çok olabilir (?a=1&a=2); ilkini alırız.
export function tekDeger(deger: string | string[] | undefined): string {
  return (Array.isArray(deger) ? deger[0] : deger) ?? "";
}

// Arama kutusuna yazılanı Supabase süzgecine koymadan önce temizler.
// Yalnızca harf, rakam, boşluk ve tire kalır: virgül, nokta, parantez gibi
// süzgeç dilinde anlamı olan karakterler atılır (kullanıcı girdisi sorguyu değiştiremez).
export function aramaTemizle(deger: string): string[] {
  return deger
    .replace(/[^\p{L}\p{N}\s-]/gu, " ")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 4)
    .map((k) => k.slice(0, 30));
}
