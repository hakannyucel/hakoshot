#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import HakoKit
import os

/// DEBUG-only: opens the R1.2 session-UI chrome (control bar, dimmer, border)
/// against a real, synthetic-source `RecordingSession` (plan §7 R1.2,
/// `hakoshot://debug-recording-chrome?x=&y=&width=&height=&snapshot=<dir>`),
/// writes every window's content as PNG into `snapshot`, then closes
/// everything. Not reachable from the app yet — wiring is the R1.2 report's
/// "Entegrasyon parçası" (`URLSchemeHandler` / `AppCommand` are hotspots).
enum RecordingChromeDebug {
    nonisolated struct Parameters: Equatable, Sendable {
        var rect: CGRect
        var snapshotDir: URL

        /// Keys: `x y width|w height|h snapshot`. `nil` when the rect or
        /// `snapshot` is missing/malformed.
        init?(queryItems: [URLQueryItem]) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            func number(_ keys: String...) -> Double? { keys.lazy.compactMap { values[$0].flatMap(Double.init) }.first }
            guard let x = number("x"), let y = number("y"), let w = number("width", "w"), let h = number("height", "h"), w > 0, h > 0 else {
                return nil
            }
            guard let path = values["snapshot"], !path.isEmpty else { return nil }
            rect = CGRect(x: x, y: y, width: w, height: h)
            snapshotDir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    private static let log = Logger(subsystem: Log.subsystem, category: "recording-chrome-debug")

    @MainActor
    static func run(_ parameters: Parameters) async {
        try? FileManager.default.createDirectory(at: parameters.snapshotDir, withIntermediateDirectories: true)

        let rect = GlobalRect(origin: parameters.rect.origin, size: parameters.rect.size)
        let layout = DisplayLayoutProvider.currentLayout()
        let displayID = ScreenGeometry.display(containing: CGPoint(x: rect.midX, y: rect.midY), layout: layout)?.id
            ?? layout.mainDisplayID

        // A real (synthetic-source) session, so the bar shows real state
        // (elapsed, timer text) instead of a hand-rolled fake.
        let session = RecordingSession()
        let request = RecordingRequest(target: .area(rect, displayID: displayID), source: .synthetic)
        do {
            _ = try await session.start(request)
        } catch {
            log.error("session.start failed: \(String(describing: error), privacy: .public)")
            return
        }
        // Let the timer read something other than "0:00".
        try? await Task.sleep(for: .seconds(1.4))

        let bar = RecordingControlBar(session: session)
        bar.show(recordedRect: rect, displayID: displayID)
        let dimmer = RecordingDimmer()
        dimmer.show(recordedRect: rect, recordingDisplayID: displayID)
        let border = RecordingAreaBorder()
        border.show(recordedRect: rect, recordingDisplayID: displayID)

        try? await Task.sleep(for: .seconds(0.3))
        write(bar.panel, name: "control-bar", dir: parameters.snapshotDir)
        for (id, panel) in dimmer.debugPanels {
            write(panel, name: id == displayID ? "dimmer" : "dimmer-display-\(id)", dir: parameters.snapshotDir)
        }
        for (id, panel) in border.debugPanels {
            write(panel, name: id == displayID ? "border" : "border-display-\(id)", dir: parameters.snapshotDir)
        }

        bar.hide()
        dimmer.hide()
        border.hide()
        await session.discard()
        log.notice("debug-recording-chrome snapshots written to \(parameters.snapshotDir.path, privacy: .public)")
    }

    /// In-process `cacheDisplay` (works with the displays asleep, never
    /// contains other apps' pixels), same technique as `DesignQADebug`.
    private static func write(_ window: NSWindow, name: String, dir: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            log.error("\(name, privacy: .public): no content view")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appending(path: "\(name).png"))
        log.notice("snapshot \(name, privacy: .public) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
#endif
