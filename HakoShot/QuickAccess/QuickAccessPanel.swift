import AppKit
import SwiftUI

/// Borderless, non-activating floating panel holding one Quick Access card (plan §1.2,
/// §4.12). Never activates the app; becomes key only while hovered so the card's
/// keyboard shortcuts work.
final class QuickAccessPanel: NSPanel {
    /// Keyboard action for this card (see `QuickAccessKeyMap`).
    var onKeyAction: ((QuickAccessAction) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // the SwiftUI card draws its own token shadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        title = "Quick Access"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onKeyAction?(.close)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let action = QuickAccessKeyMap.action(
                  keyCode: event.keyCode,
                  characters: event.charactersIgnoringModifiers,
                  modifiers: event.modifierFlags
              )
        else { return false }
        onKeyAction?(action)
        return true
    }
}

/// Panel content: hosts the SwiftUI card and tracks hover over the card rect with an
/// `.activeAlways` tracking area (SwiftUI `onHover` is unreliable while the app is
/// inactive, which is the normal state for Quick Access).
final class QuickAccessContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init<Content: View>(rootView: Content) {
        super.init(frame: .zero)
        let hosting = QuickAccessHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The card's rect inside this view (bounds minus the shadow margin).
    var cardRect: NSRect {
        bounds.insetBy(dx: QuickAccessLayout.shadowMargin, dy: QuickAccessLayout.shadowMargin)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        subviews.forEach { $0.frame = bounds }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: cardRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    /// Whether the pointer is currently over the card (used after re-layout).
    var isPointerInsideCard: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return cardRect.contains(point)
    }
}

/// Accepts the first click so buttons work even before the panel is key.
private final class QuickAccessHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
