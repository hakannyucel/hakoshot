import CoreGraphics
import Foundation
import Synchronization

/// Geometry of a background canvas around exported content, in output pixels
/// (y down). Pure math; see `BackgroundStyle` for the meaning of each field.
public struct BackgroundLayout: Sendable, Hashable {
    /// Output image size (integral).
    public var canvasSize: CGSize
    /// The card: content plus inset / balance space.
    public var cardRect: CGRect
    /// Where the content (crop + transform result) goes.
    public var contentRect: CGRect
    /// Space between content and card edges.
    public var insets: BackgroundInsets
    /// Card corner radius in pixels.
    public var cornerRadius: Double
    /// Card edges touching the canvas edge (their corners stay square).
    public var flushEdges: FlushEdges

    public struct FlushEdges: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = FlushEdges(rawValue: 1)
        public static let left = FlushEdges(rawValue: 2)
        public static let bottom = FlushEdges(rawValue: 4)
        public static let right = FlushEdges(rawValue: 8)
    }

    /// - Parameters:
    ///   - contentSize: exported content size in pixels.
    ///   - scale: canvas backing scale (points → pixels).
    ///   - balance: extra per-side space from `AutoBalance` (pixels); ignored
    ///     unless `style.autoBalance`.
    public init(contentSize: CGSize, style: BackgroundStyle, scale: Double, balance: BackgroundInsets = .zero) {
        let k = scale > 0 && scale.isFinite ? scale : 1
        let inset = (max(style.inset, 0) * k).rounded()
        var insets = BackgroundInsets(all: inset)
        if style.autoBalance { insets = insets + balance }
        let padding = (max(style.padding, 0) * k).rounded()
        let cardSize = CGSize(width: contentSize.width + insets.horizontal, height: contentSize.height + insets.vertical)

        var width = cardSize.width + 2 * padding
        var height = cardSize.height + 2 * padding
        if let ratio = style.aspectRatio.value {
            if width / height < ratio {
                width = (height * ratio).rounded()
            } else {
                height = (width / ratio).rounded()
            }
        }
        width = max(width.rounded(), 1)
        height = max(height.rounded(), 1)

        let freeX = max(width - cardSize.width, 0)
        let freeY = max(height - cardSize.height, 0)
        let x = (freeX * style.alignment.horizontal).rounded(.down)
        let y = (freeY * style.alignment.vertical).rounded(.down)
        let card = CGRect(x: x, y: y, width: cardSize.width, height: cardSize.height)

        var flush: FlushEdges = []
        if card.minX <= 0 { flush.insert(.left) }
        if card.minY <= 0 { flush.insert(.top) }
        if card.maxX >= width { flush.insert(.right) }
        if card.maxY >= height { flush.insert(.bottom) }

        canvasSize = CGSize(width: width, height: height)
        cardRect = card
        contentRect = CGRect(x: card.minX + insets.left, y: card.minY + insets.top,
                             width: contentSize.width, height: contentSize.height)
        self.insets = insets
        cornerRadius = max(style.cornerRadius, 0) * k
        flushEdges = flush
    }

    public var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    /// The card outline; corners on a flush edge stay square.
    public var cardPath: CGPath {
        let r = max(0, min(cornerRadius, cardRect.width / 2, cardRect.height / 2))
        guard r > 0 else { return CGPath(rect: cardRect, transform: nil) }
        let rect = cardRect
        func radius(_ a: FlushEdges, _ b: FlushEdges) -> Double {
            flushEdges.contains(a) || flushEdges.contains(b) ? 0 : r
        }
        let tl = radius(.top, .left), tr = radius(.top, .right)
        let br = radius(.bottom, .right), bl = radius(.bottom, .left)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }
}

/// Draws the Background tool: the canvas fill, then the rounded, shadowed
/// card with the content inside. All functions draw in a **y-down** user
/// space (see `RenderSupport`). Used by `DocumentRenderer.drawOutput`, so the
/// editor canvas and export match; the fill functions also draw the panel's
/// swatches.
public enum BackgroundRenderer {
    // MARK: Fill

    /// Paints `fill` into `rect`.
    /// - Parameters:
    ///   - images: resolves `.image` assets.
    ///   - blurredScreenshot: prepared by `makeBlurredBackdrop`, for `.blurredScreenshot`.
    public static func drawFill(
        _ fill: BackgroundFill,
        in rect: CGRect,
        context: CGContext,
        images: (AssetID) -> CGImage? = { _ in nil },
        blurredScreenshot: CGImage? = nil
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        switch fill {
        case .preset(let id):
            drawGradient(GradientCatalog.spec(for: id), in: rect, context: context)
        case .gradient(let spec):
            drawGradient(spec, in: rect, context: context)
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .image(let asset):
            guard let image = images(asset) else { return }
            context.interpolationQuality = .high
            RenderSupport.drawImage(image, in: aspectFill(image, rect), context: context)
        case .blurredScreenshot:
            guard let image = blurredScreenshot else { return }
            context.interpolationQuality = .high
            RenderSupport.drawImage(image, in: aspectFill(image, rect), context: context)
        case .transparent:
            break
        }
    }

    /// Paints a `GradientSpec` (linear base + radial glows) into `rect`.
    public static func drawGradient(_ spec: GradientSpec, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        let stops = spec.stops.sorted { $0.location < $1.location }
        if stops.count == 1, let only = stops.first {
            context.setFillColor(only.color.cgColor)
            context.fill(rect)
        } else if let gradient = makeGradient(stops.map { ($0.color, $0.location) }) {
            let angle = spec.angle * .pi / 180
            let dx = cos(angle), dy = sin(angle)
            let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let longSide = max(rect.width, rect.height)
        for glow in spec.glows {
            let a = glow.color.alpha
            // Eased falloff reads as a soft mesh blob rather than a spotlight.
            let ramp: [(Double, Double)] = [(0, 1), (0.2, 0.8), (0.4, 0.5), (0.6, 0.24), (0.8, 0.07), (1, 0)]
            guard let gradient = makeGradient(ramp.map { (glow.color.withAlpha(a * $0.1), $0.0) }) else { continue }
            let center = CGPoint(x: rect.minX + glow.x * rect.width, y: rect.minY + glow.y * rect.height)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: max(glow.radius * longSide, 1), options: [])
        }
    }

    /// The content blurred into a backdrop of `size` (aspect-filled, heavy
    /// blur, computed at low resolution and scaled up when drawn).
    public static func makeBlurredBackdrop(from content: CGImage, size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let s = min(1, 256 / max(size.width, size.height))
        let w = max(Int((size.width * s).rounded()), 1), h = max(Int((size.height * s).rounded()), 1)
        guard let context = RenderSupport.makeBitmapContext(width: w, height: h) else { return nil }
        context.interpolationQuality = .medium
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        // Slight overscale hides the clamped edge of the blur.
        context.draw(content, in: aspectFill(content, rect.insetBy(dx: -Double(w) * 0.05, dy: -Double(h) * 0.05)))
        guard let small = context.makeImage(),
              let blurred = RedactionEffects.gaussianBlur(small, radius: Double(max(w, h)) / 22) else { return nil }
        // Soften contrast a little so the card stands out.
        guard let tint = RenderSupport.makeBitmapContext(width: w, height: h) else { return blurred }
        tint.draw(blurred, in: rect)
        tint.setFillColor(RGBAColor.white.withAlpha(0.12).cgColor)
        tint.fill(rect)
        return tint.makeImage() ?? blurred
    }

    // MARK: Card

    /// Draws the card (inset space filled with `edgeColor`, clipped to the
    /// rounded card path, with the style's shadow); `drawContent` draws the
    /// content in the same user space at `layout.contentRect`.
    public static func drawCard(
        layout: BackgroundLayout,
        style: BackgroundStyle,
        scale: Double,
        edgeColor: RGBAColor?,
        baseScale: Double = 1,
        context: CGContext,
        drawContent: (CGContext) -> Void
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        if style.shadow.isVisible {
            let spec = ShadowSpec(
                offsetX: style.shadow.offsetX, offsetY: style.shadow.offsetY, blur: max(style.shadow.radius, 0),
                color: RGBAColor.black.withAlpha(min(max(style.shadow.opacity, 0), 1))
            )
            RenderSupport.setShadow(spec, canvasScale: scale, baseScale: baseScale, in: context)
        }
        context.beginTransparencyLayer(in: layout.cardRect, auxiliaryInfo: nil)
        context.addPath(layout.cardPath)
        context.clip()
        let hasInsets = layout.insets.horizontal > 0 || layout.insets.vertical > 0
        if hasInsets, let edgeColor {
            context.setFillColor(edgeColor.cgColor)
            context.fill(layout.cardRect)
        }
        drawContent(context)
        context.endTransparencyLayer()
    }

    // MARK: Helpers

    static func aspectFill(_ image: CGImage, _ rect: CGRect) -> CGRect {
        WindowBackdropCompositor.aspectFillRect(imageSize: CGSize(width: image.width, height: image.height), in: rect)
    }

    private static func makeGradient(_ stops: [(RGBAColor, Double)]) -> CGGradient? {
        guard stops.count >= 2 else { return nil }
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        for (color, location) in stops {
            components += [color.red, color.green, color.blue, color.alpha]
            locations.append(min(max(location, 0), 1))
        }
        return CGGradient(colorSpace: RenderSupport.sRGB, colorComponents: components, locations: locations, count: stops.count)
    }
}

// MARK: - Cache

/// Remembers the last auto-balance analysis and blurred backdrop, keyed by
/// the image content they were computed from, so redrawing (every editor
/// frame) doesn't re-scan pixels. One per editor window, like `RedactionCache`.
public final class BackgroundCache: Sendable {
    struct Key: Hashable, Sendable {
        var layers: [ImageLayer]
        var images: [Annotation]
        var crop: CGRect
        var transform: CanvasTransform
    }

    private struct BlurKey: Hashable {
        var content: Key
        var width: Double
        var height: Double
    }

    private struct State {
        var analysis: (key: Key, value: AutoBalance.Analysis?)?
        var blurred: (key: BlurKey, image: CGImage?)?
    }

    private let state = Mutex<State>(State())

    public init() {}

    public func removeAll() {
        state.withLock { $0 = State() }
    }

    func analysis(for key: Key, make: () -> AutoBalance.Analysis?) -> AutoBalance.Analysis? {
        if let hit = state.withLock({ $0.analysis }), hit.key == key { return hit.value }
        let value = make()
        state.withLock { $0.analysis = (key, value) }
        return value
    }

    func blurred(for key: Key, size: CGSize, make: () -> CGImage?) -> CGImage? {
        let blurKey = BlurKey(content: key, width: size.width, height: size.height)
        if let hit = state.withLock({ $0.blurred }), hit.key == blurKey { return hit.image }
        let image = make()
        state.withLock { $0.blurred = (blurKey, image) }
        return image
    }
}
