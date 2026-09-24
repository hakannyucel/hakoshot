import CoreGraphics
import HakoKit
import Testing
@testable import HakoShot

@Suite("All-In-One")
struct AllInOneTests {
    @Test func ratioPresets() {
        #expect(AspectRatioPreset.freeform.ratio == nil)
        #expect(abs((AspectRatioPreset.fixed(width: 16, height: 9).ratio ?? 0) - 16.0 / 9.0) < 1e-9)
        #expect(AspectRatioPreset.fixed(width: 4, height: 3).title == "4:3")
        #expect(AspectRatioPreset.menu.first == .freeform)
        #expect(AspectRatioPreset.menu.count == 7)
    }

    @Test func typedSizeFollowsRatio() {
        let current = CGSize(width: 400, height: 300)
        #expect(AspectRatioPreset.size(width: 800, current: current, ratio: 4.0 / 3.0) == CGSize(width: 800, height: 600))
        #expect(AspectRatioPreset.size(height: 90, current: current, ratio: 16.0 / 9.0) == CGSize(width: 160, height: 90))
        #expect(AspectRatioPreset.size(width: 800, height: 600, current: current, ratio: nil) == CGSize(width: 800, height: 600))
        #expect(AspectRatioPreset.size(width: 500, current: current, ratio: nil) == CGSize(width: 500, height: 300))
    }

    @Test func rememberedSelectionRoundTrips() {
        let rect = GlobalRect(x: -120.5, y: 40, width: 800, height: 600)
        #expect(AllInOneSettings.decode(AllInOneSettings.encode(rect)) == rect)
        #expect(AllInOneSettings.decode("") == nil)
        #expect(AllInOneSettings.decode("1,2,0,4") == nil)
    }

    @Test func modes() {
        #expect(AllInOneMode.allCases.map(\.title) == ["Area", "Fullscreen", "Window", "Scrolling", "Timer", "Text"])
        let allAvailable = AllInOneMode.allCases.allSatisfy { $0.isAvailable }
        #expect(allAvailable)
        #expect(AllInOneMode.scrolling.usesSelection)
        #expect(AllInOneMode.timer.usesSelection)
        #expect(!AllInOneMode.window.usesSelection)
    }

    @Test func selfTimerDefaults() {
        #expect(SettingsKey<Int>.selfTimerSeconds.defaultValue == 5)
        #expect(SelfTimerSettings.intervalChoices == [3, 5, 10])
    }
}
