import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

// R1.I: the coordinator's pure decisions (request from the HUD choice,
// chrome plan, last-rect encoding, countdown placement), the recording menu
// and the new recording URLs.

@Suite("Recording coordinator: request and chrome")
struct RecordingCoordinatorTests {
    private let area = RecordingTarget.area(GlobalRect(x: 100, y: 100, width: 640, height: 360), displayID: 1)

    @Test func requestCarriesTheHUDChoice() {
        let base = RecordingOptions(quality: .medium, showsCursor: true)
        let gif = RecordingCoordinator.makeRequest(
            target: area, options: RecordingCommandOptions(), selection: RecordingHUDSelection(choice: .gif),
            base: base, source: .screen
        )
        #expect(gif.format == .gif)
        #expect(gif.profile == .classic)
        #expect(gif.options == base)
        #expect(gif.target == area)

        let studioSelection = RecordingHUDSelection(choice: .studio)
        let studio = RecordingCoordinator.makeRequest(
            target: area, options: RecordingCommandOptions(), selection: studioSelection,
            base: studioSelection.overrides.applied(to: base), source: .synthetic
        )
        #expect(studio.format == .video)
        #expect(studio.profile == .studio)
        #expect(studio.options.showsCursor == false)
        #expect(studio.options.quality == .ultra)
        #expect(studio.source == .synthetic)

        let video = RecordingCoordinator.makeRequest(
            target: area, options: RecordingCommandOptions(action: .copy), selection: RecordingHUDSelection(choice: .video),
            base: base, source: .screen
        )
        #expect(video.format == .video)
        #expect(video.profile == .classic)
        #expect(video.action == .copy)
    }

    @Test func requestAppliesURLOverrides() {
        var base = RecordingOptions.default
        base.countdownSeconds = 3
        let options = RecordingCommandOptions(autoStopAfter: 2, countdownSeconds: 0, outputURL: URL(fileURLWithPath: "/tmp/x.mp4"))
        let request = RecordingCoordinator.makeRequest(
            target: area, options: options, selection: RecordingHUDSelection(choice: .video), base: base, source: .screen
        )
        #expect(request.options.countdownSeconds == 0)
        #expect(request.autoStopAfter == 2)
        #expect(request.outputURL?.path == "/tmp/x.mp4")

        let keeps = RecordingCoordinator.makeRequest(
            target: area, options: RecordingCommandOptions(), selection: RecordingHUDSelection(choice: .video), base: base, source: .screen
        )
        #expect(keeps.options.countdownSeconds == 3)
    }

    @Test func selectionWithoutHUD() {
        #expect(RecordingCoordinator.hudSelection(for: RecordingCommandOptions()).choice == .video)
        #expect(RecordingCoordinator.hudSelection(for: RecordingCommandOptions(format: .gif)).choice == .gif)
        #expect(RecordingCoordinator.hudSelection(for: RecordingCommandOptions(format: .video)).choice == .video)
        // Studio wins over the format.
        #expect(RecordingCoordinator.hudSelection(for: RecordingCommandOptions(format: .gif, studio: true)).choice == .studio)
    }

    @Test func chromePlan() {
        var options = RecordingOptions.default
        options.dimScreen = true
        options.showControls = true
        #expect(RecordingCoordinator.chromePlan(target: area, options: options)
            == RecordingChromePlan(showsDimmer: true, showsBorder: true, showsControlBar: true))
        #expect(RecordingCoordinator.chromePlan(target: .window(42), options: options)
            == RecordingChromePlan(showsDimmer: true, showsBorder: true, showsControlBar: true))
        // Fullscreen: no dimmer, no border; the bar still follows the setting.
        #expect(RecordingCoordinator.chromePlan(target: .display(1), options: options)
            == RecordingChromePlan(showsDimmer: false, showsBorder: false, showsControlBar: true))

        options.dimScreen = false
        options.showControls = false
        #expect(RecordingCoordinator.chromePlan(target: area, options: options)
            == RecordingChromePlan(showsDimmer: false, showsBorder: true, showsControlBar: false))
        #expect(RecordingCoordinator.chromePlan(target: .display(1), options: options)
            == RecordingChromePlan(showsDimmer: false, showsBorder: false, showsControlBar: false))
    }

    @Test func lastRectRoundTrip() {
        let rect = GlobalRect(x: 12.5, y: -40, width: 640, height: 360)
        let text = RecordingCoordinator.lastRectString(rect)
        #expect(RecordingCoordinator.parseLastRect(text) == rect)
        #expect(RecordingCoordinator.parseLastRect("") == nil)
        #expect(RecordingCoordinator.parseLastRect("1,2,3") == nil)
        #expect(RecordingCoordinator.parseLastRect("1,2,0,5") == nil)
        #expect(RecordingCoordinator.parseLastRect("a,b,c,d") == nil)
    }

    @Test func countdownRect() {
        let main = DisplayDescriptor(id: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScaleFactor: 2)
        let second = DisplayDescriptor(id: 2, appKitFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), backingScaleFactor: 1)
        let layout = DisplayLayout(displays: [main, second], mainDisplayID: 1)
        let window = GlobalRect(x: 300, y: 200, width: 500, height: 400)

        #expect(RecordingCoordinator.countdownRect(for: area, layout: layout) { _ in nil }
            == GlobalRect(x: 100, y: 100, width: 640, height: 360))
        #expect(RecordingCoordinator.countdownRect(for: .window(7), layout: layout) { $0 == 7 ? window : nil } == window)
        let display2 = RecordingCoordinator.countdownRect(for: .display(2), layout: layout) { _ in nil }
        #expect(display2?.width == 1920)
        #expect(display2?.height == 1080)
        #expect(RecordingCoordinator.countdownRect(for: .display(99), layout: layout) { _ in nil } == nil)
    }

    @Test func followerRectBackToGlobal() {
        let displayFrame = GlobalRect(x: 1440, y: -200, width: 1920, height: 1080)
        let rect = RecordingCoordinator.globalRect(local: CGRect(x: 10, y: 20, width: 300, height: 200), displayFrame: displayFrame)
        #expect(rect == GlobalRect(x: 1450, y: -180, width: 300, height: 200))
    }

    @Test @MainActor func idleCoordinatorIgnoresControlCommands() async {
        let coordinator = RecordingCoordinator()
        for command: AppCommand in [.stopRecording, .pauseRecording, .resumeRecording, .togglePauseRecording, .restartRecording, .discardRecording(confirm: false)] {
            await coordinator.run(command)
            #expect(coordinator.phase == .idle)
        }
        #expect(!coordinator.isRecording)
        #expect(!coordinator.isPaused)
        #expect(!coordinator.isBusy)
    }
}

@Suite("Recording menu")
struct RecordingMenuTests {
    private func titles(_ entries: [MenuEntry]) -> [String] {
        entries.compactMap { entry in
            if case let .command(title, _, _, _, _, _, _) = entry { return title }
            return nil
        }
    }

    @Test @MainActor func idleMenuHasRecordEntries() {
        let entries = titles(MenuBuilder.entries(for: MenuState()))
        #expect(entries.contains("Record Screen"))
        #expect(entries.contains("Record GIF"))
        #expect(entries.contains("Record in Studio Mode"))
        #expect(!entries.contains("Stop Recording"))
    }

    @Test @MainActor func recordingMenu() {
        let recording = titles(MenuBuilder.entries(for: MenuState(isRecording: true)))
        #expect(recording == ["Stop Recording", "Pause Recording", "Restart Recording", "Discard Recording…", "Settings…"])
        let paused = titles(MenuBuilder.entries(for: MenuState(isRecording: true, isRecordingPaused: true)))
        #expect(paused.contains("Resume Recording"))
        #expect(!paused.contains("Pause Recording"))
    }

    @Test @MainActor func busyMenuDisablesRecord() {
        for entry in MenuBuilder.entries(for: MenuState(recordingBusy: true)) {
            if case let .command(title, _, _, _, _, enabled, _) = entry, title.hasPrefix("Record") {
                #expect(!enabled, "\(title)")
            }
        }
    }
}

@Suite("Recording URLs (R1)")
struct RecordingControlURLTests {
    private func parse(_ string: String) throws -> AppCommand {
        try URLSchemeHandler.parse(#require(URL(string: string)))
    }

    @Test func controlCommands() throws {
        #expect(try parse("hakoshot://pause-recording") == .pauseRecording)
        #expect(try parse("hakoshot://resume-recording") == .resumeRecording)
        #expect(try parse("hakoshot://toggle-pause-recording") == .togglePauseRecording)
        #expect(try parse("hakoshot://toggle-recording-pause") == .togglePauseRecording)
        #expect(try parse("hakoshot://restart-recording") == .restartRecording)
        #expect(try parse("hakoshot://discard-recording") == .discardRecording(confirm: false))
        #expect(try parse("hakoshot://stop-recording") == .stopRecording)
    }

    @Test func recordScreenTargets() throws {
        #expect(try parse("hakoshot://record-screen?mode=fullscreen&display=2")
            == .record(.fullscreen, RecordingCommandOptions(display: 2)))
        #expect(try parse("hakoshot://record-screen?mode=window&window=frontmost&start=true&duration=3")
            == .record(.window, RecordingCommandOptions(start: true, autoStopAfter: 3, window: "frontmost")))
        // `window=` alone means window mode.
        #expect(try parse("hakoshot://record-screen?window=test") == .record(.window, RecordingCommandOptions(window: "test")))
        #expect(try parse("hakoshot://record-screen?window=1234&mode=window") == .record(.window, RecordingCommandOptions(window: "1234")))
        #expect(try parse("hakoshot://record-screen?countdown=3") == .record(.area, RecordingCommandOptions(countdownSeconds: 3)))
        #expect(throws: URLSchemeError.self) { try parse("hakoshot://record-screen?window=nope") }
        #expect(throws: URLSchemeError.self) { try parse("hakoshot://record-screen?countdown=-1") }
    }

    @Test func debugCommands() throws {
        #expect(try parse("hakoshot://debug-recording-state?out=/tmp/s.json") == .debugRecordingState(URL(fileURLWithPath: "/tmp/s.json")))
        #expect(throws: URLSchemeError.self) { try parse("hakoshot://debug-recording-state") }

        guard case let .debugRecordingChrome(chrome) = try parse("hakoshot://debug-recording-chrome?x=1&y=2&width=300&height=200&snapshot=/tmp/c") else {
            Issue.record("expected debugRecordingChrome")
            return
        }
        #expect(chrome.rect == CGRect(x: 1, y: 2, width: 300, height: 200))
        #expect(chrome.snapshotDir.path == "/tmp/c")
        #expect(throws: URLSchemeError.self) { try parse("hakoshot://debug-recording-chrome?x=1&y=2&width=300&height=200") }

        guard case let .debugRecordingHUD(hud) = try parse("hakoshot://debug-recording-hud?x=0&y=0&width=800&height=450&snapshot=/tmp/h.png&menu=format") else {
            Issue.record("expected debugRecordingHUD")
            return
        }
        #expect(hud.rect.size == CGSize(width: 800, height: 450))
        #expect(hud.menu == "format")

        #expect(try parse("hakoshot://debug-move-test-window?x=10&y=20&width=400&height=300&dx=5&seconds=4")
            == .debugMoveTestWindow(RecordingTargetDebug.MoveParameters(rect: CGRect(x: 10, y: 20, width: 400, height: 300), dx: 5, seconds: 4)))
        #expect(try parse("hakoshot://debug-close-test-window") == .debugCloseTestWindow)
        #expect(try parse("hakoshot://debug-record-window?window=frontmost&seconds=2")
            == .debugRecordWindow(RecordingTargetDebug.RecordWindowParameters(window: .frontmost, seconds: 2)))
    }
}
