#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import HakoKit
import ImageIO
import os
import UniformTypeIdentifiers

/// DEBUG-only: `hakoshot://debug-overlay-demo?x=&y=&snapshot=<dir>` (plan §7
/// R5.2). Opens a `RecordingOverlayWindow` on the display containing the
/// Quartz global point (x, y), fires a click ring there and a "⇧⌘F" badge,
/// and — with `snapshot` — writes the window content frozen at t = 0 / 100 /
/// 300 ms as `overlay-000ms.png`, `overlay-100ms.png`, `overlay-300ms.png`
/// (display-local pixels; ring center at (x, y) − display origin × scale),
/// plus `info.json` (ring center in image pixels, scale, window ID).
/// Without `snapshot` the live animation just plays. Uses the Settings'
/// click / badge look with both overlays forced on. Only our own layers are
/// rendered (no Screen Recording permission, works with the screen locked).
enum OverlayDemoDebug {
    nonisolated struct Parameters: Equatable, Sendable {
        var point: CGPoint
        var snapshotDir: URL?
        /// `button=right` shows the right-click double ring.
        var button: RecordingMouseButton
        /// Badge text (`keys=` already formatted, default "⇧⌘F").
        var keys: String

        /// Keys: `x y [snapshot] [button=left|right] [keys]`. `nil` when x/y
        /// are missing.
        init?(queryItems: [URLQueryItem]) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            guard let x = values["x"].flatMap(Double.init), let y = values["y"].flatMap(Double.init) else { return nil }
            point = CGPoint(x: x, y: y)
            snapshotDir = values["snapshot"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            button = values["button"].flatMap(RecordingMouseButton.init(rawValue:)) ?? .left
            keys = values["keys"].flatMap { $0.isEmpty ? nil : $0 } ?? "⇧⌘F"
        }
    }

    static let snapshotTimes: [TimeInterval] = [0, 0.1, 0.3]

    private static let log = Logger(subsystem: Log.subsystem, category: "overlay-demo-debug")

    @MainActor
    static func run(_ parameters: Parameters) async {
        let layout = DisplayLayoutProvider.currentLayout()
        let displayID = ScreenGeometry.display(containing: parameters.point, layout: layout)?.id ?? layout.mainDisplayID
        var appearance = RecordingOverlayAppearance(settings: .shared)
        appearance.highlightsClicks = true
        appearance.showsKeystrokes = true
        guard let overlay = RecordingOverlayWindow(displayID: displayID, appearance: appearance) else {
            log.error("no screen for display \(displayID)")
            return
        }
        overlay.show()
        overlay.showClick(at: parameters.point, button: parameters.button)
        overlay.showKeystroke(parameters.keys)

        if let dir = parameters.snapshotDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let scale = overlay.window.screen?.backingScaleFactor ?? 2
            for t in snapshotTimes {
                let name = String(format: "overlay-%03dms.png", Int((t * 1000).rounded()))
                guard let image = overlay.snapshot(at: t) else {
                    log.error("snapshot at \(t) failed")
                    continue
                }
                write(image, to: dir.appending(path: name))
            }
            let local = overlay.localPoint(parameters.point)
            let info: [String: Any] = [
                "displayID": displayID,
                "windowID": overlay.windowID.map { Int($0) } ?? -1,
                "scale": scale,
                "ringCenterPixel": [local.x * scale, local.y * scale],
                "ringRadiusPoints": snapshotTimes.map { overlay.appearance.clickModel.radius(at: $0) },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appending(path: "info.json"))
            }
            overlay.close()
            log.notice("debug-overlay-demo snapshots written to \(dir.path, privacy: .public)")
            return
        }

        // Live: let the badge play out (fade in, hold, fade out), then close.
        let timing = appearance.badgeTiming
        try? await Task.sleep(for: .seconds(timing.fadeIn + timing.hold + timing.fadeOut + 0.2))
        overlay.close()
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            log.notice("snapshot \(url.lastPathComponent, privacy: .public) \(image.width)x\(image.height)")
        }
    }
}
#endif
