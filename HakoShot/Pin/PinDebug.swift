#if DEBUG
import AppKit
import CoreGraphics
import os

/// DEBUG helpers to exercise pins without a screen capture. Wiring (menu item /
/// launch argument) is in the WP2.3 report's "Entegrasyon parçası".
enum PinDebug {
    /// Launch argument: pin one sample image at launch.
    static let launchArgument = "-HakoPinDebug"

    /// Pins a generated 480×300 pt @2x test card centered on the active display.
    @discardableResult
    static func pinSample(controller: PinController = .shared) -> PinPanel? {
        guard let image = sampleImage(pointSize: CGSize(width: 480, height: 300), scale: 2) else {
            Log.pin.error("debug: could not render sample image")
            return nil
        }
        return controller.pin(image, pointSize: CGSize(width: 480, height: 300))
    }

    /// Call from `applicationDidFinishLaunching`; does nothing without `launchArgument`.
    static func pinFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }
        pinSample()
    }

    /// Gradient + 1 px checker strip + label, so Retina sharpness and scaling are easy to judge.
    static func sampleImage(pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let colors = [
            CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1),
            CGColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: width, y: height), options: []
            )
        }

        // 1 px checker strip along the bottom: blurry if the pin isn't pixel-exact.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let strip = Int(24 * scale)
        for x in stride(from: 0, to: width, by: 2) {
            for y in stride(from: (x / 2) % 2, to: strip, by: 2) {
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let text = NSAttributedString(string: "HakoShot Pin\n\(Int(pointSize.width))×\(Int(pointSize.height)) pt @\(Int(scale))x", attributes: [
            .font: NSFont.systemFont(ofSize: 34 * scale, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        text.draw(at: CGPoint(x: 32 * scale, y: CGFloat(height) / 2 - 20 * scale))
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }
}
#endif
