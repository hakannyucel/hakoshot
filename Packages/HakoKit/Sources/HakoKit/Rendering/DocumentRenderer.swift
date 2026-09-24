import CoreGraphics
import Foundation

/// Renders a `ProjectDocument` (plan §4.10; draw order on `ProjectDocument`).
///
/// One code path for the live canvas and export (WYSIWYG):
/// - **Canvas** (`drawCanvas`): draws canvas pixel space, *before* crop and
///   transform, into any context whose CTM maps canvas pixels (top-left
///   origin, y down) to the destination. The editor view sets the CTM for its
///   zoom / scroll and passes the dirty rect in canvas pixels.
/// - **Output** (`drawOutput`, `makeImage`): crop + rotate/flip applied, then
///   placed on the background canvas (`BackgroundStyle`, if any); output pixel
///   space, y down. Use `outputLayout(of:)` for its size and canvas → output
///   transform.
///
/// Thread-safety: the renderer is `Sendable`; it may draw on any thread as
/// long as each `CGContext` is used by one thread at a time.
public struct DocumentRenderer: Sendable {
    public typealias AssetResolver = @Sendable (AssetID) -> CGImage?

    public var assets: AssetResolver
    public var redactionCache: RedactionCache
    /// Auto-balance analysis + blurred backdrop, per image content.
    public var backgroundCache: BackgroundCache

    public init(
        redactionCache: RedactionCache = RedactionCache(),
        backgroundCache: BackgroundCache = BackgroundCache(),
        assets: @escaping AssetResolver
    ) {
        self.assets = assets
        self.redactionCache = redactionCache
        self.backgroundCache = backgroundCache
    }

    public struct Options: Sendable {
        /// Part of the canvas to draw, in canvas pixels (the view's dirty rect
        /// converted to canvas space). `nil` = everything. Annotations outside
        /// it are skipped; drawing is clipped to it.
        public var dirtyRect: CGRect?
        /// Device pixels per context base unit, for shadow offsets/blur
        /// (CoreGraphics applies them in base space, ignoring the CTM). 1 for
        /// bitmap contexts; for an AppKit view context pass the window's
        /// `backingScaleFactor`.
        public var baseScale: Double
        /// Draw the spotlight dim layer (the editor may hide it while the
        /// spotlight tool is dragging, for instance).
        public var drawsSpotlight: Bool

        public init(dirtyRect: CGRect? = nil, baseScale: Double = 1, drawsSpotlight: Bool = true) {
            self.dirtyRect = dirtyRect
            self.baseScale = baseScale
            self.drawsSpotlight = drawsSpotlight
        }
    }

    // MARK: Canvas

    /// Draws the whole canvas (no crop / transform) into `context`, whose user
    /// space must be canvas pixel space, y down.
    public func drawCanvas(_ document: ProjectDocument, in context: CGContext, options: Options = Options()) {
        let painter = AnnotationPainter(canvasScale: document.canvas.scale, baseScale: options.baseScale)
        let dirty = options.dirtyRect?.standardized
        func visible(_ rect: CGRect) -> Bool { dirty.map { $0.intersects(rect) } ?? true }

        context.saveGState()
        defer { context.restoreGState() }
        if let dirty { context.clip(to: dirty) }

        // 1. The background is drawn by `drawOutput` around the output area.
        // 2. Image content.
        drawImageContent(document, in: context, painter: painter, visible: visible)

        // 3. Redactions (sampling only pass 2's pixels). Cache keys are
        //    computed for every redaction so pruning never drops an entry that
        //    is merely scrolled out of view.
        var liveKeys = Set<RedactionCache.Key>()
        for annotation in document.annotations {
            guard case .redaction(let shape) = annotation.kind else { continue }
            let key = redactionKey(annotation, shape: shape, in: document)
            liveKeys.insert(key)
            guard visible(shape.rect) else { continue }
            drawRedaction(annotation, shape: shape, key: key, document: document, in: context)
        }
        redactionCache.retain(only: liveKeys)

        // 4. Every other annotation in z-order.
        for annotation in document.annotations {
            switch annotation.kind {
            case .image, .redaction, .spotlight: continue
            default: break
            }
            guard visible(painter.paintedBounds(of: annotation)) else { continue }
            painter.paint(annotation, in: context)
        }

        // 5. One combined spotlight dim layer.
        if options.drawsSpotlight {
            drawSpotlights(document, in: context, clip: dirty)
        }
    }

    private func drawImageContent(
        _ document: ProjectDocument,
        in context: CGContext,
        painter: AnnotationPainter,
        visible: (CGRect) -> Bool
    ) {
        for layer in document.layers where visible(layer.frame) {
            guard let image = assets(layer.assetID) else { continue }
            RenderSupport.drawImage(image, in: layer.frame, context: context)
        }
        for annotation in document.annotations {
            guard case .image(let shape) = annotation.kind, visible(painter.paintedBounds(of: annotation)) else { continue }
            painter.paint(annotation, in: context, image: assets(shape.assetID))
        }
    }

    // MARK: Redaction

    /// Pixel region a redaction samples / covers (integral, in canvas pixels).
    static func redactionRegion(_ shape: RedactionShape) -> CGRect {
        shape.rect.integral
    }

    private func redactionKey(_ annotation: Annotation, shape: RedactionShape, in document: ProjectDocument) -> RedactionCache.Key {
        let region = Self.redactionRegion(shape)
        let shadowPad = RenderSupport.shadowPadding(canvasScale: document.canvas.scale)
        return RedactionCache.Key(
            redaction: annotation.id,
            shape: shape,
            fill: annotation.style.color,
            layers: document.layers.filter { $0.frame.intersects(region) },
            images: document.annotations.filter {
                guard case .image(let s) = $0.kind else { return false }
                return s.frame.insetBy(dx: -shadowPad, dy: -shadowPad).intersects(region)
            }
        )
    }

    private func drawRedaction(
        _ annotation: Annotation,
        shape: RedactionShape,
        key: RedactionCache.Key,
        document: ProjectDocument,
        in context: CGContext
    ) {
        let region = Self.redactionRegion(shape)
        guard region.width >= 1, region.height >= 1 else { return }
        let result: CGImage?
        if shape.method == .blackOut {
            result = nil
        } else {
            result = redactionCache.image(for: key) {
                guard let source = imageContent(document, in: region) else { return nil }
                return RedactionEffects.apply(shape, fill: annotation.style.color, to: source)
            }
        }
        context.saveGState()
        context.clip(to: shape.rect)
        if let result {
            context.interpolationQuality = .none
            RenderSupport.drawImage(result, in: region, context: context)
        } else if shape.method == .blackOut {
            context.setFillColor(annotation.style.color.cgColor)
            context.fill(shape.rect)
        }
        context.restoreGState()
    }

    /// The image-content pass (layers + image annotations) for `region`, at
    /// canvas resolution.
    func imageContent(_ document: ProjectDocument, in region: CGRect) -> CGImage? {
        guard let context = RenderSupport.makeBitmapContext(width: Int(region.width), height: Int(region.height)) else {
            return nil
        }
        RenderSupport.flipToTopLeft(context, height: region.height)
        context.translateBy(x: -region.minX, y: -region.minY)
        let painter = AnnotationPainter(canvasScale: document.canvas.scale)
        drawImageContent(document, in: context, painter: painter) { $0.intersects(region) }
        return context.makeImage()
    }

    // MARK: Spotlight

    private func drawSpotlights(_ document: ProjectDocument, in context: CGContext, clip: CGRect?) {
        let spots: [SpotlightShape] = document.annotations.compactMap {
            if case .spotlight(let s) = $0.kind { return s }
            return nil
        }
        guard let dim = spots.map(\.dimOpacity).max(), dim > 0 else { return }
        let area = clip.map { $0.intersection(document.canvas.rect) } ?? document.canvas.rect
        guard !area.isNull, !area.isEmpty else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
        context.setFillColor(RGBAColor.black.withAlpha(min(dim, 1)).cgColor)
        context.fill(area)
        context.setBlendMode(.clear)
        for spot in spots {
            let path = spot.isEllipse
                ? CGPath(ellipseIn: spot.rect, transform: nil)
                : RenderSupport.roundedRectPath(spot.rect, radius: spot.cornerRadius)
            context.addPath(path)
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Output (crop + transform + background)

    /// Crop rect actually used for output (standardized, at least 1×1 px).
    static func outputCrop(of document: ProjectDocument) -> CGRect {
        let crop = document.visibleRect.standardized
        return CGRect(
            x: crop.minX, y: crop.minY,
            width: max(crop.width.rounded(), 1), height: max(crop.height.rounded(), 1)
        )
    }

    /// Size of the cropped, rotated content (crop size, swapped for odd
    /// quarter turns), before any background.
    public static func contentSize(of document: ProjectDocument) -> CGSize {
        let crop = outputCrop(of: document)
        return document.transform.rotationQuarterTurns % 2 == 1
            ? CGSize(width: crop.height, height: crop.width)
            : crop.size
    }

    /// Maps canvas pixels to content pixels (both y-down): subtract the crop
    /// origin, rotate clockwise by the quarter turns, then flip horizontally /
    /// vertically in content space.
    public static func contentTransform(of document: ProjectDocument) -> CGAffineTransform {
        let crop = outputCrop(of: document)
        let w = crop.width
        let h = crop.height
        var t = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        let rotation: CGAffineTransform
        switch document.transform.rotationQuarterTurns {
        case 1: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: rotation = .identity
        }
        t = t.concatenating(rotation)
        let size = contentSize(of: document)
        if document.transform.flipHorizontal {
            t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        }
        if document.transform.flipVertical {
            t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        }
        return t
    }

    /// Background geometry for `document` (`nil` without a background).
    /// `balance` is the auto-balance space (see `outputLayout(of:)`, which
    /// measures it from the pixels).
    public static func backgroundLayout(of document: ProjectDocument, balance: BackgroundInsets = .zero) -> BackgroundLayout? {
        guard let style = document.background else { return nil }
        return BackgroundLayout(contentSize: contentSize(of: document), style: style,
                                scale: document.canvas.scale, balance: balance)
    }

    /// Output image size in pixels: the content size, or the background
    /// canvas when there is one. Static, so it can't measure auto-balance
    /// (pass `balance`, or use the instance `outputLayout(of:)`).
    public static func outputSize(of document: ProjectDocument, balance: BackgroundInsets = .zero) -> CGSize {
        backgroundLayout(of: document, balance: balance)?.canvasSize ?? contentSize(of: document)
    }

    /// Maps canvas pixels to output pixels (both y-down): `contentTransform`,
    /// then offset to the content's place on the background canvas. Invert it
    /// to map output clicks back. Same `balance` caveat as `outputSize`.
    public static func outputTransform(of document: ProjectDocument, balance: BackgroundInsets = .zero) -> CGAffineTransform {
        let t = contentTransform(of: document)
        guard let layout = backgroundLayout(of: document, balance: balance) else { return t }
        return t.concatenating(CGAffineTransform(translationX: layout.contentRect.minX, y: layout.contentRect.minY))
    }

    /// Everything needed to place the output, including auto-balance
    /// measured from the document's image content (cached).
    public struct OutputLayout: Sendable {
        public var size: CGSize
        /// Canvas pixels → output pixels.
        public var transform: CGAffineTransform
        public var background: BackgroundLayout?
        /// Edge analysis (present when the style needs it: inset or auto-balance).
        public var analysis: AutoBalance.Analysis?
    }

    public func outputLayout(of document: ProjectDocument) -> OutputLayout {
        guard let style = document.background else {
            return OutputLayout(size: Self.contentSize(of: document), transform: Self.contentTransform(of: document))
        }
        let analysis = (style.autoBalance || style.inset > 0) ? edgeAnalysis(of: document) : nil
        let balance = style.autoBalance ? (analysis?.balancingInsets ?? .zero) : .zero
        let layout = BackgroundLayout(contentSize: Self.contentSize(of: document), style: style,
                                      scale: document.canvas.scale, balance: balance)
        let transform = Self.contentTransform(of: document)
            .concatenating(CGAffineTransform(translationX: layout.contentRect.minX, y: layout.contentRect.minY))
        return OutputLayout(size: layout.canvasSize, transform: transform, background: layout, analysis: analysis)
    }

    /// Draws the exported result into `context`, whose user space must be
    /// output pixel space (y down, `outputLayout(of:).size`). `dirtyRect`
    /// in `options` is in canvas pixels.
    public func drawOutput(_ document: ProjectDocument, in context: CGContext, options: Options = Options()) {
        let layout = outputLayout(of: document)
        let crop = Self.outputCrop(of: document)
        var canvasOptions = options
        canvasOptions.dirtyRect = options.dirtyRect.map { $0.intersection(crop) } ?? crop

        func drawContent(_ context: CGContext) {
            context.saveGState()
            context.concatenate(layout.transform)
            context.clip(to: crop)
            drawCanvas(document, in: context, options: canvasOptions)
            context.restoreGState()
        }

        context.saveGState()
        defer { context.restoreGState() }
        guard let style = document.background, let background = layout.background else {
            drawContent(context)
            return
        }
        drawBackground(document, style: style, layout: background, in: context)
        BackgroundRenderer.drawCard(
            layout: background, style: style, scale: document.canvas.scale,
            edgeColor: layout.analysis?.edgeColor, baseScale: options.baseScale, context: context,
            drawContent: drawContent
        )
    }

    /// Canvas fill behind the card (WP5.2).
    private func drawBackground(_ document: ProjectDocument, style: BackgroundStyle, layout: BackgroundLayout, in context: CGContext) {
        var blurred: CGImage?
        if style.fill == .blurredScreenshot {
            blurred = backgroundCache.blurred(for: contentKey(of: document), size: layout.canvasSize) {
                guard let content = contentImage(of: document, maxDimension: 512) else { return nil }
                return BackgroundRenderer.makeBlurredBackdrop(from: content, size: layout.canvasSize)
            }
        }
        BackgroundRenderer.drawFill(style.fill, in: layout.canvasRect, context: context,
                                    images: assets, blurredScreenshot: blurred)
    }

    // MARK: Background analysis

    private func contentKey(of document: ProjectDocument) -> BackgroundCache.Key {
        BackgroundCache.Key(
            layers: document.layers,
            images: document.annotations.filter { if case .image = $0.kind { true } else { false } },
            crop: Self.outputCrop(of: document),
            transform: document.transform
        )
    }

    /// Auto-balance / inset edge analysis of the image content (layers +
    /// image annotations, crop + transform applied), cached per content.
    func edgeAnalysis(of document: ProjectDocument) -> AutoBalance.Analysis? {
        backgroundCache.analysis(for: contentKey(of: document)) {
            let size = Self.contentSize(of: document)
            let limit = Double(AutoBalance.maxAnalysisDimension)
            let s = min(1, limit / max(size.width, size.height))
            guard let image = contentImage(of: document, maxDimension: AutoBalance.maxAnalysisDimension),
                  var analysis = AutoBalance.analyze(image) else { return nil }
            if s < 1 {
                let m = analysis.margins
                analysis.margins = BackgroundInsets(top: (m.top / s).rounded(), left: (m.left / s).rounded(),
                                                    bottom: (m.bottom / s).rounded(), right: (m.right / s).rounded())
            }
            return analysis
        }
    }

    /// Image content in content (output-orientation) space, downscaled so the
    /// longer side is at most `maxDimension`.
    func contentImage(of document: ProjectDocument, maxDimension: Int) -> CGImage? {
        let size = Self.contentSize(of: document)
        let s = min(1, Double(maxDimension) / max(size.width, size.height))
        let w = max(Int((size.width * s).rounded()), 1), h = max(Int((size.height * s).rounded()), 1)
        guard let context = RenderSupport.makeBitmapContext(width: w, height: h) else { return nil }
        RenderSupport.flipToTopLeft(context, height: CGFloat(h))
        context.interpolationQuality = .medium
        context.scaleBy(x: Double(w) / size.width, y: Double(h) / size.height)
        context.concatenate(Self.contentTransform(of: document))
        let crop = Self.outputCrop(of: document)
        context.clip(to: crop)
        let painter = AnnotationPainter(canvasScale: document.canvas.scale)
        drawImageContent(document, in: context, painter: painter) { $0.intersects(crop) }
        return context.makeImage()
    }

    /// Renders the export image (crop + transform applied), sRGB RGBA8.
    public func makeImage(_ document: ProjectDocument) -> CGImage? {
        let size = outputLayout(of: document).size
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        RenderSupport.flipToTopLeft(context, height: CGFloat(height))
        context.interpolationQuality = .high
        drawOutput(document, in: context)
        return context.makeImage()
    }
}
