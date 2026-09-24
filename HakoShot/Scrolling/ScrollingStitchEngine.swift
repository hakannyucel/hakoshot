import CoreGraphics
import Foundation
import HakoKit
import os

/// One raw frame from the stream (or a test). `makeImage()` is called only
/// for frames the gate forwards, so the stream can keep its pixel buffer and
/// copy it lazily.
nonisolated protocol ScrollingFrame: Sendable {
    /// Arrival time, seconds on the engine's clock.
    var time: TimeInterval { get }
    var signature: FrameSignature { get }
    func makeImage() -> CGImage?
}

/// Background actor that owns the ``ScrollStitcher`` (WP6.1: one stitcher,
/// one actor) plus the stability gate and the event mapper. Frames come in
/// through ``ingest(_:)`` in order; events go out through ``events``.
actor ScrollingStitchEngine {
    nonisolated let events: AsyncStream<ScrollingSessionEvent>
    private let continuation: AsyncStream<ScrollingSessionEvent>.Continuation
    private let clock: @Sendable () -> TimeInterval

    private var stitcher: ScrollStitcher
    private var gate: FrameStabilityGate
    private var mapper = ScrollingEventMapper()
    private var latest: (any ScrollingFrame)?

    /// Frames are only stitched while capturing (after "Start").
    private(set) var isCapturing = false
    private(set) var isAutoScrolling = false
    /// Increments whenever the stitched image changes (for the preview).
    private(set) var revision = 0
    private(set) var framesSeen = 0
    private(set) var framesFed = 0

    init(
        stitcher: ScrollStitcherConfiguration,
        gate: FrameStabilityGate.Configuration = .init(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.stitcher = ScrollStitcher(configuration: stitcher)
        self.gate = FrameStabilityGate(configuration: gate)
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: ScrollingSessionEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: State

    var stitchedLength: Int { stitcher.stitchedLength }
    var stitchedPixelSize: (width: Int, height: Int) { stitcher.stitchedPixelSize }
    var axis: StitchAxis? { stitcher.axis }
    var hasBase: Bool { stitcher.acceptedFrameCount > 0 }
    var contentEnded: Bool { mapper.contentEnded }
    var limitReached: Bool { mapper.limitReached }

    func setCapturing(_ on: Bool) {
        isCapturing = on
    }

    /// Auto-scroll drives feeding itself (``feedAfterStep``); the gate stops
    /// sampling moving frames and the duplicate count restarts.
    func setAutoScrolling(_ on: Bool) {
        isAutoScrolling = on
        gate.samplesWhileMoving = !on
        mapper.resetEndDetection()
    }

    // MARK: Frames

    /// A new frame from the stream, in arrival order.
    func ingest(_ frame: any ScrollingFrame) {
        framesSeen += 1
        latest = frame
        let decision = gate.observe(frame.signature, at: frame.time)
        guard isCapturing, !isAutoScrolling, decision != .hold else { return }
        feed(frame, expectedDelta: nil)
    }

    /// Periodic check (the stream sends nothing while the screen is still).
    func tick(now: TimeInterval? = nil) {
        let time = now ?? clock()
        guard isCapturing, !isAutoScrolling, let latest else { return }
        if gate.tick(at: time) != .hold {
            feed(latest, expectedDelta: nil)
        }
    }

    /// Makes sure the image has its first frame (auto-scroll started before
    /// any manual scrolling): waits up to `timeout` for still content.
    func feedBaseIfNeeded(timeout: TimeInterval) async {
        guard !hasBase else { return }
        let deadline = clock() + timeout
        while clock() < deadline, !(latest != nil && gate.isStable(at: clock())) {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard !hasBase, let latest else { return }
        gate.markForwarded(at: clock())
        feed(latest, expectedDelta: nil)
    }

    /// Auto-scroll step: after the scroll event posted at `stepTime`, waits
    /// for content that changed after it to become stable (at most
    /// `timeout`), then feeds the latest frame with the step's expected
    /// movement. Unchanged content after the timeout is fed too, so the
    /// stitcher reports `.duplicate` (end of content).
    @discardableResult
    func feedAfterStep(stepTime: TimeInterval, expectedDelta: Int?, timeout: TimeInterval) async -> StitchEvent? {
        let deadline = stepTime + timeout
        while true {
            let now = clock()
            if gate.lastChangeTime > stepTime, gate.isStable(at: now) { break }
            if now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard let latest else { return nil }
        gate.markForwarded(at: clock())
        return feed(latest, expectedDelta: expectedDelta)
    }

    @discardableResult
    private func feed(_ frame: any ScrollingFrame, expectedDelta: Int?) -> StitchEvent? {
        guard !mapper.limitReached else { return nil }
        guard let image = frame.makeImage() else {
            Log.scrolling.error("frame could not be converted to an image")
            return nil
        }
        framesFed += 1
        let event = stitcher.append(image, expectedDelta: expectedDelta)
        switch event {
        case .started, .appended: revision += 1
        default: break
        }
        let mapped = mapper.map(event, stitchedLength: stitcher.stitchedLength, autoScrolling: isAutoScrolling)
        for item in mapped { continuation.yield(item) }
        return event
    }

    // MARK: Output

    func makeImage() -> CGImage? {
        stitcher.makeImage()
    }

    func previewImage(maxDimension: Int) -> CGImage? {
        stitcher.previewImage(maxDimension: maxDimension)
    }

    /// Latest raw frame as an image (fallback when nothing was stitched).
    func latestFrameImage() -> CGImage? {
        latest?.makeImage()
    }

    func finishEvents() {
        continuation.finish()
    }
}
