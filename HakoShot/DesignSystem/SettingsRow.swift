import SwiftUI

/// One settings line: title (+ optional gray description) on the left, trailing
/// control on the right (toggle, picker, slider, button, shortcut pill; report §12).
struct SettingsRow<Trailing: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.settingsRowTextGap) {
                Text(title)
                    .font(Tokens.Typography.rowLabel)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
                if let description {
                    Text(description)
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .labelsHidden()
                .controlSize(.regular)
        }
        .padding(.vertical, Tokens.Spacing.settingsRowV)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Trailing == EmptyView {
    /// Text-only row (no control).
    init(_ title: String, description: String? = nil) {
        self.init(title, description: description) { EmptyView() }
    }
}
