import AppKit
import CoreMedia
import HakoKit
import os

/// What a recording shows and records besides the screen (plan §4.8–§4.10,
/// R4.I / R5.I). Pure; `RecordingCompanions` follows it.
nonisolated struct RecordingCompanionPlan: Equatable, Sendable {
    /// Webcam bubble on screen (camera on in the options).
    var showsCamera: Bool
    /// Classic: the bubble is an excepted window, captured into the video.
    var capturesCameraInVideo: Bool
    /// Studio: the bubble is only a preview; the camera goes to `camera.mov`.
    var writesCameraFile: Bool
    /// Classic with click highlights or the keystroke badge: the live
    /// overlay window, captured into the video.
    var showsOverlay: Bool
    /// "Show keystrokes": keys go to `events.json` (privacy: only then).
    var recordsKeystrokes: Bool

    static func make(_ request: RecordingRequest) -> RecordingCompanionPlan {
        let classic = request.profile == .classic
        let camera = request.options.camera != nil
        return RecordingCompanionPlan(
            showsCamera: camera,
            capturesCameraInVideo: camera && classic,
            writesCameraFile: camera && !classic,
            showsOverlay: classic && (request.options.highlightsClicks || request.options.showsKeystrokes),
            recordsKeystrokes: request.options.showsKeystrokes
        )
    }

    /// The windows the stream must capture although they are ours
    /// (`RecordingSourceConfiguration.exceptedWindowIDs`): classic → the
    /// bubble and the overlay; Studio → none (bubble and badge are drawn
    /// later from `camera.mov` and `events.json`).
    func exceptedWindowIDs(bubble: CGWindowID?, overlay: CGWindowID?) -> [CGWindowID] {
        var ids: [CGWindowID] = []
        if capturesCameraInVideo, let bubble { ids.append(bubble) }
        if showsOverlay, let overlay { ids.append(overlay) }
        return ids
    }
}

/// Where the bubble's picture comes from.
nonisolated enum RecordingCameraSource: Equatable, Sendable {
    /// `CameraCapture` (needs camera access; never prompts here).
    case live
    /// `CameraTestPattern` (DEBUG `record-screen … camera=pattern`): no camera, no TCC.
    case pattern
}

/// The webcam bubble, `camera.mov`, the live click / keystroke overlay and
/// the `EventRecorder` of one recording session (R4.I, R5.I). The
/// coordinator drives it:
///
/// 1. `prepare(rect:displayID:)` BEFORE `session.start` — opens the camera,
///    shows the bubble and the overlay (the rule in `kayit-ilerleme.md`:
///    windows seen during a recording are on screen before the stream
///    starts) and returns the excepted window IDs.
/// 2. `didStart(_:engine:)` — `EventRecorder` (every recording), Studio
///    `CameraRecorder`, live overlay callbacks.
/// 3. `recordedRectChanged`, `didPause`, `didResume`, `didRestart`.
/// 4. `stopInputs()` → `session.stop()` → `finish(_:stopHost:)` (merges
///    `events.json`, `camera.mov`, sets `cameraURL` / `cursorURL`), or
///    `discard()`; then `tearDown()`.
@MainActor
final class RecordingCompanions {
    let plan: RecordingCompanionPlan
    let request: RecordingRequest
    let cameraSource: RecordingCameraSource
    let appearance: RecordingOverlayAppearance

    private(set) var bubble: WebcamBubbleWindow?
    private(set) var overlay: RecordingOverlayWindow?
    private(set) var eventRecorder: EventRecorder?
    private var capture: CameraCapture?
    private var cameraRecorder: CameraRecorder?
    private var patternFeeder: Task<Void, Never>?
    private var cameraURL: URL?
    /// The recorded rect (Quartz global points), read per input event.
    private(set) var eventRect: CGRect = .zero

    /// The bubble was dragged to another corner (the coordinator saves it).
    var onCornerChange: ((CameraCorner) -> Void)?

    init(request: RecordingRequest, cameraSource: RecordingCameraSource = .live, settings: AppSettings = .shared) {
        self.request = request
        self.cameraSource = cameraSource
        plan = RecordingCompanionPlan.make(request)
        var appearance = RecordingOverlayAppearance(settings: settings)
        appearance.highlightsClicks = request.options.highlightsClicks
        appearance.showsKeystrokes = request.options.showsKeystrokes
        self.appearance = appearance
    }

    // MARK: Before start

    /// Opens the camera and shows the bubble and the overlay around `rect`.
    /// Returns the window IDs the stream must capture. A camera that can't
    /// start (no access, unplugged) records without it and says so.
    func prepare(rect: GlobalRect, displayID: CGDirectDisplayID) async -> [CGWindowID] {
        eventRect = rect.cgRect
        if plan.showsCamera, let options = request.options.camera {
            await prepareCamera(options, rect: rect)
        }
        if plan.showsOverlay, let window = RecordingOverlayWindow(displayID: displayID, appearance: appearance) {
            window.badgeRegion = rect.cgRect
            window.show()
            overlay = window
        }
        let ids = plan.exceptedWindowIDs(bubble: bubble?.windowID, overlay: overlay?.windowID)
        if !ids.isEmpty {
            Log.recording.notice("capturing our windows \(ids.map(String.init).joined(separator: ","), privacy: .public)")
        }
        return ids
    }

    private func prepareCamera(_ options: CameraOptions, rect: GlobalRect) async {
        let bubble = WebcamBubbleWindow(options: options)
        bubble.onCornerChange = { [weak self] corner in self?.onCornerChange?(corner) }
        switch cameraSource {
        case .pattern:
            bubble.showStill(CameraTestPattern.image())
        case .live:
            let capture = CameraCapture()
            do {
                try await capture.start(deviceID: options.deviceID)
            } catch {
                Log.recording.error("camera unavailable, recording without it: \(String(describing: error), privacy: .public)")
                if case RecordingError.permissionDenied = error {
                    ToastHUD.show(.permission("Camera access is off – recording without it", pane: .camera))
                } else {
                    ToastHUD.show(.message("Camera unavailable – recording without it"))
                }
                return
            }
            bubble.attach(capture)
            self.capture = capture
        }
        guard bubble.show(recordedRect: rect) else {
            Log.recording.error("camera bubble: no display for the recorded rect")
            await capture?.stop()
            capture = nil
            return
        }
        self.bubble = bubble
    }

    // MARK: After start

    func didStart(_ handle: RecordingHandle, engine: RecordingEngine) {
        eventRect = handle.sourceRect.cgRect
        overlay?.badgeRegion = eventRect
        bubble?.updateRecordedRect(handle.sourceRect)

        if plan.writesCameraFile, bubble != nil {
            let url = handle.sessionFolder.appending(path: RawRecording.FileName.camera)
            cameraURL = url
            startCameraRecorder(url: url)
        }

        let configuration = EventRecorder.Configuration(
            sessionFolder: handle.sessionFolder,
            fps: request.options.fps,
            recordsKeystrokes: plan.recordsKeystrokes,
            keystrokeFilter: appearance.displayFilter
        )
        let recorder = EventRecorder(
            configuration: configuration,
            timeline: { await engine.timeline },
            rect: { [weak self] in self?.eventRect ?? .zero }
        )
        if let overlay {
            recorder.onClick = { [weak overlay] point, button in overlay?.showClick(at: point, button: button) }
            recorder.onKey = { [weak overlay] text in overlay?.showKeystroke(text) }
        }
        recorder.start()
        eventRecorder = recorder
        switch recorder.keystrokeState {
        case .permissionMissing:
            Log.recording.notice("keystrokes: Input Monitoring not granted; keys are off for this recording")
        case .tapFailed:
            Log.recording.error("keystrokes: the event tap couldn't start (relaunch after granting Input Monitoring)")
        case .running, .disabled:
            break
        }
    }

    private func startCameraRecorder(url: URL) {
        let recorder = CameraRecorder(outputURL: url)
        cameraRecorder = recorder
        switch cameraSource {
        case .live:
            if let capture { recorder.attach(to: capture) }
        case .pattern:
            patternFeeder?.cancel()
            patternFeeder = Task.detached(priority: .userInitiated) {
                await Self.feedPattern(to: recorder)
            }
        }
    }

    /// 30 fps test-pattern frames on the host clock until cancelled.
    nonisolated private static func feedPattern(to recorder: CameraRecorder) async {
        guard let buffer = CameraTestPattern.pixelBuffer(width: 1280, height: 720) else { return }
        while !Task.isCancelled {
            let pts = RecordingEngine.hostNow()
            if let sample = CameraTestPattern.sampleBuffer(pixelBuffer: buffer, pts: pts) {
                recorder.append(sample, hostTime: pts)
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    /// The followed window moved (Quartz global points).
    func recordedRectChanged(_ rect: GlobalRect) {
        eventRect = rect.cgRect
        overlay?.badgeRegion = eventRect
        bubble?.updateRecordedRect(rect)
    }

    /// After `engine.pause()`: `host` = the timeline's pause start.
    func didPause(at host: Double) {
        overlay?.clear()
        cameraRecorder?.pause(at: Self.cmTime(host))
    }

    /// After `engine.resume()`: `host` = the end of the pause just closed.
    func didResume(at host: Double) {
        cameraRecorder?.resume(at: Self.cmTime(host))
    }

    /// After `engine.restart()`: forget everything recorded so far.
    func didRestart() {
        overlay?.clear()
        eventRecorder?.reset()
        if let url = cameraURL {
            cameraRecorder?.cancel()
            startCameraRecorder(url: url)
        }
    }

    // MARK: Stop

    /// Stops input sources before the engine stops (no events after the stop instant).
    func stopInputs() {
        eventRecorder?.stop()
        overlay?.clear()
    }

    /// After `session.stop()`: finishes `camera.mov` (ends at `stopHost`),
    /// merges clicks / keys / cursor shapes into `events.json` with the
    /// camera offset, and fills `cameraURL` / `cursorURL`.
    func finish(_ raw: RawRecording, stopHost: CMTime) async -> RawRecording {
        var raw = raw
        patternFeeder?.cancel()
        patternFeeder = nil
        capture?.setSampleHandler(nil)
        var cameraOffset: Double?
        if let recorder = cameraRecorder {
            cameraRecorder = nil
            do {
                let summary = try await recorder.finish(at: stopHost)
                raw.cameraURL = summary.url
                if let eventsURL = raw.eventsURL,
                   let metadata = try? RecordingMetadata(jsonData: Data(contentsOf: eventsURL)) {
                    cameraOffset = summary.cameraTimeOffset(screenOrigin: metadata.hostTimeOrigin)
                }
                Log.recording.notice("camera.mov \(String(format: "%.3f", summary.duration), privacy: .public) s, \(summary.framesWritten) frames, offset \(String(format: "%.3f", cameraOffset ?? 0), privacy: .public) s")
            } catch {
                Log.recording.error("camera.mov failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let eventsURL = raw.eventsURL {
            do {
                if let recorder = eventRecorder {
                    try recorder.finish(mergingInto: eventsURL)
                }
                if let cameraOffset {
                    var metadata = try RecordingMetadata(jsonData: Data(contentsOf: eventsURL))
                    metadata.cameraTimeOffset = cameraOffset
                    try metadata.jsonData().write(to: eventsURL, options: .atomic)
                }
            } catch {
                Log.recording.error("events.json merge failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            eventRecorder?.discard()
        }
        eventRecorder = nil
        let cursorURL = raw.sessionFolder.appending(path: RawRecording.FileName.cursor)
        if FileManager.default.fileExists(atPath: cursorURL.path) { raw.cursorURL = cursorURL }
        return raw
    }

    /// Throws away `camera.mov` and the events (discard, failed start or stop).
    func discard() {
        patternFeeder?.cancel()
        patternFeeder = nil
        capture?.setSampleHandler(nil)
        cameraRecorder?.cancel()
        cameraRecorder = nil
        eventRecorder?.discard()
        eventRecorder = nil
    }

    /// Hides the bubble and the overlay, stops the camera. Safe to repeat.
    func tearDown() async {
        patternFeeder?.cancel()
        patternFeeder = nil
        eventRecorder?.stop()
        bubble?.hide()
        bubble = nil
        overlay?.close()
        overlay = nil
        if let capture {
            self.capture = nil
            capture.setSampleHandler(nil)
            await capture.stop()
        }
    }

    nonisolated static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    #if DEBUG
    /// `debug-recording-state` extras.
    var debugSummary: [String: String] {
        [
            "bubble": bubble.map { $0.isVisible ? "visible" : "hidden" } ?? "none",
            "overlay": overlay.map { $0.isVisible ? "visible" : "hidden" } ?? "none",
            "cameraFile": cameraURL?.lastPathComponent ?? "none",
            "keystrokes": eventRecorder?.keystrokeState.rawValue ?? "none",
        ]
    }
    #endif
}
