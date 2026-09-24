import CoreGraphics
import Foundation

/// Settings of the editor's Background tool (plan §4.x / §5.4:
/// padding, inset, auto-balance, alignment, ratio, corners,
/// shadow). Stored in `ProjectDocument.background`; `nil` there = "None".
///
/// Lengths are in **points** and multiplied by `CanvasInfo.scale` at render
/// time, so a preset looks the same on 1× and 2× captures.
///
/// Rendering (see `BackgroundLayout` / `BackgroundRenderer`): the exported
/// content (crop + rotate/flip applied) becomes a *card*: grown by `inset` (and
/// by the auto-balance insets) and filled there with the screenshot's edge
/// color, clipped to `cornerRadius`, casting `shadow`. The card sits on a
/// canvas filled with `fill`, `padding` away from the edges, placed per
/// `alignment`; `aspectRatio` may widen/heighten the canvas.
public struct BackgroundStyle: Sendable, Hashable {
    public var fill: BackgroundFill
    /// Space between the card and the canvas edges, points.
    public var padding: Double
    /// Space added around the screenshot inside the card, filled with the
    /// screenshot's edge color, points.
    public var inset: Double
    /// Equalize the screenshot's own uniform margins (see `AutoBalance`).
    public var autoBalance: Bool
    public var alignment: BackgroundAlignment
    public var aspectRatio: BackgroundAspectRatio
    /// Corner radius of the card, points.
    public var cornerRadius: Double
    public var shadow: BackgroundShadow

    public init(
        fill: BackgroundFill = .preset(GradientCatalog.defaultPresetID),
        padding: Double = 64,
        inset: Double = 0,
        autoBalance: Bool = true,
        alignment: BackgroundAlignment = .center,
        aspectRatio: BackgroundAspectRatio = .auto,
        cornerRadius: Double = 12,
        shadow: BackgroundShadow = .standard
    ) {
        self.fill = fill
        self.padding = padding
        self.inset = inset
        self.autoBalance = autoBalance
        self.alignment = alignment
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// Plan §5.4 defaults: padding 64 pt, inset 0, auto-balance on, 12 pt
    /// corners, 50 % shadow, centered, ratio Auto, first catalog gradient.
    public static let standard = BackgroundStyle()
}

// MARK: - Fill

/// What the canvas behind the card is painted with.
public enum BackgroundFill: Sendable, Hashable {
    /// A gradient from `GradientCatalog` by stable id.
    case preset(String)
    /// A user-defined gradient.
    case gradient(GradientSpec)
    case solid(RGBAColor)
    /// A custom image / wallpaper stored as a project asset, aspect-filled.
    case image(AssetID)
    /// The screenshot itself, aspect-filled and heavily blurred.
    case blurredScreenshot
    /// Nothing (transparent padding; the shadow still shows).
    case transparent
}

extension BackgroundFill: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id, gradient, color, asset }

    private enum Kind: String, Codable {
        case preset, gradient, solid, image, blur, transparent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .preset: self = .preset(try c.decode(String.self, forKey: .id))
        case .gradient: self = .gradient(try c.decode(GradientSpec.self, forKey: .gradient))
        case .solid: self = .solid(try c.decode(RGBAColor.self, forKey: .color))
        case .image: self = .image(try c.decode(AssetID.self, forKey: .asset))
        case .blur: self = .blurredScreenshot
        case .transparent: self = .transparent
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let id):
            try c.encode(Kind.preset, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .gradient(let spec):
            try c.encode(Kind.gradient, forKey: .kind)
            try c.encode(spec, forKey: .gradient)
        case .solid(let color):
            try c.encode(Kind.solid, forKey: .kind)
            try c.encode(color, forKey: .color)
        case .image(let asset):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(asset, forKey: .asset)
        case .blurredScreenshot:
            try c.encode(Kind.blur, forKey: .kind)
        case .transparent:
            try c.encode(Kind.transparent, forKey: .kind)
        }
    }
}

// MARK: - Gradient

/// A "mesh-like" gradient: a multi-stop linear base plus soft radial glows
/// layered on top (each fades from its color to transparent).
public struct GradientSpec: Codable, Sendable, Hashable {
    public struct Stop: Codable, Sendable, Hashable {
        public var color: RGBAColor
        /// `0...1` along the gradient axis.
        public var location: Double

        public init(_ color: RGBAColor, at location: Double) {
            self.color = color
            self.location = location
        }
    }

    public struct Glow: Codable, Sendable, Hashable {
        public var color: RGBAColor
        /// Center in unit coordinates of the filled rect (y down).
        public var x: Double
        public var y: Double
        /// Radius as a fraction of the rect's longer side.
        public var radius: Double

        public init(_ color: RGBAColor, x: Double, y: Double, radius: Double) {
            self.color = color
            self.x = x
            self.y = y
            self.radius = radius
        }
    }

    public var stops: [Stop]
    /// Direction of the linear base in degrees, y down: 0 = left → right,
    /// 90 = top → bottom, 45 = top-left → bottom-right.
    public var angle: Double
    public var glows: [Glow]

    public init(stops: [Stop], angle: Double = 135, glows: [Glow] = []) {
        self.stops = stops
        self.angle = angle
        self.glows = glows
    }

    /// Evenly spaced stops.
    public init(colors: [RGBAColor], angle: Double = 135, glows: [Glow] = []) {
        let n = max(colors.count - 1, 1)
        self.init(stops: colors.enumerated().map { Stop($1, at: Double($0) / Double(n)) }, angle: angle, glows: glows)
    }
}

// MARK: - Alignment

/// One of the 3×3 positions of the card inside the padded canvas. Off-center
/// on an axis means the card sits flush against that canvas edge (its padding
/// moves to the opposite side), the popular "window rising from the bottom"
/// look.
public enum BackgroundAlignment: String, Codable, Sendable, Hashable, CaseIterable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    /// Horizontal position: 0 = left, 0.5 = center, 1 = right.
    public var horizontal: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: 0
        case .top, .center, .bottom: 0.5
        case .topRight, .right, .bottomRight: 1
        }
    }

    /// Vertical position: 0 = top, 0.5 = center, 1 = bottom.
    public var vertical: Double {
        switch self {
        case .topLeft, .top, .topRight: 0
        case .left, .center, .right: 0.5
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }
}

// MARK: - Aspect ratio

/// Output canvas proportions. `auto` = content + padding, nothing added;
/// a ratio grows one dimension (never shrinks) so `width / height` matches.
public enum BackgroundAspectRatio: Sendable, Hashable {
    case auto
    case ratio(width: Double, height: Double)

    public static let square = BackgroundAspectRatio.ratio(width: 1, height: 1)
    public static let fourThree = BackgroundAspectRatio.ratio(width: 4, height: 3)
    public static let threeTwo = BackgroundAspectRatio.ratio(width: 3, height: 2)
    public static let sixteenNine = BackgroundAspectRatio.ratio(width: 16, height: 9)

    /// The menu presets, in display order (portrait variants are custom ratios).
    public static let presets: [BackgroundAspectRatio] = [.auto, .square, .fourThree, .threeTwo, .sixteenNine]

    /// `width / height`, or `nil` for `auto` / degenerate values.
    public var value: Double? {
        guard case .ratio(let w, let h) = self, w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        return w / h
    }

    /// "Auto", "16:9", "1.5:1".
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .ratio(let w, let h): "\(Self.format(w)):\(Self.format(h))"
        }
    }

    /// Parses `label` back ("auto" case-insensitive, "W:H").
    public init?(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "auto" {
            self = .auto
            return
        }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        self = .ratio(width: w, height: h)
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }
}

extension BackgroundAspectRatio: Codable {
    /// Encoded as its label ("auto", "16:9") for readable project files.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let string = try c.decode(String.self)
        guard let value = BackgroundAspectRatio(label: string) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid aspect ratio '\(string)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self == .auto ? "auto" : label)
    }
}

// MARK: - Shadow

/// Drop shadow of the card. Lengths in points.
public struct BackgroundShadow: Codable, Sendable, Hashable {
    /// `0...1`; 0 disables the shadow.
    public var opacity: Double
    /// Blur radius, points.
    public var radius: Double
    public var offsetX: Double
    /// Positive = down.
    public var offsetY: Double

    public init(opacity: Double = 0.5, radius: Double = 24, offsetX: Double = 0, offsetY: Double = 12) {
        self.opacity = opacity
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// 50 % (plan §5.4), soft, slightly below.
    public static let standard = BackgroundShadow()
    public static let none = BackgroundShadow(opacity: 0, radius: 0, offsetX: 0, offsetY: 0)

    public var isVisible: Bool { opacity > 0 }
}

// MARK: - Codable

extension BackgroundStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case fill, padding, inset, autoBalance, alignment, aspectRatio, cornerRadius, shadow
    }

    /// `fill` is required (so unrelated JSON never decodes as a background);
    /// every other field falls back to its default, and unknown keys are
    /// ignored, so adding fields later stays compatible.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundStyle.standard
        fill = try c.decode(BackgroundFill.self, forKey: .fill)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? d.inset
        autoBalance = try c.decodeIfPresent(Bool.self, forKey: .autoBalance) ?? d.autoBalance
        alignment = try c.decodeIfPresent(BackgroundAlignment.self, forKey: .alignment) ?? d.alignment
        aspectRatio = try c.decodeIfPresent(BackgroundAspectRatio.self, forKey: .aspectRatio) ?? d.aspectRatio
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(BackgroundShadow.self, forKey: .shadow) ?? d.shadow
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fill, forKey: .fill)
        try c.encode(padding, forKey: .padding)
        try c.encode(inset, forKey: .inset)
        try c.encode(autoBalance, forKey: .autoBalance)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(shadow, forKey: .shadow)
    }
}
