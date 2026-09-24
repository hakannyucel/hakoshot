#if DEBUG
import AppKit
import HakoKit
import os

/// DEBUG automation for the real capture flows (WP3.4 / WP3.I smoke tests):
///
///     -HakoFlowDebug area|window|text|selfTimer|allInOne
///       [-HakoFlowDebugRect x,y,w,h]      initial selection (shown in the overlay)
///       [-HakoFlowDebugFreeze]            force Freeze Screen for this run
///       [-HakoFlowDebugFinish confirm|cancel|frontWindow|size|ratioMenu|area|fullscreen|window|timer|text]
///       [-HakoFlowDebugDelay seconds]     before finishing (default 1)
///       [-HakoFlowDebugAction save|copy|pin]
///
/// `confirm` = Return, `cancel` = Esc, `frontWindow` = click the frontmost
/// window; the mode names tap that All-In-One button. The overlay always
/// finishes by itself, so nothing stays on screen.
enum CaptureFlowDebug {
    static let launchArgument = "-HakoFlowDebug"
    static let rectArgument = "-HakoFlowDebugRect"
    static let freezeArgument = "-HakoFlowDebugFreeze"
    static let finishArgument = "-HakoFlowDebugFinish"
    static let delayArgument = "-HakoFlowDebugDelay"
    static let actionArgument = "-HakoFlowDebugAction"

    static func runFromLaunchArgumentsIfRequested(
        coordinator: AppCoordinator,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard let modeName = value(after: launchArgument, in: arguments) else { return }
        if modeName == "combine" {
            runCombine(coordinator: coordinator, arguments: arguments)
            return
        }
        let mode: CaptureMode
        switch modeName {
        case "area": mode = .area
        case "window": mode = .window
        case "text": mode = .text
        case "selfTimer": mode = .selfTimer
        case "allInOne": mode = .allInOne
        default:
            Log.coordinator.error("flow debug: unknown mode \(modeName, privacy: .public)")
            return
        }
        let rect = value(after: rectArgument, in: arguments).flatMap(parseRect)
        let action = value(after: actionArgument, in: arguments).flatMap(PostCaptureAction.init(rawValue:))
        let finish = value(after: finishArgument, in: arguments) ?? "cancel"
        let delay = value(after: delayArgument, in: arguments).flatMap(Double.init) ?? 1

        coordinator.debugConfigureCaptureFlow { flow in
            flow.debugShowsPresetInOverlay = true
            flow.debugForcesFreeze = arguments.contains(freezeArgument)
            flow.debugAutoFinish = { overlay, bar in
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    Log.coordinator.notice("flow debug: finishing with \(finish, privacy: .public)")
                    perform(finish, overlay: overlay, bar: bar)
                }
            }
        }
        Task {
            // Let the launch-time warm-up settle.
            try? await Task.sleep(for: .milliseconds(500))
            await coordinator.perform(.capture(mode, CaptureOptions(rect: rect, action: action)))
        }
    }

    /// `-HakoFlowDebug combine -HakoFlowDebugRect x,y,w,h`: sample editor →
    /// ⇧⌘I "Add New Screenshot" → overlay selects the rect and confirms →
    /// logs the editor's canvas size and image count (the pixels aren't inspected).
    private static func runCombine(coordinator: AppCoordinator, arguments: [String]) {
        let rect = value(after: rectArgument, in: arguments).flatMap(parseRect) ?? CGRect(x: 200, y: 200, width: 300, height: 200)
        coordinator.debugConfigureCaptureFlow { flow in
            flow.debugAutoFinish = { overlay, _ in
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    overlay.setSelection(GlobalRect(origin: rect.origin, size: rect.size))
                    overlay.confirmSelection()
                }
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard let editor = EditorDebug.openSample() else { return }
            let before = editor.model.document.canvas
            editor.model.addNewScreenshot()
            try? await Task.sleep(for: .seconds(4))
            let doc = editor.model.document
            let images = doc.annotations.filter { $0.kind.tag == .image }.count
            Log.coordinator.notice("flow debug combine: canvas \(Int(before.width))x\(Int(before.height)) -> \(Int(doc.canvas.width))x\(Int(doc.canvas.height)), images \(images)")
        }
    }

    private static func perform(_ finish: String, overlay: SelectionOverlayController, bar: AllInOneBar?) {
        if let bar, let mode = AllInOneMode(rawValue: finish) {
            bar.tap(mode)
            // Window mode waits for a click: pick the frontmost window.
            if mode == .window { perform("frontWindow", overlay: overlay, bar: nil) }
            return
        }
        switch finish {
        case "ratioMenu":
            // Leaves the overlay open (for a screenshot); the next finish ends it.
            bar?.toggleRatioMenu()
        case "size":
            // Types 1280 × 720 into the size fields with a 16:9 lock, then confirms.
            bar?.selectRatio(.fixed(width: 16, height: 9))
            bar?.model.widthText = "1280"
            bar?.submitSize(editedWidth: true)
            bar?.captureTapped()
        case "confirm":
            if bar != nil { bar?.captureTapped() } else { overlay.confirmSelection() }
        case "frontWindow":
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let window = WindowLocator.snapshot().frontmostWindow(preferringPID: pid) {
                Log.coordinator.notice("flow debug: front window '\(window.displayName, privacy: .public)'")
                overlay.finish(.window(window.id))
            } else {
                overlay.cancel()
            }
        default:
            overlay.cancel()
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func parseRect(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
#endif
