import AppKit
import SwiftUI

/// Round SF Symbol button (report §7 Quick Access corners, §8 Pin bar, §9.2 editor
/// quick actions, §4 scrolling auto-scroll).
enum CircleIconStyle: Sendable {
    /// Dark translucent disc, white glyph (Quick Access / Pin hover controls).
    case hudDark
    /// White disc, black glyph (editor bottom-right actions, scrolling auto-scroll).
    case light
}

struct CircleIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var style: CircleIconStyle = .hudDark
    var diameter: CGFloat = Tokens.Size.circleButton
    let action: () -> Void

    init(
        systemImage: String,
        accessibilityLabel: String,
        style: CircleIconStyle = .hudDark,
        diameter: CGFloat = Tokens.Size.circleButton,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.style = style
        self.diameter = diameter
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * Tokens.Size.circleButtonIcon / Tokens.Size.circleButton, weight: .semibold))
        }
        .buttonStyle(CircleIconButtonStyle(style: style, diameter: diameter))
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    var style: CircleIconStyle = .hudDark
    var diameter: CGFloat = Tokens.Size.circleButton

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, style: style, diameter: diameter)
    }

    private struct CircleBody: View {
        let configuration: Configuration
        let style: CircleIconStyle
        let diameter: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(background))
                .overlay {
                    if style == .light {
                        Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: Tokens.Stroke.hairline)
                    }
                }
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(DSAnimation.hoverControls, value: hovering)
                .animation(DSAnimation.hoverControls, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch style {
            case .hudDark: Color(nsColor: Tokens.Palette.hudTextPrimary)
            case .light: Color(nsColor: Tokens.Palette.hudTextOnLight)
            }
        }

        private var background: Color {
            switch style {
            case .hudDark:
                Color(nsColor: hovering ? Tokens.Palette.hudControlFillHover : Tokens.Palette.hudControlFill)
            case .light:
                Color(nsColor: hovering ? Tokens.Palette.hudLightFillHover : Tokens.Palette.hudLightFill)
            }
        }
    }
}
