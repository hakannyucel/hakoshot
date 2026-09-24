#if DEBUG
import AppKit
import HakoKit
import os

/// DEBUG-only helpers to exercise the selection overlay without the capture
/// pipeline. Wiring lives in the WP1.2 report ("Entegrasyon parçası").
enum OverlayDebug {
    /// Launch argument: show the overlay once at launch and log the outcome.
    static let launchArgument = "-HakoOverlayDebug"
    /// Optional launch argument pair: `-HakoOverlayDebugAutoCancel <seconds>`
    /// cancels the session after that delay (for unattended screenshots).
    static let autoCancelArgument = "-HakoOverlayDebugAutoCancel"
    /// Optional: `-HakoOverlayDebugRect x,y,w,h` (Quartz global points) starts
    /// with a pre-selected rect, so the dim / frame / label are visible.
    static let initialRectArgument = "-HakoOverlayDebugRect"
    /// Optional: `-HakoOverlayDebugMode area|window|allInOne|scrolling|text`.
    static let modeArgument = "-HakoOverlayDebugMode"
    /// Optional flags: freeze the screen / editable selection with handles /
    /// embed a sample accessory bar (All-In-One placeholder) / apply the
    /// user's overlay settings (magnifier, crosshair, freeze).
    static let freezeArgument = "-HakoOverlayDebugFreeze"
    static let editableArgument = "-HakoOverlayDebugEditable"
    static let accessoryArgument = "-HakoOverlayDebugAccessory"
    static let userSettingsArgument = "-HakoOverlayDebugUserSettings"

    private static let controller = SelectionOverlayController()

    /// Runs one overlay session and logs the outcome.
    @discardableResult
    static func runAndLog(_ config: OverlayConfig = OverlayConfig(), accessory: (any OverlayAccessory)? = nil) async -> SelectionOutcome {
        let outcome = await controller.run(config, accessory: accessory)
        Log.overlay.notice("debug outcome: \(describe(outcome), privacy: .public)")
        return outcome
    }

    /// Call from `applicationDidFinishLaunching`; does nothing without `launchArgument`.
    static func runFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }
        var config = OverlayConfig(mode: .area, initialRect: value(after: initialRectArgument, in: arguments).flatMap(parseRect))
        if arguments.contains(userSettingsArgument) { config = config.applyingUserSettings() }
        switch value(after: modeArgument, in: arguments) {
        case "window": config.mode = .window
        case "allInOne": config.mode = .allInOne
        case "scrolling": config.mode = .scrolling
        case "text": config.mode = .text
        default: break
        }
        if arguments.contains(freezeArgument) { config.freeze = true }
        if arguments.contains(editableArgument) { config.editable = true }
        let accessory: (any OverlayAccessory)? = arguments.contains(accessoryArgument) ? DebugAccessory() : nil
        if let delay = value(after: autoCancelArgument, in: arguments).flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                controller.cancel()
            }
        }
        Task { await runAndLog(config, accessory: accessory) }
    }

    static func describe(_ outcome: SelectionOutcome) -> String {
        switch outcome {
        case .area(let rect, let displayID):
            "area x=\(rect.minX) y=\(rect.minY) w=\(rect.width) h=\(rect.height) display=\(displayID)"
        case .window(let windowID):
            "window \(windowID)"
        case .fullscreen(let displayID):
            "fullscreen display=\(displayID)"
        case .frozenArea(let rect, let displayID, let snapshot):
            "frozenArea x=\(rect.minX) y=\(rect.minY) w=\(rect.width) h=\(rect.height) display=\(displayID) crop=\(snapshot.cropped(to: rect).map { "\($0.width)x\($0.height)" } ?? "nil")"
        case .cancelled:
            "cancelled"
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func parseRect(_ text: String) -> GlobalRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return GlobalRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
/// A plain dark pill standing in for the All-In-One bar: shows the selection
/// size and exercises `OverlayAccessoryHost` (size 800×600 on click).
private final class DebugAccessory: OverlayAccessory {
    private let label = NSTextField(labelWithString: "No selection")
    private weak var host: (any OverlayAccessoryHost)?
    let view: NSView

    init() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = Tokens.Palette.hudControlFill.cgColor
        container.layer?.cornerRadius = 22
        label.textColor = Tokens.Palette.hudTextPrimary
        label.alignment = .center
        label.frame = container.bounds.insetBy(dx: 16, dy: 12)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)
        container.widthAnchor.constraint(equalToConstant: 260).isActive = true
        container.heightAnchor.constraint(equalToConstant: 44).isActive = true
        view = container
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        container.addGestureRecognizer(click)
    }

    func overlayDidStart(_ host: any OverlayAccessoryHost) {
        self.host = host
    }

    func overlay(_ host: any OverlayAccessoryHost, selectionDidChange rect: GlobalRect?) {
        label.stringValue = rect.map { "\(Int($0.width)) × \(Int($0.height))  (click: 800×600)" } ?? "No selection"
    }

    @objc private func clicked() {
        host?.setSelectionSize(CGSize(width: 800, height: 600))
    }
}
#endif
