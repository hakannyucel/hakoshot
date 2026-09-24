#if DEBUG
import AppKit
import CoreGraphics
import Foundation

/// DEBUG helper: shows Quick Access cards for generated test images (no screen capture,
/// no permission needed). Saving uses the real `AppSettings.shared` output folder.
enum QuickAccessDebug {
    /// Kept alive for the app's lifetime; integration code should use its own controller.
    static let controller = QuickAccessController()

    /// Shows `count` sample cards (different aspect ratios). `hoverNewest` forces the
    /// hover controls on the newest card (for screenshots / visual QA).
    static func showSample(count: Int = 1, hoverNewest: Bool = false) {
        let sizes: [CGSize] = [CGSize(width: 800, height: 500), CGSize(width: 600, height: 600), CGSize(width: 1200, height: 400)]
        var lastID: UUID?
        for index in 0..<max(1, count) {
            guard let result = sampleResult(pointSize: sizes[index % sizes.count], hue: CGFloat(index) * 0.17) else { continue }
            lastID = controller.show(result)
        }
        if hoverNewest, let lastID {
            controller.debugSetHovered(lastID)
        }
    }

    /// A gradient test image with a grid and a label, `pointSize` at 2x.
    static func sampleResult(pointSize: CGSize, hue: CGFloat = 0) -> CaptureResult? {
        let scale: CGFloat = 2
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let top = NSColor(hue: (0.58 + hue).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.95, alpha: 1)
        let bottom = NSColor(hue: (0.83 + hue).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.75, alpha: 1)
        if let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        }

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        context.setLineWidth(2)
        let step = 40 * scale
        var x: CGFloat = 0
        while x < CGFloat(width) {
            context.stroke(CGRect(x: x, y: 0, width: 0, height: CGFloat(height)))
            x += step
        }
        var y: CGFloat = 0
        while y < CGFloat(height) {
            context.stroke(CGRect(x: 0, y: y, width: CGFloat(width), height: 0))
            y += step
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let label = "HakoShot sample \(Int(pointSize.width))×\(Int(pointSize.height))" as NSString
        label.draw(
            at: CGPoint(x: 32 * scale, y: 32 * scale),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 44 * scale, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return CaptureResult(image: image, pointSize: pointSize, scale: scale, mode: .area)
    }
}

extension QuickAccessController {
    /// DEBUG: force the hover controls on a card without a real pointer.
    func debugSetHovered(_ id: UUID) {
        hoverChanged(id, hovering: true)
    }
}
#endif
