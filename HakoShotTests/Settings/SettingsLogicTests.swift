import Foundation
import HakoKit
import Testing
@testable import HakoShot

@MainActor
private func scratchSettings(_ name: String = #function) -> (AppSettings, UserDefaults) {
    let suite = "com.hakanyucel.hakoshot.tests.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    return (AppSettings(defaults: defaults), defaults)
}

@Suite("FileNamePatternParser")
struct FileNamePatternParserTests {
    @Test func defaultPatternRoundTrips() {
        let pattern = FileNameTemplate.default.pattern
        let segments = FileNamePatternParser.segments(from: pattern)
        #expect(segments == [
            .text("HakoShot "), .token(.year4), .text("-"), .token(.month), .text("-"), .token(.day),
            .text(" at "), .token(.hour24), .text("."), .token(.minute), .text("."), .token(.second),
        ])
        #expect(FileNamePatternParser.pattern(from: segments) == pattern)
    }

    @Test func modeWinsOverMonthAndUnknownPercentStaysText() {
        #expect(FileNamePatternParser.segments(from: "%mode%m") == [.token(.mode), .token(.month)])
        #expect(FileNamePatternParser.segments(from: "50%x %n") == [.text("50%x "), .token(.counter)])
        #expect(FileNamePatternParser.segments(from: "%") == [.text("%")])
        #expect(FileNamePatternParser.segments(from: "") == [])
    }

    @Test func everyTokenParsesBack() {
        for token in FileNameToken.allCases {
            #expect(FileNamePatternParser.segments(from: token.rawValue) == [.token(token)])
        }
    }

    @Test func acceptanceExamplePattern() {
        let segments = FileNamePatternParser.segments(from: "%Y%m%d-%n")
        #expect(segments == [.token(.year4), .token(.month), .token(.day), .text("-"), .token(.counter)])
        #expect(FileNamePatternParser.usesCounter("%Y%m%d-%n"))
        #expect(!FileNamePatternParser.usesCounter(FileNameTemplate.default.pattern))
    }

    @Test func normalizeMergesAndDropsEmptyText() {
        let result = FileNamePatternParser.normalized([.text("a"), .text(""), .text("b"), .token(.day), .text("")])
        #expect(result == [.text("ab"), .token(.day)])
    }

    @Test func movingReordersSegments() {
        let s: [FileNameSegment] = [.token(.year4), .token(.month), .token(.day)]
        #expect(FileNamePatternParser.moving(s, from: 0, to: 3) == [.token(.month), .token(.day), .token(.year4)])
        #expect(FileNamePatternParser.moving(s, from: 2, to: 0) == [.token(.day), .token(.year4), .token(.month)])
        #expect(FileNamePatternParser.moving(s, from: 1, to: 1) == s)
        #expect(FileNamePatternParser.moving(s, from: 5, to: 0) == s)
    }

    @Test @MainActor func previewRendersTemplate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 14, minute: 5, second: 12)) ?? .now
        #expect(FileNamePreview.fileName(pattern: "%Y%m%d-%n", format: .png, counter: 7, date: date) == "20260924-7.png")
        #expect(FileNamePreview.fileName(pattern: FileNameTemplate.default.pattern, format: .jpeg, counter: 1, date: date)
            == "HakoShot 2026-09-24 at 14.05.12.jpg")
    }
}

@Suite("FileNameCounter") @MainActor
struct FileNameCounterTests {
    @Test func advancesOnlyWhenPatternUsesCounter() {
        let (settings, _) = scratchSettings()
        #expect(FileNameCounter.take(pattern: "%Y", settings: settings) == 1)
        #expect(FileNameCounter.peek(settings: settings) == 1)
        #expect(FileNameCounter.take(pattern: "%Y-%n", settings: settings) == 1)
        #expect(FileNameCounter.take(pattern: "%Y-%n", settings: settings) == 2)
        #expect(FileNameCounter.peek(settings: settings) == 3)
    }
}

@Suite("AnnotateDefaults") @MainActor
struct AnnotateDefaultsTests {
    @Test func defaultsMatchPlan() {
        let (settings, _) = scratchSettings()
        let tools = AnnotateDefaults.configured(settings)
        #expect(tools == ToolSettings())
        #expect(AnnotateDefaults.initialToolSettings(settings) == ToolSettings())
    }

    @Test func configuredValuesApply() {
        let (settings, _) = scratchSettings()
        settings.set("#0A84FF", for: .annotateDefaultColor)
        settings.set(4, for: .annotateStrokeWidthIndex)
        settings.set(99, for: .annotateTextSizeIndex)
        settings.set(.thick, for: .annotateArrowStyle)
        settings.set(.boxed, for: .annotateTextStyle)
        settings.set(.filledSquare, for: .annotateCounterStyle)
        settings.set(.blackOut, for: .annotateRedactionMethod)
        settings.set(false, for: .annotateShadow)
        let tools = AnnotateDefaults.configured(settings)
        #expect(tools.color == RGBAColor.annotationBlue)
        #expect(tools.strokePresetIndex == 4)
        #expect(tools.textSizePresetIndex == TextSizePreset.points.count - 1)
        #expect(tools.arrowStyle == .thick)
        #expect(tools.textStyle == .boxed)
        #expect(tools.counterStyle == .filledSquare)
        #expect(tools.redactionMethod == .blackOut)
        #expect(!tools.shadow)
    }

    @Test func remembersLastUsedOnlyWhenEnabled() {
        let (settings, _) = scratchSettings()
        var used = ToolSettings()
        used.arrowStyle = .curved
        used.color = .annotationGreen
        AnnotateDefaults.remember(used, settings: settings)
        #expect(AnnotateDefaults.initialToolSettings(settings) == used)

        settings.set(false, for: .annotateRememberLastUsed)
        #expect(AnnotateDefaults.initialToolSettings(settings) == ToolSettings())
        AnnotateDefaults.forgetLastUsed(settings: settings)
        settings.set(true, for: .annotateRememberLastUsed)
        #expect(AnnotateDefaults.initialToolSettings(settings) == ToolSettings())

        settings.set(false, for: .annotateRememberLastUsed)
        AnnotateDefaults.remember(used, settings: settings)
        #expect(settings.value(for: .annotateLastToolSettings).isEmpty)
    }
}

@Suite("WallpaperDefaults")
struct WallpaperDefaultsTests {
    @Test func roundTripsAndFallsBack() {
        #expect(WallpaperDefaults.style(from: "") == .standard)
        #expect(WallpaperDefaults.style(from: "{not json") == .standard)
        var style = BackgroundStyle.standard
        style.fill = .preset("ocean")
        style.padding = 40
        style.cornerRadius = 20
        #expect(WallpaperDefaults.style(from: WallpaperDefaults.json(for: style)) == style)
    }

    @Test func imageFillsBecomeDefaultGradient() {
        var style = BackgroundStyle.standard
        style.fill = .image(AssetID())
        #expect(WallpaperDefaults.style(from: WallpaperDefaults.json(for: style)).fill == BackgroundStyle.standard.fill)
    }

    @Test func offersEveryCatalogFill() {
        #expect(WallpaperDefaults.gradientFills.count == GradientCatalog.gradients.count)
        #expect(WallpaperDefaults.solidFills.count == GradientCatalog.solidColors.count)
        #expect(WallpaperDefaults.title(for: .preset(GradientCatalog.defaultPresetID)) == "Aurora")
    }
}
