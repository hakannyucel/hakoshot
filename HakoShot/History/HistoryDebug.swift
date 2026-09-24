#if DEBUG
import AppKit
import CoreGraphics
import CoreText
import Foundation
import HakoKit
import os

/// DEBUG helpers for WP2.2: seed history with generated sample images (not
/// screen captures) and show the overlay. Wiring: WP2.2 report
/// ("Entegrasyon parçası").
enum HistoryDebug {
    /// Launch argument: seed samples and show the overlay at launch.
    static let launchArgument = "-HakoHistoryDebug"
    /// Optional `-HakoHistoryDebugRoot <path>`: use a scratch history folder
    /// instead of the real `~/Library/Application Support/HakoShot/History`.
    static let rootArgument = "-HakoHistoryDebugRoot"

    /// Adds `count` generated captures to `store`, spread over the last few days.
    static func seedSamples(count: Int = 8, into store: HistoryStore = .shared) async {
        let modes: [CaptureMode] = [.area, .window, .fullscreen(.preferred), .scrolling, .area, .text, .previousArea, .area]
        let sizes: [(Int, Int)] = [(640, 400), (520, 520), (1280, 800), (420, 1100), (900, 300), (600, 380), (800, 600), (700, 450)]
        let hues: [CGFloat] = [0.58, 0.95, 0.08, 0.33, 0.75, 0.14, 0.48, 0.02]
        let now = Date()
        for i in 0..<count {
            let (w, h) = sizes[i % sizes.count]
            guard let image = sampleImage(width: w * 2, height: h * 2, hue: hues[i % hues.count], label: "Sample \(i + 1)") else { continue }
            let result = CaptureResult(
                image: image,
                pointSize: CGSize(width: w, height: h),
                scale: 2,
                mode: modes[i % modes.count],
                date: now.addingTimeInterval(-Double(i) * 3 * 3600)
            )
            await store.add(result, savedURL: nil)
        }
        Log.history.notice("debug: seeded \(count) samples into \(store.rootURL.path, privacy: .public)")
    }

    /// Seeds (when the store is empty) and shows the overlay.
    static func seedAndShow(controller: HistoryOverlayController = .shared) async {
        if await controller.store.recent(limit: 1).isEmpty {
            await seedSamples(into: controller.store)
        }
        controller.onRestore = { item, image in
            Log.history.notice("debug restore \(item.id.uuidString, privacy: .public) \(image.width)x\(image.height)")
        }
        controller.show()
    }

    private static var debugController: HistoryOverlayController?

    /// Call from `applicationDidFinishLaunching`; does nothing without `launchArgument`.
    static func runFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }
        var controller = HistoryOverlayController.shared
        if let index = arguments.firstIndex(of: rootArgument), arguments.indices.contains(index + 1) {
            let root = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
            controller = HistoryOverlayController(store: HistoryStore(rootURL: root))
            debugController = controller
        }
        Task { await seedAndShow(controller: controller) }
    }

    /// Generated gradient "screenshot" with a fake window and a label.
    static func sampleImage(width: Int, height: Int, hue: CGFloat, label: String) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }
        // Fake window with a title bar.
        let inset = CGFloat(min(width, height)) * 0.12
        let window = CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
        let radius = min(window.width, window.height) * 0.04
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        let barHeight = min(window.height * 0.12, 56)
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
        ctx.fill(CGRect(x: window.minX, y: window.maxY - barHeight, width: window.width, height: barHeight / 2).insetBy(dx: radius, dy: 0))
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let d = barHeight * 0.3
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: window.minX + d + CGFloat(i) * d * 1.6, y: window.maxY - barHeight * 0.65, width: d, height: d))
        }
        // Text lines.
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
        var y = window.maxY - barHeight * 2
        while y > window.minY + barHeight * 0.6 {
            ctx.fill(CGRect(x: window.minX + barHeight * 0.6, y: y, width: window.width * 0.55, height: barHeight * 0.18))
            y -= barHeight * 0.45
        }
        // Label.
        let font = CTFontCreateWithName("SF Pro Display Bold" as CFString, CGFloat(min(width, height)) * 0.1, nil)
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor(hue: hue, saturation: 0.8, brightness: 0.5, alpha: 1).cgColor,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: window.midX - bounds.width / 2, y: window.midY - bounds.height / 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
#endif
