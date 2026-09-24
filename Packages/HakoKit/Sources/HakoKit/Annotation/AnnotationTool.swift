import CoreGraphics
import Foundation

/// Editor tools, in toolbar order, with their single-key shortcuts (plan §4.11).
public enum AnnotationTool: String, Codable, Sendable, CaseIterable {
    case move, crop, background
    case rectangle, filledRectangle, ellipse, line, arrow, text
    case pencil, highlighter, counter, redaction, spotlight

    /// Key that selects the tool (lowercase).
    public var shortcutKey: Character {
        switch self {
        case .move: "v"
        case .crop: "k"
        case .background: "b"
        case .pencil: "d"
        case .highlighter: "m"
        case .line: "l"
        case .text: "t"
        case .arrow: "a"
        case .counter: "c"
        case .ellipse: "e"
        case .redaction: "p"
        case .spotlight: "h"
        case .rectangle: "r"
        case .filledRectangle: "f"
        }
    }

    public static func tool(forShortcut key: Character) -> AnnotationTool? {
        allCases.first { $0.shortcutKey == Character(key.lowercased()) }
    }

    /// Whether dragging on the canvas with this tool creates an annotation.
    public var createsAnnotation: Bool {
        switch self {
        case .move, .crop, .background: false
        default: true
        }
    }
}

/// The current tool options shown in the option bar. Persistable (Codable,
/// missing keys fall back to defaults) so the app can remember them.
public struct ToolSettings: Sendable, Hashable {
    /// Shared color for all tools except the highlighter.
    public var color: RGBAColor = .defaultAnnotation
    /// 0-based index into `StrokeWidthPreset.points` (default 6 pt).
    public var strokePresetIndex: Int = StrokeWidthPreset.defaultIndex
    /// 0-based index into `TextSizePreset.points` (default 30 pt).
    public var textSizePresetIndex: Int = TextSizePreset.defaultIndex
    public var shadow: Bool = true
    /// Interior fill for new outline rectangles / ellipses.
    public var shapeFill: RGBAColor?
    /// Corner radius for new rectangles and filled rectangles, in points.
    public var rectangleCornerRadiusPoints: Double = 0
    public var arrowStyle: ArrowStyle = .standard
    public var textStyle: TextStyle = .standard
    public var textAlignment: TextAlignmentMode = .left
    public var counterStyle: CounterStyle = .filledCircle
    /// Number the first counter gets when the document has none (0 allowed).
    public var counterStartNumber: Int = 1
    public var redactionMethod: RedactionMethod = .pixelate
    public var highlighterColor: RGBAColor = .highlighterYellow
    public var highlighterOpacity: Double = 0.45
    /// Highlighter has its own width preset (default 20 pt).
    public var highlighterPresetIndex: Int = 5
    public var spotlightDimOpacity: Double = 0.6
    public var spotlightCornerRadiusPoints: Double = 8

    public init() {}

    /// Keys `1`–`6` edit this index for the given tool.
    public func strokePresetIndex(for tool: AnnotationTool) -> Int {
        tool == .highlighter ? highlighterPresetIndex : strokePresetIndex
    }

    public mutating func setStrokePresetIndex(_ index: Int, for tool: AnnotationTool) {
        let clamped = min(max(index, 0), StrokeWidthPreset.points.count - 1)
        if tool == .highlighter { highlighterPresetIndex = clamped } else { strokePresetIndex = clamped }
    }

    /// Style for a new annotation made with `tool` on a canvas of `scale`.
    public func style(for tool: AnnotationTool, scale: Double) -> AnnotationStyle {
        let width = StrokeWidthPreset.pixels(at: strokePresetIndex(for: tool), scale: scale)
        switch tool {
        case .highlighter:
            return AnnotationStyle(color: highlighterColor, strokeWidth: width, opacity: highlighterOpacity, shadow: false)
        case .rectangle, .ellipse:
            return AnnotationStyle(color: color, strokeWidth: width, shadow: shadow, fill: shapeFill)
        case .redaction:
            return AnnotationStyle(color: .black, strokeWidth: width, shadow: false)
        case .spotlight:
            return AnnotationStyle(color: .black, strokeWidth: width, shadow: false)
        default:
            return AnnotationStyle(color: color, strokeWidth: width, shadow: shadow)
        }
    }
}

extension ToolSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case color, strokePresetIndex, textSizePresetIndex, shadow, shapeFill, rectangleCornerRadiusPoints
        case arrowStyle, textStyle, textAlignment, counterStyle, counterStartNumber, redactionMethod
        case highlighterColor, highlighterOpacity, highlighterPresetIndex
        case spotlightDimOpacity, spotlightCornerRadiusPoints
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color) ?? color
        strokePresetIndex = try c.decodeIfPresent(Int.self, forKey: .strokePresetIndex) ?? strokePresetIndex
        textSizePresetIndex = try c.decodeIfPresent(Int.self, forKey: .textSizePresetIndex) ?? textSizePresetIndex
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? shadow
        shapeFill = try c.decodeIfPresent(RGBAColor.self, forKey: .shapeFill)
        rectangleCornerRadiusPoints = try c.decodeIfPresent(Double.self, forKey: .rectangleCornerRadiusPoints)
            ?? rectangleCornerRadiusPoints
        arrowStyle = try c.decodeIfPresent(ArrowStyle.self, forKey: .arrowStyle) ?? arrowStyle
        textStyle = try c.decodeIfPresent(TextStyle.self, forKey: .textStyle) ?? textStyle
        textAlignment = try c.decodeIfPresent(TextAlignmentMode.self, forKey: .textAlignment) ?? textAlignment
        counterStyle = try c.decodeIfPresent(CounterStyle.self, forKey: .counterStyle) ?? counterStyle
        counterStartNumber = try c.decodeIfPresent(Int.self, forKey: .counterStartNumber) ?? counterStartNumber
        redactionMethod = try c.decodeIfPresent(RedactionMethod.self, forKey: .redactionMethod) ?? redactionMethod
        highlighterColor = try c.decodeIfPresent(RGBAColor.self, forKey: .highlighterColor) ?? highlighterColor
        highlighterOpacity = try c.decodeIfPresent(Double.self, forKey: .highlighterOpacity) ?? highlighterOpacity
        highlighterPresetIndex = try c.decodeIfPresent(Int.self, forKey: .highlighterPresetIndex)
            ?? highlighterPresetIndex
        spotlightDimOpacity = try c.decodeIfPresent(Double.self, forKey: .spotlightDimOpacity) ?? spotlightDimOpacity
        spotlightCornerRadiusPoints = try c.decodeIfPresent(Double.self, forKey: .spotlightCornerRadiusPoints)
            ?? spotlightCornerRadiusPoints
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(strokePresetIndex, forKey: .strokePresetIndex)
        try c.encode(textSizePresetIndex, forKey: .textSizePresetIndex)
        try c.encode(shadow, forKey: .shadow)
        try c.encodeIfPresent(shapeFill, forKey: .shapeFill)
        try c.encode(rectangleCornerRadiusPoints, forKey: .rectangleCornerRadiusPoints)
        try c.encode(arrowStyle, forKey: .arrowStyle)
        try c.encode(textStyle, forKey: .textStyle)
        try c.encode(textAlignment, forKey: .textAlignment)
        try c.encode(counterStyle, forKey: .counterStyle)
        try c.encode(counterStartNumber, forKey: .counterStartNumber)
        try c.encode(redactionMethod, forKey: .redactionMethod)
        try c.encode(highlighterColor, forKey: .highlighterColor)
        try c.encode(highlighterOpacity, forKey: .highlighterOpacity)
        try c.encode(highlighterPresetIndex, forKey: .highlighterPresetIndex)
        try c.encode(spotlightDimOpacity, forKey: .spotlightDimOpacity)
        try c.encode(spotlightCornerRadiusPoints, forKey: .spotlightCornerRadiusPoints)
    }
}

/// Builds annotations from canvas drags, so every tool creates shapes the same
/// way. Typical editor flow (one undo step):
/// ```
/// store.beginInteraction("Add Arrow")
/// let a = AnnotationFactory.begin(tool:at:settings:scale:nextCounterNumber:)
/// store.apply(.add(a))
/// // mouseDragged:
/// store.apply(.update(AnnotationFactory.update(a, anchor: start, to: p, constrained: shift)))
/// // mouseUp:
/// if let done = AnnotationFactory.finish(current) { store.apply(.update(done)); store.endInteraction() }
/// else { store.cancelInteraction() }
/// ```
public enum AnnotationFactory {
    /// Minimum drag size (pixels) for a shape to be kept.
    public static let minimumSize = 2.0

    /// A new, zero-size annotation for `tool` at `point`. `nil` for tools that
    /// don't create annotations. `scale` is the canvas backing scale.
    public static func begin(
        tool: AnnotationTool,
        at point: CGPoint,
        settings: ToolSettings,
        scale: Double,
        nextCounterNumber: Int,
        seed: UInt32 = UInt32.random(in: .min ... .max)
    ) -> Annotation? {
        let style = settings.style(for: tool, scale: scale)
        let zero = CGRect(origin: point, size: .zero)
        let corner = settings.rectangleCornerRadiusPoints * scale
        let kind: Annotation.Kind
        switch tool {
        case .move, .crop, .background:
            return nil
        case .rectangle:
            kind = .rectangle(RectShape(rect: zero, cornerRadius: corner))
        case .filledRectangle:
            kind = .filledRectangle(RectShape(rect: zero, cornerRadius: corner))
        case .ellipse:
            kind = .ellipse(RectShape(rect: zero))
        case .line:
            kind = .line(LineShape(start: point, end: point))
        case .arrow:
            kind = .arrow(ArrowShape(start: point, end: point, arrowStyle: settings.arrowStyle))
        case .text:
            let fontSize = TextSizePreset.pixels(at: settings.textSizePresetIndex, scale: scale)
            let frame = CGRect(x: point.x, y: point.y, width: fontSize * 10, height: fontSize * 1.25)
            kind = .text(TextShape(text: "", frame: frame, fontSize: fontSize,
                                   textStyle: settings.textStyle, alignment: settings.textAlignment))
        case .pencil:
            kind = .pencil(PathShape(points: [point]))
        case .highlighter:
            kind = .highlighter(PathShape(points: [point]))
        case .counter:
            let diameter = max(5 * style.strokeWidth, 24 * scale)
            kind = .counter(CounterShape(center: point, number: nextCounterNumber, diameter: diameter,
                                         counterStyle: settings.counterStyle))
        case .redaction:
            let method = settings.redactionMethod
            kind = .redaction(RedactionShape(rect: zero, method: method,
                                             strength: method.defaultStrengthPoints * scale, seed: seed))
        case .spotlight:
            kind = .spotlight(SpotlightShape(rect: zero, cornerRadius: settings.spotlightCornerRadiusPoints * scale,
                                             dimOpacity: settings.spotlightDimOpacity))
        }
        return Annotation(kind: kind, style: style)
    }

    /// Applies a creation drag from `anchor` (mouse-down point) to `point`.
    /// `constrained` (⇧): squares/circles, 45° lines, straight freehand strokes.
    public static func update(_ annotation: Annotation, anchor: CGPoint, to point: CGPoint, constrained: Bool) -> Annotation {
        var copy = annotation
        func box() -> CGRect {
            var dx = point.x - anchor.x
            var dy = point.y - anchor.y
            if constrained {
                let side = max(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side
                dy = dy < 0 ? -side : side
            }
            return CGRect(x: anchor.x, y: anchor.y, width: dx, height: dy).standardized
        }
        let end = constrained ? snapAngle(from: anchor, to: point) : point
        switch annotation.kind {
        case .rectangle(var s): s.rect = box(); copy.kind = .rectangle(s)
        case .filledRectangle(var s): s.rect = box(); copy.kind = .filledRectangle(s)
        case .ellipse(var s): s.rect = box(); copy.kind = .ellipse(s)
        case .redaction(var s): s.rect = box(); copy.kind = .redaction(s)
        case .spotlight(var s): s.rect = box(); copy.kind = .spotlight(s)
        case .image(var s): s.frame = box(); copy.kind = .image(s)
        case .line(var s): s.start = anchor; s.end = end; copy.kind = .line(s)
        case .arrow(var s): s.start = anchor; s.end = end; copy.kind = .arrow(s)
        case .pencil(var s):
            s.points = constrained ? [anchor, end] : s.points + [point]
            copy.kind = .pencil(s)
        case .highlighter(var s):
            s.points = constrained ? [anchor, end] : s.points + [point]
            copy.kind = .highlighter(s)
        case .counter(var s): s.center = point; copy.kind = .counter(s)
        case .text: break
        }
        return copy
    }

    /// Finalizes a creation drag: smooths freehand paths and returns `nil` if
    /// the shape is too small to keep (a click without a drag). Counters and
    /// text are always kept.
    public static func finish(_ annotation: Annotation) -> Annotation? {
        var copy = annotation
        switch annotation.kind {
        case .counter, .text:
            return annotation
        case .pencil(var s):
            s.points = PathSmoothing.smooth(s.points)
            copy.kind = .pencil(s)
            return copy
        case .highlighter(var s):
            s.points = PathSmoothing.smooth(s.points)
            let box = Annotation.boundingBox(s.points)
            guard box.width + box.height >= minimumSize else { return nil }
            copy.kind = .highlighter(s)
            return copy
        case .line(let s):
            return hypot(s.end.x - s.start.x, s.end.y - s.start.y) >= minimumSize ? annotation : nil
        case .arrow(let s):
            return hypot(s.end.x - s.start.x, s.end.y - s.start.y) >= minimumSize ? annotation : nil
        default:
            let b = annotation.bounds
            return b.width >= minimumSize && b.height >= minimumSize ? annotation : nil
        }
    }

    /// Snaps `point` so the segment from `anchor` is a multiple of 45°.
    public static func snapAngle(from anchor: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: anchor.x + length * cos(angle), y: anchor.y + length * sin(angle))
    }
}
