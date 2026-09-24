import AppKit
import ApplicationServices
import CoreGraphics
import HakoKit
import os

/// Posts synthetic scroll-wheel events at the selection's center (plan
/// §2.1, §4.8). Needs the "control your computer" permission
/// (`CGPreflightPostEventAccess`, or Accessibility trust, which implies it).
///
/// Events are pixel-unit wheel events of one step each (a fraction of the
/// selection along the axis) and carry ``eventTag`` so the session's input
/// monitor can tell them from the user's own scrolling.
final class AutoScroller {
    /// `eventSourceUserData` of every event we post ("HAKO").
    nonisolated static let eventTag: Int64 = 0x4841_4B4F

    /// Whether synthetic events can be posted right now.
    static var isPermitted: Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    let axis: StitchAxis
    /// Quartz global point the events are posted at.
    let target: CGPoint
    /// Step in points (wheel pixel units are points).
    let stepPoints: Int32
    /// Expected content movement per step, in captured pixels.
    let expectedDeltaPixels: Int
    /// +1 scrolls towards the end of the content; flipped once if the first
    /// step moved the content backwards (e.g. an app inverting synthetic deltas).
    private(set) var direction: Int32 = 1

    /// - Parameters:
    ///   - rect: the selection, Quartz global points.
    ///   - scale: capture scale (pixels per point).
    init(rect: GlobalRect, scale: CGFloat, axis: StitchAxis, speed: ScrollingAutoScrollSpeed) {
        self.axis = axis
        target = CGPoint(x: rect.midX, y: rect.midY)
        stepPoints = Self.stepPoints(for: rect, axis: axis, speed: speed)
        expectedDeltaPixels = Int((CGFloat(stepPoints) * scale).rounded())
    }

    /// Step size along `axis` in points (at least 1).
    nonisolated static func stepPoints(for rect: GlobalRect, axis: StitchAxis, speed: ScrollingAutoScrollSpeed) -> Int32 {
        let extent = axis == .vertical ? rect.height : rect.width
        return Int32(max(1, (extent * speed.stepFraction).rounded()))
    }

    func reverseDirection() {
        direction = -direction
        Log.scrolling.notice("auto-scroll: content moved backwards, reversing wheel direction")
    }

    /// Moves the pointer onto the selection when it is elsewhere (wheel
    /// events go to the window under the pointer). No permission needed.
    func placePointerIfNeeded(inside rect: GlobalRect) {
        guard !rect.contains(WindowLocator.mouseLocation) else { return }
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Posts one step. Returns `false` if the event could not be created.
    @discardableResult
    func postStep() -> Bool {
        let delta = -stepPoints * direction
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: axis == .vertical ? 1 : 2,
            wheel1: axis == .vertical ? delta : 0,
            wheel2: axis == .horizontal ? delta : 0,
            wheel3: 0
        )
        guard let event else { return false }
        event.location = target
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
        return true
    }

    /// `true` for events this class posted.
    static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == eventTag
    }
}
