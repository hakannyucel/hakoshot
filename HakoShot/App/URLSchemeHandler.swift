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
