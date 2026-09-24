import CoreGraphics
import Foundation
import Testing
@testable import HakoShot

@Suite("URLSchemeHandler")
struct URLSchemeHandlerTests {
    private func parse(_ string: String) throws -> AppCommand {
        let url = try #require(URL(string: string))
        return try URLSchemeHandler.parse(url)
    }

    private func error(_ string: String) throws -> URLSchemeError? {
        let url = try #require(URL(string: string))
        do {
            _ = try URLSchemeHandler.parse(url)
            return nil
        } catch {
            return error
        }
    }

    @Test(arguments: [
        ("hakoshot://capture-area", AppCommand.capture(.area)),
        ("hakoshot://capture-previous-area", .capture(.previousArea)),
        ("hakoshot://capture-fullscreen", .capture(.fullscreen(.preferred))),
        ("hakoshot://capture-window", .capture(.window)),
        ("hakoshot://scrolling-capture", .capture(.scrolling)),
        ("hakoshot://self-timer", .capture(.selfTimer)),
        ("hakoshot://all-in-one", .capture(.allInOne)),
        ("hakoshot://capture-text", .captureText(lineBreaks: true)),
        ("hakoshot://open-history", .openHistory),
        ("hakoshot://restore-recently-closed", .restoreLastClosed),
        ("hakoshot://open-annotate", .openEditor(nil)),
        ("hakoshot://open-from-clipboard", .openFromClipboard),
        ("hakoshot://toggle-desktop-icons", .toggleDesktopIcons),
        ("hakoshot://close-all-pins", .closeAllPins),
        ("hakoshot://open-settings", .openSettings),
        ("hakoshot://open-onboarding", .openOnboarding),
    ])
    func basicCommands(url: String, expected: AppCommand) throws {
        #expect(try parse(url) == expected)
    }

    @Test func commandIsCaseInsensitiveAndPathFormWorks() throws {
        #expect(try parse("HAKOSHOT://Capture-Area") == .capture(.area))
        #expect(try parse("hakoshot:///capture-window") == .capture(.window))
        #expect(try parse("hakoshot:capture-window") == .capture(.window))
    }

    @Test func areaWithRectAndAction() throws {
        let command = try parse("hakoshot://capture-area?x=100&y=50&width=400&height=300&action=save")
        #expect(command == .capture(.area, CaptureOptions(rect: CGRect(x: 100, y: 50, width: 400, height: 300), action: .save)))
    }

    @Test func areaAcceptsShortRectNamesAndDecimals() throws {
        let command = try parse("hakoshot://capture-area?x=-10.5&y=0&w=20&h=30.25")
        #expect(command == .capture(.area, CaptureOptions(rect: CGRect(x: -10.5, y: 0, width: 20, height: 30.25))))
    }

    @Test func actionOnOtherCaptureModes() throws {
        #expect(try parse("hakoshot://capture-fullscreen?action=copy") == .capture(.fullscreen(.preferred), CaptureOptions(action: .copy)))
        #expect(try parse("hakoshot://capture-window?action=ANNOTATE") == .capture(.window, CaptureOptions(action: .annotate)))
        #expect(try parse("hakoshot://capture-previous-area?action=pin") == .capture(.previousArea, CaptureOptions(action: .pin)))
    }

    @Test func rectIgnoredOutsideArea() throws {
        #expect(try parse("hakoshot://capture-window?x=1&y=2&width=3&height=4") == .capture(.window))
    }

    @Test func selfTimerAndAllInOneAcceptRect() throws {
        let rect = CGRect(x: 10, y: 20, width: 800, height: 600)
        #expect(
            try parse("hakoshot://self-timer?x=10&y=20&width=800&height=600&action=save")
                == .capture(.selfTimer, CaptureOptions(rect: rect, action: .save))
        )
        #expect(try parse("hakoshot://all-in-one?x=10&y=20&w=800&h=600") == .capture(.allInOne, CaptureOptions(rect: rect)))
        #expect(try error("hakoshot://all-in-one?x=10") == .incompleteRect)
    }

    @Test func scrollingCaptureRectStartAndAutoScroll() throws {
        let rect = CGRect(x: 100, y: 200, width: 600, height: 400)
        #expect(
            try parse("hakoshot://scrolling-capture?x=100&y=200&width=600&height=400&start=true")
                == .capture(.scrolling, CaptureOptions(rect: rect, start: true))
        )
        #expect(
            try parse("hakoshot://scrolling-capture?x=100&y=200&w=600&h=400&start=0&autoscroll=YES&action=save")
                == .capture(.scrolling, CaptureOptions(rect: rect, action: .save, start: false, autoScroll: true))
        )
        #expect(try parse("hakoshot://scrolling-capture?auto-scroll=1") == .capture(.scrolling, CaptureOptions(autoScroll: true)))
        // No `start` → follow the setting.
        #expect(try parse("hakoshot://scrolling-capture?autoscroll=false") == .capture(.scrolling, CaptureOptions()))
        #expect(try error("hakoshot://scrolling-capture?start=maybe") == .invalidParameter(name: "start", value: "maybe"))
        #expect(try error("hakoshot://scrolling-capture?x=1&y=2") == .incompleteRect)
        // Other modes ignore the scrolling-only parameters.
        #expect(try parse("hakoshot://capture-area?start=true&autoscroll=true") == .capture(.area))
    }

    @Test func openSettingsPage() throws {
        #expect(try parse("hakoshot://open-settings?page=Shortcuts") == .openSettingsPage("shortcuts"))
        #expect(try parse("hakoshot://open-settings?page=") == .openSettings)
    }

    @Test func fullscreenDisplay() throws {
        #expect(try parse("hakoshot://capture-fullscreen?display=all") == .capture(.fullscreen(.allDisplays)))
        #expect(try parse("hakoshot://capture-fullscreen?display=active") == .capture(.fullscreen(.activeDisplay)))
        #expect(try error("hakoshot://capture-fullscreen?display=left") == .invalidParameter(name: "display", value: "left"))
    }

    @Test func captureTextLineBreaks() throws {
        #expect(try parse("hakoshot://capture-text?linebreaks=false") == .captureText(lineBreaks: false))
        #expect(try parse("hakoshot://capture-text?linebreaks=0") == .captureText(lineBreaks: false))
        #expect(try parse("hakoshot://capture-text?line-breaks=true") == .captureText(lineBreaks: true))
        #expect(try error("hakoshot://capture-text?linebreaks=maybe") == .invalidParameter(name: "linebreaks", value: "maybe"))
    }

    @Test func captureTextRect() throws {
        #expect(
            try parse("hakoshot://capture-text?x=10&y=20&width=300&height=40&linebreaks=false")
                == .captureText(lineBreaks: false, rect: CGRect(x: 10, y: 20, width: 300, height: 40))
        )
        #expect(try error("hakoshot://capture-text?x=10&y=20") == .incompleteRect)
    }

    @Test func openAnnotateFilePath() throws {
        #expect(try parse("hakoshot://open-annotate?filepath=/tmp/a%20b.png") == .openEditor(URL(fileURLWithPath: "/tmp/a b.png")))
        #expect(try parse("hakoshot://open-annotate?filepath=file:///tmp/x.png") == .openEditor(URL(fileURLWithPath: "/tmp/x.png")))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try parse("hakoshot://open-annotate?filepath=~/x.png") == .openEditor(URL(fileURLWithPath: home + "/x.png")))
        #expect(try parse("hakoshot://open-annotate?filepath=") == .openEditor(nil))
    }

    @Test func errors() throws {
        #expect(try error("https://capture-area") == .unsupportedScheme("https"))
        #expect(try error("hakoshot://") == .missingCommand)
        #expect(try error("hakoshot://capture-video") == .unknownCommand("capture-video"))
        #expect(try error("hakoshot://capture-area?action=upload") == .invalidParameter(name: "action", value: "upload"))
        #expect(try error("hakoshot://capture-area?x=1&y=2&width=3") == .incompleteRect)
        #expect(try error("hakoshot://capture-area?x=1&y=2&width=0&height=3") == .emptyRect)
        #expect(try error("hakoshot://capture-area?x=a&y=2&width=3&height=3") == .invalidParameter(name: "x", value: "a"))
    }

    @Test func descriptionIsReadable() {
        let command = AppCommand.capture(.area, CaptureOptions(rect: CGRect(x: 1, y: 2, width: 3, height: 4), action: .save))
        #expect(command.description == "capture(area, rect=1,2,3x4, action=save)")
        #expect(AppCommand.capture(.area).description == "capture(area)")
    }
}
