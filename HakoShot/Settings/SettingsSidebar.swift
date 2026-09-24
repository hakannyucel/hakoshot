import AppKit
import SwiftUI

/// Settings window layout. Spacing, radii, colors and fonts come from `Tokens`;
/// the remaining values are window/sidebar geometry specific to this window.
enum SettingsMetrics {
    /// Report §12: 1620×1320 px @2x screenshots.
    static let windowSize = CGSize(width: 810, height: 660)
    static let sidebarWidth: CGFloat = 220
    static let sidebarPadding = Tokens.Spacing.s
    static let rowSpacing = Tokens.Spacing.xxs
    static let rowHeight: CGFloat = 32
    static let rowPadding = Tokens.Spacing.s
    static let rowRadius = Tokens.Radius.toolHighlight
    /// Sidebar badges are smaller than the report's 36 pt (a compact 32 pt row).
    static let badgeSize: CGFloat = 22
    static let badgeRadius: CGFloat = 6
    static let badgeIconSize = Tokens.Size.circleButtonIcon
    static let headerIconSize: CGFloat = 40
    static let pagePadding = Tokens.Spacing.xl
    static let titleTopPadding = Tokens.Spacing.s
    static let selectionFill = Color(nsColor: Tokens.Palette.selectionFill)
    /// Annotate color dots (ring included).
    static let colorSwatch: CGFloat = 24
    /// Wallpaper gradient grid cell (report §12 thumbnails, scaled to the card).
    static let wallpaperSwatch: CGFloat = 52
    static let wallpaperSwatchRadius = Tokens.Radius.toolHighlight
    static let wallpaperPreviewHeight: CGFloat = 150
    /// File name chip editor (report §12 `settings14.png`).
    static let chipHeight: CGFloat = 24
    static let chipPaddingH = Tokens.Spacing.s
    static let chipFill = Color.accentColor.opacity(0.16)
    static let modalWidth: CGFloat = 560
}

/// Settings pages in sidebar order (plan §5.3). About is pinned to the bottom.
///
/// To add a page: add a case here, fill `title`/`symbol`/`badgeColor`, add its
/// view in `SettingsPageView`, and put the view in `Settings/Pages/<Name>SettingsPage.swift`.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case quickAccess
    case wallpaper
    case screenshots
    case recording
    case annotate
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .quickAccess: "Quick Access"
        case .wallpaper: "Wallpaper"
        case .screenshots: "Screenshots"
        case .recording: "Screen Recording"
        case .annotate: "Annotate"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .quickAccess: "rectangle.on.rectangle"
        case .wallpaper: "photo"
        case .screenshots: "camera"
        case .recording: "video"
        case .annotate: "pencil.tip"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// Sidebar badge colors (UI report §12).
    var badgeColor: Color {
        switch self {
        case .general: Color(.systemGray)
        case .shortcuts: Color(white: 0.3)
        case .quickAccess: Color(.systemGreen)
        case .wallpaper: Color(.systemTeal)
        case .screenshots: Color(.systemBlue)
        case .recording: Color(.systemRed)
        case .annotate: Color(.systemOrange)
        case .advanced: Color(.systemPurple)
        case .about: Color(.systemGray)
        }
    }

    /// Pages shown in the main list (About is rendered separately at the bottom).
    static var mainPages: [SettingsPage] { allCases.filter { $0 != .about } }
}

/// Maps a page to its content view.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .quickAccess: QuickAccessSettingsPage()
        case .wallpaper: WallpaperSettingsPage()
        case .screenshots: ScreenshotsSettingsPage()
        case .recording: RecordingSettingsPage()
        case .annotate: AnnotateSettingsPage()
        case .advanced: AdvancedSettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            header
                .padding(.bottom, SettingsMetrics.rowPadding)
            ForEach(SettingsPage.mainPages) { page in
                row(page)
            }
            Spacer(minLength: 0)
            row(.about)
        }
        .padding(SettingsMetrics.sidebarPadding)
        .padding(.top, SettingsMetrics.pagePadding) // clear the transparent titlebar
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: SettingsMetrics.rowPadding) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: SettingsMetrics.headerIconSize, height: SettingsMetrics.headerIconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text("HakoShot").font(.headline)
                Text("Version \(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowPadding)
    }

    private func row(_ page: SettingsPage) -> some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: SettingsMetrics.rowPadding) {
                Image(systemName: page.symbol)
                    .font(.system(size: SettingsMetrics.badgeIconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: SettingsMetrics.badgeSize, height: SettingsMetrics.badgeSize)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsMetrics.badgeRadius)
                            .fill(page.badgeColor.gradient)
                    )
                Text(page.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.rowPadding)
            .frame(height: SettingsMetrics.rowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .fill(selection == page ? SettingsMetrics.selectionFill : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }
}
