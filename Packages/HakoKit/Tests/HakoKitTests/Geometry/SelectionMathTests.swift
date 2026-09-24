import Testing
import CoreGraphics
@testable import HakoKit

@Suite("SelectionMath")
struct SelectionMathTests {
    /// A display at Quartz (100, 50), 800×600 — non-zero origin to catch
    /// accidental use of local coordinates.
    let bounds = GlobalRect(x: 100, y: 50, width: 800, height: 600)

    // MARK: rect(anchor:current:)

    @Test func plainDragDownRight() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 200, y: 100), current: CGPoint(x: 300, y: 250), bounds: bounds)
        #expect(r == GlobalRect(x: 200, y: 100, width: 100, height: 150))
    }

    @Test func plainDragUpLeftIsStandardized() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 300, y: 250), current: CGPoint(x: 200, y: 100), bounds: bounds)
        #expect(r == GlobalRect(x: 200, y: 100, width: 100, height: 150))
    }

    @Test func plainDragIsClampedToBounds() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 800, y: 600), current: CGPoint(x: 5000, y: -5000), bounds: bounds)
        #expect(r == GlobalRect(x: 800, y: 50, width: 100, height: 550))
    }

    @Test func anchorOutsideBoundsIsClampedFirst() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 0, y: 0), current: CGPoint(x: 150, y: 80), bounds: bounds)
        #expect(r == GlobalRect(x: 100, y: 50, width: 50, height: 30))
    }

    @Test func squareUsesLongerSideAndKeepsDirection() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 500, y: 400), current: CGPoint(x: 450, y: 380), constraints: .square, bounds: bounds)
        #expect(r == GlobalRect(x: 450, y: 350, width: 50, height: 50))
    }

    @Test func squareShrinksAtEdgeInsteadOfBeingCut() {
        // Only 50 pt of room to the right; square must stay square.
        let r = SelectionMath.rect(anchor: CGPoint(x: 850, y: 100), current: CGPoint(x: 1000, y: 400), constraints: .square, bounds: bounds)
        #expect(r.width == r.height)
        #expect(r == GlobalRect(x: 850, y: 100, width: 50, height: 50))
    }

    @Test func fromCenterIsSymmetric() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 500, y: 300), current: CGPoint(x: 540, y: 320), constraints: .fromCenter, bounds: bounds)
        #expect(r == GlobalRect(x: 460, y: 280, width: 80, height: 40))
        #expect(r.midX == 500 && r.midY == 300)
    }

    @Test func fromCenterLimitedByNearerEdge() {
        // 20 pt to the left edge, so half-width caps at 20 even when dragging right.
        let r = SelectionMath.rect(anchor: CGPoint(x: 120, y: 300), current: CGPoint(x: 300, y: 310), constraints: .fromCenter, bounds: bounds)
        #expect(r == GlobalRect(x: 100, y: 290, width: 40, height: 20))
    }

    @Test func fromCenterSquare() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 500, y: 300), current: CGPoint(x: 510, y: 330), constraints: [.fromCenter, .square], bounds: bounds)
        #expect(r == GlobalRect(x: 470, y: 270, width: 60, height: 60))
    }

    @Test func fromCenterSquareLimitedByEdge() {
        let r = SelectionMath.rect(anchor: CGPoint(x: 500, y: 60), current: CGPoint(x: 600, y: 200), constraints: [.fromCenter, .square], bounds: bounds)
        #expect(r == GlobalRect(x: 490, y: 50, width: 20, height: 20))
    }

    @Test func negativeOriginDisplay() {
        // Display left of / above main: negative Quartz coordinates.
        let left = GlobalRect(x: -1920, y: -200, width: 1920, height: 1080)
        let r = SelectionMath.rect(anchor: CGPoint(x: -100, y: -150), current: CGPoint(x: 50, y: -300), bounds: left)
        #expect(r == GlobalRect(x: -100, y: -200, width: 100, height: 50))
    }

    // MARK: Drag threshold

    @Test func clickVersusDrag() {
        let start = CGPoint(x: 10, y: 10)
        #expect(!SelectionMath.isDrag(from: start, to: CGPoint(x: 11, y: 11)))
        #expect(SelectionMath.isDrag(from: start, to: CGPoint(x: 10, y: 10 + SelectionMath.minimumDragDistance)))
    }

    // MARK: Nudge

    @Test(arguments: [
        (NudgeDirection.left, false, CGPoint(x: 199, y: 100)),
        (NudgeDirection.right, false, CGPoint(x: 201, y: 100)),
        (NudgeDirection.up, false, CGPoint(x: 200, y: 99)),
        (NudgeDirection.down, false, CGPoint(x: 200, y: 101)),
        (NudgeDirection.left, true, CGPoint(x: 190, y: 100)),
        (NudgeDirection.down, true, CGPoint(x: 200, y: 110)),
    ])
    func nudgeSteps(direction: NudgeDirection, large: Bool, expected: CGPoint) {
        #expect(SelectionMath.nudge(CGPoint(x: 200, y: 100), direction, large: large) == expected)
    }

    @Test func nudgeClampsIntoBounds() {
        let p = SelectionMath.nudge(CGPoint(x: 105, y: 52), .left, large: true, within: bounds)
        #expect(p == CGPoint(x: 100, y: 52))
        let q = SelectionMath.nudge(CGPoint(x: 895, y: 648), .down, large: true, within: bounds)
        #expect(q == CGPoint(x: 895, y: 650))
    }

    // MARK: Space-move

    @Test func translationUnclampedInside() {
        let rect = GlobalRect(x: 200, y: 200, width: 100, height: 100)
        let d = SelectionMath.clampedTranslation(of: rect, by: CGVector(dx: 30, dy: -40), within: bounds)
        #expect(d == CGVector(dx: 30, dy: -40))
    }

    @Test func translationStopsAtEdges() {
        let rect = GlobalRect(x: 780, y: 60, width: 100, height: 100)
        let d = SelectionMath.clampedTranslation(of: rect, by: CGVector(dx: 50, dy: -50), within: bounds)
        #expect(d == CGVector(dx: 20, dy: -10))
    }

    @Test func translationOfOversizedRectDoesNotMove() {
        let rect = GlobalRect(x: 100, y: 50, width: 800, height: 600)
        let d = SelectionMath.clampedTranslation(of: rect, by: CGVector(dx: 5, dy: 5), within: bounds)
        #expect(d == CGVector(dx: 0, dy: 0))
    }

    // MARK: Pixel alignment

    @Test func pixelAlignOnRetinaKeepsHalfPoints() {
        let r = GlobalRect(x: 200.3, y: 100.74, width: 50.2, height: 20)
        let a = SelectionMath.pixelAligned(r, scale: 2, within: bounds)
        #expect(a == GlobalRect(x: 200.5, y: 100.5, width: 50, height: 20))
    }

    @Test func pixelAlignOnNonRetinaRoundsToWholePoints() {
        let r = GlobalRect(x: 200.4, y: 100.6, width: 10.2, height: 10.2)
        let a = SelectionMath.pixelAligned(r, scale: 1, within: bounds)
        #expect(a == GlobalRect(x: 200, y: 101, width: 11, height: 10))
    }

    @Test func pixelAlignStaysInsideBounds() {
        let r = GlobalRect(x: 99.9, y: 49.9, width: 800.3, height: 600.3)
        #expect(SelectionMath.pixelAligned(r, scale: 2, within: bounds) == bounds)
    }

    @Test func capturableNeedsOnePixelPerAxis() {
        #expect(SelectionMath.isCapturable(GlobalRect(x: 0, y: 0, width: 0.5, height: 0.5), scale: 2))
        #expect(!SelectionMath.isCapturable(GlobalRect(x: 0, y: 0, width: 0.5, height: 10), scale: 1))
        #expect(!SelectionMath.isCapturable(GlobalRect(x: 0, y: 0, width: 10, height: 0), scale: 2))
    }
}
