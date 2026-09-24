import CoreGraphics
import Foundation

/// Tightly packed 8-bit RGBA pixels (`bytesPerRow == width × 4`), sRGB.
/// Alpha is ignored by the quantizer: video frames are opaque.
public struct RGBAPixelBuffer: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height * 4, "RGBA buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A buffer filled with one opaque color.
    public init(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) {
        var pixels = [UInt8](repeating: 255, count: max(0, width * height) * 4)
        var i = 0
        while i < pixels.count {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            i += 4
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// Draws `image` into an sRGB RGBA8 buffer (alpha channel skipped).
    public init?(cgImage image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: pixels)
    }

    /// An opaque sRGB CGImage of the buffer.
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// A palette of at most 256 opaque colors.
public struct GIFColorPalette: Sendable, Hashable {
    /// Colors as `0xRRGGBB`.
    public let colors: [UInt32]

    public init(colors: [UInt32]) {
        precondition(!colors.isEmpty && colors.count <= 256, "palette needs 1…256 colors")
        self.colors = colors.map { $0 & 0xFF_FFFF }
    }

    public var count: Int { colors.count }

    /// `r, g, b` triplets, as `CGColorSpace(indexedBaseSpace:)` and GIF
    /// color tables expect.
    public var rgbTable: [UInt8] {
        var table: [UInt8] = []
        table.reserveCapacity(colors.count * 3)
        for c in colors {
            table.append(UInt8(truncatingIfNeeded: c >> 16))
            table.append(UInt8(truncatingIfNeeded: c >> 8))
            table.append(UInt8(truncatingIfNeeded: c))
        }
        return table
    }

    /// Indexed sRGB color space over this palette.
    public func makeColorSpace() -> CGColorSpace? {
        guard let base = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let table = rgbTable
        return table.withUnsafeBufferPointer {
            CGColorSpace(indexedBaseSpace: base, last: colors.count - 1, colorTable: $0.baseAddress!)
        }
    }

    /// An 8-bit indexed CGImage (`indices.count == width × height`).
    public func makeIndexedImage(indices: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, indices.count == width * height,
              let space = makeColorSpace(),
              let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Median-cut palette builder plus nearest-color mapping with optional
/// Floyd–Steinberg dithering (plan §1.7, §4.17).
///
/// Colors are histogrammed at 6 bits per channel (262 144 bins) with exact
/// per-bin sums, so a palette color is the true mean of its pixels: a solid
/// image yields exactly one, exact color.
public enum ColorQuantizer {
    static let bits = 6
    static let binCount = 1 << (bits * 3)

    @inline(__always)
    static func binKey(_ r: Int, _ g: Int, _ b: Int) -> Int {
        ((r >> 2) << 12) | ((g >> 2) << 6) | (b >> 2)
    }

    /// Builds a global palette of at most `maxColors` (1…256) colors from
    /// `buffers`, reading every `sampleStep`-th pixel.
    public static func palette(from buffers: [RGBAPixelBuffer], maxColors: Int, sampleStep: Int = 1) -> GIFColorPalette {
        let limit = min(max(maxColors, 1), 256)
        let step = max(1, sampleStep) * 4

        var counts = [UInt32](repeating: 0, count: binCount)
        var sums = [UInt64](repeating: 0, count: binCount * 3)
        counts.withUnsafeMutableBufferPointer { counts in
            sums.withUnsafeMutableBufferPointer { sums in
                for buffer in buffers {
                    buffer.pixels.withUnsafeBufferPointer { px in
                        var i = 0
                        let n = px.count
                        while i + 2 < n {
                            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                            let key = binKey(r, g, b)
                            counts[key] &+= 1
                            sums[key * 3] &+= UInt64(r)
                            sums[key * 3 + 1] &+= UInt64(g)
                            sums[key * 3 + 2] &+= UInt64(b)
                            i += step
                        }
                    }
                }
            }
        }

        var entries: [ColorEntry] = []
        for key in 0..<binCount where counts[key] > 0 {
            let c = UInt64(counts[key])
            let sr = sums[key * 3], sg = sums[key * 3 + 1], sb = sums[key * 3 + 2]
            entries.append(ColorEntry(
                r: UInt8((sr + c / 2) / c), g: UInt8((sg + c / 2) / c), b: UInt8((sb + c / 2) / c),
                count: c, sumR: sr, sumG: sg, sumB: sb
            ))
        }
        guard !entries.isEmpty else { return GIFColorPalette(colors: [0]) }

        var boxes = [ColorBox(entries: entries, lo: 0, hi: entries.count)]
        while boxes.count < limit {
            var best = -1
            var bestScore = 0.0
            for (i, box) in boxes.enumerated() where box.hi - box.lo > 1 && box.maxRange > 0 {
                let score = Double(box.maxRange) * Double(box.count)
                if score > bestScore { bestScore = score; best = i }
            }
            guard best >= 0 else { break }
            let box = boxes[best]
            let axis = box.longestAxis
            entries[box.lo..<box.hi].sort { a, b in
                let ka = a.channel(axis), kb = b.channel(axis)
                return ka != kb ? ka < kb : a.packed < b.packed
            }
            let half = box.count / 2
            var running: UInt64 = 0
            var split = box.lo + 1
            for i in box.lo..<(box.hi - 1) {
                running += entries[i].count
                split = i + 1
                if running >= half { break }
            }
            boxes[best] = ColorBox(entries: entries, lo: box.lo, hi: split)
            boxes.append(ColorBox(entries: entries, lo: split, hi: box.hi))
        }

        let colors = boxes.map { box -> UInt32 in
            var c: UInt64 = 0, r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0
            for i in box.lo..<box.hi {
                c += entries[i].count
                r += entries[i].sumR
                g += entries[i].sumG
                b += entries[i].sumB
            }
            let rr = UInt32((r + c / 2) / c), gg = UInt32((g + c / 2) / c), bb = UInt32((b + c / 2) / c)
            return (rr << 16) | (gg << 8) | bb
        }
        var seen = Set<UInt32>()
        return GIFColorPalette(colors: colors.filter { seen.insert($0).inserted })
    }

    /// Single-image convenience.
    public static func palette(from buffer: RGBAPixelBuffer, maxColors: Int, sampleStep: Int = 1) -> GIFColorPalette {
        palette(from: [buffer], maxColors: maxColors, sampleStep: sampleStep)
    }

    /// Maps `buffer` to palette indices (see `PaletteMapper`).
    public static func indices(for buffer: RGBAPixelBuffer, palette: GIFColorPalette, dither: Double = 0) -> [UInt8] {
        var mapper = PaletteMapper(palette: palette)
        return mapper.indices(for: buffer, dither: dither)
    }

    /// Maps `buffer` and wraps the result as an 8-bit indexed CGImage.
    public static func indexedImage(for buffer: RGBAPixelBuffer, palette: GIFColorPalette, dither: Double = 0) -> CGImage? {
        palette.makeIndexedImage(
            indices: indices(for: buffer, palette: palette, dither: dither),
            width: buffer.width, height: buffer.height
        )
    }
}

/// Nearest-palette-color mapper with a lookup cache keyed by the 6-bit
/// color bin; reuse one mapper across frames that share a palette.
public struct PaletteMapper: Sendable {
    public let palette: GIFColorPalette
    /// Palette as `r, g, b` triplets, in palette order.
    private let rgb: [Int32]
    /// `(g, r, b, index)` quads sorted by green, so a lookup scans outward
    /// from the query's green and stops once ΔG alone exceeds the best.
    private let byGreen: [Int32]
    private var cache: [UInt16]

    public init(palette: GIFColorPalette) {
        self.palette = palette
        rgb = palette.colors.flatMap { [Int32(($0 >> 16) & 0xFF), Int32(($0 >> 8) & 0xFF), Int32($0 & 0xFF)] }
        let order = palette.colors.indices.sorted { a, b in
            let ga = (palette.colors[a] >> 8) & 0xFF, gb = (palette.colors[b] >> 8) & 0xFF
            return ga != gb ? ga < gb : a < b
        }
        var quads: [Int32] = []
        quads.reserveCapacity(order.count * 4)
        for i in order {
            let c = palette.colors[i]
            quads.append(Int32((c >> 8) & 0xFF))
            quads.append(Int32((c >> 16) & 0xFF))
            quads.append(Int32(c & 0xFF))
            quads.append(Int32(i))
        }
        byGreen = quads
        cache = [UInt16](repeating: .max, count: ColorQuantizer.binCount)
    }

    /// Palette index nearest to `(r, g, b)` (weighted squared distance
    /// 2·ΔR² + 4·ΔG² + 3·ΔB²), cached per 6-bit bin.
    public mutating func nearestIndex(red r: Int, green g: Int, blue b: Int) -> UInt8 {
        let byGreen = self.byGreen
        return byGreen.withUnsafeBufferPointer { sorted in
            cache.withUnsafeMutableBufferPointer { cache in
                Self.lookup(Int32(r), Int32(g), Int32(b), sorted: sorted, cache: cache)
            }
        }
    }

    /// Palette indices for every pixel, row-major. `dither` (0…1) scales
    /// the Floyd–Steinberg error (0 = plain nearest color).
    public mutating func indices(for buffer: RGBAPixelBuffer, dither: Double = 0) -> [UInt8] {
        let w = buffer.width, h = buffer.height
        var out = [UInt8](repeating: 0, count: w * h)
        guard w > 0, h > 0 else { return out }
        let strength = dither.isFinite ? min(max(dither, 0), 1) : 0
        // Errors are kept ×16 (the Floyd–Steinberg denominator); `scale`
        // is the dither strength in 1/256 steps.
        let scale = Int32((strength * 256).rounded())
        let rgb = self.rgb
        let byGreen = self.byGreen
        let errStride = (w + 2) * 3
        var errA = [Int32](repeating: 0, count: scale == 0 ? 0 : errStride)
        var errB = errA

        rgb.withUnsafeBufferPointer { palette in
        byGreen.withUnsafeBufferPointer { sorted in
        cache.withUnsafeMutableBufferPointer { cache in
        buffer.pixels.withUnsafeBufferPointer { px in
        out.withUnsafeMutableBufferPointer { out in
            if scale == 0 {
                var i = 0
                for p in 0..<(w * h) {
                    out[p] = Self.lookup(Int32(px[i]), Int32(px[i + 1]), Int32(px[i + 2]), sorted: sorted, cache: cache)
                    i += 4
                }
                return
            }
            errA.withUnsafeMutableBufferPointer { a in
            errB.withUnsafeMutableBufferPointer { b in
                var current = a, next = b
                for y in 0..<h {
                    var i = y * w * 4
                    for x in 0..<w {
                        let e = (x + 1) * 3
                        let r = Self.clampByte(Int32(px[i]) + (current[e] + 8) >> 4)
                        let g = Self.clampByte(Int32(px[i + 1]) + (current[e + 1] + 8) >> 4)
                        let bl = Self.clampByte(Int32(px[i + 2]) + (current[e + 2] + 8) >> 4)
                        let index = Self.lookup(r, g, bl, sorted: sorted, cache: cache)
                        out[y * w + x] = index
                        let k = Int(index) * 3
                        let er = ((r - palette[k]) * scale) >> 8
                        let eg = ((g - palette[k + 1]) * scale) >> 8
                        let eb = ((bl - palette[k + 2]) * scale) >> 8
                        // 7/16 right, 3/16 down-left, 5/16 down, 1/16 down-right.
                        current[e + 3] += er * 7; current[e + 4] += eg * 7; current[e + 5] += eb * 7
                        next[e - 3] += er * 3; next[e - 2] += eg * 3; next[e - 1] += eb * 3
                        next[e] += er * 5; next[e + 1] += eg * 5; next[e + 2] += eb * 5
                        next[e + 3] += er; next[e + 4] += eg; next[e + 5] += eb
                        i += 4
                    }
                    swap(&current, &next)
                    next.update(repeating: 0)
                }
            }
            }
        }
        }
        }
        }
        }
        return out
    }

    @inline(__always)
    private static func lookup(
        _ r: Int32, _ g: Int32, _ b: Int32,
        sorted: UnsafeBufferPointer<Int32>,
        cache: UnsafeMutableBufferPointer<UInt16>
    ) -> UInt8 {
        let key = ColorQuantizer.binKey(Int(r), Int(g), Int(b))
        let hit = cache[key]
        if hit != .max { return UInt8(truncatingIfNeeded: hit) }
        let n = sorted.count / 4
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid * 4] < g { lo = mid + 1 } else { hi = mid }
        }
        var best: Int32 = 0
        var bestDistance = Int32.max
        var up = lo, down = lo - 1
        while up < n || down >= 0 {
            if up < n {
                let k = up * 4
                let dg = sorted[k] - g
                if 4 * dg * dg >= bestDistance {
                    up = n
                } else {
                    let dr = sorted[k + 1] - r, db = sorted[k + 2] - b
                    let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                    if d < bestDistance { bestDistance = d; best = sorted[k + 3] }
                    up += 1
                }
            }
            if down >= 0 {
                let k = down * 4
                let dg = g - sorted[k]
                if 4 * dg * dg >= bestDistance {
                    down = -1
                } else {
                    let dr = sorted[k + 1] - r, db = sorted[k + 2] - b
                    let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                    if d < bestDistance { bestDistance = d; best = sorted[k + 3] }
                    down -= 1
                }
            }
            if bestDistance == 0 { break }
        }
        cache[key] = UInt16(best)
        return UInt8(truncatingIfNeeded: best)
    }

    @inline(__always)
    private static func clampByte(_ v: Int32) -> Int32 { min(max(v, 0), 255) }
}

// MARK: - Median-cut internals

struct ColorEntry {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var count: UInt64
    var sumR: UInt64
    var sumG: UInt64
    var sumB: UInt64

    var packed: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }

    @inline(__always)
    func channel(_ axis: Int) -> UInt8 {
        switch axis {
        case 0: r
        case 1: g
        default: b
        }
    }
}

struct ColorBox {
    var lo: Int
    var hi: Int
    var count: UInt64
    var maxRange: Int
    var longestAxis: Int

    init(entries: [ColorEntry], lo: Int, hi: Int) {
        self.lo = lo
        self.hi = hi
        var minR = 255, minG = 255, minB = 255, maxR = 0, maxG = 0, maxB = 0
        var total: UInt64 = 0
        for i in lo..<hi {
            let e = entries[i]
            let r = Int(e.r), g = Int(e.g), b = Int(e.b)
            minR = min(minR, r); maxR = max(maxR, r)
            minG = min(minG, g); maxG = max(maxG, g)
            minB = min(minB, b); maxB = max(maxB, b)
            total += e.count
        }
        count = total
        // Green weighs most in perceived difference, then blue, then red.
        let ranges = [(maxR - minR) * 2, (maxG - minG) * 4, (maxB - minB) * 3]
        var axis = 0
        for a in 1..<3 where ranges[a] > ranges[axis] { axis = a }
        longestAxis = axis
        maxRange = hi > lo ? ranges[axis] : 0
    }
}
