import CoreGraphics
import Foundation

// Shared drawing helpers for `Rendering/*`.
//
// Convention: every drawing function in this folder draws in a **y-down**
// user space (top-left origin), i.e. canvas pixel space as stored in the
// model. Callers set up the CTM (see `DocumentRenderer`); helpers here that
// need CoreGraphics' native y-up orientation (images, CoreText) flip locally.

public extension RGBAColor {
    /// sRGB `CGColor` for this color.
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum RenderSupport {
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 8-bit premultiplied RGBA sRGB bitmap context, cleared to transparent.
    /// The CTM is left in CoreGraphics' default y-up orientation.
    static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(width, 1),
            height: max(height, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Makes a bitmap context's user space y-down with the origin top-left.
    static func flipToTopLeft(_ context: CGContext, height: CGFloat) {
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
    }

    /// Draws `image` upright into `rect` of a y-down user space.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Applies a `ShadowSpec` (points) to the context's gstate.
    ///
    /// CoreGraphics shadow offset and blur are specified in the context's
    /// *base* space and ignore the CTM, so the values are pushed through the
    /// CTM here: `baseScale` is CTM units per base unit (1 for bitmap
    /// contexts; the backing scale factor for AppKit view contexts).
    static func setShadow(_ spec: ShadowSpec, canvasScale: Double, baseScale: Double, in context: CGContext) {
        let offset = CGSize(width: spec.offsetX * canvasScale, height: spec.offsetY * canvasScale)
        // `ctm` (user → device, y-up) carries the flip; `convertToDeviceSpace`
        // doesn't for bitmap contexts (their device space reports y-down).
        let ctm = context.ctm
        let deviceOffset = offset.applying(ctm)
        let deviceBlur = CGSize(width: spec.blur * canvasScale, height: 0).applying(ctm)
        let blur = hypot(deviceBlur.width, deviceBlur.height)
        let base = baseScale > 0 ? baseScale : 1
        context.setShadow(
            offset: CGSize(width: deviceOffset.width / base, height: deviceOffset.height / base),
            blur: blur / base,
            color: spec.color.cgColor
        )
    }

    /// How far (canvas px) a standard shadow can reach beyond a shape.
    static func shadowPadding(canvasScale: Double) -> Double {
        let spec = ShadowSpec.standard
        return (max(abs(spec.offsetX), abs(spec.offsetY)) + 2 * spec.blur) * canvasScale
    }

    /// `CGPath(roundedRect:)` with the radius clamped so it can't trap.
    static func roundedRectPath(_ rect: CGRect, radius: Double) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}
