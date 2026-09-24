import AppKit

/// Editor window: ⌘ shortcuts are resolved here first (so they work without an
/// app Edit menu), stray plain keys fall through to the canvas, and the
/// traffic lights are re-centered in the 52 pt toolbar after every layout.
final class EditorWindow: NSWindow {
    /// Runs an editor command; returns whether it was handled.
    var commandHandler: ((EditorCommand) -> Bool)?
    /// Receives plain keys nobody else handled (e.g. focus on a toolbar control).
    weak var canvas: CanvasView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let command = EditorShortcuts.commandShortcut(for: EditorKeyInput(event: event)),
           commandHandler?(command) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let canvas, firstResponder !== canvas, !(firstResponder is NSText), canvas.handleKey(event) { return }
        super.keyDown(with: event)
    }

    // MARK: Traffic lights

    /// Vertically centers the standard window buttons in the toolbar
    /// (the titlebar is only 28 pt tall by default).
    func layoutTrafficLights() {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = standardWindowButton(.closeButton),
              let titlebarView = close.superview,
              let container = titlebarView.superview
        else { return }
        let height = EditorMetrics.toolbarHeight
        let width = EditorMetrics.toolbarLeadingInset - 8
        let target = NSRect(x: 0, y: frame.height - height, width: width, height: height)
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

/// Root content view; re-applies the traffic-light layout whenever AppKit lays
/// the window out (resize, full screen, key changes).
final class EditorRootView: NSView {
    override func layout() {
        super.layout()
        (window as? EditorWindow)?.layoutTrafficLights()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        (window as? EditorWindow)?.layoutTrafficLights()
    }
}
