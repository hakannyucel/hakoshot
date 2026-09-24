import Foundation
import Testing
@testable import HakoShot

/// Runs real Vision barcode detection against `CIQRCodeGenerator` fixtures
/// (plan §7 WP3.5).
@Suite("QRDetector")
struct QRDetectorTests {
    @Test("decodes a QR payload and flags it as a URL")
    func decodesURLPayload() async throws {
        let payload = "https://hakoshot.app/ocr-test"
        let image = OCRFixture.qrImage(payload: payload)

        let result = try await QRDetector.detectFirst(in: image)
        let unwrapped = try #require(result)

        #expect(unwrapped.payload == payload)
        #expect(unwrapped.url?.absoluteString == payload)
    }

    @Test("decodes a non-URL QR payload without a URL")
    func decodesNonURLPayload() async throws {
        let payload = "HAKOSHOT-TEST-1234"
        let image = OCRFixture.qrImage(payload: payload)

        let result = try await QRDetector.detectFirst(in: image)
        let unwrapped = try #require(result)

        #expect(unwrapped.payload == payload)
        #expect(unwrapped.url == nil)
    }

    @Test("an image with no barcode returns nil")
    func returnsNilWhenNoBarcode() async throws {
        let plain = OCRFixture.textImage(lines: ["no barcode here"])
        let result = try await QRDetector.detectFirst(in: plain)
        #expect(result == nil)
    }
}
