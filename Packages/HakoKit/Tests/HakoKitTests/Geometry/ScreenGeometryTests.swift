import Testing
import CoreGraphics
@testable import HakoKit

@Suite("ScreenGeometry")
struct ScreenGeometryTests {
    /// Three displays, mixed scales, one with a negative AppKit x-origin
    /// (to the left of main) and one with a negative resulting Quartz
    /// y-origin (stacked above main) — plan §0.4 test requirement.
    ///
    ///     ┌───────────┐
    ///     │  display3 │  2560×1440 @2x, AppKit y = 1080…2520
    ///     └───────────┘
    /// ┌────────┐┌──────────┐
    /// │display2││ display1 │  1920×1080 @1x / @2x, AppKit y = 0…1080
    /// │(left)  ││ (main)   │
    /// └────────┘└──────────┘
    static func threeDisplayLayout() -> (layout: DisplayLayout, main: DisplayDescriptor, left: DisplayDescriptor, above: DisplayDescriptor) {
        let main = DisplayDescriptor(
            id: 1,
            appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 2.0
        )
        let left = DisplayDescriptor(
            id: 2,
            appKitFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 1.0
        )
        let above = DisplayDescriptor(
            id: 3,
            appKitFrame: CGRect(x: 0, y: 1080, width: 2560, height: 1440),
            backingScaleFactor: 2.0
        )
        let layout = DisplayLayout(displays: [main, left, above], mainDisplayID: 1)
        return (layout, main, left, above)
    }

    @Test func mainDisplayGlobalFrameMatchesItsOwnTopLeftOrigin() {
        let (layout, main, _, _) = Self.threeDisplayLayout()
        let global = ScreenGeometry.globalFrame(of: main, layout: layout)
        #expect(global == GlobalRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func leftDisplayHasNegativeGlobalX() {
        let (layout, _, left, _) = Self.threeDisplayLayout()
        let global = ScreenGeometry.globalFrame(of: left, layout: layout)
        #expect(global == GlobalRect(x: -1920, y: 0, width: 1920, height: 1080))
    }

    @Test func aboveDisplayHasNegativeGlobalY() {
        let (layout, _, _, above) = Self.threeDisplayLayout()
        let global = ScreenGeometry.globalFrame(of: above, layout: layout)
        #expect(global == GlobalRect(x: 0, y: -1440, width: 2560, height: 1440))
    }

    @Test func appKitRoundTripsThroughGlobal() {
        let (layout, _, left, above) = Self.threeDisplayLayout()
        for display in [left, above] {
            let global = ScreenGeometry.globalFrame(of: display, layout: layout)!
            let backToAppKit = ScreenGeometry.appKitRect(fromGlobal: global, layout: layout)
            #expect(backToAppKit == display.appKitFrame)
        }
    }

    @Test func globalRectReturnsNilWithoutMainDisplay() {
        let layout = DisplayLayout(displays: [], mainDisplayID: 99)
        #expect(ScreenGeometry.globalRect(fromAppKit: .zero, layout: layout) == nil)
        #expect(ScreenGeometry.appKitRect(fromGlobal: GlobalRect(x: 0, y: 0, width: 1, height: 1), layout: layout) == nil)
    }

    @Test func displayContainingPointFindsEachDisplay() {
        let (layout, main, left, above) = Self.threeDisplayLayout()
        #expect(ScreenGeometry.display(containing: CGPoint(x: 960, y: 540), layout: layout)?.id == main.id)
        #expect(ScreenGeometry.display(containing: CGPoint(x: -960, y: 540), layout: layout)?.id == left.id)
        #expect(ScreenGeometry.display(containing: CGPoint(x: 1280, y: -720), layout: layout)?.id == above.id)
        #expect(ScreenGeometry.display(containing: CGPoint(x: 100_000, y: 100_000), layout: layout) == nil)
    }

    @Test func displaysIntersectingFindsSpanningRect() {
        let (layout, main, left, _) = Self.threeDisplayLayout()
        // Rect straddling the seam between the left and main displays.
        let spanning = GlobalRect(x: -100, y: 400, width: 200, height: 100)
        let hits = ScreenGeometry.displays(intersecting: spanning, layout: layout).map(\.id).sorted()
        #expect(hits == [main.id, left.id].sorted())
    }

    @Test func pixelRectScalesAndOffsetsByOwningDisplay() {
        let (layout, _, left, _) = Self.threeDisplayLayout()
        // Selection fully inside `left` (scale 1.0): 100pt from its left edge,
        // 50pt from its top edge, 300×200 pt.
        let selection = GlobalRect(x: -1820, y: 50, width: 300, height: 200)
        let pixelRect = ScreenGeometry.pixelRect(of: selection, on: left, layout: layout)
        #expect(pixelRect == CGRect(x: 100, y: 50, width: 300, height: 200))
    }

    @Test func pixelRectScalesByRetinaBackingFactor() {
        let (layout, main, _, _) = Self.threeDisplayLayout()
        // Selection fully inside `main` (scale 2.0): 10pt in from top-left, 40×30 pt.
        let selection = GlobalRect(x: 10, y: 10, width: 40, height: 30)
        let pixelRect = ScreenGeometry.pixelRect(of: selection, on: main, layout: layout)
        #expect(pixelRect == CGRect(x: 20, y: 20, width: 80, height: 60))
    }

    @Test func pixelRectReturnsNilWithoutMainDisplay() {
        let stranger = DisplayDescriptor(id: 999, appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), backingScaleFactor: 1)
        let layoutWithoutMain = DisplayLayout(displays: [stranger], mainDisplayID: 1)
        #expect(ScreenGeometry.pixelRect(of: GlobalRect(x: 0, y: 0, width: 1, height: 1), on: stranger, layout: layoutWithoutMain) == nil)
    }
}
