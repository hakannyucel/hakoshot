import CoreGraphics
import Testing
@testable import HakoKit

@Suite("WindowBackdropCompositor")
struct WindowBackdropCompositorTests {
    /// Reads RGBA bytes of `image` by redrawing it into a known-layout context
    /// (row 0 = top).
    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    static func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(data[i..<i + 4])
    }

    /// A transparent `size` image with an opaque red square of `inset` margin.
    static func windowImage(width: Int, height: Int, inset: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset))
        return context.makeImage()
    }

    @Test func solidColorAddsPaddingAndFillsTransparency() throws {
        let window = try #require(Self.windowImage(width: 20, height: 10, inset: 2))
        let result = try #require(WindowBackdropCompositor.composite(window: window, padding: 5, backdrop: .color(.white)))
        #expect(result.width == 30)
        #expect(result.height == 20)
        let data = Self.pixels(result)
        // Padding corner: white, opaque.
        #expect(Self.pixel(data, width: 30, x: 0, y: 0) == [255, 255, 255, 255])
        // Window's transparent margin (shadow area) shows the backdrop.
        #expect(Self.pixel(data, width: 30, x: 6, y: 6) == [255, 255, 255, 255])
        // Window content stays red.
        #expect(Self.pixel(data, width: 30, x: 15, y: 10) == [255, 0, 0, 255])
    }

    @Test func imageBackdropCoversCanvas() throws {
        let window = try #require(Self.windowImage(width: 10, height: 10, inset: 0))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let wallContext = try #require(CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        wallContext.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        wallContext.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let wallpaper = try #require(wallContext.makeImage())

        let result = try #require(WindowBackdropCompositor.composite(window: window, padding: 4, backdrop: .image(wallpaper)))
        #expect(result.width == 18 && result.height == 18)
        let data = Self.pixels(result)
        for (x, y) in [(0, 0), (17, 0), (0, 17), (17, 17)] {
            #expect(Self.pixel(data, width: 18, x: x, y: y) == [0, 0, 255, 255])
        }
        #expect(Self.pixel(data, width: 18, x: 9, y: 9) == [255, 0, 0, 255])
    }

    @Test func zeroPaddingKeepsSize() throws {
        let window = try #require(Self.windowImage(width: 8, height: 6, inset: 1))
        let result = try #require(WindowBackdropCompositor.composite(window: window, padding: -3, backdrop: .color(.black)))
        #expect(result.width == 8 && result.height == 6)
    }

    @Test func aspectFillCentersAndCovers() {
        let rect = WindowBackdropCompositor.aspectFillRect(
            imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(rect == CGRect(x: -50, y: 0, width: 200, height: 100))
        let tall = WindowBackdropCompositor.aspectFillRect(
            imageSize: CGSize(width: 50, height: 100), in: CGRect(x: 0, y: 0, width: 100, height: 50)
        )
        #expect(tall == CGRect(x: 0, y: -75, width: 100, height: 200))
    }
}

@Suite("WindowShadowTrim")
struct WindowShadowTrimTests {
    /// `width × height` transparent image with an opaque block covering
    /// top-left-origin rect `block`.
    static func image(width: Int, height: Int, block: CGRect?) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if let block {
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
            context.fill(CGRect(x: block.minX, y: CGFloat(height) - block.maxY, width: block.width, height: block.height))
        }
        return context.makeImage()
    }

    @Test func trimsToTopLeftAnchoredContentPlusRing() throws {
        // Content at x 1...14, y 1...6 (1 px transparent ring on left/top,
        // mirrored on right/bottom).
        let source = try #require(Self.image(width: 40, height: 30, block: CGRect(x: 1, y: 1, width: 14, height: 6)))
        #expect(WindowShadowTrim.contentSize(of: source) == CGSize(width: 16, height: 8))
        let trimmed = WindowShadowTrim.trimmed(source)
        #expect(trimmed.width == 16 && trimmed.height == 8)
    }

    @Test func noRingWhenContentStartsAtOrigin() throws {
        let source = try #require(Self.image(width: 40, height: 30, block: CGRect(x: 0, y: 2, width: 20, height: 5)))
        #expect(WindowShadowTrim.contentSize(of: source) == CGSize(width: 20, height: 9))
    }

    @Test func contentTouchingEdgesIsClamped() throws {
        let source = try #require(Self.image(width: 10, height: 10, block: CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(WindowShadowTrim.contentSize(of: source) == CGSize(width: 10, height: 10))
        #expect(WindowShadowTrim.trimmed(source).width == 10)
    }

    @Test func emptyImageIsUnchanged() throws {
        let source = try #require(Self.image(width: 12, height: 9, block: nil))
        #expect(WindowShadowTrim.contentSize(of: source) == nil)
        let trimmed = WindowShadowTrim.trimmed(source)
        #expect(trimmed.width == 12 && trimmed.height == 9)
    }
}
