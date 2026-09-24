import AppKit
import HakoKit
import SwiftUI
import os

/// One annotation editor window (plan §1.2, §4.11): `NSWindow` with
/// `.fullSizeContentView`, SwiftUI top/bottom bars, AppKit `CanvasView` in a
/// magnifying `NSScrollView`. Any number can be open at once.
///
/// Entry points: `open(result:savedURL:)` (Quick Access / capture) and
/// `open(image:scale:sourceURL:mode:date:)` (Pin, History, files).
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    // MARK: Integration hooks (set once by AppCoordinator)

    /// Shared activation policy (Dock icon while an editor is open). When `nil`,
    /// the editor switches the policy itself and restores `.accessory` after the
    /// last editor closes.
    static var activationPolicy: ActivationPolicyController?
    /// Bottom-bar Pin button: `(renderedImage, pointSize)`. `nil` hides the button.
    static var onPin: ((CGImage, CGSize) -> Void)?

    private static var openEditors: [EditorWindowController] = []
    private static var switchedPolicyItself = false

    let model: EditorViewModel
    let canvas: CanvasView
    let scrollView: NSScrollView
    private let editorWindow: EditorWindow
    private let undoBridge = EditorUndoManager()
    private var fitsToWindow = true
    private var closeConfirmed = false
    private var observers: [NSObjectProtocol] = []

    // MARK: Opening

    /// `historyID`: the capture's History entry; every save refreshes its
    /// editable `.hakoshot` copy there.
    @discardableResult
    static func open(result: CaptureResult, savedURL: URL? = nil, historyID: UUID? = nil) -> EditorWindowController {
        open(image: result.image, scale: result.scale, sourceURL: savedURL, mode: result.mode, date: result.date, historyID: historyID)
    }

    /// `sourceURL`: the file the image came from; ⌘S then updates it in place.
    @discardableResult
    static func open(
        image: CGImage,
        scale: CGFloat,
        sourceURL: URL? = nil,
        mode: CaptureMode = .area,
        date: Date = .now,
        historyID: UUID? = nil
    ) -> EditorWindowController {
        let model = EditorViewModel(image: image, scale: scale, mode: mode, date: date, sourceURL: sourceURL)
        model.historyID = historyID
        let controller = open(model: model)
        EditorViewModel.log.notice("opened editor \(image.width)x\(image.height) px @\(scale)x")
        return controller
    }

    /// Opens a decoded `.hakoshot` project with every annotation editable.
    /// `projectURL`: the package on disk (⌘S writes it); an editor already
    /// showing that package is brought to the front instead.
    @discardableResult
    static func open(
        project: ProjectFile.Contents,
        projectURL: URL?,
        sourceURL: URL? = nil,
        historyID: UUID? = nil
    ) -> EditorWindowController? {
        if let projectURL, let existing = openEditors.first(where: { $0.model.projectURL?.standardizedFileURL == projectURL.standardizedFileURL }) {
            existing.present()
            return existing
        }
        guard let model = EditorViewModel(project: project, projectURL: projectURL, sourceURL: sourceURL, historyID: historyID) else {
            EditorViewModel.log.error("project has no image layer")
            return nil
        }
        let controller = open(model: model)
        let canvas = project.document.canvas
        EditorViewModel.log.notice(
            "opened project \(projectURL?.lastPathComponent ?? "history", privacy: .public): \(canvas.width)x\(canvas.height) px, \(project.document.annotations.count) annotations"
        )
        return controller
    }

    private static func open(model: EditorViewModel) -> EditorWindowController {
        let controller = EditorWindowController(model: model)
        openEditors.append(controller)
        controller.present()
        return controller
    }

    #if DEBUG
    static var debugOpenEditors: [EditorWindowController] { openEditors }

    /// Closes every editor without asking (DEBUG automation).
    static func closeAllDiscardingChanges() {
        for editor in openEditors {
            editor.closeConfirmed = true
            editor.window?.close()
        }
    }
    #endif

    static var openEditorCount: Int { openEditors.count }

    // MARK: Init

    init(model: EditorViewModel) {
        self.model = model
        self.canvas = CanvasView(model: model)
        self.scrollView = NSScrollView()

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = EditorWindowSizing.initialLayout(for: canvas.geometry, visibleFrame: visible.size)

        let window = EditorWindow(
            contentRect: CGRect(origin: .zero, size: layout.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = model.projectURL?.lastPathComponent ?? model.saveTarget?.lastPathComponent ?? "HakoShot Editor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = EditorMetrics.minimumWindowSize
        window.backgroundColor = .windowBackgroundColor
        self.editorWindow = window
        super.init(window: window)

        undoBridge.model = model
        model.hostWindow = window
        window.delegate = self
        window.canvas = canvas
        window.commandHandler = { [weak self] command in self?.perform(command) ?? false }
        canvas.onCommand = { [weak self] command in self?.perform(command) ?? false }
        model.zoomHandler = { [weak self] request in self?.applyZoom(request) }
        buildViews()
        position(window, contentSize: layout.contentSize, in: visible)
        scrollView.magnification = layout.zoom
        model.zoom = layout.zoom
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildViews() {
        let root = EditorRootView()
        root.wantsLayer = true

        let toolbar = FirstMouseHostingView(rootView: EditorToolbarView(
            model: model,
            onSaveAs: { [weak self] in _ = self?.perform(.saveAs) },
            onDone: { [weak self] in self?.done() }
        ))
        toolbar.sizingOptions = []

        let pinAction: (() -> Void)? = Self.onPin == nil ? nil : { [weak self] in self?.pin() }
        let bottom = FirstMouseHostingView(rootView: EditorBottomBar(
            model: model,
            onPin: pinAction,
            onCopy: { [weak self] in _ = self?.perform(.copyImage) },
            onSave: { [weak self] in _ = self?.perform(.save) }
        ))
        bottom.sizingOptions = []

        let separator = HairlineView()
        let backgroundPanel = BackgroundPanelHost.makeView(model: model)

        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = EditorMetrics.canvasBackground
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorMetrics.canvasBackground
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ZoomMath.minimum
        scrollView.maxMagnification = ZoomMath.maximum
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        for view in [scrollView, backgroundPanel, separator, toolbar, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorMetrics.toolbarHeight),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: EditorMetrics.separatorHeight),

            backgroundPanel.topAnchor.constraint(equalTo: scrollView.topAnchor),
            backgroundPanel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            backgroundPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: backgroundPanel.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: EditorMetrics.bottomBarHeight),
        ])
        editorWindow.contentView = root
    }

    /// Centered on the visible frame, cascading when other editors are open.
    private func position(_ window: NSWindow, contentSize: CGSize, in visible: CGRect) {
        window.setContentSize(contentSize)
        let size = window.frame.size
        let cascade = CGFloat(Self.openEditors.count % 8) * EditorMetrics.cascadeOffset
        let origin = CGPoint(
            x: (visible.midX - size.width / 2 + cascade).rounded(),
            y: (visible.midY - size.height / 2 - cascade).rounded()
        )
        window.setFrameOrigin(origin)
    }

    private func observe() {
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncZoom() }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fitsToWindow = false
                self?.syncZoom()
            }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fitsToWindow else { return }
                self.fitToWindow()
            }
        })
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
        editorWindow.makeFirstResponder(canvas)
        editorWindow.layoutTrafficLights()
        NSApp.activate()
    }

    // MARK: Zoom

    private func syncZoom() {
        let zoom = scrollView.magnification
        if abs(model.zoom - zoom) > 0.0001 { model.zoom = zoom }
    }

    func applyZoom(_ request: ZoomRequest) {
        switch request {
        case .zoomIn: setZoom(ZoomMath.zoomIn(from: scrollView.magnification))
        case .zoomOut: setZoom(ZoomMath.zoomOut(from: scrollView.magnification))
        case .actualSize: setZoom(1)
        case .fit: fitToWindow()
        case .set(let zoom): setZoom(zoom)
        }
    }

    private func setZoom(_ zoom: CGFloat) {
        fitsToWindow = false
        let visible = canvas.visibleRect
        scrollView.setMagnification(ZoomMath.clamp(zoom), centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        syncZoom()
    }

    private func fitToWindow() {
        fitsToWindow = true
        scrollView.magnification = ZoomMath.fit(content: canvas.frame.size, in: scrollView.contentSize)
        syncZoom()
    }

    // MARK: Commands

    /// Every editor command, from keys, menus and buttons.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        let editingText = canvas.textEditor?.textView
        switch command {
        case .undo:
            if let editingText { editingText.undoManager?.undo() } else { model.undo() }
        case .redo:
            if let editingText { editingText.undoManager?.redo() } else { model.redo() }
        case .copy:
            if let editingText { return NSApp.sendAction(#selector(NSText.copy(_:)), to: editingText, from: nil) }
            if model.hasSelection {
                model.copySelectionToPasteboard()
                model.showStatus("Copied \(model.selection.count == 1 ? "object" : "objects")")
            } else {
                model.copyImageToClipboard()
            }
        case .cut:
            if let editingText { return NSApp.sendAction(#selector(NSText.cut(_:)), to: editingText, from: nil) }
            guard model.hasSelection else { return false }
            model.copySelectionToPasteboard()
            model.deleteSelection()
        case .paste:
            if let editingText { return NSApp.sendAction(#selector(NSText.paste(_:)), to: editingText, from: nil) }
            // Copied objects win (⌘C writes them last); otherwise an image.
            return model.pasteFromPasteboard() || model.pasteImage()
        case .copyImage:
            model.copyImageToClipboard()
        case .save:
            model.save()
        case .saveAs:
            model.saveAs(from: window)
        case .duplicate:
            guard editingText == nil else { return false }
            model.duplicateSelection()
        case .selectAll:
            if let editingText { return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: editingText, from: nil) }
            model.selectAll()
        case .zoomIn: applyZoom(.zoomIn)
        case .zoomOut: applyZoom(.zoomOut)
        case .zoomActualSize: applyZoom(.actualSize)
        case .zoomToFit: applyZoom(.fit)
        case .close:
            window?.performClose(nil)
        case .addImage:
            model.chooseImagesToCombine(from: window)
        case .addScreenshot:
            model.addNewScreenshot()
        case .selectTool(let tool):
            model.selectTool(tool)
        case .sizePreset(let index):
            model.setSizePreset(index)
        case .increaseSize:
            model.stepSize(by: 1)
        case .decreaseSize:
            model.stepSize(by: -1)
        case .deleteSelection:
            model.deleteSelection()
        case .nudge(let dx, let dy):
            model.nudgeSelection(dx: dx, dy: dy)
        case .escape, .editSelectedText:
            return canvas.perform(command)
        }
        return true
    }

    private func done() {
        canvas.textEditor?.end()
        if model.store.hasUnsavedChanges || !model.hasSaveDestination {
            guard model.save() else { return }
        }
        closeConfirmed = true
        window?.close()
    }

    private func pin() {
        guard let image = model.renderImage() else { return }
        Self.onPin?(image, model.pointSize(of: image))
    }

    // MARK: Edit menu (responder chain)

    @objc func undo(_ sender: Any?) { perform(.undo) }
    @objc func redo(_ sender: Any?) { perform(.redo) }
    @objc func saveDocument(_ sender: Any?) { perform(.save) }
    @objc func saveDocumentAs(_ sender: Any?) { perform(.saveAs) }
    @objc func copy(_ sender: Any?) { perform(.copy) }
    @objc func paste(_ sender: Any?) { perform(.paste) }
    @objc func delete(_ sender: Any?) { perform(.deleteSelection) }
    @objc func duplicate(_ sender: Any?) { perform(.duplicate) }
    @objc override func selectAll(_ sender: Any?) { perform(.selectAll) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = undoBridge.undoMenuItemTitle
            return undoBridge.canUndo
        case #selector(redo(_:)):
            menuItem.title = undoBridge.redoMenuItemTitle
            return undoBridge.canRedo
        case #selector(delete(_:)), #selector(duplicate(_:)):
            return model.hasSelection
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoBridge
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.textEditor?.end()
        guard model.store.hasUnsavedChanges, !closeConfirmed else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to this screenshot?"
        alert.informativeText = "Your annotations will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard self.model.save() else { return }
                self.closeConfirmed = true
                sender.close()
            case .alertThirdButtonReturn:
                self.closeConfirmed = true
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowDidResize(_ notification: Notification) {
        editorWindow.layoutTrafficLights()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        editorWindow.layoutTrafficLights()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        editorWindow.layoutTrafficLights()
    }

    func windowWillClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        ColorPanelBridge.shared.detach(model)
        Self.openEditors.removeAll { $0 === self }
        // Switching back to `.accessory` while the close animation runs leaves
        // the window stuck on screen (seen on macOS 27), so the window closes
        // without animation and the policy changes once it is gone.
        editorWindow.animationBehavior = .none
        DispatchQueue.main.async {
            if let policy = Self.activationPolicy {
                policy.release(self)
            } else if Self.openEditors.isEmpty, Self.switchedPolicyItself {
                Self.switchedPolicyItself = false
                NSApp.setActivationPolicy(.accessory)
            }
        }
        EditorViewModel.log.notice("closed editor")
    }
}

/// 1 pt divider under the toolbar.
final class HairlineView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        Tokens.Palette.divider.setFill()
        bounds.fill()
    }
}

/// Bars react to the first click even when the editor isn't key (like the canvas).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
