import Foundation
import HakoKit

/// Settings > Wallpaper: the style the editor's Background tool starts with.
/// It is the same value the editor keeps as "last used"
/// (`editorBackgroundLastStyle`, read by `EditorViewModel.defaultBackgroundStyle`),
/// so choosing here takes effect in the next editor right away, and the
/// editor's own changes show up here.
nonisolated enum WallpaperDefaults {
    static func style(from json: String) -> BackgroundStyle {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data) else { return .standard }
        return style
    }

    /// JSON for `editorBackgroundLastStyle`. Image fills belong to one
    /// document, so they fall back to the default gradient.
    static func json(for style: BackgroundStyle) -> String {
        guard let data = try? JSONEncoder().encode(BackgroundPresetStore.portable(style)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fills offered on the page: catalog gradients, then plain colors.
    static var gradientFills: [BackgroundFill] {
        GradientCatalog.gradients.map { .preset($0.id) }
    }

    static var solidFills: [BackgroundFill] {
        GradientCatalog.solidColors.map { .solid($0) }
    }

    static func title(for fill: BackgroundFill) -> String {
        switch fill {
        case let .preset(id): GradientCatalog.preset(id: id)?.name ?? id
        case .gradient: "Custom Gradient"
        case let .solid(color): String(color.hexString.prefix(7))
        case .image: "Image"
        case .blurredScreenshot: "Blurred Screenshot"
        case .transparent: "Transparent"
        }
    }
}
