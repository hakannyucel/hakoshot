import Foundation

/// A built-in background gradient. `id` is stored in project files
/// (`BackgroundFill.preset`) and must never change once shipped.
public struct GradientPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var spec: GradientSpec

    public init(id: String, name: String, spec: GradientSpec) {
        self.id = id
        self.name = name
        self.spec = spec
    }
}

/// HakoShot's own background gradients and plain colors (plan §5.4: our own
/// designs, no third-party wallpapers). Each gradient is a linear base with a
/// couple of soft radial glows for a mesh-like look.
///
/// Ids are stable: never rename or remove one; append new presets instead.
public enum GradientCatalog {
    /// The default Background tool fill.
    public static let defaultPresetID = "aurora"

    public static let gradients: [GradientPreset] = [
        preset("aurora", "Aurora", ["#3B1C8C", "#6D28D9", "#0E7490"], angle: 135, glows: [
            glow("#22D3EE", 0.9, 0.15, 0.55), glow("#C026D3", 0.05, 0.95, 0.6), glow("#818CF8", 0.35, 0.3, 0.4),
        ]),
        preset("sunset", "Sunset", ["#FF6B6B", "#FF8E53", "#FFC371"], angle: 120, glows: [
            glow("#FF3CAC", 0.05, 0.05, 0.6), glow("#FFE29F", 0.95, 0.95, 0.5),
        ]),
        preset("ocean", "Ocean", ["#0B1D3A", "#123A6B", "#1C6E8C"], angle: 150, glows: [
            glow("#38BDF8", 0.85, 0.2, 0.55), glow("#2DD4BF", 0.15, 0.95, 0.5),
        ]),
        preset("peach", "Peach", ["#FFE1E8", "#FFD6C0", "#CFF5F3"], angle: 135, glows: [
            glow("#FFB4C6", 0.1, 0.15, 0.5), glow("#A5F3EC", 0.95, 0.9, 0.55),
        ]),
        preset("lagoon", "Lagoon", ["#0FB889", "#27C4C6", "#3A8DDE"], angle: 135, glows: [
            glow("#A7F3D0", 0.1, 0.1, 0.45), glow("#1E40AF", 0.95, 0.95, 0.5),
        ]),
        preset("grape", "Grape", ["#4C1D95", "#7E22CE", "#DB2777"], angle: 125, glows: [
            glow("#F472B6", 0.9, 0.2, 0.5), glow("#312E81", 0.1, 0.9, 0.55),
        ]),
        preset("citrus", "Citrus", ["#FDE047", "#FB923C", "#F43F5E"], angle: 145, glows: [
            glow("#FEF9C3", 0.1, 0.1, 0.45), glow("#E11D48", 0.9, 0.95, 0.5),
        ]),
        preset("mint", "Mint", ["#E3FCD2", "#B9F0C8", "#9ADFD8"], angle: 135, glows: [
            glow("#FFFFFF", 0.2, 0.15, 0.45), glow("#6EE7B7", 0.9, 0.85, 0.5),
        ]),
        preset("blush", "Blush", ["#F9C5E3", "#D9C2F0", "#B3C8F5"], angle: 135, glows: [
            glow("#FBCFE8", 0.1, 0.1, 0.5), glow("#A5B4FC", 0.9, 0.9, 0.55),
        ]),
        preset("midnight", "Midnight", ["#0A0E1A", "#141B2E", "#1E2745"], angle: 160, glows: [
            glow("#4F46E5", 0.85, 0.1, 0.55), glow("#0EA5E9", 0.1, 0.95, 0.45),
        ]),
        preset("ember", "Ember", ["#1C0A1E", "#4A0E1E", "#7C1D0E"], angle: 140, glows: [
            glow("#F97316", 0.9, 0.9, 0.55), glow("#BE123C", 0.15, 0.2, 0.5),
        ]),
        preset("sky", "Sky", ["#BFD9FF", "#A8C8FA", "#CDEBFB"], angle: 180, glows: [
            glow("#FFFFFF", 0.8, 0.15, 0.5), glow("#93C5FD", 0.1, 0.9, 0.5),
        ]),
        preset("coral", "Coral", ["#FF9A8B", "#FF6A88", "#FF99AC"], angle: 135, glows: [
            glow("#FFD1C1", 0.9, 0.1, 0.45), glow("#E8457C", 0.1, 0.95, 0.5),
        ]),
        preset("forest", "Forest", ["#0F3B3A", "#1F5F4A", "#4E8F5F"], angle: 135, glows: [
            glow("#8BC34A", 0.9, 0.9, 0.5), glow("#0D9488", 0.1, 0.1, 0.5),
        ]),
        preset("lavender", "Lavender", ["#E6D5FB", "#C8D1FA", "#B6DCF8"], angle: 135, glows: [
            glow("#D8B4FE", 0.1, 0.9, 0.5), glow("#FFFFFF", 0.85, 0.1, 0.4),
        ]),
        preset("flamingo", "Flamingo", ["#F857A6", "#FF5E7A", "#FF7B54"], angle: 130, glows: [
            glow("#FDBA74", 0.95, 0.9, 0.5), glow("#C026D3", 0.05, 0.1, 0.5),
        ]),
        preset("dusk", "Dusk", ["#1E3A5F", "#3B3F74", "#5B3F7A"], angle: 135, glows: [
            glow("#F0ABFC", 0.9, 0.9, 0.5), glow("#38BDF8", 0.1, 0.1, 0.45),
        ]),
        preset("sand", "Sand", ["#F8E3B8", "#F6C99A", "#F4AE8C"], angle: 150, glows: [
            glow("#FFF7E6", 0.15, 0.1, 0.5), glow("#F59E7A", 0.9, 0.95, 0.45),
        ]),
        preset("glacier", "Glacier", ["#EEF4FF", "#DCE6FB", "#C9D8F7"], angle: 160, glows: [
            glow("#FFFFFF", 0.2, 0.2, 0.55), glow("#A5C3F5", 0.9, 0.9, 0.5),
        ]),
        preset("neon", "Neon", ["#12C2E9", "#8B5CF6", "#F64F59"], angle: 120, glows: [
            glow("#22D3EE", 0.05, 0.05, 0.45), glow("#EC4899", 0.95, 0.95, 0.45),
        ]),
        preset("graphite", "Graphite", ["#2A2D34", "#3A3E47", "#4A4F59"], angle: 145, glows: [
            glow("#6B7280", 0.85, 0.15, 0.5), glow("#111827", 0.1, 0.95, 0.5),
        ]),
        preset("meadow", "Meadow", ["#FEF3C7", "#D9F99D", "#86EFAC"], angle: 135, glows: [
            glow("#FDE68A", 0.1, 0.1, 0.45), glow("#34D399", 0.95, 0.95, 0.5),
        ]),
    ]

    /// Plain-color swatches (panel "Plain color" row), light to dark then hues.
    public static let solidColors: [RGBAColor] = [
        "#FFFFFF", "#F2F2F7", "#8E8E93", "#1C1C1E", "#0A84FF",
        "#5E5CE6", "#BF5AF2", "#FF375F", "#FF9F0A", "#30D158",
    ].compactMap { RGBAColor(hex: $0) }

    public static func preset(id: String) -> GradientPreset? {
        gradients.first { $0.id == id }
    }

    /// The spec for `id`, falling back to the default preset for unknown ids
    /// (a file written by a newer version with presets we don't know).
    public static func spec(for id: String) -> GradientSpec {
        preset(id: id)?.spec ?? gradients.first?.spec ?? GradientSpec(colors: [.white, .black])
    }

    // MARK: Builders

    private static func color(_ hex: String) -> RGBAColor {
        RGBAColor(hex: hex) ?? .black
    }

    /// Glow radii in the table are scaled by 1.25 (tuned visually).
    private static func glow(_ hex: String, _ x: Double, _ y: Double, _ radius: Double, alpha: Double = 0.7) -> GradientSpec.Glow {
        GradientSpec.Glow(color(hex).withAlpha(alpha), x: x, y: y, radius: radius * 1.25)
    }

    private static func preset(_ id: String, _ name: String, _ colors: [String], angle: Double, glows: [GradientSpec.Glow]) -> GradientPreset {
        GradientPreset(id: id, name: name, spec: GradientSpec(colors: colors.map(color), angle: angle, glows: glows))
    }
}
