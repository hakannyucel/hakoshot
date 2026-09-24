import CoreGraphics

/// "Max resolution" recording setting (plan §4.13). Caps the **short side**
/// of the output in pixels, keeping the aspect ratio. `.original` = no cap.
public enum RecordingResolutionCap: String, Sendable, Hashable, Codable, CaseIterable {
    case original
    case p2160
    case p1440
    case p1080
    case p720

    /// Short-side cap in pixels; `nil` for `.original`.
    public var shortSideLimit: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }
}

/// What to do when the requested codec is H.264 and the output exceeds the
/// H.264 limit (plan §1.3, user decision §9.2-2).
public enum H264OverflowPolicy: String, Sendable, Hashable, Codable {
    /// Keep the full resolution and encode with HEVC (default).
    case switchToHEVC
    /// Keep H.264 and scale the output down until it fits.
    case downscale
}

/// The encoder's frame size and codec, derived from a capture rect.
public struct RecordingOutputPlan: Sendable, Hashable {
    /// Encoded frame size in pixels (both even, ≥ 2).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Codec actually used (may differ from the requested one).
    public var codec: VideoCodec
    /// Output pixels per captured point (after 1x and max-resolution caps).
    /// Metadata stays in points; renderers multiply by this.
    public var effectiveScale: Double
    /// `true` when the requested H.264 was replaced with HEVC.
    public var didSwitchToHEVC: Bool
    /// `true` when the size was reduced for the H.264 limit (`.downscale`).
    public var didDownscaleForH264: Bool

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        codec: VideoCodec,
        effectiveScale: Double,
        didSwitchToHEVC: Bool = false,
        didDownscaleForH264: Bool = false
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.effectiveScale = effectiveScale
        self.didSwitchToHEVC = didSwitchToHEVC
        self.didDownscaleForH264 = didDownscaleForH264
    }

    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}

/// Pure output-size math for recordings (plan §1.3, §4.13).
///
/// Pipeline: `points × backingScale` (or × 1 with "Scale Retina videos to
/// 1x") → short-side cap ("Max resolution") → floor to even → H.264 limit
/// check (switch to HEVC, or downscale).
public enum RecordingGeometry {
    /// H.264 Level 5.1/5.2 `MaxFS`: 36 864 macroblocks (16×16) per frame,
    /// i.e. 9 437 184 luma samples (4096×2304). 5K (5120×2880 = 57 600 MBs)
    /// is over.
    public static let h264MaxMacroblocks = 36_864
    /// Largest width/height the hardware H.264 encoder accepts (VideoToolbox
    /// caps H.264 at 4096 on Apple silicon; R0 spike confirms).
    public static let h264MaxDimension = 4_096

    /// Floors to the nearest even integer, minimum 2 (4:2:0 needs even sizes).
    public static func evenFloor(_ value: Double) -> Int {
        guard value.isFinite else { return 2 }
        let floored = Int(value.rounded(.down))
        return max(2, floored - (floored & 1))
    }

    /// Raw pixel size before any cap: `points × scale` (scale 1 when
    /// `scaleTo1x`). Not rounded.
    public static func rawPixelSize(pointSize: CGSize, backingScale: Double, scaleTo1x: Bool) -> CGSize {
        let scale = scaleTo1x ? 1 : max(backingScale, 1)
        return CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    /// Size after 1x and max-resolution caps, floored to even. Never upscales.
    public static func outputPixelSize(
        pointSize: CGSize,
        backingScale: Double,
        scaleTo1x: Bool = false,
        maxResolution: RecordingResolutionCap = .original
    ) -> (width: Int, height: Int) {
        let raw = rawPixelSize(pointSize: pointSize, backingScale: backingScale, scaleTo1x: scaleTo1x)
        var factor = 1.0
        if let limit = maxResolution.shortSideLimit {
            let shortSide = min(raw.width, raw.height)
            if shortSide > Double(limit) { factor = Double(limit) / shortSide }
        }
        return (evenFloor(raw.width * factor), evenFloor(raw.height * factor))
    }

    /// Whether H.264 (Level 5.2, hardware encoder) can encode this frame size.
    public static func fitsH264(width: Int, height: Int) -> Bool {
        guard width <= h264MaxDimension, height <= h264MaxDimension else { return false }
        let macroblocks = ((width + 15) / 16) * ((height + 15) / 16)
        return macroblocks <= h264MaxMacroblocks
    }

    /// Largest even size with the same aspect ratio that fits H.264.
    /// Returns the input unchanged when it already fits.
    public static func h264FittingSize(width: Int, height: Int) -> (width: Int, height: Int) {
        if fitsH264(width: width, height: height) { return (width, height) }
        let w = Double(width), h = Double(height)
        // Start from the analytic bound, then step down until it fits
        // (macroblock rounding can push the first guess just over).
        let maxSamples = Double(h264MaxMacroblocks * 256)
        var factor = min(
            1,
            Double(h264MaxDimension) / max(w, h),
            (maxSamples / (w * h)).squareRoot()
        )
        while true {
            let size = (evenFloor(w * factor), evenFloor(h * factor))
            if fitsH264(width: size.0, height: size.1) { return size }
            factor *= 0.995
        }
    }

    /// Full plan: size, codec, effective scale.
    ///
    /// When `codec == .h264` and the size is over the H.264 limit:
    /// `.switchToHEVC` keeps the size and returns `.hevc`; `.downscale` keeps
    /// H.264 and shrinks to `h264FittingSize`.
    public static func plan(
        pointSize: CGSize,
        backingScale: Double,
        scaleTo1x: Bool = false,
        maxResolution: RecordingResolutionCap = .original,
        codec: VideoCodec = .h264,
        h264Overflow: H264OverflowPolicy = .switchToHEVC
    ) -> RecordingOutputPlan {
        var (width, height) = outputPixelSize(
            pointSize: pointSize,
            backingScale: backingScale,
            scaleTo1x: scaleTo1x,
            maxResolution: maxResolution
        )
        var resolvedCodec = codec
        var switched = false
        var downscaled = false
        if codec == .h264, !fitsH264(width: width, height: height) {
            switch h264Overflow {
            case .switchToHEVC:
                resolvedCodec = .hevc
                switched = true
            case .downscale:
                (width, height) = h264FittingSize(width: width, height: height)
                downscaled = true
            }
        }
        let effectiveScale = pointSize.width > 0 ? Double(width) / pointSize.width : 1
        return RecordingOutputPlan(
            pixelWidth: width,
            pixelHeight: height,
            codec: resolvedCodec,
            effectiveScale: effectiveScale,
            didSwitchToHEVC: switched,
            didDownscaleForH264: downscaled
        )
    }
}

/// Aspect-ratio presets for the recording HUD and Studio canvas
/// (plan §4.2, §5.2). `freeform` / `auto` have no fixed ratio.
public struct RecordingAspectRatio: Sendable, Hashable, Codable, CustomStringConvertible {
    /// `0` for freeform/auto.
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let freeform = RecordingAspectRatio(width: 0, height: 0)
    public static let square = RecordingAspectRatio(width: 1, height: 1)
    public static let fourThree = RecordingAspectRatio(width: 4, height: 3)
    public static let fiveFour = RecordingAspectRatio(width: 5, height: 4)
    public static let threeTwo = RecordingAspectRatio(width: 3, height: 2)
    public static let sixteenNine = RecordingAspectRatio(width: 16, height: 9)
    public static let sixteenTen = RecordingAspectRatio(width: 16, height: 10)
    public static let nineSixteen = RecordingAspectRatio(width: 9, height: 16)
    public static let fourFive = RecordingAspectRatio(width: 4, height: 5)

    /// HUD ratio menu order (plus "Custom", which the app handles).
    public static let hudPresets: [RecordingAspectRatio] = [
        .freeform, .square, .fourThree, .fiveFour, .threeTwo, .sixteenNine, .sixteenTen, .nineSixteen,
    ]
    /// Studio canvas presets; `.freeform` means "Auto" (source ratio).
    public static let studioPresets: [RecordingAspectRatio] = [
        .freeform, .sixteenNine, .fourThree, .square, .fourFive, .nineSixteen,
    ]

    public var isFreeform: Bool { width <= 0 || height <= 0 }

    /// width / height; `nil` for freeform.
    public var value: Double? { isFreeform ? nil : Double(width) / Double(height) }

    /// "16:9", or "freeform".
    public var description: String { isFreeform ? "freeform" : "\(width):\(height)" }

    /// Parses "16:9" / "freeform" / "auto".
    public init?(label: String) {
        let lower = label.lowercased()
        if lower == "freeform" || lower == "auto" { self = .freeform; return }
        let parts = lower.split(separator: ":")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
    }

    /// Height for a given width at this ratio (freeform: unchanged `nil`).
    public func height(forWidth width: Double) -> Double? {
        value.map { width / $0 }
    }

    /// Width for a given height at this ratio.
    public func width(forHeight height: Double) -> Double? {
        value.map { height * $0 }
    }

    /// Largest size with this ratio inside `bounds` (freeform: `bounds`).
    public func largestSize(fittingIn bounds: CGSize) -> CGSize {
        guard let ratio = value, bounds.width > 0, bounds.height > 0 else { return bounds }
        if bounds.width / bounds.height > ratio {
            return CGSize(width: bounds.height * ratio, height: bounds.height)
        }
        return CGSize(width: bounds.width, height: bounds.width / ratio)
    }

    /// Output pixel size for a canvas of `outputHeight` px (Studio), even.
    /// Freeform uses `sourceSize`'s ratio.
    public func canvasPixelSize(outputHeight: Int, sourceSize: CGSize) -> (width: Int, height: Int) {
        let sourceRatio: Double = sourceSize.height > 0 ? Double(sourceSize.width / sourceSize.height) : 16.0 / 9.0
        let ratio: Double = value ?? sourceRatio
        let height = RecordingGeometry.evenFloor(Double(outputHeight))
        return (RecordingGeometry.evenFloor((Double(height) * ratio).rounded()), height)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let label = try c.decode(String.self)
        guard let ratio = RecordingAspectRatio(label: label) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad aspect ratio \(label)")
        }
        self = ratio
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
