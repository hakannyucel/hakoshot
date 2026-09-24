# HakoShot

Ekran görüntüsü ve video kaydetmek, düzenlemek ve paylaşmak için macOS menü çubuğu uygulaması.

## Özellikler

- **Yakalama:** alan, önceki alan, tam ekran (aktif ya da tüm ekranlar), pencere, kaydırmalı yakalama (otomatik kaydırma dahil), zamanlayıcı ve All-In-One.
- **Yakalama katmanı:** ekranı dondurma, piksel büyüteci, kenara yapışma, sabit oran ve boyut, çentik kırpma, yakalarken masaüstü simgelerini gizleme.
- **Metin tanıma (OCR) ve QR:** satır sonlu ya da satır sonsuz; dil ipuçları sayesinde Türkçe karakterler korunur.
- **Yakalama sonrası:** Quick Access kartları, kopyalama, kaydetme, sürükle-bırak, ekrana sabitleme (Pin), 1 aylık geçmiş, son kapatılanı geri getirme.
- **Editör:** 12 çizim aracı, kırpma, arka plan paneli (gradyan, düz renk, görsel), görüntü birleştirme, tuval boyutu. Düzenlenebilir `.hakoshot` proje dosyası.
- **Dışa aktarma:** PNG, JPEG, HEIC, WebP; Retina görüntüler için 1x ve `@2x` seçenekleri; `%Y%m%d-%n` gibi dosya adı şablonları.
- **Ekran kaydı:** alan, pencere ve tam ekran; sistem sesi, mikrofon, webcam balonu, tıklama ve tuş gösterimi; duraklatma, yeniden başlatma ve kaydı silme.
- **Video ve GIF:** video editöründe trim, crop, resize ve ses ayarı; GIF kaydı ve dönüştürme.
- **Studio Mode:** otomatik zoom, motion blur, kamera ve imleç düzenlemeleri; düzenlenebilir `.hakostudio` projeleri ve MP4/GIF dışa aktarma.
- **Ayarlar:** kısayol kaydedici, ilk açılış rehberi, girişte başlatma.

## İndirme ve kurulum

Dağıtım dosyaları [GitHub Releases](https://github.com/hakannyucel/hakoshot/releases) sayfasında paylaşılır. İlk dağıtım `0.1.0` ön sürümü, Apple Silicon (`arm64`) içindir ve macOS 26.0 veya üstünü gerektirir.

1. Sürümün **Assets** bölümünden `HakoShot-0.1.0-arm64.dmg` dosyasını indirin.
2. DMG'yi açın ve **HakoShot.app** dosyasını **Applications** klasörüne sürükleyin.
3. DMG'yi çıkarıp uygulamayı Applications'tan açın. HakoShot menü çubuğunda çalışır.

Otomatik güncelleyici yoktur. Yeni sürüm için Releases sayfasını kontrol edin; HakoShot'tan çıkıp yeni uygulamayı Applications'a kopyalayın. Ön sürümde gerçek mikrofon/kamera ve minimum macOS 26 üzerinde elle doğrulama henüz tamamlanmamıştır.

## İzinler

**Sistem Ayarları › Gizlilik ve Güvenlik** altında kullanılan özelliğe göre izin verin:

- **Ekran Kaydı / Ekran ve Sistem Sesi Kaydı:** ekran görüntüsü, ekran kaydı ve sistem sesi için.
- **Erişilebilirlik:** otomatik kaydırmalı yakalama için.
- **Mikrofon:** kayda mikrofon sesi eklemek için.
- **Kamera:** webcam balonu ve Studio kamera kaydı için.
- **Giriş İzleme:** kayıtta tuşları göstermek için.

İzin değişikliğinden sonra macOS isterse uygulamayı yeniden açın.

## Kaynaktan derleme gereksinimleri

- macOS 26.0 veya üstü
- Xcode 26.5 (Swift 6.3)

## Derleme ve kurulum

```sh
scripts/build.sh     # Debug derler, .app yolunu yazar
scripts/test.sh      # HakoKit ve uygulama testlerini çalıştırır
scripts/install.sh   # derler, /Applications/HakoShot.app'e kurar ve açar
```

İmza ayarı isteğe bağlıdır. `Config/Signing.example.xcconfig` dosyasını `Config/Signing.xcconfig` olarak kopyalayıp kendi Team ID ve sertifika hash'inizi girin. Bu dosya git'e girmez. Yoksa uygulama ad-hoc imzalanır ve Ekran Kaydı izni her derlemede yeniden istenir.

Uygulamayı `/Applications` altından çalıştırın. Sabit yol ve aynı imza kimliği, izinlerin derlemeler arasında korunmasına yardımcı olur. Geliştirme imzasından dağıtım imzasına geçerken izinleri yeniden vermeniz gerekebilir.

## Kısayollar

Varsayılan kısayollar macOS'un kendi ekran görüntüsü kısayollarıyla çakışır. Önce **Sistem Ayarları › Klavye › Klavye Kısayolları › Ekran Görüntüleri** altındaki kısayolları kapatın. İlk açılış rehberi bu adımda yardımcı olur.


| Kısayol | Komut               |
| ------- | ------------------- |
| `⌘⇧1`   | All-In-One          |
| `⌘⇧2`   | Metin yakala (OCR)  |
| `⌘⇧3`   | Tam ekran           |
| `⌘⇧4`   | Alan                |
| `⌘⇧5`   | Pencere             |
| `⌘⇧6`   | Önceki alan         |
| `⌘⇧7`   | Kaydırmalı yakalama |
| `⌘⇧8`   | Zamanlayıcı         |
| `⌘⇧9`   | Ekran kaydı / kaydı durdur |


Satır sonsuz metin, geçmiş, masaüstü simgeleri, tüm pinleri kapatma ve panodan açma komutlarının varsayılan kısayolu yoktur. Bunlar **Ayarlar › Shortcuts** sayfasından atanır.

## URL şeması

Her komut `hakoshot://` URL'siyle de tetiklenebilir. Bu, betiklerde ve otomasyonda işe yarar:

```sh
open "hakoshot://capture-area?x=100&y=100&width=400&height=300&action=save"
open "hakoshot://capture-fullscreen?display=all&action=copy"
open "hakoshot://scrolling-capture?autoscroll=true"
open "hakoshot://capture-text?linebreaks=false"
open "hakoshot://open-settings?page=shortcuts"
```

`action` şunlardan biri olabilir: `copy`, `save`, `annotate`, `pin`. Tam liste `HakoShot/App/URLSchemeHandler.swift` dosyasındadır.

## Proje yapısı

```
HakoShot/              Uygulama (AppKit + SwiftUI), özellik başına klasör
  App/                 AppCoordinator, AppCommand, URL şeması
  Capture/ Overlay/    ScreenCaptureKit yakalama ve seçim katmanı
  Editor/              Çizim editörü, kırpma, arka plan paneli
  Recording/           Ekran kaydı, video/GIF, Studio editörü ve dışa aktarma
  QuickAccess/ Pin/ History/ OCR/ Scrolling/ Settings/ ...
HakoShotTests/         Uygulama testleri
Packages/HakoKit/      Saf mantık (AppKit/SwiftUI yok): geometri, isimlendirme,
                       dışa aktarma, çizim modeli, proje dosyası, render, birleştirme
scripts/               build, test, install
Config/                Derleme ayarları
```

`HakoKit` bağımsız olarak da test edilebilir:

```sh
cd Packages/HakoKit && swift test
```

## Bağımlılıklar

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts): global kısayollar
- [libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode): WebP kodlama


Üçüncü taraf lisansları [ThirdPartyNotices.txt](HakoShot/Resources/ThirdPartyNotices.txt) dosyasında ve uygulamanın kaynakları içinde bulunur.
