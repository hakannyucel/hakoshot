import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("HitTesting")
struct HitTestingTests {
    private func hit(_ a: Annotation, _ x: Double, _ y: Double, ppp: Double = 1) -> Bool {
        HitTesting.hits(CGPoint(x: x, y: y), annotation: a, pixelsPerPoint: ppp)
    }

    @Test func toleranceIsStrokeAware() {
        #expect(HitTesting.tolerance(for: AnnotationFixtures.rect(0, 0, 1, 1, width: 2), pixelsPerPoint: 1) == 4)
        #expect(HitTesting.tolerance(for: AnnotationFixtures.rect(0, 0, 1, 1, width: 2), pixelsPerPoint: 2) == 8)
        #expect(HitTesting.tolerance(for: AnnotationFixtures.rect(0, 0, 1, 1, width: 40), pixelsPerPoint: 1) == 20)
    }

    @Test func outlineRectangleHitsBorderOnly() {
        let r = AnnotationFixtures.rect(100, 100, 200, 100, width: 4) // tol = 4
        #expect(hit(r, 100, 150))
        #expect(hit(r, 97, 150))
        #expect(hit(r, 304, 200))
        #expect(!hit(r, 200, 150)) // hollow interior
        #expect(!hit(r, 90, 150))
        var filled = r
        filled.style.fill = .white
        #expect(hit(filled, 200, 150))
    }

    @Test func filledRectangleHitsInterior() {
        let r = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 0, y: 0, width: 50, height: 50))),
                           style: AnnotationStyle(strokeWidth: 2))
        #expect(hit(r, 25, 25))
        #expect(hit(r, 53, 25))
        #expect(!hit(r, 60, 25))
    }

    @Test func ellipseHitsNearOutline() {
        let e = Annotation(kind: .ellipse(RectShape(rect: CGRect(x: 0, y: 0, width: 200, height: 100))),
                           style: AnnotationStyle(strokeWidth: 4))
        #expect(hit(e, 100, 0))
        #expect(hit(e, 202, 50))
        #expect(!hit(e, 100, 50)) // center of hollow ellipse
        #expect(!hit(e, 5, 5)) // bounding-box corner, far from the curve
        var filled = e
        filled.style.fill = .white
        #expect(hit(filled, 100, 50))
        #expect(!hit(filled, 5, 5))
    }

    @Test func lineUsesSegmentDistance() {
        let l = Annotation(kind: .line(LineShape(start: .zero, end: CGPoint(x: 100, y: 100))), style: AnnotationStyle(strokeWidth: 20))
        #expect(hit(l, 50, 50))
        #expect(hit(l, 57, 43)) // ~9.9 px off the line, within 10
        #expect(!hit(l, 60, 40)) // ~14 px
        #expect(!hit(l, 120, 120)) // beyond the end cap tolerance
        let thin = Annotation(kind: .line(LineShape(start: .zero, end: CGPoint(x: 100, y: 0))), style: AnnotationStyle(strokeWidth: 1))
        #expect(hit(thin, 50, 3))
        #expect(!hit(thin, 50, 6))
        #expect(hit(thin, 50, 6, ppp: 2)) // zoomed out / retina: 8 px slop
    }

    @Test func arrowHitsShaftAndHead() {
        let a = Annotation(kind: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 200, y: 0))), style: AnnotationStyle(strokeWidth: 4))
        #expect(hit(a, 100, 3))
        #expect(!hit(a, 100, 10))
        #expect(hit(a, 190, 10)) // inside head radius (16)
        #expect(!hit(a, 0, 10)) // tail has no head
        var double = a
        double.kind = .arrow(ArrowShape(start: .zero, end: CGPoint(x: 200, y: 0), arrowStyle: .doubleHeaded))
        #expect(hit(double, 5, 10))
    }

    @Test func curvedArrowFollowsCurve() {
        let a = Annotation(kind: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 200, y: 0),
                                                   control: CGPoint(x: 100, y: 200), arrowStyle: .curved)),
                           style: AnnotationStyle(strokeWidth: 4))
        #expect(hit(a, 100, 100)) // apex of the quadratic: B(0.5) = (100, 100)
        #expect(!hit(a, 100, 2)) // the straight chord is empty
    }

    @Test func pencilAndHighlighterUsePolyline() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)]
        let p = Annotation(kind: .pencil(PathShape(points: pts)), style: AnnotationStyle(strokeWidth: 6))
        #expect(hit(p, 25, 3))
        #expect(hit(p, 52, 25))
        #expect(!hit(p, 25, 25))
        let h = Annotation(kind: .highlighter(PathShape(points: pts)), style: AnnotationStyle(strokeWidth: 40))
        #expect(hit(h, 25, 18))
        let dot = Annotation(kind: .pencil(PathShape(points: [CGPoint(x: 10, y: 10)])), style: AnnotationStyle(strokeWidth: 6))
        #expect(hit(dot, 12, 12))
        #expect(!hit(dot, 20, 20))
    }

    @Test func counterHitsCircle() {
        let c = AnnotationFixtures.counter(1, at: CGPoint(x: 100, y: 100)) // diameter 60, stroke 12 → tol 6
        #expect(hit(c, 100, 100))
        #expect(hit(c, 135, 100))
        #expect(!hit(c, 140, 100))
    }

    @Test func areaKindsHitInside() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 40)
        let kinds: [Annotation.Kind] = [
            .text(TextShape(text: "x", frame: rect, fontSize: 20)),
            .redaction(RedactionShape(rect: rect, strength: 10, seed: 0)),
            .spotlight(SpotlightShape(rect: rect, cornerRadius: 0)),
            .image(ImageShape(assetID: AnnotationFixtures.extraAsset, frame: rect)),
        ]
        for kind in kinds {
            let a = Annotation(kind: kind, style: AnnotationStyle(strokeWidth: 2))
            #expect(hit(a, 60, 30), "\(kind.tag)")
            #expect(hit(a, 7, 30), "\(kind.tag)")
            #expect(!hit(a, 60, 80), "\(kind.tag)")
        }
    }

    @Test func topmostWinsInZOrder() {
        let bottom = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 0, y: 0, width: 100, height: 100))),
                                style: AnnotationStyle())
        let top = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 50, y: 50, width: 100, height: 100))),
                             style: AnnotationStyle())
        let list = [bottom, top]
        #expect(HitTesting.topmostAnnotation(at: CGPoint(x: 75, y: 75), in: list) == top.id)
        #expect(HitTesting.topmostAnnotation(at: CGPoint(x: 25, y: 25), in: list) == bottom.id)
        #expect(HitTesting.topmostAnnotation(at: CGPoint(x: 500, y: 500), in: list) == nil)
        // After reordering, the other one wins.
        let reordered = EditorReducer.reordered(list, ids: [bottom.id], operation: .bringToFront)
        #expect(HitTesting.topmostAnnotation(at: CGPoint(x: 75, y: 75), in: reordered) == bottom.id)
    }

    @Test func handleHitTesting() {
        let r = AnnotationFixtures.rect(100, 100, 200, 100)
        #expect(HitTesting.handle(at: CGPoint(x: 302, y: 203), of: r) == .bottomRight)
        #expect(HitTesting.handle(at: CGPoint(x: 200, y: 99), of: r) == .top)
        #expect(HitTesting.handle(at: CGPoint(x: 200, y: 150), of: r) == nil)
        #expect(HitTesting.handle(at: CGPoint(x: 308, y: 207), of: r, pixelsPerPoint: 2) == .bottomRight)
        #expect(HitTesting.handle(at: CGPoint(x: 308, y: 207), of: r) == nil)

        let arrow = Annotation(kind: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), arrowStyle: .curved)),
                               style: AnnotationStyle())
        // Control handle sits on the curve's midpoint: (50, -10) for the default bend.
        #expect(HitTesting.handle(at: CGPoint(x: 50, y: -10), of: arrow) == .control)
        #expect(HitTesting.handle(at: CGPoint(x: 99, y: 1), of: arrow) == .end)
    }

    @Test func marqueeSelection() {
        let a = AnnotationFixtures.rect(0, 0, 10, 10)
        let b = AnnotationFixtures.rect(100, 100, 10, 10)
        #expect(HitTesting.annotations(intersecting: CGRect(x: 50, y: 50, width: 100, height: 100), in: [a, b]) == [b.id])
        #expect(HitTesting.annotations(intersecting: CGRect(x: 200, y: 200, width: -250, height: -250), in: [a, b]) == [a.id, b.id])
    }
}
