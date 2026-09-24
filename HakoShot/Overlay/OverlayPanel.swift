import AppKit

/// Borderless, transparent, full-screen panel for one display (plan §4.1).
/// Sits above menus and the Dock, joins every Space, and can become key for
/// keyboard input without activating the app.
final class OverlayPanel: NSPanel {
    /// Called for `cancelOperation` (Esc reaching the window instead of the view).
    var onCancel: (() -> Void)?

    /// `frame` is the display's `NSScreen.frame` (AppKit global coordinates).
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Explicit `false` makes fully transparent areas still receive clicks.
        ignoresMouseEvents = false
        // Mouse moves come from each view's `.activeAlways` tracking area (also
        // when the panel is not key); window-level delivery would duplicate them.
        acceptsMouseMovedEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keep the panel over the menu bar / notch area instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
