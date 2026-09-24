import AppKit
import Carbon.HIToolbox
import HakoKit
import os

/// Fullscreen recording with several displays (plan §4.1 "ekran seçici"):
/// one tinted panel per display saying "Click to record this display". A
/// click picks that display; `Esc` (global hot key, or local while we're
/// active) cancels. With a single display there is nothing to pick.
@MainActor
final class RecordingDisplayPicker {
    private var panels: [RecordingDisplayPickerPanel] = []
    private var continuation: CheckedContinuation<CGDirectDisplayID?, Never>?
    private var escape: EscapeHotKey?
    private var localMonitor: Any?

    var isRunning: Bool { continuation != nil }

    /// The chosen display, or `nil` when cancelled (or already running).
    func run(layout: DisplayLayout = DisplayLayoutProvider.currentLayout()) async -> CGDirectDisplayID? {
        guard continuation == nil else { return nil }
        if layout.displays.count <= 1 { return layout.displays.first?.id ?? layout.mainDisplayID }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    func cancel() {
        finish(nil)
    }

    private func show() {
        for screen in NSScreen.screens {
            guard let displayID = DisplayLayoutProvider.displayID(of: screen) else { continue }
            let panel = RecordingDisplayPickerPanel(screen: screen)
            panel.onClick = { [weak self] in self?.finish(displayID) }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        escape = EscapeHotKey { [weak self] in self?.cancel() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return event }
            self?.cancel()
            return nil
        }
        NSApp.activate()
        panels.first { $0.screen == NSScreen.main }?.makeKey()
        Log.recording.notice("display picker shown on \(self.panels.count) displays")
    }

    private func finish(_ displayID: CGDirectDisplayID?) {
        guard let continuation else { return }
        self.continuation = nil
        escape?.invalidate()
        escape = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        Log.recording.notice("display picker: \(displayID.map { "display \($0)" } ?? "cancelled", privacy: .public)")
        continuation.resume(returning: displayID)
    }
}

/// Full-display tinted panel with a centered label; highlights on hover.
final class RecordingDisplayPickerPanel: NSPanel {
    var onClick: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
        let view = RecordingDisplayPickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onClick = { [weak self] in self?.onClick?() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RecordingDisplayPickerView: NSView {
    var onClick: (() -> Void)?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pointer may already be inside when the panel appears.
        guard let window else { return }
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHovered ? Tokens.Recording.displayPickerHoverTint : Tokens.Recording.displayPickerTint).setFill()
        bounds.fill()

        let title = NSAttributedString(string: "Click to record this display", attributes: [
            .font: Tokens.Recording.displayPickerTitleFont,
            .foregroundColor: Tokens.Palette.hudTextPrimary,
        ])
        let hint = NSAttributedString(string: "Press Esc to cancel", attributes: [
            .font: Tokens.Recording.displayPickerHintFont,
            .foregroundColor: Tokens.Palette.hudTextSecondary,
        ])
        let titleSize = title.size()
        let hintSize = hint.size()
        let gap = Tokens.Spacing.s
        let padding = Tokens.Spacing.xl
        let contentHeight = titleSize.height + gap + hintSize.height
        let pill = CGRect(
            x: bounds.midX - (max(titleSize.width, hintSize.width) / 2 + padding),
            y: bounds.midY - (contentHeight / 2 + padding),
            width: max(titleSize.width, hintSize.width) + padding * 2,
            height: contentHeight + padding * 2
        )
        Tokens.Palette.hudControlFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: Tokens.Radius.modal, yRadius: Tokens.Radius.modal).fill()
        title.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: pill.minY + padding + hintSize.height + gap))
        hint.draw(at: CGPoint(x: bounds.midX - hintSize.width / 2, y: pill.minY + padding))
    }
}
