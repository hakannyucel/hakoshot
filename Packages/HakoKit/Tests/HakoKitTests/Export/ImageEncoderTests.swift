import Testing
import CoreGraphics
import Foundation
@testable import HakoKit

@Suite("ImageFormat")
struct ImageFormatTests {
    @Test func pngJpegHeicAreAlwaysSupportedOnMacOS() {
        // ImageIO on every supported macOS version can write these three;
        // only WebP support is uncertain (plan §1.6), so it's checked at
        // runtime rather than assumed here.
        #expect(ImageFormat.png.isSupported)
        #expect(ImageFormat.jpeg.isSupported)
        #expect(ImageFormat.heic.isSupported)
    }

    @Test func allFormatsAreEncodableRegardlessOfImageIOWriteSupport() {
        // `.webp` may or may not be `isSupported` (ImageIO's own write path)
        // depending on the OS, but `ImageEncoder` always has a working path
        // for it (WP7.3's libwebp fallback), so `isEncodable` must be true
        // for every case — this is what UI format pickers should filter on.
        for format in ImageFormat.allCases {
            #expect(format.isEncodable)
        }
    }

    @Test func fileExtensions() {
        #expect(ImageFormat.png.fileExtension == "png")
        #expect(ImageFormat.jpeg.fileExtension == "jpg")
        #expect(ImageFormat.heic.fileExtension == "heic")
        #expect(ImageFormat.webp.fileExtension == "webp")
    }
}

@Suite("ImageEncoder")
struct ImageEncoderTests {
    /// A synthetic 8×6 RGBA image: opaque red on the left half, fully
    /// transparent on the right half, so PNG alpha round-tripping is
    /// actually exercised.
    static func makeTestImage(width: Int = 8, height: Int = 6) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    @Test func encodeDecodePNGPreservesSizeAndAlpha() throws {
        let image = Self.makeTestImage()
        let data = try ImageEncoder.encode(image, format: .png, options: .defaults(for: .png, scale: 1))
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
        #expect(decoded.alphaInfo != .none)
    }

    @Test func encodeDecodeJPEGPreservesSize() throws {
        let image = Self.makeTestImage()
        let data = try ImageEncoder.encode(image, format: .jpeg, options: .defaults(for: .jpeg, scale: 2))
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
    }

    @Test func encodeDecodeHEICPreservesSize() throws {
        let image = Self.makeTestImage()
        let data = try ImageEncoder.encode(image, format: .heic, options: .defaults(for: .heic, scale: 1))
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
    }

    @Test func dpiMetadataReflectsScale() throws {
        let image = Self.makeTestImage()
        let data = try ImageEncoder.encode(image, format: .png, options: .defaults(for: .png, scale: 2))
        let dpi = try #require(ImageEncoder.dpi(of: data))
        #expect(dpi == 144)
    }

    @Test func dpiMetadataAt1xScale() throws {
        let image = Self.makeTestImage()
        let data = try ImageEncoder.encode(image, format: .png, options: .defaults(for: .png, scale: 1))
        let dpi = try #require(ImageEncoder.dpi(of: data))
        #expect(dpi == 72)
    }

    @Test func defaultQualitiesMatchPlan() {
        #expect(ImageEncodeOptions.defaults(for: .jpeg, scale: 1).compressionQuality == 0.85)
        #expect(ImageEncodeOptions.defaults(for: .heic, scale: 1).compressionQuality == 0.80)
        #expect(ImageEncodeOptions.defaults(for: .webp, scale: 1).compressionQuality == 0.85)
    }

    /// WebP always encodes successfully now (WP7.3): via ImageIO when this
    /// OS's `CGImageDestinationCopyTypeIdentifiers()` includes it, otherwise
    /// via the `libwebp`-based `WebPEncoder` fallback — `ImageEncoder` picks
    /// the path transparently, so `.encode(format: .webp, …)` never throws
    /// `unsupportedFormat` regardless of which path this machine takes.
    @Test func encodeDecodeWebPPreservesSizeAndAlpha() throws {
        let image = Self.makeTestImage()
        let data = try ImageEncoder.encode(image, format: .webp, options: .defaults(for: .webp, scale: 2))
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
        // Lossy WebP still has to preserve the fully-transparent half:
        // sample the decoded alpha channel directly rather than trust
        // `alphaInfo`, since decode may report a premultiplied variant.
        let alphaBytes = try #require(Self.alphaChannel(of: decoded))
        let rightHalfStart = decoded.width / 2
        for y in 0..<decoded.height {
            for x in rightHalfStart..<decoded.width {
                #expect(alphaBytes[y * decoded.width + x] == 0)
            }
        }
    }

    /// Exercises the `libwebp` fallback directly, independent of whether
    /// this machine's ImageIO happens to support writing WebP.
    @Test func webPEncoderFallbackRoundTrips() throws {
        let image = Self.makeTestImage()
        let data = try WebPEncoder.encode(image, quality: 0.85)
        #expect(data.starts(with: "RIFF".utf8))
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
    }

    /// Reads back a straight (non-premultiplied) 8-bit alpha channel,
    /// regardless of the decoded image's own alpha layout.
    private static func alphaChannel(of image: CGImage) -> [UInt8]? {
        var alpha = [UInt8](repeating: 0, count: image.width * image.height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = alpha.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return alpha
    }
}
