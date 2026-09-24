import AppKit
import SwiftUI

/// Small non-activating HUD shown near the cursor after `TextCaptureFlow`
/// finishes: a large "⌘V" badge for copied text, a "Copied link" pill (with
/// an "Open" button for URL payloads) for a QR/barcode, or a plain message
/// ("No text found") — plan §4.13, UI report §6. Auto-dismisses after
/// `Tokens.Duration.toastHold`, fading in/out per the toast duration tokens.
@MainActor
enum ToastHUD {
    enum Content: Equatable {
        /// Text (or a non-URL barcode payload) was copied to the clipboard.
        case commandV
        /// A barcode payload that parses as an `http(s)` URL was copied;
        /// `url` is non-nil exactly when the "Open" button should show.
        case linkCopied(url: URL?)
        case message(String)
        /// A message with an "Open Settings" button for a privacy pane
        /// (recording: camera or Input Monitoring access is off).
        case permission(String, pane: PermissionsService.Pane)
    }

    private static var panel: ToastPanel?
    private static var dismissTask: Task<Void, Never>?

    /// Shows `content` near `screenPoint` (AppKit screen space, bottom-left
    /// origin); defaults to the current mouse location. Replaces any toast
    /// already on screen.
    static func show(_ content: Content, near screenPoint: CGPoint? = nil) {
        dismissTask?.cancel()

        let anchor = screenPoint ?? NSEvent.mouseLocation
        let hostedPanel = panel ?? ToastPanel()
        panel = hostedPanel

        let hosting = ToastHostingView(rootView: ToastContentView(content: content))
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(fitting.width, 1), height: max(fitting.height, 1))
        hosting.frame = NSRect(origin: .zero, size: size)
        hostedPanel.contentView = hosting
        hostedPanel.setContentSize(size)
        hostedPanel.setFrameOrigin(origin(for: size, near: anchor))

        switch content {
        case .linkCopied(.some), .permission:
            hostedPanel.ignoresMouseEvents = false
        default:
            hostedPanel.ignoresMouseEvents = true
        }

        hostedPanel.alphaValue = 0
        hostedPanel.orderFrontRegardless()
        DSAnimation.run(.toastIn) { _ in
            hostedPanel.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Tokens.Duration.toastHold))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    /// Fades the current toast out early (e.g. a new capture started).
    static func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let hostedPanel = panel else { return }
        DSAnimation.run(.toastOut) { _ in
            hostedPanel.animator().alphaValue = 0
        } completion: {
            // A toast shown meanwhile reuses this panel; leave it up.
            guard dismissTask == nil else { return }
            hostedPanel.orderOut(nil)
        }
    }

    /// Places the toast just below/right of `point`, clamped to the
    /// containing screen's visible frame.
    private static func origin(for size: NSSize, near point: CGPoint) -> NSPoint {
        let offset: CGFloat = 18
        var origin = NSPoint(x: point.x + offset, y: point.y - size.height - offset)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 8), max(frame.minX + 8, frame.maxX - size.width - 8))
            origin.y = min(max(origin.y, frame.minY + 8), max(frame.minY + 8, frame.maxY - size.height - 8))
        }
        return origin
    }
}

/// Borderless, non-activating floating panel (mirrors `QuickAccessPanel`'s
/// setup); never steals key/focus from the app the user just pasted into.
private final class ToastPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI content draws its own token shadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click (for the QR toast's "Open" button) without the
/// panel becoming key.
private final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

private struct ToastContentView: View {
    let content: ToastHUD.Content

    var body: some View {
        Group {
            switch content {
            case .commandV:
                Text("⌘V")
                    .font(Tokens.Typography.toastGlyph)
                    .foregroundStyle(.white)
                    .frame(width: Tokens.Size.toastBadge, height: Tokens.Size.toastBadge)

            case let .linkCopied(url):
                HStack(spacing: Tokens.Spacing.m) {
                    Text("Copied link")
                        .font(Tokens.Typography.pillLabel)
                        .foregroundStyle(.white)
                    if let url {
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain)
                            .font(Tokens.Typography.pillLabel.bold())
                            .foregroundStyle(Color.dsAccent)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.s)

            case let .message(text):
                Text(text)
                    .font(Tokens.Typography.pillLabel)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Tokens.Spacing.m)
                    .padding(.vertical, Tokens.Spacing.s)

            case let .permission(text, pane):
                HStack(spacing: Tokens.Spacing.m) {
                    Text(text)
                        .font(Tokens.Typography.pillLabel)
                        .foregroundStyle(.white)
                    Button("Open Settings") { PermissionsService.openSystemSettings(pane) }
                        .buttonStyle(.plain)
                        .font(Tokens.Typography.pillLabel.bold())
                        .foregroundStyle(Color.dsAccent)
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, Tokens.Spacing.s)
            }
        }
        .fixedSize()
        .hudPanel(cornerRadius: Tokens.Radius.toastBadge, blendingMode: .behindWindow, shadow: .toast)
    }
}
