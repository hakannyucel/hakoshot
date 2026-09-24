import CoreGraphics
import Foundation

/// Row-major 32-bit pixels in the layout ScreenCaptureKit produces
/// (BGRA in memory: premultiplied-first alpha, 32-bit little endian).
struct StitchPixels: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt32]

    static let bitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(width: Int, height: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Renders `image` 1:1 into 32-bit pixels. When `colorSpace` equals the
    /// image's own color space no color conversion happens, so the result is
    /// pixel-exact.
    init?(image: CGImage, colorSpace: CGColorSpace) {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt32](repeating: 0, count: w * h)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: colorSpace, bitmapInfo: Self.bitmapInfo
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    /// Working color space for a captured frame: its own RGB space when it has
    /// one (keeps pixels exact), otherwise sRGB.
    static func workingColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Swaps x and y, so a horizontal scroll becomes a vertical one.
    func transposed() -> StitchPixels {
        let w = width
        let h = height
        var out = [UInt32](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                // Blocked transpose for cache friendliness.
                let block = 32
                var by = 0
                while by < h {
                    let yEnd = min(by + block, h)
                    var bx = 0
                    while bx < w {
                        let xEnd = min(bx + block, w)
                        for y in by..<yEnd {
                            let row = y * w
                            for x in bx..<xEnd {
                                dst[x * h + y] = src[row + x]
                            }
                        }
                        bx += block
                    }
                    by += block
                }
            }
        }
        return StitchPixels(width: h, height: w, pixels: out)
    }

    func makeImage(colorSpace: CGColorSpace) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Per-row signatures of one frame (rows along the scroll axis).
struct LineSignatures: Sendable {
    static let binCount = 32

    let count: Int
    /// 64-bit hash of each row, excluding the trailing scroll-bar strip.
    let hashes: [UInt64]
    /// `count * binCount` mean luminance values (0...255) of 32 equal cells per row.
    let descriptors: [Float]
    /// Rows whose hash is very frequent in the frame (blank background etc.).
    /// They carry no position information.
    let common: [Bool]

    init(pixels: StitchPixels, trailingExclusion: Int) {
        let w = pixels.width
        let h = pixels.height
        let excluded = max(0, min(trailingExclusion, w / 4))
        let effectiveWidth = max(1, w - excluded)
        let bins = min(Self.binCount, effectiveWidth)
        let stride = Self.binCount

        var binOf = [Int](repeating: 0, count: effectiveWidth)
        var binSize = [Float](repeating: 0, count: stride)
        for x in 0..<effectiveWidth {
            let b = x * bins / effectiveWidth
            binOf[x] = b
            binSize[b] += 1
        }
        var scale = [Float](repeating: 0, count: stride)
        for b in 0..<stride where binSize[b] > 0 {
            scale[b] = 1 / (256 * binSize[b])
        }

        var hashes = [UInt64](repeating: 0, count: h)
        var descriptors = [Float](repeating: 0, count: h * stride)
        var sums = [UInt32](repeating: 0, count: stride)

        pixels.pixels.withUnsafeBufferPointer { px in
            binOf.withUnsafeBufferPointer { binOf in
                sums.withUnsafeMutableBufferPointer { sums in
                    hashes.withUnsafeMutableBufferPointer { hashes in
                        descriptors.withUnsafeMutableBufferPointer { desc in
                            for y in 0..<h {
                                let row = y * w
                                var hv: UInt64 = 0xcbf2_9ce4_8422_2325
                                for x in 0..<effectiveWidth {
                                    let p = px[row + x]
                                    hv = (hv ^ UInt64(p)) &* 0x0000_0100_0000_01b3
                                    let lum = ((p >> 16) & 0xff) &* 77 &+ ((p >> 8) & 0xff) &* 150 &+ (p & 0xff) &* 29
                                    sums[binOf[x]] &+= lum
                                }
                                // Final avalanche so neighbouring rows spread well.
                                hv ^= hv >> 33
                                hv = hv &* 0xff51_afd7_ed55_8ccd
                                hv ^= hv >> 33
                                hashes[y] = hv
                                let base = y * stride
                                for b in 0..<stride {
                                    desc[base + b] = Float(sums[b]) * scale[b]
                                    sums[b] = 0
                                }
                            }
                        }
                    }
                }
            }
        }

        var frequency: [UInt64: Int] = [:]
        frequency.reserveCapacity(h)
        for value in hashes { frequency[value, default: 0] += 1 }
        let limit = max(3, h / 8)
        self.common = hashes.map { (frequency[$0] ?? 0) > limit }
        self.count = h
        self.hashes = hashes
        self.descriptors = descriptors
    }
}

/// A frame in canonical orientation (scroll axis = y) with its signatures.
struct StitchFrame: Sendable {
    let pixels: StitchPixels
    let signatures: LineSignatures

    init(pixels: StitchPixels, scrollBarInset: Int) {
        self.pixels = pixels
        self.signatures = LineSignatures(pixels: pixels, trailingExclusion: scrollBarInset)
    }
}
