import AppKit
import HakoKit
import os
import SwiftUI

// Scrolling capture UI (UI report §4, plan §4.8): dimmed backdrop with the
// selection frame and a hint pill (click-through, so the content under the
// selection can be scrolled), a round Auto-Scroll button on the selection's
// right edge, a growing live thumbnail bottom-left, and Cancel / Done pills
// bottom-center with a status badge ("Slow down", "Auto-Scroll") above them.
// All panels belong to HakoShot, which the stream excludes, so none of this
// shows up in the capture.

/// Observable UI state, driven by the flow.
@Observable
final class ScrollingOverlayModel {
    enum Phase: Equatable {
        /// Area chosen, waiting for "Start Capture" (setting off).
        case ready
        case capturing
        case finishing
    }

    var phase: Phase = .ready
    /// Content has moved at least once (hides the hint).
    var hasProgress = false
    var isAutoScrolling = false
    var showsSlowDown = false
    /// Auto-Scroll was requested without event-posting permission.
    var needsAccessibility = false
    var preview: CGImage?

    var hintText: String? {
        switch phase {
        case .ready: "Click Start Capture, then scroll the content slowly"
        case .capturing where !hasProgress && !isAutoScrolling: "Scroll to capture, or click Auto-Scroll"
        case .capturing, .finishing: nil
        }
    }
}

/// Button actions of the scrolling UI (main actor).
struct ScrollingOverlayActions {
    var start: () -> Void = {}
    /// `horizontal` when ⌥ was held.
    var toggleAutoScroll: (_ horizontal: Bool) -> Void = { _ in }
    var cancel: () -> Void = {}
    var done: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var dismissPermissionNotice: () -> Void = {}
}

/// Pure placement math (AppKit screen coordinates, bottom-left origin).
nonisolated struct ScrollingOverlayLayout: Equatable {
    var screen: CGRect
    var selection: CGRect

    /// Center of the Auto-Scroll button: just right of the selection, or
    /// just inside its right edge when the screen edge is too close.
    var sideButtonCenter: CGPoint {
        let d = Tokens.Scrolling.sideButtonDiameter
        let gap = Tokens.Scrolling.sideButtonGap
        let outside = selection.maxX + gap + d / 2
        let x = outside + d / 2 <= screen.maxX ? outside : selection.maxX - gap - d / 2
        return CGPoint(x: x, y: selection.midY)
    }

    var controlsFrame: CGRect {
        let size = Tokens.Scrolling.controlsSize
        return CGRect(
            x: (screen.midX - size.width / 2).rounded(),
            y: screen.minY + Tokens.Scrolling.controlsBottomInset - Tokens.Scrolling.controlsSpacing,
            width: size.width, height: size.height
        )
    }

    /// Panel that holds the thumbnail (image is bottom-left aligned in it).
    var thumbnailFrame: CGRect {
        let inset = Tokens.Scrolling.thumbnailInset
        let height = (screen.height * Tokens.Scrolling.thumbnailMaxHeightFraction).rounded()
        return CGRect(x: screen.minX + inset, y: screen.minY + inset, width: Tokens.Scrolling.thumbnailMaxWidth, height: height)
    }

    /// Size of a `pixelSize` preview shown within `maxSize`, aspect kept.
    static func fittedThumbnailSize(pixelSize: CGSize, maxSize: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let scale = min(maxSize.width / pixelSize.width, maxSize.height / pixelSize.height)
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }
}

/// Owns the scrolling UI panels for one session.
final class ScrollingOverlayUI {
    let model = ScrollingOverlayModel()
    var actions = ScrollingOverlayActions()

    private let screen: NSScreen
    private let layout: ScrollingOverlayLayout
    /// Selection in the frame panel's view space (top-left origin).
    private let localSelection: CGRect
    private var panels: [NSPanel] = []
    private var controlsPanel: ScrollingPanel?
    private var keyMonitor: Any?

    /// `nil` if the display is gone.
    init?(rect: GlobalRect, displayID: CGDirectDisplayID) {
        let displayLayout = DisplayLayoutProvider.currentLayout()
        guard let screen = DisplayLayoutProvider.screen(for: displayID),
              let appKitSelection = ScreenGeometry.appKitRect(fromGlobal: rect, layout: displayLayout)
        else { return nil }
        self.screen = screen
        layout = ScrollingOverlayLayout(screen: screen.frame, selection: appKitSelection)
        localSelection = CGRect(
            x: appKitSelection.minX - screen.frame.minX,
            y: screen.frame.maxY - appKitSelection.maxY,
            width: appKitSelection.width, height: appKitSelection.height
        )
    }

    func show() {
        guard panels.isEmpty else { return }
        let actionsProxy = ActionsProxy(owner: self)

        // 1. Backdrop + frame + hint: fully click-through.
        let frame = ScrollingPanel(frame: screen.frame, level: .frame, interactive: false)
        frame.contentView = NSHostingView(rootView: ScrollingFrameView(model: model, selection: localSelection))
        // 2. Auto-Scroll button on the right edge.
        let d = Tokens.Scrolling.sideButtonDiameter
        let center = layout.sideButtonCenter
        let side = ScrollingPanel(
            frame: CGRect(x: center.x - d / 2, y: center.y - d / 2 - d, width: d, height: d * 3),
            level: .controls, interactive: true
        )
        side.contentView = NSHostingView(rootView: ScrollingSideButton(model: model, actions: actionsProxy))
        // 3. Thumbnail (click-through).
        let thumb = ScrollingPanel(frame: layout.thumbnailFrame, level: .controls, interactive: false)
        thumb.contentView = NSHostingView(rootView: ScrollingThumbnailView(model: model))
        // 4. Cancel / Done + status (key for Esc / Return).
        let controls = ScrollingPanel(frame: layout.controlsFrame, level: .controls, interactive: true, canBecomeKey: true)
        controls.contentView = NSHostingView(rootView: ScrollingControlsView(model: model, actions: actionsProxy))
        controlsPanel = controls

        panels = [frame, thumb, side, controls]
        for panel in panels {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        controls.makeKey()
        DSAnimation.run(.overlayFadeIn) { _ in
            for panel in self.panels { panel.animator().alphaValue = 1 }
        }
        installKeyMonitor()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
        controlsPanel = nil
    }

    /// Esc = Cancel, Return = Start / Done (plan §4.8).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                actions.cancel()
                return nil
            case 36, 76:
                if model.phase == .ready { actions.start() } else { actions.done() }
                return nil
            default:
                return event
            }
        }
    }

    /// Lets SwiftUI views call the current `actions` (set after `show()`).
    fileprivate struct ActionsProxy {
        weak var owner: ScrollingOverlayUI?
        func start() { owner?.actions.start() }
        func toggleAutoScroll(horizontal: Bool) { owner?.actions.toggleAutoScroll(horizontal) }
        func cancel() { owner?.actions.cancel() }
        func done() { owner?.actions.done() }
        func openAccessibilitySettings() { owner?.actions.openAccessibilitySettings() }
        func dismissPermissionNotice() { owner?.actions.dismissPermissionNotice() }
    }
}

// MARK: - Panel

private final class ScrollingPanel: NSPanel {
    enum Layer {
        case frame, controls

        var level: NSWindow.Level {
            switch self {
            case .frame: .popUpMenu
            case .controls: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            }
        }
    }

    private let allowsKey: Bool

    init(frame: CGRect, level layer: Layer, interactive: Bool, canBecomeKey: Bool = false) {
        allowsKey = canBecomeKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = layer.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = !canBecomeKey
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - Views

private struct ScrollingFrameView: View {
    let model: ScrollingOverlayModel
    let selection: CGRect

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(selection)
                }
                .fill(Color(nsColor: Tokens.Palette.selectionDim), style: FillStyle(eoFill: true))

                // 1 pt white line on the edge, 1 pt black line outside it.
                Rectangle()
                    .strokeBorder(Color(nsColor: Tokens.Overlay.frameOuterColor), lineWidth: Tokens.Overlay.frameLineWidth)
                    .frame(width: selection.width + 2 * Tokens.Overlay.frameLineWidth, height: selection.height + 2 * Tokens.Overlay.frameLineWidth)
                    .offset(x: selection.minX - Tokens.Overlay.frameLineWidth, y: selection.minY - Tokens.Overlay.frameLineWidth)
                Rectangle()
                    .strokeBorder(Color(nsColor: Tokens.Overlay.frameInnerColor), lineWidth: Tokens.Overlay.frameLineWidth)
                    .frame(width: selection.width, height: selection.height)
                    .offset(x: selection.minX, y: selection.minY)

                if let hint = model.hintText {
                    ScrollingHintPill(text: hint)
                        .position(x: selection.midX, y: selection.midY)
                        .transition(.opacity)
                }
            }
            .animation(DSAnimation.overlayFadeIn, value: model.hintText)
        }
        .ignoresSafeArea()
    }
}

/// White pill with dark text (report §4 start hint).
private struct ScrollingHintPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.Scrolling.hintFont)
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextOnLight))
            .padding(.horizontal, Tokens.Spacing.l)
            .frame(height: Tokens.Size.pillHeight + Tokens.Spacing.s)
            .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.hudLightFill)))
            .shadow(
                color: .black.opacity(Tokens.Shadow.toast.opacity),
                radius: Tokens.Shadow.toast.radius, y: Tokens.Shadow.toast.y
            )
            .fixedSize()
    }
}

private struct ScrollingSideButton: View {
    let model: ScrollingOverlayModel
    let actions: ScrollingOverlayUI.ActionsProxy

    var body: some View {
        ZStack {
            // Thin track along the edge, like a scroll bar (report §4).
            Capsule()
                .fill(Color(nsColor: Tokens.Palette.hudControlFill))
                .frame(width: Tokens.Scrolling.sideTrackWidth)
            CircleIconButton(
                systemImage: model.isAutoScrolling ? "stop.fill" : "arrow.down",
                accessibilityLabel: model.isAutoScrolling ? "Stop Auto-Scroll" : "Auto-Scroll (⌥-click: horizontal)",
                style: .light,
                diameter: Tokens.Scrolling.sideButtonDiameter
            ) {
                actions.toggleAutoScroll(horizontal: NSEvent.modifierFlags.contains(.option))
            }
            .disabled(model.phase == .finishing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScrollingThumbnailView: View {
    let model: ScrollingOverlayModel

    var body: some View {
        GeometryReader { proxy in
            if let preview = model.preview {
                let size = ScrollingOverlayLayout.fittedThumbnailSize(
                    pixelSize: CGSize(width: preview.width, height: preview.height),
                    maxSize: CGSize(
                        width: proxy.size.width - 2 * Tokens.Spacing.s,
                        height: proxy.size.height - 2 * Tokens.Spacing.s
                    )
                )
                let shape = RoundedRectangle(cornerRadius: Tokens.Scrolling.thumbnailCornerRadius, style: .continuous)
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color(nsColor: Tokens.Scrolling.thumbnailBorder), lineWidth: Tokens.Stroke.hairline))
                    .shadow(
                        color: .black.opacity(Tokens.Scrolling.thumbnailShadow.opacity),
                        radius: Tokens.Scrolling.thumbnailShadow.radius, y: Tokens.Scrolling.thumbnailShadow.y
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(Tokens.Spacing.s)
                    .animation(DSAnimation.hoverControls, value: size)
            }
        }
    }
}

private struct ScrollingControlsView: View {
    let model: ScrollingOverlayModel
    let actions: ScrollingOverlayUI.ActionsProxy

    var body: some View {
        VStack(spacing: Tokens.Scrolling.controlsSpacing) {
            Spacer(minLength: 0)
            if model.needsAccessibility {
                permissionCard
            } else if let status {
                ScrollingStatusBadge(systemImage: status.icon, text: status.text)
            }
            HStack(spacing: Tokens.Spacing.s) {
                PillButton("Cancel", systemImage: "xmark", style: .hudDark, action: actions.cancel)
                if model.phase == .ready {
                    PillButton("Start Capture", systemImage: "record.circle", style: .hudLight, action: actions.start)
                } else {
                    PillButton("Done", systemImage: "checkmark", style: .hudLight, action: actions.done)
                        .disabled(model.phase == .finishing)
                }
            }
        }
        .padding(.bottom, Tokens.Scrolling.controlsSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(DSAnimation.hoverControls, value: model.showsSlowDown)
        .animation(DSAnimation.hoverControls, value: model.isAutoScrolling)
        .animation(DSAnimation.hoverControls, value: model.needsAccessibility)
    }

    private var status: (icon: String, text: String)? {
        if model.showsSlowDown { return ("tortoise.fill", "Slow down") }
        if model.isAutoScrolling { return ("arrow.down.circle.fill", "Auto-Scroll") }
        return nil
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Auto-Scroll needs Accessibility access")
                .font(Tokens.Typography.pillLabel)
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            Text("Allow HakoShot in System Settings › Privacy & Security › Accessibility. Until then, scroll the content yourself; the capture keeps running.")
                .font(Tokens.Typography.hudLabel)
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Spacing.s) {
                PillButton("Open Settings", style: .hudLight, action: actions.openAccessibilitySettings)
                PillButton("Scroll Manually", style: .hudDark, action: actions.dismissPermissionNotice)
            }
        }
        .padding(Tokens.Spacing.m)
        .frame(width: Tokens.Scrolling.permissionCardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.modal, style: .continuous)
                .fill(Color(nsColor: Tokens.Palette.hudControlFill))
        )
    }
}

private struct ScrollingStatusBadge: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.pillIconGap) {
            Image(systemName: systemImage).imageScale(.small)
            Text(text)
        }
        .font(Tokens.Typography.pillLabel)
        .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
        .padding(.horizontal, Tokens.Spacing.pillPaddingH)
        .frame(height: Tokens.Size.pillHeight)
        .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.hudControlFill)))
        .transition(.opacity)
    }
}
