import SwiftUI

/// Shortcut recorder (UI report §12): a white, raised pill
/// with the combo ("⇧⌘4"), or a gray "Record Shortcut" pill when unassigned.
/// Click to record ("Type Shortcut…" with an accent ring); Esc cancels,
/// ⌫ clears. Hovering an assigned pill shows a clear button.
struct ShortcutRecorderPill: View {
    let binding: ShortcutBinding
    let model: ShortcutsSettingsModel

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var isRecording: Bool { model.isRecording(binding) }
    private var label: String? { model.label(for: binding) }

    var body: some View {
        HStack(spacing: Metrics.clearGap) {
            Text(text)
                .font(label != nil && !isRecording ? Metrics.comboFont : Metrics.placeholderFont)
                .foregroundStyle(textColor)
                .lineLimit(1)
            if showsClearButton {
                Button {
                    model.clear(binding)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Metrics.clearIconSize))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Metrics.paddingH)
        .frame(minWidth: Metrics.minWidth, minHeight: Metrics.height)
        .background { background }
        .contentShape(Capsule())
        .onTapGesture { model.toggleRecording(binding) }
        .onHover { hovering = $0 }
        .animation(DSAnimation.hoverControls, value: hovering)
        .animation(DSAnimation.hoverControls, value: isRecording)
        .help(isRecording ? "Press a shortcut. Esc cancels, ⌫ clears." : "Click to record a new shortcut")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(binding.title) shortcut")
        .accessibilityValue(isRecording ? "Recording" : (label ?? "None"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.toggleRecording(binding) }
    }

    private var text: String {
        if isRecording { return "Type Shortcut…" }
        return label ?? "Record Shortcut"
    }

    private var showsClearButton: Bool {
        hovering && !isRecording && label != nil
    }

    private var textColor: Color {
        if isRecording { return Color.dsAccent }
        return label != nil ? Color(nsColor: Tokens.Palette.textPrimary) : Color(nsColor: Tokens.Palette.textSecondary)
    }

    @ViewBuilder private var background: some View {
        if label != nil || isRecording {
            Capsule()
                .fill(colorScheme == .dark ? Metrics.raisedFillDark : Metrics.raisedFillLight)
                .overlay {
                    Capsule().strokeBorder(
                        isRecording ? Color.dsAccent : Color.primary.opacity(Metrics.borderOpacity),
                        lineWidth: isRecording ? Metrics.recordingRing : Tokens.Stroke.hairline
                    )
                }
                .shadow(color: .black.opacity(Metrics.shadowOpacity), radius: Metrics.shadowRadius, y: Metrics.shadowY)
        } else {
            Capsule()
                .fill(Color(nsColor: Tokens.Palette.neutralPillFill))
                .overlay {
                    if hovering {
                        Capsule().strokeBorder(Color.primary.opacity(Metrics.borderOpacity), lineWidth: Tokens.Stroke.hairline)
                    }
                }
        }
    }

    /// Pill metrics (estimated from the UI report).
    private enum Metrics {
        static let height: CGFloat = 24
        static let minWidth: CGFloat = 96
        static let paddingH: CGFloat = 12
        static let clearGap: CGFloat = 4
        static let clearIconSize: CGFloat = 11
        static let recordingRing: CGFloat = 1.5
        static let borderOpacity = 0.10
        static let shadowOpacity = 0.10
        static let shadowRadius: CGFloat = 1.5
        static let shadowY: CGFloat = 0.5
        static let comboFont = Font.system(size: 12.5, weight: .medium)
        static let placeholderFont = Font.system(size: 12, weight: .regular)
        static let raisedFillLight = Color.white
        static let raisedFillDark = Color(white: 0.30)
    }
}
