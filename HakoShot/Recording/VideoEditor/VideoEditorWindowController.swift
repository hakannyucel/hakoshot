import AppKit
import HakoKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Commands of the video editor (plan §4.16 shortcuts).
enum VideoEditorCommand: Equatable {
    case playPause
    case stepFrames(Int)
    case stepSeconds(Double)
    case setInPoint
    case setOutPoint
    case undo
    case redo
    case save
    case saveAs
    case copy
    case close
    /// Return in crop mode.
    case finishCrop
    /// Esc in crop mode.
    case cancelCrop
}

/// Key → command mapping (pure): Space play/pause, ←/→ one frame, ⇧←/→
/// one second, I/O in/out point, ⌘Z/⇧⌘Z, ⌘S/⇧⌘S, ⌘C, ⌘W, Return/Esc in
/// crop mode.
nonisolated enum VideoEditorKeyMap {
    static let space: UInt16 = 49
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53

    static func command(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, isCropping: Bool) -> VideoEditorCommand? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        let key = characters?.lowercased() ?? ""
        if mods.contains(.command) {
            switch (key, mods.subtracting(.command)) {
            case ("z", []): return .undo
            case ("z", [.shift]): return .redo
            case ("s", []): return .save
            case ("s", [.shift]): return .saveAs
            case ("c", []): return .copy
            case ("w", []): return .close
            default: return nil
            }
        }
        switch keyCode {
        case space where mods.isEmpty: return .playPause
        case leftArrow: return mods.contains(.shift) ? .stepSeconds(-VideoEditorMetrics.largeStepSeconds) : .stepFrames(-1)
        case rightArrow: return mods.contains(.shift) ? .stepSeconds(VideoEditorMetrics.largeStepSeconds) : .stepFrames(1)
        case returnKey, keypadEnter: return isCropping ? .finishCrop : nil
        case escape: return isCropping ? .cancelCrop : nil
        default: break
        }
        guard mods.isEmpty || mods == [.shift] else { return nil }
        switch key {
        case "i": return .setInPoint
        case "o": return .setOutPoint
        default: return nil
        }
    }
}

/// Video editor window: keys go to the controller before the focused view
/// (except while a text field edits), the traffic lights sit centered in
/// the 52 pt toolbar like the screenshot editor's.
final class VideoEditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command), keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Space / arrows would otherwise be eaten by a focused button or popup.
        if event.type == .keyDown, !event.modifierFlags.contains(.command), !(firstResponder is NSText),
           keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    func layoutTrafficLights() {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = standardWindowButton(.closeButton),
              let titlebarView = close.superview,
              let container = titlebarView.superview
        else { return }
        let height = VideoEditorMetrics.toolbarHeight
        let target = NSRect(x: 0, y: frame.height - height, width: EditorMetrics.toolbarLeadingInset - 8, height: height)
        if container.frame != target { container.frame = target }
        if titlebarView.frame != container.bounds { titlebarView.frame = container.bounds }
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            let origin = NSPoint(
                x: EditorMetrics.trafficLightLeading + CGFloat(index) * EditorMetrics.trafficLightSpacing,
                y: ((height - button.frame.height) / 2).rounded()
            )
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// Root view that re-centers the traffic lights after every layout.
final class VideoEditorRootView: NSView {
    override var wantsUpdateLayer: Bool { true }

    /// Opaque window background (also makes `cacheDisplay` snapshots match
    /// the window).
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        (window as? VideoEditorWindow)?.layoutTrafficLights()
    }
}

/// One classic video editor window (kayit-teknik-plan §4.16): toolbar on
/// top, the player (with the crop overlay) in the middle, the 64 pt
/// timeline at the bottom. Any number can be open (one per file).
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    // MARK: Integration hooks

    /// Shared activation policy (Dock icon while an editor is open), same as
    /// `EditorWindowController.activationPolicy`.
    static var activationPolicy: ActivationPolicyController?

    private static var openWindows: [VideoEditorWindowController] = []
    private static var switchedPolicyItself = false

    let model: VideoEditorViewModel
    let playerView = PlayerView()
    let thumbnails = ThumbnailLoader()
    private let editorWindow: VideoEditorWindow
    private let cropHost: NSHostingView<VideoCropOverlay>
    private let statusHost: NSHostingView<PlayerStatusOverlay>
    private let sheet = VideoExportSheetPresenter()
    private var closeConfirmed = false
    private var sizedToVideo = false

    // MARK: Opening

    /// Opens `url` (mp4 / mov) in a new window, or brings the window already
    /// showing it to the front. `historyID`: the History entry the video
    /// came from; saves record their file there.
    @discardableResult
    static func open(url: URL, historyID: UUID? = nil) -> VideoEditorWindowController {
        let standardized = url.standardizedFileURL
        if let existing = openWindows.first(where: { $0.model.sourceURL.standardizedFileURL == standardized }) {
            existing.present()
            return existing
        }
        let controller = VideoEditorWindowController(model: VideoEditorViewModel(sourceURL: url, historyID: historyID))
        openWindows.append(controller)
        controller.present()
        Task { await controller.load() }
        return controller
    }

    static var openEditorCount: Int { openWindows.count }

    #if DEBUG
    static var debugOpenWindows: [VideoEditorWindowController] { openWindows }

    static func closeAllDiscardingChanges() {
        for controller in openWindows {
            controller.closeConfirmed = true
            controller.window?.close()
        }
    }
    #endif

    // MARK: Init

    init(model: VideoEditorViewModel) {
        self.model = model
        self.cropHost = NSHostingView(rootView: VideoCropOverlay(model: model))
        self.statusHost = NSHostingView(rootView: PlayerStatusOverlay(model: model))
        let window = VideoEditorWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 960, height: 640)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.sourceURL.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = VideoEditorMetrics.minimumWindowSize
        window.backgroundColor = .windowBackgroundColor
        window.representedURL = model.sourceURL
        self.editorWindow = window
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        playerView.onClick = { [weak self] in
            guard let self, !self.model.isCropping else { return }
            self.model.togglePlayPause()
        }
        buildViews()
        center(window, contentSize: window.contentLayoutRect.size)
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildViews() {
        let root = VideoEditorRootView()
        root.wantsLayer = true

        let toolbar = FirstMouseHostingView(rootView: VideoEditorToolbar(
            model: model,
            onCopy: { [weak self] in self?.perform(.copy) },
            onSaveAs: { [weak self] in self?.perform(.saveAs) },
            onDone: { [weak self] in self?.done() }
        ))
        toolbar.sizingOptions = []
        let bottom = FirstMouseHostingView(rootView: VideoEditorBottomBar(model: model, thumbnails: thumbnails))
        bottom.sizingOptions = []
        let topLine = HairlineView()
        let bottomLine = HairlineView()

        for overlay in [cropHost, statusHost] as [NSView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            playerView.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: playerView.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            ])
        }
        cropHost.sizingOptions = []
        statusHost.sizingOptions = []
        cropHost.isHidden = true

        for view in [playerView, topLine, bottomLine, toolbar, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: VideoEditorMetrics.toolbarHeight),

            topLine.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: Tokens.Stroke.hairline),

            playerView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),

            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: Tokens.Stroke.hairline),
            bottomLine.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: VideoEditorMetrics.bottomBarHeight),
        ])
        editorWindow.contentView = root
    }

    /// Initial window size for a video of `pixelSize`: the video fitted into
    /// `maximumScreenFraction` of the visible frame plus the bars.
    nonisolated static func contentSize(forVideo pixelSize: CGSize, backingScale: CGFloat, visible: CGSize) -> CGSize {
        let chrome = VideoEditorMetrics.toolbarHeight + VideoEditorMetrics.bottomBarHeight + 2 * Tokens.Stroke.hairline
            + 2 * VideoEditorMetrics.playerInset
        let maxSize = CGSize(
            width: visible.width * VideoEditorMetrics.maximumScreenFraction,
            height: visible.height * VideoEditorMetrics.maximumScreenFraction
        )
        let points = CGSize(width: pixelSize.width / max(backingScale, 1), height: pixelSize.height / max(backingScale, 1))
        let room = CGSize(width: maxSize.width - 2 * VideoEditorMetrics.playerInset, height: maxSize.height - chrome)
        let factor = min(1, room.width / max(points.width, 1), room.height / max(points.height, 1))
        let width = max(VideoEditorMetrics.minimumWindowSize.width, (points.width * factor + 2 * VideoEditorMetrics.playerInset).rounded())
        let height = max(VideoEditorMetrics.minimumWindowSize.height, (points.height * factor + chrome).rounded())
        return CGSize(width: min(width, max(maxSize.width, VideoEditorMetrics.minimumWindowSize.width)),
                      height: min(height, max(maxSize.height, VideoEditorMetrics.minimumWindowSize.height)))
    }

    private func center(_ window: NSWindow, contentSize: CGSize) {
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        window.setContentSize(contentSize)
        let size = window.frame.size
        let cascade = CGFloat((Self.openWindows.count) % 8) * VideoEditorMetrics.cascadeOffset
        window.setFrameOrigin(CGPoint(
            x: (visible.midX - size.width / 2 + cascade).rounded(),
            y: (visible.midY - size.height / 2 - cascade).rounded()
        ))
    }

    /// Keeps the overlays' visibility in step with the model.
    private func observeModel() {
        withObservationTracking {
            _ = model.isCropping
            _ = model.loadState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.window != nil else { return }
                self.applyModelState()
                self.observeModel()
            }
        }
        applyModelState()
    }

    private func applyModelState() {
        cropHost.isHidden = !model.isCropping
        statusHost.isHidden = model.loadState == .ready
    }

    // MARK: Loading and presenting

    func load() async {
        await model.load()
        guard model.loadState == .ready else { return }
        if !sizedToVideo {
            sizedToVideo = true
            let screen = editorWindow.screen ?? NSScreen.main
            let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            let size = Self.contentSize(forVideo: model.sourcePixelSize, backingScale: screen?.backingScaleFactor ?? 2, visible: visible)
            center(editorWindow, contentSize: size)
        }
        model.startPlayback()
        playerView.player = model.player
    }

    private func present() {
        if let policy = Self.activationPolicy {
            policy.acquire(self)
        } else if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            Self.switchedPolicyItself = true
        }
        showWindow(nil)
        editorWindow.makeKeyAndOrderFront(nil)
        editorWindow.makeFirstResponder(playerView)
        editorWindow.layoutTrafficLights()
        NSApp.activate()
    }

    // MARK: Commands

    private func handleKey(_ event: NSEvent) -> Bool {
        let editingText = editorWindow.firstResponder is NSText
        guard let command = VideoEditorKeyMap.command(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            isCropping: model.isCropping
        ) else { return false }
        if editingText {
            // Text fields keep their own editing keys.
            switch command {
            case .save, .saveAs, .close: break
            default: return false
            }
        }
        // Popovers and sheets handle their own keys.
        if editorWindow.attachedSheet != nil { return false }
        return perform(command)
    }

    @discardableResult
    func perform(_ command: VideoEditorCommand) -> Bool {
        guard model.loadState == .ready || command == .close else { return command == .close }
        switch command {
        case .playPause: model.togglePlayPause()
        case .stepFrames(let n): model.step(frames: n)
        case .stepSeconds(let s): model.step(seconds: s)
        case .setInPoint: model.setInPointAtPlayhead()
        case .setOutPoint: model.setOutPointAtPlayhead()
        case .undo: model.undo()
        case .redo: model.redo()
        case .save: runExport(.save)
        case .saveAs: saveAs()
        case .copy: runExport(.copy)
        case .close: window?.performClose(nil)
        case .finishCrop: model.setCropping(false)
        case .cancelCrop: model.cancelCropping()
        }
        return true
    }

    /// Done: saves unsaved edits (a new file, the original is kept), then
    /// closes. Nothing edited = just close.
    private func done() {
        guard model.loadState == .ready, model.hasUnsavedChanges, !model.isUnchanged else {
            closeConfirmed = true
            window?.close()
            return
        }
        runExport(.save) { [weak self] url in
            guard url != nil, let self else { return }
            self.closeConfirmed = true
            self.window?.close()
        }
    }

    private func saveAs() {
        guard !model.isExporting else { return }
        model.pause()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [model.recipe.format == .gif ? .gif : .mpeg4Movie]
        panel.directoryURL = model.saveTarget?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: (model.settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath, isDirectory: true)
        panel.nameFieldStringValue = model.suggestedFileName()
        let hadTarget = model.saveTarget != nil
        panel.beginSheetModal(for: editorWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.runExport(.saveAs(url)) { saved in
                // A template-named new file used the next `%n` value.
                if saved != nil, !hadTarget {
                    _ = FileNameCounter.take(pattern: self.model.settings.value(for: .outputFileNameTemplate), settings: self.model.settings)
                }
            }
        }
    }

    /// Runs an export with the progress sheet; `completion` gets the file.
    private func runExport(_ operation: VideoEditorViewModel.ExportOperation, completion: ((URL?) -> Void)? = nil) {
        guard !model.isExporting, model.loadState == .ready else { return }
        model.pause()
        model.setCropping(false)
        let task = model.startExport(operation)
        sheet.present(on: editorWindow, model: model)
        Task { [weak self] in
            let url = await task.value
            self?.sheet.dismiss()
            completion?(url)
        }
    }

    // MARK: Menu (responder chain)

    @objc func undo(_ sender: Any?) { perform(.undo) }
    @objc func redo(_ sender: Any?) { perform(.redo) }
    @objc func saveDocument(_ sender: Any?) { perform(.save) }
    @objc func saveDocumentAs(_ sender: Any?) { perform(.saveAs) }
    @objc func copy(_ sender: Any?) { perform(.copy) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): model.canUndo
        case #selector(redo(_:)): model.canRedo
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(copy(_:)):
            model.loadState == .ready && !model.isExporting
        default: true
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isExporting {
            NSSound.beep()
            return false
        }
        guard !closeConfirmed, model.hasUnsavedChanges, !model.isUnchanged else { return true }
        model.pause()
        let alert = NSAlert()
        alert.messageText = "Save changes to this video?"
        alert.informativeText = "Your edits will be lost if you don't save them. The original file is kept either way."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.runExport(.save) { url in
                    guard url != nil else { return }
                    self.closeConfirmed = true
                    sender.close()
                }
            case .alertThirdButtonReturn:
                self.closeConfirmed = true
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowDidResize(_ notification: Notification) { editorWindow.layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { editorWindow.layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { editorWindow.layoutTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        model.tearDown()
        thumbnails.cancel()
        playerView.player = nil
        Self.openWindows.removeAll { $0 === self }
        editorWindow.animationBehavior = .none
        DispatchQueue.main.async {
            if let policy = Self.activationPolicy {
                policy.release(self)
            } else if Self.openWindows.isEmpty, EditorWindowController.openEditorCount == 0, Self.switchedPolicyItself {
                Self.switchedPolicyItself = false
                NSApp.setActivationPolicy(.accessory)
            }
        }
        Log.videoEditor.notice("closed video editor")
    }
}

/// Spinner while the file loads, the error when it can't be opened.
struct PlayerStatusOverlay: View {
    let model: VideoEditorViewModel

    var body: some View {
        ZStack {
            switch model.loadState {
            case .loading:
                ProgressView().controlSize(.large)
            case .failed(let message):
                VStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    Text("Can't open this video")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                        .multilineTextAlignment(.center)
                }
                .padding(Tokens.Spacing.xl)
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
