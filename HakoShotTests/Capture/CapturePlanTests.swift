import CoreGraphics
import HakoKit
import Testing
@testable import HakoShot

@Suite("CapturePlan")
struct CapturePlanTests {
    /// Retina main 1440×900 @2x, plus a 1920×1080 @1x display to its right,
    /// bottom-aligned (AppKit y = 0), so its Quartz top is at y = -180.
    private let layout = DisplayLayout(
        displays: [
            DisplayDescriptor(id: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScaleFactor: 2),
            DisplayDescriptor(id: 2, appKitFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), backingScaleFactor: 1),
        ],
        mainDisplayID: 1
    )

    @Test func singleRetinaDisplayDoublesPixels() throws {
        let plan = try #require(CapturePlan.make(rect: GlobalRect(x: 100, y: 50, width: 300, height: 200), layout: layout))
        #expect(plan.isSingleDisplay)
        #expect(plan.outputScale == 2)
        #expect(plan.pixelWidth == 600 && plan.pixelHeight == 400)
        let piece = try #require(plan.pieces.first)
        #expect(piece.displayID == 1)
        #expect(piece.sourceRect == CGRect(x: 100, y: 50, width: 300, height: 200))
        #expect(piece.destination == CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    @Test func secondaryDisplayUsesLocalPointsAndItsScale() throws {
        let plan = try #require(CapturePlan.make(rect: GlobalRect(x: 1500, y: -100, width: 100, height: 100), layout: layout))
        #expect(plan.isSingleDisplay)
        #expect(plan.outputScale == 1)
        #expect(plan.pixelWidth == 100)
        #expect(plan.pieces.first?.sourceRect == CGRect(x: 60, y: 80, width: 100, height: 100))
    }

    @Test func spanningRectCompositesAtHighestScale() throws {
        let plan = try #require(CapturePlan.make(rect: GlobalRect(x: 1400, y: 100, width: 100, height: 50), layout: layout))
        #expect(!plan.isSingleDisplay)
        #expect(plan.outputScale == 2)
        #expect(plan.pixelWidth == 200 && plan.pixelHeight == 100)
        let left = try #require(plan.pieces.first { $0.displayID == 1 })
        let right = try #require(plan.pieces.first { $0.displayID == 2 })
        #expect(left.sourceRect == CGRect(x: 1400, y: 100, width: 40, height: 50))
        #expect(left.destination == CGRect(x: 0, y: 0, width: 80, height: 100))
        #expect(right.sourceRect == CGRect(x: 0, y: 280, width: 60, height: 50))
        #expect(right.destination == CGRect(x: 80, y: 0, width: 120, height: 100))
        #expect(right.pixelWidth == 120)
    }

    @Test func emptyOrOffscreenRectHasNoPlan() {
        #expect(CapturePlan.make(rect: GlobalRect(x: 10, y: 10, width: 0, height: 10), layout: layout) == nil)
        #expect(CapturePlan.make(rect: GlobalRect(x: -500, y: -500, width: 10, height: 10), layout: layout) == nil)
    }
}
