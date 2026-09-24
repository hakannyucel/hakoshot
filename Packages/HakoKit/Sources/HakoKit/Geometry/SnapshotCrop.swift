import CoreGraphics

/// Pure helpers for reading a display snapshot taken before the overlay
/// appeared (Freeze Screen, magnifier; plan §4.2, §4.3). A snapshot covers
/// `displayFrame` (Quartz global points) at `scale` pixels per point, top-left
/// origin.
public enum SnapshotCrop {
    /// `rect` (Quartz global points) in the snapshot's pixel space, rounded
    /// outward to whole pixels and clipped to the image. `nil` if nothing is left.
    public static func pixelRect(
        for rect: GlobalRect,
        displayFrame: GlobalRect,
        scale: CGFloat,
        imageSize: CGSize
    ) -> CGRect? {
        let s = max(scale, 1)
        // Round to the nearest pixel edge (selections are already pixel
        // aligned; this only removes floating-point noise).
        let minX = ((rect.minX - displayFrame.minX) * s).rounded()
        let minY = ((rect.minY - displayFrame.minY) * s).rounded()
        let maxX = ((rect.maxX - displayFrame.minX) * s).rounded()
        let maxY = ((rect.maxY - displayFrame.minY) * s).rounded()
        let pixels = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let clipped = pixels.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }

    /// `image` cropped to `rect`; `nil` if `rect` is outside the display.
    /// `CGImage.cropping(to:)` shares the pixel buffer, so this is cheap.
    public static func crop(
        _ image: CGImage,
        to rect: GlobalRect,
        displayFrame: GlobalRect,
        scale: CGFloat
    ) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let pixels = pixelRect(for: rect, displayFrame: displayFrame, scale: scale, imageSize: size) else { return nil }
        return image.cropping(to: pixels)
    }

    /// The pixel (integral, top-left origin) under `point`, which may lie
    /// outside the image near display edges.
    public static func pixel(at point: CGPoint, displayFrame: GlobalRect, scale: CGFloat) -> (x: Int, y: Int) {
        let s = max(scale, 1)
        return (
            Int(((point.x - displayFrame.minX) * s).rounded(.down)),
            Int(((point.y - displayFrame.minY) * s).rounded(.down))
        )
    }

    /// Magnifier source: a `count`×`count` pixel square centered on the pixel
    /// under `point` (`count` odd), as a unit-space rect for
    /// `CALayer.contentsRect` over an image of `imageSize`. With a flipped
    /// layer geometry (`contentsRect` origin at the image's top-left) the
    /// y-axis matches pixel rows; otherwise flip `y`. The rect may extend past
    /// 0…1 near display edges.
    public static func unitSamplingRect(
        around point: CGPoint,
        displayFrame: GlobalRect,
        scale: CGFloat,
        count: Int,
        imageSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let center = pixel(at: point, displayFrame: displayFrame, scale: scale)
        let half = count / 2
        let x = CGFloat(center.x - half)
        let y = CGFloat(center.y - half)
        return CGRect(
            x: x / imageSize.width,
            y: y / imageSize.height,
            width: CGFloat(count) / imageSize.width,
            height: CGFloat(count) / imageSize.height
        )
    }
}
