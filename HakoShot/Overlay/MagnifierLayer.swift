import AppKit
import HakoKit
import QuartzCore

/// Loupe next to the cursor (plan §4.3, UI report §1): 96 pt rounded square
/// showing the 15 × 15 device pixels around the cursor, nearest-neighbor
/// scaled, with a faint pixel grid and a framed center pixel. A caption pill
/// under it shows the coordinate / size text and the center pixel's color.
///
/// Source pixels are a display snapshot taken at overlay start; the loupe
/// shows a sub-rect of it via `contentsRect`, so a mouse move only changes
/// one rect (no per-move image work besides the 1-pixel color read).
final class MagnifierLayer {
    /// Container; frame = the view's bounds.
    let layer = CALayer()
    private let card = CALayer()          // shadow + border carrier
    private let loupe = CALayer()         // clipped pixels
    private let grid = CAShapeLayer()
    private let centerOuter = CALayer()
    private let centerInner = CALayer()
    private let caption = CALayer()
    private let captionText = CATextLayer()
    private let colorText = CATextLayer()
    private let swatch = CALayer()

    private var snapshot: FrozenSnapshot?
    private var lastColorPixel: (x: Int, y: Int)?
    private var lastColorHex = ""

    private typealias T = Tokens.Overlay
    private static let size = T.magnifierSize
    private static let count = T.magnifierPixelCount
    private static var cell: CGFloat { size / CGFloat(count) }
    private static let captionGap = Tokens.Spacing.xs

    init() {
        let size = Self.size
        card.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        card.cornerRadius = T.magnifierCornerRadius
        card.backgroundColor = NSColor.black.cgColor
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = Float(T.magnifierShadow.opacity)
        card.shadowRadius = T.magnifierShadow.radius
        card.shadowOffset = CGSize(width: 0, height: -T.magnifierShadow.y)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: T.magnifierCornerRadius, cornerHeight: T.magnifierCornerRadius, transform: nil)
        card.anchorPoint = .zero
        layer.addSublayer(card)

        loupe.frame = card.bounds
        loupe.cornerRadius = T.magnifierCornerRadius
        loupe.masksToBounds = true
        loupe.magnificationFilter = .nearest
        loupe.contentsGravity = .resize
        loupe.borderWidth = T.magnifierBorderWidth
        loupe.borderColor = T.magnifierBorderColor.cgColor
        card.addSublayer(loupe)

        let path = CGMutablePath()
        for i in 1..<Self.count {
            let v = (CGFloat(i) * Self.cell).rounded()
            path.move(to: CGPoint(x: v, y: 0))
            path.addLine(to: CGPoint(x: v, y: size))
            path.move(to: CGPoint(x: 0, y: v))
            path.addLine(to: CGPoint(x: size, y: v))
        }
        grid.path = path
        grid.strokeColor = T.magnifierGridColor.cgColor
        grid.lineWidth = Tokens.Stroke.hairline / 2
        grid.frame = loupe.bounds
        loupe.insertSublayer(grid, at: 0)

        // Center pixel: white ring inside a black ring.
        let half = Self.count / 2
        let cellRect = CGRect(x: CGFloat(half) * Self.cell, y: CGFloat(half) * Self.cell, width: Self.cell, height: Self.cell)
        centerOuter.frame = cellRect.insetBy(dx: -1, dy: -1)
        centerOuter.borderColor = T.magnifierCenterOuter.cgColor
        centerOuter.borderWidth = Tokens.Stroke.hairline
        centerInner.frame = cellRect
        centerInner.borderColor = T.magnifierCenterInner.cgColor
        centerInner.borderWidth = Tokens.Stroke.hairline
        loupe.addSublayer(centerOuter)
        loupe.addSublayer(centerInner)

        caption.backgroundColor = T.magnifierCaptionFill.cgColor
        caption.cornerRadius = Tokens.Radius.toolHighlight
        caption.anchorPoint = .zero
        caption.bounds = CGRect(x: 0, y: 0, width: size, height: T.magnifierCaptionHeight)
        for (text, color) in [(captionText, T.magnifierCaptionText), (colorText, T.magnifierCaptionSecondary)] {
            text.font = T.magnifierCaptionFont
            text.fontSize = T.magnifierCaptionFont.pointSize
            text.foregroundColor = color.cgColor
            text.alignmentMode = .center
            caption.addSublayer(text)
        }
        swatch.borderColor = NSColor(white: 1, alpha: 0.5).cgColor
        swatch.borderWidth = Tokens.Stroke.hairline
        swatch.cornerRadius = 2
        caption.addSublayer(swatch)
        layer.addSublayer(caption)

        OverlayLayerActions.disable([layer, card, loupe, grid, centerOuter, centerInner, caption, captionText, colorText, swatch])
        layer.isHidden = true
    }

    /// Source pixels for this display (`nil` = not available yet → hidden).
    func setSnapshot(_ snapshot: FrozenSnapshot?) {
        self.snapshot = snapshot
        loupe.contents = snapshot?.image
        lastColorPixel = nil
    }

    var hasSnapshot: Bool { snapshot != nil }

    func hide() {
        layer.isHidden = true
    }

    /// Shows the loupe for `global` (Quartz global cursor) at `local` (view
    /// coordinates), flipping away from the display edges.
    func show(global: CGPoint, local: CGPoint, caption text: String, within bounds: CGRect, scale: CGFloat) {
        guard let snapshot else {
            hide()
            return
        }
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        var unit = SnapshotCrop.unitSamplingRect(
            around: global, displayFrame: snapshot.displayFrame, scale: snapshot.scale,
            count: Self.count, imageSize: imageSize
        )
        // `contentsRect` is in the layer's (bottom-left origin) space; pixel rows run top-down.
        unit.origin.y = 1 - unit.origin.y - unit.height
        loupe.contentsRect = unit

        // Layout: loupe + caption to the bottom-right of the cursor, flipped at edges.
        let offset = T.magnifierOffset
        let size = Self.size
        let totalHeight = size + Self.captionGap + T.magnifierCaptionHeight
        var x = local.x + offset
        if x + size > bounds.maxX { x = local.x - offset - size }
        var top = local.y - offset
        if top - totalHeight < bounds.minY { top = local.y + offset + totalHeight }
        x = min(max(x, bounds.minX), bounds.maxX - size)
        top = min(max(top, bounds.minY + totalHeight), bounds.maxY)
        card.position = CGPoint(x: x.rounded(), y: (top - size).rounded())
        caption.position = CGPoint(x: x.rounded(), y: (top - totalHeight).rounded())

        layoutCaption(text: text, global: global, snapshot: snapshot, scale: scale)
        layer.isHidden = false
    }

    private func layoutCaption(text: String, global: CGPoint, snapshot: FrozenSnapshot, scale: CGFloat) {
        let height = T.magnifierCaptionHeight
        let lineHeight = (height - Tokens.Spacing.xs) / 2
        for sub in [captionText, colorText] { sub.contentsScale = scale }
        captionText.string = text
        captionText.frame = CGRect(x: 0, y: height / 2, width: Self.size, height: lineHeight)

        let pixel = SnapshotCrop.pixel(at: global, displayFrame: snapshot.displayFrame, scale: snapshot.scale)
        if lastColorPixel == nil || lastColorPixel?.x != pixel.x || lastColorPixel?.y != pixel.y {
            lastColorPixel = pixel
            let color = Self.color(at: pixel, in: snapshot.image)
            swatch.backgroundColor = color?.cgColor
            lastColorHex = color.map(Self.hex) ?? "—"
        }
        colorText.string = lastColorHex
        let textWidth = (lastColorHex as NSString).size(withAttributes: [.font: T.magnifierCaptionFont]).width.rounded(.up)
        let swatchSize = T.magnifierSwatch
        let total = swatchSize + Tokens.Spacing.xs + textWidth
        let startX = ((Self.size - total) / 2).rounded()
        let y = Tokens.Spacing.xxs
        swatch.frame = CGRect(x: startX, y: y + (lineHeight - swatchSize) / 2, width: swatchSize, height: swatchSize)
        colorText.frame = CGRect(x: startX + swatchSize + Tokens.Spacing.xs, y: y, width: textWidth, height: lineHeight)
        colorText.alignmentMode = .left
    }

    /// sRGB color of one pixel of `image`; `nil` outside the image.
    private static func color(at pixel: (x: Int, y: Int), in image: CGImage) -> NSColor? {
        guard pixel.x >= 0, pixel.y >= 0, pixel.x < image.width, pixel.y < image.height,
              let one = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes: [UInt8] = [0, 0, 0, 0]
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    private static func hex(_ color: NSColor) -> String {
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
