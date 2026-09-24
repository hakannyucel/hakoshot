import Foundation

/// An sRGB color with straight (non-premultiplied) alpha, components in `0...1`.
///
/// Encoded in `project.json` as a `#RRGGBBAA` hex string (plan §4.9; components
/// quantize to 8 bits on save, so build colors from hex/8-bit values), which keeps
/// the file readable and diff-friendly. The renderer converts it with
/// `CGColor(srgbRed:green:blue:alpha:)`.
public struct RGBAColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (leading `#` optional).
    public init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        if string.count == 3 {
            string = string.map { "\($0)\($0)" }.joined()
        }
        if string.count == 6 { string += "FF" }
        guard string.count == 8, let value = UInt32(string, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            alpha: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBBAA`, uppercase.
    public var hexString: String {
        func byte(_ component: Double) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// WCAG relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Black or white, whichever reads better on top of `self`. Used for text on
    /// boxed text styles and for counter digits on light fills.
    public var contrastingColor: RGBAColor {
        relativeLuminance > 0.5 ? .black : .white
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

extension RGBAColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let color = RGBAColor(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid color hex '\(string)'")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

// MARK: - Palette (plan §5.4)

public extension RGBAColor {
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)

    static let annotationPink = RGBAColor(hex: "#FF375F") ?? .black
    static let annotationRed = RGBAColor(hex: "#FF3B30") ?? .black
    static let annotationOrange = RGBAColor(hex: "#FF9500") ?? .black
    static let annotationYellow = RGBAColor(hex: "#FFCC00") ?? .black
    static let annotationGreen = RGBAColor(hex: "#34C759") ?? .black
    static let annotationBlue = RGBAColor(hex: "#0A84FF") ?? .black
    static let annotationPurple = RGBAColor(hex: "#AF52DE") ?? .black

    /// Highlighter default: yellow `#FFEB3B`. Opacity (45 %) lives in the style.
    static let highlighterYellow = RGBAColor(hex: "#FFEB3B") ?? .black

    /// The fixed swatches in the editor's color popover, in display order.
    static let annotationPalette: [RGBAColor] = [
        .annotationPink, .annotationRed, .annotationOrange, .annotationYellow,
        .annotationGreen, .annotationBlue, .annotationPurple, .black, .white,
    ]

    /// Default annotation color (pink).
    static let defaultAnnotation: RGBAColor = .annotationPink
}
