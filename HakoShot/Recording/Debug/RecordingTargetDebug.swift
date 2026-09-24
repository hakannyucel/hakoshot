#if DEBUG
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import HakoKit
import os

/// DEBUG helpers for window / fullscreen targets (plan §7 R1.4):
///
/// - `debug-move-test-window?x=&y=&width=&height=&dx=&dy=&interval=&seconds=`
///   opens a four-color test window (quadrants red / green / blue / yellow,
///   top-left first) and moves it on a timer, bouncing inside its screen;
/// - `record-screen?mode=window&window=frontmost|test|<id>` and
///   `mode=fullscreen&display=<n>` resolve through `TargetParameters`;
/// - `debug-record-window?window=test|frontmost|<id>&seconds=&out=` records a
///   window with `WindowFollower` attached, without the coordinator
///   (source + writer directly, like `debug-record`).
enum RecordingTargetDebug {
    // MARK: Moving test window

    /// Quadrant colors, top-left, top-right, bottom-left, bottom-right.
    static let quadrantColors: [NSColor] = [
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
        NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1),
    ]

    /// The test window opened by `debug-move-test-window` (one at a time).
    private(set) static var current: MovingTestWindow?

    nonisolated struct MoveParameters: Equatable, Sendable {
        /// Quartz global points; `nil` = 400×300 near the main display's top-left.
        var rect: CGRect?
        /// Step per tick in points.
        var dx: CGFloat = 30
        var dy: CGFloat = 0
        var interval: Duration = .milliseconds(250)
        /// Closes itself after this long.
        var seconds: Double = 15

        init(rect: CGRect? = nil, dx: CGFloat = 30, dy: CGFloat = 0, interval: Duration = .milliseconds(250), seconds: Double = 15) {
            self.rect = rect
            self.dx = dx
            self.dy = dy
            self.interval = interval
            self.seconds = seconds
        }

        /// Keys: `x y width|w height|h dx dy interval (ms) seconds`.
        init(queryItems: [URLQueryItem]) {
            let values = RecordingTargetDebug.values(queryItems)
            func number(_ keys: String...) -> Double? { keys.lazy.compactMap { values[$0].flatMap(Double.init) }.first }
            if let x = number("x"), let y = number("y"), let w = number("width", "w"), let h = number("height", "h"), w > 0, h > 0 {
                rect = CGRect(x: x, y: y, width: w, height: h)
            }
            if let dx = number("dx") { self.dx = dx }
            if let dy = number("dy") { self.dy = dy }
            if let ms = number("interval"), ms >= 16 { interval = .milliseconds(Int(ms)) }
            if let seconds = number("seconds", "duration"), seconds > 0 { self.seconds = seconds }
        }
    }

    /// Opens (replacing any previous one) and starts moving the test window.
    @discardableResult
    static func showMovingTestWindow(_ parameters: MoveParameters = MoveParameters()) -> MovingTestWindow {
        current?.close()
        let layout = DisplayLayoutProvider.currentLayout()
        let rect = parameters.rect.map { GlobalRect(origin: $0.origin, size: $0.size) }
            ?? GlobalRect(x: 200, y: 200, width: 400, height: 300)
        let window = MovingTestWindow(global: rect, layout: layout)
        window.startMoving(dx: parameters.dx, dy: parameters.dy, interval: parameters.interval, closeAfter: parameters.seconds)
        current = window
        Log.recording.notice("debug-move-test-window: window \(window.windowID) at \(String(describing: rect.cgRect), privacy: .public)")
        return window
    }

    static func closeTestWindow() {
        current?.close()
        current = nil
    }

    /// A borderless, click-through window with four colored quadrants.
    final class MovingTestWindow {
        let window: NSWindow
        private var moveTask: Task<Void, Never>?

        var windowID: CGWindowID { CGWindowID(window.windowNumber) }

        init(global: GlobalRect, layout: DisplayLayout) {
            let frame = ScreenGeometry.appKitRect(fromGlobal: global, layout: layout) ?? CGRect(origin: .zero, size: global.size)
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = true
            window.hasShadow = false
            window.level = .floating
            window.ignoresMouseEvents = true
            window.backgroundColor = .black
            window.title = "HakoShot Test Window"
            let view = NSView(frame: CGRect(origin: .zero, size: global.size))
            view.wantsLayer = true
            let halfW = global.width / 2
            let halfH = global.height / 2
            // AppKit layer origin is bottom-left: top row has y = halfH.
            let origins = [CGPoint(x: 0, y: halfH), CGPoint(x: halfW, y: halfH), CGPoint(x: 0, y: 0), CGPoint(x: halfW, y: 0)]
            for (origin, color) in zip(origins, RecordingTargetDebug.quadrantColors) {
                let layer = CALayer()
                layer.frame = CGRect(origin: origin, size: CGSize(width: halfW, height: halfH))
                layer.backgroundColor = color.cgColor
                view.layer?.addSublayer(layer)
            }
            window.contentView = view
            window.orderFrontRegardless()
        }

        /// Moves by (dx, dy) every `interval`, bouncing off the screen's
        /// visible frame; closes after `closeAfter` seconds.
        func startMoving(dx: CGFloat, dy: CGFloat, interval: Duration, closeAfter: Double) {
            moveTask?.cancel()
            moveTask = Task { [weak self] in
                var step = CGVector(dx: dx, dy: -dy) // Quartz dy down = AppKit up negative
                let deadline = ContinuousClock.now + .milliseconds(Int(closeAfter * 1000))
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled else { return }
                    step = self.moveOnce(by: step)
                }
                self?.close()
            }
        }

        /// One move; returns the step to use next (reversed at an edge).
        @discardableResult
        func moveOnce(by step: CGVector) -> CGVector {
            let bounds = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
            var frame = window.frame.offsetBy(dx: step.dx, dy: step.dy)
            var next = step
            if frame.minX < bounds.minX || frame.maxX > bounds.maxX {
                next.dx = -step.dx
                frame = window.frame.offsetBy(dx: next.dx, dy: step.dy)
            }
            if frame.minY < bounds.minY || frame.maxY > bounds.maxY {
                next.dy = -step.dy
                frame = CGRect(origin: CGPoint(x: frame.minX, y: window.frame.minY + next.dy), size: frame.size)
            }
            window.setFrameOrigin(frame.origin)
            return next
        }

        func stopMoving() {
            moveTask?.cancel()
            moveTask = nil
        }

        func close() {
            stopMoving()
            window.orderOut(nil)
            window.close()
        }
    }

    // MARK: record-screen target parameters

    /// Which window a `window=` value names.
    nonisolated enum WindowSelector: Equatable, Sendable {
        /// Frontmost eligible window of the frontmost app (not HakoShot).
        case frontmost
        /// The `debug-move-test-window` window.
        case testWindow
        case id(CGWindowID)

        init?(_ value: String) {
            switch value.lowercased() {
            case "frontmost", "front": self = .frontmost
            case "test": self = .testWindow
            default:
                guard let number = UInt32(value) else { return nil }
                self = .id(number)
            }
        }
    }

    /// `record-screen` target keys: `mode=area|window|fullscreen`,
    /// `window=frontmost|test|<id>`, `display=<n>` (1 = main).
    nonisolated struct TargetParameters: Equatable, Sendable {
        var mode: RecordingTargetKind?
        var window: WindowSelector?
        var display: Int?

        init(mode: RecordingTargetKind? = nil, window: WindowSelector? = nil, display: Int? = nil) {
            self.mode = mode
            self.window = window
            self.display = display
        }

        init(queryItems: [URLQueryItem]) {
            let values = RecordingTargetDebug.values(queryItems)
            mode = values["mode"].flatMap { RecordingTargetKind(rawValue: $0.lowercased()) }
            window = values["window"].flatMap(WindowSelector.init)
            display = values["display"].flatMap { Int($0) }.flatMap { $0 >= 1 ? $0 : nil }
            if mode == nil, window != nil { mode = .window }
        }
    }

    nonisolated static func displayID(number: Int, layout: DisplayLayout) -> CGDirectDisplayID? {
        RecordingDisplayNumbering.displayID(number: number, layout: layout)
    }

    /// A concrete target for window / fullscreen parameters; `nil` for area
    /// mode (the coordinator uses the rect or the overlay) or when nothing matches.
    static func target(for parameters: TargetParameters, layout: DisplayLayout = DisplayLayoutProvider.currentLayout()) -> RecordingTarget? {
        switch parameters.mode {
        case .window:
            guard let selector = parameters.window, let id = windowID(for: selector) else { return nil }
            return .window(id)
        case .fullscreen, .pickDisplay:
            let id = parameters.display.flatMap { displayID(number: $0, layout: layout) } ?? layout.mainDisplayID
            return .display(id)
        case .area, nil:
            return nil
        }
    }

    static func windowID(for selector: WindowSelector) -> CGWindowID? {
        switch selector {
        case .frontmost:
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return WindowLocator.snapshot().frontmostWindow(preferringPID: pid)?.id
        case .testWindow:
            return current?.windowID
        case let .id(id):
            return id
        }
    }

    // MARK: debug-record-window

    nonisolated struct RecordWindowParameters: Equatable, Sendable {
        var window: WindowSelector = .testWindow
        var seconds: Double = 3
        var out: URL?

        init(window: WindowSelector = .testWindow, seconds: Double = 3, out: URL? = nil) {
            self.window = window
            self.seconds = seconds
            self.out = out
        }

        init(queryItems: [URLQueryItem]) {
            let values = RecordingTargetDebug.values(queryItems)
            window = values["window"].flatMap(WindowSelector.init) ?? .testWindow
            seconds = values["seconds"].flatMap(Double.init).map { max(0.5, $0) } ?? 3
            if let path = values["out"], !path.isEmpty {
                out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        }
    }

    /// Result of a followed window recording.
    struct FollowedRecording: Sendable {
        var url: URL
        var pixelSize: CGSize
        var pointSize: CGSize
        var duration: Double
        var sourceRectUpdates: Int
    }

    /// URL entry point for `debug-record-window`.
    static func runRecordWindow(_ parameters: RecordWindowParameters) async {
        guard let id = windowID(for: parameters.window) else {
            Log.recording.error("debug-record-window: no window for \(String(describing: parameters.window), privacy: .public)")
            return
        }
        let out = parameters.out ?? FileManager.default.temporaryDirectory.appending(path: "hakoshot-window-\(id).mov")
        do {
            let result = try await recordFollowing(windowID: id, seconds: parameters.seconds, out: out)
            Log.recording.notice("debug-record-window wrote \(result.url.path, privacy: .public): \(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)) px, \(String(format: "%.3f", result.duration), privacy: .public) s, \(result.sourceRectUpdates) rect updates")
        } catch {
            Log.recording.error("debug-record-window failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Records `windowID` for `seconds` with a `WindowFollower` moving the
    /// source rect. Uses `ScreenStreamSource` + `RecordingWriter` directly
    /// (the engine doesn't expose `updateSourceRect` yet). The window is
    /// passed as an excepted window so our own test window is recorded even
    /// with the display filter.
    static func recordFollowing(windowID: CGWindowID, seconds: Double, out: URL, options: RecordingOptions = .default) async throws -> FollowedRecording {
        let layout = DisplayLayoutProvider.currentLayout()
        let target = RecordingTarget.window(windowID)
        let resolved = try RecordingEngine.resolve(target, layout: layout, windowBounds: RecordingEngine.windowBounds(of:))
        let request = RecordingRequest(target: target, options: options, source: .screen)
        let plan = RecordingEngine.outputPlan(request, resolved: resolved)
        let fps = RecordingEngine.effectiveFPS(request)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try RecordingWriter(configuration: RecordingWriterConfiguration(
            outputURL: out, plan: plan, quality: RecordingEngine.effectiveQuality(request), fps: fps
        ))
        let source = ScreenStreamSource()
        let firstFrame = FirstFrameSignal()
        let configuration = RecordingSourceConfiguration(
            target: target,
            displayID: resolved.displayID,
            sourceRect: resolved.sourceRect,
            pixelSize: plan.pixelSize,
            fps: fps,
            showsCursor: false,
            exceptedWindowIDs: [windowID]
        )
        let handlers = RecordingFrameSourceHandlers(
            onVideo: { [writer, firstFrame] buffer in if writer.appendVideo(buffer) { firstFrame.signal() } },
            onAudio: { _, _ in },
            onStop: { error in Log.recording.error("debug-record-window: source stopped: \(String(describing: error), privacy: .public)") }
        )
        do {
            try await source.start(configuration, handlers: handlers)
        } catch {
            writer.cancel()
            throw error
        }
        guard await firstFrame.wait(timeout: .seconds(5)) else {
            await source.stop()
            writer.cancel()
            throw RecordingError.noFrames
        }

        let handle = RecordingHandle(
            id: UUID(), sessionFolder: out.deletingLastPathComponent(), target: target, profile: .classic,
            sourceRect: resolved.globalRect, displayID: resolved.displayID, pixelSize: plan.pixelSize,
            pointSize: resolved.pointSize, scale: resolved.scale, startDate: .now
        )
        let follower = WindowFollower.make(
            for: handle, layout: layout,
            apply: { rect in try await source.updateSourceRect(rect) },
            onWindowClosed: { Log.recording.notice("debug-record-window: window closed") }
        )
        follower?.start()
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        follower?.stop()

        writer.stopAccepting()
        await source.stop()
        let summary = try await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        return FollowedRecording(
            url: out, pixelSize: plan.pixelSize, pointSize: resolved.pointSize,
            duration: summary.duration, sourceRectUpdates: follower?.updateCount ?? 0
        )
    }

    // MARK: Helpers

    nonisolated static func values(_ queryItems: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
        return values
    }
}
#endif

import CoreGraphics
import HakoKit

/// URL `display=<n>` numbering (release code too): 1 = main display, then the
/// others in `layout.displays` order (CleanShot-compatible, plan §4.21).
nonisolated enum RecordingDisplayNumbering {
    static func displayID(number: Int, layout: DisplayLayout) -> CGDirectDisplayID? {
        guard number >= 1 else { return nil }
        let ordered = layout.displays.filter { $0.id == layout.mainDisplayID }
            + layout.displays.filter { $0.id != layout.mainDisplayID }
        return number <= ordered.count ? ordered[number - 1].id : nil
    }
}
