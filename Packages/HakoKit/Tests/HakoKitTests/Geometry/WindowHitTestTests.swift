import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("WindowHitTest")
struct WindowHitTestTests {
    /// A raw `CGWindowListCopyWindowInfo`-shaped entry.
    static func info(
        _ id: Int, _ frame: CGRect, layer: Int = 0, alpha: Double = 1,
        pid: Int = 100, owner: String = "Safari", title: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: [
                "X": NSNumber(value: Double(frame.minX)), "Y": NSNumber(value: Double(frame.minY)),
                "Width": NSNumber(value: Double(frame.width)), "Height": NSNumber(value: Double(frame.height)),
            ] as [String: Any],
        ]
        if let title { dict[kCGWindowName as String] = title }
        return dict
    }

    /// Front-to-back, like the real list: menu bar, a status item, our overlay,
    /// a tiny tooltip, an invisible window, Finder in front, Safari behind,
    /// then the Dock's wallpaper window.
    static var fakeList: [[String: Any]] { [
        info(1, CGRect(x: 0, y: 0, width: 2560, height: 25), layer: 24, pid: 1, owner: "Window Server", title: "Menubar"),
        info(2, CGRect(x: 2000, y: 0, width: 30, height: 25), layer: 25, pid: 2, owner: "Control Center"),
        info(3, CGRect(x: 0, y: 0, width: 2560, height: 1440), layer: 1000, pid: 999, owner: "HakoShot"),
        info(4, CGRect(x: 300, y: 300, width: 30, height: 20), layer: 3, pid: 100, owner: "Safari"),
        info(5, CGRect(x: 100, y: 100, width: 500, height: 500), layer: 0, alpha: 0, pid: 300, owner: "Ghost"),
        info(6, CGRect(x: 200, y: 200, width: 400, height: 300), pid: 200, owner: "Finder", title: "Downloads"),
        info(7, CGRect(x: 100, y: 100, width: 1000, height: 800), pid: 100, owner: "Safari", title: ""),
        info(8, CGRect(x: -1920, y: 0, width: 1920, height: 1080), pid: 100, owner: "Safari", title: "Left"),
        info(9, CGRect(x: 0, y: 0, width: 2560, height: 1440), layer: -2_147_483_624, pid: 3, owner: "Dock", title: "Wallpaper"),
    ] }

    static var rules: WindowEligibility { WindowEligibility(excludedPIDs: [999]) }

    @Test func parsesDescriptor() throws {
        let window = try #require(WindowHitTest.descriptor(from: Self.fakeList[5]))
        #expect(window.id == 6)
        #expect(window.frame == CGRect(x: 200, y: 200, width: 400, height: 300))
        #expect(window.ownerPID == 200)
        #expect(window.ownerName == "Finder")
        #expect(window.title == "Downloads")
        #expect(window.layer == 0)
        #expect(window.alpha == 1)
    }

    @Test func parsesPlainSwiftNumbers() throws {
        let raw: [String: Any] = [
            kCGWindowNumber as String: 42,
            kCGWindowOwnerPID as String: 7,
            kCGWindowBounds as String: ["X": 1.5, "Y": -20, "Width": 100, "Height": 50.0] as [String: Any],
        ]
        let window = try #require(WindowHitTest.descriptor(from: raw))
        #expect(window.id == 42)
        #expect(window.frame == CGRect(x: 1.5, y: -20, width: 100, height: 50))
        #expect(window.ownerName == "")
        #expect(window.title == nil)
    }

    @Test func emptyTitleBecomesNil() throws {
        let window = try #require(WindowHitTest.descriptor(from: Self.fakeList[6]))
        #expect(window.title == nil)
    }

    @Test func missingBoundsIsRejected() {
        var raw = Self.fakeList[5]
        raw.removeValue(forKey: kCGWindowBounds as String)
        #expect(WindowHitTest.descriptor(from: raw) == nil)
    }

    @Test func filterKeepsOnlyAppWindowsInOrder() {
        let eligible = WindowHitTest.eligibleWindows(from: Self.fakeList, rules: Self.rules)
        #expect(eligible.map(\.id) == [6, 7, 8])
    }

    @Test func defaultRulesKeepOwnWindowWhenPIDNotExcluded() {
        // Layer 1000 is still outside 0...24, so the overlay is dropped anyway.
        let eligible = WindowHitTest.eligibleWindows(from: Self.fakeList)
        #expect(!eligible.contains { $0.id == 3 })
    }

    @Test func excludedPIDDropsNormalLayerWindow() {
        let own = WindowDescriptor(id: 50, frame: CGRect(x: 0, y: 0, width: 300, height: 300), ownerPID: 999, ownerName: "HakoShot")
        #expect(WindowHitTest.eligibleWindows([own], rules: Self.rules).isEmpty)
        #expect(WindowHitTest.eligibleWindows([own]).count == 1)
    }

    @Test func minimumSizeIsInclusive() {
        let exact = WindowDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 40, height: 40), ownerPID: 1, ownerName: "A")
        let thin = WindowDescriptor(id: 2, frame: CGRect(x: 0, y: 0, width: 400, height: 39), ownerPID: 1, ownerName: "A")
        #expect(WindowHitTest.eligibleWindows([exact, thin]).map(\.id) == [1])
    }

    @Test func hitTestPicksFrontmost() {
        let eligible = WindowHitTest.eligibleWindows(from: Self.fakeList, rules: Self.rules)
        // Inside both Finder (front) and Safari (behind).
        #expect(WindowHitTest.window(at: CGPoint(x: 300, y: 300), in: eligible)?.id == 6)
        // Only Safari.
        #expect(WindowHitTest.window(at: CGPoint(x: 900, y: 700), in: eligible)?.id == 7)
        // Tiny tooltip at (300,300) and invisible window were filtered out,
        // so the point under the tooltip still hits Finder.
        #expect(WindowHitTest.window(at: CGPoint(x: 310, y: 310), in: eligible)?.id == 6)
    }

    @Test func hitTestOnSecondaryDisplayWithNegativeX() {
        let eligible = WindowHitTest.eligibleWindows(from: Self.fakeList, rules: Self.rules)
        #expect(WindowHitTest.window(at: CGPoint(x: -100, y: 500), in: eligible)?.id == 8)
    }

    @Test func hitTestMissReturnsNil() {
        let eligible = WindowHitTest.eligibleWindows(from: Self.fakeList, rules: Self.rules)
        // Only the menu bar and wallpaper are here, both filtered.
        #expect(WindowHitTest.window(at: CGPoint(x: 2400, y: 10), in: eligible) == nil)
        #expect(WindowHitTest.window(at: CGPoint(x: 2400, y: 1300), in: eligible) == nil)
    }

    @Test func hitTestEdges() {
        let window = WindowDescriptor(id: 1, frame: CGRect(x: 100, y: 100, width: 200, height: 100), ownerPID: 1, ownerName: "A")
        #expect(WindowHitTest.window(at: CGPoint(x: 100, y: 100), in: [window]) != nil)
        #expect(WindowHitTest.window(at: CGPoint(x: 300, y: 150), in: [window]) == nil)
    }

    @Test func fullyCoveredDetection() {
        let front = WindowDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 500), ownerPID: 1, ownerName: "A")
        let hidden = WindowDescriptor(id: 2, frame: CGRect(x: 10, y: 10, width: 100, height: 100), ownerPID: 2, ownerName: "B")
        let peeking = WindowDescriptor(id: 3, frame: CGRect(x: 400, y: 400, width: 200, height: 200), ownerPID: 3, ownerName: "C")
        let list = [front, hidden, peeking]
        #expect(!WindowHitTest.isFullyCovered(front, in: list))
        #expect(WindowHitTest.isFullyCovered(hidden, in: list))
        #expect(!WindowHitTest.isFullyCovered(peeking, in: list))
    }
}
