import CoreGraphics
import Foundation
import HakoKit

/// Maps between canvas **pixels** (model space, top-left origin) and the canvas
/// view's **points** (flipped, top-left origin).
///
/// The view shows a *displayed* pixel space: the canvas itself (no crop /
/// transform / background), or the export output (`DocumentRenderer.outputLayout`:
/// crop + rotate/flip + background), or crop mode's uncropped rotated image.
/// `transform` maps canvas pixels into it; the view is that space at 100 %
/// (÷ `scale`) plus `margin` on every side; NSScrollView magnification is on top.
nonisolated struct CanvasGeometry: Equatable, Sendable {
    /// Displayed size in pixels (canvas, output or crop-mode image).
    var canvasSize: CGSize
    /// Canvas pixels per point (capture backing scale).
    var scale: CGFloat
    /// Gray border around the image, in view points.
    var margin: CGFloat
    /// Canvas pixels → displayed pixels (identity for the plain canvas).
    var transform: CGAffineTransform
    private var inverse: CGAffineTransform

    init(canvasSize: CGSize, scale: CGFloat, margin: CGFloat = EditorMetrics.canvasMargin, transform: CGAffineTransform = .identity) {
        self.canvasSize = canvasSize
        self.scale = scale > 0 ? scale : 1
        self.margin = margin
        self.transform = transform
        self.inverse = transform.inverted()
    }

    init(canvas: CanvasInfo, margin: CGFloat = EditorMetrics.canvasMargin) {
        self.init(canvasSize: CGSize(width: canvas.width, height: canvas.height), scale: canvas.scale, margin: margin)
    }

    /// Image size in points.
    var imageSize: CGSize { CGSize(width: canvasSize.width / scale, height: canvasSize.height / scale) }

    /// The canvas view's frame size.
    var viewSize: CGSize { CGSize(width: imageSize.width + 2 * margin, height: imageSize.height + 2 * margin) }

    /// Where the displayed image (output incl. background) sits in the view.
    var imageRect: CGRect { CGRect(origin: CGPoint(x: margin, y: margin), size: imageSize) }

    // Displayed pixels <-> view points.

    func viewPoint(fromOutput p: CGPoint) -> CGPoint {
        CGPoint(x: margin + p.x / scale, y: margin + p.y / scale)
    }

    func outputPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - margin) * scale, y: (p.y - margin) * scale)
    }

    func viewRect(fromOutput r: CGRect) -> CGRect {
        guard !r.isNull else { return .null }
        return CGRect(x: margin + r.minX / scale, y: margin + r.minY / scale, width: r.width / scale, height: r.height / scale)
    }

    func outputRect(fromView r: CGRect) -> CGRect {
        guard !r.isNull else { return .null }
        return CGRect(x: (r.minX - margin) * scale, y: (r.minY - margin) * scale, width: r.width * scale, height: r.height * scale)
    }

    // Canvas pixels <-> view points (through `transform`).

    func viewPoint(fromCanvas p: CGPoint) -> CGPoint {
        viewPoint(fromOutput: p.applying(transform))
    }

    func canvasPoint(fromView p: CGPoint) -> CGPoint {
        outputPoint(fromView: p).applying(inverse)
    }

    func viewRect(fromCanvas r: CGRect) -> CGRect {
        guard !r.isNull else { return .null }
        return viewRect(fromOutput: r.applying(transform))
    }

    func canvasRect(fromView r: CGRect) -> CGRect {
        guard !r.isNull else { return .null }
        return outputRect(fromView: r).applying(inverse)
    }

    /// Canvas pixels per *screen* point at `magnification` — what `HitTesting` calls
    /// `pixelsPerPoint`, so tolerances feel the same at every zoom.
    func pixelsPerScreenPoint(magnification: CGFloat) -> CGFloat {
        scale / max(magnification, 0.0001)
    }

    static func == (a: CanvasGeometry, b: CanvasGeometry) -> Bool {
        a.canvasSize == b.canvasSize && a.scale == b.scale && a.margin == b.margin && a.transform == b.transform
    }
}

/// What the canvas view shows for a document (pure; tested).
nonisolated enum CanvasDisplay: Equatable, Sendable {
    /// The canvas as is (no crop, transform or background): cheapest path.
    case canvas
    /// Crop mode: the uncropped image with rotate/flip applied.
    case crop
    /// The export output: crop + rotate/flip + background.
    case output

    static func mode(for document: ProjectDocument, cropping: Bool) -> CanvasDisplay {
        if cropping { return .crop }
        if document.background == nil, document.crop == nil, document.transform.isIdentity { return .canvas }
        return .output
    }

    /// Geometry for `mode`. `layout` is `renderer.outputLayout(of:)` (only
    /// read for `.output`; it measures auto-balance).
    static func geometry(
        for document: ProjectDocument,
        mode: CanvasDisplay,
        layout: () -> DocumentRenderer.OutputLayout
    ) -> CanvasGeometry {
        let scale = CGFloat(document.canvas.scale)
        switch mode {
        case .canvas:
            return CanvasGeometry(canvas: document.canvas)
        case .crop:
            return CanvasGeometry(canvasSize: CropMath.displayBounds(of: document).size, scale: scale,
                                  transform: CropMath.displayTransform(of: document))
        case .output:
            let output = layout()
            return CanvasGeometry(canvasSize: output.size, scale: scale, transform: output.transform)
        }
    }
}

/// Zoom levels for ⌘+ / ⌘− / fit (pure, tested).
nonisolated enum ZoomMath {
    static let steps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]
    static let minimum: CGFloat = 0.05
    static let maximum: CGFloat = 8
    private static let epsilon: CGFloat = 0.005

    static func clamp(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minimum), maximum)
    }

    /// Next larger step (or `maximum`).
    static func zoomIn(from zoom: CGFloat) -> CGFloat {
        steps.first { $0 > zoom + epsilon } ?? maximum
    }

    /// Next smaller step (or `minimum`).
    static func zoomOut(from zoom: CGFloat) -> CGFloat {
        steps.last { $0 < zoom - epsilon } ?? minimum
    }

    /// Largest zoom (never above 100 %) at which `content` fits in `viewport`.
    static func fit(content: CGSize, in viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return clamp(min(1, viewport.width / content.width, viewport.height / content.height))
    }

    /// "100%", "33%".
    static func label(_ zoom: CGFloat) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}

/// First window size + zoom for an image (pure, tested).
nonisolated enum EditorWindowSizing {
    struct Layout: Equatable {
        var contentSize: CGSize
        var zoom: CGFloat
    }

    /// Fits `geometry.viewSize` (image + margins) plus the top and bottom bars into
    /// `visibleFrame × EditorMetrics.maximumScreenFraction`, never above 100 %.
    static func initialLayout(for geometry: CanvasGeometry, visibleFrame: CGSize) -> Layout {
        let chrome = EditorMetrics.toolbarHeight + EditorMetrics.separatorHeight + EditorMetrics.bottomBarHeight
        let maxWidth = visibleFrame.width * EditorMetrics.maximumScreenFraction
        let maxHeight = visibleFrame.height * EditorMetrics.maximumScreenFraction
        let doc = geometry.viewSize
        let zoom = ZoomMath.fit(content: doc, in: CGSize(width: maxWidth, height: max(maxHeight - chrome, 1)))
        let minimum = EditorMetrics.minimumWindowSize
        let width = min(max(minimum.width, (doc.width * zoom).rounded(.up)), max(maxWidth, minimum.width))
        let height = min(max(minimum.height, (doc.height * zoom).rounded(.up) + chrome), max(maxHeight, minimum.height))
        return Layout(contentSize: CGSize(width: width, height: height), zoom: zoom)
    }
}
