import CoreGraphics
import CoreText
import Foundation

/// Draws individual annotations (spec: the doc comments in `Annotation/Shapes.swift`).
///
/// The context's user space must be canvas pixel space, **y-down**
/// (`DocumentRenderer` sets this up). Redactions and spotlights are layer
/// effects that need the whole document; `DocumentRenderer` draws those.
/// Selection handles are drawn by the UI, not here.
public struct AnnotationPainter: Sendable {
    /// Canvas backing scale (points → pixels) for point-based constants (shadow).
    public var canvasScale: Double
    /// Device pixels per context base unit; see `RenderSupport.setShadow`.
    /// 1 for bitmap contexts, the backing scale for AppKit view contexts.
    public var baseScale: Double

    public init(canvasScale: Double, baseScale: Double = 1) {
        self.canvasScale = canvasScale
        self.baseScale = baseScale
    }

    // MARK: Bounds

    /// Everything the annotation can touch when drawn (stroke, arrow heads,
    /// text boxes, shadow), in canvas pixels. Use for culling / invalidation.
    public func paintedBounds(of annotation: Annotation) -> CGRect {
        var rect: CGRect
        switch annotation.kind {
        case .text(let shape):
            rect = textBoxRect(shape: shape, layout: TextLayout(shape: shape)).union(shape.frame)
            if shape.textStyle == .outlined { rect = rect.insetBy(dx: -0.15 * shape.fontSize, dy: -0.15 * shape.fontSize) }
        case .counter(let shape):
            rect = counterBadge(shape).rect
        default:
            rect = annotation.visualBounds
        }
        rect = rect.insetBy(dx: -2, dy: -2)
        if annotation.style.shadow, casts(annotation) {
            let pad = RenderSupport.shadowPadding(canvasScale: canvasScale)
            rect = rect.insetBy(dx: -pad, dy: -pad)
        }
        return rect
    }

    private func casts(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .highlighter, .redaction, .spotlight: false
        default: true
        }
    }

    // MARK: Painting

    /// Draws `annotation`. `image` is the resolved asset for `.image`
    /// annotations (ignored otherwise). `.redaction` and `.spotlight` draw
    /// nothing here.
    public func paint(_ annotation: Annotation, in context: CGContext, image: CGImage? = nil) {
        let style = annotation.style
        switch annotation.kind {
        case .rectangle(let s):
            group(annotation, in: context) { ctx in
                let path = RenderSupport.roundedRectPath(s.rect, radius: s.cornerRadius)
                if let fill = style.fill {
                    ctx.addPath(path)
                    ctx.setFillColor(fill.cgColor)
                    ctx.fillPath()
                }
                stroke(path, style: style, in: ctx, join: .round)
            }
        case .filledRectangle(let s):
            group(annotation, in: context) { ctx in
                ctx.addPath(RenderSupport.roundedRectPath(s.rect, radius: s.cornerRadius))
                ctx.setFillColor(style.color.cgColor)
                ctx.fillPath()
            }
        case .ellipse(let s):
            group(annotation, in: context) { ctx in
                let path = CGPath(ellipseIn: s.rect, transform: nil)
                if let fill = style.fill {
                    ctx.addPath(path)
                    ctx.setFillColor(fill.cgColor)
                    ctx.fillPath()
                }
                stroke(path, style: style, in: ctx, join: .round)
            }
        case .line(let s):
            group(annotation, in: context) { ctx in
                let path = CGMutablePath()
                path.move(to: s.start)
                path.addLine(to: s.end)
                stroke(path, style: style, in: ctx, join: .round, cap: .round)
            }
        case .arrow(let s):
            group(annotation, in: context) { ctx in
                let parts = ArrowGeometry.parts(for: s, strokeWidth: style.strokeWidth)
                if let shaft = parts.shaft {
                    stroke(shaft, style: style, in: ctx, join: .round, cap: .round)
                }
                ctx.addPath(parts.fill)
                ctx.setFillColor(style.color.cgColor)
                ctx.fillPath()
            }
        case .text(let s):
            paintText(annotation, shape: s, in: context)
        case .pencil(let s):
            group(annotation, in: context) { ctx in
                paintFreehand(s.points, style: style, in: ctx)
            }
        case .highlighter(let s):
            group(annotation, in: context, shadow: false, blend: .multiply) { ctx in
                paintFreehand(s.points, style: style, in: ctx)
            }
        case .counter(let s):
            paintCounter(annotation, shape: s, in: context)
        case .image(let s):
            guard let image else { return }
            group(annotation, in: context) { ctx in
                ctx.interpolationQuality = .high
                RenderSupport.drawImage(image, in: s.frame, context: ctx)
            }
        case .redaction, .spotlight:
            return
        }
    }

    /// Runs `body` inside a transparency layer so the annotation's parts get
    /// one shadow and one opacity (overlaps don't double up).
    private func group(
        _ annotation: Annotation,
        in context: CGContext,
        shadow: Bool? = nil,
        blend: CGBlendMode = .normal,
        layerRect: CGRect? = nil,
        _ body: (CGContext) -> Void
    ) {
        context.saveGState()
        if shadow ?? annotation.style.shadow {
            RenderSupport.setShadow(.standard, canvasScale: canvasScale, baseScale: baseScale, in: context)
        }
        context.setAlpha(min(max(annotation.style.opacity, 0), 1))
        context.setBlendMode(blend)
        // Layer bounds without the shadow: the shadow is added on composite.
        let rect = layerRect ?? annotation.visualBounds
        context.beginTransparencyLayer(in: rect.insetBy(dx: -4, dy: -4), auxiliaryInfo: nil)
        body(context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func stroke(
        _ path: CGPath,
        style: AnnotationStyle,
        in context: CGContext,
        join: CGLineJoin,
        cap: CGLineCap = .butt
    ) {
        guard style.strokeWidth > 0 else { return }
        context.addPath(path)
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.strokeWidth)
        context.setLineJoin(join)
        context.setLineCap(cap)
        context.strokePath()
    }

    // MARK: Freehand

    private func paintFreehand(_ points: [CGPoint], style: AnnotationStyle, in context: CGContext) {
        guard let first = points.first else { return }
        let w = style.strokeWidth
        if points.count == 1 || points.allSatisfy({ $0 == first }) {
            context.setFillColor(style.color.cgColor)
            context.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w))
            return
        }
        let path = CGMutablePath()
        path.move(to: first)
        for segment in PathSmoothing.cubicSegments(points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        stroke(path, style: style, in: context, join: .round, cap: .round)
    }

    // MARK: Text

    /// Box behind boxed text styles: the used rect plus padding.
    func textBoxRect(shape: TextShape, layout: TextLayout) -> CGRect {
        layout.usedRect.insetBy(dx: -0.35 * shape.fontSize, dy: -0.15 * shape.fontSize)
    }

    private func paintText(_ annotation: Annotation, shape: TextShape, in context: CGContext) {
        let style = annotation.style
        let layout = TextLayout(shape: shape)
        let outline = shape.textStyle == .outlined ? 0.15 * shape.fontSize : 0
        let layerRect = textBoxRect(shape: shape, layout: layout).union(shape.frame).insetBy(dx: -outline, dy: -outline)
        group(annotation, in: context, layerRect: layerRect) { ctx in
            switch shape.textStyle {
            case .standard, .rounded, .monospaced:
                layout.fill(in: ctx, color: style.color)
            case .outlined:
                layout.stroke(in: ctx, color: style.color.contrastingColor, width: 0.15 * shape.fontSize)
                layout.fill(in: ctx, color: style.color)
            case .boxed, .roundBoxed, .monospacedBoxed:
                let radius = shape.textStyle == .roundBoxed ? 0.45 * shape.fontSize : 0.1 * shape.fontSize
                ctx.addPath(RenderSupport.roundedRectPath(textBoxRect(shape: shape, layout: layout), radius: radius))
                ctx.setFillColor(style.color.cgColor)
                ctx.fillPath()
                layout.fill(in: ctx, color: style.color.contrastingColor)
            }
        }
    }

    // MARK: Counter

    struct CounterBadge {
        var rect: CGRect
        var layout: TextLayout
    }

    func counterBadge(_ shape: CounterShape) -> CounterBadge {
        let d = shape.diameter
        let font = TextLayout.counterFont(size: 0.55 * d)
        var layout = TextLayout(text: String(shape.number), font: font, origin: .zero, wrapWidth: nil, alignment: .left)
        let textWidth = layout.usedRect.width
        let width = textWidth > 0.7 * d ? textWidth + 0.5 * d : d
        let rect = CGRect(x: shape.center.x - width / 2, y: shape.center.y - d / 2, width: width, height: d)
        // Center the digits optically: cap height centered on the badge.
        let capHeight = CTFontGetCapHeight(font)
        let baselineY = shape.center.y + capHeight / 2
        let ascent = CTFontGetAscent(font)
        layout = TextLayout(
            text: String(shape.number),
            font: font,
            origin: CGPoint(x: shape.center.x - textWidth / 2, y: baselineY - ascent),
            wrapWidth: nil,
            alignment: .left
        )
        return CounterBadge(rect: rect, layout: layout)
    }

    private func paintCounter(_ annotation: Annotation, shape: CounterShape, in context: CGContext) {
        let color = annotation.style.color
        let badge = counterBadge(shape)
        let d = shape.diameter
        group(annotation, in: context, layerRect: badge.rect) { ctx in
            switch shape.counterStyle {
            case .filledCircle:
                ctx.addPath(RenderSupport.roundedRectPath(badge.rect, radius: d / 2))
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
                badge.layout.fill(in: ctx, color: color.contrastingColor)
            case .outlinedCircle:
                let ring = 0.1 * d
                let path = RenderSupport.roundedRectPath(badge.rect.insetBy(dx: ring / 2, dy: ring / 2), radius: (d - ring) / 2)
                ctx.addPath(path)
                ctx.setFillColor(RGBAColor.white.cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(ring)
                ctx.strokePath()
                badge.layout.fill(in: ctx, color: color)
            case .filledSquare:
                ctx.addPath(RenderSupport.roundedRectPath(badge.rect, radius: 0.25 * d))
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
                badge.layout.fill(in: ctx, color: color.contrastingColor)
            }
        }
    }
}
