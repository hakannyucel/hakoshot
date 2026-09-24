import AppKit
import AVFoundation
import HakoKit
import SwiftUI
import os

/// One Studio editor window per `.hakostudio` package (plan §4.19):
/// toolbar, preview, inspector, timeline with the zoom lane.
///
/// Entry points: `open(url:)` (Finder, History, "Open in Studio", after a
/// Studio recording) and `chooseAndOpen()` (open panel). An editor already
/// showing a package is brought to the front.
final class StudioWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    // MARK: Integration hooks (set once by AppCoordinator)

    /// Shared activation policy (Dock icon while a window is open); `nil`:
    /// the window switches the policy itself.
    static var activationPolicy: ActivationPolicyController?
    /// Called after a successful export with the exported file (show a
    /// Quick Access card: `quickAccess.show(recording:savedURL:historyID:)`).
    static var onExported: ((RecordingResult) -> Void)?

    private static var openWindows: [StudioWindowController] = []
    private static var switchedPolicyItself = false

    let model: StudioViewModel
    private let studioWindow: StudioWindow
    private let undoBridge = StudioUndoManager()
    private var closeConfirmed = false

    // MARK: Opening

    /// Opens (or focuses) the editor for the package at `url`. `nil` when
    /// the package can't be read (an alert explains why).
    @discardableResult
    static func open(url: URL) -> StudioWindowController? {
        let target = url.standardizedFileURL
        if let existing = openWindows.first(where: { $0.model.packageURL.standardizedFileURL == target }) {
            existing.present()
            return existing
        }
        do {
            let model = try StudioViewModel.load(url: target)
            let controller = StudioWindowController(model: model)
            openWindows.append(controller)
            controller.present()
            model.start()
            StudioViewModel.log.notice("opened studio \(target.lastPathComponent, privacy: .public) \(model.project.source.pixelWidth)x\(model.project.source.pixelHeight), \(String(format: "%.2f", model.sourceDuration), privacy: .public) s")
            return controller
        } catch {
            StudioViewModel.log.error("open studio failed: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(url.lastPathComponent)"
            alert.informativeText = String(describing: error)
            alert.runModal()
            return nil
        }
    }

    /// Open panel for `.hakostudio` packages.
    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: StudioProjectFile.fileExtension) ?? .package]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    static var openWindowCount: Int { openWindows.count }

    #if DEBUG
    static var debugOpenWindows: [StudioWindowController] { openWindows }
    #endif

    // MARK: Init

    init(model: StudioViewModel) {
        self.model = model
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = StudioLayout.initialContentSize(visible: visible.size)
        let window = StudioWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.representedURL = model.packageURL
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = StudioLayout.minimumWindowSize
        window.backgroundColor = .windowBackgroundColor
        self.studioWindow = window
        super.init(window: window)

        undoBridge.model = model
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.commandHandler = { [weak self] command in self?.perform(command) ?? false }
        let root = NSHostingView(rootView: StudioRootView(
            model: model,
            onExport: { [weak self] in self?.showExportSheet() }
        ))
        window.contentView = root
        window.setContentSize(size)
        let cascade = CGFloat(Self.openWindows.count % 8) * StudioLayout.cascadeOffset
        window.setFrameOrigin(CGPoint(x: (visible.midX - window.frame.width / 2 + cascade).rounded(),
                                      y: (visible.midY - window.frame.height / 2 - cascade).rounded()))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func present() {
        if let policy = Self.activationPolicy {
            policy.acquire(self)
        } else if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            Self.switchedPolicyItself = true
        }
        showWindow(nil)
        studioWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Commands

    enum Command {
        case save, undo, redo, export, close, togglePlay
    }

    @discardableResult
    func perform(_ command: Command) -> Bool {
        switch command {
        case .save: model.saveNow()
        case .undo: model.undo()
        case .redo: model.redo()
        case .export: showExportSheet()
        case .close: window?.performClose(nil)
        case .togglePlay: model.playback.togglePlay()
        }
        return true
    }

    /// Plain keys: Space play/pause, ⌫ delete selection, ←/→ step a frame,
    /// Esc clears selections.
    private func handleKey(_ event: NSEvent) -> Bool {
        if studioWindow.firstResponder is NSText { return false }
        switch event.keyCode {
        case 49: // space
            model.playback.togglePlay()
        case 51, 117: // delete, forward delete
            return model.deleteSelection()
        case 123:
            model.playback.step(frames: event.modifierFlags.contains(.shift) ? -10 : -1, fps: model.outputFPS)
        case 124:
            model.playback.step(frames: event.modifierFlags.contains(.shift) ? 10 : 1, fps: model.outputFPS)
        case 53: // escape
            model.selectZoom(nil)
            model.rangeSelection = nil
            model.selectedCut = nil
        default:
            return false
        }
        return true
    }

    // MARK: Export

    private var exportSheet: NSWindow?

    func showExportSheet() {
        guard exportSheet == nil, let window else { return }
        model.playback.pause()
        let exportModel = StudioExportModel(studio: model)
        exportModel.onFinished = { [weak self] result in
            if let result { Self.onExported?(result) }
            self?.endExportSheet()
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: StudioExportSheet(model: exportModel)))
        sheet.styleMask = [.titled]
        exportSheet = sheet
        window.beginSheet(sheet)
    }

    private func endExportSheet() {
        guard let sheet = exportSheet else { return }
        window?.endSheet(sheet)
        exportSheet = nil
    }

    // MARK: Edit menu (responder chain)

    @objc func undo(_ sender: Any?) { perform(.undo) }
    @objc func redo(_ sender: Any?) { perform(.redo) }
    @objc func saveDocument(_ sender: Any?) { perform(.save) }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = undoBridge.undoMenuItemTitle
            return undoBridge.canUndo
        case #selector(redo(_:)):
            menuItem.title = undoBridge.redoMenuItemTitle
            return undoBridge.canRedo
        default:
            return true
        }
    }

    // MARK: Snapshot

    /// The window content with the current preview frame drawn into the
    /// preview area (`cacheDisplay` doesn't capture `AVPlayerLayer`).
    func snapshotImage() async -> CGImage? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let base = rep.cgImage else { return nil }
        guard let previewView = StudioPlayerNSView.find(in: view), let frame = previewView.videoFrameRect() else { return base }
        let project = model.project
        let time = model.playback.currentTime
        guard let still = try? await StudioExport.frameImage(project: project, media: model.media, outputTime: time,
                                                             outputHeight: Int(frame.height * 2)) else { return base }
        let scale = CGFloat(base.width) / view.bounds.width
        let rect = previewView.convert(frame, to: view)
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: full)
        // `view` is flipped (SwiftUI hosting): convert to CG bottom-left.
        let y = view.isFlipped ? view.bounds.height - rect.maxY : rect.minY
        context.draw(still, in: CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale))
        return context.makeImage()
    }

    /// Closes without asking (DEBUG automation); unsaved edits are autosaved first.
    func closeWithoutSaving() {
        closeConfirmed = true
        window?.close()
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoBridge
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges, !closeConfirmed else { return true }
        // Studio projects autosave: save and close.
        Task { [weak self] in
            guard let self else { return }
            _ = await self.model.save()
            self.closeConfirmed = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.tearDown()
        Self.openWindows.removeAll { $0 === self }
        studioWindow.animationBehavior = .none
        DispatchQueue.main.async {
            if let policy = Self.activationPolicy {
                policy.release(self)
            } else if Self.openWindows.isEmpty, EditorWindowController.openEditorCount == 0, Self.switchedPolicyItself {
                Self.switchedPolicyItself = false
                NSApp.setActivationPolicy(.accessory)
            }
        }
        StudioViewModel.log.notice("closed studio")
    }
}

// MARK: - Window

/// Studio window: ⌘ shortcuts resolve here first (no app Edit/File menu),
/// plain keys go to the editor unless a text field has focus.
final class StudioWindow: NSWindow {
    var commandHandler: ((StudioWindowController.Command) -> Bool)?
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let command = Self.command(for: event), commandHandler?(command) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    static func command(for event: NSEvent) -> StudioWindowController.Command? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "s"): return .save
        case ([.command], "z"): return .undo
        case ([.command, .shift], "z"): return .redo
        case ([.command], "e"): return .export
        case ([.command], "w"): return .close
        default: return nil
        }
    }
}

// MARK: - Undo bridge

/// The window's `NSUndoManager`, backed by `StudioStore`'s undo stack (Edit
/// menu titles "Undo Move Zoom").
final class StudioUndoManager: UndoManager {
    weak var model: StudioViewModel?

    override var canUndo: Bool { model?.store.canUndo ?? false }
    override var canRedo: Bool { model?.store.canRedo ?? false }
    override var undoActionName: String { model?.store.undoActionName ?? "" }
    override var redoActionName: String { model?.store.redoActionName ?? "" }
    override var undoMenuItemTitle: String { undoMenuTitle(forUndoActionName: undoActionName) }
    override var redoMenuItemTitle: String { redoMenuTitle(forUndoActionName: redoActionName) }
    override func undo() { model?.undo() }
    override func redo() { model?.redo() }
}

// MARK: - Layout

/// Studio window metrics (plan §4.19; sugg. values).
nonisolated enum StudioLayout {
    static let minimumWindowSize = CGSize(width: 900, height: 600)
    static let preferredContentSize = CGSize(width: 1280, height: 820)
    static let cascadeOffset: CGFloat = 24
    static let toolbarHeight = Tokens.Recording.editorToolbarHeight
    static let timelineHorizontalInset = Tokens.Spacing.l
    static let laneGap = Tokens.Spacing.xs
    static let videoLaneHeight = Tokens.Recording.editorThumbnailWidth
    static let clicksLaneHeight: CGFloat = 12
    static let timelineControlsHeight: CGFloat = 32
    static let playheadWidth: CGFloat = 2
    static let playheadKnob: CGFloat = 10
    static let zoomEdgeHandle: CGFloat = 8
    static let zoomBlockRadius: CGFloat = 6
    static let exportSheetWidth: CGFloat = 380

    static func initialContentSize(visible: CGSize) -> CGSize {
        CGSize(width: min(preferredContentSize.width, visible.width * 0.9),
               height: min(preferredContentSize.height, visible.height * 0.9))
    }
}
