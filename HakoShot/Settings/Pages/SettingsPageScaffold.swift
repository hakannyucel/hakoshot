import SwiftUI

/// Common page chrome: large title + scrollable content.
struct SettingsPageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.cardGap) {
                Text(title)
                    .font(Tokens.Typography.settingsTitle)
                    .padding(.top, SettingsMetrics.titleTopPadding)
                content
            }
            .padding(SettingsMetrics.pagePadding)
            .padding(.top, SettingsMetrics.pagePadding) // clear the transparent titlebar
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

