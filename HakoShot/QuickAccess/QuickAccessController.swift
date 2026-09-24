import AppKit
import Foundation
import HakoKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Manages the Quick Access card stack (plan §3.2, §4.12, §5.4): one floating,
/// non-activating panel per card, newest on top, bottom-left by default, auto-close
/// (Save and Close after 30 s; hover pauses it), drag and drop, keyboard shortcuts.
///
/// Actions it can't perform itself go through the closures below so the M2
/// integration can connect the editor, Pin and History.
final class QuickAccessController {
    private static let log = Logger(subsystem: "com.hakanyucel.HakoShot", category: "quick-access")
    /// How many closed cards `restoreLastClosed()` remembers.
    static let recentlyClosedLimit = 20
    /// After the pointer leaves a card, auto-close waits at least this long.
    static let minimumResumeInterval: TimeInterval = 2

    // MARK: Integration hooks

    /// Edit / ⌘E / "Open in Editor". `nil` = editor not available yet (card stays open).
    /// The request carries the card's saved file and History entry so the
    /// editor's ⌘S updates the right file and history record.
    var onEdit: ((QuickAccessEditRequest) -> Void)?
    /// Pin / ⌘P. `nil` = Pin not available yet (card stays open).
    var onPin: ((CaptureResult) -> Void)?
    /// Every time a card leaves the screen (any reason), with where it was saved, if anywhere.
    var onClosed: ((CaptureResult, _ savedURL: URL?) -> Void)?
    /// Every time a card writes the capture to disk (Save, Save As, auto-close, Show in Finder).
    var onSaved: ((CaptureResult, URL) -> Void)?
    /// History bookkeeping for cards shown with a `historyID` (WP2.I): closed, saved, restored.
    var onHistoryEvent: ((QuickAccessHistoryEvent) -> Void)?

    // MARK: State

    private final class Entry {
        let card: QuickAccessCard
        let panel: QuickAccessPanel
        let container: QuickAccessContainerView
        /// `HistoryStore` entry this card belongs to, if any.
        var historyID: UUID?
        var autoCloseTask: Task<Void, Never>?
        var deadline: Date?
        var remaining: TimeInterval?
        var isClosing = false
        /// Save panel open, drag in flight, …: auto-close must not fire.
        var isBusy = false
        var dragSource: DragSource?

        init(card: QuickAccessCard, panel: QuickAccessPanel, container: QuickAccessContainerView) {
            self.card = card
            self.panel = panel
            self.container = container
        }
    }

    private struct ClosedCard {
        let result: CaptureResult
        let savedURL: URL?
        let historyID: UUID?
    }

    private let settings: AppSettings
    private let outputService: OutputService
    private let clipboardWriter: ClipboardWriter
    private let animates: Bool
    /// Oldest → newest.
    private var entries: [Entry] = []
    private var recentlyClosed: [ClosedCard] = []
    private var screenFrame: CGRect = .zero
    private var config = QuickAccessConfig()

    init(
        settings: AppSettings = .shared,
        outputService: OutputService? = nil,
        clipboardWriter: ClipboardWriter = ClipboardWriter(),
        animates: Bool = true
    ) {
        self.settings = settings
        self.outputService = outputService ?? OutputService(settings: settings)
        self.clipboardWriter = clipboardWriter
        self.animates = animates
        Task.detached(priority: .background) { DragSource.purgeOldDragFiles() }
    }

    // MARK: Public API

    /// Number of cards currently on screen.
    var visibleCount: Int { entries.count }
    /// Captures currently shown, oldest → newest.
    var visibleResults: [CaptureResult] { entries.map(\.card.result) }
    /// Whether `restoreLastClosed()` has something to bring back.
    var canRestore: Bool { !recentlyClosed.isEmpty }

    /// Shows a card for `result`. Pass `savedURL` if the capture was already written to
    /// disk (e.g. a History restore) and `historyID` to get `onHistoryEvent` callbacks
    /// for it. Returns the card id.
    @discardableResult
    func show(_ result: CaptureResult, savedURL: URL? = nil, historyID: UUID? = nil) -> UUID {
        config = QuickAccessConfig(settings: settings)
        screenFrame = targetScreen(for: result).visibleFrame

        let card = QuickAccessCard(result: result, savedURL: savedURL, width: config.cardWidth)
        let panelFrame = QuickAccessLayout.panelFrame(forCard: CGRect(origin: .zero, size: card.size))
        let panel = QuickAccessPanel(contentRect: panelFrame)
        let id = card.id

        let view = QuickAccessCardView(
            card: card,
            onAction: { [weak self] action in self?.perform(action, on: id) },
            onDragStart: { [weak self] in self?.beginDrag(id) }
        )
        let container = QuickAccessContainerView(rootView: view)
        container.frame = NSRect(origin: .zero, size: panelFrame.size)
        panel.contentView = container
        container.onHoverChanged = { [weak self] hovering in self?.hoverChanged(id, hovering: hovering) }
        panel.onKeyAction = { [weak self] action in self?.perform(action, on: id) }

        let entry = Entry(card: card, panel: panel, container: container)
        entry.historyID = historyID
        entries.append(entry)
        prepareDragFile(for: card)

        // Plan §4.12: at most 6 visible; the oldest leaves with the auto-close action.
        while entries.count > QuickAccessConfig.maxVisibleCards, let oldest = entries.first {
            autoClose(oldest)
        }

        layout(newEntry: entry)
        startAutoClose(entry, interval: config.autoCloseInterval)
        Self.log.notice("show card \(id.uuidString, privacy: .public), \(self.entries.count) visible")
        return id
    }

    /// Closes every card without saving (they can still be restored).
    func closeAll() {
        for entry in entries.reversed() {
            close(entry)
        }
    }

    /// Re-shows the most recently closed card. Returns `false` if there is none.
    @discardableResult
    func restoreLastClosed() -> Bool {
        guard let last = recentlyClosed.popLast() else { return false }
        show(last.result, savedURL: last.savedURL, historyID: last.historyID)
        if let historyID = last.historyID { onHistoryEvent?(.restored(historyID: historyID)) }
        return true
    }

    #if DEBUG
    /// DEBUG automation: runs `action` on the newest card. Returns `false` if none.
    @discardableResult
    func debugPerformOnNewest(_ action: QuickAccessAction) -> Bool {
        guard let newest = entries.last else { return false }
        perform(action, on: newest.card.id)
        return true
    }
    #endif

    /// Performs `action` on the card `id` (also used by the view, keys and context menu).
    func perform(_ action: QuickAccessAction, on id: UUID) {
        guard let entry = entry(id), !entry.isClosing else { return }
        switch action {
        case .copy(let keepOpen):
            copy(entry, keepOpen: keepOpen)
        case .save, .saveAndClose:
            if entry.card.savedURL != nil {
                close(entry)
                return
            }
            switch config.saveBehavior {
            case .exportLocation:
                if saveToExportLocation(entry) != nil { close(entry) }
            case .askForDestination:
                saveAs(entry)
            }
        case .saveAs:
            saveAs(entry)
        case .edit:
            guard let onEdit else {
                Self.log.notice("edit: editor not available yet")
                NSSound.beep()
                return
            }
            onEdit(QuickAccessEditRequest(result: entry.card.result, savedURL: entry.card.savedURL, historyID: entry.historyID))
            close(entry)
        case .pin:
            guard let onPin else {
                Self.log.notice("pin: Pin not available yet")
                NSSound.beep()
                return
            }
            onPin(entry.card.result)
            close(entry)
        case .showInFinder:
            if let url = saveToExportLocation(entry) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .close:
            close(entry)
        case .closeAll:
            closeAll()
        }
    }

    // MARK: Actions

    private func copy(_ entry: Entry, keepOpen: Bool) {
        do {
            try clipboardWriter.write(entry.card.result.image, fileURL: entry.card.savedURL)
        } catch {
            Self.log.error("copy failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }
        entry.card.copyFlashCount += 1
        guard !keepOpen else { return }
        entry.isClosing = true
        cancelAutoClose(entry)
        let delay = animates ? Tokens.Duration.copyFlash : 0
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self?.close(entry, force: true)
        }
    }

    /// Saves to the export folder unless already saved. Returns the file URL, or `nil`
    /// on failure (logged + beep; the card stays).
    @discardableResult
    private func saveToExportLocation(_ entry: Entry) -> URL? {
        if let saved = entry.card.savedURL { return saved }
        do {
            let url = try outputService.save(entry.card.result)
            entry.card.savedURL = url
            onSaved?(entry.card.result, url)
            if let historyID = entry.historyID { onHistoryEvent?(.saved(historyID: historyID, url: url)) }
            Self.log.notice("saved \(url.path, privacy: .public)")
            return url
        } catch {
            Self.log.error("save failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    private func saveAs(_ entry: Entry) {
        let format = settings.value(for: .outputImageFormat)
        let result = entry.card.result
        let pattern = settings.value(for: .outputFileNameTemplate)
        let namer = FileNamer(
            template: FileNameTemplate(pattern: pattern),
            pathExtension: format.fileExtension,
            clock: { [date = result.date] in date }
        )
        let panel = NSSavePanel()
        // `%n` suggestion: the next counter value; it advances only once the file is written.
        panel.nameFieldStringValue = namer.fileName(counter: FileNameCounter.peek(settings: settings), mode: result.mode.fileNameToken)
        if let type = UTType(format.utTypeIdentifier) { panel.allowedContentTypes = [type] }
        panel.directoryURL = URL(
            fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath,
            isDirectory: true
        )
        entry.isBusy = true
        cancelAutoClose(entry)
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                entry.isBusy = false
                guard response == .OK, let url = panel.url else {
                    self.resumeAutoClose(entry)
                    return
                }
                do {
                    let data = try ImageEncoder.encode(
                        result.image,
                        format: format,
                        options: ImageEncodeOptions(
                            compressionQuality: CGFloat(self.settings.outputQuality(for: format)),
                            dpi: 72 * result.scale
                        )
                    )
                    try data.write(to: url, options: .atomic)
                    _ = FileNameCounter.take(pattern: pattern, settings: self.settings)
                    entry.card.savedURL = url
                    self.onSaved?(result, url)
                    if let historyID = entry.historyID { self.onHistoryEvent?(.saved(historyID: historyID, url: url)) }
                    self.close(entry)
                } catch {
                    Self.log.error("save as failed: \(String(describing: error), privacy: .public)")
                    NSSound.beep()
                    self.resumeAutoClose(entry)
                }
            }
        }
    }

    /// Auto-close / eviction: apply the configured action, then close.
    private func autoClose(_ entry: Entry) {
        if config.autoCloseAction == .saveAndClose {
            saveToExportLocation(entry)
        }
        close(entry, force: true)
    }

    private func close(_ entry: Entry, force: Bool = false) {
        guard let index = entries.firstIndex(where: { $0 === entry }) else { return }
        if entry.isClosing && !force { return }
        entry.isClosing = true
        cancelAutoClose(entry)
        entries.remove(at: index)
        handBackKeyFocus(from: entry.panel)

        recentlyClosed.append(ClosedCard(result: entry.card.result, savedURL: entry.card.savedURL, historyID: entry.historyID))
        if recentlyClosed.count > Self.recentlyClosedLimit {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.recentlyClosedLimit)
        }

        let panel = entry.panel
        let cardFrame = panel.frame.insetBy(dx: QuickAccessLayout.shadowMargin, dy: QuickAccessLayout.shadowMargin)
        let offscreen = QuickAccessLayout.panelFrame(
            forCard: QuickAccessLayout.offscreenFrame(for: cardFrame, in: screenFrame, position: config.position)
        )
        if animates {
            DSAnimation.run(.quickAccessSlideIn) { _ in
                panel.animator().setFrame(offscreen, display: true)
                panel.animator().alphaValue = 0
            } completion: {
                // Runs even if the animation never finishes (displays asleep): see `DSAnimation.run`.
                panel.alphaValue = 0
                panel.orderOut(nil)
                panel.contentView = nil
            }
        } else {
            panel.orderOut(nil)
            panel.contentView = nil
        }

        onClosed?(entry.card.result, entry.card.savedURL)
        if let historyID = entry.historyID { onHistoryEvent?(.closed(historyID: historyID)) }
        layout(newEntry: nil)
    }

    // MARK: Layout

    /// Positions all cards (animated). `newEntry` slides in from the screen edge.
    private func layout(newEntry: Entry?) {
        let frames = QuickAccessLayout.cardFrames(
            sizes: entries.map(\.card.size),
            in: screenFrame,
            position: config.position,
            inset: Tokens.Spacing.quickAccessScreenInset,
            gap: Tokens.Spacing.quickAccessStackGap
        )
        for (entry, cardFrame) in zip(entries, frames) {
            let target = QuickAccessLayout.panelFrame(forCard: cardFrame)
            if entry === newEntry {
                let start = QuickAccessLayout.panelFrame(
                    forCard: QuickAccessLayout.offscreenFrame(for: cardFrame, in: screenFrame, position: config.position)
                )
                entry.panel.setFrame(animates ? start : target, display: false)
                entry.panel.alphaValue = animates ? 0 : 1
                entry.panel.orderFrontRegardless()
                guard animates else { continue }
                DSAnimation.run(.quickAccessSlideIn) { _ in
                    entry.panel.animator().setFrame(target, display: true)
                    entry.panel.animator().alphaValue = 1
                }
            } else if entry.panel.frame != target {
                if animates {
                    DSAnimation.run(.quickAccessSlideIn) { _ in
                        entry.panel.animator().setFrame(target, display: true)
                    }
                } else {
                    entry.panel.setFrame(target, display: true)
                }
            }
        }
    }

    private func targetScreen(for result: CaptureResult) -> NSScreen {
        let screens = NSScreen.screens
        if config.moveToActiveScreen {
            let mouse = NSEvent.mouseLocation
            if let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
                return screen
            }
        }
        if let displayID = result.displayID,
           let screen = screens.first(where: { $0.displayID == displayID }) {
            return screen
        }
        return NSScreen.main ?? screens.first ?? NSScreen()
    }

    // MARK: Hover, keyboard focus

    /// Pointer entered/left card `id` (from the panel's tracking area).
    func hoverChanged(_ id: UUID, hovering: Bool) {
        guard let entry = entry(id), !entry.isClosing else { return }
        entry.card.isHovered = hovering
        if hovering {
            cancelAutoClose(entry)
            // Key while hovered so ⌘C/⌘S/⌘E/⌘W work; non-activating, so no focus steal.
            entry.panel.makeKey()
        } else {
            resumeAutoClose(entry)
            handBackKeyFocus(from: entry.panel)
        }
    }

    /// When the pointer leaves, give keyboard focus back to the app the user was in.
    private func handBackKeyFocus(from panel: QuickAccessPanel) {
        guard panel.isKeyWindow, !NSApp.isActive else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            front.activate()
        }
    }

    // MARK: Auto-close

    private func startAutoClose(_ entry: Entry, interval: TimeInterval?) {
        cancelAutoClose(entry)
        guard let interval else { return }
        entry.remaining = interval
        guard !entry.card.isHovered, !entry.isBusy, !entry.card.isDragging else { return }
        entry.deadline = Date(timeIntervalSinceNow: interval)
        entry.autoCloseTask = Task { @MainActor [weak self, weak entry] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self, let entry, !entry.isClosing else { return }
            Self.log.notice("auto-close card \(entry.card.id.uuidString, privacy: .public)")
            self.autoClose(entry)
        }
    }

    /// Stops the timer and remembers the time left.
    private func cancelAutoClose(_ entry: Entry) {
        if let deadline = entry.deadline {
            entry.remaining = max(0, deadline.timeIntervalSinceNow)
        }
        entry.deadline = nil
        entry.autoCloseTask?.cancel()
        entry.autoCloseTask = nil
    }

    private func resumeAutoClose(_ entry: Entry) {
        guard config.autoCloseEnabled, !entry.isClosing, let remaining = entry.remaining else { return }
        startAutoClose(entry, interval: max(remaining, Self.minimumResumeInterval))
    }

    // MARK: Drag and drop

    private func prepareDragFile(for card: QuickAccessCard) {
        guard card.savedURL == nil else { return }
        let result = card.result
        let template = FileNameTemplate(pattern: settings.value(for: .outputFileNameTemplate))
        let modeToken = result.mode.fileNameToken
        let counter = FileNameCounter.peek(settings: settings)
        Task { @MainActor [weak card] in
            let url = try? await Task.detached(priority: .userInitiated) {
                try DragSource.writeDragFile(for: result, template: template, modeToken: modeToken, counter: counter)
            }.value
            card?.dragFileURL = url
        }
    }

    private func beginDrag(_ id: UUID) {
        guard let entry = entry(id), !entry.isClosing, !entry.card.isDragging,
              let event = NSApp.currentEvent,
              [.leftMouseDragged, .leftMouseDown].contains(event.type)
        else { return }

        let card = entry.card
        let fileURL: URL
        if let url = card.savedURL ?? card.dragFileURL {
            fileURL = url
        } else {
            do {
                fileURL = try DragSource.writeDragFile(
                    for: card.result,
                    template: FileNameTemplate(pattern: settings.value(for: .outputFileNameTemplate)),
                    modeToken: card.result.mode.fileNameToken,
                    counter: FileNameCounter.peek(settings: settings)
                )
                card.dragFileURL = fileURL
            } catch {
                Self.log.error("drag file failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
        }

        card.isDragging = true
        entry.isBusy = true
        cancelAutoClose(entry)
        entry.dragSource = DragSource.begin(
            from: entry.container,
            event: event,
            fileURL: fileURL,
            preview: card.thumbnail,
            previewFrame: entry.container.cardRect
        ) { [weak self, weak entry] dropped in
            guard let self, let entry else { return }
            entry.dragSource = nil
            entry.card.isDragging = false
            entry.isBusy = false
            if dropped && self.config.closeAfterDragging {
                self.close(entry)
            } else {
                entry.card.isHovered = entry.container.isPointerInsideCard
                if !entry.card.isHovered { self.resumeAutoClose(entry) }
            }
        }
    }

    private func entry(_ id: UUID) -> Entry? {
        entries.first { $0.card.id == id }
    }
}

/// What `QuickAccessController.onEdit` receives.
struct QuickAccessEditRequest {
    var result: CaptureResult
    /// Where the card saved the capture, if it did.
    var savedURL: URL?
    /// The card's History entry, if any.
    var historyID: UUID?
}

/// History bookkeeping reported by `QuickAccessController.onHistoryEvent`.
enum QuickAccessHistoryEvent: Equatable {
    /// The card left the screen (any reason): a "Restore Recently Closed" candidate.
    case closed(historyID: UUID)
    /// The card wrote the capture to disk.
    case saved(historyID: UUID, url: URL)
    /// `restoreLastClosed()` brought the card back.
    case restored(historyID: UUID)
}

extension NSScreen {
    /// The CoreGraphics display id of this screen.
    fileprivate var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
