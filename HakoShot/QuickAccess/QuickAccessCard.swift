import AppKit
import CoreGraphics
import Foundation
import Observation

/// State of one Quick Access card, shared by `QuickAccessController` (owner) and
/// `QuickAccessCardView` (renders it).
@Observable
final class QuickAccessCard: Identifiable {
    let id = UUID()
    /// Screenshot or recording (plan §4.15).
    let item: QuickAccessItem
    /// Card size in points (without the panel's shadow margin).
    let size: CGSize
    /// Downscaled preview (the full capture can be 5K+; the card is ≤ 320 pt wide).
    let thumbnail: NSImage
    /// Hover / context-menu controls this card offers (videos: no Pin / Annotate;
    /// GIF and Edit only once the R3 handlers exist).
    let controls: QuickAccessCardControls

    /// Where the capture was saved (by the card or before it was shown), if anywhere.
    var savedURL: URL?
    /// Temp file prepared in the background for drag and drop / copy (`DragSource`):
    /// a PNG for screenshots, a template-named link to the recording for videos.
    var dragFileURL: URL?
    var isHovered = false
    var isDragging = false
    /// Incremented on each copy to fire the copy flash.
    var copyFlashCount = 0
    /// Convert to GIF running for this card (0…1); `nil` = none (R3).
    var conversionProgress: Double?

    /// The screenshot (image cards). Video cards: `nil`.
    var result: CaptureResult? { item.capture }
    /// The recording (video / GIF cards). Image cards: `nil`.
    var recording: RecordingResult? { item.recording }

    /// Duration badge text (`m:ss`), video cards only.
    var durationText: String? {
        recording.map { QuickAccessDurationFormat.string(seconds: $0.duration) }
    }

    convenience init(result: CaptureResult, savedURL: URL?, width: CGFloat) {
        self.init(item: .image(result), savedURL: savedURL, width: width)
    }

    init(
        item: QuickAccessItem,
        savedURL: URL?,
        width: CGFloat,
        controls: QuickAccessCardControls? = nil
    ) {
        self.item = item
        self.savedURL = savedURL
        self.controls = controls ?? QuickAccessCardControls(item: item)
        size = QuickAccessLayout.cardSize(imageSize: item.contentSize, width: width)
        switch item {
        case .image(let result):
            let maxPixels = QuickAccessConfig.cardWidthRange.upperBound * max(result.scale, 2) * 2
            let preview = Self.downscaled(result.image, maxDimension: Int(maxPixels)) ?? result.image
            thumbnail = NSImage(cgImage: preview, size: result.pointSize)
        case .video(let recording):
            let maxPixels = QuickAccessConfig.cardWidthRange.upperBound * 2 * 2
            let preview = Self.downscaled(recording.thumbnail, maxDimension: Int(maxPixels)) ?? recording.thumbnail
            let aspectSize = item.contentSize.width > 0 && item.contentSize.height > 0
                ? item.contentSize
                : CGSize(width: preview.width, height: preview.height)
            thumbnail = NSImage(cgImage: preview, size: aspectSize)
        }
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
