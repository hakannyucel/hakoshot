import CoreGraphics
import Foundation

/// Visual style shared by every annotation kind. All lengths are in the
/// document's **image pixel** space (plan §3.2), so a 6 pt stroke on a 2×
/// capture is stored as `strokeWidth = 12`.
///
/// How each field is used per kind is documented on `Annotation.Kind`.
public struct AnnotationStyle: Codable, Sendable, Hashable {
    /// Stroke color; for filled shapes (filled rectangle, counter, boxed text)
    /// the fill color.
    public var color: RGBAColor
    /// Stroke width in pixels. Also drives derived sizes (arrow head, counter
    /// diameter at creation).
    public var strokeWidth: Double
    /// Whole-annotation opacity `0...1`, applied as a transparency layer
    /// (so overlapping stroke segments don't double up).
    public var opacity: Double
    /// Drop shadow on/off. Parameters are `ShadowSpec.standard`.
    public var shadow: Bool
    /// Optional interior fill for outline rectangle / ellipse. `nil` = hollow.
    /// Ignored by kinds that are inherently filled or have no interior.
    public var fill: RGBAColor?

    public init(
        color: RGBAColor = .defaultAnnotation,
        strokeWidth: Double = 12,
        opacity: Double = 1,
        shadow: Bool = true,
        fill: RGBAColor? = nil
    ) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.shadow = shadow
        self.fill = fill
    }
}

/// Shadow parameters for annotations with `style.shadow == true`
/// (plan §5.4: `0 2 6 rgba(0,0,0,0.3)`), in **points**; the renderer multiplies
/// by the canvas scale. y offset is downward in image space (top-left origin).
public struct ShadowSpec: Sendable, Hashable {
    public var offsetX: Double
    public var offsetY: Double
    public var blur: Double
    public var color: RGBAColor

    public static let standard = ShadowSpec(
        offsetX: 0, offsetY: 2, blur: 6, color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.3)
    )
}

/// The six stroke width presets (keys `1`–`6`), in points (plan §5.4).
public enum StrokeWidthPreset {
    public static let points: [Double] = [2, 4, 6, 8, 12, 20]
    /// Index into `points` (0-based) of the default preset: 3rd preset, 6 pt.
    public static let defaultIndex = 2

    /// Point value for a 0-based preset index, clamped into range.
    public static func points(at index: Int) -> Double {
        points[min(max(index, 0), points.count - 1)]
    }

    /// Pixel width for a preset on a canvas with the given backing scale.
    public static func pixels(at index: Int, scale: Double) -> Double {
        points(at: index) * scale
    }
}

/// The six text size presets, in points (plan §5.4).
public enum TextSizePreset {
    public static let points: [Double] = [14, 18, 24, 30, 40, 56]
    /// Default: 4th preset, 30 pt.
    public static let defaultIndex = 3

    public static func points(at index: Int) -> Double {
        points[min(max(index, 0), points.count - 1)]
    }

    public static func pixels(at index: Int, scale: Double) -> Double {
        points(at: index) * scale
    }
}
