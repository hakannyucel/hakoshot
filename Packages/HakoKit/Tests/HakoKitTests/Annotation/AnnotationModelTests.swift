import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("Annotation model")
struct AnnotationModelTests {
    @Test func resizeCornerAndEdge() {
        let a = AnnotationFixtures.rect(100, 100, 100, 50)
        #expect(a.resized(handle: .topLeft, to: CGPoint(x: 50, y: 80)).bounds == CGRect(x: 50, y: 80, width: 150, height: 70))
        #expect(a.resized(handle: .bottom, to: CGPoint(x: 999, y: 300)).bounds == CGRect(x: 100, y: 100, width: 100, height: 200))
    }

    @Test func resizePastOppositeEdgeFlipsAndStaysPositive() {
        let a = AnnotationFixtures.rect(100, 100, 100, 50)
        let r = a.resized(handle: .right, to: CGPoint(x: 40, y: 0)).bounds
        #expect(r == CGRect(x: 40, y: 100, width: 60, height: 50))
        let collapsed = a.resized(handle: .right, to: CGPoint(x: 100, y: 0)).bounds
        #expect(collapsed.width == 1)
    }

    @Test func resizeKeepAspect() {
        let a = AnnotationFixtures.rect(0, 0, 200, 100)
        let r = a.resized(handle: .bottomRight, to: CGPoint(x: 400, y: 120), keepAspect: true).bounds
        #expect(r == CGRect(x: 0, y: 0, width: 400, height: 200))
        let tl = a.resized(handle: .topLeft, to: CGPoint(x: 100, y: 0), keepAspect: true).bounds
        #expect(tl == CGRect(x: 100, y: 50, width: 100, height: 50))
    }

    @Test func resizeScalesPathPoints() {
        let path = Annotation(kind: .pencil(PathShape(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)])),
                              style: AnnotationStyle())
        let r = path.resized(handle: .right, to: CGPoint(x: 40, y: 5))
        guard case .pencil(let s) = r.kind else {
            Issue.record("kind changed")
            return
        }
        #expect(s.points == [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 10), CGPoint(x: 40, y: 0)])
    }

    @Test func lineAndArrowHandles() {
        let line = Annotation(kind: .line(LineShape(start: .zero, end: CGPoint(x: 10, y: 0))), style: AnnotationStyle())
        #expect(line.handles == [.start, .end])
        let moved = line.resized(handle: .end, to: CGPoint(x: 50, y: 50))
        #expect(moved.position(of: .end) == CGPoint(x: 50, y: 50))
        #expect(moved.position(of: .start) == .zero)
        #expect(line.position(of: .topLeft) == nil)

        let straight = Annotation(kind: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0))), style: AnnotationStyle())
        #expect(straight.handles == [.start, .end])
        let curved = Annotation(kind: .arrow(ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), arrowStyle: .curved)),
                                style: AnnotationStyle())
        #expect(curved.handles == [.start, .control, .end])
        // Dragging the control handle puts the curve's midpoint under the cursor.
        let bent = curved.resized(handle: .control, to: CGPoint(x: 50, y: 40))
        #expect(bent.position(of: .control) == CGPoint(x: 50, y: 40))
        guard case .arrow(let s) = bent.kind else { return }
        #expect(s.control == CGPoint(x: 50, y: 80))
    }

    @Test func curvedArrowDefaultBend() {
        let arrow = ArrowShape(start: .zero, end: CGPoint(x: 100, y: 0), arrowStyle: .curved)
        #expect(arrow.resolvedControl == CGPoint(x: 50, y: -20))
        #expect(ArrowShape(start: .zero, end: CGPoint(x: 1, y: 0)).resolvedControl == nil)
        #expect(arrow.polyline(samples: 4).count == 5)
        #expect(ArrowShape.headLength(strokeWidth: 12) == 48)
        #expect(ArrowShape.headLength(strokeWidth: 1) == 12)
    }

    @Test func counterResizeChangesDiameter() {
        let c = AnnotationFixtures.counter(1, at: CGPoint(x: 100, y: 100))
        let r = c.resized(handle: .bottomRight, to: CGPoint(x: 150, y: 120))
        #expect(r.counter?.diameter == 100)
        #expect(r.counter?.center == CGPoint(x: 100, y: 100))
    }

    @Test func textSideHandlesChangeWidthOnly() {
        let t = Annotation(kind: .text(TextShape(text: "hi", frame: CGRect(x: 10, y: 10, width: 100, height: 40), fontSize: 30)),
                           style: AnnotationStyle())
        #expect(t.handles == [.left, .right])
        #expect(t.resized(handle: .right, to: CGPoint(x: 300, y: 999)).bounds == CGRect(x: 10, y: 10, width: 290, height: 40))
        #expect(t.resized(handle: .left, to: CGPoint(x: 0, y: 0)).bounds == CGRect(x: 0, y: 10, width: 110, height: 40))
        #expect(t.resized(handle: .bottom, to: CGPoint(x: 0, y: 500)) == t)
    }

    @Test func shapesStandardizeRects() {
        let s = RectShape(rect: CGRect(x: 100, y: 100, width: -50, height: -20))
        #expect(s.rect == CGRect(x: 50, y: 80, width: 50, height: 20))
    }

    @Test func textStyleBoxedFlags() {
        #expect(TextStyle.allCases.count == 7)
        #expect(TextStyle.allCases.filter(\.isBoxed) == [.boxed, .roundBoxed, .monospacedBoxed])
        #expect(ArrowStyle.allCases.count == 4)
        #expect(RedactionMethod.allCases.count == 4)
    }
}

@Suite("Annotation factory & tools")
struct AnnotationFactoryTests {
    let settings = ToolSettings()

    @Test func rectangleDragConstrainedToSquare() throws {
        let start = CGPoint(x: 100, y: 100)
        let a = try #require(AnnotationFactory.begin(tool: .rectangle, at: start, settings: settings, scale: 2, nextCounterNumber: 1))
        #expect(a.style.strokeWidth == 12) // 6 pt × 2
        #expect(a.style.color == .defaultAnnotation)
        let dragged = AnnotationFactory.update(a, anchor: start, to: CGPoint(x: 40, y: 130), constrained: true)
        #expect(dragged.bounds == CGRect(x: 40, y: 100, width: 60, height: 60))
        #expect(AnnotationFactory.finish(dragged) != nil)
    }

    @Test func clickWithoutDragIsDiscarded() throws {
        for tool in [AnnotationTool.rectangle, .ellipse, .line, .arrow, .redaction, .spotlight, .highlighter] {
            let a = try #require(AnnotationFactory.begin(tool: tool, at: CGPoint(x: 5, y: 5), settings: settings,
                                                         scale: 1, nextCounterNumber: 1))
            #expect(AnnotationFactory.finish(a) == nil, "\(tool)")
        }
        for tool in [AnnotationTool.counter, .text, .pencil] {
            let a = try #require(AnnotationFactory.begin(tool: tool, at: CGPoint(x: 5, y: 5), settings: settings,
                                                         scale: 1, nextCounterNumber: 1))
            #expect(AnnotationFactory.finish(a) != nil, "\(tool)")
        }
    }

    @Test func nonDrawingToolsCreateNothing() {
        for tool in AnnotationTool.allCases where !tool.createsAnnotation {
            #expect(AnnotationFactory.begin(tool: tool, at: .zero, settings: settings, scale: 1, nextCounterNumber: 1) == nil)
        }
    }

    @Test func arrowSnapsTo45Degrees() throws {
        let start = CGPoint.zero
        let a = try #require(AnnotationFactory.begin(tool: .arrow, at: start, settings: settings, scale: 1, nextCounterNumber: 1))
        let d = AnnotationFactory.update(a, anchor: start, to: CGPoint(x: 100, y: 90), constrained: true)
        guard case .arrow(let s) = d.kind else {
            Issue.record("not an arrow")
            return
        }
        #expect(abs(s.end.x - s.end.y) < 1e-9)
    }

    @Test func counterUsesNextNumberAndDiameterRule() throws {
        let c = try #require(AnnotationFactory.begin(tool: .counter, at: CGPoint(x: 1, y: 1), settings: settings,
                                                     scale: 2, nextCounterNumber: 7))
        #expect(c.counter?.number == 7)
        #expect(c.counter?.diameter == 60) // max(5 × 12, 24 × 2)
        var small = settings
        small.strokePresetIndex = 0
        let s = try #require(AnnotationFactory.begin(tool: .counter, at: .zero, settings: small, scale: 2, nextCounterNumber: 1))
        #expect(s.counter?.diameter == 48) // min 24 pt
    }

    @Test func highlighterAndRedactionDefaults() throws {
        let h = try #require(AnnotationFactory.begin(tool: .highlighter, at: .zero, settings: settings, scale: 2, nextCounterNumber: 1))
        #expect(h.style.color == .highlighterYellow)
        #expect(h.style.opacity == 0.45)
        #expect(h.style.strokeWidth == 40)
        #expect(!h.style.shadow)
        let r = try #require(AnnotationFactory.begin(tool: .redaction, at: .zero, settings: settings, scale: 2,
                                                     nextCounterNumber: 1, seed: 42))
        guard case .redaction(let shape) = r.kind else {
            Issue.record("not a redaction")
            return
        }
        #expect(shape.method == .pixelate && shape.strength == 24 && shape.seed == 42)
    }

    @Test func pencilDragIsSmoothedOnFinish() throws {
        let start = CGPoint.zero
        var a = try #require(AnnotationFactory.begin(tool: .pencil, at: start, settings: settings, scale: 1, nextCounterNumber: 1))
        for i in 1...200 {
            let jitter = i.isMultiple(of: 2) ? 0.3 : -0.3
            a = AnnotationFactory.update(a, anchor: start, to: CGPoint(x: Double(i), y: jitter), constrained: false)
        }
        #expect(a.bounds.width == 200)
        let done = try #require(AnnotationFactory.finish(a))
        guard case .pencil(let s) = done.kind else {
            Issue.record("not a pencil")
            return
        }
        #expect(s.points.count < 10)
        #expect(s.points.first == .zero)
        #expect(s.points.last?.x == 200)
    }

    @Test func toolShortcutsAreUnique() {
        let keys = AnnotationTool.allCases.map(\.shortcutKey)
        #expect(Set(keys).count == keys.count)
        #expect(AnnotationTool.tool(forShortcut: "A") == .arrow)
        #expect(AnnotationTool.tool(forShortcut: "x") == nil)
    }

    @Test func toolSettingsDecodeWithMissingKeysUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"arrowStyle":"curved"}"#.utf8))
        var expected = ToolSettings()
        expected.arrowStyle = .curved
        #expect(decoded == expected)
        var custom = ToolSettings()
        custom.shapeFill = .annotationBlue
        custom.setStrokePresetIndex(9, for: .highlighter)
        #expect(custom.highlighterPresetIndex == 5)
        custom.setStrokePresetIndex(0, for: .arrow)
        let roundTrip = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(custom))
        #expect(roundTrip == custom)
    }

    @Test func presets() {
        #expect(StrokeWidthPreset.points == [2, 4, 6, 8, 12, 20])
        #expect(StrokeWidthPreset.points(at: StrokeWidthPreset.defaultIndex) == 6)
        #expect(TextSizePreset.points(at: TextSizePreset.defaultIndex) == 30)
        #expect(StrokeWidthPreset.pixels(at: 99, scale: 2) == 40)
        #expect(RGBAColor.annotationPalette.count == 9)
    }
}

@Suite("PathSmoothing")
struct PathSmoothingTests {
    @Test func straightLineCollapsesToEndpoints() {
        let points = (0...50).map { CGPoint(x: Double($0) * 3, y: 10) }
        #expect(PathSmoothing.smooth(points) == [CGPoint(x: 0, y: 10), CGPoint(x: 150, y: 10)])
    }

    @Test func cornersSurvive() {
        let points = (0...20).map { CGPoint(x: Double($0) * 5, y: 0) } + (1...20).map { CGPoint(x: 100, y: Double($0) * 5) }
        let smoothed = PathSmoothing.smooth(points)
        #expect(smoothed.count >= 3)
        #expect(smoothed.first == .zero)
        #expect(smoothed.last == CGPoint(x: 100, y: 100))
    }

    @Test func shortInputsUntouched() {
        let two = [CGPoint.zero, CGPoint(x: 1, y: 1)]
        #expect(PathSmoothing.smooth(two) == two)
        #expect(PathSmoothing.cubicSegments([.zero]).isEmpty)
    }

    @Test func catmullRomSegmentsPassThroughPoints() {
        let pts = [CGPoint.zero, CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)]
        let segs = PathSmoothing.cubicSegments(pts)
        #expect(segs.count == 2)
        #expect(segs[0].start == pts[0] && segs[0].end == pts[1])
        #expect(segs[1].start == pts[1] && segs[1].end == pts[2])
        // Tangent at the middle point is parallel to (p2 - p0) = (20, 0).
        #expect(abs(segs[0].control2.y - 10) < 1e-9)
        #expect(abs(segs[1].control1.y - 10) < 1e-9)
    }
}
