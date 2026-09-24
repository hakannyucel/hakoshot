@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import HakoKit
import Testing
@testable import HakoShot

// R4.1 / R4.2 webcam: device list logic, settings picker, CameraRecorder
// (camera.mov) with the test pattern, and the bubble window (shape mask,
// snapping, clamping, window ID, snapshot pixels). Nothing here opens a
// camera or prompts for camera access.

@Suite("Camera devices")
struct CameraDeviceListTests {
    let list = CameraDeviceList(
        devices: [
            CameraDevice(id: "builtin", name: "FaceTime HD Camera", kind: .builtIn),
            CameraDevice(id: "iphone", name: "iPhone Camera", kind: .continuity),
        ],
        defaultDeviceID: "builtin"
    )

    @Test func resolvesTheChosenDeviceOrFallsBackToTheDefault() {
        #expect(list.resolve("iphone")?.id == "iphone")
        #expect(list.resolve(nil)?.id == "builtin")
        #expect(list.resolve("")?.id == "builtin")
        #expect(list.resolve("unplugged")?.id == "builtin")
        #expect(CameraDeviceList.empty.resolve(nil) == nil)
    }

    @Test func pickerListsDefaultDevicesAndAMissingSelection() {
        let options = CameraSettingsSection.pickerOptions(devices: list, selectedID: "gone")
        #expect(options.map(\.id) == ["", "builtin", "iphone", "gone"])
        #expect(options[0].title == "Default (FaceTime HD Camera)")
        #expect(CameraSettingsSection.pickerOptions(devices: .empty, selectedID: "").map(\.title) == ["Default"])
    }

    @Test func listingDoesNotPrompt() {
        // Reading the list and the status must work without any TCC prompt.
        _ = CameraDeviceList.current()
        _ = CameraPermission.status
    }

    @Test func captureRefusesWithoutAuthorization() async {
        guard CameraPermission.status != .authorized else { return }
        await #expect(throws: RecordingError.permissionDenied(.camera)) {
            try await CameraCapture().start(deviceID: nil)
        }
    }
}

@Suite("Camera recorder", .serialized)
struct CameraRecorderTests {
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hakoshot-camera-\(UUID().uuidString).mov")
    }

    /// Feeds `count` pattern frames at 30 fps host times starting at `start`.
    static func feed(_ recorder: CameraRecorder, width: Int = 640, height: Int = 360, start: Double, count: Int) async {
        guard let buffer = CameraTestPattern.pixelBuffer(width: width, height: height) else { return }
        for index in 0..<count {
            let host = start + Double(index) / 30
            let pts = CMTime(seconds: host, preferredTimescale: 600_000)
            if let sample = CameraTestPattern.sampleBuffer(pixelBuffer: buffer, pts: pts) {
                recorder.append(sample, hostTime: pts)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    static func videoInfo(_ url: URL) async throws -> (duration: Double, size: CGSize, codec: FourCharCode?) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let format = try await track.load(.formatDescriptions).first
        return (duration, size, format.map { CMFormatDescriptionGetMediaSubType($0) })
    }

    @Test func writesH264CameraMovWithTheFirstFrameHostTime() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CameraRecorder(outputURL: url)
        await Self.feed(recorder, start: 1000, count: 45)
        let stop = CMTime(seconds: 1000 + 1.5, preferredTimescale: 600_000)
        let summary = try await recorder.finish(at: stop)
        #expect(summary.firstFrameHostTime == 1000)
        #expect(abs(summary.duration - 1.5) < 0.05)
        #expect(summary.pixelSize == CGSize(width: 640, height: 360))
        #expect(summary.framesWritten > 30)
        let info = try await Self.videoInfo(url)
        #expect(abs(info.duration - 1.5) < 0.1)
        #expect(info.size == CGSize(width: 640, height: 360))
        #expect(info.codec == kCMVideoCodecType_H264)
        // Screen started 0.2 s after the camera → camera time = screen time + 0.2.
        #expect(abs(summary.cameraTimeOffset(screenOrigin: 1000.2) - 0.2) < 1e-9)
    }

    @Test func capsTheResolutionAt1080p() async throws {
        #expect(CameraRecorder.outputSize(width: 3840, height: 2160, cap: .p1080) == (1920, 1080))
        #expect(CameraRecorder.outputSize(width: 1280, height: 720, cap: .p1080) == (1280, 720))
        #expect(CameraRecorder.outputSize(width: 1080, height: 1920, cap: .p1080) == (1080, 1920))

        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CameraRecorder(outputURL: url)
        await Self.feed(recorder, width: 2560, height: 1440, start: 50, count: 10)
        let summary = try await recorder.finish()
        #expect(summary.pixelSize == CGSize(width: 1920, height: 1080))
        let info = try await Self.videoInfo(url)
        #expect(info.size == CGSize(width: 1920, height: 1080))
    }

    @Test func pauseRemovesTheSameHostRangeAsTheScreen() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CameraRecorder(outputURL: url)
        // Frames 0…2 s; paused 0.5…1.2 s host.
        let pauseStart = 2000.5, pauseEnd = 2001.2
        guard let buffer = CameraTestPattern.pixelBuffer(width: 320, height: 180) else { Issue.record("no buffer"); return }
        for index in 0..<60 {
            let host = 2000 + Double(index) / 30
            let pts = CMTime(seconds: host, preferredTimescale: 600_000)
            if index == 15 { recorder.pause(at: CMTime(seconds: pauseStart, preferredTimescale: 600_000)) }
            if index == 36 { recorder.resume(at: CMTime(seconds: pauseEnd, preferredTimescale: 600_000)) }
            if let sample = CameraTestPattern.sampleBuffer(pixelBuffer: buffer, pts: pts) { recorder.append(sample, hostTime: pts) }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let summary = try await recorder.finish(at: CMTime(seconds: 2002, preferredTimescale: 600_000))
        #expect(abs(summary.duration - 1.3) < 0.05)
        #expect(summary.pauses.count == 1)
        let info = try await Self.videoInfo(url)
        #expect(abs(info.duration - 1.3) < 0.1)
    }

    @Test func finishWithoutFramesThrowsNoFramesAndLeavesNoFile() async {
        let url = Self.tempURL()
        let recorder = CameraRecorder(outputURL: url)
        await #expect(throws: RecordingError.noFrames) { try await recorder.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
@Suite("Webcam bubble", .serialized)
struct WebcamBubbleTests {
    /// A recorded rect on the main screen (AppKit coordinates).
    static var recordedRect: CGRect {
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 800, height: 500)
    }

    static func makeBubble(_ options: CameraOptions = CameraOptions()) -> WebcamBubbleWindow {
        let bubble = WebcamBubbleWindow(options: options)
        bubble.showStill(CameraTestPattern.image())
        bubble.show(appKitRecordedRect: recordedRect)
        return bubble
    }

    @Test func showsBottomRightWithMarginAndExposesAWindowID() {
        let bubble = Self.makeBubble()
        defer { bubble.hide() }
        let rect = Self.recordedRect
        let margin = Tokens.Recording.cameraMargin
        let side = Tokens.Recording.cameraSize(.medium)
        #expect(bubble.bubbleFrame == CGRect(x: rect.maxX - margin - side, y: rect.minY + margin, width: side, height: side))
        #expect(bubble.windowID != nil)
        #expect(bubble.isVisible)
        // The window adds shadow padding around the bubble.
        #expect(bubble.panel.frame == bubble.bubbleFrame.insetBy(dx: -bubble.shadowPadding, dy: -bubble.shadowPadding))
        #expect(!bubble.panel.canBecomeKey)
    }

    @Test func shapesAndSizes() {
        let bubble = Self.makeBubble(CameraOptions(shape: .vertical, size: .small))
        defer { bubble.hide() }
        #expect(bubble.bubbleFrame.size == CGSize(width: 140, height: (140 * 16.0 / 9.0).rounded()))
        bubble.setOptions(CameraOptions(shape: .rectangle, size: .large))
        #expect(bubble.bubbleFrame.size == CGSize(width: (240 * 16.0 / 9.0).rounded(), height: 240))
        #expect(bubble.bubbleView.cornerRadius == Tokens.Recording.cameraRectangleCornerRadius)
        bubble.setOptions(CameraOptions(shape: .circle, size: .medium))
        #expect(bubble.bubbleView.cornerRadius == 90)
    }

    @Test func dragIsClampedAndSnapsToTheNearestCorner() {
        let bubble = Self.makeBubble()
        defer { bubble.hide() }
        var reported: CameraCorner?
        bubble.onCornerChange = { reported = $0 }
        let rect = Self.recordedRect

        // Way past the bottom-right edge: stays inside the recorded rect.
        bubble.beginDrag(at: CGPoint(x: 0, y: 0))
        bubble.drag(to: CGPoint(x: 5000, y: -5000))
        #expect(rect.contains(bubble.bubbleFrame))
        #expect(bubble.bubbleFrame.maxX == rect.maxX)
        #expect(bubble.bubbleFrame.minY == rect.minY)

        // Into the top-left quadrant (AppKit: high y), then release.
        bubble.drag(to: CGPoint(x: -5000, y: 5000))
        #expect(rect.contains(bubble.bubbleFrame))
        bubble.endDrag(animated: false)
        let margin = Tokens.Recording.cameraMargin
        #expect(bubble.corner == .topLeft)
        #expect(reported == .topLeft)
        #expect(bubble.bubbleFrame.minX == rect.minX + margin)
        #expect(bubble.bubbleFrame.maxY == rect.maxY - margin)
    }

    @Test func doubleClickFullscreenFillsTheRecordedRect() {
        let bubble = Self.makeBubble()
        defer { bubble.hide() }
        bubble.toggleFullscreen()
        #expect(bubble.isFullscreen)
        #expect(bubble.bubbleFrame == Self.recordedRect)
        #expect(bubble.panel.frame == Self.recordedRect)
        // No dragging in fullscreen.
        bubble.beginDrag(at: .zero)
        bubble.drag(to: CGPoint(x: 100, y: 100))
        #expect(bubble.bubbleFrame == Self.recordedRect)
        bubble.toggleFullscreen()
        #expect(bubble.corner == .bottomRight)
        #expect(bubble.bubbleFrame.size == CGSize(width: 180, height: 180))
    }

    // MARK: Snapshot pixels

    /// sRGB components; display color management shifts pure bars a little
    /// (magenta's green reads ≈ 0.31), hence the loose thresholds.
    struct Pixel { var r, g, b, a: Double }

    /// sRGB pixel at a point in the bubble (bubble-rect fractions, y down).
    static func pixel(_ rep: NSBitmapImageRep, bubble: WebcamBubbleWindow, fx: Double, fy: Double) -> Pixel? {
        let scale = Double(rep.pixelsWide) / Double(bubble.bubbleView.bounds.width)
        let pad = Double(bubble.shadowPadding)
        let x = Int(((pad + fx * bubble.bubbleFrame.width) * scale).rounded(.down))
        let y = Int(((pad + fy * bubble.bubbleFrame.height) * scale).rounded(.down))
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return Pixel(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: color.alphaComponent)
    }

    static func isGreen(_ p: Pixel?) -> Bool { guard let p else { return false }; return p.g > 0.8 && p.r < 0.5 && p.b < 0.5 }
    static func isMagenta(_ p: Pixel?) -> Bool { guard let p else { return false }; return p.r > 0.8 && p.b > 0.8 && p.g < 0.5 }

    @Test func testPatternSnapshotIsMaskedAndMirrored() throws {
        let bubble = Self.makeBubble(CameraOptions(shape: .squircle))
        defer { bubble.hide() }
        let rep = try #require(bubble.snapshot())
        // Square bubble aspect-fills the 16:9 pattern: 0.3 → green bar, 0.7 → magenta bar.
        #expect(Self.isGreen(Self.pixel(rep, bubble: bubble, fx: 0.3, fy: 0.4)))
        #expect(Self.isMagenta(Self.pixel(rep, bubble: bubble, fx: 0.7, fy: 0.4)))
        #expect((Self.pixel(rep, bubble: bubble, fx: 0.5, fy: 0.4)?.a ?? 0) > 0.99)
        // Squircle corner is cut (only faint shadow there).
        #expect((Self.pixel(rep, bubble: bubble, fx: 0.01, fy: 0.01)?.a ?? 1) < 0.3)

        bubble.setOptions(CameraOptions(shape: .squircle, mirrored: true))
        let mirrored = try #require(bubble.snapshot())
        #expect(Self.isMagenta(Self.pixel(mirrored, bubble: bubble, fx: 0.3, fy: 0.4)))
        #expect(Self.isGreen(Self.pixel(mirrored, bubble: bubble, fx: 0.7, fy: 0.4)))
    }

    @Test func circleMaskCutsDeeperThanSquircle() throws {
        let bubble = Self.makeBubble(CameraOptions(shape: .circle))
        defer { bubble.hide() }
        let circle = try #require(bubble.snapshot())
        // 45° point at ~10 % in: outside the circle, inside the squircle.
        #expect((Self.pixel(circle, bubble: bubble, fx: 0.1, fy: 0.1)?.a ?? 1) < 0.3)
        bubble.setOptions(CameraOptions(shape: .squircle))
        let squircle = try #require(bubble.snapshot())
        #expect((Self.pixel(squircle, bubble: bubble, fx: 0.1, fy: 0.1)?.a ?? 0) > 0.99)
    }

    @Test func hitTestingFollowsTheMask() {
        let bubble = Self.makeBubble(CameraOptions(shape: .circle))
        defer { bubble.hide() }
        let view = bubble.bubbleView
        let pad = bubble.shadowPadding
        let center = CGPoint(x: pad + bubble.bubbleFrame.width / 2, y: pad + bubble.bubbleFrame.height / 2)
        #expect(view.hitTest(view.convert(center, to: view.superview)) === view)
        let corner = CGPoint(x: pad + 2, y: pad + 2)
        #expect(view.hitTest(view.convert(corner, to: view.superview)) == nil)
    }
}

#if DEBUG
@MainActor
@Suite("Camera debug", .serialized)
struct CameraDebugTests {
    @Test func recordCameraPatternWritesMovAndJSON() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hakoshot-camdebug-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appending(path: "camera.mov")
        let parameters = try #require(CameraDebug.RecordParameters(queryItems: [
            URLQueryItem(name: "seconds", value: "1"), URLQueryItem(name: "out", value: out.path),
            URLQueryItem(name: "source", value: "pattern"),
        ]))
        let result = await CameraDebug.recordCamera(parameters)
        #expect(result["error"] == nil)
        #expect(abs((result["duration"] as? Double ?? 0) - 1.0) < 0.2)
        #expect(result["width"] as? Int == 1280)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathExtension("json").path))
    }

    @Test func recordCameraWithoutAuthorizationReportsPermissionDenied() async throws {
        guard CameraPermission.status != .authorized else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "hakoshot-camdebug-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let parameters = try #require(CameraDebug.RecordParameters(queryItems: [
            URLQueryItem(name: "seconds", value: "0.5"), URLQueryItem(name: "out", value: dir.appending(path: "c.mov").path),
        ]))
        let result = await CameraDebug.recordCamera(parameters)
        #expect(result["error"] as? String == "permissionDenied")
    }

    @Test func bubbleSnapshotUsesThePattern() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hakoshot-camdebug-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "bubble.png")
        let parameters = CameraDebug.BubbleParameters(queryItems: [
            URLQueryItem(name: "shape", value: "circle"), URLQueryItem(name: "size", value: "large"),
            URLQueryItem(name: "pattern", value: "1"), URLQueryItem(name: "snapshot", value: png.path),
        ])
        #expect(parameters.options.shape == .circle)
        #expect(parameters.options.size == .large)
        let result = await CameraDebug.showBubble(parameters)
        #expect(result["source"] as? String == "pattern")
        #expect((result["windowID"] as? Int ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: png.path))
        let frame = try #require(result["bubbleFrame"] as? [Double])
        #expect(frame[2] == 240 && frame[3] == 240)
    }
}
#endif
