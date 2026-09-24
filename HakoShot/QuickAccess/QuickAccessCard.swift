import AppKit
import CoreGraphics
import Foundation
import Observation

/// State of one Quick Access card, shared by `QuickAccessController` (owner) and
/// `QuickAccessCardView` (renders it).
@Observable
final class QuickAccessCard: Identifiable {
    let id = UUID()
    let result: CaptureResult
    /// Card size in points (without the panel's shadow margin).
    let size: CGSize
    /// Downscaled preview (the full capture can be 5K+; the card is ≤ 320 pt wide).
    let thumbnail: NSImage

    /// Where the capture was saved (by the card or before it was shown), if anywhere.
    var savedURL: URL?
    /// Temp PNG prepared in the background for drag and drop (`DragSource`).
    var dragFileURL: URL?
    var isHovered = false
    var isDragging = false
    /// Incremented on each copy to fire the copy flash.
    var copyFlashCount = 0

    init(result: CaptureResult, savedURL: URL?, width: CGFloat) {
        self.result = result
        self.savedURL = savedURL
        size = QuickAccessLayout.cardSize(imageSize: result.pointSize, width: width)
        let maxPixels = QuickAccessConfig.cardWidthRange.upperBound * max(result.scale, 2) * 2
        let preview = Self.downscaled(result.image, maxDimension: Int(maxPixels)) ?? result.image
        thumbnail = NSImage(cgImage: preview, size: result.pointSize)
    }

    /// Aspect-preserving downscale so the longest side is at most `maxDimension` pixels.
    nonisolated static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxDimension, maxDimension > 0 else { return image }
        let factor = CGFloat(maxDimension) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
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
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
