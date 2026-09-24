import CoreGraphics
import Foundation
import HakoKit
import os

/// Pure rect math for window-mode recordings (plan §4.1).
///
/// Coordinates: window frames in Quartz global points (`kCGWindowBounds`),
/// the result in the recorded display's local points (top-left origin), which
/// is what `SCStreamConfiguration.sourceRect` takes.
nonisolated enum WindowFollowMath {
    /// Where the window is relative to the recorded display.
    enum Visibility: Sendable, Equatable {
        /// Fully on the recorded display.
        case onDisplay
        /// Partly outside it (moved over an edge or onto another display); the
        /// visible part is recorded.
        case clipped
        /// Entirely outside it; the last source rect is kept.
        case offDisplay
    }

    struct Placement: Sendable, Equatable {
        /// New `sourceRect` (display-local points); `nil` when off the display.
        var sourceRect: CGRect?
        var visibility: Visibility
        /// Share of the window's area on the recorded display (0…1).
        var visibleFraction: CGFloat
    }

    /// Changes smaller than this (points) don't update the stream.
    static let changeTolerance: CGFloat = 0.5

    /// The window frame in display-local points.
    static func localRect(of windowFrame: GlobalRect, displayFrame: GlobalRect) -> CGRect {
        CGRect(
            x: windowFrame.minX - displayFrame.minX,
            y: windowFrame.minY - displayFrame.minY,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }

    /// Source rect for the window's current frame.
    ///
    /// `referenceSize` is the size recorded at start (the output size is
    /// fixed then). The visible part of the window is grown around its center
    /// to the reference aspect ratio, so a resized or edge-clipped window is
    /// scaled uniformly (`scalesToFit`) instead of stretched, then moved (or,
    /// if larger, clamped) inside the display. A window that only moved gives
    /// its own frame back, so its content stays put in the video.
    static func placement(windowFrame: GlobalRect, displayFrame: GlobalRect, referenceSize: CGSize) -> Placement {
        let displayBounds = CGRect(origin: .zero, size: displayFrame.size)
        let local = localRect(of: windowFrame, displayFrame: displayFrame)
        let visible = local.intersection(displayBounds)
        let windowArea = max(local.width * local.height, 1)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return Placement(sourceRect: nil, visibility: .offDisplay, visibleFraction: 0)
        }
        let fraction = min(1, (visible.width * visible.height) / windowArea)
        let visibility: Visibility = visible.equalTo(local) ? .onDisplay : .clipped
        let fitted = fitAspect(visible, to: referenceSize)
        let rect = keep(fitted, inside: displayBounds)
        return Placement(sourceRect: rect, visibility: visibility, visibleFraction: fraction)
    }

    /// Grows `rect` around its center (never shrinks) until it has
    /// `referenceSize`'s aspect ratio. Unchanged when the ratios already match
    /// or the reference is empty.
    static func fitAspect(_ rect: CGRect, to referenceSize: CGSize) -> CGRect {
        guard referenceSize.width > 0, referenceSize.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let target = referenceSize.width / referenceSize.height
        let current = rect.width / rect.height
        guard abs(current - target) / target > 0.001 else { return rect }
        var size = rect.size
        if current < target {
            size.width = rect.height * target
        } else {
            size.height = rect.width / target
        }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Moves `rect` inside `bounds`; a side longer than `bounds` is clamped.
    static func keep(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        var result = rect
        if result.width >= bounds.width {
            result.origin.x = bounds.minX
            result.size.width = bounds.width
        } else {
            result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        }
        if result.height >= bounds.height {
            result.origin.y = bounds.minY
            result.size.height = bounds.height
        } else {
            result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        }
        return result
    }

    /// Whether `new` differs from `old` enough to update the stream.
    static func hasChanged(_ new: CGRect, from old: CGRect?) -> Bool {
        guard let old else { return true }
        return abs(new.minX - old.minX) > changeTolerance || abs(new.minY - old.minY) > changeTolerance
            || abs(new.width - old.width) > changeTolerance || abs(new.height - old.height) > changeTolerance
    }
}

/// Keeps a window-mode recording on its window (plan §4.1, §5.2).
///
/// Polls at ~30 Hz (plan said 10 Hz; measured: a window jumping 30 pt every
/// 250 ms was in place 59 % of the video time at 10 Hz, 76 % at 30 Hz;
/// `updateConfiguration` itself takes 40–80 ms, and the frame captured at
/// the moment of a move always shows the old rect). Polls the window's frame with `CGWindowListCopyWindowInfo` (one window,
/// cheap) and, when it changed, calls `apply` with the new source rect
/// (`RecordingFrameSource.updateSourceRect`). The stream stays on its
/// display: a window dragged to another display is recorded clipped at the
/// edge (logged once per transition) and the last rect is kept while it's
/// entirely elsewhere. A window that disappears from the window list for
/// `closeConfirmationPolls` polls in a row counts as closed: `onWindowClosed`
/// runs once and polling stops (the coordinator stops the recording). A
/// minimized / hidden window is not closed; the last rect is kept.
final class WindowFollower {
    /// A window-list lookup result.
    struct WindowState: Sendable, Equatable {
        /// Quartz global points.
        var frame: GlobalRect
        var isOnScreen: Bool
    }

    struct Configuration: Sendable, Equatable {
        var windowID: CGWindowID
        var displayID: CGDirectDisplayID
        /// The recorded display in Quartz global points.
        var displayFrame: GlobalRect
        /// The source rect the stream started with (display-local points).
        var initialSourceRect: CGRect
        var interval: Duration = .milliseconds(33)
        var closeConfirmationPolls = 2
    }

    typealias WindowQuery = @Sendable (CGWindowID) -> WindowState?
    typealias Apply = @Sendable (CGRect) async throws -> Void

    let configuration: Configuration
    private let query: WindowQuery
    private let apply: Apply
    private let onWindowClosed: () -> Void

    private var pollTask: Task<Void, Never>?
    private var missingPolls = 0
    private var lastVisibility: WindowFollowMath.Visibility = .onDisplay
    private var wasHidden = false
    private(set) var lastAppliedRect: CGRect?
    /// Successful `apply` calls (tests, log).
    private(set) var updateCount = 0
    private(set) var isClosed = false

    init(
        configuration: Configuration,
        query: @escaping WindowQuery = WindowFollower.liveWindowState(of:),
        apply: @escaping Apply,
        onWindowClosed: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.query = query
        self.apply = apply
        self.onWindowClosed = onWindowClosed
        lastAppliedRect = configuration.initialSourceRect
    }

    /// A follower for a window-mode handle; `nil` for other targets or when
    /// the handle's display is gone.
    static func make(
        for handle: RecordingHandle,
        layout: DisplayLayout,
        apply: @escaping Apply,
        onWindowClosed: @escaping () -> Void
    ) -> WindowFollower? {
        guard case let .window(windowID) = handle.target,
              let display = layout.display(withID: handle.displayID),
              let displayFrame = ScreenGeometry.globalFrame(of: display, layout: layout)
        else { return nil }
        let initial = WindowFollowMath.localRect(of: handle.sourceRect, displayFrame: displayFrame)
        return WindowFollower(
            configuration: Configuration(windowID: windowID, displayID: handle.displayID, displayFrame: displayFrame, initialSourceRect: initial),
            apply: apply,
            onWindowClosed: onWindowClosed
        )
    }

    var isRunning: Bool { pollTask != nil }

    func start() {
        guard pollTask == nil, !isClosed else { return }
        Log.recording.notice("window follower: following window \(self.configuration.windowID) on display \(self.configuration.displayID)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = await self.pollOnce()
                guard keepGoing else { return }
                try? await Task.sleep(for: self.configuration.interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll: look the window up, update the stream if it moved. Returns
    /// `false` once the window is closed.
    @discardableResult
    func pollOnce() async -> Bool {
        guard !isClosed else { return false }
        guard let state = query(configuration.windowID) else {
            missingPolls += 1
            if missingPolls >= configuration.closeConfirmationPolls {
                isClosed = true
                pollTask = nil
                Log.recording.notice("window follower: window \(self.configuration.windowID) closed")
                onWindowClosed()
                return false
            }
            return true
        }
        missingPolls = 0
        guard state.isOnScreen else {
            if !wasHidden { Log.recording.notice("window follower: window \(self.configuration.windowID) hidden; keeping the last rect") }
            wasHidden = true
            return true
        }
        wasHidden = false

        let placement = WindowFollowMath.placement(
            windowFrame: state.frame,
            displayFrame: configuration.displayFrame,
            referenceSize: configuration.initialSourceRect.size
        )
        if placement.visibility != lastVisibility {
            logTransition(to: placement)
            lastVisibility = placement.visibility
        }
        guard let rect = placement.sourceRect, WindowFollowMath.hasChanged(rect, from: lastAppliedRect) else { return true }
        do {
            try await apply(rect)
            lastAppliedRect = rect
            updateCount += 1
        } catch {
            Log.recording.error("window follower: updateSourceRect failed: \(String(describing: error), privacy: .public)")
        }
        return true
    }

    private func logTransition(to placement: WindowFollowMath.Placement) {
        let percent = Int((placement.visibleFraction * 100).rounded())
        switch placement.visibility {
        case .onDisplay:
            Log.recording.notice("window follower: window back on display \(self.configuration.displayID)")
        case .clipped:
            Log.recording.notice("window follower: window partly off display \(self.configuration.displayID) (\(percent)% visible); recording the visible part")
        case .offDisplay:
            Log.recording.notice("window follower: window left display \(self.configuration.displayID); the recording stays there with the last rect")
        }
    }

    /// The window's frame and on-screen flag from the window server; `nil`
    /// when the window no longer exists.
    nonisolated static func liveWindowState(of windowID: CGWindowID) -> WindowState? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return WindowState(frame: GlobalRect(origin: bounds.origin, size: bounds.size), isOnScreen: onScreen)
    }
}
