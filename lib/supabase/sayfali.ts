// Supabase (PostgREST) bir sorguda en fazla 1000 satır döndürür; fazlası sessizce kesilir.
// Bu yardımcı sorguyu 1000'erli sayfalarla tekrarlayıp bütün satırları toplar.
// Sayfalar arasında satır kaymasın diye sorgu benzersiz bir sütuna göre sıralanmalı (ör. id).
// Üretilmiş veritabanı tipleri olmadığı için satır tipini (T) çağıran söyler.
type Yanit = { data: unknown[] | null; error: { message: string } | null };

export async function tumSatirlar<T>(
  getir: (bas: number, son: number) => PromiseLike<Yanit>,
  sayfaBoyu = 1000,
): Promise<T[]> {
  const satirlar: T[] = [];
  for (let bas = 0; ; bas += sayfaBoyu) {
    const { data, error } = await getir(bas, bas + sayfaBoyu - 1);
    if (error) throw new Error(error.message);
    satirlar.push(...((data ?? []) as T[]));
    if (!data || data.length < sayfaBoyu) return satirlar;
  }
}
