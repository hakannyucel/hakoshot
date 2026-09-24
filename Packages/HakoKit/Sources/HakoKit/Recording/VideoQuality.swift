/// Video codec for recordings and exports (plan §1.3, §4.13).
public enum VideoCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264
    case hevc

    /// Bitrate ceiling in bits/s (100 Mbps H.264, 80 Mbps HEVC).
    public var maxBitrate: Int {
        switch self {
        case .h264: 100_000_000
        case .hevc: 80_000_000
        }
    }

    /// HEVC needs fewer bits for the same quality.
    public var bitsPerPixelFactor: Double {
        switch self {
        case .h264: 1.0
        case .hevc: 0.7
        }
    }
}

/// Recording quality presets (plan §4.13, §5.2). Default `.high`; Studio raw
/// recordings are always `.ultra`.
public enum VideoQuality: String, Sendable, Hashable, Codable, CaseIterable {
    case low
    case medium
    case high
    case ultra

    public static let `default`: VideoQuality = .high
    /// Studio raw recordings are re-encoded later, so they record at Ultra.
    public static let studioRaw: VideoQuality = .ultra

    /// Bits per pixel per frame for H.264 (HEVC × 0.7).
    public var bitsPerPixel: Double {
        switch self {
        case .low: 0.02
        case .medium: 0.035
        case .high: 0.05
        case .ultra: 0.08
        }
    }

    /// Bitrate floor in bits/s, for every quality and codec.
    public static let minBitrate = 2_000_000

    /// Average bitrate in bits/s:
    /// `width × height × fps × bpp × codecFactor`, clamped to
    /// `[minBitrate, codec.maxBitrate]`. E.g. 1080p60 High H.264 = 6 220 800.
    public func bitrate(width: Int, height: Int, fps: Int, codec: VideoCodec = .h264) -> Int {
        let raw = Double(max(width, 0)) * Double(max(height, 0)) * Double(max(fps, 0))
            * bitsPerPixel * codec.bitsPerPixelFactor
        let rounded = Int(raw.rounded())
        return min(max(rounded, Self.minBitrate), codec.maxBitrate)
    }
}

/// Frame-rate lists (plan §4.13, §5.2).
public enum RecordingFrameRates {
    /// Video fps menu, highest first. Default 60.
    public static let video: [Int] = [60, 50, 30, 25, 24, 15]
    public static let defaultVideo = 60
    /// GIF fps menu. Default 15.
    public static let gif: [Int] = [5, 10, 15, 20, 24, 30]
    public static let defaultGIF = 15
    /// Studio raw recordings: up to the display refresh rate, capped here.
    public static let studioRawMax = 60

    /// The closest value in `list` to `fps` (ties go to the higher value).
    /// Used to sanitize URL/Settings input.
    public static func nearest(_ fps: Int, in list: [Int] = video) -> Int {
        guard let first = list.first else { return fps }
        return list.reduce(first) { best, candidate in
            let db = abs(best - fps), dc = abs(candidate - fps)
            if dc < db || (dc == db && candidate > best) { return candidate }
            return best
        }
    }

    /// Studio raw fps: display refresh rate, capped at `studioRawMax`,
    /// never below 1.
    public static func studioRawFPS(displayRefreshRate: Double) -> Int {
        guard displayRefreshRate.isFinite, displayRefreshRate >= 1 else { return studioRawMax }
        return min(studioRawMax, Int(displayRefreshRate.rounded()))
    }
}
