import CoreGraphics
import CoreImage
import Foundation
import Synchronization

/// Pixel effects for `.redaction` annotations (spec: `RedactionMethod`).
///
/// Every effect takes the image content under the redaction (exactly the
/// region's pixels, produced by `DocumentRenderer`) and returns a same-size
/// image to draw over it. Nothing from outside the region is sampled.
public enum RedactionEffects {
    /// Block size of the pixelate pass that follows the secure blur.
    public static let secureBlurBlockSize = 4
    /// Maximum brightness jitter applied to each pixelated block (±6 %).
    public static let jitterAmount = 0.06

    /// Applies `shape.method` to `source` (the content under the region).
    /// `fill` is the black-out color (`style.color`).
    public static func apply(_ shape: RedactionShape, fill: RGBAColor, to source: CGImage) -> CGImage? {
        switch shape.method {
        case .pixelate:
            return pixelate(source, blockSize: max(Int(shape.strength.rounded()), 2), seed: shape.seed)
        case .secureBlur:
            guard let blurred = gaussianBlur(source, radius: shape.strength) else { return nil }
            return pixelate(blurred, blockSize: secureBlurBlockSize, seed: shape.seed)
        case .smoothBlur:
            return gaussianBlur(source, radius: shape.strength)
        case .blackOut:
            return solid(fill, width: source.width, height: source.height)
        }
    }

    // MARK: Pixelate

    /// Block-average pixelation, blocks anchored at the image's top-left.
    /// Each block's average is scaled by a deterministic `1 ± 6 %` factor
    /// derived from `seed` and the block index.
    public static func pixelate(_ image: CGImage, blockSize: Int, seed: UInt32) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, blockSize > 0,
              let context = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        // Bitmap rows are stored top row first, so block rows start at the top.
        var blockY = 0
        var by = 0
        while blockY < height {
            let y1 = min(blockY + blockSize, height)
            var blockX = 0
            var bx = 0
            while blockX < width {
                let x1 = min(blockX + blockSize, width)
                var sum = (0, 0, 0, 0)
                for y in blockY..<y1 {
                    let row = y * bytesPerRow
                    for x in blockX..<x1 {
                        let i = row + x * 4
                        sum.0 += Int(pixels[i])
                        sum.1 += Int(pixels[i + 1])
                        sum.2 += Int(pixels[i + 2])
                        sum.3 += Int(pixels[i + 3])
                    }
                }
                let count = Double((y1 - blockY) * (x1 - blockX))
                let factor = 1 + jitter(seed: seed, x: bx, y: by)
                let alpha = Double(sum.3) / count
                func channel(_ total: Int) -> UInt8 {
                    // Premultiplied: color can't exceed alpha.
                    UInt8(min(max((Double(total) / count * factor).rounded(), 0), alpha.rounded()))
                }
                let r = channel(sum.0), g = channel(sum.1), b = channel(sum.2)
                let a = UInt8(min(max(alpha.rounded(), 0), 255))
                for y in blockY..<y1 {
                    let row = y * bytesPerRow
                    for x in blockX..<x1 {
                        let i = row + x * 4
                        pixels[i] = r
                        pixels[i + 1] = g
                        pixels[i + 2] = b
                        pixels[i + 3] = a
                    }
                }
                blockX = x1
                bx += 1
            }
            blockY = y1
            by += 1
        }
        return context.makeImage()
    }

    /// Deterministic value in `-jitterAmount...jitterAmount` (SplitMix64 hash).
    static func jitter(seed: UInt32, x: Int, y: Int) -> Double {
        var z = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        z ^= UInt64(truncatingIfNeeded: x) &* 0xBF58_476D_1CE4_E5B9
        z ^= UInt64(truncatingIfNeeded: y) &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Double(z >> 11) / Double(1 << 53)
        return (unit * 2 - 1) * jitterAmount
    }

    // MARK: Blur

    /// Gaussian blur (sigma = `radius`) with the input clamped to its extent so
    /// edges don't fade to transparent.
    public static func gaussianBlur(_ image: CGImage, radius: Double) -> CGImage? {
        guard radius > 0 else { return image }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        return CIContextBox.shared.context.createCGImage(
            output, from: extent, format: .RGBA8, colorSpace: RenderSupport.sRGB
        )
    }

    // MARK: Black out

    static func solid(_ color: RGBAColor, width: Int, height: Int) -> CGImage? {
        guard let context = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// One shared CoreImage context (thread-safe per Apple docs).
private final class CIContextBox: @unchecked Sendable {
    static let shared = CIContextBox()
    let context = CIContext(options: [
        .workingColorSpace: RenderSupport.sRGB,
        .outputColorSpace: RenderSupport.sRGB,
        .cacheIntermediates: false,
    ])
}

// MARK: - Cache

/// Caches redaction effect output so redrawing the canvas (dragging other
/// objects, zooming, scrolling) doesn't recompute blurs / pixelation.
///
/// Keys contain everything the result depends on: the redaction's id, rect,
/// method, strength, seed, fill color, and the image content (layers + image
/// annotations) that overlaps the rect. So entries invalidate themselves when
/// any of that changes; there is no manual invalidation for document edits.
/// `DocumentRenderer` prunes entries for redactions that are no longer in the
/// drawn document after every draw. Call `removeAll()` only if asset pixels
/// behind an `AssetID` change (assets are immutable, so normally never) or on
/// memory pressure.
///
/// Share one cache per editor window between canvas drawing and export.
public final class RedactionCache: Sendable {
    struct Key: Hashable, Sendable {
        var redaction: Annotation.ID
        var shape: RedactionShape
        var fill: RGBAColor
        /// Image content overlapping the region.
        var layers: [ImageLayer]
        var images: [Annotation]
    }

    private let storage = Mutex<[Key: CGImage]>([:])

    public init() {}

    /// Number of cached results (for tests / diagnostics).
    public var count: Int { storage.withLock { $0.count } }

    public func removeAll() {
        storage.withLock { $0.removeAll() }
    }

    func image(for key: Key, make: () -> CGImage?) -> CGImage? {
        if let hit = storage.withLock({ $0[key] }) { return hit }
        guard let made = make() else { return nil }
        storage.withLock { $0[key] = made }
        return made
    }

    /// Drops entries whose key isn't in `keys`.
    func retain(only keys: Set<Key>) {
        storage.withLock { dict in
            for key in dict.keys where !keys.contains(key) {
                dict.removeValue(forKey: key)
            }
        }
    }
}
