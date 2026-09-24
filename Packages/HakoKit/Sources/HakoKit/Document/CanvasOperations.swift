import CoreGraphics
import Foundation

/// Side of the visible content a combined image is placed on (WP5.4).
public enum CombineEdge: String, Codable, Sendable, Hashable, CaseIterable {
    case right, bottom, left, top
}

/// Pure canvas operations behind the combine / canvas-size / resize actions
/// (WP5.4). All geometry is in canvas pixels, before crop and transform.
public enum CanvasOperations {
    // MARK: Combine

    /// Frame for an image of `size` placed next to `document.visibleRect` on
    /// `edge`, `spacing` pixels away, aligned to the visible area's top (for
    /// left/right) or left edge (for top/bottom). May lie outside the canvas;
    /// `insertingImage` grows the canvas to fit.
    public static func combineFrame(for size: CGSize, beside document: ProjectDocument, edge: CombineEdge, spacing: Double = 0) -> CGRect {
        let visible = document.visibleRect
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let origin: CGPoint = switch edge {
        case .right: CGPoint(x: visible.maxX + spacing, y: visible.minY)
        case .left: CGPoint(x: visible.minX - spacing - w, y: visible.minY)
        case .bottom: CGPoint(x: visible.minX, y: visible.maxY + spacing)
        case .top: CGPoint(x: visible.minX, y: visible.minY - spacing - h)
        }
        return CGRect(origin: origin, size: CGSize(width: w, height: h))
    }

    /// Adds `image` (an `.image` annotation) and grows the canvas so its frame
    /// fits. Growing to the left / top moves everything already on the canvas
    /// (layers, annotations, crop) right / down. A crop, if any, is extended to
    /// include the image. Non-image annotations are simply appended.
    public static func insertingImage(_ image: Annotation, into document: ProjectDocument) -> ProjectDocument {
        // Where the canvas grows left/up, content (and the new frame) moves.
        let (grown, shift) = expanded(document, toInclude: image.bounds)
        var doc = grown
        let annotation = image.translated(by: shift)
        if let crop = doc.crop {
            doc.crop = crop.union(annotation.bounds.integral).intersection(doc.canvas.rect)
        }
        doc.annotations.append(annotation)
        return doc
    }

    /// Grows the canvas so `rect` (canvas pixels) is inside it; never shrinks.
    /// Returns the new document and how far existing content moved.
    static func expanded(_ document: ProjectDocument, toInclude rect: CGRect) -> (ProjectDocument, CGVector) {
        let canvas = document.canvas.rect
        let union = canvas.union(rect.integral)
        guard union != canvas else { return (document, .zero) }
        let offset = CGVector(dx: canvas.minX - union.minX, dy: canvas.minY - union.minY)
        var doc = document.translatingContent(by: offset)
        doc.canvas.width = Int(union.width.rounded())
        doc.canvas.height = Int(union.height.rounded())
        return (doc, offset)
    }

    // MARK: Canvas size

    /// New canvas size with the existing content placed by `anchor` (e.g.
    /// `.topLeft` keeps it at the origin and adds / removes space at the
    /// right and bottom; `.center` splits it). Shrinking may push content
    /// off the canvas (it is kept, just not visible). The crop moves with
    /// the content and is clipped to the new canvas (`nil` stays `nil`).
    public static func resizingCanvas(_ document: ProjectDocument, width: Int, height: Int, anchor: BackgroundAlignment) -> ProjectDocument {
        let w = max(width, 1)
        let h = max(height, 1)
        let dx = (Double(w - document.canvas.width) * anchor.horizontal).rounded(.down)
        let dy = (Double(h - document.canvas.height) * anchor.vertical).rounded(.down)
        var doc = document.translatingContent(by: CGVector(dx: dx, dy: dy))
        doc.canvas.width = w
        doc.canvas.height = h
        if let crop = doc.crop {
            let clipped = crop.intersection(doc.canvas.rect)
            doc.crop = clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        return doc
    }

    // MARK: Resize (resolution)

    /// Scales the whole document so the visible area (`crop ?? canvas`,
    /// before rotation) becomes `width × height` pixels. Assets keep their
    /// pixels (layers draw them scaled), so this is non-destructive and
    /// undoable. Stroke widths, font sizes, counter diameters, redaction
    /// strengths and the canvas `scale` (points → pixels, which also scales
    /// background padding) follow by the geometric mean of the two factors.
    public static func resizingImage(_ document: ProjectDocument, width: Int, height: Int) -> ProjectDocument {
        let visible = document.visibleRect
        guard visible.width > 0, visible.height > 0, width > 0, height > 0 else { return document }
        let sx = Double(width) / visible.width
        let sy = Double(height) / visible.height
        guard sx.isFinite, sy.isFinite, sx != 1 || sy != 1 else { return document }
        return scaled(document, sx: sx, sy: sy)
    }

    /// Scales every geometric value by `sx` / `sy`.
    public static func scaled(_ document: ProjectDocument, sx: Double, sy: Double) -> ProjectDocument {
        var doc = document
        func scale(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
        }
        doc.canvas.width = max(Int((Double(document.canvas.width) * sx).rounded()), 1)
        doc.canvas.height = max(Int((Double(document.canvas.height) * sy).rounded()), 1)
        doc.canvas.scale = document.canvas.scale * (sx * sy).squareRoot()
        doc.layers = document.layers.map { layer in
            var copy = layer
            copy.frame = scale(layer.frame)
            return copy
        }
        doc.crop = document.crop.map { crop in
            let r = scale(crop)
            // Integral edges so the output size is exactly the requested one.
            return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: max(r.width.rounded(), 1), height: max(r.height.rounded(), 1))
                .intersection(doc.canvas.rect)
        }
        doc.annotations = document.annotations.map { $0.scaled(sx: sx, sy: sy) }
        return doc
    }
}

extension ProjectDocument {
    /// Moves layers, annotations and the crop by `offset` (canvas size unchanged).
    func translatingContent(by offset: CGVector) -> ProjectDocument {
        guard offset != .zero else { return self }
        var doc = self
        doc.layers = layers.map { layer in
            var copy = layer
            copy.frame = layer.frame.offsetBy(dx: offset.dx, dy: offset.dy)
            return copy
        }
        doc.annotations = annotations.map { $0.translated(by: offset) }
        doc.crop = crop?.offsetBy(dx: offset.dx, dy: offset.dy)
        return doc
    }
}

public extension Annotation {
    /// Copy with all geometry scaled by `sx` / `sy` about the canvas origin.
    /// Lengths without a direction (stroke width, font size, counter
    /// diameter, corner radii, redaction strength) use `√(sx·sy)`.
    func scaled(sx: Double, sy: Double) -> Annotation {
        let s = (sx * sy).squareRoot()
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * sx, y: point.y * sy) }
        func r(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy) }
        var copy = self
        copy.style.strokeWidth *= s
        switch kind {
        case .rectangle(var shape):
            shape.rect = r(shape.rect); shape.cornerRadius *= s; copy.kind = .rectangle(shape)
        case .filledRectangle(var shape):
            shape.rect = r(shape.rect); shape.cornerRadius *= s; copy.kind = .filledRectangle(shape)
        case .ellipse(var shape):
            shape.rect = r(shape.rect); shape.cornerRadius *= s; copy.kind = .ellipse(shape)
        case .line(var shape):
            shape.start = p(shape.start); shape.end = p(shape.end); copy.kind = .line(shape)
        case .arrow(var shape):
            shape.start = p(shape.start); shape.end = p(shape.end); shape.control = shape.control.map(p)
            copy.kind = .arrow(shape)
        case .text(var shape):
            shape.frame = r(shape.frame); shape.fontSize *= s; copy.kind = .text(shape)
        case .pencil(var shape):
            shape.points = shape.points.map(p); copy.kind = .pencil(shape)
        case .highlighter(var shape):
            shape.points = shape.points.map(p); copy.kind = .highlighter(shape)
        case .counter(var shape):
            shape.center = p(shape.center); shape.diameter *= s; copy.kind = .counter(shape)
        case .redaction(var shape):
            shape.rect = r(shape.rect); shape.strength *= s; copy.kind = .redaction(shape)
        case .spotlight(var shape):
            shape.rect = r(shape.rect); shape.cornerRadius *= s; copy.kind = .spotlight(shape)
        case .image(var shape):
            shape.frame = r(shape.frame); copy.kind = .image(shape)
        }
        return copy
    }
}
