import CoreGraphics
import Foundation

// MARK: - Errors

public enum StudioProjectError: Error, Sendable, Equatable {
    /// `project.json` was written by a newer HakoShot (`formatVersion` > current).
    case unsupportedFormatVersion(Int)
}

// MARK: - Source

/// File names of the immutable recording inputs inside the package's
/// `media/` folder (plan §4.18). `nil` = not present.
public struct StudioMediaFiles: Sendable, Hashable {
    public static let defaultScreen = "screen.mov"
    public static let defaultCamera = "camera.mov"
    public static let defaultEvents = RecordingMetadata.fileName
    public static let defaultCursor = CursorTrackCodec.fileName
    public static let defaultCursorsDirectory = "cursors"

    /// Screen video (Studio: cursorless `screen.mov`; classic: the mp4). Required.
    public var screen: String
    public var camera: String?
    /// `events.json` (`RecordingMetadata`).
    public var events: String?
    /// `cursor.bin` (`CursorTrackCodec`).
    public var cursor: String?
    /// Folder of cursor shape PNGs (`<hash>.png`).
    public var cursorsDirectory: String?

    public init(
        screen: String = Self.defaultScreen,
        camera: String? = nil,
        events: String? = Self.defaultEvents,
        cursor: String? = Self.defaultCursor,
        cursorsDirectory: String? = Self.defaultCursorsDirectory
    ) {
        self.screen = screen
        self.camera = camera
        self.events = events
        self.cursor = cursor
        self.cursorsDirectory = cursorsDirectory
    }

    /// Every referenced name, screen first.
    public var allNames: [String] {
        [screen] + [camera, events, cursor, cursorsDirectory].compactMap { $0 }
    }
}

/// What was recorded. Informational except for sizes / duration, which the
/// layout and timeline use. Immutable after the project is created.
public struct StudioSource: Sendable, Hashable {
    /// Encoded screen frame size.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Recording rect size in points (cursor / click coordinates use points).
    public var pointWidth: Double
    public var pointHeight: Double
    /// Nominal frame rate of the screen video.
    public var fps: Double
    /// Screen video duration, seconds (source time).
    public var duration: Double
    /// The cursor is part of the video pixels (classic recording opened in
    /// Studio): cursor settings are inert, zoom and background still work.
    public var cursorBakedIn: Bool
    /// Audio tracks in file order ("microphone", "system").
    public var audioTracks: [String]
    public var media: StudioMediaFiles

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        pointWidth: Double? = nil,
        pointHeight: Double? = nil,
        fps: Double = 60,
        duration: Double,
        cursorBakedIn: Bool = false,
        audioTracks: [String] = [],
        media: StudioMediaFiles = StudioMediaFiles()
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth ?? Double(pixelWidth)
        self.pointHeight = pointHeight ?? Double(pixelHeight)
        self.fps = fps
        self.duration = duration
        self.cursorBakedIn = cursorBakedIn
        self.audioTracks = audioTracks
        self.media = media
    }

    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    public var hasCamera: Bool { media.camera != nil }
    /// Source pixels per recording point.
    public var pixelsPerPoint: Double { pointWidth > 0 ? Double(pixelWidth) / pointWidth : 1 }
}

// MARK: - Edit

/// Trim and cuts in source seconds (plan §4.18: every stored time is source
/// media time; `EditTimeline` maps to output time).
public struct StudioEdit: Sendable, Hashable {
    public var trim: EditTimeRange?
    public var cuts: [EditTimeRange]

    public init(trim: EditTimeRange? = nil, cuts: [EditTimeRange] = []) {
        self.trim = trim
        self.cuts = cuts
    }

    public func timeline(sourceDuration: Double) -> EditTimeline {
        EditTimeline(sourceDuration: sourceDuration, trim: trim, cuts: cuts)
    }
}

// MARK: - Canvas

/// Output canvas: proportions, size, and the background card look.
///
/// Lengths (`background.padding`, `cornerRadius`, shadow) are **reference
/// points**: pixels on a `referenceHeight` (1080 px) tall canvas, scaled by
/// `lengthScale(canvasHeight:)` so a look is resolution independent.
/// `background.inset`, `autoBalance` and `aspectRatio` do not apply to
/// Studio (the canvas ratio is `aspectRatio` here); `alignment` places the
/// content inside the padded area.
public struct StudioCanvas: Sendable, Hashable {
    public static let referenceHeight = 1080.0
    /// Plan §4.19 output heights.
    public static let outputHeights = [720, 1080, 1440, 2160]
    public static let defaultOutputHeight = 1080
    /// Studio background default: catalog gradient, 64 pt padding, 12 pt
    /// corners, standard shadow, no auto-balance.
    public static let defaultBackground = BackgroundStyle(
        fill: .preset(GradientCatalog.defaultPresetID),
        padding: 64,
        inset: 0,
        autoBalance: false,
        alignment: .center,
        aspectRatio: .auto,
        cornerRadius: 12,
        shadow: .standard
    )

    /// `.freeform` = "Auto" (source ratio). Presets: `RecordingAspectRatio.studioPresets`.
    public var aspectRatio: RecordingAspectRatio
    /// Output height in pixels (even).
    public var outputHeight: Int
    public var background: BackgroundStyle

    public init(
        aspectRatio: RecordingAspectRatio = .freeform,
        outputHeight: Int = Self.defaultOutputHeight,
        background: BackgroundStyle = Self.defaultBackground
    ) {
        self.aspectRatio = aspectRatio
        self.outputHeight = outputHeight
        self.background = background
    }

    /// Space around the content, reference points.
    public var padding: Double {
        get { background.padding }
        set { background.padding = newValue }
    }

    /// Content corner radius, reference points.
    public var cornerRadius: Double {
        get { background.cornerRadius }
        set { background.cornerRadius = newValue }
    }

    public var shadow: BackgroundShadow {
        get { background.shadow }
        set { background.shadow = newValue }
    }

    /// Output pixels per reference point.
    public static func lengthScale(canvasHeight: Double) -> Double {
        canvasHeight > 0 && canvasHeight.isFinite ? canvasHeight / referenceHeight : 1
    }

    /// Output pixel size for a source of `sourceSize` (even dimensions).
    public func pixelSize(sourceSize: CGSize) -> CGSize {
        let size = aspectRatio.canvasPixelSize(outputHeight: outputHeight, sourceSize: sourceSize)
        return CGSize(width: size.width, height: size.height)
    }

    public func normalized() -> StudioCanvas {
        var copy = self
        copy.outputHeight = RecordingGeometry.evenFloor(Double(min(max(outputHeight, 144), 4320)))
        copy.background.padding = clampFinite(background.padding, 0, 400, fallback: 64)
        copy.background.cornerRadius = clampFinite(background.cornerRadius, 0, 200, fallback: 12)
        copy.background.shadow.opacity = clampFinite(background.shadow.opacity, 0, 1, fallback: 0.5)
        copy.background.shadow.radius = clampFinite(background.shadow.radius, 0, 200, fallback: 24)
        return copy
    }
}

// MARK: - Cursor

public enum StudioCursorStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// The recorded cursor shapes (`cursors/<hash>.png`).
    case system
    /// HakoShot's vector arrow (fallback when no shapes were recorded).
    case arrow
}

/// Cursor rendering (plan §4.20). Inert when `StudioSource.cursorBakedIn`.
public struct StudioCursorSettings: Sendable, Hashable {
    public static let scaleRange: ClosedRange<Double> = 0.5...3
    public static let defaultScale = 1.5
    public static let defaultSmoothing = 0.6
    public static let defaultIdleDelay = 2.0

    public var visible: Bool
    /// Size multiplier of the cursor sprite, `0.5…3`.
    public var scale: Double
    /// `0…1` → time constant 0…120 ms (`CursorSmoothing`).
    public var smoothing: Double
    public var style: StudioCursorStyle
    /// Fade the cursor out after `idleDelay` seconds without movement.
    public var hideWhenIdle: Bool
    public var idleDelay: Double
    /// Click ring at each mouse-down.
    public var clickEffect: Bool

    public init(
        visible: Bool = true,
        scale: Double = Self.defaultScale,
        smoothing: Double = Self.defaultSmoothing,
        style: StudioCursorStyle = .system,
        hideWhenIdle: Bool = false,
        idleDelay: Double = Self.defaultIdleDelay,
        clickEffect: Bool = true
    ) {
        self.visible = visible
        self.scale = scale
        self.smoothing = smoothing
        self.style = style
        self.hideWhenIdle = hideWhenIdle
        self.idleDelay = idleDelay
        self.clickEffect = clickEffect
    }

    public func normalized() -> StudioCursorSettings {
        var copy = self
        copy.scale = clampFinite(scale, Self.scaleRange.lowerBound, Self.scaleRange.upperBound, fallback: Self.defaultScale)
        copy.smoothing = clampFinite(smoothing, 0, 1, fallback: Self.defaultSmoothing)
        copy.idleDelay = clampFinite(idleDelay, 0.25, 30, fallback: Self.defaultIdleDelay)
        return copy
    }
}

// MARK: - Zoom

/// Easing of a zoom transition (plan §4.20: `easeInOutCubic`).
public enum StudioEasing: String, Sendable, Hashable, Codable, CaseIterable {
    case linear
    case easeInOutCubic
    case easeOutCubic

    /// Maps `0…1` (clamped) to `0…1`.
    public func apply(_ t: Double) -> Double {
        let x = min(max(t.isFinite ? t : 0, 0), 1)
        switch self {
        case .linear:
            return x
        case .easeInOutCubic:
            return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .easeOutCubic:
            return 1 - pow(1 - x, 3)
        }
    }
}

/// Zoom transition speed (plan §4.20: slow / normal / fast).
public enum StudioZoomSpeed: String, Sendable, Hashable, Codable, CaseIterable {
    case slow, normal, fast

    /// Duration of the zoom in/out transition, seconds.
    public var transitionDuration: Double {
        switch self {
        case .slow: 0.8
        case .normal: 0.5
        case .fast: 0.3
        }
    }
}

/// Where a zoom segment looks.
public enum ZoomFocus: Sendable, Hashable {
    /// Follow the smoothed cursor (plan default).
    case followCursor
    /// A fixed point in unit source coordinates (`0…1`, y down).
    case fixed(x: Double, y: Double)
}

extension ZoomFocus: Codable {
    private enum CodingKeys: String, CodingKey { case mode, x, y }

    /// Unknown modes decode as `.followCursor`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "followCursor"
        if mode == "fixed" {
            self = .fixed(x: c.studioValue(.x, default: 0.5), y: c.studioValue(.y, default: 0.5))
        } else {
            self = .followCursor
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .followCursor:
            try c.encode("followCursor", forKey: .mode)
        case .fixed(let x, let y):
            try c.encode("fixed", forKey: .mode)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        }
    }
}

/// One zoomed interval in source seconds (R7 `ZoomPlanner` / zoom lane).
public struct ZoomSegment: Sendable, Hashable, Identifiable {
    public static let scaleRange: ClosedRange<Double> = 1...6

    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var focus: ZoomFocus
    public var easing: StudioEasing
    /// Made or edited by the user; auto re-planning keeps it.
    public var isManual: Bool

    public init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        scale: Double = 2,
        focus: ZoomFocus = .followCursor,
        easing: StudioEasing = .easeInOutCubic,
        isManual: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.scale = scale
        self.focus = focus
        self.easing = easing
        self.isManual = isManual
    }

    public var duration: Double { max(0, end - start) }
    public func contains(_ time: Double) -> Bool { time >= start && time < end }

    public func normalized() -> ZoomSegment {
        var copy = self
        let s = start.isFinite ? max(0, start) : 0
        let e = end.isFinite ? max(s, end) : s
        copy.start = s
        copy.end = e
        copy.scale = clampFinite(scale, Self.scaleRange.lowerBound, Self.scaleRange.upperBound, fallback: 2)
        if case .fixed(let x, let y) = focus {
            copy.focus = .fixed(x: clampFinite(x, 0, 1, fallback: 0.5), y: clampFinite(y, 0, 1, fallback: 0.5))
        }
        return copy
    }
}

public struct StudioZoomSettings: Sendable, Hashable {
    public static let defaultScale = 2.0

    /// Plan zoom segments from clicks (R7 `ZoomPlanner`).
    public var auto: Bool
    /// Scale for new / auto segments.
    public var defaultScale: Double
    public var speed: StudioZoomSpeed
    /// Sorted by `start`.
    public var segments: [ZoomSegment]

    public init(
        auto: Bool = true,
        defaultScale: Double = Self.defaultScale,
        speed: StudioZoomSpeed = .normal,
        segments: [ZoomSegment] = []
    ) {
        self.auto = auto
        self.defaultScale = defaultScale
        self.speed = speed
        self.segments = segments
    }

    public func normalized() -> StudioZoomSettings {
        var copy = self
        copy.defaultScale = clampFinite(defaultScale, ZoomSegment.scaleRange.lowerBound,
                                        ZoomSegment.scaleRange.upperBound, fallback: Self.defaultScale)
        copy.segments = segments.map { $0.normalized() }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return copy
    }
}

// MARK: - Motion blur

public struct StudioMotionBlur: Sendable, Hashable {
    public var enabled: Bool
    /// `0…1`.
    public var intensity: Double

    public init(enabled: Bool = true, intensity: Double = 0.5) {
        self.enabled = enabled
        self.intensity = intensity
    }

    public func normalized() -> StudioMotionBlur {
        StudioMotionBlur(enabled: enabled, intensity: clampFinite(intensity, 0, 1, fallback: 0.5))
    }
}

// MARK: - Camera

/// Same raw values as the app's `CameraShape`.
public enum StudioCameraShape: String, Sendable, Hashable, Codable, CaseIterable {
    case squircle, circle
    /// 16:9.
    case rectangle
    /// 9:16.
    case vertical

    /// width / height.
    public var aspect: Double {
        switch self {
        case .squircle, .circle: 1
        case .rectangle: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        }
    }
}

/// Same raw values as the app's `CameraCorner`.
public enum StudioCameraCorner: String, Sendable, Hashable, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Webcam overlay (plan §4.18). Only drawn when the source has a camera.
public struct StudioCameraSettings: Sendable, Hashable {
    public static let sizeRange: ClosedRange<Double> = 0.05...0.6
    public static let defaultSize = 0.18

    public var visible: Bool
    public var shape: StudioCameraShape
    /// Shorter side of the bubble as a fraction of the canvas's shorter side.
    public var size: Double
    public var corner: StudioCameraCorner
    public var mirrored: Bool
    /// Soft drop shadow under the bubble (the live bubble's look).
    public var shadow: Bool
    /// 2 pt white outline around the bubble.
    public var border: Bool

    public init(
        visible: Bool = true,
        shape: StudioCameraShape = .squircle,
        size: Double = Self.defaultSize,
        corner: StudioCameraCorner = .bottomRight,
        mirrored: Bool = false,
        shadow: Bool = true,
        border: Bool = false
    ) {
        self.visible = visible
        self.shape = shape
        self.size = size
        self.corner = corner
        self.mirrored = mirrored
        self.shadow = shadow
        self.border = border
    }

    public func normalized() -> StudioCameraSettings {
        var copy = self
        copy.size = clampFinite(size, Self.sizeRange.lowerBound, Self.sizeRange.upperBound, fallback: Self.defaultSize)
        return copy
    }
}

// MARK: - Keystrokes

/// Keystroke badges in the Studio render (R7). Same raw values as the app's
/// keystroke enums.
public struct StudioKeystrokeSettings: Sendable, Hashable {
    public var visible: Bool
    /// "dark" / "light".
    public var style: String
    /// "bottomCenter", "bottomLeft", "bottomRight", "topCenter".
    public var position: String
    /// "small" / "medium" / "large".
    public var size: String
    /// "shortcutsOnly" / "allKeys" (`KeystrokeDisplayFilter`). Only keys
    /// that passed the recording's filter exist, so `allKeys` shows every
    /// recorded key.
    public var filter: String

    public init(visible: Bool = false, style: String = "dark", position: String = "bottomCenter", size: String = "medium",
                filter: String = KeystrokeDisplayFilter.allKeys.rawValue) {
        self.visible = visible
        self.style = style
        self.position = position
        self.size = size
        self.filter = filter
    }

    // Typed views (unknown strings fall back to the defaults).

    public var placement: KeystrokeBadgePlacement {
        get { KeystrokeBadgePlacement(rawValue: position) ?? .bottomCenter }
        set { position = newValue.rawValue }
    }

    public var badgeSize: RecordingOverlaySize {
        get { RecordingOverlaySize(rawValue: size) ?? .medium }
        set { size = newValue.rawValue }
    }

    public var displayFilter: KeystrokeDisplayFilter {
        get { KeystrokeDisplayFilter(rawValue: filter) ?? .allKeys }
        set { filter = newValue.rawValue }
    }

    /// Light pill with dark glyphs (`style == "light"`); else dark.
    public var isLight: Bool {
        get { style == "light" }
        set { style = newValue ? "light" : "dark" }
    }
}

// MARK: - Export

public struct StudioExportSettings: Sendable, Hashable {
    public var format: VideoEditOutputFormat
    /// Output frame rate (video); capped by the source rate at export.
    public var fps: Int
    public var quality: VideoQuality
    public var codec: VideoCodec
    /// Used when `format == .gif`.
    public var gif: GIFExportOptions

    public init(
        format: VideoEditOutputFormat = .mp4,
        fps: Int = RecordingFrameRates.defaultVideo,
        quality: VideoQuality = .default,
        codec: VideoCodec = .h264,
        gif: GIFExportOptions = .default
    ) {
        self.format = format
        self.fps = fps
        self.quality = quality
        self.codec = codec
        self.gif = gif
    }

    /// Frame rate to render: `fps` capped by the source (never below 1).
    public func outputFPS(sourceFPS: Double) -> Int {
        let wanted = max(1, min(fps, VideoEditRecipe.maxFPS))
        guard sourceFPS > 0, sourceFPS.isFinite else { return wanted }
        return max(1, min(wanted, Int(sourceFPS.rounded())))
    }

    public func normalized() -> StudioExportSettings {
        var copy = self
        copy.fps = max(1, min(fps, VideoEditRecipe.maxFPS))
        copy.gif = gif.normalized()
        return copy
    }
}

// MARK: - Defaults

/// Defaults for new projects: plan §5 plus the app's Studio settings
/// (`studioAutoZoom`, `studioDefaultZoom`, `studioCursorSmoothing`,
/// `studioMotionBlur`, `studioMotionBlurIntensity`, `studioDefaultBackground`).
public struct StudioProjectDefaults: Sendable, Hashable {
    public var autoZoom: Bool
    public var defaultZoom: Double
    public var cursorSmoothing: Double
    public var motionBlur: Bool
    public var motionBlurIntensity: Double
    public var background: BackgroundStyle
    public var aspectRatio: RecordingAspectRatio
    public var outputHeight: Int

    public init(
        autoZoom: Bool = true,
        defaultZoom: Double = StudioZoomSettings.defaultScale,
        cursorSmoothing: Double = StudioCursorSettings.defaultSmoothing,
        motionBlur: Bool = true,
        motionBlurIntensity: Double = 0.5,
        background: BackgroundStyle = StudioCanvas.defaultBackground,
        aspectRatio: RecordingAspectRatio = .freeform,
        outputHeight: Int = StudioCanvas.defaultOutputHeight
    ) {
        self.autoZoom = autoZoom
        self.defaultZoom = defaultZoom
        self.cursorSmoothing = cursorSmoothing
        self.motionBlur = motionBlur
        self.motionBlurIntensity = motionBlurIntensity
        self.background = background
        self.aspectRatio = aspectRatio
        self.outputHeight = outputHeight
    }

    public static let standard = StudioProjectDefaults()
}

// MARK: - Project

/// `project.json` of a `.hakostudio` package (plan §4.18): every Studio edit
/// over the immutable recording in `media/`. Holds no pixels, so undo
/// snapshots are cheap.
///
/// Decoding: `formatVersion` and `source` are required; every other section
/// and field falls back to its default when missing or unreadable, and
/// unknown keys are ignored. A newer `formatVersion` is rejected (older ones
/// go through `StudioMigration` first).
public struct StudioProject: Sendable, Hashable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var createdAt: Date
    public var source: StudioSource
    public var edit: StudioEdit
    public var canvas: StudioCanvas
    public var cursor: StudioCursorSettings
    public var zoom: StudioZoomSettings
    public var motionBlur: StudioMotionBlur
    public var camera: StudioCameraSettings
    public var keystrokes: StudioKeystrokeSettings
    /// Mute, master volume, mono, per-track gains (file track order).
    public var audio: VideoEditAudio
    public var export: StudioExportSettings

    public init(
        source: StudioSource,
        createdAt: Date = Date(),
        edit: StudioEdit = StudioEdit(),
        canvas: StudioCanvas = StudioCanvas(),
        cursor: StudioCursorSettings = StudioCursorSettings(),
        zoom: StudioZoomSettings = StudioZoomSettings(),
        motionBlur: StudioMotionBlur = StudioMotionBlur(),
        camera: StudioCameraSettings = StudioCameraSettings(),
        keystrokes: StudioKeystrokeSettings = StudioKeystrokeSettings(),
        audio: VideoEditAudio = VideoEditAudio(),
        export: StudioExportSettings = StudioExportSettings()
    ) {
        self.formatVersion = Self.currentFormatVersion
        // Whole seconds: `project.json` stores ISO-8601 without fractions,
        // so a fresh project equals its round trip.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.source = source
        self.edit = edit
        self.canvas = canvas
        self.cursor = cursor
        self.zoom = zoom
        self.motionBlur = motionBlur
        self.camera = camera
        self.keystrokes = keystrokes
        self.audio = audio
        self.export = export
    }

    /// A new project with `defaults` applied.
    public init(source: StudioSource, defaults: StudioProjectDefaults, createdAt: Date = Date()) {
        self.init(
            source: source,
            createdAt: createdAt,
            canvas: StudioCanvas(aspectRatio: defaults.aspectRatio, outputHeight: defaults.outputHeight,
                                 background: defaults.background),
            cursor: StudioCursorSettings(smoothing: defaults.cursorSmoothing),
            zoom: StudioZoomSettings(auto: defaults.autoZoom, defaultScale: defaults.defaultZoom),
            motionBlur: StudioMotionBlur(enabled: defaults.motionBlur, intensity: defaults.motionBlurIntensity)
        )
        self = normalized()
    }

    /// Cursor size / smoothing / idle hiding apply (Studio-mode recordings only).
    public var supportsCursorEditing: Bool { !source.cursorBakedIn }

    public var timeline: EditTimeline { edit.timeline(sourceDuration: source.duration) }

    /// Canvas pixel size.
    public var canvasPixelSize: CGSize { canvas.pixelSize(sourceSize: source.pixelSize) }

    /// Every asset referenced (custom background image).
    public var referencedAssets: Set<AssetID> {
        if case .image(let id) = canvas.background.fill { return [id] }
        return []
    }

    /// Clamps every value into its valid range.
    public func normalized() -> StudioProject {
        var copy = self
        copy.canvas = canvas.normalized()
        copy.cursor = cursor.normalized()
        copy.zoom = zoom.normalized()
        copy.motionBlur = motionBlur.normalized()
        copy.camera = camera.normalized()
        copy.audio = audio.normalized()
        copy.export = export.normalized()
        return copy
    }

    // MARK: JSON

    /// ISO-8601 dates, pretty, sorted keys (same as `project.json` of `.hakoshot`).
    public static func makeEncoder() -> JSONEncoder { ProjectDocument.makeEncoder() }
    public static func makeDecoder() -> JSONDecoder { ProjectDocument.makeDecoder() }

    public func jsonData() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public init(jsonData: Data) throws {
        self = try Self.makeDecoder().decode(StudioProject.self, from: jsonData)
    }
}

// MARK: - Codable

extension KeyedDecodingContainer {
    /// Lenient read: missing, `null` or ill-typed values give `fallback`.
    func studioValue<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// Lenient optional read.
    func studioOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension StudioProject: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, createdAt, source, edit, canvas, cursor, zoom, motionBlur, camera, keystrokes, audio, export
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Self.currentFormatVersion else {
            throw StudioProjectError.unsupportedFormatVersion(version)
        }
        formatVersion = version
        createdAt = c.studioValue(.createdAt, default: Date(timeIntervalSince1970: 0))
        source = try c.decode(StudioSource.self, forKey: .source)
        edit = c.studioValue(.edit, default: StudioEdit())
        canvas = c.studioValue(.canvas, default: StudioCanvas())
        cursor = c.studioValue(.cursor, default: StudioCursorSettings())
        zoom = c.studioValue(.zoom, default: StudioZoomSettings())
        motionBlur = c.studioValue(.motionBlur, default: StudioMotionBlur())
        camera = c.studioValue(.camera, default: StudioCameraSettings())
        keystrokes = c.studioValue(.keystrokes, default: StudioKeystrokeSettings())
        audio = c.studioValue(.audio, default: VideoEditAudio())
        export = c.studioValue(.export, default: StudioExportSettings())
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(source, forKey: .source)
        try c.encode(edit, forKey: .edit)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(motionBlur, forKey: .motionBlur)
        try c.encode(camera, forKey: .camera)
        try c.encode(keystrokes, forKey: .keystrokes)
        try c.encode(audio, forKey: .audio)
        try c.encode(export, forKey: .export)
    }
}

extension StudioMediaFiles: Codable {
    private enum CodingKeys: String, CodingKey { case screen, camera, events, cursor, cursorsDirectory }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = c.studioValue(.screen, default: Self.defaultScreen)
        camera = c.studioOptional(.camera)
        events = c.studioOptional(.events)
        cursor = c.studioOptional(.cursor)
        cursorsDirectory = c.studioOptional(.cursorsDirectory)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screen, forKey: .screen)
        try c.encodeIfPresent(camera, forKey: .camera)
        try c.encodeIfPresent(events, forKey: .events)
        try c.encodeIfPresent(cursor, forKey: .cursor)
        try c.encodeIfPresent(cursorsDirectory, forKey: .cursorsDirectory)
    }
}

extension StudioSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case pixelWidth, pixelHeight, pointWidth, pointHeight, fps, duration, cursorBakedIn, audioTracks, media
    }

    /// Pixel size and duration are required; the rest defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let width = try c.decode(Int.self, forKey: .pixelWidth)
        let height = try c.decode(Int.self, forKey: .pixelHeight)
        self.init(
            pixelWidth: width,
            pixelHeight: height,
            pointWidth: c.studioOptional(.pointWidth),
            pointHeight: c.studioOptional(.pointHeight),
            fps: c.studioValue(.fps, default: 60.0),
            duration: try c.decode(Double.self, forKey: .duration),
            cursorBakedIn: c.studioValue(.cursorBakedIn, default: false),
            audioTracks: c.studioValue(.audioTracks, default: []),
            media: c.studioValue(.media, default: StudioMediaFiles())
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try c.encode(pointWidth, forKey: .pointWidth)
        try c.encode(pointHeight, forKey: .pointHeight)
        try c.encode(fps, forKey: .fps)
        try c.encode(duration, forKey: .duration)
        try c.encode(cursorBakedIn, forKey: .cursorBakedIn)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encode(media, forKey: .media)
    }
}

extension StudioEdit: Codable {
    private enum CodingKeys: String, CodingKey { case trim, cuts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trim = c.studioOptional(.trim)
        cuts = c.studioValue(.cuts, default: [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(trim, forKey: .trim)
        try c.encode(cuts, forKey: .cuts)
    }
}

extension StudioCanvas: Codable {
    private enum CodingKeys: String, CodingKey { case aspectRatio, outputHeight, background }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio = c.studioValue(.aspectRatio, default: .freeform)
        outputHeight = c.studioValue(.outputHeight, default: Self.defaultOutputHeight)
        background = c.studioValue(.background, default: Self.defaultBackground)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(outputHeight, forKey: .outputHeight)
        try c.encode(background, forKey: .background)
    }
}

extension StudioCursorSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case visible, scale, smoothing, style, hideWhenIdle, idleDelay, clickEffect
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudioCursorSettings()
        visible = c.studioValue(.visible, default: d.visible)
        scale = c.studioValue(.scale, default: d.scale)
        smoothing = c.studioValue(.smoothing, default: d.smoothing)
        style = c.studioValue(.style, default: d.style)
        hideWhenIdle = c.studioValue(.hideWhenIdle, default: d.hideWhenIdle)
        idleDelay = c.studioValue(.idleDelay, default: d.idleDelay)
        clickEffect = c.studioValue(.clickEffect, default: d.clickEffect)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(visible, forKey: .visible)
        try c.encode(scale, forKey: .scale)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(style, forKey: .style)
        try c.encode(hideWhenIdle, forKey: .hideWhenIdle)
        try c.encode(idleDelay, forKey: .idleDelay)
        try c.encode(clickEffect, forKey: .clickEffect)
    }
}

extension ZoomSegment: Codable {
    private enum CodingKeys: String, CodingKey { case id, start, end, scale, focus, easing, isManual }

    /// `start` / `end` are required; a segment without them is dropped by
    /// `StudioZoomSettings`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.studioValue(.id, default: UUID())
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        scale = c.studioValue(.scale, default: StudioZoomSettings.defaultScale)
        focus = c.studioValue(.focus, default: .followCursor)
        easing = c.studioValue(.easing, default: .easeInOutCubic)
        isManual = c.studioValue(.isManual, default: false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(scale, forKey: .scale)
        try c.encode(focus, forKey: .focus)
        try c.encode(easing, forKey: .easing)
        try c.encode(isManual, forKey: .isManual)
    }
}

/// Decodes an array element by element, skipping unreadable ones.
private struct LenientElement<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension StudioZoomSettings: Codable {
    private enum CodingKeys: String, CodingKey { case auto, defaultScale, speed, segments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auto = c.studioValue(.auto, default: true)
        defaultScale = c.studioValue(.defaultScale, default: Self.defaultScale)
        speed = c.studioValue(.speed, default: .normal)
        let raw: [LenientElement<ZoomSegment>] = c.studioValue(.segments, default: [])
        segments = raw.compactMap(\.value)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(auto, forKey: .auto)
        try c.encode(defaultScale, forKey: .defaultScale)
        try c.encode(speed, forKey: .speed)
        try c.encode(segments, forKey: .segments)
    }
}

extension StudioMotionBlur: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, intensity }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.studioValue(.enabled, default: true)
        intensity = c.studioValue(.intensity, default: 0.5)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(intensity, forKey: .intensity)
    }
}

extension StudioCameraSettings: Codable {
    private enum CodingKeys: String, CodingKey { case visible, shape, size, corner, mirrored, shadow, border }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudioCameraSettings()
        visible = c.studioValue(.visible, default: d.visible)
        shape = c.studioValue(.shape, default: d.shape)
        size = c.studioValue(.size, default: d.size)
        corner = c.studioValue(.corner, default: d.corner)
        mirrored = c.studioValue(.mirrored, default: d.mirrored)
        shadow = c.studioValue(.shadow, default: d.shadow)
        border = c.studioValue(.border, default: d.border)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(visible, forKey: .visible)
        try c.encode(shape, forKey: .shape)
        try c.encode(size, forKey: .size)
        try c.encode(corner, forKey: .corner)
        try c.encode(mirrored, forKey: .mirrored)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(border, forKey: .border)
    }
}

extension StudioKeystrokeSettings: Codable {
    private enum CodingKeys: String, CodingKey { case visible, style, position, size, filter }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudioKeystrokeSettings()
        visible = c.studioValue(.visible, default: d.visible)
        style = c.studioValue(.style, default: d.style)
        position = c.studioValue(.position, default: d.position)
        size = c.studioValue(.size, default: d.size)
        filter = c.studioValue(.filter, default: d.filter)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(visible, forKey: .visible)
        try c.encode(style, forKey: .style)
        try c.encode(position, forKey: .position)
        try c.encode(size, forKey: .size)
        try c.encode(filter, forKey: .filter)
    }
}

extension StudioExportSettings: Codable {
    private enum CodingKeys: String, CodingKey { case format, fps, quality, codec, gif }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StudioExportSettings()
        format = c.studioValue(.format, default: d.format)
        fps = c.studioValue(.fps, default: d.fps)
        quality = c.studioValue(.quality, default: d.quality)
        codec = c.studioValue(.codec, default: d.codec)
        gif = c.studioValue(.gif, default: d.gif)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(fps, forKey: .fps)
        try c.encode(quality, forKey: .quality)
        try c.encode(codec, forKey: .codec)
        try c.encode(gif, forKey: .gif)
    }
}

// MARK: - Helpers

func clampFinite(_ value: Double, _ low: Double, _ high: Double, fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, low), high)
}
