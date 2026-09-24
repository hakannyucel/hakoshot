import AppKit
import Foundation
import Testing
@testable import HakoShot

@Suite("PostCaptureRouter")
struct PostCaptureRouterTests {
    private func makeRouter(
        settings: AppSettings,
        pasteboard: NSPasteboard
    ) -> PostCaptureRouter {
        PostCaptureRouter(
            settings: settings,
            outputService: OutputService(settings: settings),
            clipboardWriter: ClipboardWriter(pasteboard: pasteboard)
        )
    }

    private func makePrivatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.hakanyucel.hakoshot.tests.router.\(UUID().uuidString)"))
    }

    @Test func defaultRouteSavesAndCopiesWhenBothSettingsOn() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(true, for: .outputSaveToDiskOnCapture)
        scratchSettings.settings.set(true, for: .outputCopyToClipboardOnCapture)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let outcome = try router.route(PostCaptureFixture.captureResult())

        #expect(outcome.copiedToClipboard)
        let savedURL = try #require(outcome.savedURL)
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test func saveOverrideOnlySaves() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let outcome = try router.route(PostCaptureFixture.captureResult(), overriding: .save)

        #expect(!outcome.copiedToClipboard)
        #expect(pasteboard.data(forType: .png) == nil)
        let savedURL = try #require(outcome.savedURL)
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
    }

    @Test func copyOverrideOnlyCopiesByDefault() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(false, for: .outputCopyAlsoSavesToDisk)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let outcome = try router.route(PostCaptureFixture.captureResult(), overriding: .copy)

        #expect(outcome.copiedToClipboard)
        #expect(outcome.savedURL == nil)
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test func copyOverrideAlsoSavesWhenConfigured() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(true, for: .outputCopyAlsoSavesToDisk)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let outcome = try router.route(PostCaptureFixture.captureResult(), overriding: .copy)

        #expect(outcome.copiedToClipboard)
        let savedURL = try #require(outcome.savedURL)
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
    }

    @Test func annotateWithoutEditorFallsBackToDefaultRoute() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(true, for: .outputSaveToDiskOnCapture)
        scratchSettings.settings.set(true, for: .outputCopyToClipboardOnCapture)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let recorder = DestinationRecorder()
        router.destinations = recorder.destinations()

        let outcome = try router.route(PostCaptureFixture.captureResult(), overriding: .annotate)
        #expect(outcome.savedURL != nil)
        #expect(outcome.copiedToClipboard)
        #expect(!outcome.openedInEditor)
        #expect(recorder.cards.count == 1)
    }

    @Test func defaultsShowQuickAccessOnlyAndRecordHistory() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        #expect(AfterCaptureConfig(settings: scratchSettings.settings) == .default)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let recorder = DestinationRecorder()
        router.destinations = recorder.destinations()
        let outcome = try router.route(PostCaptureFixture.captureResult())

        #expect(outcome.savedURL == nil)
        #expect(!outcome.copiedToClipboard)
        #expect(pasteboard.data(forType: .png) == nil)
        #expect(!outcome.pinned)
        let historyID = try #require(outcome.historyID)
        #expect(recorder.historyIDs == [historyID])
        #expect(recorder.cards.count == 1)
        #expect(recorder.cards.first?.historyID == historyID)
        #expect(outcome.quickAccessCardID == recorder.cards.first?.cardID)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: scratchDir.url.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func savedFileIsHandedToQuickAccessAndPinRuns() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(true, for: .outputSaveToDiskOnCapture)
        scratchSettings.settings.set(true, for: .afterCapturePin)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let recorder = DestinationRecorder()
        router.destinations = recorder.destinations()
        let outcome = try router.route(PostCaptureFixture.captureResult())

        let savedURL = try #require(outcome.savedURL)
        #expect(recorder.cards.first?.savedURL == savedURL)
        #expect(recorder.pins == 1)
        #expect(outcome.pinned)
    }

    @Test func overridesSkipQuickAccess() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let recorder = DestinationRecorder()
        router.destinations = recorder.destinations()

        let saved = try router.route(PostCaptureFixture.captureResult(), overriding: .save)
        #expect(saved.savedURL != nil)
        let pinned = try router.route(PostCaptureFixture.captureResult(), overriding: .pin)
        #expect(pinned.pinned)
        #expect(pinned.savedURL == nil)

        #expect(recorder.cards.isEmpty)
        #expect(recorder.pins == 1)
        #expect(recorder.historyIDs.count == 2)
    }

    @Test func defaultRouteDoesNothingWhenBothSettingsOff() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = makePrivatePasteboard()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
            pasteboard.releaseGlobally()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(false, for: .outputSaveToDiskOnCapture)
        scratchSettings.settings.set(false, for: .outputCopyToClipboardOnCapture)

        let router = makeRouter(settings: scratchSettings.settings, pasteboard: pasteboard)
        let outcome = try router.route(PostCaptureFixture.captureResult())

        #expect(outcome == .none)
    }
}

/// Records what `PostCaptureRouter` sends to its destinations.
private final class DestinationRecorder {
    struct Card {
        let cardID: UUID
        let savedURL: URL?
        let historyID: UUID?
    }

    var historyIDs: [UUID] = []
    var cards: [Card] = []
    var pins = 0

    func destinations() -> PostCaptureDestinations {
        PostCaptureDestinations(
            addToHistory: { [self] _, _ in
                let id = UUID()
                historyIDs.append(id)
                return id
            },
            showQuickAccess: { [self] _, savedURL, historyID in
                let id = UUID()
                cards.append(Card(cardID: id, savedURL: savedURL, historyID: historyID))
                return id
            },
            pin: { [self] _ in pins += 1 }
        )
    }
}
