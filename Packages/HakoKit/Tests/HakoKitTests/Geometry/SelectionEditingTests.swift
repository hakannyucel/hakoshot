import Testing
import CoreGraphics
@testable import HakoKit

@Suite("SelectionEditing")
struct SelectionEditingTests {
    let bounds = GlobalRect(x: 0, y: 0, width: 1000, height: 800)
    let rect = GlobalRect(x: 100, y: 100, width: 200, height: 100)

    @Test func handleHitTesting() {
        #expect(SelectionEditing.handle(at: CGPoint(x: 102, y: 97), of: rect) == .topLeft)
        #expect(SelectionEditing.handle(at: CGPoint(x: 300, y: 200), of: rect) == .bottomRight)
        #expect(SelectionEditing.handle(at: CGPoint(x: 150, y: 101), of: rect) == .top)
        #expect(SelectionEditing.handle(at: CGPoint(x: 299, y: 150), of: rect) == .right)
        #expect(SelectionEditing.handle(at: CGPoint(x: 200, y: 150), of: rect) == nil)
        #expect(SelectionEditing.handle(at: CGPoint(x: 500, y: 500), of: rect) == nil)
    }

    @Test func handlePoints() {
        #expect(SelectionHandle.top.point(on: rect) == CGPoint(x: 200, y: 100))
        #expect(SelectionHandle.bottomLeft.point(on: rect) == CGPoint(x: 100, y: 200))
    }

    @Test func resizeCornerMovesTwoEdges() {
        let r = SelectionEditing.resize(rect, handle: .bottomRight, to: CGPoint(x: 350, y: 260), bounds: bounds)
        #expect(r == GlobalRect(x: 100, y: 100, width: 250, height: 160))
    }

    @Test func resizeEdgeMovesOneEdge() {
        let r = SelectionEditing.resize(rect, handle: .left, to: CGPoint(x: 50, y: 999), bounds: bounds)
        #expect(r == GlobalRect(x: 50, y: 100, width: 250, height: 100))
    }

    @Test func resizeCannotCrossOppositeEdge() {
        let r = SelectionEditing.resize(rect, handle: .right, to: CGPoint(x: 20, y: 150), bounds: bounds)
        #expect(r.minX == 100 && r.width == SelectionEditing.minimumSize)
    }

    @Test func resizeIsClampedToBounds() {
        let r = SelectionEditing.resize(rect, handle: .topLeft, to: CGPoint(x: -50, y: -50), bounds: bounds)
        #expect(r == GlobalRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func resizeCornerKeepsRatio() {
        let r = SelectionEditing.resize(rect, handle: .bottomRight, to: CGPoint(x: 500, y: 210), ratio: 2, bounds: bounds)
        #expect(r == GlobalRect(x: 100, y: 100, width: 400, height: 200))
    }

    @Test func resizeEdgeKeepsRatioAroundCenter() {
        let r = SelectionEditing.resize(rect, handle: .right, to: CGPoint(x: 500, y: 150), ratio: 2, bounds: bounds)
        #expect(r == GlobalRect(x: 100, y: 50, width: 400, height: 200))
    }

    @Test func ratioDrag() {
        let r = SelectionEditing.rect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 260, y: 130), ratio: 16.0 / 9.0, bounds: bounds)
        #expect(r.width == 160 && abs(r.height - 90) < 0.0001)
        let up = SelectionEditing.rect(anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 90, y: 0), ratio: 1, bounds: bounds)
        #expect(up == GlobalRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func ratioDragFitsBounds() {
        let r = SelectionEditing.rect(anchor: CGPoint(x: 900, y: 100), current: CGPoint(x: 2000, y: 150), ratio: 2, bounds: bounds)
        #expect(r == GlobalRect(x: 900, y: 100, width: 100, height: 50))
    }

    @Test func resizedToSizeStaysInBounds() {
        let r = SelectionEditing.resized(GlobalRect(x: 700, y: 500, width: 10, height: 10), to: CGSize(width: 800, height: 600), within: bounds)
        #expect(r == GlobalRect(x: 200, y: 200, width: 800, height: 600))
        let huge = SelectionEditing.resized(rect, to: CGSize(width: 5000, height: 5000), within: bounds)
        #expect(huge == bounds)
    }

    @Test func nudgeMove() {
        #expect(SelectionEditing.nudged(rect, .right, kind: .move, large: false, within: bounds).minX == 101)
        #expect(SelectionEditing.nudged(rect, .up, kind: .move, large: true, within: bounds).minY == 90)
        let edge = GlobalRect(x: 0, y: 0, width: 10, height: 10)
        #expect(SelectionEditing.nudged(edge, .left, kind: .move, large: true, within: bounds) == edge)
    }

    @Test func nudgeGrowAndShrink() {
        let grown = SelectionEditing.nudged(rect, .right, kind: .grow, large: true, within: bounds)
        #expect(grown == GlobalRect(x: 100, y: 100, width: 210, height: 100))
        let taller = SelectionEditing.nudged(rect, .down, kind: .grow, large: false, within: bounds)
        #expect(taller.height == 101 && taller.minY == 100)
        let shrunk = SelectionEditing.nudged(rect, .left, kind: .shrink, large: false, within: bounds)
        #expect(shrunk.width == 199)
        let atEdge = SelectionEditing.nudged(GlobalRect(x: 990, y: 0, width: 10, height: 10), .right, kind: .grow, large: true, within: bounds)
        #expect(atEdge.width == 10)
    }
}
