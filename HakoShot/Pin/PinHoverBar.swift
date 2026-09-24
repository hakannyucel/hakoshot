import AppKit
import Observation
import SwiftUI

/// Live state the pin's SwiftUI pieces render.
@Observable
final class PinHoverModel {
    var zoom: CGFloat = 1
    var isLocked = false
    var canEdit = false
    /// Hides the lower-priority buttons when the pin is too narrow for all of them.
    var isCompact = false
    /// Text of the transient center HUD ("70%", "Copied").
    var hudText = ""
}

/// Callbacks of the hover bar buttons.
struct PinHoverActions {
    var close: () -> Void
    var toggleLock: () -> Void
    var copy: () -> Void
    var save: () -> Void
    var edit: () -> Void
    var resetZoom: () -> Void
}

/// Top-leading hover control: close (report §8: "sol-üstte X").
struct PinHoverCloseButton: View {
    let actions: PinHoverActions

    var body: some View {
        CircleIconButton(systemImage: "xmark", accessibilityLabel: "Close Pin", action: actions.close)
            .environment(\.colorScheme, .dark)
    }
}

/// Top-trailing hover group (report §8: zoom badge "100%", lock, …; plan §4.12:
/// X, zoom badge, lock, Copy). Adds Save and Edit (placeholder until the editor exists).
struct PinHoverBar: View {
    let model: PinHoverModel
    let actions: PinHoverActions

    var body: some View {
        HStack(spacing: Tokens.Pin.hoverBarItemGap) {
            Button(PinGeometry.percentText(Double(model.zoom)), action: actions.resetZoom)
                .buttonStyle(ZoomBadgeStyle())
                .help("Actual Size")
            CircleIconButton(
                systemImage: model.isLocked ? "lock.fill" : "lock.open",
                accessibilityLabel: "Lock (click-through)",
                action: actions.toggleLock
            )
            CircleIconButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy", action: actions.copy)
            if !model.isCompact {
                CircleIconButton(systemImage: "square.and.arrow.down", accessibilityLabel: "Save", action: actions.save)
                CircleIconButton(systemImage: "pencil", accessibilityLabel: "Open in Editor", action: actions.edit)
                    .disabled(!model.canEdit)
            }
        }
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// `.hudDark` pill, narrower so the badge sits well next to 30 pt circles.
private struct ZoomBadgeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.pillLabel.monospacedDigit())
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            .padding(.horizontal, Tokens.Spacing.m)
            .frame(minWidth: Tokens.Pin.zoomBadgeMinWidth)
            .frame(height: Tokens.Size.pillHeight)
            .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.hudControlFill)))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Center HUD for opacity / zoom / copy feedback.
struct PinHUDLabel: View {
    let model: PinHoverModel

    var body: some View {
        Text(model.hudText)
            .font(Tokens.Typography.pillLabel.monospacedDigit())
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            .padding(.horizontal, Tokens.Spacing.l)
            .frame(height: Tokens.Size.pillHeight + Tokens.Spacing.s)
            .hudPanel(cornerRadius: (Tokens.Size.pillHeight + Tokens.Spacing.s) / 2, blendingMode: .withinWindow, shadow: nil)
            .fixedSize()
    }
}

/// Hosting view that reacts to the first click even when the pin isn't key.
final class PinHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
