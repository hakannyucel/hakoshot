import CoreGraphics
import Foundation

/// Per-side lengths in output pixels.
public struct BackgroundInsets: Sendable, Hashable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(all value: Double) {
        self.init(top: value, left: value, bottom: value, right: value)
    }

    public static let zero = BackgroundInsets()

    public var horizontal: Double { left + right }
    public var vertical: Double { top + bottom }

    public static func + (a: BackgroundInsets, b: BackgroundInsets) -> BackgroundInsets {
        BackgroundInsets(top: a.top + b.top, left: a.left + b.left, bottom: a.bottom + b.bottom, right: a.right + b.right)
    }
}

/// Edge analysis behind the Background tool's **Inset** and **Auto-balance**.
///
/// Interpretation (Auto Balance adjusts the space around the content so the
/// image sits balanced): screenshots often have a uniform
/// margin (a page background, window chrome color) that is uneven, e.g. a
/// selection drawn with 40 px of white on the left and 8 px on the right.
/// Auto-balance detects that uniform *edge color* and the width of the
/// uniform band on every side, then pads the thinner side of each axis with
/// the edge color until both sides of the axis match (horizontal and vertical
/// are balanced independently, and nothing is ever cropped). The inset slider
/// uses the same edge color to add equal space on every side. When the edges
/// aren't a single color (a photo, content touching the border) auto-balance
/// adds nothing.
public enum AutoBalance {
    public struct Analysis: Sendable, Hashable {
        /// Color that fills inset / balance space: the dominant border color
        /// (or the border's average when it isn't uniform).
        public var edgeColor: RGBAColor
        /// Whether the border is (mostly) one color.
        public var isUniform: Bool
        /// Width of the uniform band on each side, in the analyzed image's
        /// pixels. Zero when not uniform, or when the whole image is uniform.
        public var margins: BackgroundInsets

        public init(edgeColor: RGBAColor, isUniform: Bool, margins: BackgroundInsets) {
            self.edgeColor = edgeColor
            self.isUniform = isUniform
            self.margins = margins
        }

        /// Space to add so opposite margins match (per axis).
        public var balancingInsets: BackgroundInsets {
            guard isUniform else { return .zero }
            let h = max(margins.left, margins.right)
            let v = max(margins.top, margins.bottom)
            return BackgroundInsets(top: v - margins.top, left: h - margins.left,
                                    bottom: v - margins.bottom, right: h - margins.right)
        }
    }

    /// Longest side analyzed; larger images are downsampled first (margins are
    /// scaled back, so they're accurate to about one analysis pixel).
    static let maxAnalysisDimension = 1024
    /// Share of border pixels that must match the dominant color.
    static let uniformShare = 0.8
    /// Per-channel tolerance (0...255) for "same color as the edge".
    static let tolerance = 10

    /// Analyzes `image`'s edges. `nil` only if a bitmap can't be created.
    public static func analyze(_ image: CGImage) -> Analysis? {
        let fullW = image.width, fullH = image.height
        guard fullW > 0, fullH > 0 else { return nil }
        let factor = max(1, Double(max(fullW, fullH)) / Double(maxAnalysisDimension))
        let w = max(Int((Double(fullW) / factor).rounded()), 1)
        let h = max(Int((Double(fullH) / factor).rounded()), 1)
        guard let context = RenderSupport.makeBitmapContext(width: w, height: h), let data = context.data else { return nil }
        context.interpolationQuality = factor > 1 ? .medium : .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = context.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: rowBytes * h)

        // Bitmap memory is top row first.
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = y * rowBytes + x * 4
            return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3]))
        }

        // Border pixels.
        var border: [(Int, Int, Int, Int)] = []
        border.reserveCapacity(2 * (w + h))
        for x in 0..<w {
            border.append(px(x, 0))
            if h > 1 { border.append(px(x, h - 1)) }
        }
        if h > 2 {
            for y in 1..<(h - 1) {
                border.append(px(0, y))
                if w > 1 { border.append(px(w - 1, y)) }
            }
        }

        // Dominant color: most common 4-bit-per-channel bucket, averaged.
        var buckets: [Int: (count: Int, sum: (Int, Int, Int, Int))] = [:]
        var total = (0, 0, 0, 0)
        for c in border {
            let key = (c.0 >> 4) << 12 | (c.1 >> 4) << 8 | (c.2 >> 4) << 4 | (c.3 >> 4)
            var entry = buckets[key] ?? (0, (0, 0, 0, 0))
            entry.count += 1
            entry.sum = (entry.sum.0 + c.0, entry.sum.1 + c.1, entry.sum.2 + c.2, entry.sum.3 + c.3)
            buckets[key] = entry
            total = (total.0 + c.0, total.1 + c.1, total.2 + c.2, total.3 + c.3)
        }
        guard let top = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        let n = top.count
        let dominant = (top.sum.0 / n, top.sum.1 / n, top.sum.2 / n, top.sum.3 / n)
        let matching = border.reduce(0) { $0 + (matches($1, dominant) ? 1 : 0) }
        let isUniform = Double(matching) / Double(border.count) >= uniformShare

        guard isUniform else {
            let m = Double(border.count)
            let avg = (Double(total.0) / m, Double(total.1) / m, Double(total.2) / m, Double(total.3) / m)
            return Analysis(edgeColor: straightColor(avg), isUniform: false, margins: .zero)
        }

        func rowIsEdge(_ y: Int) -> Bool {
            for x in 0..<w where !matches(px(x, y), dominant) { return false }
            return true
        }
        func columnIsEdge(_ x: Int) -> Bool {
            for y in 0..<h where !matches(px(x, y), dominant) { return false }
            return true
        }
        var topM = 0
        while topM < h, rowIsEdge(topM) { topM += 1 }
        var margins = BackgroundInsets.zero
        if topM < h {
            var bottomM = 0
            while bottomM < h - topM, rowIsEdge(h - 1 - bottomM) { bottomM += 1 }
            var leftM = 0
            while leftM < w, columnIsEdge(leftM) { leftM += 1 }
            var rightM = 0
            while rightM < w - leftM, columnIsEdge(w - 1 - rightM) { rightM += 1 }
            let sx = Double(fullW) / Double(w), sy = Double(fullH) / Double(h)
            margins = BackgroundInsets(top: (Double(topM) * sy).rounded(), left: (Double(leftM) * sx).rounded(),
                                       bottom: (Double(bottomM) * sy).rounded(), right: (Double(rightM) * sx).rounded())
        }
        let d = (Double(dominant.0), Double(dominant.1), Double(dominant.2), Double(dominant.3))
        return Analysis(edgeColor: straightColor(d), isUniform: true, margins: margins)
    }

    private static func matches(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance
            && abs(a.2 - b.2) <= tolerance && abs(a.3 - b.3) <= tolerance
    }

    /// Premultiplied 0...255 components → straight-alpha color.
    private static func straightColor(_ c: (Double, Double, Double, Double)) -> RGBAColor {
        guard c.3 > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        let a = c.3 / 255
        return RGBAColor(red: c.0 / 255 / a, green: c.1 / 255 / a, blue: c.2 / 255 / a, alpha: a)
    }
}
