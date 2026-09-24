#if DEBUG
import CoreGraphics
import Foundation
import HakoKit
import os

/// DEBUG: runs `RecordingEngine` directly (no overlay, HUD, finalize or
/// router) and leaves the raw `.mov` (plan §7 R0.2,
/// `hakoshot://debug-record?x=&y=&width=&height=&seconds=&source=screen|synthetic&out=`).
enum RecordingDebug {
    /// `debug-record` URL parameters.
    nonisolated struct Parameters: Equatable, Sendable {
        /// Quartz global points; `nil` = the main display.
        var rect: CGRect?
        var seconds: Double = 3
        var source: RecordingSourceKind = .screen
        /// Where the `.mov` goes; `nil` = leave it in the session folder.
        var out: URL?
        var fps: Int?
        var codec: RecordingCodec?
        var quality: RecordingQuality?
        var showsCursor: Bool?
        /// `systemAudio=1`: record system audio (synthetic: 440 Hz tone).
        var systemAudio = false
        /// `mic=1`: record the system default microphone (synthetic: 880 Hz
        /// tone); `mic=<uniqueID>` picks a device.
        var microphone: MicrophoneChoice?

        init(
            rect: CGRect? = nil, seconds: Double = 3, source: RecordingSourceKind = .screen, out: URL? = nil,
            fps: Int? = nil, codec: RecordingCodec? = nil, quality: RecordingQuality? = nil, showsCursor: Bool? = nil,
            systemAudio: Bool = false, microphone: MicrophoneChoice? = nil
        ) {
            self.rect = rect
            self.seconds = seconds
            self.source = source
            self.out = out
            self.fps = fps
            self.codec = codec
            self.quality = quality
            self.showsCursor = showsCursor
            self.systemAudio = systemAudio
            self.microphone = microphone
        }

        /// Lenient parse: unknown or malformed values fall back to defaults.
        /// Keys: `x y width|w height|h seconds|duration source out fps codec quality cursor systemAudio mic`.
        init(queryItems: [URLQueryItem]) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            func number(_ keys: String...) -> Double? { keys.lazy.compactMap { values[$0].flatMap(Double.init) }.first }
            if let x = number("x"), let y = number("y"), let w = number("width", "w"), let h = number("height", "h"), w > 0, h > 0 {
                rect = CGRect(x: x, y: y, width: w, height: h)
            }
            seconds = number("seconds", "duration").map { max(0.2, $0) } ?? 3
            source = values["source"].flatMap { RecordingSourceKind(rawValue: $0.lowercased()) } ?? .screen
            if let path = values["out"], !path.isEmpty {
                out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            fps = number("fps").map { Int($0) }
            codec = values["codec"].flatMap { RecordingCodec(rawValue: $0.lowercased()) }
            quality = values["quality"].flatMap { RecordingQuality(rawValue: $0.lowercased()) }
            func flag(_ value: String?) -> Bool { value.map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false }
            if let cursor = values["cursor"] { showsCursor = flag(cursor) }
            systemAudio = flag(values["systemaudio"])
            if let mic = values["mic"], !mic.isEmpty, !["0", "false", "no"].contains(mic.lowercased()) {
                microphone = flag(mic) ? .systemDefault : .device(uniqueID: mic)
            }
        }
    }

    /// Records `seconds` of media (counted from the first frame) and returns
    /// the `.mov` URL: `out` if given (the session folder is then deleted),
    /// otherwise `screen.mov` inside the session folder.
    static func record(
        rect: CGRect?,
        seconds: Double,
        source: RecordingSourceKind = .screen,
        out: URL? = nil,
        options: RecordingOptions = .default,
        engine: RecordingEngine = .shared
    ) async throws -> URL {
        let target = Self.target(rect: rect)
        let request = RecordingRequest(target: target, options: options, autoStopAfter: seconds, source: source, outputURL: out)
        let handle = try await engine.start(request)
        guard await engine.waitForFirstFrame(timeout: .seconds(5)) else {
            await engine.discard()
            throw RecordingError.noFrames
        }
        try? await Task.sleep(for: .seconds(seconds))
        let raw = try await engine.stop()
        Log.recording.notice("debug-record: \(Int(handle.pixelSize.width))x\(Int(handle.pixelSize.height)) px, \(String(format: "%.3f", raw.duration), privacy: .public) s")

        guard let out else { return raw.screenURL }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: out)
        try fileManager.moveItem(at: raw.screenURL, to: out)
        try? fileManager.removeItem(at: raw.sessionFolder)
        return out
    }

    /// URL entry point: records and logs the result (errors are logged too).
    static func run(_ parameters: Parameters) async {
        var options = RecordingOptions.default
        if let fps = parameters.fps { options.fps = fps }
        if let codec = parameters.codec { options.codec = codec }
        if let quality = parameters.quality { options.quality = quality }
        if let showsCursor = parameters.showsCursor { options.showsCursor = showsCursor }
        options.capturesSystemAudio = parameters.systemAudio
        options.microphone = parameters.microphone
        do {
            let url = try await record(
                rect: parameters.rect, seconds: parameters.seconds, source: parameters.source,
                out: parameters.out, options: options
            )
            Log.recording.notice("debug-record wrote \(url.path, privacy: .public)")
        } catch {
            Log.recording.error("debug-record failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `.area` on the display under the rect's center, or the main display.
    static func target(rect: CGRect?) -> RecordingTarget {
        let layout = DisplayLayoutProvider.currentLayout()
        guard let rect else { return .display(layout.mainDisplayID) }
        let global = GlobalRect(origin: rect.origin, size: rect.size)
        let displayID = ScreenGeometry.display(containing: CGPoint(x: rect.midX, y: rect.midY), layout: layout)?.id
            ?? layout.mainDisplayID
        return .area(global, displayID: displayID)
    }
}
#endif
