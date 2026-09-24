import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// A cursor image with its hot spot, ready for the Studio renderer.
public struct StudioCursorSprite: @unchecked Sendable {
    /// Upright image (any pixel density).
    public var image: CGImage
    /// Hot spot in points from the image's top-left.
    public var hotSpot: CGPoint
    /// Image size in points (`StudioCursorState.scale` is canvas px per point).
    public var size: CGSize

    public init(image: CGImage, hotSpot: CGPoint, size: CGSize) {
        self.image = image
        self.hotSpot = hotSpot
        self.size = size
    }

    /// A recorded shape (`cursors/<hash>.png`) with its metadata.
    public init(image: CGImage, shape: RecordingCursorShape) {
        self.init(image: image, hotSpot: CGPoint(x: shape.hotSpotX, y: shape.hotSpotY),
                  size: CGSize(width: shape.width, height: shape.height))
    }

    /// HakoShot's vector arrow (classic macOS shape: black body, white
    /// outline), drawn with CoreGraphics at 4 px per point so it stays sharp
    /// when zoomed. Used when a recording has no cursor PNGs or the style is
    /// `.arrow`.
    public static let arrow: StudioCursorSprite = makeArrow()

    private static func makeArrow() -> StudioCursorSprite {
        let size = CGSize(width: 17, height: 25)
        let density = 4.0
        let hotSpot = CGPoint(x: 2, y: 2)
        let w = Int(size.width * density), h = Int(size.height * density)
        let context = RenderSupport.makeBitmapContext(width: w, height: h)!
        RenderSupport.flipToTopLeft(context, height: CGFloat(h))
        context.scaleBy(x: density, y: density)
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 4, y: 12.7),
            CGPoint(x: 6.8, y: 19.3), CGPoint(x: 9.6, y: 18.1), CGPoint(x: 6.9, y: 11.6),
            CGPoint(x: 12.3, y: 11.6),
        ]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x + hotSpot.x, y: $0.y + hotSpot.y) })
        path.closeSubpath()
        context.setLineJoin(.round)
        context.setShadow(offset: CGSize(width: 0, height: -1 * density), blur: 2 * density,
                          color: RGBAColor.black.withAlpha(0.35).cgColor)
        context.addPath(path)
        context.setStrokeColor(RGBAColor.white.cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        // Black body; the outer half of the stroke stays as a white outline.
        context.addPath(path)
        context.setFillColor(RGBAColor.black.cgColor)
        context.fillPath()
        return StudioCursorSprite(image: context.makeImage()!, hotSpot: hotSpot, size: size)
    }
}

/// Draws one Studio output frame with Core Image (plan §4.19). The same
/// renderer serves the editor preview, thumbnails and export (through the
/// app's `StudioCompositor`).
///
/// Layers, bottom to top: background fill, content shadow, the source's
/// `viewRect` scaled into `contentRect` with rounded corners, click rings,
/// the cursor sprite, the keystroke badge, the webcam bubble (shadow,
/// optional white outline). Click rings and the cursor are clipped to
/// `contentRect`.
///
/// Coordinates: `StudioFrameState` is canvas pixels y down; Core Image is y
/// up. The returned image covers exactly `(0, 0, canvasSize)`.
///
/// Thread safety: the struct is `Sendable`; its caches (background per
/// canvas size + fill, keystroke pill per label) live in locked boxes
/// shared by copies.
public struct StudioFrameRenderer: Sendable {
    public struct Options: Sendable, Hashable {
        /// Click ring color (plan §5.2: `#0A84FF`).
        public var clickRingColor: RGBAColor
        /// Ring stroke width, reference points.
        public var clickRingWidth: Double
        /// Right-click adds a second, inner ring at this fraction of the radius.
        public var secondaryRingFraction: Double

        public init(clickRingColor: RGBAColor = RGBAColor(hex: "#0A84FF") ?? .black,
                    clickRingWidth: Double = 2, secondaryRingFraction: Double = 0.6) {
            self.clickRingColor = clickRingColor
            self.clickRingWidth = clickRingWidth
            self.secondaryRingFraction = secondaryRingFraction
        }

        public static let standard = Options()
    }

    public var options: Options
    /// Resolves `.image` background assets.
    public let backgroundImages: @Sendable (AssetID) -> CGImage?
    private let cache = Cache()
    private let badgeCache = BadgeCache()

    public init(options: Options = .standard,
                backgroundImages: @escaping @Sendable (AssetID) -> CGImage? = { _ in nil }) {
        self.options = options
        self.backgroundImages = backgroundImages
    }

    // MARK: Render

    /// The full canvas for one frame.
    /// - Parameters:
    ///   - source: the screen frame (extent = the source pixel size, CI y up).
    ///   - camera: the webcam frame; drawn only when `state.camera` is set.
    ///   - cursorSprite: shape index → sprite; `nil` falls back to `.arrow`.
    public func render(
        source: CIImage,
        camera: CIImage? = nil,
        state: StudioFrameState,
        cursorSprite: (Int) -> StudioCursorSprite? = { _ in nil }
    ) -> CIImage {
        let canvas = state.canvasRect
        guard canvas.width > 0, canvas.height > 0 else { return CIImage.empty() }
        let H = canvas.height
        func ci(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

        let content = ci(state.contentRect)
        // Background + card shadow (static per layout: rasterized once).
        var image = backdrop(state: state, content: content, source: source)

        // Content.
        if let placed = placedContent(source: source, view: state.viewRect, into: content) {
            let masked = Self.masked(placed, rect: content, radius: state.cornerRadius)
            image = masked.composited(over: image)
        }

        // Click rings.
        var overlays = CIImage.empty()
        for effect in state.clickEffects where effect.opacity > 0 && effect.radius > 0 {
            let center = CGPoint(x: effect.position.x, y: H - effect.position.y)
            let width = max(options.clickRingWidth * state.lengthScale, 1)
            var ring = ringImage(center: center, radius: effect.radius, width: width)
            if effect.button == .right {
                ring = ringImage(center: center, radius: effect.radius * options.secondaryRingFraction, width: width)
                    .composited(over: ring)
            }
            overlays = Self.faded(ring, by: effect.opacity).composited(over: overlays)
        }

        // Cursor.
        if let cursor = state.cursor, cursor.opacity > 0, cursor.scale > 0 {
            let sprite = cursorSprite(cursor.shapeIndex) ?? .arrow
            let img = CIImage(cgImage: sprite.image)
            let s = cursor.scale
            let w = sprite.size.width * s, h = sprite.size.height * s
            let topLeft = CGPoint(x: cursor.position.x - sprite.hotSpot.x * s,
                                  y: cursor.position.y - sprite.hotSpot.y * s)
            let sx = w / max(img.extent.width, 1), sy = h / max(img.extent.height, 1)
            let placed = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: topLeft.x, y: H - topLeft.y - h))
            overlays = Self.faded(placed, by: cursor.opacity).composited(over: overlays)
        }
        if !overlays.extent.isEmpty {
            image = overlays.cropped(to: content).composited(over: image)
        }

        // Keystroke badge.
        if let badge = state.keystrokeBadge, let pill = badgeImage(badge, canvasHeight: H) {
            image = pill.composited(over: image)
        }

        // Webcam.
        if let layout = state.camera, let camera, !camera.extent.isEmpty, !camera.extent.isInfinite {
            let rect = ci(layout.rect)
            if layout.shadow.isVisible {
                image = Self.shadowImage(rect: rect, radius: layout.cornerRadius, shadow: layout.shadow)
                    .composited(over: image)
            }
            let e = camera.extent
            let scale = max(rect.width / e.width, rect.height / e.height)
            var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(scaleX: layout.mirrored ? -scale : scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
            if !t.a.isFinite { t = .identity }
            let placed = camera.clampedToExtent().transformed(by: t).cropped(to: rect)
            image = Self.masked(placed, rect: rect, radius: layout.cornerRadius).composited(over: image)
            if layout.borderWidth > 0 {
                let w = layout.borderWidth
                // The generator strokes inside its extent: the outline lies
                // on the bubble's outer edge.
                let stroke = CIFilter.roundedRectangleStrokeGenerator()
                stroke.extent = rect
                stroke.radius = Float(max(0, min(layout.cornerRadius, rect.width / 2, rect.height / 2)))
                stroke.width = Float(w)
                stroke.color = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: RenderSupport.sRGB) ?? .white
                if let outline = stroke.outputImage { image = outline.cropped(to: rect).composited(over: image) }
            }
        }

        return image.cropped(to: canvas)
    }

    /// Motion blur: renders each plan sample (the closure gives the source
    /// frame and the state at that source time) and averages them by weight.
    /// A single-sample plan costs one plain render.
    public func renderBlurred(
        plan: MotionBlurPlan,
        camera: CIImage? = nil,
        cursorSprite: (Int) -> StudioCursorSprite? = { _ in nil },
        frame: (Double) -> (CIImage, StudioFrameState)
    ) -> CIImage {
        var accumulated: CIImage?
        var total = 0.0
        for sample in plan.samples where sample.weight > 0 {
            let (source, state) = frame(sample.sourceTime)
            let image = render(source: source, camera: camera, state: state, cursorSprite: cursorSprite)
            total += sample.weight
            if let acc = accumulated {
                // Running weighted mean: acc·(1 − t) + image·t.
                accumulated = Self.mix(acc, image, t: sample.weight / total)
            } else {
                accumulated = image
            }
        }
        if let accumulated { return accumulated }
        let (source, state) = frame(plan.sourceTime)
        return render(source: source, camera: camera, state: state, cursorSprite: cursorSprite)
    }

    // MARK: Output

    /// The shared context: Metal-backed (Core Image's default on this
    /// hardware), half-float linear working space, sRGB output, no
    /// intermediate caching (every video frame is new).
    public static var sharedContext: CIContext { ContextBox.shared.context }

    /// Renders `image` (its extent, or `rect`) to an 8-bit sRGB `CGImage`.
    public static func makeCGImage(_ image: CIImage, rect: CGRect? = nil, context: CIContext? = nil) -> CGImage? {
        let r = rect ?? image.extent
        guard !r.isEmpty, !r.isInfinite else { return nil }
        return (context ?? sharedContext).createCGImage(image, from: r, format: .RGBA8, colorSpace: RenderSupport.sRGB)
    }

    public func makeCGImage(_ image: CIImage, context: CIContext? = nil) -> CGImage? {
        Self.makeCGImage(image, context: context)
    }

    /// Drops cached backgrounds (e.g. after a background image asset
    /// changed) and keystroke pills.
    public func removeCaches() {
        cache.removeAll()
        badgeCache.removeAll()
    }

    // MARK: Layers

    /// The keystroke pill in CI coords (cached per label and size; alpha and
    /// the repeat pulse applied here).
    private func badgeImage(_ badge: StudioKeystrokeBadgeState, canvasHeight H: Double) -> CIImage? {
        guard badge.alpha > 0, badge.frame.width > 0, badge.frame.height > 0 else { return nil }
        let key = BadgeCache.Key(text: badge.text, width: badge.frame.width.rounded(.up),
                                 height: badge.frame.height.rounded(.up), fontSize: badge.fontSize, isLight: badge.isLight)
        let pill: CIImage
        if let hit = badgeCache.image(for: key) {
            pill = hit
        } else {
            guard let cg = StudioKeystrokeBadgeImage.make(text: badge.text, size: CGSize(width: key.width, height: key.height),
                                                          fontSize: badge.fontSize, isLight: badge.isLight) else { return nil }
            pill = CIImage(cgImage: cg)
            badgeCache.store(pill, for: key)
        }
        let f = badge.frame
        let s = badge.scale > 0 && badge.scale.isFinite ? badge.scale : 1
        let w = f.width * s, h = f.height * s
        let origin = CGPoint(x: f.midX - w / 2, y: H - f.midY - h / 2)
        let e = pill.extent
        let placed = pill
            .transformed(by: CGAffineTransform(scaleX: w / max(e.width, 1), y: h / max(e.height, 1)))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return Self.faded(placed, by: badge.alpha)
    }

    /// Soft shadow of a rounded rect (CI coords); same blur mapping as the
    /// content shadow.
    static func shadowImage(rect: CGRect, radius: Double, shadow: BackgroundShadow) -> CIImage {
        let alpha = min(max(shadow.opacity, 0), 1)
        var shape = roundedRect(rect, radius: radius, color: RGBAColor.black.withAlpha(alpha))
            .transformed(by: CGAffineTransform(translationX: shadow.offsetX, y: -shadow.offsetY))
        // CG's shadow blur is about twice the Gaussian sigma.
        let sigma = max(shadow.radius, 0) / 2
        if sigma > 0.01 { shape = shape.applyingGaussianBlur(sigma: sigma) }
        return shape
    }

    /// Background fill with the content card's shadow. Everything but the
    /// blurred-screenshot fill is the same every frame, so it's rendered once
    /// into a GPU-shareable buffer (`rasterized`) and reused: drawing a 4K
    /// gradient image and blurring the card shadow per frame cost ~14 ms.
    private func backdrop(state: StudioFrameState, content: CGRect, source: CIImage) -> CIImage {
        let canvas = state.canvasRect
        let shadow = state.shadow
        let hasShadow = shadow.isVisible && content.width > 0 && content.height > 0
        func withShadow(_ background: CIImage) -> CIImage {
            guard hasShadow else { return background }
            return Self.shadowImage(rect: content, radius: state.cornerRadius, shadow: shadow).composited(over: background)
        }
        let fill: CIImage
        switch state.background {
        case .blurredScreenshot:
            return withShadow(Self.blurredBackdrop(source: source, canvas: canvas))
        case .transparent:
            fill = CIImage(color: .clear).cropped(to: canvas)
        case .solid(let color):
            fill = CIImage(color: Self.ciColor(color)).cropped(to: canvas)
        case .image, .preset, .gradient:
            fill = CIImage.empty() // drawn on a cache miss below
        }
        // A plain color without a shadow is already free.
        if !hasShadow, !fill.extent.isEmpty { return fill }

        let key = Cache.Key(fill: state.background, width: canvas.width, height: canvas.height,
                            card: hasShadow ? content : .null, cornerRadius: hasShadow ? state.cornerRadius : 0,
                            shadow: hasShadow ? shadow : .none)
        if let hit = cache.background(for: key) { return hit }
        var base = fill
        switch state.background {
        case .image, .preset, .gradient:
            // `nil` = missing image asset: not cached, so it appears once loaded.
            guard let cg = drawFill(state.background, size: canvas.size) else {
                return withShadow(CIImage(color: .clear).cropped(to: canvas))
            }
            base = CIImage(cgImage: cg)
        default:
            break
        }
        let composed = withShadow(base).cropped(to: canvas)
        let image = Self.rasterized(composed, size: canvas.size) ?? composed
        cache.store(image, for: key)
        return image
    }

    /// `image` rendered once (shared context, sRGB 8-bit) into an
    /// IOSurface-backed buffer; the returned image reads it on the GPU
    /// without an upload. `nil` if the buffer can't be made.
    static func rasterized(_ image: CIImage, size: CGSize) -> CIImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        sharedContext.render(image, to: buffer, bounds: bounds, colorSpace: RenderSupport.sRGB)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: RenderSupport.sRGB])
    }

    /// `BackgroundRenderer.drawFill` into a bitmap (the screenshot
    /// Background tool's exact look). `nil` when an image asset is missing
    /// (not cached, so it appears once loaded).
    private func drawFill(_ fill: BackgroundFill, size: CGSize) -> CGImage? {
        if case .image(let asset) = fill, backgroundImages(asset) == nil { return nil }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let context = RenderSupport.makeBitmapContext(width: w, height: h) else { return nil }
        RenderSupport.flipToTopLeft(context, height: CGFloat(h))
        BackgroundRenderer.drawFill(fill, in: CGRect(x: 0, y: 0, width: w, height: h), context: context,
                                    images: backgroundImages)
        return context.makeImage()
    }

    /// Same recipe as `BackgroundRenderer.makeBlurredBackdrop` (aspect-fill
    /// at ≤ 256 px, 5 % overscale, blur = long side / 22, 12 % white), live
    /// per frame on the GPU.
    static func blurredBackdrop(source: CIImage, canvas: CGRect) -> CIImage {
        let e = source.extent
        guard !e.isEmpty, !e.isInfinite else { return CIImage(color: .clear).cropped(to: canvas) }
        let s = min(1, 256 / max(canvas.width, canvas.height))
        let small = CGRect(x: 0, y: 0, width: max((canvas.width * s).rounded(), 1), height: max((canvas.height * s).rounded(), 1))
        let target = small.insetBy(dx: -small.width * 0.05, dy: -small.height * 0.05)
        let fill = max(target.width / e.width, target.height / e.height)
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: fill, y: fill))
            .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
        let blurred = source.clampedToExtent().transformed(by: t)
            .applyingGaussianBlur(sigma: max(small.width, small.height) / 22)
            .cropped(to: small)
        let tint = CIImage(color: ciColor(RGBAColor.white.withAlpha(0.12))).cropped(to: small)
        let up = CGAffineTransform(scaleX: canvas.width / small.width, y: canvas.height / small.height)
        return tint.composited(over: blurred).clampedToExtent()
            .samplingLinear()
            .transformed(by: up)
            .cropped(to: canvas)
    }

    /// Source `view` (source px, y down) scaled into `rect` (CI coords).
    private func placedContent(source: CIImage, view: CGRect, into rect: CGRect) -> CIImage? {
        let e = source.extent
        guard !e.isEmpty, !e.isInfinite, view.width > 0, view.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let viewCI = CGRect(x: e.minX + view.minX, y: e.maxY - view.maxY, width: view.width, height: view.height)
        let t = CGAffineTransform(translationX: -viewCI.minX, y: -viewCI.minY)
            .concatenating(CGAffineTransform(scaleX: rect.width / view.width, y: rect.height / view.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        // Clamping first keeps the edges crisp (no fade to transparent).
        return source.cropped(to: viewCI.intersection(e)).clampedToExtent().transformed(by: t).cropped(to: rect)
    }

    private func ringImage(center: CGPoint, radius: Double, width: Double) -> CIImage {
        let filter = CIFilter.roundedRectangleStrokeGenerator()
        let outer = radius + width / 2
        filter.extent = CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer)
        filter.radius = Float(outer)
        filter.width = Float(width)
        filter.color = Self.ciColor(options.clickRingColor)
        return filter.outputImage ?? CIImage.empty()
    }

    // MARK: Helpers

    static func ciColor(_ c: RGBAColor) -> CIColor {
        CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha, colorSpace: RenderSupport.sRGB)
            ?? CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// A filled rounded rect (CI coords).
    static func roundedRect(_ rect: CGRect, radius: Double, color: RGBAColor) -> CIImage {
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(max(0, min(radius, rect.width / 2, rect.height / 2)))
        filter.color = ciColor(color)
        return filter.outputImage ?? CIImage.empty()
    }

    /// `image` limited to a rounded `rect`.
    static func masked(_ image: CIImage, rect: CGRect, radius: Double) -> CIImage {
        guard radius > 0 else { return image.cropped(to: rect) }
        let filter = CIFilter.blendWithAlphaMask()
        filter.inputImage = image
        filter.backgroundImage = CIImage(color: .clear).cropped(to: rect)
        filter.maskImage = roundedRect(rect, radius: radius, color: .white)
        return (filter.outputImage ?? image).cropped(to: rect)
    }

    /// Premultiplied scale of every channel (true opacity).
    static func faded(_ image: CIImage, by opacity: Double) -> CIImage {
        let o = min(max(opacity, 0), 1)
        if o >= 1 { return image }
        return mix(CIImage(color: .clear).cropped(to: image.extent), image, t: o)
    }

    /// Premultiplied linear interpolation `a·(1 − t) + b·t`.
    static func mix(_ a: CIImage, _ b: CIImage, t: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = a
        filter.targetImage = b
        filter.time = Float(min(max(t, 0), 1))
        return filter.outputImage ?? b
    }
}

// MARK: - Cache / context

extension StudioFrameRenderer {
    /// Background images per (fill, canvas size); a few entries (preview and
    /// export sizes, a recent style change).
    final class Cache: @unchecked Sendable {
        struct Key: Hashable {
            var fill: BackgroundFill
            var width: Double
            var height: Double
            /// Card shadow baked in (`.null` / `.none` = no shadow).
            var card: CGRect
            var cornerRadius: Double
            var shadow: BackgroundShadow
        }

        /// Preview size, export size and a recent style change (≤ 33 MB
        /// each at 4K).
        private static let limit = 3
        private let lock = NSLock()
        private var entries: [(key: Key, image: CIImage)] = []

        func background(for key: Key) -> CIImage? {
            lock.withLock { entries.first { $0.key == key }?.image }
        }

        func store(_ image: CIImage, for key: Key) {
            lock.withLock {
                entries.removeAll { $0.key == key }
                entries.insert((key, image), at: 0)
                if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
            }
        }

        func removeAll() {
            lock.withLock { entries.removeAll() }
        }
    }

    /// Keystroke pills per (label, pixel size, style): a label shows for
    /// seconds, so each is drawn with CoreText once.
    final class BadgeCache: @unchecked Sendable {
        struct Key: Hashable {
            var text: String
            var width: Double
            var height: Double
            var fontSize: Double
            var isLight: Bool
        }

        private static let limit = 32
        private let lock = NSLock()
        private var entries: [Key: CIImage] = [:]
        private var order: [Key] = []

        func image(for key: Key) -> CIImage? {
            lock.withLock { entries[key] }
        }

        func store(_ image: CIImage, for key: Key) {
            lock.withLock {
                if entries.updateValue(image, forKey: key) == nil { order.append(key) }
                if order.count > Self.limit {
                    let drop = order.removeFirst()
                    entries[drop] = nil
                }
            }
        }

        func removeAll() {
            lock.withLock {
                entries.removeAll()
                order.removeAll()
            }
        }
    }

    private final class ContextBox: @unchecked Sendable {
        static let shared = ContextBox()
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAh,
            .outputColorSpace: RenderSupport.sRGB,
            .cacheIntermediates: false,
            .name: "HakoKit.StudioFrameRenderer",
        ])
    }
}
