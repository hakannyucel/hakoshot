# hakoshot

## Çalışma modeli: Orchestrator

Ana ajan (Claude) orchestrator leader olarak çalışır. Kullanıcı yalnızca orchestrator ile muhatap olur.

- Orchestrator işi planlar, parçalara böler ve her parçayı subagent'a verir.
- Subagent'lar işi yapar ve sonucu orchestrator'a raporlar. Kullanıcıyla doğrudan konuşmaz.
- Orchestrator subagent çıktılarını kontrol eder, birleştirir ve kullanıcıya tek, özet bir rapor sunar.
- Birbirinden bağımsız işler paralel subagent'larla yürütülür.
- Kalıcı değeri olan araştırma ve kararlar `reports/` altına kaydedilir (bkz. Reports).
- Kullanıcıya ait kararlar (kapsam, öncelik, geri dönüşü zor adımlar) orchestrator tarafından kullanıcıya sorulur. Subagent bu kararları kendi başına vermez.

## Proje: HakoShot

Ekran görüntüsü almak, düzenlemek ve sabitlemek için kişisel macOS menü çubuğu uygulaması (Swift 6.3, macOS 26+).

- `HakoShot/`: uygulama (AppKit + SwiftUI), özellik başına klasör.
- `Packages/HakoKit/`: saf mantık (AppKit/SwiftUI yok), `swift test` ile test edilir.
- Ekran kaydı (Studio Mode dahil): `HakoShot/Recording/`; plan ve ilerleme `reports/kayit-*.md`.
- Komutlar: `scripts/build.sh`, `scripts/test.sh`, `scripts/install.sh` (derler, `/Applications/HakoShot.app`'e kurar ve açar). Paralel çalışmada `DERIVED_DATA=<yol>` ve `SWIFTPM_SCRATCH=<yol>` ile ayrı klasör kullan.
- Duman testleri `hakoshot://` URL'leriyle yapılır (ör. `open "hakoshot://capture-area?x=100&y=100&width=400&height=300&action=save"`).
- Güncel durum ve API özetleri: `reports/ilerleme.md`. Tasarım kararları: `reports/hakoshot-teknik-plan.md`, `reports/kapsam-kararlari.md`.
- Test görüntüleri kullanıcının ekranını içerir: incelendikten sonra silinir, içeriği anlatılmaz.

## Reports

`reports/` klasörü, araştırdığımız ve birlikte düşündüğümüz bilgileri `.md` formatında tutar.

- Göreve başlamadan önce `reports/` içindeki ilgili dosyaları oku ve referans al.
- Yeni araştırma ya da karar çıktılarını `reports/` altına `.md` olarak kaydet.
- Dosya adları kısa, açıklayıcı ve kebab-case olsun (ör. `reports/rakip-analizi.md`).
- Mevcut bir rapor konuyu zaten kapsıyorsa yeni dosya açma, onu güncelle.
