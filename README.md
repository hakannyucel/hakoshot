# HakoShot

Ekran görüntüsü almak, düzenlemek ve paylaşmak için kişisel macOS menü çubuğu uygulaması.

## Özellikler

- **Yakalama:** alan, önceki alan, tam ekran (aktif ya da tüm ekranlar), pencere, kaydırmalı yakalama (otomatik kaydırma dahil), zamanlayıcı ve All-In-One.
- **Yakalama katmanı:** ekranı dondurma, piksel büyüteci, kenara yapışma, sabit oran ve boyut, çentik kırpma, yakalarken masaüstü simgelerini gizleme.
- **Metin tanıma (OCR) ve QR:** satır sonlu ya da satır sonsuz; dil ipuçları sayesinde Türkçe karakterler korunur.
- **Yakalama sonrası:** Quick Access kartları, kopyalama, kaydetme, sürükle-bırak, ekrana sabitleme (Pin), 1 aylık geçmiş, son kapatılanı geri getirme.
- **Editör:** 12 çizim aracı, kırpma, arka plan paneli (gradyan, düz renk, görsel), görüntü birleştirme, tuval boyutu. Düzenlenebilir `.hakoshot` proje dosyası.
- **Dışa aktarma:** PNG, JPEG, HEIC, WebP; Retina görüntüler için 1x ve `@2x` seçenekleri; `%Y%m%d-%n` gibi dosya adı şablonları.
- **Ayarlar:** 8 sayfa, kısayol kaydedici, ilk açılış rehberi, girişte başlatma.

## Gereksinimler

- macOS 26.0 veya üstü
- Xcode 26.5 (Swift 6.3)
- Ekran Kaydı izni (her yakalama için). Erişilebilirlik izni yalnızca otomatik kaydırma için gerekir.

## Derleme ve kurulum

```sh
scripts/build.sh     # Debug derler, .app yolunu yazar
scripts/test.sh      # HakoKit ve uygulama testlerini çalıştırır
scripts/install.sh   # derler, /Applications/HakoShot.app'e kurar ve açar
```

İmza ayarı isteğe bağlıdır. `Config/Signing.example.xcconfig` dosyasını `Config/Signing.xcconfig` olarak kopyalayıp kendi Team ID ve sertifika hash'inizi girin. Bu dosya git'e girmez. Yoksa uygulama ad-hoc imzalanır ve Ekran Kaydı izni her derlemede yeniden istenir.

Uygulama her zaman `/Applications` altından çalıştırılmalıdır. Böylece Ekran Kaydı izni ve girişte başlatma ayarı derlemeler arasında korunur.

İzin bir güncellemeden sonra takılırsa:

```sh
tccutil reset ScreenCapture com.hakanyucel.HakoShot
```

Ardından HakoShot'u yeniden açın.

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

