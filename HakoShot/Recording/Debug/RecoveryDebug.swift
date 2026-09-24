#if DEBUG
import CoreGraphics
import Foundation
import HakoKit
import os

/// Crash-recovery smoke tests (R7.4, plan §4.22).
///
/// `hakoshot://debug-crash-during-recording?seconds=3&source=synthetic`
/// starts a recording through `RecordingEngine.shared` (default sessions
/// root, no coordinator), waits `seconds` after the first frame and calls
/// `abort()`: the session folder is left behind with a fragmented
/// `screen.mov`, and the next launch recovers it into History.
///
/// `hakoshot://debug-recover-recordings?out=<json>` runs a recovery pass now
/// (skipping the active session) and writes the report as JSON.
enum RecoveryDebug {
    nonisolated struct CrashParameters: Sendable, Equatable {
        var seconds: Double = 3
        var source: RecordingSourceKind = .synthetic
        var rect: CGRect?
        /// Studio profile (recovered as a `.hakostudio`).
        var studio = false

        init(seconds: Double = 3, source: RecordingSourceKind = .synthetic, rect: CGRect? = nil, studio: Bool = false) {
            self.seconds = seconds
            self.source = source
            self.rect = rect
            self.studio = studio
        }

        /// Keys: `seconds|duration`, `source=synthetic|screen`, `x y width|w height|h`, `studio=1`.
        init(queryItems: [URLQueryItem]) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name] = value } }
            func number(_ keys: String...) -> Double? { keys.lazy.compactMap { values[$0].flatMap(Double.init) }.first }
            if let seconds = number("seconds", "duration"), seconds.isFinite, seconds > 0 { self.seconds = min(seconds, 60) }
            if let source = values["source"].flatMap(RecordingSourceKind.init(rawValue:)) { self.source = source }
            if let studio = values["studio"] { self.studio = ["1", "true", "yes"].contains(studio.lowercased()) }
            if let x = number("x"), let y = number("y"), let width = number("width", "w"), let height = number("height", "h"),
               width > 0, height > 0 {
                rect = CGRect(x: x, y: y, width: width, height: height)
            }
        }
    }

    /// Records, then kills the process. Returns only when starting failed.
    static func crashDuringRecording(_ parameters: CrashParameters, engine: RecordingEngine = .shared) async {
        let rect = parameters.rect ?? CGRect(x: 100, y: 100, width: 640, height: 360)
        let request = RecordingRequest(
            target: RecordingDebug.target(rect: rect),
            profile: parameters.studio ? .studio : .classic,
            source: parameters.source
        )
        do {
            let handle = try await engine.start(request)
            guard await engine.waitForFirstFrame(timeout: .seconds(5)) else {
                Log.recording.error("debug-crash-during-recording: no first frame")
                await engine.discard()
                return
            }
            Log.recording.notice("debug-crash-during-recording: session \(handle.id.uuidString, privacy: .public), aborting in \(parameters.seconds, privacy: .public) s")
            try? await Task.sleep(for: .seconds(parameters.seconds))
            Log.recording.notice("debug-crash-during-recording: abort()")
            abort()
        } catch {
            Log.recording.error("debug-crash-during-recording: start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs `RecordingRecovery.recover` now and writes a JSON summary to `out`.
    static func recoverNow(historyStore: HistoryStore, out: URL?, engine: RecordingEngine = .shared) async {
        let active = await engine.currentHandle?.id
        let report = await RecordingRecovery.recover(
            sessionsRoot: engine.sessionsRoot,
            excluding: active.map { [$0] } ?? [],
            historyStore: historyStore
        )
        guard let out else { return }
        let summary: [String: Any] = [
            "recovered": report.recovered.map { recovered -> [String: Any] in
                [
                    "session": recovered.sessionID.uuidString,
                    "file": recovered.result.fileURL.path,
                    "duration": recovered.result.duration,
                    "historyID": recovered.result.historyID?.uuidString ?? NSNull(),
                    "studio": recovered.wasStudio,
                    "package": recovered.studioPackageURL?.path ?? NSNull(),
                ]
            },
            "deleted": report.deleted.map(\.lastPathComponent),
            "kept": report.kept.map(\.lastPathComponent),
            "skipped": report.skipped.map(\.lastPathComponent),
            "message": report.message ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out, options: .atomic)
        } catch {
            Log.recording.error("debug-recover-recordings: writing \(out.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
