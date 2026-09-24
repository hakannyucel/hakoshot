import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

@Suite("QuickAccessLayout")
struct QuickAccessLayoutTests {
    @Test func cardSizeKeepsAspectWithinClamp() {
        #expect(QuickAccessLayout.cardSize(imageSize: CGSize(width: 800, height: 500), width: 200) == CGSize(width: 200, height: 125))
        // Very wide → clamped to minAspect.
        #expect(QuickAccessLayout.cardSize(imageSize: CGSize(width: 4000, height: 100), width: 200) == CGSize(width: 200, height: 80))
        // Very tall (scrolling capture) → clamped to maxAspect.
        #expect(QuickAccessLayout.cardSize(imageSize: CGSize(width: 800, height: 20_000), width: 200) == CGSize(width: 200, height: 250))
        // Degenerate size falls back.
        #expect(QuickAccessLayout.cardSize(imageSize: .zero, width: 200).height == 125)
    }

    @Test func stackGrowsUpFromBottomLeftNewestOnTop() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let sizes = [CGSize(width: 200, height: 125), CGSize(width: 200, height: 200), CGSize(width: 200, height: 80)]
        let frames = QuickAccessLayout.cardFrames(sizes: sizes, in: screen, position: .left, inset: 20, gap: 12)
        #expect(frames.count == 3)
        #expect(frames[0] == CGRect(x: 20, y: 45, width: 200, height: 125))
        #expect(frames[1] == CGRect(x: 20, y: 45 + 125 + 12, width: 200, height: 200))
        #expect(frames[2].minY == frames[1].maxY + 12)
        // Newest (last) is the top-most card.
        #expect(frames[2].minY > frames[0].minY)
    }

    @Test func rightPositionAlignsToRightEdgeOfThatScreen() {
        let screen = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        let frames = QuickAccessLayout.cardFrames(sizes: [CGSize(width: 240, height: 150)], in: screen, position: .right, inset: 20, gap: 12)
        #expect(frames[0] == CGRect(x: 1440 + 2560 - 20 - 240, y: 20, width: 240, height: 150))
    }

    @Test func offscreenFrameIsPastTheAnchoredEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let card = CGRect(x: 20, y: 20, width: 200, height: 125)
        let left = QuickAccessLayout.offscreenFrame(for: card, in: screen, position: .left)
        #expect(left.maxX < screen.minX)
        #expect(left.minY == card.minY)
        let right = QuickAccessLayout.offscreenFrame(for: card, in: screen, position: .right)
        #expect(right.minX > screen.maxX)
    }

    @Test func panelFrameAddsShadowMargin() {
        let card = CGRect(x: 20, y: 20, width: 200, height: 125)
        let panel = QuickAccessLayout.panelFrame(forCard: card)
        #expect(panel.width == 200 + 2 * QuickAccessLayout.shadowMargin)
        #expect(panel.midX == card.midX)
    }
}

@Suite("QuickAccessKeyMap")
struct QuickAccessKeyMapTests {
    private func action(_ chars: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> QuickAccessAction? {
        QuickAccessKeyMap.action(keyCode: keyCode, characters: chars, modifiers: flags)
    }

    @Test func commandShortcuts() {
        #expect(action("c", .command) == .copy(keepOpen: false))
        #expect(action("c", [.command, .option]) == .copy(keepOpen: true))
        #expect(action("s", .command) == .save)
        #expect(action("S", [.command, .shift]) == .saveAs)
        #expect(action("e", .command) == .edit)
        #expect(action("p", .command) == .pin)
        #expect(action("w", .command) == .close)
        #expect(action("w", [.command, .option]) == .closeAll)
    }

    @Test func plainKeys() {
        #expect(action("\u{1b}", [], keyCode: QuickAccessKeyMap.escapeKeyCode) == .close)
        #expect(action("\r", [], keyCode: QuickAccessKeyMap.returnKeyCode) == .saveAndClose)
        #expect(action("c", []) == nil)
    }

    @Test func unrelatedCombosAreIgnored() {
        #expect(action("c", [.command, .control]) == nil)
        #expect(action("x", .command) == nil)
        #expect(action("e", [.command, .shift]) == nil)
        // Caps Lock / function flags don't matter.
        #expect(action("s", [.command, .capsLock]) == .save)
    }
}

@Suite("QuickAccessConfig")
struct QuickAccessConfigTests {
    @Test func planDefaults() {
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        let config = QuickAccessConfig(settings: scratch.settings)
        #expect(config.position == .left)
        #expect(config.moveToActiveScreen)
        #expect(config.cardWidth == 200)
        #expect(config.autoCloseEnabled)
        #expect(config.autoCloseSeconds == 30)
        #expect(config.autoCloseInterval == 30)
        #expect(config.autoCloseAction == .saveAndClose)
        #expect(config.closeAfterDragging)
        #expect(config.saveBehavior == .exportLocation)
    }

    @Test func clampsOutOfRangeValues() {
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        scratch.settings.set(1000, for: .quickAccessCardWidth)
        scratch.settings.set(0, for: .quickAccessAutoCloseSeconds)
        scratch.settings.set(false, for: .quickAccessAutoCloseEnabled)
        scratch.settings.set(QuickAccessPosition.right, for: .quickAccessPosition)
        let config = QuickAccessConfig(settings: scratch.settings)
        #expect(config.cardWidth == 320)
        #expect(config.autoCloseSeconds == 3)
        #expect(config.autoCloseInterval == nil)
        #expect(config.position == .right)
    }
}

@Suite("QuickAccessController", .serialized)
struct QuickAccessControllerTests {
    private final class Harness {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hakanyucel.hakoshot.tests.\(UUID().uuidString)"))
        let controller: QuickAccessController

        init(autoCloseSeconds: Int? = nil) {
            scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
            if let autoCloseSeconds {
                scratchSettings.settings.set(autoCloseSeconds, for: .quickAccessAutoCloseSeconds)
            } else {
                scratchSettings.settings.set(false, for: .quickAccessAutoCloseEnabled)
            }
            controller = QuickAccessController(
                settings: scratchSettings.settings,
                clipboardWriter: ClipboardWriter(pasteboard: pasteboard),
                animates: false
            )
        }

        func cleanup() {
            controller.closeAll()
            pasteboard.releaseGlobally()
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }

        func savedFiles() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: scratchDir.url, includingPropertiesForKeys: nil)) ?? []
        }
    }

    @Test func stacksCardsAndCapsVisibleCount() {
        let harness = Harness()
        defer { harness.cleanup() }
        for _ in 0..<3 { harness.controller.show(PostCaptureFixture.captureResult()) }
        #expect(harness.controller.visibleCount == 3)

        for _ in 0..<5 { harness.controller.show(PostCaptureFixture.captureResult()) }
        #expect(harness.controller.visibleCount == QuickAccessConfig.maxVisibleCards)
        // Evicted cards used the auto-close action (Save and Close by default).
        #expect(harness.savedFiles().count == 2)
    }

    @Test func closeAllAndRestoreLastClosed() {
        let harness = Harness()
        defer { harness.cleanup() }
        var closed: [URL?] = []
        harness.controller.onClosed = { _, url in closed.append(url) }

        harness.controller.show(PostCaptureFixture.captureResult(pointWidth: 10))
        harness.controller.show(PostCaptureFixture.captureResult(pointWidth: 20))
        harness.controller.closeAll()
        #expect(harness.controller.visibleCount == 0)
        #expect(closed.count == 2)
        #expect(harness.savedFiles().isEmpty)   // Close all never saves

        #expect(harness.controller.restoreLastClosed())
        #expect(harness.controller.visibleCount == 1)
        #expect(harness.controller.restoreLastClosed())
        #expect(harness.controller.visibleCount == 2)
        #expect(!harness.controller.restoreLastClosed())
    }

    @Test func historyEventsFollowTheCard() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        var events: [QuickAccessHistoryEvent] = []
        harness.controller.onHistoryEvent = { events.append($0) }

        let historyID = UUID()
        let id = harness.controller.show(PostCaptureFixture.captureResult(), historyID: historyID)
        harness.controller.perform(.save, on: id)
        #expect(events.count == 2)
        guard case .saved(let savedID, _) = events.first else {
            Issue.record("expected .saved first, got \(events)")
            return
        }
        #expect(savedID == historyID)
        #expect(events.last == .closed(historyID: historyID))

        #expect(harness.controller.restoreLastClosed())
        #expect(events.last == .restored(historyID: historyID))

        // Cards without a history id report nothing.
        events.removeAll()
        harness.controller.show(PostCaptureFixture.captureResult())
        harness.controller.closeAll()
        #expect(events == [.closed(historyID: historyID)])
    }

    @Test func saveWritesFileAndClosesWithURL() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        var closedURL: URL?
        var savedURL: URL?
        harness.controller.onClosed = { _, url in closedURL = url }
        harness.controller.onSaved = { _, url in savedURL = url }

        let id = harness.controller.show(PostCaptureFixture.captureResult())
        harness.controller.perform(.save, on: id)

        #expect(harness.controller.visibleCount == 0)
        let url = try #require(savedURL)
        #expect(closedURL == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func copyKeepOpenWritesPasteboardAndKeepsCard() {
        let harness = Harness()
        defer { harness.cleanup() }
        let id = harness.controller.show(PostCaptureFixture.captureResult())
        harness.controller.perform(.copy(keepOpen: true), on: id)
        #expect(harness.pasteboard.data(forType: .png) != nil)
        #expect(harness.controller.visibleCount == 1)
    }

    @Test func editAndPinCallHooksAndClose() {
        let harness = Harness()
        defer { harness.cleanup() }
        var edited = 0
        var pinned = 0

        let first = harness.controller.show(PostCaptureFixture.captureResult())
        // No hook yet → card stays (Edit is a stub until M4).
        harness.controller.perform(.edit, on: first)
        #expect(harness.controller.visibleCount == 1)

        harness.controller.onEdit = { _ in edited += 1 }
        harness.controller.onPin = { _ in pinned += 1 }
        harness.controller.perform(.edit, on: first)
        let second = harness.controller.show(PostCaptureFixture.captureResult())
        harness.controller.perform(.pin, on: second)

        #expect(edited == 1)
        #expect(pinned == 1)
        #expect(harness.controller.visibleCount == 0)
    }

    @Test func autoCloseSavesAndCloses() async throws {
        let harness = Harness(autoCloseSeconds: 3)
        defer { harness.cleanup() }
        harness.controller.show(PostCaptureFixture.captureResult())
        #expect(harness.controller.visibleCount == 1)
        // Poll: the main actor may be busy with other suites running in parallel.
        let deadline = Date(timeIntervalSinceNow: 8)
        while harness.controller.visibleCount > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(harness.controller.visibleCount == 0)
        #expect(harness.savedFiles().count == 1)
    }

    @Test func dragFileHasTemplateName() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let result = PostCaptureFixture.captureResult()
        let url = try DragSource.writeDragFile(for: result, template: .default, modeToken: "area", in: dir.url)
        #expect(url.pathExtension == "png")
        #expect(url.lastPathComponent.hasPrefix("HakoShot "))
        let data = try Data(contentsOf: url)
        let image = try #require(ImageEncoder.decode(data))
        #expect(image.width == result.image.width)
    }
}
