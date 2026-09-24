import CoreGraphics
import CoreMedia
import Foundation
import HakoKit

// Screen-recording contracts (plan `kayit-teknik-plan.md` §2.2, §2.3).
//
// CONTRACT FILE (hotspot, plan §7.0): written by the orchestrator before the
// parallel recording packages start. It holds only data types and protocols;
// the actors and controllers (`RecordingEngine`, `RecordingCoordinator`,
// `RecordingOutputRouter`, …) are created by their owning packages. Owning
// packages must NOT change this file without the orchestrator; ask for changes
// in the package report ("Entegrasyon parçası").
//
// Coordinates (plan §2.2): global = Quartz points (`GlobalRect`, top-left
// origin); inside a video = output pixels, top-left origin; cursor / click
// positions in metadata = points relative to the recorded rect.

// MARK: - Target

/// What the user asked to record, before a concrete target is chosen
/// (`AppCommand.record`, URL `record-screen?mode=`).
nonisolated enum RecordingTargetKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// Area selection (overlay `.recording`) or a URL rect.
    case area
    /// Window pick (overlay window mode).
    case window
    /// The whole display under the cursor (or `display=` from the URL).
    case fullscreen
    /// Fullscreen, but ask which display first when there are several.
    case pickDisplay
}

/// The concrete thing being recorded (plan §4.1). One display per session.
nonisolated enum RecordingTarget: Sendable, Equatable, Hashable {
    /// `rect` in Quartz global points, fully inside `displayID`.
    case area(GlobalRect, displayID: CGDirectDisplayID)
    /// Followed while it moves (`WindowFollower`); output size fixed at start.
    case window(CGWindowID)
    case display(CGDirectDisplayID)

    var kind: RecordingTargetKind {
        switch self {
        case .area: .area
        case .window: .window
        case .display: .fullscreen
        }
    }
}

// MARK: - Profile and format

/// How the session captures (plan §4.9, §4.10).
nonisolated enum RecordingProfile: String, Sendable, Equatable, CaseIterable, Codable {
    /// Overlays (clicks, keys, webcam) recorded live; cursor from SCK per "Show cursor".
    case classic
    /// Cursor hidden, Ultra quality, everything else as metadata; opens in Studio.
    case studio
}

/// The file the user gets from a classic recording. A GIF is always recorded
/// as video first, then converted (plan §4.14, §4.17).
nonisolated enum RecordingFormat: String, Sendable, Equatable, CaseIterable, Codable {
    case video
    case gif

    /// Extension of the delivered file.
    var pathExtension: String {
        switch self {
        case .video: "mp4"
        case .gif: "gif"
        }
    }
}

/// Where frames come from. `synthetic` is DEBUG only (`SyntheticFrameSource`,
/// URL `source=synthetic`): moving test pattern + 440/880 Hz tones, works with
/// the screen locked and without permission.
nonisolated enum RecordingSourceKind: String, Sendable, Equatable, CaseIterable {
    case screen
    case synthetic
}

// MARK: - Options

/// Microphone selection. `nil` in `RecordingOptions.microphone` = mic off.
nonisolated enum MicrophoneChoice: Sendable, Equatable, Hashable {
    case systemDefault
    /// `AVCaptureDevice.uniqueID`.
    case device(uniqueID: String)
}

/// Webcam bubble options (plan §4.8). `nil` in `RecordingOptions.camera` = camera off.
nonisolated struct CameraOptions: Sendable, Equatable, Hashable {
    /// `AVCaptureDevice.uniqueID`; `nil` = system default camera.
    var deviceID: String?
    var shape: CameraShape
    var size: RecordingElementSize
    var corner: CameraCorner
    var mirrored: Bool

    init(
        deviceID: String? = nil,
        shape: CameraShape = .squircle,
        size: RecordingElementSize = .medium,
        corner: CameraCorner = .bottomRight,
        mirrored: Bool = false
    ) {
        self.deviceID = deviceID
        self.shape = shape
        self.size = size
        self.corner = corner
        self.mirrored = mirrored
    }
}

/// Everything that shapes one recording, snapshotted when it starts (plan
/// §2.2). Defaults equal the plan §5 defaults; `init(settings:)` in
/// `RecordingSettings.swift` reads the user's settings.
nonisolated struct RecordingOptions: Sendable, Equatable, Hashable {
    /// Frames per second (`RecordingSettingChoices.frameRates`).
    var fps: Int
    var quality: RecordingQuality
    var codec: RecordingCodec
    var maxResolution: RecordingMaxResolution
    /// "Scale Retina videos to 1x": output at point size.
    var scaleTo1x: Bool
    /// Classic only; Studio always records without the cursor.
    var showsCursor: Bool
    var highlightsClicks: Bool
    /// Also decides whether key events are stored in metadata (privacy, plan §4.10).
    var showsKeystrokes: Bool
    /// `nil` = microphone off.
    var microphone: MicrophoneChoice?
    var capturesSystemAudio: Bool
    /// `nil` = camera off.
    var camera: CameraOptions?
    var hideDesktopIcons: Bool
    var doNotDisturb: Bool
    /// 0 = no countdown.
    var countdownSeconds: Int
    /// Ignored for fullscreen targets (plan §4.4).
    var dimScreen: Bool
    var showControls: Bool
    /// Finalize: downmix to mono (plan §4.7).
    var monoAudio: Bool
    /// Finalize: one mixed AAC track or separate microphone / system tracks.
    var audioTrackLayout: RecordingAudioTrackLayout

    init(
        fps: Int = 60,
        quality: RecordingQuality = .high,
        codec: RecordingCodec = .h264,
        maxResolution: RecordingMaxResolution = .original,
        scaleTo1x: Bool = false,
        showsCursor: Bool = true,
        highlightsClicks: Bool = true,
        showsKeystrokes: Bool = false,
        microphone: MicrophoneChoice? = nil,
        capturesSystemAudio: Bool = false,
        camera: CameraOptions? = nil,
        hideDesktopIcons: Bool = false,
        doNotDisturb: Bool = false,
        countdownSeconds: Int = 0,
        dimScreen: Bool = true,
        showControls: Bool = true,
        monoAudio: Bool = false,
        audioTrackLayout: RecordingAudioTrackLayout = .single
    ) {
        self.fps = fps
        self.quality = quality
        self.codec = codec
        self.maxResolution = maxResolution
        self.scaleTo1x = scaleTo1x
        self.showsCursor = showsCursor
        self.highlightsClicks = highlightsClicks
        self.showsKeystrokes = showsKeystrokes
        self.microphone = microphone
        self.capturesSystemAudio = capturesSystemAudio
        self.camera = camera
        self.hideDesktopIcons = hideDesktopIcons
        self.doNotDisturb = doNotDisturb
        self.countdownSeconds = countdownSeconds
        self.dimScreen = dimScreen
        self.showControls = showControls
        self.monoAudio = monoAudio
        self.audioTrackLayout = audioTrackLayout
    }

    /// Plan §5 defaults.
    static let `default` = RecordingOptions()
}

/// One recording to run: the coordinator builds it after selection + HUD and
/// hands it to `RecordingEngine.start(_:overlayWindowIDs:)`.
nonisolated struct RecordingRequest: Sendable, Equatable {
    var target: RecordingTarget
    var options: RecordingOptions
    var format: RecordingFormat
    var profile: RecordingProfile
    /// Overrides the after-recording settings (`save`, `copy`; URL `action=`).
    var action: PostCaptureAction?
    /// Stop automatically after this many media seconds. Honored in DEBUG only (URL `duration=`).
    var autoStopAfter: Double?
    /// Frame source. `.synthetic` is honored in DEBUG only (URL `source=`).
    var source: RecordingSourceKind
    /// Write the finished file here and skip the output router. DEBUG only (URL `out=`).
    var outputURL: URL?

    init(
        target: RecordingTarget,
        options: RecordingOptions = .default,
        format: RecordingFormat = .video,
        profile: RecordingProfile = .classic,
        action: PostCaptureAction? = nil,
        autoStopAfter: Double? = nil,
        source: RecordingSourceKind = .screen,
        outputURL: URL? = nil
    ) {
        self.target = target
        self.options = options
        self.format = format
        self.profile = profile
        self.action = action
        self.autoStopAfter = autoStopAfter
        self.source = source
        self.outputURL = outputURL
    }
}

// MARK: - Engine output

/// One audio track in the raw recording. Order in files: microphone, system (plan §4.7).
nonisolated enum AudioTrackKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case microphone
    case system
}

/// Returned by `RecordingEngine.start`: the running session's identity and geometry.
nonisolated struct RecordingHandle: Sendable, Equatable, Hashable {
    /// Also the session folder name.
    var id: UUID
    /// `~/Library/Application Support/HakoShot/Recordings/<id>/`.
    var sessionFolder: URL
    var target: RecordingTarget
    var profile: RecordingProfile
    /// Recorded rect in Quartz global points (window: frame at start).
    var sourceRect: GlobalRect
    var displayID: CGDirectDisplayID
    /// Video size in pixels (even numbers, after max resolution / 1x).
    var pixelSize: CGSize
    /// Recorded rect size in points.
    var pointSize: CGSize
    /// Display backing scale (2 on Retina), before 1x scaling.
    var scale: CGFloat
    var startDate: Date
}

/// Live numbers for the control bar, menu bar timer and logs (`RecordingEngine.stats`).
nonisolated struct RecordingStats: Sendable, Equatable {
    /// Media seconds written so far (pauses excluded).
    var duration: Double
    var framesWritten: Int
    var droppedFrames: Int
    /// Bytes of the raw files written so far.
    var fileSize: Int64
    /// Microphone peak level, 0…1 linear; `nil` when the mic is off.
    var microphoneLevel: Float?
    /// System audio peak level, 0…1 linear; `nil` when system audio is off.
    var systemAudioLevel: Float?
    var isPaused: Bool
    /// The microphone is on but has been silent (≤ −60 dBFS) for 3 s (plan
    /// §1.4: the control bar warns; `RecordingEngine.isMicrophoneSilent`).
    var microphoneSilent: Bool

    init(
        duration: Double = 0,
        framesWritten: Int = 0,
        droppedFrames: Int = 0,
        fileSize: Int64 = 0,
        microphoneLevel: Float? = nil,
        systemAudioLevel: Float? = nil,
        isPaused: Bool = false,
        microphoneSilent: Bool = false
    ) {
        self.duration = duration
        self.framesWritten = framesWritten
        self.droppedFrames = droppedFrames
        self.fileSize = fileSize
        self.microphoneLevel = microphoneLevel
        self.systemAudioLevel = systemAudioLevel
        self.isPaused = isPaused
        self.microphoneSilent = microphoneSilent
    }

    static let zero = RecordingStats()
}

/// A stopped session's files, before finalize (plan §2.3). The session folder
/// is owned by the recording pipeline until finalize / Studio import moves or
/// deletes it.
nonisolated struct RawRecording: Sendable, Equatable {
    /// File names inside `sessionFolder` (also used by `.hakostudio` `media/`).
    nonisolated enum FileName {
        static let screen = "screen.mov"
        static let camera = "camera.mov"
        static let events = "events.json"
        static let cursor = "cursor.bin"
        /// Session state for crash recovery (plan §4.22).
        static let session = "session.json"
    }

    var id: UUID
    var sessionFolder: URL
    var screenURL: URL
    /// Studio profile with the camera on.
    var cameraURL: URL?
    /// HakoKit `RecordingMetadata` JSON.
    var eventsURL: URL?
    /// HakoKit `CursorTrackCodec` binary cursor track.
    var cursorURL: URL?
    var target: RecordingTarget
    var profile: RecordingProfile
    var format: RecordingFormat
    var pixelSize: CGSize
    var pointSize: CGSize
    var scale: CGFloat
    var fps: Int
    /// Media seconds (pauses excluded).
    var duration: Double
    var audioTracks: [AudioTrackKind]
    var startDate: Date

    init(
        id: UUID,
        sessionFolder: URL,
        screenURL: URL? = nil,
        cameraURL: URL? = nil,
        eventsURL: URL? = nil,
        cursorURL: URL? = nil,
        target: RecordingTarget,
        profile: RecordingProfile,
        format: RecordingFormat = .video,
        pixelSize: CGSize,
        pointSize: CGSize,
        scale: CGFloat,
        fps: Int,
        duration: Double,
        audioTracks: [AudioTrackKind] = [],
        startDate: Date
    ) {
        self.id = id
        self.sessionFolder = sessionFolder
        self.screenURL = screenURL ?? sessionFolder.appendingPathComponent(FileName.screen)
        self.cameraURL = cameraURL
        self.eventsURL = eventsURL
        self.cursorURL = cursorURL
        self.target = target
        self.profile = profile
        self.format = format
        self.pixelSize = pixelSize
        self.pointSize = pointSize
        self.scale = scale
        self.fps = fps
        self.duration = duration
        self.audioTracks = audioTracks
        self.startDate = startDate
    }
}

/// The finished file handed to `RecordingOutputRouter` (plan §2.2, §4.15).
nonisolated struct RecordingResult: Sendable {
    /// `.mp4` or `.gif` (history copy or temp file until saved).
    var fileURL: URL
    var format: RecordingFormat
    var duration: Double
    var pixelSize: CGSize
    var thumbnail: CGImage
    var date: Date
    var targetKind: RecordingTargetKind
    /// Set once the history entry is written.
    var historyID: UUID?
    /// Studio recordings: the `.hakostudio` package.
    var studioProjectURL: URL?
    /// Kept for "Open in Studio" / debugging; `nil` for converted files.
    var raw: RawRecording?

    init(
        fileURL: URL,
        format: RecordingFormat,
        duration: Double,
        pixelSize: CGSize,
        thumbnail: CGImage,
        date: Date = .now,
        targetKind: RecordingTargetKind,
        historyID: UUID? = nil,
        studioProjectURL: URL? = nil,
        raw: RawRecording? = nil
    ) {
        self.fileURL = fileURL
        self.format = format
        self.duration = duration
        self.pixelSize = pixelSize
        self.thumbnail = thumbnail
        self.date = date
        self.targetKind = targetKind
        self.historyID = historyID
        self.studioProjectURL = studioProjectURL
        self.raw = raw
    }
}

// MARK: - Frame source

/// What a frame source needs to start (built by `RecordingEngine` /
/// `ContentFilterBuilder` from a `RecordingRequest`).
nonisolated struct RecordingSourceConfiguration: Sendable, Equatable {
    var target: RecordingTarget
    /// Display the stream captures.
    var displayID: CGDirectDisplayID
    /// Captured rect in display-local points (`SCStreamConfiguration.sourceRect`); `nil` = whole display.
    var sourceRect: CGRect?
    /// Output buffer size in pixels (even).
    var pixelSize: CGSize
    var fps: Int
    var showsCursor: Bool
    var capturesSystemAudio: Bool
    var microphone: MicrophoneChoice?
    /// Our own windows that must appear in the video (overlays, webcam bubble, desktop covers).
    var exceptedWindowIDs: [CGWindowID]
    /// Leave notification banners out of the video (DND layer 1, plan §4.11).
    var excludesNotifications: Bool
    /// Deliver frames but let the engine decide when the writer session starts (countdown pre-roll, plan §4.3).
    var preRoll: Bool

    init(
        target: RecordingTarget,
        displayID: CGDirectDisplayID,
        sourceRect: CGRect? = nil,
        pixelSize: CGSize,
        fps: Int,
        showsCursor: Bool,
        capturesSystemAudio: Bool = false,
        microphone: MicrophoneChoice? = nil,
        exceptedWindowIDs: [CGWindowID] = [],
        excludesNotifications: Bool = false,
        preRoll: Bool = false
    ) {
        self.target = target
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
        self.fps = fps
        self.showsCursor = showsCursor
        self.capturesSystemAudio = capturesSystemAudio
        self.microphone = microphone
        self.exceptedWindowIDs = exceptedWindowIDs
        self.excludesNotifications = excludesNotifications
        self.preRoll = preRoll
    }
}

/// Output callbacks of a frame source. They run on the source's own serial
/// queues (`video`, `audio`), never on the main actor, and must not block.
nonisolated struct RecordingFrameSourceHandlers: Sendable {
    var onVideo: @Sendable (CMSampleBuffer) -> Void
    var onAudio: @Sendable (CMSampleBuffer, AudioTrackKind) -> Void
    /// Called once when the source stops by itself (`nil`) or fails (display
    /// disconnected, permission revoked). Not called after `stop()`.
    var onStop: @Sendable ((any Error)?) -> Void

    init(
        onVideo: @escaping @Sendable (CMSampleBuffer) -> Void,
        onAudio: @escaping @Sendable (CMSampleBuffer, AudioTrackKind) -> Void = { _, _ in },
        onStop: @escaping @Sendable ((any Error)?) -> Void = { _ in }
    ) {
        self.onVideo = onVideo
        self.onAudio = onAudio
        self.onStop = onStop
    }
}

/// Produces screen video + audio sample buffers for `RecordingEngine`.
/// Implementations: `ScreenStreamSource` (SCStream) and `SyntheticFrameSource`
/// (DEBUG: test pattern + tones). Video buffers are 420v, host-clock PTS.
nonisolated protocol RecordingFrameSource: AnyObject, Sendable {
    /// Starts capturing; returns once the first frame can arrive.
    func start(_ configuration: RecordingSourceConfiguration, handlers: RecordingFrameSourceHandlers) async throws
    /// Moves the captured rect (window follow, plan §4.1), display-local points.
    func updateSourceRect(_ rect: CGRect) async throws
    /// Stops capturing. Idempotent; no callbacks after it returns.
    func stop() async
}

extension RecordingFrameSource {
    nonisolated func updateSourceRect(_ rect: CGRect) async throws {}
}

// MARK: - Errors

/// A permission the recording flow may need (plan §1.8).
nonisolated enum RecordingPermission: String, Sendable, Equatable, CaseIterable {
    case screenRecording
    case microphone
    case camera
    case inputMonitoring
}

nonisolated enum RecordingError: Error, Sendable, Equatable {
    case permissionDenied(RecordingPermission)
    /// Only one session at a time (plan §2.2).
    case alreadyRecording
    case noActiveSession
    /// The requested state change is not valid now (e.g. pause while finalizing).
    case invalidState(String)
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    /// Empty or off-screen rect.
    case invalidTarget
    /// Free disk space below the limit (plan §4.5: 2 GB).
    case insufficientDiskSpace(availableBytes: Int64)
    /// SCStream / synthetic source failed to start or stopped with an error.
    case sourceFailed(String)
    /// AVAssetWriter failed.
    case writerFailed(String)
    /// mp4 remux / audio mix / GIF conversion failed.
    case finalizeFailed(String)
    /// Stopped before any frame was written.
    case noFrames
    /// Cancelled by the user (Esc during countdown, discard).
    case cancelled
}

extension RecordingError: nonisolated CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case let .permissionDenied(permission): "permission denied: \(permission.rawValue)"
        case .alreadyRecording: "already recording"
        case .noActiveSession: "no active recording session"
        case let .invalidState(detail): "invalid state: \(detail)"
        case let .displayNotFound(id): "display \(id) not found"
        case let .windowNotFound(id): "window \(id) not found"
        case .invalidTarget: "invalid recording target"
        case let .insufficientDiskSpace(bytes): "insufficient disk space (\(bytes) bytes free)"
        case let .sourceFailed(detail): "source failed: \(detail)"
        case let .writerFailed(detail): "writer failed: \(detail)"
        case let .finalizeFailed(detail): "finalize failed: \(detail)"
        case .noFrames: "no frames recorded"
        case .cancelled: "cancelled"
        }
    }
}

// MARK: - Command options

/// Parameters of `AppCommand.record` (menu, hotkeys, URL `record-screen`, plan §4.21).
nonisolated struct RecordingCommandOptions: Equatable, Sendable {
    /// Pre-selected rect in Quartz global points (URL `x, y, width, height`).
    var rect: CGRect?
    /// 1-based display number (1 = main; URL `display=`, CleanShot-compatible).
    var display: Int?
    /// `nil` = the HUD / format menu decides (Record Video by default).
    var format: RecordingFormat?
    /// Record in Studio mode (URL `studio=true`).
    var studio: Bool
    /// Skip the HUD and start right away (URL `start=true`).
    var start: Bool
    /// After-recording override (`save`, `copy`).
    var action: PostCaptureAction?

    // DEBUG-only parameters (plan §4.21); the URL parser fills them in DEBUG builds only.

    /// Stop after this many seconds (URL `duration=`).
    var autoStopAfter: Double?
    /// Countdown override in seconds; 0 = none (URL `countdown=`).
    var countdownSeconds: Int?
    /// Write the result here and skip the router (URL `out=`).
    var outputURL: URL?
    /// Frame source (URL `source=screen|synthetic`).
    var source: RecordingSourceKind?
    /// Window mode without the overlay (URL `window=frontmost|test|<id>`,
    /// `RecordingTargetDebug.WindowSelector`; R1.4).
    var window: String?
    /// Camera override (URL `camera=1|0|pattern`; R4.I). `pattern` shows
    /// `CameraTestPattern` in the bubble (and feeds it to `camera.mov` in
    /// Studio) without touching the camera or TCC.
    var camera: RecordingCameraOverride?
    /// "Highlight clicks" override (URL `clicks=1|0`; R5.I).
    var highlightsClicks: Bool?
    /// "Show keystrokes" override (URL `keys=1|0`; R5.I).
    var showsKeystrokes: Bool?

    init(
        rect: CGRect? = nil,
        display: Int? = nil,
        format: RecordingFormat? = nil,
        studio: Bool = false,
        start: Bool = false,
        action: PostCaptureAction? = nil,
        autoStopAfter: Double? = nil,
        countdownSeconds: Int? = nil,
        outputURL: URL? = nil,
        source: RecordingSourceKind? = nil,
        window: String? = nil,
        camera: RecordingCameraOverride? = nil,
        highlightsClicks: Bool? = nil,
        showsKeystrokes: Bool? = nil
    ) {
        self.rect = rect
        self.display = display
        self.format = format
        self.studio = studio
        self.start = start
        self.action = action
        self.autoStopAfter = autoStopAfter
        self.countdownSeconds = countdownSeconds
        self.outputURL = outputURL
        self.source = source
        self.window = window
        self.camera = camera
        self.highlightsClicks = highlightsClicks
        self.showsKeystrokes = showsKeystrokes
    }
}

/// DEBUG `record-screen` camera override (R4.I).
nonisolated enum RecordingCameraOverride: String, Sendable, Equatable {
    case off
    case on
    /// The bubble shows the test pattern; no camera, no TCC.
    case pattern
}

extension RecordingCommandOptions: nonisolated CustomStringConvertible {
    nonisolated var description: String {
        var parts: [String] = []
        if let rect { parts.append("rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))") }
        if let display { parts.append("display=\(display)") }
        if let format { parts.append("format=\(format.rawValue)") }
        if studio { parts.append("studio") }
        if start { parts.append("start") }
        if let action { parts.append("action=\(action.rawValue)") }
        if let autoStopAfter { parts.append("duration=\(autoStopAfter)") }
        if let countdownSeconds { parts.append("countdown=\(countdownSeconds)") }
        if let outputURL { parts.append("out=\(outputURL.path)") }
        if let source { parts.append("source=\(source.rawValue)") }
        if let window { parts.append("window=\(window)") }
        if let camera { parts.append("camera=\(camera.rawValue)") }
        if let highlightsClicks { parts.append("clicks=\(highlightsClicks)") }
        if let showsKeystrokes { parts.append("keys=\(showsKeystrokes)") }
        return parts.joined(separator: ", ")
    }
}
