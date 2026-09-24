import CoreGraphics
import Foundation
@testable import HakoKit

/// Pixel access + fixtures for renderer tests.
struct PixelBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard let context = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let count = context.bytesPerRow * height
        let rowBytes = context.bytesPerRow
        let raw = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count)
        var packed = [UInt8]()
        packed.reserveCapacity(width * height * 4)
        for y in 0..<height {
            packed.append(contentsOf: raw[(y * rowBytes)..<(y * rowBytes + width * 4)])
        }
        bytes = packed
    }

    /// RGBA (premultiplied) at `(x, y)`, top-left origin.
    func pixel(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }
}

struct RGBA: Equatable, CustomStringConvertible {
    var r, g, b, a: Int

    init(r: Int, g: Int, b: Int, a: Int = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: RGBAColor) {
        self.init(r: Int((color.red * 255).rounded()), g: Int((color.green * 255).rounded()),
                  b: Int((color.blue * 255).rounded()), a: Int((color.alpha * 255).rounded()))
    }

    func isClose(to other: RGBA, tolerance: Int = 6) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
            && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
    }

    var luminance: Double { 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) }

    var description: String { "rgba(\(r),\(g),\(b),\(a))" }

    static let white = RGBA(r: 255, g: 255, b: 255)
    static let black = RGBA(r: 0, g: 0, b: 0)
}

enum RenderFixtures {
    static let base = AssetID(rawValue: "BASE")
    static let extra = AssetID(rawValue: "EXTRA")

    /// Solid-color image.
    static func solid(_ color: RGBAColor, width: Int, height: Int) -> CGImage? {
        guard let ctx = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Deterministic "busy" image: color gradients + fine stripes, so effects
    /// visibly change it.
    static func pattern(width: Int, height: Int) -> CGImage? {
        guard let ctx = RenderSupport.makeBitmapContext(width: width, height: height),
              let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * rowBytes + x * 4
                p[i] = UInt8((x * 255) / max(width - 1, 1))
                p[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                p[i + 2] = (x / 3 + y / 5) % 2 == 0 ? 230 : 40
                p[i + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    static func document(width: Int = 400, height: Int = 300, annotations: [Annotation] = []) -> ProjectDocument {
        var doc = ProjectDocument(baseImage: base, pixelWidth: width, pixelHeight: height, scale: 2,
                                  createdAt: Date(timeIntervalSince1970: 0))
        doc.annotations = annotations
        return doc
    }

    static func renderer(base image: CGImage?, extra: CGImage? = nil, cache: RedactionCache = RedactionCache()) -> DocumentRenderer {
        let images: [AssetID: CGImage] = [base: image, RenderFixtures.extra: extra].compactMapValues { $0 }
        return DocumentRenderer(redactionCache: cache) { images[$0] }
    }

    static func whiteRenderer(width: Int = 400, height: Int = 300) -> DocumentRenderer {
        renderer(base: solid(.white, width: width, height: height))
    }

    static func render(_ doc: ProjectDocument, with renderer: DocumentRenderer) -> PixelBuffer? {
        renderer.makeImage(doc).flatMap(PixelBuffer.init)
    }

    static func noShadow(_ color: RGBAColor = .annotationRed, width: Double = 10) -> AnnotationStyle {
        AnnotationStyle(color: color, strokeWidth: width, opacity: 1, shadow: false)
    }
}
