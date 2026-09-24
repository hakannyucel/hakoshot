import AppKit
import CoreGraphics
import HakoKit
import Testing
@testable import HakoShot

@Suite("Editor zoom math")
struct ZoomMathTests {
    @Test func zoomStepsMoveToTheNextPreset() {
        #expect(ZoomMath.zoomIn(from: 1) == 1.25)
        #expect(ZoomMath.zoomOut(from: 1) == 0.75)
        #expect(ZoomMath.zoomIn(from: 0.6) == 0.67)
        #expect(ZoomMath.zoomOut(from: 0.6) == 0.5)
        #expect(ZoomMath.zoomIn(from: 8) == ZoomMath.maximum)
        #expect(ZoomMath.zoomOut(from: 0.1) == ZoomMath.minimum)
    }

    @Test func fitNeverExceedsActualSize() {
        #expect(ZoomMath.fit(content: CGSize(width: 400, height: 300), in: CGSize(width: 1000, height: 1000)) == 1)
        #expect(ZoomMath.fit(content: CGSize(width: 2000, height: 500), in: CGSize(width: 1000, height: 1000)) == 0.5)
        #expect(ZoomMath.fit(content: CGSize(width: 1000, height: 4000), in: CGSize(width: 1000, height: 1000)) == 0.25)
        #expect(ZoomMath.fit(content: .zero, in: CGSize(width: 10, height: 10)) == 1)
        #expect(ZoomMath.fit(content: CGSize(width: 100_000, height: 10), in: CGSize(width: 10, height: 10)) == ZoomMath.minimum)
    }

    @Test func labels() {
        #expect(ZoomMath.label(1) == "100%")
        #expect(ZoomMath.label(0.333) == "33%")
        #expect(ZoomMath.label(2) == "200%")
    }

    @Test func initialWindowFitsSmallImagesAtActualSize() {
        let geometry = CanvasGeometry(canvasSize: CGSize(width: 800, height: 600), scale: 2)
        let layout = EditorWindowSizing.initialLayout(for: geometry, visibleFrame: CGSize(width: 2560, height: 1400))
        #expect(layout.zoom == 1)
        #expect(layout.contentSize.width == EditorMetrics.minimumWindowSize.width)
        #expect(layout.contentSize.height >= geometry.viewSize.height + EditorMetrics.toolbarHeight + EditorMetrics.bottomBarHeight)
    }

    @Test func initialWindowScalesLargeImagesDown() {
        let geometry = CanvasGeometry(canvasSize: CGSize(width: 5120, height: 2880), scale: 1)
        let visible = CGSize(width: 2560, height: 1400)
        let layout = EditorWindowSizing.initialLayout(for: geometry, visibleFrame: visible)
        #expect(layout.zoom < 1)
        #expect(layout.contentSize.width <= visible.width * EditorMetrics.maximumScreenFraction + 0.5)
        #expect(layout.contentSize.height <= visible.height * EditorMetrics.maximumScreenFraction + 0.5)
    }
}

@Suite("Canvas geometry")
struct CanvasGeometryTests {
    let geometry = CanvasGeometry(canvasSize: CGSize(width: 2000, height: 1000), scale: 2, margin: 30)

    @Test func viewSizeIsPointsPlusMargins() {
        #expect(geometry.imageSize == CGSize(width: 1000, height: 500))
        #expect(geometry.viewSize == CGSize(width: 1060, height: 560))
        #expect(geometry.imageRect == CGRect(x: 30, y: 30, width: 1000, height: 500))
    }

    @Test func pointsAndRectsRoundTrip() {
        let pixel = CGPoint(x: 400, y: 250)
        let view = geometry.viewPoint(fromCanvas: pixel)
        #expect(view == CGPoint(x: 230, y: 155))
        #expect(geometry.canvasPoint(fromView: view) == pixel)
        let rect = CGRect(x: 100, y: 60, width: 40, height: 20)
        #expect(geometry.canvasRect(fromView: geometry.viewRect(fromCanvas: rect)) == rect)
        #expect(geometry.viewRect(fromCanvas: .null).isNull)
    }

    @Test func pixelsPerScreenPointFollowsZoom() {
        #expect(geometry.pixelsPerScreenPoint(magnification: 1) == 2)
        #expect(geometry.pixelsPerScreenPoint(magnification: 0.5) == 4)
    }
}

@Suite("Handle geometry")
struct HandleGeometryTests {
    @Test func handlesKeepTheirScreenSizeAtAnyZoom() {
        let at100 = HandleGeometry.handleRect(center: CGPoint(x: 50, y: 50), diameter: 10, magnification: 1)
        #expect(at100 == CGRect(x: 45, y: 45, width: 10, height: 10))
        let at200 = HandleGeometry.handleRect(center: CGPoint(x: 50, y: 50), diameter: 10, magnification: 2)
        #expect(at200.width == 5)
        #expect(at200.midX == 50 && at200.midY == 50)
    }

    @Test func shiftLocksMovesToTheDominantAxis() {
        #expect(HandleGeometry.constrainedDelta(CGVector(dx: 10, dy: 3), constrained: true) == CGVector(dx: 10, dy: 0))
        #expect(HandleGeometry.constrainedDelta(CGVector(dx: -2, dy: -9), constrained: true) == CGVector(dx: 0, dy: -9))
        #expect(HandleGeometry.constrainedDelta(CGVector(dx: 4, dy: 3), constrained: false) == CGVector(dx: 4, dy: 3))
    }

    @Test func shiftSnapsLineEndpointsTo45Degrees() {
        let line = Annotation(kind: .line(LineShape(start: .zero, end: CGPoint(x: 100, y: 0))), style: AnnotationStyle())
        let snapped = HandleGeometry.endpointTarget(CGPoint(x: 100, y: 90), handle: .end, of: line, constrained: true)
        #expect(abs(snapped.x - snapped.y) < 0.001)
        let free = HandleGeometry.endpointTarget(CGPoint(x: 100, y: 90), handle: .end, of: line, constrained: false)
        #expect(free == CGPoint(x: 100, y: 90))
    }

    @Test func chromeBoundsCoverEveryHandle() {
        let rect = Annotation(kind: .rectangle(RectShape(rect: CGRect(x: 10, y: 10, width: 100, height: 50))), style: AnnotationStyle(strokeWidth: 4))
        let chrome = HandleGeometry.chromeBounds(of: rect, pixelsPerScreenPoint: 2, handleDiameter: 10)
        for handle in rect.handles {
            guard let p = rect.position(of: handle) else {
                Issue.record("missing handle \(handle)")
                continue
            }
            #expect(chrome.insetBy(dx: 10, dy: 10).contains(p))
        }
        #expect(!HandleGeometry.drawsOutline(for: Annotation(kind: .line(LineShape(start: .zero, end: CGPoint(x: 1, y: 1))), style: AnnotationStyle())))
    }

    @Test func handleCursors() {
        #expect(HandleGeometry.cursorKind(for: .topLeft) == .frame(.topLeft))
        #expect(HandleGeometry.cursorKind(for: .right) == .frame(.right))
        #expect(HandleGeometry.cursorKind(for: .control) == .point)
    }
}
