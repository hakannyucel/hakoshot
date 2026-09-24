import Foundation
import HakoKit

// Screen-recording settings contract (plan `kayit-teknik-plan.md` §4.21, §5).
//
// CONTRACT FILE (hotspot, plan §7.0): written by the orchestrator before the
// parallel recording packages start. Every recording `SettingsKey` lives here
// so no package has to add keys to a shared file. Owning packages read these
// keys and enums but must NOT change names, raw values or defaults without the
// orchestrator; request changes in the package report ("Entegrasyon parçası").
//
// Enum raw values are what `UserDefaults` stores (via the `AppSettings`
// `RawRepresentable<String>` bridge), so they must never be renamed. Numeric
// choices (fps, GIF width, countdown) are plain `SettingsKey<Int>` with the
// allowed values listed next to them. Quality / resolution math lives in
// HakoKit (`VideoQuality`, `RecordingGeometry`, R0.1); the app-side enums here
// only name the user's choice and R0.1's types map from them.

// MARK: - Enums

/// Settings > Recording > Video "Quality" (plan §4.13). Maps to HakoKit
/// `VideoQuality` (bits-per-pixel: Low 0.02, Medium 0.035, High 0.05, Ultra 0.08).
nonisolated enum RecordingQuality: String, Sendable, Equatable, CaseIterable {
    case low, medium, high, ultra

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .ultra: "Ultra"
        }
    }
}

/// Settings > Recording > Video "Codec" (plan §4.13). H.264 by default.
nonisolated enum RecordingCodec: String, Sendable, Equatable, CaseIterable {
    case h264
    case hevc

    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// Settings > Recording > Video "Max resolution" (plan §4.13): a cap on the
/// output's **short edge**, aspect ratio kept. Maps to HakoKit `RecordingGeometry`.
nonisolated enum RecordingMaxResolution: String, Sendable, Equatable, CaseIterable {
    case original
    case p2160
    case p1440
    case p1080
    case p720

    /// Short-edge limit in pixels; `nil` = no limit (Original).
    var shortEdgePixels: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }

    var title: String {
        switch self {
        case .original: "Original"
        case .p2160: "4K (2160p)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
}

/// Settings > Recording > Audio "Audio tracks" (plan §4.7). Separate tracks are
/// ordered microphone, then system.
nonisolated enum RecordingAudioTrackLayout: String, Sendable, Equatable, CaseIterable {
    case single
    case separate

    var title: String {
        switch self {
        case .single: "Single track"
        case .separate: "Separate tracks"
        }
    }
}

/// Small / Medium / Large, shared by click highlight, keystroke badge and
/// webcam bubble sizes (plan §4.8, §4.9). Point values are in `Tokens.Recording`.
nonisolated enum RecordingElementSize: String, Sendable, Equatable, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Click highlight ring style (plan §4.9): outline (default) or filled.
nonisolated enum ClickHighlightStyle: String, Sendable, Equatable, CaseIterable {
    case outline
    case filled
}

/// Keystroke badge position (plan §4.9).
nonisolated enum KeystrokeBadgePosition: String, Sendable, Equatable, CaseIterable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    case topCenter
}

/// Keystroke badge style (plan §4.9): dark capsule (default) or light.
nonisolated enum KeystrokeBadgeStyle: String, Sendable, Equatable, CaseIterable {
    case dark
    case light
}

/// Which keys the badge shows (plan §4.9). `shortcutsOnly` = combos with ⌘, ⌃
/// or ⌥ plus lone special keys (Esc, Return, Tab, Delete, arrows, F-keys).
nonisolated enum KeystrokeFilter: String, Sendable, Equatable, CaseIterable {
    case shortcutsOnly
    case allKeys
}

/// Webcam bubble shape (plan §4.8).
nonisolated enum CameraShape: String, Sendable, Equatable, CaseIterable, Codable {
    case squircle
    /// Circle.
    case circle
    /// 16:9 rectangle.
    case rectangle
    /// 9:16 rectangle.
    case vertical
}

/// Corner the webcam bubble snaps to (plan §4.8; default bottom-right).
nonisolated enum CameraCorner: String, Sendable, Equatable, CaseIterable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - Allowed numeric values

/// Lists for the numeric pickers (plan §4.13, §4.17, §4.3).
nonisolated enum RecordingSettingChoices {
    /// Video frame rates, default 60.
    static let frameRates = [60, 50, 30, 25, 24, 15]
    /// Countdown lengths in seconds, default 3.
    static let countdownSeconds = [3, 5, 10]
    /// GIF frame rates, default 15.
    static let gifFrameRates = [5, 10, 15, 20, 24, 30]
    /// GIF output widths in pixels; `gifOriginalWidth` (0) = source width. Default 800.
    static let gifWidths = [400, 600, 800, 1000, 1200, gifOriginalWidth]
    static let gifOriginalWidth = 0
}

// MARK: - General (plan §4.21 "General", §4.1, §4.11)

extension SettingsKey where Value == Bool {
    /// "Show controls while recording": the bottom control bar. Default on (verified).
    static var recordingShowControls: SettingsKey<Bool> {
        SettingsKey("recordingShowControls", default: true)
    }

    /// "Remember last selection": the area overlay opens with `recordingLastRect`. Default on (verified).
    static var recordingRememberLastSelection: SettingsKey<Bool> {
        SettingsKey("recordingRememberLastSelection", default: true)
    }

    /// "Display recording time in menu bar": status item title `● 1:24`. Default off (verified).
    static var recordingShowTimeInMenuBar: SettingsKey<Bool> {
        SettingsKey("recordingShowTimeInMenuBar", default: false)
    }

    /// "Dim screen while recording": black 40 % outside the area. Default on (verified).
    static var recordingDimScreen: SettingsKey<Bool> {
        SettingsKey("recordingDimScreen", default: true)
    }

    /// "Show countdown" before recording starts. Default off (verified).
    static var recordingShowCountdown: SettingsKey<Bool> {
        SettingsKey("recordingShowCountdown", default: false)
    }

    /// "Do Not Disturb while recording" (plan §4.11: hide notification banners
    /// from the video + optional Focus shortcuts). Default off (verified).
    static var recordingDoNotDisturb: SettingsKey<Bool> {
        SettingsKey("recordingDoNotDisturb", default: false)
    }

    /// Set once the "Focus shortcuts not found" warning was shown (plan §4.11: warn once).
    static var recordingFocusShortcutWarningShown: SettingsKey<Bool> {
        SettingsKey("recordingFocusShortcutWarningShown", default: false)
    }

    /// "Hide desktop icons while recording" (plan §4.12). Separate from the
    /// screenshot setting. Default off.
    static var recordingHideDesktopIcons: SettingsKey<Bool> {
        SettingsKey("recordingHideDesktopIcons", default: false)
    }
}

extension SettingsKey where Value == Int {
    /// Countdown length in seconds (`RecordingSettingChoices.countdownSeconds`). Default 3.
    static var recordingCountdownSeconds: SettingsKey<Int> {
        SettingsKey("recordingCountdownSeconds", default: 3)
    }

    /// Video frame rate (`RecordingSettingChoices.frameRates`). Default 60 (verified).
    static var recordingFrameRate: SettingsKey<Int> {
        SettingsKey("recordingFrameRate", default: 60)
    }

    /// GIF frame rate (`RecordingSettingChoices.gifFrameRates`). Default 15 (verified).
    static var gifFrameRate: SettingsKey<Int> {
        SettingsKey("gifFrameRate", default: 15)
    }

    /// GIF output width in pixels, height auto; 0 = original
    /// (`RecordingSettingChoices.gifWidths`). Default 800 (verified).
    static var gifWidth: SettingsKey<Int> {
        SettingsKey("gifWidth", default: 800)
    }
}

extension SettingsKey where Value == String {
    /// Last recorded area, `"x,y,width,height"` in Quartz global points (same
    /// encoding as `capturePreviousAreaRect`); "" = none. Written when a
    /// recording starts, not on Esc (plan §4.1, §4.2).
    static var recordingLastRect: SettingsKey<String> {
        SettingsKey("recordingLastRect", default: "")
    }

    /// Shortcuts.app shortcut run when recording starts ("HakoShot Focus On",
    /// plan §4.11). "" = not set up (notification banners are still hidden).
    static var recordingFocusOnShortcut: SettingsKey<String> {
        SettingsKey("recordingFocusOnShortcut", default: "")
    }

    /// Shortcuts.app shortcut run when recording ends ("HakoShot Focus Off"). "" = not set up.
    static var recordingFocusOffShortcut: SettingsKey<String> {
        SettingsKey("recordingFocusOffShortcut", default: "")
    }
}

// MARK: - Cursor (plan §4.21 "Cursor", §4.9, §4.10)

extension SettingsKey where Value == Bool {
    /// "Show cursor" in classic recordings (Studio never bakes it in). Default on (verified).
    static var recordingShowCursor: SettingsKey<Bool> {
        SettingsKey("recordingShowCursor", default: true)
    }

    /// "Highlight clicks": live ring overlay. Default on (verified).
    static var recordingHighlightClicks: SettingsKey<Bool> {
        SettingsKey("recordingHighlightClicks", default: true)
    }

    /// Click highlight Options… "Animate". Default on.
    static var recordingClickAnimated: SettingsKey<Bool> {
        SettingsKey("recordingClickAnimated", default: true)
    }
}

extension SettingsKey where Value == String {
    /// Click highlight color, `#RRGGBB` sRGB. Default `#0A84FF` (observed blue).
    static var recordingClickColor: SettingsKey<String> {
        SettingsKey("recordingClickColor", default: "#0A84FF")
    }
}

extension SettingsKey where Value == RecordingElementSize {
    /// Click highlight Options… size. Default Medium.
    static var recordingClickSize: SettingsKey<RecordingElementSize> {
        SettingsKey("recordingClickSize", default: .medium)
    }

    /// Keystroke badge Options… size. Default Medium (44 pt).
    static var recordingKeystrokeSize: SettingsKey<RecordingElementSize> {
        SettingsKey("recordingKeystrokeSize", default: .medium)
    }

    /// Webcam bubble size: Small 140 / Medium 180 / Large 240 pt. Default Medium.
    static var recordingCameraSize: SettingsKey<RecordingElementSize> {
        SettingsKey("recordingCameraSize", default: .medium)
    }
}

extension SettingsKey where Value == ClickHighlightStyle {
    /// Click highlight Options… style. Default Outline (observed).
    static var recordingClickStyle: SettingsKey<ClickHighlightStyle> {
        SettingsKey("recordingClickStyle", default: .outline)
    }
}

// MARK: - Keystrokes (plan §4.21 "Keystrokes", §4.9)

extension SettingsKey where Value == Bool {
    /// "Show keystrokes": live badge + key events in metadata. Default off (verified).
    static var recordingShowKeystrokes: SettingsKey<Bool> {
        SettingsKey("recordingShowKeystrokes", default: false)
    }
}

extension SettingsKey where Value == KeystrokeBadgePosition {
    /// Keystroke badge position. Default bottom-center (observed).
    static var recordingKeystrokePosition: SettingsKey<KeystrokeBadgePosition> {
        SettingsKey("recordingKeystrokePosition", default: .bottomCenter)
    }
}

extension SettingsKey where Value == KeystrokeBadgeStyle {
    /// Keystroke badge style. Default Dark (observed).
    static var recordingKeystrokeStyle: SettingsKey<KeystrokeBadgeStyle> {
        SettingsKey("recordingKeystrokeStyle", default: .dark)
    }
}

extension SettingsKey where Value == KeystrokeFilter {
    /// Which keys are shown. Default "Shortcuts only".
    static var recordingKeystrokeFilter: SettingsKey<KeystrokeFilter> {
        SettingsKey("recordingKeystrokeFilter", default: .shortcutsOnly)
    }
}

// MARK: - Video (plan §4.21 "Video", §4.13)

extension SettingsKey where Value == RecordingMaxResolution {
    /// "Max resolution". Default Original (verified).
    static var recordingMaxResolution: SettingsKey<RecordingMaxResolution> {
        SettingsKey("recordingMaxResolution", default: .original)
    }
}

extension SettingsKey where Value == RecordingQuality {
    /// "Quality". Default High.
    static var recordingQuality: SettingsKey<RecordingQuality> {
        SettingsKey("recordingQuality", default: .high)
    }
}

extension SettingsKey where Value == RecordingCodec {
    /// "Codec". Default H.264 (MP4 H.264, verified).
    static var recordingCodec: SettingsKey<RecordingCodec> {
        SettingsKey("recordingCodec", default: .h264)
    }
}

extension SettingsKey where Value == Bool {
    /// "Scale Retina videos to 1x". Default off (verified).
    static var recordingScaleRetinaTo1x: SettingsKey<Bool> {
        SettingsKey("recordingScaleRetinaTo1x", default: false)
    }
}

// MARK: - Audio (plan §4.21 "Audio", §4.7)

extension SettingsKey where Value == Bool {
    /// Microphone on/off (HUD toggle, persists). Default off.
    static var recordingMicrophoneEnabled: SettingsKey<Bool> {
        SettingsKey("recordingMicrophoneEnabled", default: false)
    }

    /// "Record audio in mono". Default off (verified).
    static var recordingMonoAudio: SettingsKey<Bool> {
        SettingsKey("recordingMonoAudio", default: false)
    }

    /// "Record system audio" (HUD toggle, persists). Default off (verified).
    static var recordingSystemAudio: SettingsKey<Bool> {
        SettingsKey("recordingSystemAudio", default: false)
    }
}

extension SettingsKey where Value == String {
    /// Microphone `AVCaptureDevice.uniqueID`; "" = System default.
    static var recordingMicrophoneDeviceID: SettingsKey<String> {
        SettingsKey("recordingMicrophoneDeviceID", default: "")
    }
}

extension SettingsKey where Value == RecordingAudioTrackLayout {
    /// "Audio tracks". Default Single track (verified).
    static var recordingAudioTracks: SettingsKey<RecordingAudioTrackLayout> {
        SettingsKey("recordingAudioTracks", default: .single)
    }
}

// MARK: - Camera (plan §4.21 "Camera", §4.8)

extension SettingsKey where Value == Bool {
    /// Webcam bubble on/off (HUD toggle, persists). Default off.
    static var recordingCameraEnabled: SettingsKey<Bool> {
        SettingsKey("recordingCameraEnabled", default: false)
    }

    /// "Mirror" the webcam image. Default off.
    static var recordingCameraMirror: SettingsKey<Bool> {
        SettingsKey("recordingCameraMirror", default: false)
    }
}

extension SettingsKey where Value == String {
    /// Camera `AVCaptureDevice.uniqueID`; "" = system default camera.
    static var recordingCameraDeviceID: SettingsKey<String> {
        SettingsKey("recordingCameraDeviceID", default: "")
    }
}

extension SettingsKey where Value == CameraShape {
    /// Webcam bubble shape. Default Squircle (observed).
    static var recordingCameraShape: SettingsKey<CameraShape> {
        SettingsKey("recordingCameraShape", default: .squircle)
    }
}

extension SettingsKey where Value == CameraCorner {
    /// Corner the bubble was last snapped to. Default bottom-right (observed).
    static var recordingCameraCorner: SettingsKey<CameraCorner> {
        SettingsKey("recordingCameraCorner", default: .bottomRight)
    }
}

// MARK: - GIF (plan §4.21 "GIF", §4.17)

extension SettingsKey where Value == Bool {
    /// "Optimize GIFs" (merge repeated frames, palette optimization). Default on (verified).
    static var gifOptimize: SettingsKey<Bool> {
        SettingsKey("gifOptimize", default: true)
    }
}

extension SettingsKey where Value == Double {
    /// GIF "Quality" slider 0…1 (→ 64–256 colors, dithering 0–0.8). Default 0.8 (verified ~80 %).
    static var gifQuality: SettingsKey<Double> {
        SettingsKey("gifQuality", default: 0.8)
    }
}

// MARK: - Studio (plan §4.21 "Studio", §4.20)

extension SettingsKey where Value == Bool {
    /// "Auto zoom on clicks" for new Studio projects. Default on.
    static var studioAutoZoom: SettingsKey<Bool> {
        SettingsKey("studioAutoZoom", default: true)
    }

    /// "Motion blur" for new Studio projects. Default on.
    static var studioMotionBlur: SettingsKey<Bool> {
        SettingsKey("studioMotionBlur", default: true)
    }
}

extension SettingsKey where Value == Double {
    /// "Default zoom" scale for new zoom segments. Default 2×.
    static var studioDefaultZoom: SettingsKey<Double> {
        SettingsKey("studioDefaultZoom", default: 2.0)
    }

    /// "Cursor smoothing" 0…1 (→ 0–120 ms). Default 0.6.
    static var studioCursorSmoothing: SettingsKey<Double> {
        SettingsKey("studioCursorSmoothing", default: 0.6)
    }

    /// Motion blur intensity 0…1. Default 0.5.
    static var studioMotionBlurIntensity: SettingsKey<Double> {
        SettingsKey("studioMotionBlurIntensity", default: 0.5)
    }
}

extension SettingsKey where Value == String {
    /// "Default background" for new Studio projects: HakoKit `BackgroundStyle`
    /// JSON (same encoding as `editorBackgroundLastStyle`, see
    /// `WallpaperDefaults.style(from:)`); "" = `BackgroundStyle.standard`.
    static var studioDefaultBackground: SettingsKey<String> {
        SettingsKey("studioDefaultBackground", default: "")
    }
}

// MARK: - After recording (plan §4.15; General page, "Recording" column)

extension SettingsKey where Value == Bool {
    /// After recording: "Show Quick Access". Default on (verified).
    static var afterRecordingShowQuickAccess: SettingsKey<Bool> {
        SettingsKey("afterRecordingShowQuickAccess", default: true)
    }

    /// After recording: "Copy" (file URL to the pasteboard). Default off (verified).
    static var afterRecordingCopy: SettingsKey<Bool> {
        SettingsKey("afterRecordingCopy", default: false)
    }

    /// After recording: "Save" to the export folder. Default off (verified).
    static var afterRecordingSave: SettingsKey<Bool> {
        SettingsKey("afterRecordingSave", default: false)
    }

    /// After recording: "Open Video Editor". Default off (verified).
    static var afterRecordingOpenVideoEditor: SettingsKey<Bool> {
        SettingsKey("afterRecordingOpenVideoEditor", default: false)
    }
}

// MARK: - Snapshots

extension RecordingOptions {
    /// The user's current recording settings (HUD toggles included). Callers
    /// then apply per-recording overrides (profile, URL parameters).
    init(settings: AppSettings) {
        let microphoneID = settings.value(for: .recordingMicrophoneDeviceID)
        let cameraID = settings.value(for: .recordingCameraDeviceID)
        self.init(
            fps: settings.value(for: .recordingFrameRate),
            quality: settings.value(for: .recordingQuality),
            codec: settings.value(for: .recordingCodec),
            maxResolution: settings.value(for: .recordingMaxResolution),
            scaleTo1x: settings.value(for: .recordingScaleRetinaTo1x),
            showsCursor: settings.value(for: .recordingShowCursor),
            highlightsClicks: settings.value(for: .recordingHighlightClicks),
            showsKeystrokes: settings.value(for: .recordingShowKeystrokes),
            microphone: settings.value(for: .recordingMicrophoneEnabled)
                ? (microphoneID.isEmpty ? .systemDefault : .device(uniqueID: microphoneID))
                : nil,
            capturesSystemAudio: settings.value(for: .recordingSystemAudio),
            camera: settings.value(for: .recordingCameraEnabled)
                ? CameraOptions(
                    deviceID: cameraID.isEmpty ? nil : cameraID,
                    shape: settings.value(for: .recordingCameraShape),
                    size: settings.value(for: .recordingCameraSize),
                    corner: settings.value(for: .recordingCameraCorner),
                    mirrored: settings.value(for: .recordingCameraMirror)
                )
                : nil,
            hideDesktopIcons: settings.value(for: .recordingHideDesktopIcons),
            doNotDisturb: settings.value(for: .recordingDoNotDisturb),
            countdownSeconds: settings.value(for: .recordingShowCountdown)
                ? settings.value(for: .recordingCountdownSeconds)
                : 0,
            dimScreen: settings.value(for: .recordingDimScreen),
            showControls: settings.value(for: .recordingShowControls),
            monoAudio: settings.value(for: .recordingMonoAudio),
            audioTrackLayout: settings.value(for: .recordingAudioTracks)
        )
    }
}

/// Snapshot of the after-recording checkboxes (plan §4.15), read once per
/// routed recording. History is always written.
nonisolated struct AfterRecordingConfig: Sendable, Equatable {
    var showQuickAccess = true
    var copyToClipboard = false
    var saveToDisk = false
    var openVideoEditor = false

    static let `default` = AfterRecordingConfig()
}

extension AfterRecordingConfig {
    init(settings: AppSettings) {
        self.init(
            showQuickAccess: settings.value(for: .afterRecordingShowQuickAccess),
            copyToClipboard: settings.value(for: .afterRecordingCopy),
            saveToDisk: settings.value(for: .afterRecordingSave),
            openVideoEditor: settings.value(for: .afterRecordingOpenVideoEditor)
        )
    }
}
