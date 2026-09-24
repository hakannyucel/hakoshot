import CoreGraphics
import Foundation

/// Every user-triggerable action. Hotkeys, the menu bar and `hakoshot://` URLs
/// all produce an `AppCommand` and hand it to `AppCoordinator.perform(_:)`.
nonisolated enum AppCommand: Equatable, Sendable {
    case capture(CaptureMode, CaptureOptions = CaptureOptions())
    /// `rect` (Quartz global points, URL scheme only) skips the area overlay.
    case captureText(lineBreaks: Bool, rect: CGRect? = nil)
    case openHistory
    case restoreLastClosed
    /// `nil` means "ask the user to pick a file".
    case openEditor(URL?)
    case openFromClipboard
    case toggleDesktopIcons
    case closeAllPins
    case unlockAllPins
    case openSettings
    /// Opens Settings on one page (`SettingsPage` raw value, e.g. "shortcuts").
    case openSettingsPage(String)
    /// Shows the onboarding window from its first step.
    case openOnboarding

    // MARK: Screen recording (kayit-teknik-plan §2.2, §4.21)

    /// Starts a recording flow: selection overlay → HUD → session. While a
    /// recording runs, the "Record Screen" hotkey sends this and it stops.
    case record(RecordingTargetKind, RecordingCommandOptions = RecordingCommandOptions())
    case stopRecording
    case pauseRecording
    case resumeRecording
    case togglePauseRecording
    /// Throws away what was recorded and starts again with the same target (no confirmation).
    case restartRecording
    /// `confirm`: ask "Discard recording?" first (control bar Trash); URL commands pass `false`.
    case discardRecording(confirm: Bool)
    /// `nil` means "ask the user to pick a file".
    case openVideoEditor(URL?)
    /// Video → GIF with Settings › Screen Recording › GIF. `action` `nil`:
    /// a Quick Access GIF card; `.save` / `.copy`: save / copy instead (URL
    /// `action=`). History always gets the GIF.
    case convertToGIF(URL, action: PostCaptureAction? = nil)
    /// `.hakostudio` package or a video file; `nil` means "ask the user to pick a file".
    case openStudio(URL?)
    #if DEBUG
    case showDesignSystemPreview
    case debugCaptureMainDisplay
    case debugQuickAccessSample
    case debugPinSample
    case debugHistorySample
    case debugCaptureFrontWindow
    /// Opens the annotated sample editor, saves it as a project at the URL, closes it.
    case debugEditorSaveProject(URL)
    /// Performs Edit (or Close) on the newest Quick Access card.
    case debugQuickAccessEdit(close: Bool = false)
    /// Closes every editor window without asking.
    case debugCloseEditors
    /// Adds the sample annotations to every open editor, then ⌘S.
    case debugAnnotateAndSaveEditors
    /// Removes one History entry (and its files).
    case debugRemoveHistoryEntry(UUID)
    /// Presses Done on the running scrolling capture.
    case debugFinishScrolling
    /// Routes a synthetic tall `.scrolling` result like a finished scrolling capture
    /// (checks Quick Access / history wiring when the display can't be captured).
    case debugScrollingSample(CaptureOptions)
    /// Sets one global shortcut (`nil` key code clears it); modifiers are `NSEvent.ModifierFlags` raw values.
    case debugSetShortcut(name: String, keyCode: Int?, modifiers: UInt)
    case debugResetShortcuts
    /// Opens Settings on `page` and writes the window's content as PNG (works with the display asleep).
    case debugSnapshotSettings(page: String, url: URL)
    /// Runs `RecordingEngine` directly and leaves the raw `.mov` (R0.2, `debug-record`).
    case debugRecord(RecordingDebug.Parameters)
    /// Writes `MediaInspector.info(for:)` of `file` as JSON to `out` (R0.3, `debug-media-info`).
    case debugMediaInfo(file: URL, out: URL)
    /// Shows a synthetic video / GIF Quick Access card (R0.5).
    case debugQuickAccessVideoSample(format: RecordingFormat, hover: Bool)
    /// Adds a synthetic video entry to History (R0.4).
    case debugHistorySampleVideo
    /// Writes the recording session / coordinator state as JSON (R1.3, R1.I).
    case debugRecordingState(URL)
    /// Opens the session chrome with a synthetic session and snapshots it (R1.2).
    case debugRecordingChrome(RecordingChromeDebug.Parameters)
    /// Opens the pre-record HUD standalone and snapshots it (R1.1).
    case debugRecordingHUD(RecordingHUDDebug.Parameters)
    /// Opens (and moves) the four-color test window (R1.4).
    case debugMoveTestWindow(RecordingTargetDebug.MoveParameters)
    case debugCloseTestWindow
    /// Records a window with the follower, without the coordinator (R1.4).
    case debugRecordWindow(RecordingTargetDebug.RecordWindowParameters)
    /// Writes the audio input devices as JSON (R2.1, `debug-audio-devices`).
    case debugAudioDevices(URL)
    /// Runs the finalizer's audio mix on a raw file (R2.2, `debug-finalize`).
    case debugFinalize(RecordingAudioDebug.FinalizeParameters)
    /// Renders a file with a recipe, no UI (R3.2, `debug-render`).
    case debugRender(RenderDebug.Parameters)
    /// Opens the video editor and snapshots it (R3.3, `debug-video-editor`).
    case debugVideoEditor(VideoEditorDebug.SnapshotParameters)
    /// The video editor's save path without UI (R3.3, `debug-video-editor-apply`).
    case debugVideoEditorApply(VideoEditorDebug.ApplyParameters)
    /// Records, then `abort()`s: the next launch recovers the session (R7.4).
    case debugCrashDuringRecording(RecoveryDebug.CrashParameters)
    /// Runs a recovery pass now; `out` gets the report as JSON (R7.4).
    case debugRecoverRecordings(out: URL?)
    /// Camera list as JSON (R4.1, `debug-camera-devices?out=`).
    case debugCameraDevices([URLQueryItem])
    /// Records the camera / test pattern to a .mov (R4.1, `debug-record-camera`).
    case debugRecordCamera(CameraDebug.RecordParameters)
    /// Shows and snapshots the webcam bubble (R4.2, `debug-webcam-bubble`).
    case debugWebcamBubble(CameraDebug.BubbleParameters)
    /// Synthetic click / key into the running EventRecorder (R5.1, `debug-inject-input`).
    case debugInjectInput(InputDebug.InjectParameters)
    /// The running (or last finished) EventRecorder as JSON (R5.1, `debug-recording-events`).
    case debugRecordingEvents(URL)
    /// Click ring + keystroke badge demo / snapshots (R5.2, `debug-overlay-demo`).
    case debugOverlayDemo(OverlayDemoDebug.Parameters)
    /// Studio frame / export / snapshot / zoom / sample project (R6.4, `debug-render-studio-frame` …).
    case debugStudio(StudioDebug.Command)
    /// Studio export benchmark (R7.3, `debug-benchmark-export`).
    case debugBenchmarkExport(StudioBenchmarkDebug.Spec)
    /// Closes every Studio window (edits are autosaved first).
    case debugCloseStudioWindows
    #endif
}

nonisolated enum CaptureMode: Equatable, Sendable {
    case area
    case window
    case fullscreen(FullscreenTarget)
    case previousArea
    case scrolling
    case selfTimer
    case allInOne
    case text
}

nonisolated enum FullscreenTarget: Equatable, Sendable {
    /// Follow Settings > Screenshots > Fullscreen display.
    case preferred
    /// The display under the mouse cursor.
    case activeDisplay
    case allDisplays
}

/// Overrides that can accompany a capture (mainly from URL commands).
nonisolated struct CaptureOptions: Equatable, Sendable {
    /// Pre-selected rect in Quartz global points (top-left origin, see plan §3.2).
    var rect: CGRect?
    /// Overrides the after-capture settings for this one capture.
    var action: PostCaptureAction?
    /// Scrolling capture: start capturing without the "Start Capture" step;
    /// `nil` follows Settings > Screenshots > Scrolling (URL `start=`).
    var start: Bool?
    /// Scrolling capture: auto-scroll right away (URL `autoscroll=`).
    var autoScroll: Bool

    init(rect: CGRect? = nil, action: PostCaptureAction? = nil, start: Bool? = nil, autoScroll: Bool = false) {
        self.rect = rect
        self.action = action
        self.start = start
        self.autoScroll = autoScroll
    }
}

nonisolated enum PostCaptureAction: String, Equatable, Sendable, CaseIterable {
    case copy
    case save
    case annotate
    case pin
}

// MARK: - Logging

extension AppCommand: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case let .capture(mode, options):
            var parts: [String] = []
            if let rect = options.rect {
                parts.append("rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))")
            }
            if let action = options.action { parts.append("action=\(action.rawValue)") }
            if let start = options.start { parts.append("start=\(start)") }
            if options.autoScroll { parts.append("autoscroll") }
            let suffix = parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
            return "capture(\(mode)\(suffix))"
        case let .captureText(lineBreaks, rect):
            let suffix = rect.map { ", rect=\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? ""
            return "captureText(lineBreaks: \(lineBreaks)\(suffix))"
        case .openHistory: return "openHistory"
        case .restoreLastClosed: return "restoreLastClosed"
        case let .openEditor(url): return "openEditor(\(url?.path ?? "choose file"))"
        case .openFromClipboard: return "openFromClipboard"
        case .toggleDesktopIcons: return "toggleDesktopIcons"
        case .closeAllPins: return "closeAllPins"
        case .unlockAllPins: return "unlockAllPins"
        case .openSettings: return "openSettings"
        case let .openSettingsPage(page): return "openSettings(\(page))"
        case .openOnboarding: return "openOnboarding"
        case let .record(kind, options):
            let details = options.description
            return "record(\(kind.rawValue)\(details.isEmpty ? "" : ", " + details))"
        case .stopRecording: return "stopRecording"
        case .pauseRecording: return "pauseRecording"
        case .resumeRecording: return "resumeRecording"
        case .togglePauseRecording: return "togglePauseRecording"
        case .restartRecording: return "restartRecording"
        case let .discardRecording(confirm): return "discardRecording(confirm: \(confirm))"
        case let .openVideoEditor(url): return "openVideoEditor(\(url?.path ?? "choose file"))"
        case let .convertToGIF(url, action): return "convertToGIF(\(url.path)\(action.map { ", action=\($0.rawValue)" } ?? ""))"
        case let .openStudio(url): return "openStudio(\(url?.path ?? "choose file"))"
        #if DEBUG
        case .showDesignSystemPreview: return "showDesignSystemPreview"
        case .debugCaptureMainDisplay: return "debugCaptureMainDisplay"
        case .debugQuickAccessSample: return "debugQuickAccessSample"
        case .debugPinSample: return "debugPinSample"
        case .debugHistorySample: return "debugHistorySample"
        case .debugCaptureFrontWindow: return "debugCaptureFrontWindow"
        case let .debugEditorSaveProject(url): return "debugEditorSaveProject(\(url.path))"
        case let .debugQuickAccessEdit(close): return close ? "debugQuickAccessClose" : "debugQuickAccessEdit"
        case .debugCloseEditors: return "debugCloseEditors"
        case .debugAnnotateAndSaveEditors: return "debugAnnotateAndSaveEditors"
        case let .debugRemoveHistoryEntry(id): return "debugRemoveHistoryEntry(\(id.uuidString))"
        case .debugFinishScrolling: return "debugFinishScrolling"
        case .debugScrollingSample: return "debugScrollingSample"
        case let .debugSetShortcut(name, keyCode, modifiers):
            return "debugSetShortcut(\(name), keyCode: \(keyCode.map(String.init) ?? "none"), modifiers: \(modifiers))"
        case .debugResetShortcuts: return "debugResetShortcuts"
        case let .debugSnapshotSettings(page, url): return "debugSnapshotSettings(\(page), \(url.path))"
        case let .debugRecord(parameters): return "debugRecord(\(parameters.source.rawValue), \(parameters.seconds) s)"
        case let .debugMediaInfo(file, out): return "debugMediaInfo(\(file.path) -> \(out.path))"
        case let .debugQuickAccessVideoSample(format, hover): return "debugQuickAccessVideoSample(\(format.rawValue)\(hover ? ", hover" : ""))"
        case .debugHistorySampleVideo: return "debugHistorySampleVideo"
        case let .debugRecordingState(url): return "debugRecordingState(\(url.path))"
        case let .debugRecordingChrome(p): return "debugRecordingChrome(\(p.rect), \(p.snapshotDir.path))"
        case let .debugRecordingHUD(p): return "debugRecordingHUD(\(p.rect), \(p.snapshot?.path ?? "-"))"
        case let .debugMoveTestWindow(p): return "debugMoveTestWindow(\(p.rect.map { "\($0)" } ?? "default"))"
        case .debugCloseTestWindow: return "debugCloseTestWindow"
        case let .debugRecordWindow(p): return "debugRecordWindow(\(p.window), \(p.seconds) s)"
        case let .debugAudioDevices(url): return "debugAudioDevices(\(url.path))"
        case let .debugFinalize(p): return "debugFinalize(\(p.summary))"
        case let .debugRender(p): return "debugRender(\(p.source.lastPathComponent) -> \(p.out.path))"
        case let .debugVideoEditor(p): return "debugVideoEditor(\(p.source.lastPathComponent), snapshot: \(p.snapshot?.path ?? "-"))"
        case let .debugVideoEditorApply(p): return "debugVideoEditorApply(\(p.source.lastPathComponent) -> \(p.out?.path ?? "export folder"))"
        case let .debugCrashDuringRecording(p): return "debugCrashDuringRecording(\(p.seconds) s, \(p.source.rawValue))"
        case let .debugRecoverRecordings(out): return "debugRecoverRecordings(\(out?.path ?? "-"))"
        case .debugCameraDevices: return "debugCameraDevices"
        case let .debugRecordCamera(p): return "debugRecordCamera(\(p.source.rawValue), \(p.seconds) s -> \(p.out.path))"
        case let .debugWebcamBubble(p): return "debugWebcamBubble(\(p.options.shape.rawValue), \(p.snapshot?.path ?? "-"))"
        case let .debugInjectInput(p): return "debugInjectInput(\(p.kind.rawValue))"
        case let .debugRecordingEvents(url): return "debugRecordingEvents(\(url.path))"
        case let .debugOverlayDemo(p): return "debugOverlayDemo(\(p.point.x),\(p.point.y), \(p.snapshotDir?.path ?? "-"))"
        case let .debugStudio(command): return "debugStudio(\(command))"
        case let .debugBenchmarkExport(spec): return "debugBenchmarkExport(\(spec.out.path))"
        case .debugCloseStudioWindows: return "debugCloseStudioWindows"
        #endif
        }
    }
}
