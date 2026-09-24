import AppKit
import CoreGraphics
import Darwin
import Foundation
import HakoKit

/// One cursor position reading, host seconds, in points relative to the
/// recording rect's top-left corner (at the moment of the reading).
nonisolated struct CursorPositionSample: Sendable, Equatable {
    var hostTime: Double
    var localPoint: CGPoint
    /// Button and `hidden` flags (the shape index is added by `EventRecorder`).
    var flags: CursorSampleFlags
}

/// Samples the global mouse location at a fixed rate (plan §1.6, §4.10):
/// the recording fps clamped to 60…120 Hz. Positions are converted to points
/// relative to the recording rect, read from `rect` on every tick so window
/// mode follows the moving window (R1.4). Button state comes from
/// `NSEvent.pressedMouseButtons`; `hidden` from the (best-effort)
/// WindowServer cursor visibility.
///
/// `EventRecorder` skips repeated identical samples when the cursor is idle.
@MainActor
final class CursorTracker {
    nonisolated static let minRate: Double = 60
    nonisolated static let maxRate: Double = 120

    /// Sampling rate for a recording fps (60…120 Hz).
    nonisolated static func rate(forFPS fps: Int) -> Double {
        min(max(Double(fps), minRate), maxRate)
    }

    let rate: Double
    private let rect: () -> CGRect
    private let onSample: (CursorPositionSample) -> Void
    private var timer: Timer?

    /// - Parameters:
    ///   - rect: recording rect in Quartz global points (top-left origin).
    init(rate: Double, rect: @escaping () -> CGRect, onSample: @escaping (CursorPositionSample) -> Void) {
        self.rate = min(max(rate, 1), Self.maxRate)
        self.rect = rect
        self.onSample = onSample
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        sampleNow()
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        timer.tolerance = 0.1 / rate
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Takes one reading now.
    func sampleNow() {
        guard let global = CGEvent(source: nil)?.location else { return }
        var flags = Self.buttonFlags(NSEvent.pressedMouseButtons)
        if Self.isCursorVisible() == false { flags.insert(.hidden) }
        onSample(CursorPositionSample(
            hostTime: HostTime.nowSeconds(),
            localPoint: Self.localPoint(global, in: rect()),
            flags: flags
        ))
    }

    /// Quartz global point → points relative to `rect`'s top-left.
    nonisolated static func localPoint(_ global: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: global.x - rect.minX, y: global.y - rect.minY)
    }

    /// `NSEvent.pressedMouseButtons` bits (0 left, 1 right, 2+ other) → flags.
    nonisolated static func buttonFlags(_ pressed: Int) -> CursorSampleFlags {
        var flags: CursorSampleFlags = []
        if pressed & 1 != 0 { flags.insert(.leftDown) }
        if pressed & 2 != 0 { flags.insert(.rightDown) }
        if pressed & ~3 != 0 { flags.insert(.otherDown) }
        return flags
    }

    /// WindowServer cursor visibility (`CGCursorIsVisible`), resolved at run
    /// time: the symbol is deprecated ("no longer supported") and calling it
    /// directly warns. `nil` when unavailable → treated as visible.
    static func isCursorVisible() -> Bool? {
        guard let function = cursorIsVisibleFunction else { return nil }
        return function() != 0
    }

    private typealias CursorIsVisibleFunction = @convention(c) () -> Int32

    private static let cursorIsVisibleFunction: CursorIsVisibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: CursorIsVisibleFunction.self)
    }()
}
