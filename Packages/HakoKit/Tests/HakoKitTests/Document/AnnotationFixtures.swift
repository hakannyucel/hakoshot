import CoreGraphics
import Foundation
@testable import HakoKit

/// Shared builders for annotation / document tests.
enum AnnotationFixtures {
    static let baseAsset = AssetID(rawValue: "7F3A0C2E-0000-4000-8000-000000000001")
    static let extraAsset = AssetID(rawValue: "7F3A0C2E-0000-4000-8000-000000000002")

    static func emptyDocument() -> ProjectDocument {
        ProjectDocument(
            baseImage: baseAsset, pixelWidth: 2000, pixelHeight: 1200, scale: 2,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, width: Double = 12) -> Annotation {
        Annotation(kind: .rectangle(RectShape(rect: CGRect(x: x, y: y, width: w, height: h))),
                   style: AnnotationStyle(strokeWidth: width))
    }

    static func counter(_ number: Int, at point: CGPoint = CGPoint(x: 100, y: 100)) -> Annotation {
        Annotation(kind: .counter(CounterShape(center: point, number: number, diameter: 60)),
                   style: AnnotationStyle())
    }

    /// One annotation of every kind (and every arrow / text / redaction variant).
    static func everyKind() -> [Annotation] {
        let style = AnnotationStyle(color: .annotationBlue, strokeWidth: 8, opacity: 0.9, shadow: true,
                                    fill: RGBAColor(hex: "#FFCC0080"))
        var result: [Annotation] = [
            Annotation(kind: .rectangle(RectShape(rect: CGRect(x: 10, y: 20, width: 300, height: 200), cornerRadius: 8)),
                       style: style),
            Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 400, y: 20, width: 100, height: 50))),
                       style: AnnotationStyle(color: .annotationRed)),
            Annotation(kind: .ellipse(RectShape(rect: CGRect(x: 50, y: 300, width: 200, height: 100))),
                       style: style),
            Annotation(kind: .line(LineShape(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 50))),
                       style: AnnotationStyle()),
            Annotation(kind: .pencil(PathShape(points: [CGPoint(x: 1, y: 2), CGPoint(x: 3.5, y: 4.25), CGPoint(x: 9, y: 1)])),
                       style: AnnotationStyle()),
            Annotation(kind: .highlighter(PathShape(points: [CGPoint(x: 100, y: 500), CGPoint(x: 600, y: 500)])),
                       style: AnnotationStyle(color: .highlighterYellow, strokeWidth: 40, opacity: 0.45, shadow: false)),
            counter(3, at: CGPoint(x: 800, y: 800)),
            Annotation(kind: .spotlight(SpotlightShape(rect: CGRect(x: 900, y: 100, width: 300, height: 300),
                                                       cornerRadius: 16, dimOpacity: 0.6, isEllipse: true)),
                       style: AnnotationStyle(shadow: false)),
            Annotation(kind: .image(ImageShape(assetID: extraAsset, frame: CGRect(x: 1000, y: 600, width: 400, height: 300))),
                       style: AnnotationStyle()),
        ]
        for (i, arrowStyle) in ArrowStyle.allCases.enumerated() {
            let control: CGPoint? = arrowStyle == .curved ? CGPoint(x: 150, y: 20 + Double(i)) : nil
            result.append(Annotation(
                kind: .arrow(ArrowShape(start: CGPoint(x: 10, y: 600 + Double(i) * 40),
                                        end: CGPoint(x: 300, y: 620 + Double(i) * 40),
                                        control: control, arrowStyle: arrowStyle)),
                style: AnnotationStyle()))
        }
        for (i, textStyle) in TextStyle.allCases.enumerated() {
            result.append(Annotation(
                kind: .text(TextShape(text: "Hello 👋 \(i)\nline two",
                                      frame: CGRect(x: 1200, y: Double(i) * 80, width: 500, height: 70),
                                      fontSize: 60, textStyle: textStyle,
                                      alignment: TextAlignmentMode.allCases[i % 3])),
                style: AnnotationStyle(color: .annotationGreen)))
        }
        for (i, method) in RedactionMethod.allCases.enumerated() {
            result.append(Annotation(
                kind: .redaction(RedactionShape(rect: CGRect(x: Double(i) * 110, y: 1000, width: 100, height: 40),
                                                method: method, strength: 24, seed: UInt32(1000 + i))),
                style: AnnotationStyle(color: .black, shadow: false)))
        }
        return result
    }

    static func fullDocument() -> ProjectDocument {
        var doc = emptyDocument()
        doc.annotations = everyKind()
        doc.crop = CGRect(x: 10, y: 10, width: 1800, height: 1000)
        doc.transform = CanvasTransform(rotationQuarterTurns: 1, flipHorizontal: true)
        doc.background = BackgroundStyle(
            fill: .gradient(GradientSpec(colors: [.annotationPink, .annotationBlue], angle: 45)),
            padding: 48, alignment: .bottom, aspectRatio: .sixteenNine
        )
        doc.source = CaptureSourceInfo(mode: "area", capturedAt: Date(timeIntervalSince1970: 1_790_000_000), displayScale: 2)
        return doc
    }
}
