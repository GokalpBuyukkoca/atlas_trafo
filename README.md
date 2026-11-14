# Atlas Trafo PDKS Kayıt Düzeltme Sistemi
## Sorunlar ve Adım Adım Çözümleri

> Bu doküman, mevcut kartlı PDKS'de yaşanan 17 sorunu ve geliştirdiğimiz sistemin her birini nasıl çözdüğünü anlatır.
> Mevcut kartlı PDKS değişmez; sistem onun kayıtlarını alıp yanında çalışır.

---

## Bütün çözümlerin dayandığı ortak kurallar

1. **Ham kayıt asla değişmez.** PDKS'den gelen kayıt olduğu gibi saklanır. Her düzeltme ayrı bir tabloya yazılır.
2. **Sistem her gece önceki günü işler.** Hatalı veya eksik kayıtları kendisi bulur.
3. **Kanıt varsa sistem düzeltir, yoksa amire sorar.** Kanıt, tesis kapısı veya yemekhane kaydıdır. Amir soruyu ertesi sabah ekranında görür.
4. **Çalışan aleyhine her karar İK'dadır.** Kesinti, devamsızlık ve kart paylaşımı bu kapsamdadır (KVKK m.11). Sistem bu kararları kendisi vermez, yalnızca öneri ve uyarı üretir.
5. **Her işlem kayıt altındadır.** Her düzeltme, onay ve itiraz için kim, ne zaman, eski değer, yeni değer ve gerekçe bilgisi silinemeyen bir kayda yazılır.
6. **Biyometri yok, akıllı telefon varsayılmaz.**

Tablodaki işaretler: **[Y]** yazılım içi öneri, **[F]** fabrikaya öneri (donanım veya prosedür).

---

## A. Okutma Sorunları

### 1. Giriş okutmama

**Sorun:** Çalışan işe gelmiş ama girişte kartını okutmamış. PDKS'de yalnızca çıkış kaydı görünür ve gün eksik ya da devamsız sayılabilir.

**Adım adım çözüm:**
1. Gece işi, çıkışı olup girişi olmayan kayıtları bulur.
2. Sistem aynı gün için çalışanın tesis kapısı ve yemekhane kayıtlarına bakar.
3. **Kanıt varsa:** Giriş saati olarak kapıdan geçiş saati ya da vardiya başlangıcı yazılır. Düzeltmenin türü "otomatik – kanıtlı" olarak işaretlenir.
4. **Kanıt yoksa:** Kayıt, ertesi sabah amirin "Sorulacaklar" listesine düşer.
5. Amir "Geldi, saat şu" ya da "Gelmedi" der. "Gelmedi" cevabı devamsızlık kararı için İK'ya gider.
6. Her adım değişiklik kaydına yazılır.

**Karar veren:** Kanıt varsa sistem, yoksa amir. Devamsızlık kararı İK'nındır.
**Ek öneri [Y]:** Aynı kişide ayda 3'ten fazla tekrarlanırsa İK'ya bilgi raporu gider. Bu rapor ceza değil, yalnızca bilgilendirmedir.

---

### 2. Çıkış okutmama

**Sorun:** Çalışan çıkarken kartını okutmamış. Çalışma süresi hesaplanamaz.

**Adım adım çözüm:**
1. Gece işi, girişi olup çıkışı olmayan kayıtları bulur.
2. Sistem kapıdan çıkış ve servis kaydı gibi kanıtlara bakar.
3. **Kanıt varsa:** Çıkış saati kanıttaki saatle doldurulur ve "otomatik – kanıtlı" olarak işaretlenir.
4. **Kanıt yoksa:** Kayıt amire sorulur. Amir vardiya bitiş saatini ya da gerçek saati onaylar.
5. Amir onaylayana kadar o günün süresi "belirsiz" görünür ve puantaja eksik olarak girmez.

**Karar veren:** Kanıt varsa sistem, yoksa amir.
**Ek öneri [F]:** Çıkış okuyucusunun yanına görünür bir "Kartını okut" uyarısı konması.

---

### 3. Mükerrer okutma

**Sorun:** Çalışan kartını art arda iki veya daha fazla kez okutmuş. Sistemde birden fazla giriş ya da çıkış oluşur ve hesap bozulur.

**Adım adım çözüm:**
1. Gece işi, aynı kişinin kısa süre içindeki (ör. 2 dakika) aynı yönlü okutmalarını bulur.
2. Bunlar tek okutma sayılır. Girişte ilk okutma, çıkışta son okutma esas alınır.
3. Ham kayıtlar silinmez, yalnızca "mükerrer" olarak işaretlenir.
4. Amire soru gitmez, çünkü karar kurala göre otomatik verilir.

**Karar veren:** Sistem.
**Ek öneri [Y]:** Dakika eşiği İK'nın ayar ekranından değiştirilebilsin.

---

### 4. Kart unutma veya kaybetme

**Sorun:** Çalışan kartını evde unutmuş ya da kaybetmiş. O gün hiç okutma kaydı yoktur.

**Adım adım çözüm:**
1. Amir, ekranındaki "Kart unuttu" butonuna basar ve çalışanı seçer.
2. Sistem o gün için kapı ve yemekhane kayıtlarına bakar.
3. **Kanıt varsa:** Amir saatleri tek tıkla onaylar.
4. **Kanıt yoksa:** Amir giriş ve çıkış saatini kendisi girer ve gerekçe yazar.
5. **Kart kaybolduysa:** İK eski kartı sistemde "kayıp" olarak kapatır ve yeni kart tanımlar. Kayıp karttan sonradan gelen okutma şüpheli sayılır.

**Karar veren:** Saatleri amir onaylar. Kart iptali ve yenileme İK'nındır.
**Ek öneri [F]:** Güvenlik günlük geçici kart versin ve bunu deftere değil sisteme işlesin.

---

### 5. Okuyucu arızası

**Sorun:** Bir kart okuyucu bozulmuş. O okuyucunun kullanıldığı saatlerde kimsenin kaydı yoktur.

**Adım adım çözüm:**
1. İK veya sistem yöneticisi arızayı girer: hangi okuyucu, hangi saat aralığında.
2. Sistem, o aralıkta normalde o okuyucuyu kullanan çalışanları listeler.
3. Kanıtı olanların (kapı, yemekhane) kayıtları **toplu olarak onaylanır.**
4. **Kanıtı olmayanlar** tek tek amire düşer.
5. Toplu onay da her çalışan için ayrı ayrı değişiklik kaydına yazılır.

**Karar veren:** Kanıtlılar için sistem, kanıtsızlar için amir.
**Ek öneri [Y]:** Bir okuyucudan saatlerce hiç kayıt gelmezse sistem sabah "arıza şüphesi" uyarısı versin.

---

## B. Kötüye Kullanım

### 6. Başkası adına kart okutma

**Sorun:** Bir çalışan, işe gelmeyen arkadaşının kartını da okutuyor. Gelmeyen kişi gelmiş gibi görünür.

**Adım adım çözüm:**
1. Gece işi 4 otomatik şüphe kuralını çalıştırır:
   - **İki kart kuralı:** Aynı okuyucuda iki farklı kart birkaç saniye arayla okutulmuş.
   - **Gün boyu iz yok:** Kart okutulmuş ama kişinin kapı ve yemekhanede hiç kaydı yok.
   - **Eş zamanlı çift okutma:** Aynı kart aynı anda birbirinden uzak iki noktada okutulmuş.
   - **Tekrar eden desen:** Aynı iki kart düzenli olarak hep birlikte okutuluyor.
2. Amir de ekibinde gelmeyen birini fark ederse ekranındaki **"Eksik bildir"** butonuna basar.
3. Kural ya da amir bildirimiyle yakalanan kayıt **"şüpheli"** olarak İK'ya düşer.
4. Sistem otomatik ceza vermez. İK inceler ve karar verir.
5. Amir yoklaması yapılmaz.

**Karar veren:** İK.
**Ek öneri [F]:** Turnike veya fotoğraflı güvenlik ekranı.

---

## C. Vardiya Sorunları

### 7. Gece vardiyası gün aşımı

**Sorun:** Gece vardiyası 23:00'te başlayıp ertesi gün 07:00'de bitiyor. Takvim gününe göre bakıldığında giriş bir güne, çıkış öbür güne düşer ve iki yarım gün gibi görünür.

**Adım adım çözüm:**
1. Her vardiyanın bir başlangıç ve bitiş saati, bir de tolerans payı (ör. ±2 saat) tanımlanır. Buna "vardiya penceresi" denir.
2. Gece işi okutmaları takvim gününe göre değil, **vardiyanın başladığı güne** bağlar.
3. 23:00 girişi ve ertesi gün 07:00 çıkışı tek vardiya olarak hesaplanır.
4. Puantajda bu çalışma vardiyanın başladığı güne yazılır.

**Karar veren:** Sistem.
**Ek öneri [Y]:** Gece yarısını geçen vakalar için ayrı test senaryoları yazılsın.

---

### 8. Vardiya değişikliğinin işlenmemesi

**Sorun:** Çalışanın vardiyası değişmiş ama sisteme girilmemiş. Çalışan doğru saatte gelse bile geç kalmış ya da devamsız görünür.

**Adım adım çözüm:**
1. Amir, vardiya değişikliğini önceden sistemdeki "Vardiya değişikliği" ekranından girer.
2. Girilmemişse gece işi, okutma saatlerinin planlanan vardiyaya uymadığını fark eder.
3. Sistem okutmaları en yakın vardiyaya eşler ve amire sorar: "Bu kişi gece vardiyasında mıydı?"
4. Amir onaylarsa vardiya güncellenir ve hesaplama yeniden yapılır.
5. Geçmiş tarihli değişiklikler kayda "geriye dönük" olarak yazılır.

**Karar veren:** Amir.
**Ek öneri [Y]:** Geriye dönük vardiya değişikliği ayrıca İK onayına gitsin.

---

### 9. Geç kalma ve erken çıkış hesabı

**Sorun:** Geç kalma ve erken çıkış dakikaları elle ya da tutarsız hesaplanıyor.

**Adım adım çözüm:**
1. Sistem, düzeltilmiş giriş ve çıkış saatini vardiya planıyla karşılaştırır.
2. Tolerans (ör. 5 dakika) düşüldükten sonra geç kalma ve erken çıkış dakikalarını otomatik hesaplar.
3. Hesaplama puantajda **"bilgi"** olarak görünür. Sistem kesinti uygulamaz.
4. Çalışan hesaba itiraz ederse amir bu itirazı sisteme girer.
5. Kesinti yapılıp yapılmayacağına İK karar verir.

**Karar veren:** Sistem hesaplar, kararı İK verir.
**Ek öneri [Y]:** Tolerans dakikası İK ayar ekranından değiştirilebilsin.

---

### 10. Fazla mesai (yazılı onay, 270 saat sınırı)

**Sorun:** Fazla mesai yazılı onay olmadan yapılıyor ve yıllık 270 saat yasal sınırı takip edilmiyor.

**Adım adım çözüm:**
1. Amir, fazla mesai talebini sistemden girer: kim, hangi gün, kaç saat.
2. Talep İK onayına gider ve onaylanınca kayıt altına alınır. Bu, yazılı onay yerine geçer.
3. Gece işi, vardiya süresini aşan çalışmaları bulur.
4. Onayı olan mesai puantaja "fazla mesai" olarak yazılır. Onayı olmayan mesai **"onaysız"** olarak işaretlenip İK'ya düşer.
5. Sistem her çalışanın yıllık toplamını tutar. Toplam 240 saati geçince amire ve İK'ya uyarı verir, 270 saate ulaşınca yeni talep girilemez.

**Karar veren:** Talebi amir girer, onayı İK verir.
**Ek öneri [F]:** Mesai onayının mesai yapılmadan önce alınması kuralı.

---

## D. Düzeltme Süreci Sorunları

### 11. Ay sonunda Excel'de düzeltme

**Sorun:** Hatalar ay sonunda Excel'de elle düzeltiliyor. Kim neyi neden değiştirdi bilinmiyor ve hata riski yüksek.

**Adım adım çözüm:**
1. Tüm düzeltmeler sistemin içinde, ilgili ekranlardan yapılır.
2. Her düzeltme ham kayda değil, ayrı düzeltme tablosuna yazılır.
3. Ay sonunda İK puantajı **kilitler.** Kilitlendikten sonra değişiklik yalnızca İK'nın gerekçeli işlemiyle yapılabilir.
4. Excel yalnızca **çıktı** olarak alınır ve tekrar sisteme yüklenmez.

**Karar veren:** İK (ay sonu kilidi).
**Ek öneri [F]:** Puantajın Excel'de değiştirilmesini yasaklayan bir iç talimat.

---

### 12. Düzeltmelerin izinin olmaması

**Sorun:** Bir kaydın neden değiştiği, kimin değiştirdiği ve eski değerin ne olduğu bilinmiyor.

**Adım adım çözüm:**
1. Her düzeltme, onay ve itirazda sistem şu bilgileri kaydeder: kim, ne zaman, hangi kayıt, eski değer, yeni değer, gerekçe.
2. Bu kayıt tablosu silinemez ve değiştirilemez. Uygulamanın bu tabloda yalnızca ekleme yetkisi vardır.
3. İK, bir çalışanın herhangi bir gününün tüm geçmişini tek ekranda görebilir.

**Karar veren:** Sistem (otomatik kayıt).
**Ek öneri [Y]:** Power BI'da kişi, birim ve tür bazında bir "düzeltme raporu".

---

### 13. Ay sonu yığılması

**Sorun:** Tüm hatalar ay sonunda bir arada fark ediliyor. İK ve amirler birkaç güne yüzlerce düzeltme sığdırmak zorunda kalıyor.

**Adım adım çözüm:**
1. Sistem her gece yalnızca önceki günü işler.
2. Amir her sabah yalnızca dünün sorularını görür. Bu genellikle birkaç kayıttır.
3. Amir soruları aynı gün cevaplar ve sorunlar gün gün kapanır.
4. Ay sonuna yalnızca İK kararı bekleyen az sayıda kayıt kalır.

**Karar veren:** Amir (günlük cevaplar).
**Ek öneri [Y]:** 3 gün cevaplanmayan soru üst amire ve İK'ya yükselsin.

---

### 14. İzin ve raporun geç girilmesi

**Sorun:** Çalışanın izni ya da sağlık raporu sisteme geç giriliyor. O günler devamsızlık olarak görünüyor.

**Adım adım çözüm:**
1. İK, izni veya raporu sisteme girer: tür ve tarih aralığı.
2. Giriş geçmiş bir tarihe aitse sistem o günleri **yeniden hesaplar.**
3. Devamsızlık işaretleri kendiliğinden kalkar ve amire giden ilgili sorular kapanır.
4. Raporun içeriği tutulmaz, yalnızca "raporlu" bilgisi ve tarih aralığı saklanır (KVKK).

**Karar veren:** İK.
**Ek öneri [F]:** Raporun 2 iş günü içinde İK'ya iletilmesi kuralı.

---

## E. Diğer Sorunlar

### 15. Bordroya elle aktarım

**Sorun:** Puantaj bordro programına elle aktarılıyor. Bu yavaş ve hataya açık.

**Adım adım çözüm:**
1. Ay sonunda İK puantajı kilitler.
2. Sistem, kilitli puantajı bordro programının istediği formatta tek bir dosya (Excel/CSV) olarak verir.
3. İK bu dosyayı bordro programına yükler.
4. Dışa aktarımın kendisi de değişiklik kaydına yazılır: kim, ne zaman, hangi ay.

**Karar veren:** İK.
**Ek öneri [F]:** **Varsayım:** Bordro formatı fabrikadan öğrenilecek. İleride bordro programıyla doğrudan entegrasyon yapılabilir.

---

### 16. Tesis kayıtlarının ayrı tutulması

**Sorun:** Kapı, yemekhane ve PDKS kayıtları ayrı yerlerde duruyor ve birbiriyle karşılaştırılmıyor.

**Adım adım çözüm:**
1. Kapı ve yemekhane kayıtları da her gece sisteme alınır. **Varsayım:** Bu kayıtlar CSV/Excel olarak gelir.
2. Tüm kayıtlar aynı sicil numarasıyla eşleştirilir.
3. Gece işi bu kayıtları **kanıt** olarak kullanır (bkz. sorun 1, 2, 4, 5, 6).

**Karar veren:** Sistem.
**Ek öneri [F]:** Tüm sistemlerde aynı sicil numarası kullanılsın ve saatler senkron olsun (NTP).

---

### 17. Çalışanın kendi kaydını görememesi

**Sorun:** Çalışan kendi giriş-çıkış kaydını göremiyor. Hatayı ancak maaşı eksik yatınca fark ediyor.

> **Not:** Çalışanın kaydına sürekli bakabilmesi yasal bir zorunluluk değildir. Çalışan ayın özetini zaten her ay ücret hesap pusulasında (bordro) görür (İş Kanunu m.37). KVKK ise çalışana istediğinde kendi verisini öğrenme hakkı verir. Bu yüzden çözüm, çalışan için sürekli açık bir ekran değil, **istek üzerine kayıt dökümü** vermektir.

**Adım adım çözüm:**
1. Çalışan, kendi kaydını görmek istediğini İK'ya söyler veya yazılı olarak bildirir.
2. İK, sistemdeki **"Çalışan dökümü"** ekranında çalışanı ve tarih aralığını seçer.
3. Sistem tek tıkla bir PDF üretir: giriş-çıkış saatleri, geç kalma, fazla mesai, izin/rapor günleri ve yapılan düzeltmeler (kim, ne zaman, neden).
4. İK bu PDF'i çalışana çıktı olarak ya da e-postayla verir.
5. Çalışan hatalı bir gün görürse İK'ya veya amirine itiraz eder. İtiraz sisteme girilir. Amir sonuçlandırır, konu çalışan aleyhineyse karar İK'nındır.
6. Dökümün kime, ne zaman verildiği ve itirazlar değişiklik kaydına yazılır.

**Karar veren:** İK dökümü verir. İtirazı amir sonuçlandırır, çalışan aleyhine konularda karar İK'nındır.
**Ek öneri [Y]:** Döküm şablonu KVKK bilgi talebine cevap olarak da kullanılabilsin. **Varsayım:** Bu yasal değerlendirme fabrikanın İK'sına veya hukuk danışmanına teyit ettirilecek.

---

## Özet Tablo

| No | Sorun | Karar veren |
|---|---|---|
| 1 | Giriş okutmama | Sistem (kanıtlı) / Amir |
| 2 | Çıkış okutmama | Sistem (kanıtlı) / Amir |
| 3 | Mükerrer okutma | Sistem |
| 4 | Kart unutma/kaybetme | Amir / İK (kart iptali) |
| 5 | Okuyucu arızası | Sistem (kanıtlı) / Amir |
| 6 | Başkası adına okutma | İK |
| 7 | Gece vardiyası gün aşımı | Sistem |
| 8 | Vardiya değişikliğinin işlenmemesi | Amir |
| 9 | Geç kalma/erken çıkış | Sistem hesaplar / İK karar |
| 10 | Fazla mesai | Amir talep / İK onay |
| 11 | Excel'de düzeltme | İK |
| 12 | Düzeltme izinin olmaması | Sistem |
| 13 | Ay sonu yığılması | Amir |
| 14 | İzin/raporun geç girilmesi | İK |
| 15 | Bordroya elle aktarım | İK |
| 16 | Tesis kayıtlarının ayrı tutulması | Sistem |
| 17 | Çalışanın kaydını görememesi | İK döküm verir / Amir-İK itiraz kararı |
