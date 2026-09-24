import Testing
import CoreGraphics
@testable import HakoKit

@Suite("SnapshotCrop")
struct SnapshotCropTests {
    /// A second display at Quartz (1000, -200), 100×50 pt @2x → 200×100 px.
    let displayFrame = GlobalRect(x: 1000, y: -200, width: 100, height: 50)

    /// 200×100 px RGBA image whose pixel (x, y) has red = x, green = y.
    func gradientImage() throws -> CGImage {
        let width = 200, height = 100
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x)
                bytes[i + 1] = UInt8(y)
                bytes[i + 2] = 0
            }
        }
        let data = try #require(CFDataCreate(nil, bytes, bytes.count))
        let provider = try #require(CGDataProvider(data: data))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    @Test func pixelRectMapsGlobalToPixels() {
        let r = SnapshotCrop.pixelRect(
            for: GlobalRect(x: 1010, y: -190, width: 20, height: 10),
            displayFrame: displayFrame, scale: 2, imageSize: CGSize(width: 200, height: 100)
        )
        #expect(r == CGRect(x: 20, y: 20, width: 40, height: 20))
    }

    @Test func pixelRectClipsToImage() {
        let r = SnapshotCrop.pixelRect(
            for: GlobalRect(x: 990, y: -210, width: 30, height: 20),
            displayFrame: displayFrame, scale: 2, imageSize: CGSize(width: 200, height: 100)
        )
        #expect(r == CGRect(x: 0, y: 0, width: 40, height: 20))
    }

    @Test func pixelRectOutsideIsNil() {
        let r = SnapshotCrop.pixelRect(
            for: GlobalRect(x: 0, y: 0, width: 30, height: 20),
            displayFrame: displayFrame, scale: 2, imageSize: CGSize(width: 200, height: 100)
        )
        #expect(r == nil)
    }

    @Test func cropReturnsExpectedPixels() throws {
        let image = try gradientImage()
        let cropped = try #require(SnapshotCrop.crop(
            image, to: GlobalRect(x: 1025, y: -185, width: 10, height: 5), displayFrame: displayFrame, scale: 2
        ))
        #expect(cropped.width == 20 && cropped.height == 10)
        // Draw into a known context to read the top-left pixel of the crop.
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // 1×1 context: draw the crop so its top-left pixel lands on (0, 0).
        context.draw(cropped, in: CGRect(x: 0, y: 1 - cropped.height, width: cropped.width, height: cropped.height))
        #expect(pixel[0] == 50 && pixel[1] == 30)
    }

    @Test func pixelUnderPoint() {
        let p = SnapshotCrop.pixel(at: CGPoint(x: 1010.7, y: -190.2), displayFrame: displayFrame, scale: 2)
        #expect(p.x == 21 && p.y == 19)
    }

    @Test func unitSamplingRectIsCenteredOnCursorPixel() {
        let r = SnapshotCrop.unitSamplingRect(
            around: CGPoint(x: 1050, y: -175), displayFrame: displayFrame, scale: 2, count: 15,
            imageSize: CGSize(width: 200, height: 100)
        )
        // Cursor pixel (100, 50); square starts 7 px before it.
        #expect(abs(r.minX - 93.0 / 200) < 1e-9)
        #expect(abs(r.minY - 43.0 / 100) < 1e-9)
        #expect(abs(r.width - 15.0 / 200) < 1e-9)
        #expect(abs(r.height - 15.0 / 100) < 1e-9)
    }
}
