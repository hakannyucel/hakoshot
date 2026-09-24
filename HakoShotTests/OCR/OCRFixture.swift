import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Test-only image generators for `TextRecognitionServiceTests` /
/// `QRDetectorTests` (plan §7 WP3.5): a CoreText-rendered text image and a
/// `CIQRCodeGenerator` barcode image, both real `CGImage`s Vision can run on.
enum OCRFixture {
    /// A white `width`×height `CGImage` with `lines` drawn top-to-bottom in
    /// black `Helvetica` text via CoreText — big and high-contrast enough
    /// for `RecognizeTextRequest` to read reliably.
    static func textImage(lines: [String], width: Int = 900, fontSize: CGFloat = 36) -> CGImage {
        let lineHeight = fontSize * 1.6
        let topMargin = fontSize
        let height = Int(lineHeight * CGFloat(lines.count) + topMargin)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        // CGBitmapContext's default space is already y-up (origin bottom-left),
        // matching CoreText's text space directly — no flip needed.
        var y = CGFloat(height) - topMargin
        for line in lines {
            let attributed = CFAttributedStringCreate(nil, line as CFString, attributes as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 24, y: y)
            CTLineDraw(ctLine, context)
            y -= lineHeight
        }
        return context.makeImage()!
    }

    /// A `size`×`size` QR code image encoding `payload` (plan §7 WP3.5:
    /// `CIQRCodeGenerator`).
    static func qrImage(payload: String, size: Int = 300) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = filter.outputImage!
        let scale = CGFloat(size) / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ciContext = CIContext()
        return ciContext.createCGImage(scaled, from: scaled.extent)!
    }
}
