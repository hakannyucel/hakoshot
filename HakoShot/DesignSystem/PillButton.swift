import AppKit
import SwiftUI

/// Capsule-shaped button family (report §4, §7, §9.1, §10, §12).
enum PillStyle: Sendable {
    /// Accent fill, white text: "Done", "Crop", "Restore", active History filter.
    case primary
    /// Neutral gray on light surfaces: "Save as…", "Choose…", settings buttons.
    case neutral
    /// Light (near white) pill on dark HUD: Quick Access "Copy"/"Save", scrolling "Done", tooltips.
    case hudLight
    /// Dark translucent pill on HUD: "Cancel", inactive History filters, "100%" zoom badge.
    case hudDark
}

struct PillButtonStyle: ButtonStyle {
    var style: PillStyle = .neutral
    /// Stretch to the available width (e.g. stacked Quick Access pills).
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: style, fillsWidth: fillsWidth)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let style: PillStyle
        let fillsWidth: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Tokens.Typography.pillLabel)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, Tokens.Spacing.pillPaddingH)
                .frame(minWidth: Tokens.Size.pillMinWidth, maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: Tokens.Size.pillHeight)
                .background(Capsule(style: .continuous).fill(background))
                .contentShape(Capsule(style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(DSAnimation.hoverControls, value: hovering)
                .animation(DSAnimation.hoverControls, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch style {
            case .primary: .white
            case .neutral: Color(nsColor: Tokens.Palette.textPrimary)
            case .hudLight: Color(nsColor: Tokens.Palette.hudTextOnLight)
            case .hudDark: Color(nsColor: Tokens.Palette.hudTextPrimary)
            }
        }

        private var background: Color {
            switch style {
            case .primary:
                Color.accentColor.opacity(hovering ? 0.88 : 1)
            case .neutral:
                Color(nsColor: hovering ? Tokens.Palette.selectionFill : Tokens.Palette.neutralPillFill)
            case .hudLight:
                Color(nsColor: hovering ? Tokens.Palette.hudLightFillHover : Tokens.Palette.hudLightFill)
            case .hudDark:
                Color(nsColor: hovering ? Tokens.Palette.hudControlFillHover : Tokens.Palette.hudControlFill)
            }
        }
    }
}

/// Convenience pill: optional leading SF Symbol + title.
struct PillButton: View {
    let title: String
    var systemImage: String?
    var style: PillStyle = .neutral
    var fillsWidth = false
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        style: PillStyle = .neutral,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.pillIconGap) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                        .fontWeight(.semibold)
                }
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle(style: style, fillsWidth: fillsWidth))
    }
}
