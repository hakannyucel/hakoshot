import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Synthetic tall "page": every row has its own pseudo-random pattern of
/// 8-pixel blocks, so any window of it matches at exactly one offset.
enum ScrollingFixture {
    static func page(width: Int, height: Int, seed: UInt64 = 7) -> CGImage? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            var state = seed &+ UInt64(y) &* 0x9E37_79B9_7F4A_7C15
            for block in 0..<(width / 8) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = UInt8(truncatingIfNeeded: state >> 56)
                for x in (block * 8)..<min(width, block * 8 + 8) {
                    let i = y * bytesPerRow + x * 4
                    pixels[i] = value
                    pixels[i + 1] = value &+ 40
                    pixels[i + 2] = value &+ 90
                    pixels[i + 3] = 255
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The part of `page` visible when scrolled to `offset`.
    static func window(of page: CGImage, offset: Int, height: Int) -> CGImage? {
        page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: height))
    }
}

/// A frame made from a `CGImage` (what the stream frames look like to the engine).
struct FakeFrame: ScrollingFrame {
    let image: CGImage
    let time: TimeInterval
    let signature: FrameSignature

    init(_ image: CGImage, time: TimeInterval) {
        self.image = image
        self.time = time
        signature = FrameSignature.compute(image: image)
    }

    func makeImage() -> CGImage? { image }
}

@Suite("Scrolling: frame signature")
struct FrameSignatureTests {
    @Test func identicalFramesMatchAndScrolledFramesDiffer() throws {
        let page = try #require(ScrollingFixture.page(width: 160, height: 800))
        let a = try #require(ScrollingFixture.window(of: page, offset: 0, height: 300))
        let b = try #require(ScrollingFixture.window(of: page, offset: 0, height: 300))
        let moved = try #require(ScrollingFixture.window(of: page, offset: 3, height: 300))
        let sa = FrameSignature.compute(image: a)
        #expect(sa.rowHashes.count == 300)
        #expect(sa.differenceFraction(from: FrameSignature.compute(image: b)) == 0)
        #expect(sa.differenceFraction(from: FrameSignature.compute(image: moved)) > 0.9)
    }

    @Test func rowSamplingIsCapped() throws {
        let page = try #require(ScrollingFixture.page(width: 64, height: 2_000))
        let signature = FrameSignature.compute(image: page)
        #expect(signature.rowHashes.count <= FrameSignature.maximumSampledRows)
        #expect(signature.rowHashes.count >= FrameSignature.maximumSampledRows / 2)
    }

    @Test func trailingInsetIgnoresScrollBarStrip() {
        let width = 64, height = 10
        let a = [UInt32](repeating: 0x00FF_FFFF, count: width * height)
        var b = a
        for y in 0..<height { b[y * width + width - 2] = 0x0000_0000 } // "scroll bar" appears
        func signature(_ pixels: [UInt32], inset: Int) -> FrameSignature {
            pixels.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return FrameSignature(rowHashes: []) }
                return FrameSignature.compute(base: base, width: width, height: height, bytesPerRow: width * 4, trailingInset: inset)
            }
        }
        let sa = signature(a, inset: 4)
        let sb = signature(b, inset: 4)
        let sbFull = signature(b, inset: 0)
        #expect(sa == sb)
        #expect(sa != sbFull)
    }

    @Test func differentSizesNeverMatch() {
        let a = FrameSignature(rowHashes: [1, 2, 3])
        #expect(a.differenceFraction(from: FrameSignature(rowHashes: [1, 2])) == 1)
        #expect(FrameSignature(rowHashes: [1, 2, 3, 4]).differenceFraction(from: FrameSignature(rowHashes: [1, 2, 3, 5])) == 0.25)
    }
}

@Suite("Scrolling: stability gate")
struct FrameStabilityGateTests {
    private func signature(_ value: UInt64, rows: Int = 100) -> FrameSignature {
        FrameSignature(rowHashes: (0..<rows).map { UInt64($0) &* 31 &+ value })
    }

    @Test func stillContentIsForwardedOnce() {
        var gate = FrameStabilityGate()
        #expect(gate.observe(signature(1), at: 0) == .hold)
        #expect(gate.tick(at: 0.05) == .hold)
        #expect(gate.observe(signature(1), at: 0.083) == .hold)
        #expect(gate.tick(at: 0.13) == .forwardStable)
        #expect(gate.tick(at: 0.5) == .hold)
        #expect(gate.observe(signature(1), at: 0.6) == .hold)
    }

    @Test func movingContentIsSampledThenStableFrameForwarded() {
        var gate = FrameStabilityGate()
        _ = gate.observe(signature(1), at: 0)
        #expect(gate.tick(at: 0.2) == .forwardStable)
        // User scrolls continuously: a new frame every 1/12 s.
        #expect(gate.observe(signature(2), at: 0.40) == .forwardMoving)
        #expect(gate.observe(signature(3), at: 0.483) == .hold)
        #expect(gate.observe(signature(4), at: 0.566) == .hold)
        #expect(gate.observe(signature(5), at: 0.65) == .forwardMoving)
        // Last movement, then scrolling stops: the settled frame goes through once.
        #expect(gate.observe(signature(6), at: 0.733) == .hold)
        #expect(gate.tick(at: 0.80) == .hold)
        #expect(gate.tick(at: 0.86) == .forwardStable)
        #expect(gate.tick(at: 0.95) == .hold)
        // Content that was already sent as a moving sample is not sent again.
        #expect(gate.observe(signature(7), at: 1.2) == .forwardMoving)
        #expect(gate.tick(at: 1.5) == .hold)
    }

    @Test func autoScrollModeOnlyForwardsStableFrames() {
        var gate = FrameStabilityGate()
        gate.samplesWhileMoving = false
        _ = gate.observe(signature(1), at: 0)
        #expect(gate.tick(at: 0.2) == .forwardStable)
        #expect(gate.observe(signature(2), at: 0.5) == .hold)
        #expect(gate.observe(signature(3), at: 0.9) == .hold)
        #expect(gate.lastChangeTime == 0.9)
        #expect(!gate.isStable(at: 0.95))
        #expect(gate.isStable(at: 1.02))
        #expect(gate.tick(at: 1.02) == .forwardStable)
    }

    @Test func smallChangesLikeACaretDoNotCountAsMovement() {
        var gate = FrameStabilityGate()
        let base = signature(1)
        var caret = base
        caret.rowHashes[40] = 999 // 1 % of rows changed
        _ = gate.observe(base, at: 0)
        #expect(gate.observe(caret, at: 0.083) == .hold)
        #expect(gate.lastChangeTime == 0)
        #expect(gate.tick(at: 0.13) == .forwardStable)
    }
}

@Suite("Scrolling: event mapping")
struct ScrollingEventMapperTests {
    private func step(_ total: Int) -> StitchEvent {
        .appended(StitchStep(offset: 100, addedLength: 100, totalLength: total, confidence: 1, ambiguous: false, axis: .vertical))
    }

    @Test func threeDuplicatesDuringAutoScrollEndTheContent() {
        var mapper = ScrollingEventMapper()
        #expect(mapper.map(.started, stitchedLength: 400, autoScrolling: true) == [.started(length: 400)])
        #expect(mapper.map(.duplicate, stitchedLength: 400, autoScrolling: true).isEmpty)
        #expect(mapper.map(.duplicate, stitchedLength: 400, autoScrolling: true).isEmpty)
        #expect(mapper.map(step(500), stitchedLength: 500, autoScrolling: true) == [.progress(length: 500)])
        #expect(mapper.map(.duplicate, stitchedLength: 500, autoScrolling: true).isEmpty)
        #expect(mapper.map(.duplicate, stitchedLength: 500, autoScrolling: true).isEmpty)
        #expect(mapper.map(.duplicate, stitchedLength: 500, autoScrolling: true) == [.contentEnded])
        #expect(mapper.map(.duplicate, stitchedLength: 500, autoScrolling: true).isEmpty)
        #expect(mapper.contentEnded)
        mapper.resetEndDetection()
        #expect(!mapper.contentEnded)
        #expect(mapper.consecutiveDuplicates == 0)
    }

    @Test func manualDuplicatesNeverEnd() {
        var mapper = ScrollingEventMapper()
        for _ in 0..<10 {
            #expect(mapper.map(.duplicate, stitchedLength: 400, autoScrolling: false).isEmpty)
        }
        #expect(!mapper.contentEnded)
    }

    @Test func slowDownShowsOnceAndHidesOnProgress() {
        var mapper = ScrollingEventMapper()
        #expect(mapper.map(.rejected(.tooFast), stitchedLength: 400, autoScrolling: false) == [.slowDown(true)])
        #expect(mapper.map(.rejected(.tooFast), stitchedLength: 400, autoScrolling: false).isEmpty)
        #expect(mapper.map(.rejected(.backward(offset: 20)), stitchedLength: 400, autoScrolling: false).isEmpty)
        #expect(mapper.map(step(600), stitchedLength: 600, autoScrolling: false) == [.slowDown(false), .progress(length: 600)])
    }

    @Test func limitIsReportedOnce() {
        var mapper = ScrollingEventMapper()
        #expect(mapper.map(.limitReached(totalLength: 32_000), stitchedLength: 32_000, autoScrolling: true) == [.limitReached(length: 32_000)])
        #expect(mapper.map(.limitReached(totalLength: 32_000), stitchedLength: 32_000, autoScrolling: true).isEmpty)
    }
}

@Suite("Scrolling: engine with fake frames")
struct ScrollingStitchEngineTests {
    private func configuration() -> ScrollStitcherConfiguration {
        var config = ScrollStitcherConfiguration()
        config.scrollBarInset = 0
        return config
    }

    @Test func manualScrollingStitchesTheWholePage() async throws {
        let page = try #require(ScrollingFixture.page(width: 160, height: 1_200))
        let engine = ScrollingStitchEngine(stitcher: configuration(), clock: { 0 })
        await engine.setCapturing(true)
        var time: TimeInterval = 0
        // Scroll 90 px per burst; each burst: 3 moving frames, then it settles.
        for offset in stride(from: 0, through: 780, by: 30) {
            let frame = try #require(ScrollingFixture.window(of: page, offset: offset, height: 400))
            await engine.ingest(FakeFrame(frame, time: time))
            time += 1.0 / 12.0
            if offset % 90 == 0 {
                await engine.tick(now: time + 0.2)
                time += 0.3
            }
        }
        await engine.tick(now: time + 0.5)
        let image = try #require(await engine.makeImage())
        #expect(image.width == 160)
        #expect(image.height == 780 + 400)
        #expect(await engine.revision > 3)
        let fed = await engine.framesFed
        let seen = await engine.framesSeen
        #expect(fed < seen)
    }

    @Test func nothingIsStitchedBeforeCapturing() async throws {
        let page = try #require(ScrollingFixture.page(width: 64, height: 300))
        let engine = ScrollingStitchEngine(stitcher: configuration(), clock: { 0 })
        let frame = try #require(ScrollingFixture.window(of: page, offset: 0, height: 200))
        await engine.ingest(FakeFrame(frame, time: 0))
        await engine.tick(now: 1)
        #expect(await engine.hasBase == false)
        #expect(await engine.latestFrameImage() != nil)
    }

    @Test func autoScrollStepsStitchAndDetectTheEnd() async throws {
        let page = try #require(ScrollingFixture.page(width: 128, height: 700))
        let start = ProcessInfo.processInfo.systemUptime
        let engine = ScrollingStitchEngine(
            stitcher: configuration(),
            gate: .init(stableInterval: 0.02)
        )
        await engine.setCapturing(true)
        await engine.setAutoScrolling(true)
        await engine.ingest(FakeFrame(try #require(ScrollingFixture.window(of: page, offset: 0, height: 300)), time: start - 1))
        await engine.feedBaseIfNeeded(timeout: 0.2)
        #expect(await engine.hasBase)

        // Four steps of 100 px reach the bottom (offset 400 = 700 - 300).
        for offset in [100, 200, 300, 400] {
            let stepTime = ProcessInfo.processInfo.systemUptime
            let frame = try #require(ScrollingFixture.window(of: page, offset: offset, height: 300))
            await engine.ingest(FakeFrame(frame, time: stepTime + 0.001))
            let event = await engine.feedAfterStep(stepTime: stepTime, expectedDelta: 100, timeout: 0.3)
            guard case .appended(let step)? = event else {
                Issue.record("step to \(offset): \(String(describing: event))")
                return
            }
            #expect(step.offset == 100)
        }
        // At the end nothing moves: three timed-out steps are duplicates.
        for _ in 0..<3 {
            let event = await engine.feedAfterStep(
                stepTime: ProcessInfo.processInfo.systemUptime, expectedDelta: 100, timeout: 0.03
            )
            #expect(event == .duplicate)
        }
        #expect(await engine.contentEnded)
        let image = try #require(await engine.makeImage())
        #expect(image.height == 700)

        await engine.finishEvents()
        var received: [ScrollingSessionEvent] = []
        for await event in engine.events { received.append(event) }
        #expect(received.first == .started(length: 300))
        #expect(received.contains(.progress(length: 700)))
        #expect(received.last == .contentEnded)
    }
}

@Suite("Scrolling: helpers")
struct ScrollingHelperTests {
    @Test func autoScrollStepIsAFractionOfTheSelection() {
        let rect = GlobalRect(x: 0, y: 0, width: 400, height: 600)
        #expect(AutoScroller.stepPoints(for: rect, axis: .vertical, speed: .normal) == 210)
        #expect(AutoScroller.stepPoints(for: rect, axis: .horizontal, speed: .slow) == 80)
        #expect(AutoScroller.stepPoints(for: GlobalRect(x: 0, y: 0, width: 1, height: 1), axis: .vertical, speed: .slow) == 1)
    }

    @Test func sideButtonSitsOutsideOrInsideTheRightEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let roomy = ScrollingOverlayLayout(screen: screen, selection: CGRect(x: 100, y: 100, width: 400, height: 400))
        #expect(roomy.sideButtonCenter.x > 500)
        #expect(roomy.sideButtonCenter.y == 300)
        let tight = ScrollingOverlayLayout(screen: screen, selection: CGRect(x: 600, y: 100, width: 395, height: 400))
        #expect(tight.sideButtonCenter.x < 995)
    }

    @Test func thumbnailKeepsAspect() {
        let size = ScrollingOverlayLayout.fittedThumbnailSize(pixelSize: CGSize(width: 800, height: 8_000), maxSize: CGSize(width: 150, height: 400))
        #expect(size == CGSize(width: 40, height: 400))
        #expect(ScrollingOverlayLayout.fittedThumbnailSize(pixelSize: .zero, maxSize: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test func settingsDefaults() {
        let defaults = UserDefaults(suiteName: "ScrollingSettingsTests-\(UUID().uuidString)") ?? .standard
        let options = AppSettings(defaults: defaults).scrollingOptions
        #expect(options == ScrollingOptions())
        #expect(options.maximumLength == 32_000)
        #expect(options.autoScrollSpeed == .normal)
    }

    #if DEBUG
    @Test func debugRectParsing() {
        #expect(ScrollingCaptureDebug.parseRect("10,20,300,400") == GlobalRect(x: 10, y: 20, width: 300, height: 400))
        #expect(ScrollingCaptureDebug.parseRect("10,20,0,400") == nil)
        #expect(ScrollingCaptureDebug.parseRect("nope") == nil)
    }
    #endif
}
