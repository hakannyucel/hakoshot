import CoreGraphics
import Foundation
@testable import HakoKit

/// Deterministic RNG (SplitMix64) so fixtures are reproducible.
struct FixtureRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixture {
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Opaque BGRA pixel (premultiplied-first, little endian → 0xAARRGGBB).
    static func pixel(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xFF00_0000 | UInt32(clamping: r & 0xff) << 16 | UInt32(clamping: g & 0xff) << 8 | UInt32(clamping: b & 0xff)
    }

    static let background = pixel(250, 250, 248)

    struct PageOptions {
        var blankRegion: Range<Int>?
        var repeatingRegion: Range<Int>?
        var repeatPeriod = 48
    }

    /// Renders a tall synthetic "web page": paragraphs of glyph-like text rows,
    /// separators, gradient+noise images, noise blocks and blank spacing.
    static func page(width: Int, height: Int, seed: UInt64, options: PageOptions = PageOptions()) -> StitchPixels {
        var rng = FixtureRNG(seed: seed)
        var px = [UInt32](repeating: background, count: width * height)
        var y = 0
        func fillRect(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ color: (Int, Int) -> UInt32) {
            for yy in max(0, y0)..<min(height, y0 + h) {
                for xx in max(0, x0)..<min(width, x0 + w) { px[yy * width + xx] = color(xx, yy) }
            }
        }
        while y < height {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...4: // paragraph
                let lines = Int.random(in: 1...6, using: &rng)
                for _ in 0..<lines {
                    var x = 12
                    let lineEnd = width - Int.random(in: 30...200, using: &rng)
                    let ink = Int.random(in: 10...80, using: &rng)
                    while x < lineEnd {
                        let wordLength = Int.random(in: 2...9, using: &rng)
                        for _ in 0..<wordLength where x < lineEnd {
                            let glyphW = Int.random(in: 4...8, using: &rng)
                            for gy in 0..<12 {
                                for gx in 0..<glyphW where Int.random(in: 0..<3, using: &rng) == 0 {
                                    let yy = y + 3 + gy, xx = x + gx
                                    if yy < height, xx < width { px[yy * width + xx] = pixel(ink, ink, ink + 10) }
                                }
                            }
                            x += glyphW + 1
                        }
                        x += Int.random(in: 4...8, using: &rng)
                    }
                    y += 18
                }
                y += Int.random(in: 4...16, using: &rng)
            case 5: // separator
                let c = Int.random(in: 150...220, using: &rng)
                fillRect(8, y, width - 16, Int.random(in: 1...2, using: &rng)) { _, _ in pixel(c, c, c) }
                y += Int.random(in: 6...20, using: &rng)
            case 6, 7: // image: gradient + noise
                let h = Int.random(in: 40...180, using: &rng)
                let w = Int.random(in: width / 4...width - 40, using: &rng)
                let x0 = Int.random(in: 10...max(10, width - w - 10), using: &rng)
                let r0 = Int.random(in: 0...255, using: &rng), g0 = Int.random(in: 0...255, using: &rng), b0 = Int.random(in: 0...255, using: &rng)
                for yy in y..<min(height, y + h) {
                    for xx in x0..<min(width, x0 + w) {
                        let n = Int.random(in: -12...12, using: &rng)
                        px[yy * width + xx] = pixel(
                            min(255, max(0, r0 + (xx - x0) / 3 + n)),
                            min(255, max(0, g0 + (yy - y) + n)),
                            min(255, max(0, b0 - (xx - x0) / 5 + n))
                        )
                    }
                }
                y += h + Int.random(in: 6...20, using: &rng)
            case 8: // pure noise block
                let h = Int.random(in: 20...80, using: &rng)
                for yy in y..<min(height, y + h) {
                    for xx in 0..<width { px[yy * width + xx] = pixel(Int.random(in: 0...255, using: &rng), Int.random(in: 0...255, using: &rng), Int.random(in: 0...255, using: &rng)) }
                }
                y += h
            default: // blank spacing
                y += Int.random(in: 10...40, using: &rng)
            }
        }
        if let blank = options.blankRegion {
            for yy in blank.clamped(to: 0..<height) { for xx in 0..<width { px[yy * width + xx] = background } }
        }
        if let region = options.repeatingRegion {
            // One period of unique rows, then tiled.
            let period = options.repeatPeriod
            let clamped = region.clamped(to: 0..<height)
            var tile = [UInt32](repeating: background, count: width * period)
            for i in 0..<(width * period) {
                tile[i] = Int.random(in: 0..<4, using: &rng) == 0 ? pixel(Int.random(in: 0...120, using: &rng), 60, 90) : background
            }
            for yy in clamped {
                let ty = (yy - clamped.lowerBound) % period
                for xx in 0..<width { px[yy * width + xx] = tile[ty * width + xx] }
            }
        }
        return StitchPixels(width: width, height: height, pixels: px)
    }

    static func band(width: Int, height: Int, seed: UInt64, base: (Int, Int, Int)) -> StitchPixels {
        var rng = FixtureRNG(seed: seed)
        var px = [UInt32](repeating: pixel(base.0, base.1, base.2), count: width * height)
        for y in 0..<height where y % 7 < 4 {
            for x in 0..<width where Int.random(in: 0..<5, using: &rng) == 0 {
                px[y * width + x] = pixel(255, 255, 255)
            }
        }
        return StitchPixels(width: width, height: height, pixels: px)
    }

    /// Rows `range` of `source`.
    static func rows(_ source: StitchPixels, _ range: Range<Int>) -> [UInt32] {
        Array(source.pixels[(range.lowerBound * source.width)..<(range.upperBound * source.width)])
    }

    /// A viewport frame: optional sticky header/footer around page rows
    /// `[offset, offset + contentHeight)`, optional per-pixel noise.
    static func frame(page: StitchPixels, offset: Int, height: Int, header: StitchPixels? = nil, footer: StitchPixels? = nil,
                      noise: Int = 0, rng: inout FixtureRNG) -> StitchPixels {
        let content = height - (header?.height ?? 0) - (footer?.height ?? 0)
        var px: [UInt32] = []
        px.reserveCapacity(page.width * height)
        if let header { px += header.pixels }
        px += rows(page, offset..<(offset + content))
        if let footer { px += footer.pixels }
        if noise > 0 {
            for i in px.indices {
                let p = px[i]
                func ch(_ shift: UInt32) -> Int { min(255, max(0, Int((p >> shift) & 0xff) + Int.random(in: -noise...noise, using: &rng))) }
                px[i] = pixel(ch(16), ch(8), ch(0))
            }
        }
        return StitchPixels(width: page.width, height: height, pixels: px)
    }

    /// Frame offsets from 0 to exactly `last`, steps in `steps`.
    static func offsets(last: Int, steps: ClosedRange<Int>, rng: inout FixtureRNG) -> [Int] {
        var result = [0]
        var o = 0
        while o < last {
            o = min(last, o + Int.random(in: steps, using: &rng))
            result.append(o)
        }
        return result
    }

    static func image(_ p: StitchPixels) -> CGImage {
        guard let image = p.makeImage(colorSpace: sRGB) else { fatalError("fixture image") }
        return image
    }

    static func pixels(of image: CGImage) -> StitchPixels? {
        StitchPixels(image: image, colorSpace: sRGB)
    }

    /// Mean absolute per-channel difference; `.infinity` on size mismatch.
    static func meanDifference(_ a: StitchPixels, _ b: StitchPixels, ignoringTrailingColumns: Int = 0) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        var total = 0
        var n = 0
        for y in 0..<a.height {
            for x in 0..<(a.width - ignoringTrailingColumns) {
                let p = a.pixels[y * a.width + x], q = b.pixels[y * a.width + x]
                for s: UInt32 in [0, 8, 16] { total += abs(Int((p >> s) & 0xff) - Int((q >> s) & 0xff)) }
                n += 3
            }
        }
        return n == 0 ? 0 : Double(total) / Double(n)
    }
}
