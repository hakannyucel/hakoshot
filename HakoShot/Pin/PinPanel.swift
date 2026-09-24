import AppKit
import CoreGraphics
import HakoKit
import os
import SwiftUI
import UniformTypeIdentifiers

/// The pixels a pin shows. `image` is `pointSize × scale` pixels.
nonisolated struct PinContent: Sendable {
    let image: CGImage
    let pointSize: CGSize

    var scale: CGFloat {
        pointSize.width > 0 ? CGFloat(image.width) / pointSize.width : 1
    }
}

/// What a pin asks its owner (`PinController`) to do.
protocol PinPanelDelegate: AnyObject {
    var canEditPins: Bool { get }
    var canRecognizeTextInPins: Bool { get }
    func pinPanelDidRequestClose(_ panel: PinPanel)
    func pinPanelDidRequestCloseAll(_ panel: PinPanel)
    func pinPanelDidChangeLock(_ panel: PinPanel)
    func pinPanelDidRequestEdit(_ panel: PinPanel)
    func pinPanelDidRequestRecognizeText(_ panel: PinPanel)
}

/// One floating screenshot (plan §1.2, §4.12): borderless `.floating` panel on all
/// Spaces that never activates the app. Interactions:
/// - drag anywhere to move, drag an edge/corner to resize (aspect locked)
/// - pinch or ⌘-scroll to zoom (10–500 %), ⌘= / ⌘- / ⌘0
/// - two-finger scroll to change opacity (10–100 %) with a "%" HUD
/// - arrows move 1 pt (⇧ 10 pt); Esc / ⌘W close; ⌥⌘Esc / ⌥⌘W close all
/// - ⌘C copy, ⌘S save, ⇧⌘S save as, ⌘E edit, ⌘L lock (click-through)
final class PinPanel: NSPanel {
    let content: PinContent
    weak var pinDelegate: PinPanelDelegate?
    let model = PinHoverModel()

    private(set) var imageOpacity: Double
    private(set) var isLocked = false
    var zoom: CGFloat { PinGeometry.zoom(for: frame.size, baseSize: content.pointSize) }

    private let settings: AppSettings
    private var pinView: PinContentView?
    private var hudHideTask: Task<Void, Never>?

    init(content: PinContent, frame: CGRect, appearance: PinAppearance, settings: AppSettings = .shared) {
        self.content = content
        self.settings = settings
        self.imageOpacity = appearance.opacity
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = appearance.showsShadow
        isMovable = true
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none

        let view = PinContentView(panel: self, appearance: appearance)
        view.frame = CGRect(origin: .zero, size: frame.size)
        contentView = view
        pinView = view
        view.setImageOpacity(imageOpacity)
        model.zoom = zoom
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Showing / hiding

    func show() {
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        DSAnimation.run(.overlayFadeIn) { _ in self.animator().alphaValue = 1 }
    }

    func dismiss(completion: @escaping () -> Void) {
        hudHideTask?.cancel()
        DSAnimation.run(.hoverControls, changes: { _ in self.animator().alphaValue = 0 }, completion: {
            self.orderOut(nil)
            completion()
        })
    }

    // MARK: Geometry

    func applyFrame(_ newFrame: CGRect) {
        setFrame(newFrame, display: true)
        model.zoom = zoom
        if hasShadow { invalidateShadow() }
    }

    /// Zooms to `newZoom` keeping `anchor` (screen point) fixed; defaults to the center.
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil, showHUD: Bool = true) {
        let point = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        applyFrame(PinGeometry.zoomedFrame(frame, baseSize: content.pointSize, zoom: newZoom, anchor: point))
        if showHUD { flashHUD(PinGeometry.percentText(Double(zoom))) }
    }

    func resetZoom() { setZoom(1) }

    func nudge(_ direction: PinNudge, largeStep: Bool) {
        setFrameOrigin(PinGeometry.nudged(frame.origin, direction, largeStep: largeStep))
    }

    // MARK: Opacity

    func setOpacity(_ value: Double, showHUD: Bool = true) {
        imageOpacity = PinGeometry.clampOpacity(value)
        pinView?.setImageOpacity(imageOpacity)
        if hasShadow { invalidateShadow() }
        if showHUD { flashHUD(PinGeometry.percentText(imageOpacity)) }
    }

    // MARK: Lock

    /// Locked = click-through (`ignoresMouseEvents`). Unlock via ⌘L while the pin is
    /// still key, or the menu bar's "Unlock All Pins" (plan §4.12).
    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        ignoresMouseEvents = locked
        model.isLocked = locked
        pinView?.setHoverVisible(false)
        flashHUD(locked ? "Locked" : "Unlocked")
        pinDelegate?.pinPanelDidChangeLock(self)
    }

    // MARK: Actions

    func copyToClipboard() {
        do {
            try ClipboardWriter().write(content.image)
            flashHUD("Copied")
        } catch {
            Log.pin.error("copy failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// Saves to the export location with the normal file-name template.
    func save() {
        let result = CaptureResult(image: content.image, pointSize: content.pointSize, scale: content.scale, mode: .area)
        do {
            let url = try OutputService(settings: settings).save(result)
            Log.pin.notice("saved pin to \(url.path, privacy: .public)")
            flashHUD("Saved")
        } catch {
            Log.pin.error("save failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    func saveAs() {
        let format = settings.value(for: .outputImageFormat)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.level = .modalPanel
        let pattern = settings.value(for: .outputFileNameTemplate)
        // `%n` suggestion: the next counter value; it advances once the file is written.
        panel.nameFieldStringValue = FileNamer(
            template: FileNameTemplate(pattern: pattern),
            pathExtension: format.fileExtension
        ).fileName(counter: FileNameCounter.peek(settings: settings), mode: CaptureMode.area.fileNameToken)
        panel.directoryURL = URL(
            fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath,
            isDirectory: true
        )
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self, self.write(to: url) else { return }
                _ = FileNameCounter.take(pattern: pattern, settings: self.settings)
            }
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        let format: ImageFormat = switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic": .heic
        default: .png
        }
        do {
            let options = ImageEncodeOptions(
                compressionQuality: CGFloat(settings.outputQuality(for: format)),
                dpi: 72 * content.scale
            )
            let data = try ImageEncoder.encode(content.image, format: format, options: options)
            try data.write(to: url, options: .atomic)
            flashHUD("Saved")
            return true
        } catch {
            Log.pin.error("save as failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return false
        }
    }

    func requestClose() { pinDelegate?.pinPanelDidRequestClose(self) }
    func requestCloseAll() { pinDelegate?.pinPanelDidRequestCloseAll(self) }

    func requestEdit() {
        guard pinDelegate?.canEditPins == true else { NSSound.beep(); return }
        pinDelegate?.pinPanelDidRequestEdit(self)
    }

    func requestRecognizeText() {
        guard pinDelegate?.canRecognizeTextInPins == true else { NSSound.beep(); return }
        pinDelegate?.pinPanelDidRequestRecognizeText(self)
    }

    var hoverActions: PinHoverActions {
        PinHoverActions(
            close: { [weak self] in self?.requestClose() },
            toggleLock: { [weak self] in
                guard let self else { return }
                self.setLocked(!self.isLocked)
            },
            copy: { [weak self] in self?.copyToClipboard() },
            save: { [weak self] in self?.save() },
            edit: { [weak self] in self?.requestEdit() },
            resetZoom: { [weak self] in self?.resetZoom() }
        )
    }

    // MARK: HUD

    func flashHUD(_ text: String) {
        model.hudText = text
        pinView?.setHUDVisible(true)
        hudHideTask?.cancel()
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Tokens.Pin.hudHold))
            guard !Task.isCancelled else { return }
            self?.pinView?.setHUDVisible(false)
        }
    }

    // MARK: Input

    /// Handles a key-down. Returns `false` for keys the pin doesn't use.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53: // Esc
            if command && option { requestCloseAll() } else { requestClose() }
            return true
        case 123: nudge(.left, largeStep: shift); return true
        case 124: nudge(.right, largeStep: shift); return true
        case 125: nudge(.down, largeStep: shift); return true
        case 126: nudge(.up, largeStep: shift); return true
        default: break
        }

        guard command else { return false }
        switch key {
        case "w":
            if option { requestCloseAll() } else { requestClose() }
        case "c": copyToClipboard()
        case "s": if shift { saveAs() } else { save() }
        case "e": requestEdit()
        case "l": setLocked(!isLocked)
        case "0": resetZoom()
        case "=", "+": setZoom(zoom * PinInteraction.keyboardZoomStep)
        case "-": setZoom(zoom / PinInteraction.keyboardZoomStep)
        default: return false
        }
        return true
    }

    /// Two-finger scroll = opacity; ⌘-scroll = zoom around the pointer.
    func handleScroll(_ event: NSEvent) {
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return }
        // Positive = fingers / wheel moving up, regardless of "natural scrolling".
        let delta = event.isDirectionInvertedFromDevice ? -raw : raw
        if event.modifierFlags.contains(.command) {
            let step = event.hasPreciseScrollingDeltas ? PinInteraction.zoomPerScrollPoint : PinInteraction.zoomPerScrollLine
            setZoom(zoom * (1 + delta * step), anchor: NSEvent.mouseLocation)
        } else {
            let step = event.hasPreciseScrollingDeltas ? PinInteraction.opacityPerScrollPoint : PinInteraction.opacityPerScrollLine
            setOpacity(imageOpacity + Double(delta) * step)
        }
    }

    func handleMagnify(_ event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    // MARK: Context menu (plan §4.12: Save, OCR, Copy, Open in Editor, Close)

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(pinMenuItem("Copy", key: "c") { [weak self] in self?.copyToClipboard() })
        menu.addItem(pinMenuItem("Save", key: "s") { [weak self] in self?.save() })
        menu.addItem(pinMenuItem("Save As…", key: "s", modifiers: [.command, .shift]) { [weak self] in self?.saveAs() })
        menu.addItem(.separator())

        let edit = pinMenuItem("Open in Editor", key: "e") { [weak self] in self?.requestEdit() }
        edit.isEnabled = pinDelegate?.canEditPins == true
        menu.addItem(edit)
        let ocr = pinMenuItem("Recognize Text") { [weak self] in self?.requestRecognizeText() }
        ocr.isEnabled = pinDelegate?.canRecognizeTextInPins == true
        menu.addItem(ocr)
        menu.addItem(.separator())

        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = pinMenuItem("\(percent)%") { [weak self] in self?.setOpacity(Double(percent) / 100) }
            item.state = Int((imageOpacity * 100).rounded()) == percent ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        let actualSize = pinMenuItem("Actual Size", key: "0") { [weak self] in self?.resetZoom() }
        actualSize.isEnabled = abs(zoom - 1) > 0.001
        menu.addItem(actualSize)
        let lock = pinMenuItem("Lock (Click-Through)", key: "l") { [weak self] in self?.setLocked(true) }
        menu.addItem(lock)
        menu.addItem(.separator())

        menu.addItem(pinMenuItem("Close", key: "w") { [weak self] in self?.requestClose() })
        menu.addItem(pinMenuItem("Close All Pins", key: "w", modifiers: [.command, .option]) { [weak self] in
            self?.requestCloseAll()
        })
        return menu
    }
}

// MARK: - Content view

/// Image + hover controls + HUD. Owns mouse / scroll / key input and forwards to `PinPanel`.
final class PinContentView: NSView {
    private weak var panel: PinPanel?
    private let imageView = PinPassthroughView()
    private let stripView = PinPassthroughView()
    private let stripLayer = CAGradientLayer()
    private let closeHost: PinHostingView<PinHoverCloseButton>
    private let barHost: PinHostingView<PinHoverBar>
    private let hudHost: PinHostingView<PinHUDLabel>
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false
    /// Hover controls are unhidden (possibly mid-fade); hidden views take no clicks.
    private var controlsShown = false
    private var barFits = true
    private var resize: (edge: PinEdge, startFrame: CGRect, startMouse: CGPoint)?

    // Widths used to decide which hover controls fit (zoom badge + circles + gaps + insets).
    private static let closeOnlyMinWidth: CGFloat = Tokens.Size.circleButton + Tokens.Spacing.hoverControlInset * 2
    private static let compactBarWidth: CGFloat = 64 + 2 * (Tokens.Size.circleButton + Tokens.Pin.hoverBarItemGap)
    private static let fullBarWidth: CGFloat = 64 + 4 * (Tokens.Size.circleButton + Tokens.Pin.hoverBarItemGap)

    init(panel: PinPanel, appearance: PinAppearance) {
        self.panel = panel
        let actions = panel.hoverActions
        closeHost = PinHostingView(rootView: PinHoverCloseButton(actions: actions))
        barHost = PinHostingView(rootView: PinHoverBar(model: panel.model, actions: actions))
        hudHost = PinHostingView(rootView: PinHUDLabel(model: panel.model))
        super.init(frame: .zero)

        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = appearance.roundedCorners ? Tokens.Radius.pinWindow : 0
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        if appearance.showsBorder {
            layer.borderWidth = Tokens.Stroke.hairline
            layer.borderColor = Tokens.Pin.borderColor.cgColor
        }

        imageView.wantsLayer = true
        if let imageLayer = imageView.layer {
            imageLayer.contents = panel.content.image
            imageLayer.contentsGravity = .resize
            imageLayer.contentsScale = panel.content.scale
            imageLayer.magnificationFilter = .linear
            imageLayer.minificationFilter = .trilinear
        }
        addSubview(imageView)

        stripView.wantsLayer = true
        stripLayer.colors = [
            NSColor(white: 0, alpha: Tokens.Pin.hoverStripOpacity).cgColor,
            NSColor(white: 0, alpha: 0).cgColor,
        ]
        stripLayer.startPoint = CGPoint(x: 0.5, y: 1)
        stripLayer.endPoint = CGPoint(x: 0.5, y: 0)
        stripView.layer?.addSublayer(stripLayer)
        addSubview(stripView)

        for host in [closeHost, barHost] as [NSView] {
            host.alphaValue = 0
            host.isHidden = true
            addSubview(host)
        }
        stripView.alphaValue = 0
        barHost.sizingOptions = [.intrinsicContentSize]
        closeHost.sizingOptions = [.intrinsicContentSize]

        hudHost.alphaValue = 0
        hudHost.isHidden = true
        hudHost.sizingOptions = [.intrinsicContentSize]
        addSubview(hudHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    func setImageOpacity(_ opacity: Double) {
        imageView.layer?.opacity = Float(opacity)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let stripHeight = min(Tokens.Pin.hoverStripHeight, bounds.height)
        stripView.frame = CGRect(x: 0, y: bounds.maxY - stripHeight, width: bounds.width, height: stripHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.frame = stripView.bounds
        CATransaction.commit()

        let inset = Tokens.Spacing.hoverControlInset
        let available = bounds.width - Self.closeOnlyMinWidth - inset
        let compact = available < Self.fullBarWidth
        if panel?.model.isCompact != compact { panel?.model.isCompact = compact }
        barFits = available >= Self.compactBarWidth
        barHost.isHidden = !(barFits && controlsShown)

        let closeSize = closeHost.fittingSize
        closeHost.frame = CGRect(
            x: inset, y: bounds.maxY - inset - closeSize.height, width: closeSize.width, height: closeSize.height
        )
        let barSize = barHost.fittingSize
        barHost.frame = CGRect(
            x: bounds.maxX - inset - barSize.width,
            y: bounds.maxY - inset - barSize.height,
            width: barSize.width,
            height: barSize.height
        )
        let hudSize = hudHost.fittingSize
        hudHost.frame = CGRect(
            x: (bounds.midX - hudSize.width / 2).rounded(),
            y: (bounds.midY - hudSize.height / 2).rounded(),
            width: hudSize.width,
            height: hudSize.height
        )
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let band = PinInteraction.resizeEdgeBand
        let b = bounds
        let corner = band * 2
        addCursorRect(CGRect(x: b.minX, y: b.minY + corner, width: band, height: b.height - corner * 2), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: b.maxX - band, y: b.minY + corner, width: band, height: b.height - corner * 2), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: b.minX + corner, y: b.minY, width: b.width - corner * 2, height: band), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: b.minX + corner, y: b.maxY - band, width: b.width - corner * 2, height: band), cursor: .resizeUpDown)
        for (rect, position) in [
            (CGRect(x: b.minX, y: b.maxY - corner, width: corner, height: corner), NSCursor.FrameResizePosition.topLeft),
            (CGRect(x: b.maxX - corner, y: b.maxY - corner, width: corner, height: corner), .topRight),
            (CGRect(x: b.minX, y: b.minY, width: corner, height: corner), .bottomLeft),
            (CGRect(x: b.maxX - corner, y: b.minY, width: corner, height: corner), .bottomRight),
        ] {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHoverVisible(true) }
    override func mouseExited(with event: NSEvent) { setHoverVisible(false) }

    func setHoverVisible(_ visible: Bool) {
        let show = visible && panel?.isLocked != true
        isHovering = show
        if show {
            controlsShown = true
            closeHost.isHidden = false
            barHost.isHidden = !barFits
        }
        let views: [NSView] = [closeHost, barHost, stripView]
        DSAnimation.run(.hoverControls, changes: { _ in
            for view in views { view.animator().alphaValue = show ? 1 : 0 }
        }, completion: { [weak self] in
            guard let self, !self.isHovering else { return }
            self.controlsShown = false
            self.closeHost.isHidden = true
            self.barHost.isHidden = true
        })
    }

    func setHUDVisible(_ visible: Bool) {
        if visible {
            hudHost.isHidden = false
            needsLayout = true
        }
        DSAnimation.run(visible ? .toastIn : .toastOut, changes: { _ in
            self.hudHost.animator().alphaValue = visible ? 1 : 0
        }, completion: { [weak self] in
            guard let self, self.hudHost.alphaValue == 0 else { return }
            self.hudHost.isHidden = true
        })
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let edge = PinGeometry.edge(at: point, in: bounds, band: PinInteraction.resizeEdgeBand) {
            resize = (edge, window.frame, NSEvent.mouseLocation)
            return
        }
        if event.clickCount == 2, panel?.pinDelegate?.canEditPins == true {
            panel?.requestEdit()
            return
        }
        window.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resize, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let translation = CGSize(width: mouse.x - resize.startMouse.x, height: mouse.y - resize.startMouse.y)
        panel.applyFrame(PinGeometry.resizedFrame(
            start: resize.startFrame, edge: resize.edge, translation: translation, baseSize: panel.content.pointSize
        ))
    }

    override func mouseUp(with event: NSEvent) {
        resize = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        panel?.makeContextMenu()
    }

    override func scrollWheel(with event: NSEvent) {
        panel?.handleScroll(event)
    }

    override func magnify(with event: NSEvent) {
        panel?.handleMagnify(event)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if panel?.handleKeyDown(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        return panel?.handleKeyDown(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// Layer host that never takes mouse events (they go to `PinContentView`).
private final class PinPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Target object for closure-based menu items (retained via `representedObject`).
private final class PinMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }
}

/// `NSMenuItem` that runs `handler`.
private func pinMenuItem(
    _ title: String,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = .command,
    handler: @escaping () -> Void
) -> NSMenuItem {
    let action = PinMenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(PinMenuAction.fire), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = action
    item.representedObject = action
    return item
}
