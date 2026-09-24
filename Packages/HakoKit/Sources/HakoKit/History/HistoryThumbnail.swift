import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO helpers for history files: downsampled previews and small JPEG
/// thumbnails, decoded without inflating the full-resolution original.
public enum HistoryThumbnail {
    /// Decodes `data` (any ImageIO format) with its longest edge ≤ `maxPixelSize`.
    /// Images already smaller are returned at their own size.
    public static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source, maxPixelSize: maxPixelSize)
    }

    public static func downsample(contentsOf url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(source, maxPixelSize: maxPixelSize)
    }

    /// JPEG thumbnail of `image`, longest edge ≤ `maxPixelSize`.
    public static func jpegThumbnail(
        of image: CGImage,
        maxPixelSize: Int = HistoryLayout.thumbnailMaxPixelSize,
        quality: CGFloat = 0.8
    ) -> Data? {
        guard let scaled = scaled(image, maxPixelSize: maxPixelSize) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Pixel size of an encoded image without decoding it.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int, dpi: Double?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        return (width, height, dpi)
    }

    // MARK: Private

    private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Redraws `image` so its longest edge is ≤ `maxPixelSize`, on an opaque
    /// dark backdrop (JPEG has no alpha; transparent window shadows would
    /// otherwise turn black at random).
    private static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let factor = min(1, Double(max(1, maxPixelSize)) / Double(longest))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
