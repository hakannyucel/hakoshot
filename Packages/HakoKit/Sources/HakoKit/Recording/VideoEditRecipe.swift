import Foundation

/// A rectangle in source video pixels, top-left origin (matches
/// `AVAssetTrack.naturalSize` orientation after `preferredTransform`).
public struct VideoCropRect: Sendable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Output container of the classic editor (plan §4.16 "Quality: Format").
public enum VideoEditOutputFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case mp4
    case gif

    public var fileExtension: String { rawValue }
}

/// Audio settings of the classic editor (plan §4.16 "Audio").
public struct VideoEditAudio: Sendable, Hashable, Codable {
    /// Upper bound of `volume` and `trackGains` (200 %, plan §4.16).
    public static let maxGain = 2.0

    public var muted: Bool
    /// Master gain, `0…2` (1 = unchanged, 2 = +6 dB boost).
    public var volume: Double
    /// Downmix to one channel.
    public var mono: Bool
    /// Per-track gain `0…2`, in file track order (mic, system for separate
    /// tracks). Missing entries mean 1.
    public var trackGains: [Double]

    public init(muted: Bool = false, volume: Double = 1, mono: Bool = false, trackGains: [Double] = []) {
        self.muted = muted
        self.volume = volume
        self.mono = mono
        self.trackGains = trackGains
    }

    /// Effective gain of track `index` (0 when muted): `volume × trackGain`.
    public func gain(forTrack index: Int) -> Double {
        if muted { return 0 }
        let track = trackGains.indices.contains(index) ? trackGains[index] : 1
        return volume * track
    }

    /// `true` when the audio passes through unchanged.
    public var isUnchanged: Bool {
        !muted && volume == 1 && !mono && trackGains.allSatisfy { $0 == 1 }
    }

    public func normalized() -> VideoEditAudio {
        VideoEditAudio(
            muted: muted,
            volume: Self.clampGain(volume),
            mono: mono,
            trackGains: trackGains.map(Self.clampGain)
        )
    }

    private static func clampGain(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), maxGain)
    }

    private enum CodingKeys: String, CodingKey { case muted, volume, mono, trackGains }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
            volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            mono: try c.decodeIfPresent(Bool.self, forKey: .mono) ?? false,
            trackGains: try c.decodeIfPresent([Double].self, forKey: .trackGains) ?? []
        )
    }
}

/// GIF export settings (plan §4.17, §5: 15 fps, 800 × auto, optimize on,
/// quality ≈ 0.8).
public struct GIFExportOptions: Sendable, Hashable, Codable {
    /// Browsers stretch delays below 2 cs, so GIFs stop at 50 fps (§1.7).
    public static let maxFPS = 50
    /// Largest palette the GIF writer keeps exactly (ImageIO reserves one
    /// index of 256 for transparency).
    public static let maxColors = 255
    public static let minColors = 64
    public static let maxDither = 0.8

    public var fps: Int
    /// Output width in pixels; 0 = source (crop) width. Never upscales.
    public var width: Int
    /// Merge identical consecutive frames and shrink the palette to content.
    public var optimize: Bool
    /// `0…1` → palette 64…255 colors and dithering 0…0.8.
    public var quality: Double

    public init(
        fps: Int = RecordingFrameRates.defaultGIF,
        width: Int = 800,
        optimize: Bool = true,
        quality: Double = 0.8
    ) {
        self.fps = fps
        self.width = width
        self.optimize = optimize
        self.quality = quality
    }

    public static let `default` = GIFExportOptions()

    /// Palette size for `quality` (64…255).
    public var paletteColorCount: Int {
        let q = Self.clampUnit(quality)
        return Self.minColors + Int((q * Double(Self.maxColors - Self.minColors)).rounded())
    }

    /// Floyd–Steinberg strength for `quality` (0…0.8).
    public var ditherStrength: Double { Self.clampUnit(quality) * Self.maxDither }

    /// Output size for a source (after crop) of `sourceWidth × sourceHeight`:
    /// `width` capped at the source width, height by aspect ratio, each ≥ 1.
    public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let sw = max(1, sourceWidth), sh = max(1, sourceHeight)
        let w = width > 0 ? min(width, sw) : sw
        let h = max(1, Int((Double(w) * Double(sh) / Double(sw)).rounded()))
        return (w, h)
    }

    public func normalized() -> GIFExportOptions {
        GIFExportOptions(
            fps: min(max(fps, 1), Self.maxFPS),
            width: max(0, width),
            optimize: optimize,
            quality: Self.clampUnit(quality)
        )
    }

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0.8 }
        return min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case fps, width, optimize, quality }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GIFExportOptions()
        self.init(
            fps: try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps,
            width: try c.decodeIfPresent(Int.self, forKey: .width) ?? d.width,
            optimize: try c.decodeIfPresent(Bool.self, forKey: .optimize) ?? d.optimize,
            quality: try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        )
    }
}

/// Everything the classic video editor changes (plan §4.16). Consumed by the
/// render pipeline (R3.2) and edited by the editor UI (R3.3).
///
/// JSON is stable (sorted keys) and tolerant: every key is optional on
/// decode, so a DEBUG URL can pass a partial recipe such as
/// `{"trim":{"start":2,"end":7}}`.
public struct VideoEditRecipe: Sendable, Hashable, Codable {
    public static let currentVersion = 1
    public static let maxDimension = 16384
    public static let maxFPS = 120

    public var version: Int
    /// Kept source range in seconds; `nil` = whole video.
    public var trim: EditTimeRange?
    /// Removed source ranges in seconds.
    public var cuts: [EditTimeRange]
    /// Crop in source pixels; `nil` = full frame.
    public var crop: VideoCropRect?
    /// Output width/height in pixels. Both set = exact size; one set = the
    /// other follows the crop aspect ratio. Take precedence over `scale`.
    public var outputWidth: Int?
    public var outputHeight: Int?
    /// Output scale relative to the crop size (used when no output size).
    public var scale: Double?
    /// Output fps; `nil` = source fps.
    public var fps: Int?
    public var quality: VideoQuality
    public var codec: VideoCodec
    public var audio: VideoEditAudio
    public var format: VideoEditOutputFormat
    public var gif: GIFExportOptions

    public init(
        trim: EditTimeRange? = nil,
        cuts: [EditTimeRange] = [],
        crop: VideoCropRect? = nil,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        scale: Double? = nil,
        fps: Int? = nil,
        quality: VideoQuality = .default,
        codec: VideoCodec = .h264,
        audio: VideoEditAudio = VideoEditAudio(),
        format: VideoEditOutputFormat = .mp4,
        gif: GIFExportOptions = .default
    ) {
        self.version = Self.currentVersion
        self.trim = trim
        self.cuts = cuts
        self.crop = crop
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.scale = scale
        self.fps = fps
        self.quality = quality
        self.codec = codec
        self.audio = audio
        self.format = format
        self.gif = gif
    }

    // MARK: Derived values

    /// The trim/cut timeline for a source of `sourceDuration` seconds.
    public func timeline(sourceDuration: Double) -> EditTimeline {
        EditTimeline(sourceDuration: sourceDuration, trim: trim, cuts: cuts)
    }

    /// Crop clamped to the source, with even size (≥ 2) and even origin;
    /// the full frame when `crop` is `nil` or empty.
    public func effectiveCrop(sourceWidth: Int, sourceHeight: Int) -> VideoCropRect {
        let sw = max(2, sourceWidth), sh = max(2, sourceHeight)
        guard let crop, crop.width > 0, crop.height > 0 else {
            return VideoCropRect(x: 0, y: 0, width: sw, height: sh)
        }
        var x = Self.evenDown(min(max(crop.x, 0), sw - 2))
        var y = Self.evenDown(min(max(crop.y, 0), sh - 2))
        let w = Self.evenDown(min(max(crop.width, 2), sw - x))
        let h = Self.evenDown(min(max(crop.height, 2), sh - y))
        x = min(x, sw - w)
        y = min(y, sh - h)
        return VideoCropRect(x: x, y: y, width: max(2, w), height: max(2, h))
    }

    /// Encoded MP4 size: from `outputWidth/Height`, else `scale`, else the
    /// crop size. Always even, in `2…maxDimension`.
    public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let crop = effectiveCrop(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let cw = Double(crop.width), ch = Double(crop.height)
        var w = cw, h = ch
        switch (outputWidth.flatMap { $0 > 0 ? $0 : nil }, outputHeight.flatMap { $0 > 0 ? $0 : nil }) {
        case let (ow?, oh?): w = Double(ow); h = Double(oh)
        case let (ow?, nil): w = Double(ow); h = Double(ow) * ch / cw
        case let (nil, oh?): h = Double(oh); w = Double(oh) * cw / ch
        case (nil, nil):
            if let scale, scale.isFinite, scale > 0 { w = cw * scale; h = ch * scale }
        }
        return (Self.evenDimension(w), Self.evenDimension(h))
    }

    /// GIF frame size: `gif.width` applied to the crop size.
    public func gifOutputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let crop = effectiveCrop(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        return gif.outputSize(sourceWidth: crop.width, sourceHeight: crop.height)
    }

    /// Output fps: `fps` (or the GIF fps for GIF output), never above the
    /// source fps when that is known.
    public func outputFPS(sourceFPS: Double?) -> Int {
        let requested = format == .gif ? gif.normalized().fps : (fps ?? 0)
        let source = sourceFPS.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
        guard requested > 0 else { return min(source ?? 60, Self.maxFPS) }
        return min(requested, source ?? requested, Self.maxFPS)
    }

    // MARK: Validation

    /// Source-independent clamping: fps `1…120`, scale `> 0`, positive
    /// sizes rounded to even, gains `0…2`, GIF options clamped, trim/cut
    /// edges finite and ordered. Keeps `nil`s.
    public func normalized() -> VideoEditRecipe {
        var r = self
        r.version = Self.currentVersion
        r.trim = trim.flatMap(Self.orderedRange)
        r.cuts = cuts.compactMap(Self.orderedRange).filter { !$0.isEmpty }
        r.crop = crop.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        r.outputWidth = outputWidth.flatMap { $0 > 0 ? Self.evenDimension(Double($0)) : nil }
        r.outputHeight = outputHeight.flatMap { $0 > 0 ? Self.evenDimension(Double($0)) : nil }
        r.scale = scale.flatMap { $0.isFinite && $0 > 0 ? min($0, 8) : nil }
        r.fps = fps.flatMap { $0 > 0 ? min($0, Self.maxFPS) : nil }
        r.audio = audio.normalized()
        r.gif = gif.normalized()
        return r
    }

    /// `normalized()` plus source-dependent clamping: trim/cuts clamped to
    /// the duration (a full-length trim becomes `nil`) and the crop clamped
    /// to the frame with even values (a full-frame crop becomes `nil`).
    public func normalized(sourceWidth: Int, sourceHeight: Int, sourceDuration: Double) -> VideoEditRecipe {
        var r = normalized()
        let timeline = r.timeline(sourceDuration: sourceDuration)
        r.trim = (timeline.trim.start == 0 && timeline.trim.end == timeline.sourceDuration) ? nil : timeline.trim
        r.cuts = timeline.cuts
        if r.crop != nil {
            let c = r.effectiveCrop(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            let full = c.x == 0 && c.y == 0 && c.width >= sourceWidth - 1 && c.height >= sourceHeight - 1
            r.crop = full ? nil : c
        }
        return r
    }

    // MARK: JSON

    /// Stable JSON (sorted keys, no escaped slashes).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }

    public static func decode(json data: Data) throws -> VideoEditRecipe {
        try JSONDecoder().decode(VideoEditRecipe.self, from: data)
    }

    public static func decode(json string: String) throws -> VideoEditRecipe {
        try decode(json: Data(string.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case version, trim, cuts, crop, outputWidth, outputHeight, scale, fps
        case quality, codec, audio, format, gif
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            trim: try c.decodeIfPresent(EditTimeRange.self, forKey: .trim),
            cuts: try c.decodeIfPresent([EditTimeRange].self, forKey: .cuts) ?? [],
            crop: try c.decodeIfPresent(VideoCropRect.self, forKey: .crop),
            outputWidth: try c.decodeIfPresent(Int.self, forKey: .outputWidth),
            outputHeight: try c.decodeIfPresent(Int.self, forKey: .outputHeight),
            scale: try c.decodeIfPresent(Double.self, forKey: .scale),
            fps: try c.decodeIfPresent(Int.self, forKey: .fps),
            quality: try c.decodeIfPresent(VideoQuality.self, forKey: .quality) ?? .default,
            codec: try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? .h264,
            audio: try c.decodeIfPresent(VideoEditAudio.self, forKey: .audio) ?? VideoEditAudio(),
            format: try c.decodeIfPresent(VideoEditOutputFormat.self, forKey: .format) ?? .mp4,
            gif: try c.decodeIfPresent(GIFExportOptions.self, forKey: .gif) ?? .default
        )
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    }

    // MARK: Helpers

    private static func evenDown(_ value: Int) -> Int { value & ~1 }

    private static func evenDimension(_ value: Double) -> Int {
        guard value.isFinite else { return 2 }
        let rounded = Int((value / 2).rounded()) * 2
        return min(max(rounded, 2), maxDimension)
    }

    private static func orderedRange(_ range: EditTimeRange) -> EditTimeRange? {
        guard range.start.isFinite, range.end.isFinite else { return nil }
        return EditTimeRange(start: min(range.start, range.end), end: max(range.start, range.end))
    }
}
