import CoreGraphics

/// Trims a window-with-shadow capture to its natural size.
///
/// `SCShareableContent.info(for:)` reports the window frame *without* its
/// shadow, and ScreenCaptureKit squeezes the shadow into whatever output size
/// is requested. So window captures with a shadow are taken on an oversized
/// canvas with `scalesToFit = false` — content lands 1:1 at the top-left —
/// and then cut to the extent of non-transparent pixels here.
public enum WindowShadowTrim {
    /// Size (pixels) of the content anchored at the top-left of `image`.
    ///
    /// ScreenCaptureKit may leave a fully transparent ring of the shadow on
    /// the left/top edge (0–1 px); the same ring is kept on the right/bottom
    /// so the window stays centered: width = last alpha column + 1 + first
    /// alpha column (height likewise). `nil` when fully transparent.
    public static func contentSize(of image: CGImage) -> CGSize? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        return buffer.withUnsafeMutableBytes { raw -> CGSize? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Plain loops over the raw bytes: this runs on multi-megapixel
            // captures, also in unoptimized Debug builds.
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var minX = width, maxX = -1, minY = height, maxY = -1
            var y = 0
            while y < height {
                let row = pixels + y * bytesPerRow + 3
                var x = 0
                while x < width {
                    if row[x &* 4] != 0 {
                        if x < minX { minX = x }
                        if y < minY { minY = y }
                        maxY = y
                        break
                    }
                    x += 1
                }
                if x < width {
                    // Found content in this row; find its last alpha column.
                    var last = width - 1
                    while last > maxX, row[last &* 4] == 0 { last -= 1 }
                    if last > maxX { maxX = last }
                }
                y += 1
            }
            guard maxX >= 0, maxY >= 0 else { return nil }
            return CGSize(width: min(width, maxX + 1 + minX), height: min(height, maxY + 1 + minY))
        }
    }

    /// `image` cropped to `contentSize(of:)` from its top-left corner, or the
    /// image unchanged when it's empty or already tight.
    public static func trimmed(_ image: CGImage) -> CGImage {
        guard let size = contentSize(of: image),
              Int(size.width) < image.width || Int(size.height) < image.height,
              let cropped = image.cropping(to: CGRect(origin: .zero, size: size))
        else { return image }
        return cropped
    }
}
