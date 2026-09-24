import CoreGraphics

/// What goes behind a captured window (plan §4.4, Settings → Window Screenshots).
public enum WindowBackdrop: Sendable {
    case color(RGBAColor)
    /// Aspect-filled behind the window (the user's desktop wallpaper).
    case image(CGImage)
}

/// Places a window capture (with its alpha shadow) centered on a solid color
/// or a wallpaper image with `padding` on every side. Pure CoreGraphics; the
/// minimal predecessor of the editor's Background tool renderer (M5).
public enum WindowBackdropCompositor {
    /// - Parameters:
    ///   - window: the window image, transparent outside the window/shadow.
    ///   - padding: pixels added on each side (points × scale).
    /// - Returns: an opaque-looking image `window + 2 × padding` pixels in size,
    ///   or `nil` if a bitmap context couldn't be created.
    public static func composite(window: CGImage, padding: Int, backdrop: WindowBackdrop) -> CGImage? {
        let pad = max(padding, 0)
        let width = window.width + 2 * pad
        let height = window.height + 2 * pad
        let colorSpace = window.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard width > 0, height > 0, let colorSpace,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        switch backdrop {
        case let .color(color):
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
            context.fill(canvas)
        case let .image(image):
            context.draw(image, in: aspectFillRect(imageSize: CGSize(width: image.width, height: image.height), in: canvas))
        }

        // Centered; symmetric padding so bottom-left vs top-left origin doesn't matter.
        context.draw(window, in: CGRect(x: pad, y: pad, width: window.width, height: window.height))
        return context.makeImage()
    }

    /// The rect `imageSize` must be drawn in to cover `bounds` completely,
    /// centered, preserving aspect ratio.
    public static func aspectFillRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }
}
