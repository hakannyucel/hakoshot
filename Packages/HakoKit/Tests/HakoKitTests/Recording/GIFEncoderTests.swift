import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HakoKit

@Suite("ColorQuantizer")
struct ColorQuantizerTests {
    /// Pseudo-random noise plus a gradient: many more than 256 colors.
    static func busyBuffer(width: Int = 160, height: Int = 90, seed: UInt32 = 1) -> RGBAPixelBuffer {
        var state = seed
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 1_664_525 &+ 1_013_904_223
                let i = (y * width + x) * 4
                px[i] = UInt8(truncatingIfNeeded: x * 255 / max(1, width - 1))
                px[i + 1] = UInt8(truncatingIfNeeded: y * 255 / max(1, height - 1))
                px[i + 2] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return RGBAPixelBuffer(width: width, height: height, pixels: px)
    }

    @Test func solidImageGivesOneExactColor() {
        let buffer = RGBAPixelBuffer(width: 64, height: 32, red: 13, green: 200, blue: 77)
        let palette = ColorQuantizer.palette(from: buffer, maxColors: 256)
        #expect(palette.count == 1)
        #expect(palette.colors == [0x0D_C84D])
        let indices = ColorQuantizer.indices(for: buffer, palette: palette, dither: 0.8)
        #expect(Set(indices) == [0])
    }

    @Test func fewColorsAreKeptExactly() {
        var buffer = RGBAPixelBuffer(width: 10, height: 10, red: 255, green: 0, blue: 0)
        for i in 0..<50 { // top half blue-ish, one close neighbour of red
            buffer.pixels[i * 4] = 0
            buffer.pixels[i * 4 + 2] = 255
        }
        buffer.pixels[99 * 4] = 250 // (250, 0, 0)
        let palette = ColorQuantizer.palette(from: buffer, maxColors: 256)
        #expect(Set(palette.colors) == [0xFF_0000, 0x00_00FF, 0xFA_0000])
        let indices = ColorQuantizer.indices(for: buffer, palette: palette)
        #expect(palette.colors[Int(indices[0])] == 0x00_00FF)
        #expect(palette.colors[Int(indices[60])] == 0xFF_0000)
        #expect(palette.colors[Int(indices[99])] == 0xFA_0000)
    }

    @Test(arguments: [256, 255, 128, 64, 2, 1])
    func paletteRespectsLimit(maxColors: Int) {
        let buffer = Self.busyBuffer()
        let palette = ColorQuantizer.palette(from: buffer, maxColors: maxColors)
        #expect(palette.count <= maxColors)
        #expect(palette.count <= 256)
        #expect(palette.count >= min(maxColors, 2) - 1)
        #expect(Set(palette.colors).count == palette.count)
        for dither in [0.0, 0.8] {
            let indices = ColorQuantizer.indices(for: buffer, palette: palette, dither: dither)
            #expect(indices.count == buffer.width * buffer.height)
            #expect(indices.allSatisfy { Int($0) < palette.count })
        }
    }

    @Test func busyImageUsesManyColorsAndLowError() {
        let buffer = Self.busyBuffer()
        let palette = ColorQuantizer.palette(from: buffer, maxColors: 255)
        #expect(palette.count > 200)
        let indices = ColorQuantizer.indices(for: buffer, palette: palette)
        var error = 0.0
        for p in 0..<indices.count {
            let c = palette.colors[Int(indices[p])]
            let dr = Double(Int(c >> 16) - Int(buffer.pixels[p * 4]))
            let dg = Double(Int((c >> 8) & 0xFF) - Int(buffer.pixels[p * 4 + 1]))
            let db = Double(Int(c & 0xFF) - Int(buffer.pixels[p * 4 + 2]))
            error += (dr * dr + dg * dg + db * db).squareRoot()
        }
        #expect(error / Double(indices.count) < 40)
    }

    @Test func globalPaletteFromSeveralFrames() {
        let red = RGBAPixelBuffer(width: 8, height: 8, red: 255, green: 0, blue: 0)
        let green = RGBAPixelBuffer(width: 8, height: 8, red: 0, green: 255, blue: 0)
        let palette = ColorQuantizer.palette(from: [red, green], maxColors: 64, sampleStep: 3)
        #expect(Set(palette.colors) == [0xFF_0000, 0x00_FF00])
    }

    @Test func indexedImageRoundTrip() throws {
        let buffer = RGBAPixelBuffer(width: 4, height: 2, red: 1, green: 2, blue: 3)
        let palette = ColorQuantizer.palette(from: buffer, maxColors: 16)
        let image = try #require(ColorQuantizer.indexedImage(for: buffer, palette: palette))
        #expect(image.bitsPerPixel == 8)
        #expect(image.colorSpace?.model == .indexed)
        let back = try #require(RGBAPixelBuffer(cgImage: image))
        #expect(back == buffer)
    }

    /// Screen-like 800×450 frame: flat panels, a gradient bar, and
    /// anti-aliased "text" stripes.
    static func screenLikeBuffer(width: Int = 800, height: Int = 450) -> RGBAPixelBuffer {
        var buffer = RGBAPixelBuffer(width: width, height: height, red: 246, green: 246, blue: 248)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if y < 40 { // title bar gradient
                    buffer.pixels[i] = UInt8(40 + x * 120 / width)
                    buffer.pixels[i + 1] = UInt8(90 + y * 3)
                    buffer.pixels[i + 2] = 200
                } else if x < 180 { // sidebar
                    buffer.pixels[i] = 228; buffer.pixels[i + 1] = 230; buffer.pixels[i + 2] = 235
                } else if y % 18 < 10, (x / 7) % 9 != 0 { // text rows with AA edges
                    let v = UInt8(30 + (x % 7) * 25)
                    buffer.pixels[i] = v; buffer.pixels[i + 1] = v; buffer.pixels[i + 2] = v
                }
            }
        }
        return buffer
    }

    @Test func screenFrameAt800px() {
        // 800 px GIF width (plan §5). No timing assertion (shared, loaded CI
        // machines); release build: noise worst case ≈ 0.13 s for palette +
        // map, screen content much less.
        let buffer = Self.screenLikeBuffer()
        let palette = ColorQuantizer.palette(from: buffer, maxColors: 217, sampleStep: 2)
        #expect(palette.count <= 217)
        var mapper = PaletteMapper(palette: palette)
        let indices = mapper.indices(for: buffer, dither: 0.64)
        #expect(indices.count == 800 * 450)
        #expect(indices.allSatisfy { Int($0) < palette.count })
        // Flat background maps to its exact color (no dither noise on flat areas).
        #expect(palette.colors[Int(indices[449 * 800 + 799])] == 0xF6_F6F8)
    }
}

@Suite("GIFEncoder")
struct GIFEncoderTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hakokit-gif-\(UUID().uuidString).gif")
    }

    private struct Decoded {
        var count: Int
        var loopCount: Int?
        var delays: [Int]
        var frames: [RGBAPixelBuffer]
    }

    private func decode(_ url: URL) throws -> Decoded {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = fileProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        var delays: [Int] = []
        var frames: [RGBAPixelBuffer] = []
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let frameGIF = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? -1
            delays.append(Int((delay * 100).rounded()))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, i, nil))
            frames.append(try #require(RGBAPixelBuffer(cgImage: image)))
        }
        return Decoded(count: count, loopCount: gif?[kCGImagePropertyGIFLoopCount] as? Int, delays: delays, frames: frames)
    }

    @Test func encodeDecodeWithGlobalPalette() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        let buffers = colors.map { RGBAPixelBuffer(width: 40, height: 20, red: $0.0, green: $0.1, blue: $0.2) }
        let quantization = GIFQuantization.forOptions(.default, sampleFrames: buffers)
        guard case let .palette(palette, _) = quantization else {
            Issue.record("expected a global palette")
            return
        }
        #expect(palette.count == 3)

        let sampler = GIFFrameSampler(fps: 15, duration: 0.2)
        #expect(sampler.delays == [7, 7, 6])
        let encoder = try GIFEncoder(url: url, loopCount: 0, quantization: quantization)
        for (buffer, delay) in zip(buffers, sampler.delays) {
            try encoder.add(frame: try #require(buffer.makeCGImage()), delayCentiseconds: delay)
        }
        #expect(encoder.frameCount == 3)
        #expect(encoder.totalDelayCentiseconds == 20)
        try encoder.finalize()

        let decoded = try decode(url)
        #expect(decoded.count == 3)
        #expect(decoded.loopCount == 0)
        #expect(decoded.delays == [7, 7, 6])
        #expect(decoded.frames == buffers) // indexed frames are written losslessly
    }

    @Test func fullPaletteIsLossless() throws {
        // 255 distinct colors survive exactly (ImageIO reserves index 255).
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var px = [UInt8](repeating: 255, count: 255 * 4)
        for i in 0..<255 {
            px[i * 4] = UInt8(i)
            px[i * 4 + 1] = UInt8((i * 7) & 255)
            px[i * 4 + 2] = UInt8((i * 13) & 255)
        }
        let buffer = RGBAPixelBuffer(width: 255, height: 1, pixels: px)
        let palette = ColorQuantizer.palette(from: buffer, maxColors: 255)
        #expect(palette.count == 255)
        let encoder = try GIFEncoder(url: url, quantization: .palette(palette, dither: 0))
        try encoder.add(buffer: buffer, delayCentiseconds: 10)
        try encoder.finalize()
        let decoded = try decode(url)
        #expect(decoded.frames == [buffer])
    }

    @Test func imageIOAndPerFrameModes() throws {
        for quantization in [GIFQuantization.imageIO, .perFrame(maxColors: 256, dither: 0.5)] {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let encoder = try GIFEncoder(url: url, loopCount: 3, quantization: quantization)
            try encoder.add(buffer: ColorQuantizerTests.busyBuffer(), delayCentiseconds: 5)
            try encoder.add(buffer: RGBAPixelBuffer(width: 160, height: 90, red: 9, green: 9, blue: 9), delayCentiseconds: 0)
            try encoder.finalize()
            let decoded = try decode(url)
            #expect(decoded.count == 2)
            #expect(decoded.loopCount == 3)
            #expect(decoded.delays == [5, 1]) // delay clamped to ≥ 1 cs
            #expect(decoded.frames[0].width == 160)
            #expect(decoded.frames[1] == RGBAPixelBuffer(width: 160, height: 90, red: 9, green: 9, blue: 9))
        }
    }

    @Test func errors() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = GIFColorPalette(colors: (0..<256).map { UInt32($0) })
        #expect(throws: GIFEncoderError.paletteTooLarge(256)) {
            try GIFEncoder(url: url, quantization: .palette(big, dither: 0))
        }
        let empty = try GIFEncoder(url: url)
        #expect(throws: GIFEncoderError.noFrames) { try empty.finalize() }
        #expect(throws: GIFEncoderError.alreadyFinalized) {
            try empty.add(buffer: RGBAPixelBuffer(width: 1, height: 1, red: 0, green: 0, blue: 0), delayCentiseconds: 5)
        }
        let discarded = try GIFEncoder(url: url)
        try discarded.add(buffer: RGBAPixelBuffer(width: 2, height: 2, red: 1, green: 1, blue: 1), delayCentiseconds: 5)
        discarded.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: GIFEncoderError.alreadyFinalized) { try discarded.finalize() }
    }

    @Test func noQuantizationWithoutSamples() {
        #expect(GIFQuantization.forOptions(.default, sampleFrames: []) == .imageIO)
    }
}
