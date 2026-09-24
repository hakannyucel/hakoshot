import CoreGraphics
import Foundation

/// Parses `hakoshot://<command>?<params>` into an `AppCommand`.
///
/// | URL | Command |
/// |---|---|
/// | `capture-area[?x=&y=&width=&height=][&action=]` | `.capture(.area, …)` (`w`/`h` accepted) |
/// | `capture-previous-area[?action=]` | `.capture(.previousArea, …)` |
/// | `capture-fullscreen[?display=active|all][&action=]` | `.capture(.fullscreen(…), …)` |
/// | `capture-window[?action=]` | `.capture(.window, …)` |
/// | `scrolling-capture[?x=&y=&width=&height=][&start=][&autoscroll=][&action=]` | `.capture(.scrolling, …)` (rect skips the overlay) |
/// | `self-timer[?x=&y=&width=&height=][&action=]` | `.capture(.selfTimer, …)` (rect skips the overlay) |
/// | `all-in-one[?x=&y=&width=&height=][&action=]` | `.capture(.allInOne, …)` (rect = initial selection) |
/// | `capture-text[?linebreaks=false][&x=&y=&width=&height=]` | `.captureText(lineBreaks:rect:)` |
/// | `open-history` | `.openHistory` |
/// | `restore-recently-closed` | `.restoreLastClosed` |
/// | `open-annotate[?filepath=]` | `.openEditor(URL?)` |
/// | `open-from-clipboard` | `.openFromClipboard` |
/// | `toggle-desktop-icons` | `.toggleDesktopIcons` |
/// | `close-all-pins` | `.closeAllPins` |
/// | `unlock-all-pins` | `.unlockAllPins` |
/// | `open-settings[?page=]` | `.openSettings` / `.openSettingsPage(page)` |
/// | `open-onboarding` | `.openOnboarding` |
/// | `record-screen[?mode=area|window|fullscreen][&x=&y=&width=&height=][&display=][&start=][&action=][&format=video|gif][&studio=]` | `.record(kind, …)` (rect + `start=true` skips the overlay) |
/// | `stop-recording` | `.stopRecording` |
/// | `pause-recording` / `resume-recording` | `.pauseRecording` / `.resumeRecording` |
/// | `toggle-pause-recording` (`toggle-recording-pause`) | `.togglePauseRecording` |
/// | `restart-recording` | `.restartRecording` |
/// | `discard-recording` | `.discardRecording(confirm: false)` |
/// | `open-video-editor[?filepath=]` | `.openVideoEditor(URL?)` (no file: open panel) |
/// | `convert-to-gif?filepath=[&action=save|copy]` | `.convertToGIF(URL, action:)` |
/// | `open-studio[?filepath=]` | `.openStudio(URL?)` (`.hakostudio` or a video; no file: open panel) |
///
/// DEBUG-only `record-screen` parameters: `duration=<s>` (auto-stop),
/// `countdown=<s>`, `out=<path>` (write the mp4 there, skip the router),
/// `source=screen|synthetic`, `window=frontmost|test|<id>` (window mode
/// without the overlay).
///
/// DEBUG-only commands (R3, R7.4): `debug-render?filepath=&recipe=<json>&out=[&passthrough=0]`,
/// `debug-video-editor?filepath=&snapshot=<png>[&recipe=&t=&crop=1&keep=1]`,
/// `debug-video-editor-apply?filepath=&recipe=<json>[&out=][&historyid=]`,
/// `debug-crash-during-recording[?seconds=&source=]`, `debug-recover-recordings[?out=]`.
///
/// DEBUG-only `record-screen` overrides (R4.I, R5.I): `camera=1|0|pattern`
/// (`pattern` = test-pattern bubble, no camera / TCC), `clicks=1|0`,
/// `keys=1|0`. With `out=`, `events.json`, `cursor.bin` and `camera.mov`
/// are copied next to it as `<out>.events.json` etc.
/// DEBUG-only webcam / input commands: `debug-camera-devices?out=`,
/// `debug-record-camera?out=[&seconds=&source=camera|pattern&device=]`,
/// `debug-webcam-bubble[?shape=&size=&corner=&mirror=&fullscreen=&x=&y=&width=&height=&pattern=&hold=&snapshot=]`,
/// `debug-inject-input?kind=click|key[&x=&y=&button=&keys=cmd+shift+f&repeat=]`,
/// `debug-recording-events?out=`, `debug-overlay-demo?x=&y=[&snapshot=&button=&keys=]`.
/// DEBUG-only Studio commands (R6.4, R7.3): `debug-render-studio-frame`,
/// `debug-export-studio`, `debug-studio-snapshot`, `debug-studio-zoom`,
/// `debug-studio-sample` (`StudioDebug.Command`), `debug-benchmark-export`,
/// `debug-close-studio-windows`; `debug-crash-during-recording` takes `studio=1`.
///
/// `action` is one of `copy`, `save`, `annotate`, `pin`.
nonisolated enum URLSchemeHandler {
    static let scheme = "hakoshot"

    static func parse(_ url: URL) throws(URLSchemeError) -> AppCommand {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme
        else {
            throw .unsupportedScheme(url.scheme)
        }

        // `hakoshot://capture-area` puts the command in the host;
        // `hakoshot:capture-area` / `hakoshot:///capture-area` in the path.
        let rawCommand: String
        if let host = components.host, !host.isEmpty {
            rawCommand = host
        } else {
            rawCommand = components.path.split(separator: "/").first.map(String.init) ?? ""
        }
        let command = rawCommand.lowercased()
        guard !command.isEmpty else { throw .missingCommand }

        let params = Parameters(components.queryItems ?? [])

        #if DEBUG
        do {
            if let studio = try StudioDebug.Command(host: command, queryItems: components.queryItems ?? []) {
                return .debugStudio(studio)
            }
        } catch {
            throw .invalidParameter(name: command, value: error.description)
        }
        #endif

        switch command {
        case "capture-area":
            return .capture(.area, try captureOptions(params, allowRect: true))
        case "capture-previous-area":
            return .capture(.previousArea, try captureOptions(params))
        case "capture-fullscreen":
            return .capture(.fullscreen(try fullscreenTarget(params)), try captureOptions(params))
        case "capture-window":
            return .capture(.window, try captureOptions(params))
        case "scrolling-capture":
            var options = try captureOptions(params, allowRect: true)
            options.start = try params.bool("start")
            options.autoScroll = try params.bool("autoscroll", "auto-scroll") ?? false
            return .capture(.scrolling, options)
        case "self-timer":
            return .capture(.selfTimer, try captureOptions(params, allowRect: true))
        case "all-in-one":
            return .capture(.allInOne, try captureOptions(params, allowRect: true))
        case "capture-text":
            let lineBreaks = try params.bool("linebreaks", "line-breaks") ?? true
            return .captureText(lineBreaks: lineBreaks, rect: try rect(params))
        case "open-history":
            return .openHistory
        case "restore-recently-closed":
            return .restoreLastClosed
        case "open-annotate":
            return .openEditor(fileURL(params.string("filepath", "path")))
        case "open-from-clipboard":
            return .openFromClipboard
        case "toggle-desktop-icons":
            return .toggleDesktopIcons
        case "close-all-pins":
            return .closeAllPins
        case "unlock-all-pins":
            return .unlockAllPins
        case "open-onboarding":
            return .openOnboarding
        case "record-screen":
            return try recordCommand(params)
        case "stop-recording":
            return .stopRecording
        case "pause-recording":
            return .pauseRecording
        case "resume-recording":
            return .resumeRecording
        case "toggle-pause-recording", "toggle-recording-pause":
            return .togglePauseRecording
        case "restart-recording":
            return .restartRecording
        case "discard-recording":
            return .discardRecording(confirm: false)
        case "open-video-editor":
            return .openVideoEditor(fileURL(params.string("filepath", "path")))
        case "open-studio":
            return .openStudio(fileURL(params.string("filepath", "path")))
        case "convert-to-gif":
            guard let file = fileURL(params.string("filepath", "path")) else {
                throw .invalidParameter(name: "filepath", value: "")
            }
            var action: PostCaptureAction?
            if let raw = params.string("action") {
                guard let parsed = PostCaptureAction(rawValue: raw.lowercased()), parsed == .save || parsed == .copy else {
                    throw .invalidParameter(name: "action", value: raw)
                }
                action = parsed
            }
            return .convertToGIF(file, action: action)
        case "open-settings":
            if let page = params.string("page", "tab"), !page.isEmpty {
                return .openSettingsPage(page.lowercased())
            }
            return .openSettings
        #if DEBUG
        case "debug-capture-main-display":
            return .debugCaptureMainDisplay
        case "debug-capture-front-window":
            return .debugCaptureFrontWindow
        case "debug-editor-save-project":
            guard let url = fileURL(params.string("filepath", "path")) else {
                throw .invalidParameter(name: "path", value: "")
            }
            return .debugEditorSaveProject(url)
        case "debug-quick-access-sample":
            return .debugQuickAccessSample
        case "debug-quick-access-edit":
            return .debugQuickAccessEdit()
        case "debug-quick-access-close":
            return .debugQuickAccessEdit(close: true)
        case "debug-close-editors":
            return .debugCloseEditors
        case "debug-annotate-and-save-editors":
            return .debugAnnotateAndSaveEditors
        case "debug-remove-history-entry":
            let raw = params.string("id") ?? ""
            guard let id = UUID(uuidString: raw) else { throw .invalidParameter(name: "id", value: raw) }
            return .debugRemoveHistoryEntry(id)
        case "debug-finish-scrolling":
            return .debugFinishScrolling
        case "debug-scrolling-sample":
            return .debugScrollingSample(try captureOptions(params))
        case "debug-set-shortcut":
            // `name=<ShortcutNames raw value>&keycode=<Carbon key code>&modifiers=command,shift`; no keycode clears it.
            guard let name = params.string("name"), !name.isEmpty else { throw .invalidParameter(name: "name", value: "") }
            let keyCode = try params.number("keycode").map { Int($0) }
            var flags: UInt = 0
            for part in (params.string("modifiers") ?? "").lowercased().split(separator: ",") {
                switch part {
                case "command", "cmd": flags |= 1 << 20
                case "shift": flags |= 1 << 17
                case "option", "alt": flags |= 1 << 19
                case "control", "ctrl": flags |= 1 << 18
                default: throw .invalidParameter(name: "modifiers", value: String(part))
                }
            }
            return .debugSetShortcut(name: name, keyCode: keyCode, modifiers: flags)
        case "debug-reset-shortcuts":
            return .debugResetShortcuts
        case "debug-snapshot-settings":
            guard let url = fileURL(params.string("filepath", "path")) else {
                throw .invalidParameter(name: "path", value: "")
            }
            return .debugSnapshotSettings(page: (params.string("page") ?? "general").lowercased(), url: url)
        case "debug-record":
            return .debugRecord(RecordingDebug.Parameters(queryItems: components.queryItems ?? []))
        case "debug-media-info":
            guard let file = fileURL(params.string("filepath", "path")) else {
                throw .invalidParameter(name: "filepath", value: "")
            }
            guard let out = fileURL(params.string("out")) else { throw .invalidParameter(name: "out", value: "") }
            return .debugMediaInfo(file: file, out: out)
        case "debug-quick-access-video-sample":
            let format: RecordingFormat = params.string("format")?.lowercased() == "gif" ? .gif : .video
            return .debugQuickAccessVideoSample(format: format, hover: try params.bool("hover") ?? false)
        case "debug-history-sample-video":
            return .debugHistorySampleVideo
        case "debug-recording-state":
            guard let out = fileURL(params.string("out", "filepath", "path")) else { throw .invalidParameter(name: "out", value: "") }
            return .debugRecordingState(out)
        case "debug-recording-chrome":
            guard let parameters = RecordingChromeDebug.Parameters(queryItems: components.queryItems ?? []) else {
                throw .invalidParameter(name: "snapshot", value: params.string("snapshot") ?? "")
            }
            return .debugRecordingChrome(parameters)
        case "debug-recording-hud":
            return .debugRecordingHUD(RecordingHUDDebug.Parameters(queryItems: components.queryItems ?? []))
        case "debug-move-test-window":
            return .debugMoveTestWindow(RecordingTargetDebug.MoveParameters(queryItems: components.queryItems ?? []))
        case "debug-close-test-window":
            return .debugCloseTestWindow
        case "debug-record-window":
            return .debugRecordWindow(RecordingTargetDebug.RecordWindowParameters(queryItems: components.queryItems ?? []))
        case "debug-audio-devices":
            guard let out = fileURL(params.string("out", "filepath", "path")) else { throw .invalidParameter(name: "out", value: "") }
            return .debugAudioDevices(out)
        case "debug-finalize":
            guard let parameters = RecordingAudioDebug.FinalizeParameters(queryItems: components.queryItems ?? []) else {
                throw .invalidParameter(name: "filepath", value: params.string("filepath", "path") ?? "")
            }
            return .debugFinalize(parameters)
        case "debug-render":
            do {
                return .debugRender(try RenderDebug.Parameters(queryItems: components.queryItems ?? []))
            } catch {
                throw .invalidParameter(name: "filepath/out/recipe", value: params.string("recipe") ?? "")
            }
        case "debug-video-editor":
            do {
                return .debugVideoEditor(try VideoEditorDebug.SnapshotParameters(queryItems: components.queryItems ?? []))
            } catch {
                throw .invalidParameter(name: "filepath", value: "")
            }
        case "debug-video-editor-apply":
            do {
                return .debugVideoEditorApply(try VideoEditorDebug.ApplyParameters(queryItems: components.queryItems ?? []))
            } catch {
                throw .invalidParameter(name: "filepath", value: "")
            }
        case "debug-crash-during-recording":
            return .debugCrashDuringRecording(RecoveryDebug.CrashParameters(queryItems: components.queryItems ?? []))
        case "debug-recover-recordings":
            return .debugRecoverRecordings(out: fileURL(params.string("out", "filepath", "path")))
        case "debug-camera-devices":
            return .debugCameraDevices(components.queryItems ?? [])
        case "debug-record-camera":
            guard let parameters = CameraDebug.RecordParameters(queryItems: components.queryItems ?? []) else {
                throw .invalidParameter(name: "out", value: params.string("out") ?? "")
            }
            return .debugRecordCamera(parameters)
        case "debug-webcam-bubble":
            return .debugWebcamBubble(CameraDebug.BubbleParameters(queryItems: components.queryItems ?? []))
        case "debug-inject-input":
            guard let parameters = InputDebug.InjectParameters(queryItems: components.queryItems ?? []) else {
                throw .invalidParameter(name: "kind", value: params.string("kind") ?? "")
            }
            return .debugInjectInput(parameters)
        case "debug-recording-events":
            guard let out = fileURL(params.string("out", "filepath", "path")) else { throw .invalidParameter(name: "out", value: "") }
            return .debugRecordingEvents(out)
        case StudioBenchmarkDebug.host:
            guard let spec = try? StudioBenchmarkDebug.spec(host: command, queryItems: components.queryItems ?? []) else {
                throw .invalidParameter(name: "out", value: params.string("out") ?? "")
            }
            return .debugBenchmarkExport(spec)
        case "debug-close-studio-windows":
            return .debugCloseStudioWindows
        case "debug-overlay-demo":
            guard let parameters = OverlayDemoDebug.Parameters(queryItems: components.queryItems ?? []) else {
                throw .invalidParameter(name: "x/y", value: "")
            }
            return .debugOverlayDemo(parameters)
        #endif
        default:
            throw .unknownCommand(rawCommand)
        }
    }

    // MARK: - Helpers

    private static func captureOptions(
        _ params: Parameters,
        allowRect: Bool = false
    ) throws(URLSchemeError) -> CaptureOptions {
        var options = CaptureOptions()
        if let raw = params.string("action") {
            guard let action = PostCaptureAction(rawValue: raw.lowercased()) else {
                throw .invalidParameter(name: "action", value: raw)
            }
            options.action = action
        }
        if allowRect {
            options.rect = try rect(params)
        }
        return options
    }

    /// `record-screen` (kayit-teknik-plan §4.21).
    private static func recordCommand(_ params: Parameters) throws(URLSchemeError) -> AppCommand {
        let kind: RecordingTargetKind
        switch params.string("mode")?.lowercased() {
        case nil, "", "area": kind = .area
        case "window": kind = .window
        case "fullscreen", "display": kind = .fullscreen
        case let other?: throw .invalidParameter(name: "mode", value: other)
        }
        var options = RecordingCommandOptions()
        options.rect = try rect(params)
        if let display = try params.number("display") {
            guard display >= 1, display == display.rounded() else { throw .invalidParameter(name: "display", value: "\(display)") }
            options.display = Int(display)
        }
        if let raw = params.string("format") {
            guard let format = RecordingFormat(rawValue: raw.lowercased()) else { throw .invalidParameter(name: "format", value: raw) }
            options.format = format
        }
        options.studio = try params.bool("studio") ?? false
        options.start = try params.bool("start") ?? false
        if let raw = params.string("action") {
            guard let action = PostCaptureAction(rawValue: raw.lowercased()), action == .save || action == .copy else {
                throw .invalidParameter(name: "action", value: raw)
            }
            options.action = action
        }
        #if DEBUG
        if let duration = try params.number("duration") {
            guard duration > 0 else { throw .invalidParameter(name: "duration", value: "\(duration)") }
            options.autoStopAfter = duration
        }
        if let countdown = try params.number("countdown") {
            guard countdown >= 0 else { throw .invalidParameter(name: "countdown", value: "\(countdown)") }
            options.countdownSeconds = Int(countdown)
        }
        options.outputURL = fileURL(params.string("out"))
        if let raw = params.string("source") {
            guard let source = RecordingSourceKind(rawValue: raw.lowercased()) else { throw .invalidParameter(name: "source", value: raw) }
            options.source = source
        }
        if let window = params.string("window"), !window.isEmpty {
            guard RecordingTargetDebug.WindowSelector(window) != nil else { throw .invalidParameter(name: "window", value: window) }
            options.window = window.lowercased()
        }
        if let raw = params.string("camera") {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": options.camera = .on
            case "0", "false", "no", "off": options.camera = .off
            case "pattern": options.camera = .pattern
            default: throw .invalidParameter(name: "camera", value: raw)
            }
        }
        options.highlightsClicks = try params.bool("clicks")
        options.showsKeystrokes = try params.bool("keys")
        #endif
        // `window=` alone means window mode.
        return .record(options.window != nil && params.string("mode") == nil ? .window : kind, options)
    }

    private static func rect(_ params: Parameters) throws(URLSchemeError) -> CGRect? {
        let x = try params.number("x")
        let y = try params.number("y")
        let width = try params.number("width", "w")
        let height = try params.number("height", "h")
        let values = [x, y, width, height]
        if values.allSatisfy({ $0 == nil }) { return nil }
        guard let x, let y, let width, let height else { throw .incompleteRect }
        guard width > 0, height > 0 else { throw .emptyRect }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func fullscreenTarget(_ params: Parameters) throws(URLSchemeError) -> FullscreenTarget {
        guard let raw = params.string("display") else { return .preferred }
        switch raw.lowercased() {
        case "active", "current": return .activeDisplay
        case "all": return .allDisplays
        default: throw .invalidParameter(name: "display", value: raw)
        }
    }

    private static func fileURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL { return url }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

nonisolated enum URLSchemeError: Error, Equatable, CustomStringConvertible {
    case unsupportedScheme(String?)
    case missingCommand
    case unknownCommand(String)
    case invalidParameter(name: String, value: String)
    case incompleteRect
    case emptyRect

    var description: String {
        switch self {
        case let .unsupportedScheme(scheme): return "unsupported scheme \(scheme ?? "nil")"
        case .missingCommand: return "missing command"
        case let .unknownCommand(command): return "unknown command '\(command)'"
        case let .invalidParameter(name, value): return "invalid value '\(value)' for '\(name)'"
        case .incompleteRect: return "x, y, width and height must all be given"
        case .emptyRect: return "width and height must be > 0"
        }
    }
}

/// Case-insensitive query parameter lookup; the last occurrence wins.
private nonisolated struct Parameters {
    private var values: [String: String] = [:]

    init(_ items: [URLQueryItem]) {
        for item in items {
            values[item.name.lowercased()] = item.value ?? ""
        }
    }

    func string(_ names: String...) -> String? {
        for name in names {
            if let value = values[name] { return value }
        }
        return nil
    }

    func number(_ names: String...) throws(URLSchemeError) -> Double? {
        for name in names {
            guard let raw = values[name] else { continue }
            guard let value = Double(raw), value.isFinite else {
                throw .invalidParameter(name: name, value: raw)
            }
            return value
        }
        return nil
    }

    func bool(_ names: String...) throws(URLSchemeError) -> Bool? {
        for name in names {
            guard let raw = values[name] else { continue }
            switch raw.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: throw .invalidParameter(name: name, value: raw)
            }
        }
        return nil
    }
}
