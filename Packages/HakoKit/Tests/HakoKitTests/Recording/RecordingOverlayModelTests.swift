import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

// R5.2: click ring curve, keystroke badge layout / timing, formatter + filter,
// repeat merging.

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

@Suite("ClickEffectModel")
struct ClickEffectModelTests {
    let model = ClickEffectModel.standard

    @Test func radiusEasesOutFrom18To30() {
        #expect(model.radius(at: 0) == 18)
        #expect(near(model.radius(at: 0.35), 30))
        // Ease-out cubic: half way in time is past half way in radius.
        let mid = model.radius(at: 0.175)
        #expect(near(mid, 18 + 12 * (1 - pow(0.5, 3))))
        #expect(mid > 24)
        // Monotonic.
        var last = 0.0
        for i in 0...35 {
            let r = model.radius(at: Double(i) / 100)
            #expect(r >= last)
            last = r
        }
    }

    @Test func alphaFadesLinearlyAndIsZeroOutside() {
        #expect(model.alpha(at: 0) == 1)
        #expect(near(model.alpha(at: 0.1), 1 - 0.1 / 0.35))
        #expect(model.alpha(at: 0.35) == 0)
        #expect(model.alpha(at: -0.01) == 0)
        #expect(model.alpha(at: 1) == 0)
        #expect(model.frame(at: 0.35) == nil)
        #expect(model.frame(at: -0.1) == nil)
        #expect(model.isActive(at: 0.349))
    }

    @Test func sizeScalesRadiusButNotLine() {
        let large = ClickEffectModel(style: .outline, size: .large)
        let small = ClickEffectModel(style: .outline, size: .small)
        #expect(near(large.radius(at: 0), 18 * 1.4))
        #expect(near(small.radius(at: 0.35), 30 * 0.75))
        #expect(large.frame(at: 0.1)?.lineWidth == 2)
        #expect(ClickEffectModel.sizeScale(.medium) == 1)
    }

    @Test func styles() throws {
        let outline = try #require(model.frame(at: 0.1))
        #expect(outline.fillAlpha == 0)
        #expect(outline.strokeAlpha == outline.alpha)
        let filled = try #require(ClickEffectModel(style: .filled).frame(at: 0.1))
        #expect(near(filled.fillAlpha, filled.alpha * 0.35))
    }

    @Test func rightClickAddsInnerRing() throws {
        #expect(try #require(model.frame(at: 0.1)).secondaryRadius == nil)
        let right = try #require(model.frame(at: 0.1, button: .right))
        #expect(near(try #require(right.secondaryRadius), right.radius * 0.6))
    }

    @Test func notAnimatedHoldsAStaticRing() {
        let still = ClickEffectModel(animated: false)
        #expect(still.radius(at: 0) == 18)
        #expect(still.radius(at: 0.3) == 18)
        #expect(still.alpha(at: 0.3) == 1)
        #expect(still.alpha(at: 0.35) == 0)
    }

    @Test func samplesSpanTheDurationAndEndInvisible() {
        let samples = model.samples(count: 10)
        #expect(samples.count == 11)
        #expect(samples.first?.alpha == 1)
        #expect(samples.last?.alpha == 0)
        #expect(near(samples.last?.radius ?? 0, 30))
    }

    @Test func studioFrameStateUsesTheSameCurve() {
        #expect(StudioFrameState.clickEffectDuration == model.duration)
        #expect(StudioFrameState.clickStartRadius == model.startRadius)
        #expect(StudioFrameState.clickEndRadius == model.endRadius)
    }
}

@Suite("KeystrokeFormatter")
struct KeystrokeFormatterTests {
    static let shift: UInt64 = 1 << 17
    static let control: UInt64 = 1 << 18
    static let option: UInt64 = 1 << 19
    static let command: UInt64 = 1 << 20
    static let fn: UInt64 = 1 << 23
    static let capsLock: UInt64 = 1 << 16

    struct Case: Sendable, CustomTestStringConvertible {
        var keyCode: UInt16
        var flags: UInt64
        var characters: String?
        var expected: String?
        var testDescription: String { expected ?? "nil(\(keyCode))" }
    }

    static let cases: [Case] = [
        Case(keyCode: 0x03, flags: shift | command, characters: "f", expected: "⇧⌘F"),
        Case(keyCode: 0x03, flags: shift | command, characters: nil, expected: "⇧⌘F"),
        Case(keyCode: 0x06, flags: command, characters: "z", expected: "⌘Z"),
        Case(keyCode: 0x08, flags: control | option | shift | command, characters: "c", expected: "⌃⌥⇧⌘C"),
        Case(keyCode: 0x24, flags: 0, expected: "↩"),
        Case(keyCode: 0x24, flags: command, expected: "⌘↩"),
        Case(keyCode: 0x30, flags: 0, characters: "\t", expected: "⇥"),
        Case(keyCode: 0x35, flags: 0, expected: "⎋"),
        Case(keyCode: 0x33, flags: 0, expected: "⌫"),
        Case(keyCode: 0x75, flags: fn, expected: "⌦"),
        Case(keyCode: 0x7B, flags: fn, expected: "←"),
        Case(keyCode: 0x7C, flags: fn | shift, expected: "⇧→"),
        Case(keyCode: 0x7D, flags: fn, expected: "↓"),
        Case(keyCode: 0x7E, flags: fn | option, expected: "⌥↑"),
        Case(keyCode: 0x31, flags: control, characters: " ", expected: "⌃Space"),
        Case(keyCode: 0x7A, flags: fn, expected: "F1"),
        Case(keyCode: 0x6F, flags: fn, expected: "F12"),
        Case(keyCode: 0x5A, flags: 0, expected: "F20"),
        Case(keyCode: 0x12, flags: command, characters: "1", expected: "⌘1"),
        Case(keyCode: 0x00, flags: capsLock, characters: "a", expected: "A"),
        // Turkish Q layout: the event's characters win over the ANSI table.
        Case(keyCode: 0x27, flags: command, characters: "i", expected: "⌘I"),
        Case(keyCode: 0x29, flags: 0, characters: "ş", expected: "Ş"),
        // Modifier keys alone never format.
        Case(keyCode: 0x37, flags: command, expected: nil),
        Case(keyCode: 0x38, flags: shift, expected: nil),
        // Unknown code, no characters.
        Case(keyCode: 0xFF, flags: command, expected: nil),
    ]

    @Test(arguments: cases)
    func formats(_ c: Case) {
        #expect(KeystrokeFormatter.format(keyCode: c.keyCode, modifierFlags: c.flags, characters: c.characters)?.text == c.expected)
    }

    @Test func shortcutsOnlyFilter() {
        func shown(_ code: UInt16, _ flags: UInt64, _ chars: String? = nil) -> Bool {
            KeystrokeFormatter.displayText(keyCode: code, modifierFlags: flags, characters: chars, filter: .shortcutsOnly) != nil
        }
        #expect(shown(0x03, Self.shift | Self.command, "f"))
        #expect(shown(0x08, Self.control, "c"))
        #expect(shown(0x00, Self.option, "a"))
        #expect(!shown(0x00, 0, "a"))              // plain typing
        #expect(!shown(0x00, Self.shift, "a"))     // Shift alone isn't a shortcut
        #expect(!shown(0x31, 0, " "))              // Space alone
        #expect(!shown(0x31, Self.shift, " "))
        #expect(shown(0x31, Self.command, " "))
        #expect(shown(0x35, 0))                    // Esc
        #expect(shown(0x24, 0))                    // Return
        #expect(shown(0x30, Self.shift))           // ⇧Tab
        #expect(shown(0x33, 0))                    // Delete
        #expect(shown(0x7B, Self.fn))              // ←, Fn bit ignored
        #expect(shown(0x60, Self.fn))              // F5
        #expect(!shown(0x3A, Self.option))         // lone ⌥
        // Fn alone doesn't make a letter a shortcut.
        #expect(!shown(0x00, Self.fn, "a"))
    }

    @Test func allKeysShowsTypingButNotLoneModifiers() {
        #expect(KeystrokeFormatter.displayText(keyCode: 0x00, modifierFlags: 0, characters: "a", filter: .allKeys) == "A")
        #expect(KeystrokeFormatter.displayText(keyCode: 0x00, modifierFlags: Self.shift, characters: "a", filter: .allKeys) == "⇧A")
        #expect(KeystrokeFormatter.displayText(keyCode: 0x38, modifierFlags: Self.shift, filter: .allKeys) == nil)
    }

    @Test func recordedEvents() {
        let down = RecordingKeyEvent(time: 1, keyCode: 0x03, modifierFlags: Self.shift | Self.command, characters: "f")
        #expect(KeystrokeFormatter.displayText(for: down, filter: .shortcutsOnly) == "⇧⌘F")
        let flags = RecordingKeyEvent(time: 1, kind: .flagsChanged, keyCode: 0x37, modifierFlags: Self.command)
        #expect(KeystrokeFormatter.displayText(for: flags, filter: .allKeys) == nil)
    }

    @Test func modifiersFromEventFlags() {
        let m = KeystrokeModifiers(eventFlags: Self.command | Self.fn | Self.capsLock | 0x100)
        #expect(m == .command)
        #expect(m.hasShortcutModifier)
        #expect(!KeystrokeModifiers.shift.hasShortcutModifier)
        #expect(KeystrokeModifiers([.command, .shift, .option, .control]).glyphs == "⌃⌥⇧⌘")
    }

    @Test func label() {
        #expect(KeystrokeFormatter.label(text: "⌘Z", count: 1) == "⌘Z")
        #expect(KeystrokeFormatter.label(text: "⌘Z", count: 3) == "⌘Z ×3")
    }
}

@Suite("Keystroke repeat merging")
struct KeystrokeRepeatMergerTests {
    @Test func sameComboWhileVisibleCounts() {
        var merger = KeystrokeRepeatMerger()
        merger.add("⌘Z", at: 0)
        merger.add("⌘Z", at: 0.5)
        let entry = merger.add("⌘Z", at: 1.5)   // still inside 1.2 s hold after 0.5
        #expect(merger.entries.count == 1)
        #expect(entry.count == 3)
        #expect(entry.label == "⌘Z ×3")
        #expect(entry.firstTime == 0)
        #expect(entry.lastTime == 1.5)
    }

    @Test func afterTheBadgeIsGoneStartsOver() {
        // Gone at lastKey + 1.2 + 0.2 = 1.4.
        let entries = KeystrokeRepeatMerger.merge([(0, "⌘Z"), (1.45, "⌘Z")])
        #expect(entries.count == 2)
        #expect(entries.map(\.count) == [1, 1])
        #expect(entries[1].fadeInStart == 1.45)
    }

    @Test func differentComboReplacesWithoutRefading() {
        let entries = KeystrokeRepeatMerger.merge([(0, "⌘C"), (0.5, "⌘V")])
        #expect(entries.count == 2)
        // ⌘C was fully visible at 0.5, so ⌘V starts at full alpha.
        #expect(near(entries[1].fadeInStart, 0.5 - 0.2))
        #expect(KeystrokeBadgeTiming.standard.alpha(for: entries[1], at: 0.5) == 1)
        // Replacing during ⌘C's fade-in keeps the partial alpha.
        let early = KeystrokeRepeatMerger.merge([(0, "⌘C"), (0.1, "⌘V")])
        #expect(near(KeystrokeBadgeTiming.standard.alpha(for: early[1], at: 0.1), 0.5))
    }

    @Test func eventsSkipAutoRepeatAndFilteredKeys() {
        let cmd: UInt64 = 1 << 20
        let events = [
            RecordingKeyEvent(time: 0, keyCode: 0x06, modifierFlags: cmd, characters: "z"),
            RecordingKeyEvent(time: 0.1, keyCode: 0x00, characters: "a"),                     // filtered
            RecordingKeyEvent(time: 0.2, keyCode: 0x06, modifierFlags: cmd, characters: "z"),
            RecordingKeyEvent(time: 0.25, keyCode: 0x06, modifierFlags: cmd, characters: "z", isRepeat: true),
        ]
        let entries = KeystrokeRepeatMerger.merge(events: events, filter: .shortcutsOnly)
        #expect(entries.count == 1)
        #expect(entries[0].label == "⌘Z ×2")
        let withRepeats = KeystrokeRepeatMerger.merge(events: events, filter: .shortcutsOnly, includeAutoRepeat: true)
        #expect(withRepeats[0].count == 3)
    }
}

@Suite("KeystrokeBadgeTiming and timeline")
struct KeystrokeBadgeTimingTests {
    let timing = KeystrokeBadgeTiming.standard

    @Test func fadeInHoldFadeOut() {
        let entry = KeystrokeBadgeEntry(text: "⌘K", firstTime: 1)
        #expect(timing.alpha(for: entry, at: 0.99) == 0)
        #expect(timing.alpha(for: entry, at: 1) == 0)
        #expect(near(timing.alpha(for: entry, at: 1.1), 0.5))
        #expect(timing.alpha(for: entry, at: 1.2) == 1)
        #expect(timing.alpha(for: entry, at: 2.19) == 1)     // hold to 1 + 1.2
        #expect(near(timing.alpha(for: entry, at: 2.3), 0.5))
        #expect(timing.alpha(for: entry, at: 2.4) == 0)
        #expect(near(timing.endTime(of: entry), 2.4))
    }

    @Test func holdRestartsFromTheLastPress() {
        let entry = KeystrokeBadgeEntry(text: "⌘Z", pressTimes: [0, 1])
        #expect(timing.alpha(for: entry, at: 2.1) == 1)
        #expect(timing.alpha(for: entry, at: 2.4) == 0)
    }

    @Test func repeatPulse() {
        #expect(near(timing.pulse(sinceRepeat: 0), 1.1))
        #expect(timing.pulse(sinceRepeat: 0.2) == 1)
        #expect(timing.pulse(sinceRepeat: -1) == 1)
        let mid = timing.pulse(sinceRepeat: 0.1)
        #expect(mid > 1 && mid < 1.1)
        let single = KeystrokeBadgeEntry(text: "⌘Z", firstTime: 0)
        #expect(timing.scale(for: single, at: 0) == 1)   // first press doesn't pulse
        let repeated = KeystrokeBadgeEntry(text: "⌘Z", pressTimes: [0, 0.5])
        #expect(near(timing.scale(for: repeated, at: 0.5), 1.1))
    }

    @Test func timelineShowsTheCountAsOfTheTime() throws {
        let entries = KeystrokeRepeatMerger.merge([(0, "⌘Z"), (0.5, "⌘Z"), (1, "⌘Z"), (1.3, "⌘S")])
        #expect(KeystrokeBadgeTimeline.frame(at: -0.1, entries: entries) == nil)
        #expect(try #require(KeystrokeBadgeTimeline.frame(at: 0.1, entries: entries)).label == "⌘Z")
        #expect(try #require(KeystrokeBadgeTimeline.frame(at: 0.6, entries: entries)).label == "⌘Z ×2")
        let third = try #require(KeystrokeBadgeTimeline.frame(at: 1.0, entries: entries))
        #expect(third.label == "⌘Z ×3")
        #expect(near(third.scale, 1.1))
        let save = try #require(KeystrokeBadgeTimeline.frame(at: 1.4, entries: entries))
        #expect(save.label == "⌘S")
        #expect(save.alpha == 1)
        #expect(KeystrokeBadgeTimeline.frame(at: 3, entries: entries) == nil)
    }
}

@Suite("KeystrokeBadgeLayout")
struct KeystrokeBadgeLayoutTests {
    let metrics = KeystrokeBadgeMetrics.standard(.medium)
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func metricsPerSize() {
        #expect(KeystrokeBadgeMetrics.standard(.small).height == 34)
        #expect(metrics.height == 44)
        #expect(KeystrokeBadgeMetrics.standard(.large).height == 56)
        #expect(metrics.cornerRadius == 22)
        #expect(metrics.edgeInset == 64)
        #expect(metrics.fontSize == 20)
        let doubled = metrics.scaled(by: 2)
        #expect(doubled.height == 88 && doubled.edgeInset == 128 && doubled.fontSize == 40)
    }

    @Test func sizeIsTextPlusPaddingAtLeastACircle() {
        #expect(KeystrokeBadgeLayout.badgeSize(textWidth: 50, metrics: metrics) == CGSize(width: 82, height: 44))
        #expect(KeystrokeBadgeLayout.badgeSize(textWidth: 4, metrics: metrics) == CGSize(width: 44, height: 44))
        #expect(KeystrokeBadgeLayout.badgeSize(textWidth: 5000, metrics: metrics, maxWidth: 300).width == 300)
    }

    @Test func bottomCenterYDownAndYUp() {
        let down = KeystrokeBadgeLayout.frame(textWidth: 50, metrics: metrics, placement: .bottomCenter, in: display)
        #expect(down == CGRect(x: 679, y: 900 - 64 - 44, width: 82, height: 44))
        let up = KeystrokeBadgeLayout.frame(textWidth: 50, metrics: metrics, placement: .bottomCenter, in: display, yDown: false)
        #expect(up == CGRect(x: 679, y: 64, width: 82, height: 44))
    }

    @Test func otherPlacements() {
        let container = CGRect(x: 100, y: 200, width: 800, height: 600)
        let left = KeystrokeBadgeLayout.frame(textWidth: 50, metrics: metrics, placement: .bottomLeft, in: container)
        #expect(left.minX == 164 && left.maxY == 200 + 600 - 64)
        let right = KeystrokeBadgeLayout.frame(textWidth: 50, metrics: metrics, placement: .bottomRight, in: container)
        #expect(near(right.maxX, 836))
        let top = KeystrokeBadgeLayout.frame(textWidth: 50, metrics: metrics, placement: .topCenter, in: container)
        #expect(top.minY == 264 && top.midX == container.midX)
    }

    @Test func smallContainerKeepsTheBadgeInside() {
        let small = CGRect(x: 10, y: 10, width: 120, height: 80)
        for placement in KeystrokeBadgePlacement.allCases {
            let frame = KeystrokeBadgeLayout.frame(textWidth: 60, metrics: metrics, placement: placement, in: small)
            #expect(small.contains(frame), "\(placement)")
        }
    }

    @Test func measuresRealText() {
        let short = KeystrokeBadgeLayout.textWidth("⌘Z", fontSize: 20)
        let long = KeystrokeBadgeLayout.textWidth("⌃⌥⇧⌘Z ×12", fontSize: 20)
        #expect(short > 10)
        #expect(long > short * 2)
        let frame = KeystrokeBadgeLayout.frame(text: "⇧⌘F", metrics: metrics, placement: .bottomCenter, in: display)
        #expect(frame.height == 44)
        #expect(near(frame.midX, 720, 0.5))
    }
}
