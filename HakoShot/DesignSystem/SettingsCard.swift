import SwiftUI

/// Settings group: optional bold section header above a rounded, borderless-looking
/// card whose rows are separated by hairline dividers (report §12).
///
/// ```swift
/// SettingsCard("After capture") {
///     SettingsRow("Play sound") { Toggle("", isOn: $sound) }
///     SettingsRow("Show Quick Access", description: "…") { Toggle("", isOn: $qa) }
/// }
/// ```
struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.settingsSectionHeaderGap) {
            if let title {
                Text(title)
                    .font(Tokens.Typography.sectionHeader)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
                    .padding(.leading, Tokens.Spacing.xs)
            }

            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.dsDivider)
                                .frame(height: Tokens.Stroke.hairline)
                                .padding(.leading, Tokens.Spacing.settingsRowH)
                        }
                        subviews[index]
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                    .fill(Color.dsSettingsCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                            .strokeBorder(Color(nsColor: Tokens.Palette.settingsCardBorder), lineWidth: Tokens.Stroke.hairline)
                    }
                    .dsShadow(.settingsCard)
            }
        }
    }
}
