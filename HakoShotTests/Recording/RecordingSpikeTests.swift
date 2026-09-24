import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
@preconcurrency import ScreenCaptureKit
import Testing
@testable import HakoShot

/// R0.2 spikes on the real screen (results in `reports/kayit-spike-notlari.md`).
/// Opt-in: set `HAKO_RECORDING_SPIKES=1` (xcodebuild: `TEST_RUNNER_HAKO_RECORDING_SPIKES=1`);
/// skipped while the screen is locked or without Screen Recording permission.
/// Recordings contain the user's screen: only pixel values / numbers are
/// checked and every file is deleted.
@Suite("Recording spikes", .serialized)
struct RecordingSpikeTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["HAKO_RECORDING_SPIKES"] == "1"
        && ScreenAvailability.isUsable

    /// Spike 3: an `exceptingWindows` window of our own app is recorded, a
    /// window that isn't excepted is not.
    /// With `scaleTo1x` the stream scales the source rect down
    /// (`scalesToFit`); the window must land at the same point position.
    @Test(.enabled(if: enabled, "opt-in spike (HAKO_RECORDING_SPIKES=1) needs an unlocked screen"), .timeLimit(.minutes(1)),
          arguments: [false, true])
    func exceptedWindowAppearsInRecording(scaleTo1x: Bool) async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DisplayLayoutProvider.currentLayout()
        let main = try #require(layout.mainDisplay)
        let rect = GlobalRect(x: 100, y: 100, width: 640, height: 360)
        let green = Self.colorWindow(.init(srgbRed: 0, green: 1, blue: 0, alpha: 1), global: GlobalRect(x: 200, y: 150, width: 100, height: 100), layout: layout)
        let red = Self.colorWindow(.init(srgbRed: 1, green: 0, blue: 0, alpha: 1), global: GlobalRect(x: 500, y: 150, width: 100, height: 100), layout: layout)
        defer { green.close(); red.close() }
        try await Task.sleep(for: .milliseconds(500))

        let engine = RecordingEngine(sessionsRoot: root)
        var options = RecordingOptions.default
        options.scaleTo1x = scaleTo1x
        let request = RecordingRequest(target: .area(rect, displayID: main.id), options: options, source: .screen)
        _ = try await engine.start(request, overlayWindowIDs: [CGWindowID(green.windowNumber)])
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(1))
        let raw = try await engine.stop()

        let scale = scaleTo1x ? 1 : main.backingScaleFactor
        let image = try await Self.frame(raw.screenURL, at: 0.5)
        let greenPixel = try #require(Self.pixel(image, x: Int(150 * scale), y: Int(100 * scale)))
        let redPixel = try #require(Self.pixel(image, x: Int(450 * scale), y: Int(100 * scale)))
        Self.log("spike3 scaleTo1x=\(scaleTo1x) excepted(green) pixel \(greenPixel), not excepted(red) pixel \(redPixel), frame \(image.width)x\(image.height)")
        #expect(greenPixel.g > 150 && greenPixel.r < 100 && greenPixel.b < 100, "excepted window missing: \(greenPixel)")
        #expect(!(redPixel.r > 150 && redPixel.g < 100 && redPixel.b < 100), "excluded window recorded: \(redPixel)")
    }

    /// Spike 2: SCRecordingOutput vs `RecordingWriter`, same rect, 5 s each,
    /// with an animated (excepted) window so the content changes every frame.
    @Test(.enabled(if: enabled, "opt-in spike (HAKO_RECORDING_SPIKES=1) needs an unlocked screen"), .timeLimit(.minutes(2)))
    func recordingOutputVersusWriter() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DisplayLayoutProvider.currentLayout()
        let main = try #require(layout.mainDisplay)
        let rect = GlobalRect(x: 0, y: 0, width: 1280, height: 720)
        let window = Self.animatedWindow(global: rect, layout: layout)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let seconds = 5.0

        // Our writer (H.264, High, 60 fps).
        let engine = RecordingEngine(sessionsRoot: root)
        let cpu0 = Self.cpuSeconds()
        _ = try await engine.start(
            RecordingRequest(target: .area(rect, displayID: main.id), source: .screen),
            overlayWindowIDs: [CGWindowID(window.windowNumber)]
        )
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(seconds))
        let stats = await engine.stats
        let raw = try await engine.stop()
        let writerCPU = Self.cpuSeconds() - cpu0
        let writerSize = Self.fileSize(raw.screenURL)
        let writerInfo = try await RecordingEngineTests.inspect(raw.screenURL)

        // SCRecordingOutput (H.264 .mov), same filter and configuration.
        let content = try await ContentFilterBuilder.fetchContent()
        let filter = try ContentFilterBuilder.makeFilter(
            .init(displayID: main.id, exceptedWindowIDs: [CGWindowID(window.windowNumber)]), content: content
        )
        let plan = RecordingGeometry.plan(pointSize: rect.size, backingScale: Double(main.backingScaleFactor))
        let config = ScreenStreamSource.makeConfiguration(RecordingSourceConfiguration(
            target: .area(rect, displayID: main.id), displayID: main.id,
            sourceRect: CGRect(origin: .zero, size: rect.size), pixelSize: plan.pixelSize, fps: 60, showsCursor: true
        ))
        let outputURL = root.appending(path: "screcording.mov")
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = outputURL
        outputConfig.videoCodecType = .h264
        outputConfig.outputFileType = .mov
        let delegate = RecordingOutputDelegate()
        let output = SCRecordingOutput(configuration: outputConfig, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(output)
        let cpu1 = Self.cpuSeconds()
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        for _ in 0..<50 where !delegate.finished { try await Task.sleep(for: .milliseconds(100)) }
        let outputCPU = Self.cpuSeconds() - cpu1
        let outputSize = Self.fileSize(outputURL)
        let outputInfo = try await RecordingEngineTests.inspect(outputURL)

        Self.log(String(
            format: "spike2 writer: %.2f s cpu, %d bytes, %.2f s, %d frames written, %d dropped, %@ %dx%d | SCRecordingOutput: %.2f s cpu, %d bytes, %.2f s, %@ %dx%d, finished %@",
            writerCPU, writerSize, writerInfo.duration, stats.framesWritten, stats.droppedFrames, writerInfo.codec,
            Int(writerInfo.size.width), Int(writerInfo.size.height),
            outputCPU, outputSize, outputInfo.duration, outputInfo.codec, Int(outputInfo.size.width), Int(outputInfo.size.height),
            delegate.finished ? "yes" : "no"
        ))
        #expect(writerSize > 0 && outputSize > 0)
    }

    // MARK: Helpers

    static func log(_ line: String) {
        print(line)
        if let dir = ProcessInfo.processInfo.environment["HAKO_RECORDING_SPIKE_LOG"] {
            let url = URL(fileURLWithPath: dir)
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func colorWindow(_ color: NSColor, global: GlobalRect, layout: DisplayLayout) -> NSWindow {
        let frame = ScreenGeometry.appKitRect(fromGlobal: global, layout: layout) ?? .zero
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }

    /// A window with a white square sliding across a black background.
    static func animatedWindow(global: GlobalRect, layout: DisplayLayout) -> NSWindow {
        let window = colorWindow(.black, global: global, layout: layout)
        let view = NSView(frame: NSRect(origin: .zero, size: global.size))
        view.wantsLayer = true
        let square = CALayer()
        square.backgroundColor = NSColor.white.cgColor
        square.frame = CGRect(x: 0, y: global.height / 2 - 60, width: 120, height: 120)
        view.layer?.addSublayer(square)
        window.contentView = view
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = 60
        animation.toValue = global.width - 60
        animation.duration = 1
        animation.autoreverses = true
        animation.repeatCount = .infinity
        square.add(animation, forKey: "slide")
        return window
    }

    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    struct RGB: CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGB? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Draw so that (x, y) (top-left origin) lands on the single pixel.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return RGB(r: Int(data[0]), g: Int(data[1]), b: Int(data[2]))
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }
}

private nonisolated final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    var finished: Bool { lock.withLock { isFinished } }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { isFinished = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        print("SCRecordingOutput failed: \(error.localizedDescription)")
        lock.withLock { isFinished = true }
    }
}
