import AppKit
import CoreGraphics
import HakoKit
import os

/// One scrolling capture (plan §4.8): an `SCStream` on the selection feeds
/// a background ``ScrollingStitchEngine`` (stability gate → `ScrollStitcher`);
/// events come back on the main actor through ``onEvent``. Manual scrolling
/// works as soon as ``start()`` returns; ``startAutoScroll(axis:)`` drives
/// the content with synthetic wheel events.
///
/// Lifecycle: `start()` → (scrolling) → `finish()` or `cancel()`. After a
/// `.contentEnded` / `.limitReached` event the owner decides (the flow
/// finishes).
final class ScrollingCaptureSession {
    nonisolated enum AutoScrollStart: Sendable, Equatable {
        case started
        /// Posting events is not allowed; the user scrolls by hand.
        case permissionMissing
        case alreadyRunning
        case notCapturing
    }

    /// Selection, Quartz global points (clamped to one display).
    let rect: GlobalRect
    let displayID: CGDirectDisplayID
    /// Pixels per point of the captured display.
    let scale: CGFloat
    let options: ScrollingOptions

    /// Main actor; stitching events and auto-scroll state changes.
    var onEvent: (ScrollingSessionEvent) -> Void = { _ in }
    var onAutoScrollChanged: (Bool) -> Void = { _ in }
    /// The stream died (display unplugged, permission revoked).
    var onStreamStopped: (String) -> Void = { _ in }

    private let engine: ScrollingStitchEngine
    private var source: ScrollingFrameSource?
    private var frameContinuation: AsyncStream<PixelBufferFrame>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var autoScrollTask: Task<Void, Never>?
    private var inputMonitor: Any?
    private(set) var isCapturing = false
    private(set) var isAutoScrolling = false
    private var isClosed = false

    /// `rect` must lie on `displayID` (see ``make(rect:options:)``).
    init(rect: GlobalRect, displayID: CGDirectDisplayID, scale: CGFloat, options: ScrollingOptions) {
        self.rect = rect
        self.displayID = displayID
        self.scale = scale
        self.options = options
        var configuration = ScrollStitcherConfiguration()
        // WP6.1: ignore the overlay scroll bar strip at capture scale.
        configuration.scrollBarInset = Int((16 * scale).rounded())
        configuration.maximumLength = options.maximumLength
        engine = ScrollingStitchEngine(stitcher: configuration)
    }

    /// Resolves the display under the selection's center and clamps the rect
    /// to it (a stream covers one display). `nil` if it's off-screen / empty.
    static func make(rect: GlobalRect, options: ScrollingOptions) -> ScrollingCaptureSession? {
        let layout = DisplayLayoutProvider.currentLayout()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = ScreenGeometry.display(containing: center, layout: layout)
            ?? ScreenGeometry.displays(intersecting: rect, layout: layout).first,
            let frame = ScreenGeometry.globalFrame(of: display, layout: layout)
        else { return nil }
        let clamped = rect.intersection(frame)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return ScrollingCaptureSession(rect: clamped, displayID: display.id, scale: display.backingScaleFactor, options: options)
    }

    // MARK: Capture

    /// Starts the stream and begins stitching (first still frame = base).
    func start() async throws {
        guard !isCapturing, !isClosed else { return }
        let layout = DisplayLayoutProvider.currentLayout()
        guard let display = layout.display(withID: displayID),
              let frame = ScreenGeometry.globalFrame(of: display, layout: layout)
        else { throw CaptureError.displayNotFound(displayID) }
        let local = CGRect(x: rect.minX - frame.minX, y: rect.minY - frame.minY, width: rect.width, height: rect.height)
        let pixelWidth = Int(CapturePlan.pixels(rect.width, scale))
        let pixelHeight = Int(CapturePlan.pixels(rect.height, scale))

        let (frames, frameContinuation) = AsyncStream.makeStream(
            of: PixelBufferFrame.self, bufferingPolicy: .bufferingNewest(2)
        )
        self.frameContinuation = frameContinuation
        let engine = engine
        pumpTask = Task.detached(priority: .userInitiated) {
            for await frame in frames { await engine.ingest(frame) }
        }
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }

        let source = ScrollingFrameSource(
            trailingInset: Int((16 * scale).rounded()),
            onFrame: { frame in frameContinuation.yield(frame) },
            onStop: { [weak self] reason in
                Task { @MainActor in self?.onStreamStopped(reason) }
            }
        )
        self.source = source
        await engine.setCapturing(true)
        try await source.start(displayID: displayID, sourceRect: local, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        isCapturing = true

        // The stream is silent while nothing changes; tick the gate so still
        // content is still forwarded (12 Hz, like the stream).
        tickTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000 / Int(ScrollingFrameSource.framesPerSecond)))
                await engine.tick()
            }
        }
        Log.scrolling.notice("session started: \(Int(self.rect.width))x\(Int(self.rect.height)) pt @\(self.scale)x")
    }

    private func handle(_ event: ScrollingSessionEvent) {
        switch event {
        case .contentEnded:
            Log.scrolling.notice("auto-scroll: end of content")
            stopAutoScroll()
        case .limitReached(let length):
            Log.scrolling.notice("length limit reached: \(length) px")
            stopAutoScroll()
        default:
            break
        }
        onEvent(event)
    }

    // MARK: Auto-scroll

    /// Starts auto-scrolling along `axis` (default: the axis the stitcher
    /// detected, else vertical). Stops by itself at the end of the content,
    /// at the length limit, or when the user scrolls / clicks / moves the
    /// pointer off the selection.
    @discardableResult
    func startAutoScroll(axis requested: StitchAxis? = nil) async -> AutoScrollStart {
        guard isCapturing, !isClosed else { return .notCapturing }
        guard !isAutoScrolling else { return .alreadyRunning }
        guard AutoScroller.isPermitted else {
            Log.scrolling.notice("auto-scroll: event posting not permitted; manual scrolling")
            return .permissionMissing
        }
        let detected = await engine.axis
        let axis = requested ?? detected ?? .vertical
        let scroller = AutoScroller(rect: rect, scale: scale, axis: axis, speed: options.autoScrollSpeed)
        isAutoScrolling = true
        await engine.setAutoScrolling(true)
        onAutoScrollChanged(true)
        installInputMonitor()
        Log.scrolling.notice("auto-scroll started: \(axis.rawValue, privacy: .public), step \(scroller.stepPoints) pt")
        autoScrollTask = Task { [weak self] in
            await self?.runAutoScroll(scroller)
        }
        return .started
    }

    func stopAutoScroll() {
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        autoScrollTask?.cancel()
        autoScrollTask = nil
        removeInputMonitor()
        let engine = engine
        Task { await engine.setAutoScrolling(false) }
        onAutoScrollChanged(false)
        Log.scrolling.notice("auto-scroll stopped")
    }

    private func runAutoScroll(_ scroller: AutoScroller) async {
        scroller.placePointerIfNeeded(inside: rect)
        await engine.feedBaseIfNeeded(timeout: 0.6)
        var checkedDirection = false
        while !Task.isCancelled, isAutoScrolling {
            // Wheel events go to the window under the pointer.
            guard rect.contains(WindowLocator.mouseLocation) else {
                Log.scrolling.notice("auto-scroll: pointer left the selection")
                break
            }
            let stepTime = ProcessInfo.processInfo.systemUptime
            guard scroller.postStep() else { break }
            let event = await engine.feedAfterStep(
                stepTime: stepTime, expectedDelta: scroller.expectedDeltaPixels, timeout: 0.4
            )
            if !checkedDirection, let event {
                switch event {
                case .rejected(.backward):
                    scroller.reverseDirection()
                    checkedDirection = true
                case .appended:
                    checkedDirection = true
                default:
                    break
                }
            }
            let ended = await engine.contentEnded
            let atLimit = await engine.limitReached
            if ended || atLimit { break }
            let pause = options.autoScrollSpeed.pauseBetweenSteps
            if pause > .zero { try? await Task.sleep(for: pause) }
        }
        if !Task.isCancelled { stopAutoScroll() }
    }

    /// The user's own scrolling or clicking stops auto-scroll (plan §4.8).
    private func installInputMonitor() {
        removeInputMonitor()
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard !AutoScroller.isSynthetic(event) else { return }
                Log.scrolling.notice("auto-scroll: user input")
                self?.stopAutoScroll()
            }
        }
    }

    private func removeInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    // MARK: Output

    /// Thumbnail of the stitched image so far, if it changed since `revision`.
    func preview(ifNewerThan revision: Int, maxDimension: Int) async -> (image: CGImage, revision: Int)? {
        let current = await engine.revision
        guard current != revision, let image = await engine.previewImage(maxDimension: maxDimension) else { return nil }
        return (image, current)
    }

    /// Stops everything and returns the stitched image (`mode: .scrolling`).
    /// Falls back to the last raw frame if nothing was stitched yet; `nil`
    /// when no frame arrived at all.
    func finish() async -> CaptureResult? {
        await stopStreaming()
        let image: CGImage?
        if await engine.hasBase {
            image = await engine.makeImage()
        } else {
            image = await engine.latestFrameImage()
        }
        let stats = (await engine.framesSeen, await engine.framesFed)
        await engine.finishEvents()
        guard let image else {
            Log.scrolling.error("finish: no frame captured")
            return nil
        }
        Log.scrolling.notice("finished: \(image.width)x\(image.height) px (\(stats.0) frames seen, \(stats.1) stitched)")
        return CaptureResult(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
            scale: scale,
            mode: .scrolling,
            sourceRect: rect,
            displayID: displayID
        )
    }

    func cancel() async {
        await stopStreaming()
        await engine.finishEvents()
        Log.scrolling.notice("session cancelled")
    }

    private func stopStreaming() async {
        guard !isClosed else { return }
        isClosed = true
        stopAutoScroll()
        tickTask?.cancel()
        tickTask = nil
        await source?.stop()
        source = nil
        frameContinuation?.finish()
        frameContinuation = nil
        await pumpTask?.value
        pumpTask = nil
        isCapturing = false
    }
}
