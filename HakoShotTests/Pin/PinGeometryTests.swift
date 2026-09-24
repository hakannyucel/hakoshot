import CoreGraphics
import Testing
@testable import HakoShot

@Suite("PinGeometry")
struct PinGeometryTests {
    private let base = CGSize(width: 400, height: 200)

    @Test func opacityIsClamped() {
        #expect(PinGeometry.clampOpacity(0.02) == 0.1)
        #expect(PinGeometry.clampOpacity(1.4) == 1)
        #expect(PinGeometry.clampOpacity(0.55) == 0.55)
    }

    @Test func zoomIsClampedWithMinimumSide() {
        #expect(PinGeometry.clampZoom(10, baseSize: base) == PinGeometry.maxZoom)
        // Short side 200 pt: 32 / 200 = 0.16 beats minZoom 0.1.
        #expect(PinGeometry.clampZoom(0.01, baseSize: base) == 0.16)
        // Tiny image: never forced below 100 %.
        #expect(PinGeometry.minimumZoom(for: CGSize(width: 20, height: 10)) == 1)
    }

    @Test func zoomKeepsAnchorFixed() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
        let anchor = CGPoint(x: 200, y: 150) // 25 % across, 25 % up
        let zoomed = PinGeometry.zoomedFrame(frame, baseSize: base, zoom: 2, anchor: anchor)
        #expect(zoomed.size == CGSize(width: 800, height: 400))
        #expect(zoomed.minX + zoomed.width * 0.25 == anchor.x)
        #expect(zoomed.minY + zoomed.height * 0.25 == anchor.y)
    }

    @Test func rightEdgeResizeKeepsAspectAndTopLeft() {
        let start = CGRect(x: 0, y: 0, width: 400, height: 200)
        let result = PinGeometry.resizedFrame(start: start, edge: .right, translation: CGSize(width: 200, height: 0), baseSize: base)
        #expect(result.size == CGSize(width: 600, height: 300))
        #expect(result.minX == 0)
        #expect(result.maxY == start.maxY)
    }

    @Test func bottomLeftCornerResizeKeepsTopRight() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 200)
        // Drag down-left: larger proportional change wins (x: +100 width vs y: +50 height = +100 width).
        let result = PinGeometry.resizedFrame(start: start, edge: .bottomLeft, translation: CGSize(width: -100, height: -20), baseSize: base)
        #expect(result.size == CGSize(width: 500, height: 250))
        #expect(result.maxX == start.maxX)
        #expect(result.maxY == start.maxY)
    }

    @Test func topEdgeResizeKeepsBottomLeft() {
        let start = CGRect(x: 0, y: 0, width: 400, height: 200)
        let result = PinGeometry.resizedFrame(start: start, edge: .top, translation: CGSize(width: 0, height: -100), baseSize: base)
        #expect(result.size == CGSize(width: 200, height: 100))
        #expect(result.origin == .zero)
    }

    @Test func resizeRespectsMinimum() {
        let start = CGRect(x: 0, y: 0, width: 400, height: 200)
        let result = PinGeometry.resizedFrame(start: start, edge: .right, translation: CGSize(width: -1000, height: 0), baseSize: base)
        #expect(result.height == 32)
        #expect(result.width == 64)
    }

    @Test func edgeHitTesting() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(PinGeometry.edge(at: CGPoint(x: 150, y: 100), in: bounds, band: 6) == nil)
        #expect(PinGeometry.edge(at: CGPoint(x: 2, y: 100), in: bounds, band: 6) == .left)
        #expect(PinGeometry.edge(at: CGPoint(x: 150, y: 198), in: bounds, band: 6) == .top)
        #expect(PinGeometry.edge(at: CGPoint(x: 298, y: 2), in: bounds, band: 6) == .bottomRight)
        #expect(PinGeometry.edge(at: CGPoint(x: 10, y: 197), in: bounds, band: 6) == .topLeft)
        #expect(PinGeometry.edge(at: CGPoint(x: 400, y: 100), in: bounds, band: 6) == nil)
    }

    @Test func nudgeSteps() {
        let origin = CGPoint(x: 10, y: 10)
        #expect(PinGeometry.nudged(origin, .left, largeStep: false) == CGPoint(x: 9, y: 10))
        #expect(PinGeometry.nudged(origin, .up, largeStep: true) == CGPoint(x: 10, y: 20))
        #expect(PinGeometry.nudged(origin, .down, largeStep: false) == CGPoint(x: 10, y: 9))
    }

    @Test func centeredFrameFitsAndNeverUpscales() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let small = PinGeometry.centeredFrame(pointSize: CGSize(width: 200, height: 100), in: visible)
        #expect(small == CGRect(x: 400, y: 350, width: 200, height: 100))
        let big = PinGeometry.centeredFrame(pointSize: CGSize(width: 2000, height: 1000), in: visible)
        #expect(big.width == 900)
        #expect(big.height == 450)
        #expect(big.midX == visible.midX)
    }

    @Test func percentText() {
        #expect(PinGeometry.percentText(1) == "100%")
        #expect(PinGeometry.percentText(0.704) == "70%")
    }
}
