import CoreGraphics
import Foundation

/// One object on the editor canvas (plan §4.10).
///
/// Z-order is the order of `ProjectDocument.annotations` (index 0 = bottom),
/// except for the fixed render passes documented on `ProjectDocument`
/// (image content → redactions → shapes → spotlight dim).
///
/// JSON shape: `{"id": "...", "kind": "arrow", "style": {...}, "shape": {...}}`.
/// `kind` is a string tag so a future kind added by a newer app version fails
/// loudly instead of being silently mis-decoded.
public struct Annotation: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var kind: Kind
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    public enum Kind: Sendable, Hashable {
        case rectangle(RectShape)
        case filledRectangle(RectShape)
        case ellipse(RectShape)
        case line(LineShape)
        case arrow(ArrowShape)
        case text(TextShape)
        case pencil(PathShape)
        case highlighter(PathShape)
        case counter(CounterShape)
        case redaction(RedactionShape)
        case spotlight(SpotlightShape)
        case image(ImageShape)

        public var tag: KindTag {
            switch self {
            case .rectangle: .rectangle
            case .filledRectangle: .filledRectangle
            case .ellipse: .ellipse
            case .line: .line
            case .arrow: .arrow
            case .text: .text
            case .pencil: .pencil
            case .highlighter: .highlighter
            case .counter: .counter
            case .redaction: .redaction
            case .spotlight: .spotlight
            case .image: .image
            }
        }
    }

    /// String discriminator used in `project.json`.
    public enum KindTag: String, Codable, Sendable, CaseIterable {
        case rectangle, filledRectangle, ellipse, line, arrow, text
        case pencil, highlighter, counter, redaction, spotlight, image
    }

    // MARK: Convenience accessors

    public var counter: CounterShape? {
        if case .counter(let shape) = kind { return shape }
        return nil
    }

    public var isSpotlight: Bool { kind.tag == .spotlight }
    public var isRedaction: Bool { kind.tag == .redaction }
}

// MARK: - Codable

extension Annotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, style, shape
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        style = try c.decode(AnnotationStyle.self, forKey: .style)
        let tag = try c.decode(KindTag.self, forKey: .kind)
        switch tag {
        case .rectangle: kind = .rectangle(try c.decode(RectShape.self, forKey: .shape))
        case .filledRectangle: kind = .filledRectangle(try c.decode(RectShape.self, forKey: .shape))
        case .ellipse: kind = .ellipse(try c.decode(RectShape.self, forKey: .shape))
        case .line: kind = .line(try c.decode(LineShape.self, forKey: .shape))
        case .arrow: kind = .arrow(try c.decode(ArrowShape.self, forKey: .shape))
        case .text: kind = .text(try c.decode(TextShape.self, forKey: .shape))
        case .pencil: kind = .pencil(try c.decode(PathShape.self, forKey: .shape))
        case .highlighter: kind = .highlighter(try c.decode(PathShape.self, forKey: .shape))
        case .counter: kind = .counter(try c.decode(CounterShape.self, forKey: .shape))
        case .redaction: kind = .redaction(try c.decode(RedactionShape.self, forKey: .shape))
        case .spotlight: kind = .spotlight(try c.decode(SpotlightShape.self, forKey: .shape))
        case .image: kind = .image(try c.decode(ImageShape.self, forKey: .shape))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.tag, forKey: .kind)
        try c.encode(style, forKey: .style)
        switch kind {
        case .rectangle(let s), .filledRectangle(let s), .ellipse(let s): try c.encode(s, forKey: .shape)
        case .line(let s): try c.encode(s, forKey: .shape)
        case .arrow(let s): try c.encode(s, forKey: .shape)
        case .text(let s): try c.encode(s, forKey: .shape)
        case .pencil(let s), .highlighter(let s): try c.encode(s, forKey: .shape)
        case .counter(let s): try c.encode(s, forKey: .shape)
        case .redaction(let s): try c.encode(s, forKey: .shape)
        case .spotlight(let s): try c.encode(s, forKey: .shape)
        case .image(let s): try c.encode(s, forKey: .shape)
        }
    }
}

// MARK: - Handles

/// A resize/edit handle on a selected annotation.
public enum AnnotationHandle: String, Sendable, Hashable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// Line / arrow endpoints.
    case start, end
    /// Curved arrow bend point.
    case control

    static let boxHandles: [AnnotationHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
    static let cornerHandles: [AnnotationHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    var isCorner: Bool { Self.cornerHandles.contains(self) }

    /// Where this box handle sits on `rect`; `nil` for non-box handles.
    func position(on rect: CGRect) -> CGPoint? {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .start, .end, .control: nil
        }
    }
}

// MARK: - Geometry

public extension Annotation {
    /// Geometric bounds in pixels, **excluding** stroke width, shadow and arrow
    /// heads (the selection box the editor draws). For lines/arrows/paths it's
    /// the bounding box of the points.
    var bounds: CGRect {
        switch kind {
        case .rectangle(let s), .filledRectangle(let s), .ellipse(let s): s.rect
        case .line(let s): Self.boundingBox([s.start, s.end])
        case .arrow(let s): Self.boundingBox(s.polyline())
        case .text(let s): s.frame
        case .pencil(let s), .highlighter(let s): Self.boundingBox(s.points)
        case .counter(let s): s.bounds
        case .redaction(let s): s.rect
        case .spotlight(let s): s.rect
        case .image(let s): s.frame
        }
    }

    /// Bounds grown by half the stroke width (and arrow head), for invalidation
    /// and marquee selection.
    var visualBounds: CGRect {
        switch kind {
        case .arrow:
            let pad = max(style.strokeWidth / 2, ArrowShape.headHalfWidth(strokeWidth: style.strokeWidth))
            return bounds.insetBy(dx: -pad, dy: -pad)
        case .rectangle, .ellipse, .line, .pencil, .highlighter:
            return bounds.insetBy(dx: -style.strokeWidth / 2, dy: -style.strokeWidth / 2)
        default:
            return bounds
        }
    }

    /// Handles shown for this annotation when it's the single selection.
    var handles: [AnnotationHandle] {
        switch kind {
        case .line: [.start, .end]
        case .arrow(let s): s.arrowStyle == .curved ? [.start, .control, .end] : [.start, .end]
        case .text: [.left, .right]
        case .counter: AnnotationHandle.cornerHandles
        default: AnnotationHandle.boxHandles
        }
    }

    /// Position of `handle` in pixels, or `nil` if this annotation lacks it.
    func position(of handle: AnnotationHandle) -> CGPoint? {
        guard handles.contains(handle) else { return nil }
        switch (kind, handle) {
        case (.line(let s), .start): return s.start
        case (.line(let s), .end): return s.end
        case (.arrow(let s), .start): return s.start
        case (.arrow(let s), .end): return s.end
        case (.arrow(let s), .control):
            // Show the handle on the curve (t = 0.5), not at the raw control point.
            guard let c = s.resolvedControl else { return nil }
            return CGPoint(x: 0.25 * s.start.x + 0.5 * c.x + 0.25 * s.end.x,
                           y: 0.25 * s.start.y + 0.5 * c.y + 0.25 * s.end.y)
        default: return handle.position(on: bounds)
        }
    }

    /// Copy moved by `delta`.
    func translated(by delta: CGVector) -> Annotation {
        var copy = self
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.dx, y: p.y + delta.dy) }
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: delta.dx, dy: delta.dy) }
        switch kind {
        case .rectangle(var s): s.rect = move(s.rect); copy.kind = .rectangle(s)
        case .filledRectangle(var s): s.rect = move(s.rect); copy.kind = .filledRectangle(s)
        case .ellipse(var s): s.rect = move(s.rect); copy.kind = .ellipse(s)
        case .line(var s): s.start = move(s.start); s.end = move(s.end); copy.kind = .line(s)
        case .arrow(var s):
            s.start = move(s.start); s.end = move(s.end); s.control = s.control.map(move)
            copy.kind = .arrow(s)
        case .text(var s): s.frame = move(s.frame); copy.kind = .text(s)
        case .pencil(var s): s.points = s.points.map(move); copy.kind = .pencil(s)
        case .highlighter(var s): s.points = s.points.map(move); copy.kind = .highlighter(s)
        case .counter(var s): s.center = move(s.center); copy.kind = .counter(s)
        case .redaction(var s): s.rect = move(s.rect); copy.kind = .redaction(s)
        case .spotlight(var s): s.rect = move(s.rect); copy.kind = .spotlight(s)
        case .image(var s): s.frame = move(s.frame); copy.kind = .image(s)
        }
        return copy
    }

    /// Copy with `handle` dragged to `point`.
    ///
    /// - Box handles move the matching edges of `bounds`; the result is
    ///   standardized (dragging past the opposite edge flips) and at least 1 px.
    ///   `keepAspect` keeps the original aspect ratio for corner handles.
    /// - Paths scale their points from the old to the new bounds.
    /// - Counters keep their center; diameter = 2 × the larger axis distance.
    /// - Text `.left`/`.right` change the wrap width only.
    /// - `.start`/`.end`/`.control` move that point (control is set explicitly).
    /// Unsupported handles return `self` unchanged.
    func resized(handle: AnnotationHandle, to point: CGPoint, keepAspect: Bool = false) -> Annotation {
        guard handles.contains(handle) else { return self }
        var copy = self
        switch kind {
        case .line(var s):
            if handle == .start { s.start = point } else if handle == .end { s.end = point }
            copy.kind = .line(s)
        case .arrow(var s):
            switch handle {
            case .start: s.start = point
            case .end: s.end = point
            case .control:
                // `point` is where the user wants the curve's midpoint:
                // B(0.5) = 0.25 s + 0.5 c + 0.25 e  →  c = 2p - (s + e)/2.
                s.control = CGPoint(x: 2 * point.x - (s.start.x + s.end.x) / 2,
                                    y: 2 * point.y - (s.start.y + s.end.y) / 2)
            default: break
            }
            copy.kind = .arrow(s)
        case .counter(var s):
            let half = max(abs(point.x - s.center.x), abs(point.y - s.center.y))
            s.diameter = max(2 * half, 1)
            copy.kind = .counter(s)
        case .text(var s):
            var frame = s.frame
            if handle == .left {
                let newMin = min(point.x, frame.maxX - 1)
                frame = CGRect(x: newMin, y: frame.minY, width: frame.maxX - newMin, height: frame.height)
            } else if handle == .right {
                frame.size.width = max(point.x - frame.minX, 1)
            }
            s.frame = frame
            copy.kind = .text(s)
        default:
            let old = bounds
            let new = Self.resize(old, handle: handle, to: point, keepAspect: keepAspect)
            copy = copy.mapped(from: old, to: new)
        }
        return copy
    }

    // MARK: Internals

    /// Maps rect-based geometry to `new`, and path points proportionally.
    private func mapped(from old: CGRect, to new: CGRect) -> Annotation {
        var copy = self
        func map(_ p: CGPoint) -> CGPoint {
            let x = old.width > 0 ? new.minX + (p.x - old.minX) / old.width * new.width : p.x + (new.minX - old.minX)
            let y = old.height > 0 ? new.minY + (p.y - old.minY) / old.height * new.height : p.y + (new.minY - old.minY)
            return CGPoint(x: x, y: y)
        }
        switch kind {
        case .rectangle(var s): s.rect = new; copy.kind = .rectangle(s)
        case .filledRectangle(var s): s.rect = new; copy.kind = .filledRectangle(s)
        case .ellipse(var s): s.rect = new; copy.kind = .ellipse(s)
        case .redaction(var s): s.rect = new; copy.kind = .redaction(s)
        case .spotlight(var s): s.rect = new; copy.kind = .spotlight(s)
        case .image(var s): s.frame = new; copy.kind = .image(s)
        case .text(var s): s.frame = new; copy.kind = .text(s)
        case .pencil(var s): s.points = s.points.map(map); copy.kind = .pencil(s)
        case .highlighter(var s): s.points = s.points.map(map); copy.kind = .highlighter(s)
        case .line(var s): s.start = map(s.start); s.end = map(s.end); copy.kind = .line(s)
        case .arrow(var s):
            s.start = map(s.start); s.end = map(s.end); s.control = s.control.map(map)
            copy.kind = .arrow(s)
        case .counter: break
        }
        return copy
    }

    /// Moves the edges of `rect` addressed by `handle` to `point`.
    static func resize(_ rect: CGRect, handle: AnnotationHandle, to point: CGPoint, keepAspect: Bool) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        case .start, .end, .control: return rect
        }
        if keepAspect, handle.isCorner, rect.width > 0, rect.height > 0 {
            var w = maxX - minX
            var h = maxY - minY
            // Uniform scale, following whichever axis changed more (relatively).
            let sx = abs(w) / rect.width
            let sy = abs(h) / rect.height
            let s = abs(sx - 1) >= abs(sy - 1) ? sx : sy
            w = (w < 0 ? -1 : 1) * rect.width * s
            h = (h < 0 ? -1 : 1) * rect.height * s
            // Anchor = the corner opposite the dragged one.
            switch handle {
            case .topLeft: minX = maxX - w; minY = maxY - h
            case .topRight: maxX = minX + w; minY = maxY - h
            case .bottomRight: maxX = minX + w; maxY = minY + h
            case .bottomLeft: minX = maxX - w; maxY = minY + h
            default: break
            }
        }
        var result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
        result.size.width = max(result.width, 1)
        result.size.height = max(result.height, 1)
        return result
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
