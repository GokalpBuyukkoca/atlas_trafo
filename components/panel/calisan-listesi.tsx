// Sicil numarası alanının açılır önerileri (<input list="...">).
// Tarayıcının kendi listesidir; JavaScript gerektirmez, yazdıkça süzülür.
export type ListeCalisani = { sicil_no: string; ad: string; soyad: string };

export function CalisanListesi({ id, calisanlar }: { id: string; calisanlar: ListeCalisani[] }) {
  return (
    <datalist id={id}>
      {calisanlar.map((c) => (
        <option key={c.sicil_no} value={c.sicil_no}>
          {c.ad} {c.soyad}
        </option>
      ))}
    </datalist>
  );
}
