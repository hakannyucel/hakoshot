import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HakoKit

/// A document using every annotation kind, laid out on an 800×600-point
/// canvas (coordinates multiplied by `scale`).
enum SampleDocument {
    static func annotations(scale k: Double) -> [Annotation] {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }
        let w = 6 * k
        func style(_ color: RGBAColor = .annotationPink, width: Double? = nil) -> AnnotationStyle {
            AnnotationStyle(color: color, strokeWidth: width ?? w, shadow: true)
        }
        var list: [Annotation] = [
            Annotation(kind: .redaction(RedactionShape(rect: r(30, 440, 120, 40), method: .pixelate, strength: 12 * k, seed: 7)),
                       style: AnnotationStyle(color: .black, shadow: false)),
            Annotation(kind: .redaction(RedactionShape(rect: r(160, 440, 120, 40), method: .secureBlur, strength: 20 * k, seed: 8)),
                       style: AnnotationStyle(color: .black, shadow: false)),
            Annotation(kind: .redaction(RedactionShape(rect: r(290, 440, 120, 40), method: .smoothBlur, strength: 20 * k, seed: 9)),
                       style: AnnotationStyle(color: .black, shadow: false)),
            Annotation(kind: .redaction(RedactionShape(rect: r(420, 440, 120, 40), method: .blackOut, strength: 0, seed: 10)),
                       style: AnnotationStyle(color: .black, shadow: false)),
            Annotation(kind: .rectangle(RectShape(rect: r(30, 30, 160, 90))), style: style()),
            Annotation(kind: .rectangle(RectShape(rect: r(210, 30, 160, 90), cornerRadius: 12 * k)), style: style(.annotationBlue)),
            Annotation(kind: .filledRectangle(RectShape(rect: r(390, 30, 120, 90), cornerRadius: 8 * k)), style: style(.annotationYellow)),
            Annotation(kind: .ellipse(RectShape(rect: r(530, 30, 160, 90))), style: style(.annotationGreen)),
            Annotation(kind: .line(LineShape(start: p(710, 30), end: p(780, 120))), style: style(.annotationOrange)),
            Annotation(kind: .pencil(PathShape(points: [p(30, 160), p(60, 140), p(90, 175), p(120, 150), p(150, 185), p(180, 155)])),
                       style: style(.annotationPurple, width: 4 * k)),
            Annotation(kind: .highlighter(PathShape(points: [p(210, 160), p(420, 162)])),
                       style: AnnotationStyle(color: .highlighterYellow, strokeWidth: 20 * k, opacity: 0.45, shadow: false)),
        ]
        for (i, arrowStyle) in ArrowStyle.allCases.enumerated() {
            let x = 440 + Double(i) * 90
            list.append(Annotation(
                kind: .arrow(ArrowShape(start: p(x, 230), end: p(x + 70, 160), arrowStyle: arrowStyle)),
                style: style(i % 2 == 0 ? .annotationPink : .annotationRed)))
        }
        for (i, textStyle) in TextStyle.allCases.enumerated() {
            let col = Double(i % 4), row = Double(i / 4)
            list.append(Annotation(
                kind: .text(TextShape(text: textStyle.rawValue.capitalized, frame: r(30 + col * 190, 260 + row * 70, 180, 40),
                                      fontSize: 24 * k, textStyle: textStyle)),
                style: style(i == 3 ? .annotationPink : (i < 3 ? .annotationRed : .annotationBlue))))
        }
        for (i, counterStyle) in CounterStyle.allCases.enumerated() {
            list.append(Annotation(
                kind: .counter(CounterShape(center: p(600 + Double(i) * 50, 350), number: i + 1, diameter: 30 * k, counterStyle: counterStyle)),
                style: style()))
        }
        list.append(Annotation(kind: .counter(CounterShape(center: p(760, 350), number: 128, diameter: 30 * k)), style: style(.annotationBlue)))
        list.append(Annotation(kind: .text(TextShape(text: "Wrapped text with emoji 👋 across a couple of lines",
                                                     frame: r(560, 390, 220, 40), fontSize: 16 * k, alignment: .center)),
                               style: style(.black)))
        list.append(Annotation(kind: .spotlight(SpotlightShape(rect: r(20, 20, 780, 480), cornerRadius: 8 * k, dimOpacity: 0.6)),
                               style: AnnotationStyle(shadow: false)))
        list.append(Annotation(kind: .spotlight(SpotlightShape(rect: r(560, 510, 220, 70), cornerRadius: 0, isEllipse: true)),
                               style: AnnotationStyle(shadow: false)))
        return list
    }

    /// A fake app screenshot (toolbar, sidebar, text lines) at `k`× scale.
    static func baseImage(scale k: Double) -> CGImage? {
        let width = Int(800 * k), height = Int(600 * k)
        guard let ctx = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        RenderSupport.flipToTopLeft(ctx, height: CGFloat(height))
        ctx.scaleBy(x: k, y: k)
        ctx.setFillColor(RGBAColor(hex: "#F5F5F7")?.cgColor ?? RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        ctx.setFillColor(RGBAColor(hex: "#E3E3E8")?.cgColor ?? RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 24))
        for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            ctx.setFillColor(RGBAColor(hex: hex)?.cgColor ?? RGBAColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: 10 + Double(i) * 18, y: 6, width: 12, height: 12))
        }
        ctx.setFillColor(RGBAColor(hex: "#1D1D1F")?.cgColor ?? RGBAColor.black.cgColor)
        var y = 40.0
        var seed = 1
        while y < 590 {
            seed = (seed * 1103 + 12345) % 9973
            let lineWidth = 200 + Double(seed % 500)
            ctx.fill(CGRect(x: 30, y: y, width: lineWidth, height: 6))
            y += 14
        }
        ctx.setFillColor(RGBAColor(hex: "#0A84FF")?.cgColor ?? RGBAColor.black.cgColor)
        ctx.fill(CGRect(x: 560, y: 500, width: 220, height: 80))
        return ctx.makeImage()
    }
}

/// Opt-in visual check: `HAKOSHOT_RENDER_SAMPLE=/path/sample.png swift test
/// --filter RenderSample` writes the sample document (2× canvas) as a PNG.
@Suite("RenderSample")
struct RenderSampleTests {
    static let outputPath = ProcessInfo.processInfo.environment["HAKOSHOT_RENDER_SAMPLE"]

    @Test(.enabled(if: outputPath != nil))
    func writeSamplePNG() throws {
        let path = try #require(Self.outputPath)
        let scale = 2.0
        let base = SampleDocument.baseImage(scale: scale)
        var doc = RenderFixtures.document(width: Int(800 * scale), height: Int(600 * scale),
                                          annotations: SampleDocument.annotations(scale: scale))
        doc.canvas.scale = scale
        let image = try #require(RenderFixtures.renderer(base: base).makeImage(doc))
        let url = URL(fileURLWithPath: path)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
