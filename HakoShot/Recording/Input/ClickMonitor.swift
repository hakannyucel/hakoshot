import AppKit
import CoreGraphics
import Foundation
import HakoKit

/// A mouse button press/release, stamped in host seconds, at a Quartz global
/// point (top-left origin, plan §3.2).
nonisolated struct MouseButtonEvent: Sendable, Equatable {
    var hostTime: Double
    var globalPoint: CGPoint
    var button: RecordingMouseButton
    var isDown: Bool
    /// `NSEvent.clickCount` for downs (double-click = 2); 1 for ups.
    var clickCount: Int
}

/// Mouse clicks for the recording (plan §1.6): a global `NSEvent` monitor
/// (other apps) plus a local one (our own windows, e.g. the control bar).
/// Mouse monitors need no permission (only key monitors do). Timestamps come
/// from the event itself (`NSEvent.timestamp`, host clock), not from when the
/// handler runs.
@MainActor
final class ClickMonitor {
    static let mask: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]

    private let onEvent: (MouseButtonEvent) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onEvent: @escaping (MouseButtonEvent) -> Void) {
        self.onEvent = onEvent
    }

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start() {
        guard !isRunning else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            guard let converted = Self.makeEvent(from: event) else { return }
            MainActor.assumeIsolated { self?.onEvent(converted) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            if let converted = Self.makeEvent(from: event) {
                MainActor.assumeIsolated { self?.onEvent(converted) }
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// `NSEvent` → `MouseButtonEvent`; `nil` for other event types.
    nonisolated static func makeEvent(from event: NSEvent) -> MouseButtonEvent? {
        let button: RecordingMouseButton
        let isDown: Bool
        switch event.type {
        case .leftMouseDown: (button, isDown) = (.left, true)
        case .leftMouseUp: (button, isDown) = (.left, false)
        case .rightMouseDown: (button, isDown) = (.right, true)
        case .rightMouseUp: (button, isDown) = (.right, false)
        case .otherMouseDown: (button, isDown) = (.other, true)
        case .otherMouseUp: (button, isDown) = (.other, false)
        default: return nil
        }
        // The CGEvent location is already Quartz global; fall back to the
        // live cursor position.
        guard let point = event.cgEvent?.location ?? CGEvent(source: nil)?.location else { return nil }
        return MouseButtonEvent(
            hostTime: HostTime.seconds(fromNSEventTimestamp: event.timestamp),
            globalPoint: point,
            button: button,
            isDown: isDown,
            clickCount: isDown ? max(1, event.clickCount) : 1
        )
    }
}
