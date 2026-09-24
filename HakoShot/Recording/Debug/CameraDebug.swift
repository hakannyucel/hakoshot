#if DEBUG
import AppKit
import CoreMedia
import Foundation
import HakoKit
import os

/// DEBUG webcam helpers (plan §7 R4.1 / R4.2). None of them prompts for
/// camera access: without authorization (or without a camera) they use
/// `CameraTestPattern` or report `permissionDenied`.
///
/// - `hakoshot://debug-camera-devices?out=<json>`
/// - `hakoshot://debug-record-camera?seconds=3&out=<camera.mov>[&source=camera|pattern]`
///   → the .mov plus `<out>.json` (duration, size, frames, firstFrameHostTime,
///   `cameraTimeOffset` against the request instant, or `error`).
/// - `hakoshot://debug-webcam-bubble?shape=&size=&corner=&mirror=&fullscreen=&x=&y=&width=&height=&pattern=&hold=&snapshot=<png>`
///   → the bubble's PNG plus `<snapshot>.json` (window ID, frames, source).
enum CameraDebug {
    nonisolated private static let log = Logger(subsystem: Log.subsystem, category: "camera-debug")

    nonisolated static func values(_ items: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items { if let value = item.value { values[item.name.lowercased()] = value } }
        return values
    }

    nonisolated static func fileURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    nonisolated static func flag(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    nonisolated private static func writeJSON(_ object: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: debug-camera-devices

    /// `{"authorization", "defaultDeviceID", "devices": [{"id", "name", "kind"}]}`.
    nonisolated static func devicesJSON(_ list: CameraDeviceList = .current(), authorization: MediaAuthorization = CameraPermission.status) -> [String: Any] {
        [
            "authorization": authorization.rawValue,
            "defaultDeviceID": list.defaultDeviceID ?? NSNull(),
            "devices": list.devices.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] },
        ]
    }

    nonisolated static func writeDevices(queryItems: [URLQueryItem]) {
        guard let out = fileURL(values(queryItems)["out"]) else {
            log.error("debug-camera-devices: missing out")
            return
        }
        writeJSON(devicesJSON(), to: out)
        log.notice("debug-camera-devices wrote \(out.path, privacy: .public)")
    }

    // MARK: debug-record-camera

    nonisolated struct RecordParameters: Equatable, Sendable {
        enum Source: String, Sendable { case camera, pattern }
        var seconds: Double
        var out: URL
        var source: Source
        var deviceID: String?

        init?(queryItems: [URLQueryItem]) {
            let values = CameraDebug.values(queryItems)
            guard let out = CameraDebug.fileURL(values["out"]) else { return nil }
            self.out = out
            seconds = values["seconds"].flatMap(Double.init).map { min(max($0, 0.2), 60) } ?? 3
            source = values["source"].flatMap(Source.init(rawValue:)) ?? .camera
            deviceID = values["device"]
        }
    }

    /// Records `seconds` of camera (or pattern) into `out`. Returns the
    /// summary JSON (also written to `<out>.json`).
    @discardableResult
    static func recordCamera(_ parameters: RecordParameters) async -> [String: Any] {
        let jsonURL = parameters.out.appendingPathExtension("json")
        try? FileManager.default.createDirectory(at: parameters.out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let requestHost = CMClockGetTime(CMClockGetHostTimeClock())
        let recorder = CameraRecorder(outputURL: parameters.out)
        var result: [String: Any] = ["source": parameters.source.rawValue, "seconds": parameters.seconds]
        do {
            switch parameters.source {
            case .camera:
                let capture = CameraCapture()
                recorder.attach(to: capture)
                try await capture.start(deviceID: parameters.deviceID)
                try? await Task.sleep(for: .seconds(parameters.seconds))
                await capture.stop()
                capture.setSampleHandler(nil)
            case .pattern:
                await feedPattern(to: recorder, seconds: parameters.seconds)
            }
            let summary = try await recorder.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
            result["duration"] = summary.duration
            result["width"] = Int(summary.pixelSize.width)
            result["height"] = Int(summary.pixelSize.height)
            result["framesWritten"] = summary.framesWritten
            result["framesDropped"] = summary.framesDropped
            result["firstFrameHostTime"] = summary.firstFrameHostTime
            // Offset against the request instant (stands in for the screen's T0).
            result["cameraTimeOffset"] = summary.cameraTimeOffset(screenOrigin: requestHost.seconds)
            result["out"] = parameters.out.path
        } catch {
            recorder.cancel()
            result["error"] = Self.errorName(error)
            result["errorDescription"] = String(describing: error)
        }
        writeJSON(result, to: jsonURL)
        log.notice("debug-record-camera wrote \(jsonURL.path, privacy: .public)")
        return result
    }

    nonisolated static func errorName(_ error: any Error) -> String {
        switch error {
        case RecordingError.permissionDenied: "permissionDenied"
        case RecordingError.noFrames: "noFrames"
        case RecordingError.sourceFailed: "sourceFailed"
        default: "failed"
        }
    }

    /// 30 fps 1280×720 pattern frames stamped with the real host clock.
    static func feedPattern(to recorder: CameraRecorder, seconds: Double, width: Int = 1280, height: Int = 720) async {
        let clock = CMClockGetHostTimeClock()
        let start = CMClockGetTime(clock)
        var frame = 0
        while (CMClockGetTime(clock) - start).seconds < seconds {
            let pts = CMClockGetTime(clock)
            if let sample = CameraTestPattern.sampleBuffer(width: width, height: height, frame: frame, pts: pts) {
                recorder.append(sample, hostTime: pts)
            }
            frame += 1
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    // MARK: debug-webcam-bubble

    /// `[x, y, width, height]` (AppKit points) for JSON.
    nonisolated static func numbers(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    nonisolated struct BubbleParameters: Equatable, Sendable {
        var options: CameraOptions
        var fullscreen: Bool
        /// Quartz global points; `nil` = 1280×720 centered on the main display.
        var rect: CGRect?
        var forcePattern: Bool
        var hold: Double
        var snapshot: URL?

        init(queryItems: [URLQueryItem]) {
            let values = CameraDebug.values(queryItems)
            var options = CameraOptions()
            if let shape = values["shape"].flatMap(CameraShape.init(rawValue:)) { options.shape = shape }
            if let size = values["size"].flatMap(RecordingElementSize.init(rawValue:)) { options.size = size }
            if let corner = values["corner"].flatMap(CameraCorner.init(rawValue:)) { options.corner = corner }
            options.mirrored = CameraDebug.flag(values["mirror"])
            options.deviceID = values["device"]
            self.options = options
            fullscreen = CameraDebug.flag(values["fullscreen"])
            forcePattern = CameraDebug.flag(values["pattern"])
            hold = values["hold"].flatMap(Double.init).map { min(max($0, 0), 60) } ?? 0
            snapshot = CameraDebug.fileURL(values["snapshot"])
            func number(_ keys: String...) -> Double? { keys.lazy.compactMap { values[$0].flatMap(Double.init) }.first }
            if let x = number("x"), let y = number("y"), let w = number("width", "w"), let h = number("height", "h"), w > 0, h > 0 {
                rect = CGRect(x: x, y: y, width: w, height: h)
            }
        }
    }

    /// Shows the bubble, snapshots it, keeps it `hold` seconds, hides it.
    @discardableResult
    static func showBubble(_ parameters: BubbleParameters) async -> [String: Any] {
        let layout = DisplayLayoutProvider.currentLayout()
        let rect: GlobalRect
        if let r = parameters.rect {
            rect = GlobalRect(origin: r.origin, size: r.size)
        } else {
            let main = layout.mainDisplay.flatMap { ScreenGeometry.globalFrame(of: $0, layout: layout) }
                ?? GlobalRect(x: 0, y: 0, width: 1440, height: 900)
            let w = min(1280, main.width), h = min(720, main.height)
            rect = GlobalRect(x: main.midX - w / 2, y: main.midY - h / 2, width: w, height: h)
        }

        let bubble = WebcamBubbleWindow(options: parameters.options)
        bubble.setFullscreen(parameters.fullscreen)
        var capture: CameraCapture?
        var source = "pattern"
        let canUseCamera = !parameters.forcePattern && CameraPermission.isGranted
            && CameraDeviceList.captureDevice(for: parameters.options.deviceID) != nil
        if canUseCamera {
            let live = CameraCapture()
            do {
                try await live.start(deviceID: parameters.options.deviceID)
                bubble.attach(live)
                capture = live
                source = "camera"
            } catch {
                log.error("camera start failed, using the test pattern: \(String(describing: error), privacy: .public)")
            }
        }
        if capture == nil { bubble.showStill(CameraTestPattern.image()) }
        bubble.show(recordedRect: rect)
        try? await Task.sleep(for: .seconds(capture == nil ? 0.2 : 1.0))

        var result: [String: Any] = [
            "source": source,
            "windowID": bubble.windowID.map { Int($0) } ?? NSNull(),
            "bubbleFrame": Self.numbers(bubble.bubbleFrame),
            "recordedRect": Self.numbers(bubble.recordedRect),
            "shadowPadding": Double(bubble.shadowPadding),
            "corner": bubble.corner.rawValue,
            "fullscreen": bubble.isFullscreen,
        ]
        if let snapshot = parameters.snapshot {
            if let capture {
                // The preview layer isn't in `cacheDisplay`; draw the last frame instead.
                result["cameraFrames"] = capture.frameCount
                bubble.bubbleView.still = capture.latestFrameImage()
            }
            if let rep = bubble.snapshot(), let data = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: snapshot)
                result["snapshotSize"] = [rep.pixelsWide, rep.pixelsHigh]
                result["scale"] = Double(rep.pixelsWide) / Double(max(bubble.bubbleView.bounds.width, 1))
            }
            writeJSON(result, to: snapshot.appendingPathExtension("json"))
        }
        if parameters.hold > 0 { try? await Task.sleep(for: .seconds(parameters.hold)) }
        bubble.hide()
        if let capture { await capture.stop() }
        log.notice("debug-webcam-bubble done (\(source, privacy: .public))")
        return result
    }
}
#endif
