import Testing
import Foundation
@testable import HakoKit

@Suite("FileNameTemplate")
struct FileNameTemplateTests {
    /// 2026-09-23 19:10:05 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_790_190_605)
    static let utc = TimeZone(identifier: "UTC")!
    static let posix = Locale(identifier: "en_US_POSIX")

    @Test func defaultPatternMatchesPlanExample() {
        let context = FileNameContext(date: Self.fixedDate, timeZone: Self.utc, locale: Self.posix)
        let rendered = FileNameTemplate.default.render(context: context)
        #expect(rendered == "HakoShot 2026-09-23 at 19.10.05")
    }

    @Test func allTokensRender() {
        let template = FileNameTemplate(pattern: "%Y|%y|%m|%B|%d|%H|%h|%M|%S|%p|%n|%mode")
        let context = FileNameContext(date: Self.fixedDate, timeZone: Self.utc, locale: Self.posix, counter: 7, mode: "area")
        let rendered = template.render(context: context)
        #expect(rendered == "2026|26|09|September|23|19|07|10|05|PM|7|area")
    }

    @Test func modeTokenDoesNotCollideWithMonthToken() {
        // "%mode" starts with "%m" (month); a naive left-to-right token pass
        // must resolve "%mode" first or this would render as "09ode".
        let template = FileNameTemplate(pattern: "%mode-%m")
        let context = FileNameContext(date: Self.fixedDate, timeZone: Self.utc, locale: Self.posix, mode: "window")
        #expect(template.render(context: context) == "window-09")
    }

    @Test func differentTimeZonesProduceDifferentLocalTimes() {
        let template = FileNameTemplate(pattern: "%H.%M.%S")
        let utcContext = FileNameContext(date: Self.fixedDate, timeZone: Self.utc, locale: Self.posix)
        let istanbulContext = FileNameContext(date: Self.fixedDate, timeZone: TimeZone(identifier: "Europe/Istanbul")!, locale: Self.posix)
        #expect(template.render(context: utcContext) == "19.10.05")
        #expect(template.render(context: istanbulContext) == "22.10.05")
    }

    @Test func noonAndMidnightHour12EdgeCases() {
        let template = FileNameTemplate(pattern: "%h %p")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let noon = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12, minute: 0, second: 0))!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0))!
        #expect(template.render(context: FileNameContext(date: noon, timeZone: Self.utc, locale: Self.posix)) == "12 PM")
        #expect(template.render(context: FileNameContext(date: midnight, timeZone: Self.utc, locale: Self.posix)) == "12 AM")
    }
}

@Suite("FileNamer")
struct FileNamerTests {
    static let fixedDate = Date(timeIntervalSince1970: 1_790_190_605) // 2026-09-23 19:10:05 UTC
    static let utc = TimeZone(identifier: "UTC")!
    static let posix = Locale(identifier: "en_US_POSIX")

    static func namer(pattern: String = FileNameTemplate.default.pattern) -> FileNamer {
        FileNamer(
            template: FileNameTemplate(pattern: pattern),
            pathExtension: "png",
            timeZone: utc,
            locale: posix,
            clock: { fixedDate }
        )
    }

    @Test func fileNameUsesTemplateAndExtension() {
        let namer = Self.namer()
        #expect(namer.fileName() == "HakoShot 2026-09-23 at 19.10.05.png")
    }

    @Test func counterTokenFeedsThroughToFileName() {
        let namer = Self.namer(pattern: "%Y%m%d-%n")
        #expect(namer.fileName(counter: 3) == "20260923-3.png")
    }

    @Test func sanitizesInvalidFileSystemCharacters() {
        let namer = Self.namer(pattern: "%mode Capture")
        // "/" and ":" must never survive into a rendered name (both are
        // meaningful to the filesystem / Finder).
        let name = namer.fileName(mode: "a/b:c")
        #expect(name == "a-b-c Capture.png")
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test func resolvedURLReturnsBaseNameWhenNoCollision() {
        let namer = Self.namer()
        let directory = URL(fileURLWithPath: "/tmp/HakoShotTests")
        let url = namer.resolvedURL(in: directory, fileExists: { _ in false })
        #expect(url.lastPathComponent == "HakoShot 2026-09-23 at 19.10.05.png")
    }

    @Test func resolvedURLAppendsIncrementingSuffixOnCollision() {
        let namer = Self.namer()
        let directory = URL(fileURLWithPath: "/tmp/HakoShotTests")
        var existing: Set<String> = [
            "HakoShot 2026-09-23 at 19.10.05.png",
            "HakoShot 2026-09-23 at 19.10.05 (2).png",
            "HakoShot 2026-09-23 at 19.10.05 (3).png",
        ]
        let url = namer.resolvedURL(in: directory, fileExists: { existing.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "HakoShot 2026-09-23 at 19.10.05 (4).png")
        existing.removeAll()
    }

    @Test func retinaSuffixIsEmptyByDefault() {
        #expect(Self.namer().retinaSuffix == "")
        #expect(Self.namer().fileName() == "HakoShot 2026-09-23 at 19.10.05.png")
    }

    @Test func retinaSuffixAppendsAfterTemplateBeforeExtension() {
        var namer = Self.namer()
        namer.retinaSuffix = "@2x"
        #expect(namer.fileName() == "HakoShot 2026-09-23 at 19.10.05@2x.png")
    }

    @Test func retinaSuffixPrecedesCollisionCounter() {
        // "@2x" must read as part of the base name, with " (2)" appended
        // after it on collision — not the other way around.
        var namer = Self.namer()
        namer.retinaSuffix = "@2x"
        let directory = URL(fileURLWithPath: "/tmp/HakoShotTests")
        let existing: Set<String> = ["HakoShot 2026-09-23 at 19.10.05@2x.png"]
        let url = namer.resolvedURL(in: directory, fileExists: { existing.contains($0.lastPathComponent) })
        #expect(url.lastPathComponent == "HakoShot 2026-09-23 at 19.10.05@2x (2).png")
    }
}
