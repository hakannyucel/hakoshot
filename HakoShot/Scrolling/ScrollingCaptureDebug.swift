#if DEBUG
import AppKit
import Foundation
import HakoKit
import os

/// Smoke test for WP6.2: runs a scrolling capture and writes the stitched
/// PNG. Wiring (launch argument in `AppDelegate`) is in the WP6.2 report.
///
/// `-HakoScrollingDebug` [`-HakoScrollingDebugRect x,y,w,h`] (Quartz global
/// points; without it the area overlay runs) [`-HakoScrollingDebugAutoScroll`]
/// [`-HakoScrollingDebugOutput <path>`] (default
/// `~/Desktop/HakoShot-scrolling-debug.png`) [`-HakoScrollingDebugDoneAfter s`]
/// (press Done automatically).
enum ScrollingCaptureDebug {
    static let launchArgument = "-HakoScrollingDebug"
    static let rectArgument = "-HakoScrollingDebugRect"
    static let autoScrollArgument = "-HakoScrollingDebugAutoScroll"
    static let outputArgument = "-HakoScrollingDebugOutput"
    static let doneAfterArgument = "-HakoScrollingDebugDoneAfter"

    static var defaultOutputURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/HakoShot-scrolling-debug.png")
    }

    /// Call from `applicationDidFinishLaunching`; does nothing without `launchArgument`.
    static func runFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }
        let rect = value(after: rectArgument, in: arguments).flatMap(parseRect)
        let output = value(after: outputArgument, in: arguments).map { URL(fileURLWithPath: $0) } ?? defaultOutputURL
        let doneAfter = value(after: doneAfterArgument, in: arguments).flatMap(Double.init)
        let autoScroll = arguments.contains(autoScrollArgument)
        Task {
            await run(rect: rect, autoScroll: autoScroll, doneAfter: doneAfter, output: output)
        }
    }

    @discardableResult
    static func run(rect: GlobalRect?, autoScroll: Bool, doneAfter: TimeInterval?, output: URL) async -> URL? {
        let flow = ScrollingCaptureFlow()
        if let doneAfter {
            Task {
                try? await Task.sleep(for: .seconds(doneAfter))
                flow.requestDone()
            }
        }
        guard let result = await flow.run(rect: rect, autoScroll: autoScroll, start: true) else {
            Log.scrolling.notice("debug scrolling capture: no result")
            return nil
        }
        do {
            let data = try ImageEncoder.encode(result.image, format: .png, options: .defaults(for: .png, scale: result.scale))
            try data.write(to: output, options: .atomic)
            Log.scrolling.notice(
                "debug scrolling capture: \(result.image.width)x\(result.image.height) px @\(result.scale)x -> \(output.path, privacy: .public)"
            )
            return output
        } catch {
            Log.scrolling.error("debug scrolling capture: write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `"x,y,w,h"` → rect.
    static func parseRect(_ string: String) -> GlobalRect? {
        let parts = string.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return GlobalRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
