import CoreGraphics
import Foundation

// Shape payloads for `Annotation.Kind`. Every coordinate and length is in the
// base canvas's image **pixel** space (top-left origin, y down), before crop.
// The doc comments double as the rendering spec for WP4.2 (`Rendering/*`).
// `w` below means `style.strokeWidth`.

// MARK: - Rect-based shapes

/// Geometry for rectangle, filled rectangle and ellipse.
///
/// Rendering:
/// - **rectangle**: stroke of width `w` centered on `rect` (half inside, half
///   outside), corner radius `cornerRadius`, round joins. If `style.fill` is set,
///   fill the interior with it first.
/// - **filledRectangle**: fill `rect` with `style.color`, corner radius
///   `cornerRadius`; no stroke.
/// - **ellipse**: stroke of width `w` on the ellipse inscribed in `rect`
///   (`cornerRadius` ignored); optional `style.fill` interior.
public struct RectShape: Codable, Sendable, Hashable {
    /// Always stored standardized (non-negative width/height).
    public var rect: CGRect
    public var cornerRadius: Double

    public init(rect: CGRect, cornerRadius: Double = 0) {
        self.rect = rect.standardized
        self.cornerRadius = cornerRadius
    }
}

// MARK: - Line

/// Straight line from `start` to `end`.
///
/// Rendering: stroke width `w`, **round** caps.
public struct LineShape: Codable, Sendable, Hashable {
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

// MARK: - Arrow

/// The four arrow styles (plan §5.4). Head sits at `end`.
public enum ArrowStyle: String, Codable, Sendable, CaseIterable {
    /// Straight shaft (width `w`, round tail cap) ending at the base of a
    /// filled isosceles triangle head. Head length `ArrowShape.headLength(w)`,
    /// head half-width `ArrowShape.headHalfWidth(w)`; the head tip is exactly
    /// `end`, and the shaft stops at the head base so it doesn't poke through.
    case standard
    /// Quadratic Bézier `start → resolvedControl → end`, stroke width `w`, round
    /// tail cap. The head is the standard head, oriented along the curve's end
    /// tangent (`end - control`).
    case curved
    /// A single filled polygon: a body that tapers from half-width `0.25·w` at
    /// `start` to half-width `w` at the head base, then a head of half-width
    /// `2·w` and length `4·w` (min 12 px). No stroke.
    case thick
    /// Like `standard`, with a second, mirrored head at `start`.
    case doubleHeaded
}

/// Geometry for arrows. `control` is only used by `.curved`.
public struct ArrowShape: Codable, Sendable, Hashable {
    public var start: CGPoint
    public var end: CGPoint
    /// Quadratic Bézier control point for curved arrows. `nil` means "default
    /// bend" (see `resolvedControl`). Ignored by the other styles.
    public var control: CGPoint?
    public var arrowStyle: ArrowStyle

    public init(start: CGPoint, end: CGPoint, control: CGPoint? = nil, arrowStyle: ArrowStyle = .standard) {
        self.start = start
        self.end = end
        self.control = control
        self.arrowStyle = arrowStyle
    }

    /// For `.curved`: `control`, or if `nil` the chord midpoint pushed
    /// perpendicular (to the left of start→end in image space) by 20 % of the
    /// chord length. `nil` for non-curved styles.
    public var resolvedControl: CGPoint? {
        guard arrowStyle == .curved else { return nil }
        if let control { return control }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Perpendicular (dy, -dx) scaled to 20 % of length == (dy, -dx) * 0.2.
        return CGPoint(x: mid.x + dy * 0.2, y: mid.y - dx * 0.2)
    }

    /// Head length for stroke width `w` (standard / curved / double-headed / thick).
    public static func headLength(strokeWidth w: Double) -> Double {
        max(4 * w, 12)
    }

    /// Head half-width (perpendicular to the shaft) for stroke width `w`.
    public static func headHalfWidth(strokeWidth w: Double) -> Double {
        max(2 * w, 8)
    }

    /// The path the arrow follows, as a polyline (used by hit-testing; the
    /// renderer should draw the true curve). Curved arrows are sampled.
    public func polyline(samples: Int = 24) -> [CGPoint] {
        guard let c = resolvedControl else { return [start, end] }
        let n = max(samples, 2)
        return (0...n).map { i in
            let t = Double(i) / Double(n)
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * start.x + 2 * mt * t * c.x + t * t * end.x,
                y: mt * mt * start.y + 2 * mt * t * c.y + t * t * end.y
            )
        }
    }
}

// MARK: - Text

/// The seven text styles (plan §5.4). "Box" metrics: horizontal padding
/// `0.35·fontSize`, vertical padding `0.15·fontSize`, drawn around the laid-out
/// text's used rect (not the whole `frame`).
public enum TextStyle: String, Codable, Sendable, CaseIterable {
    /// System font (SF Pro) bold, glyphs filled with `style.color`.
    case standard
    /// SF Pro Rounded bold, filled with `style.color`.
    case rounded
    /// SF Mono semibold, filled with `style.color`.
    case monospaced
    /// SF Pro bold; glyphs filled with `style.color` over an outline stroke of
    /// `style.color.contrastingColor`, outline width `0.15·fontSize` (stroke drawn
    /// first, fill on top so the outline only shows outside the glyphs).
    case outlined
    /// SF Pro bold in `style.color.contrastingColor` on a box filled with
    /// `style.color`, box corner radius `0.1·fontSize`.
    case boxed
    /// As `boxed`, box corner radius `0.45·fontSize` (pill-like).
    case roundBoxed
    /// SF Mono semibold, boxed like `boxed`.
    case monospacedBoxed

    public var isBoxed: Bool {
        switch self {
        case .boxed, .roundBoxed, .monospacedBoxed: true
        default: false
        }
    }
}

public enum TextAlignmentMode: String, Codable, Sendable, CaseIterable {
    case left, center, right
}

/// A text box. Plain string + single style (no per-range attributes; HakoKit
/// has no AppKit, and the text tool is single-style). Emoji are just
/// characters in `text`.
///
/// Rendering: CoreText, wrapped to `frame.width`, starting at `frame.origin`
/// (top-left), line height from the font. `frame.height` is kept up to date by
/// the editor after layout (it's what hit-testing and selection use); the
/// renderer does not clip to it. `style.strokeWidth` is not used.
public struct TextShape: Codable, Sendable, Hashable {
    public var text: String
    public var frame: CGRect
    /// Font size in pixels.
    public var fontSize: Double
    public var textStyle: TextStyle
    public var alignment: TextAlignmentMode

    public init(
        text: String,
        frame: CGRect,
        fontSize: Double,
        textStyle: TextStyle = .standard,
        alignment: TextAlignmentMode = .left
    ) {
        self.text = text
        self.frame = frame.standardized
        self.fontSize = fontSize
        self.textStyle = textStyle
        self.alignment = alignment
    }
}

// MARK: - Freehand paths (pencil, highlighter)

/// A freehand path. `points` are already smoothed (`PathSmoothing.smooth`
/// runs when the drag ends).
///
/// Rendering:
/// - **pencil**: Catmull–Rom spline through `points`
///   (`PathSmoothing.cubicSegments`), stroke width `w`, round caps and joins.
///   A single point renders as a dot of diameter `w`.
/// - **highlighter**: same curve, drawn in a transparency layer with
///   `style.opacity` (default 0.45) using **multiply** blend mode, round caps,
///   no shadow. Drawn as one path so self-overlaps don't darken.
public struct PathShape: Codable, Sendable, Hashable {
    public var points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }
}

// MARK: - Counter

/// Counter badge appearance.
public enum CounterStyle: String, Codable, Sendable, CaseIterable {
    /// Circle filled with `style.color`; digits bold (SF Pro Rounded) in
    /// `style.color.contrastingColor`.
    case filledCircle
    /// White circle with a `style.color` ring (ring width `0.1·diameter`);
    /// digits in `style.color`.
    case outlinedCircle
    /// Rounded square (corner radius `0.25·diameter`) filled with `style.color`;
    /// digits in `style.color.contrastingColor`.
    case filledSquare
}

/// A numbered step marker.
///
/// Rendering: badge centered on `center`, height `diameter`. Digit font size
/// `0.55·diameter`. For numbers whose text is wider than `0.7·diameter` the
/// badge widens into a capsule (width = text width + `0.5·diameter`).
/// Shadow per `style.shadow`.
public struct CounterShape: Codable, Sendable, Hashable {
    public var center: CGPoint
    public var number: Int
    /// Badge height (and circle diameter) in pixels. Created as
    /// `max(5·w, 24·scale)` (plan §5.4).
    public var diameter: Double
    public var counterStyle: CounterStyle

    public init(center: CGPoint, number: Int, diameter: Double, counterStyle: CounterStyle = .filledCircle) {
        self.center = center
        self.number = number
        self.diameter = diameter
        self.counterStyle = counterStyle
    }

    public var bounds: CGRect {
        CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }
}

// MARK: - Redaction

/// Redaction methods (plan §4.10): Pixelate, Secure Blur, Smooth
/// Blur and Black Out.
public enum RedactionMethod: String, Codable, Sendable, CaseIterable {
    /// Blocks of `strength` px (block-average colors); each block's average gets
    /// a deterministic ±6 % brightness jitter from `seed` so the original can't
    /// be recovered by re-pixelating guesses.
    case pixelate
    /// Gaussian blur with radius `strength` px (input clamped to extent so edges
    /// don't fade), then pixelate with 4 px blocks + the same jitter.
    case secureBlur
    /// Plain Gaussian blur, radius `strength` px, clamped to extent. Looks nice,
    /// not secure — the UI should say so.
    case smoothBlur
    /// Solid fill with `style.color` (default black); `strength` unused.
    case blackOut

    /// Default `strength` in points (× canvas scale at creation).
    public var defaultStrengthPoints: Double {
        switch self {
        case .pixelate: 12
        case .secureBlur, .smoothBlur: 20
        case .blackOut: 0
        }
    }
}

/// A redacted region.
///
/// Rendering: redactions are a special layer drawn **after the base image and
/// combined images but before every other annotation**, sampling only the
/// image content underneath `rect` (never other annotations). Effect results
/// should be cached by (id, rect, method, strength, seed).
public struct RedactionShape: Codable, Sendable, Hashable {
    public var rect: CGRect
    public var method: RedactionMethod
    /// Block size (pixelate) or blur radius (blurs), in pixels.
    public var strength: Double
    /// Seed for the pixelate jitter, so rendering is deterministic (WYSIWYG
    /// between canvas and export) yet differs per redaction.
    public var seed: UInt32

    public init(rect: CGRect, method: RedactionMethod = .pixelate, strength: Double, seed: UInt32) {
        self.rect = rect.standardized
        self.method = method
        self.strength = strength
        self.seed = seed
    }
}

// MARK: - Spotlight

/// A spotlight hole.
///
/// Rendering: spotlights are drawn **last**, as one combined layer: fill the
/// whole visible canvas with black at `dimOpacity` (max over all spotlights),
/// minus the union of every spotlight's rounded rect (corner radius
/// `cornerRadius`; with `isEllipse` the inscribed ellipse). Style color /
/// stroke / shadow are unused.
public struct SpotlightShape: Codable, Sendable, Hashable {
    public var rect: CGRect
    public var cornerRadius: Double
    public var dimOpacity: Double
    public var isEllipse: Bool

    public init(rect: CGRect, cornerRadius: Double, dimOpacity: Double = 0.6, isEllipse: Bool = false) {
        self.rect = rect.standardized
        self.cornerRadius = cornerRadius
        self.dimOpacity = dimOpacity
        self.isEllipse = isEllipse
    }
}

// MARK: - Image (combine, M5)

/// An additional image placed on the canvas (combine / "Add image", M5).
///
/// Rendering: the asset is drawn scaled into `frame`. Image annotations are part
/// of the "image content" pass together with the base layers (so redactions can
/// cover them), in array order. Style shadow applies.
public struct ImageShape: Codable, Sendable, Hashable {
    public var assetID: AssetID
    public var frame: CGRect

    public init(assetID: AssetID, frame: CGRect) {
        self.assetID = assetID
        self.frame = frame.standardized
    }
}
