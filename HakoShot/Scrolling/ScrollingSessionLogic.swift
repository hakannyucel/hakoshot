import CoreGraphics
import Foundation
import HakoKit

// Pure, stream-free pieces of the scrolling session (plan §4.8), unit-tested
// in `HakoShotTests/Scrolling` with fake frames.

// MARK: - Frame signature

/// Cheap fingerprint of a raw frame: one 64-bit hash per sampled row
/// (trailing scroll-bar strip excluded). Two frames are "the same" when only
/// a small fraction of rows differ, so a blinking caret or a spinner does not
/// keep the content from ever counting as stable.
nonisolated struct FrameSignature: Sendable, Equatable {
    var rowHashes: [UInt64]

    init(rowHashes: [UInt64]) {
        self.rowHashes = rowHashes
    }

    /// At most this many rows are hashed (evenly spaced).
    static let maximumSampledRows = 512

    /// Hashes 32-bit pixels at `base` (any 4-byte layout, e.g. BGRA).
    /// Every second pixel of a row is read; `trailingInset` pixels at the
    /// right edge are skipped (overlay scroll bars fade in and out).
    static func compute(
        base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        trailingInset: Int = 0,
        maximumRows: Int = maximumSampledRows
    ) -> FrameSignature {
        guard width > 0, height > 0 else { return FrameSignature(rowHashes: []) }
        let usableWidth = max(1, width - max(0, trailingInset))
        let stride = max(1, (height + maximumRows - 1) / max(1, maximumRows))
        var hashes: [UInt64] = []
        hashes.reserveCapacity(height / stride + 1)
        var y = 0
        while y < height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var x = 0
            while x < usableWidth {
                hash = (hash ^ UInt64(row[x])) &* 0x0000_0100_0000_01b3
                x += 2
            }
            hashes.append(hash)
            y += stride
        }
        return FrameSignature(rowHashes: hashes)
    }

    /// Signature of a `CGImage` (redrawn into 32-bit BGRA first). For tests
    /// and the debug path; the stream hashes its pixel buffers directly.
    static func compute(image: CGImage, trailingInset: Int = 0) -> FrameSignature {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return FrameSignature(rowHashes: []) }
        return pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return FrameSignature(rowHashes: []) }
            return compute(base: base, width: width, height: height, bytesPerRow: bytesPerRow, trailingInset: trailingInset)
        }
    }

    /// Fraction (0...1) of sampled rows that differ; 1 when the sizes differ.
    func differenceFraction(from other: FrameSignature) -> Double {
        guard rowHashes.count == other.rowHashes.count, !rowHashes.isEmpty else { return 1 }
        var different = 0
        for index in rowHashes.indices where rowHashes[index] != other.rowHashes[index] {
            different += 1
        }
        return Double(different) / Double(rowHashes.count)
    }
}

// MARK: - Stability gate

/// Decides which raw stream frames reach the stitcher (plan §4.8
/// "kararlılık kapısı").
///
/// - A frame whose content has not changed for `stableInterval` is forwarded
///   once (`.forwardStable`): scrolling paused, lazy content settled.
/// - While the content keeps moving (continuous manual scrolling), one frame
///   per `movingSampleInterval` is forwarded (`.forwardMoving`) so long
///   scrolls keep enough overlap. Auto-scroll turns this off and only uses
///   stable frames after each step.
/// - Frames with the same content as the last forwarded one are never
///   forwarded again by the gate itself (auto-scroll forces those to detect
///   the end of the content).
///
/// Times are seconds on one monotonic clock (`ProcessInfo.systemUptime` in
/// the app, arbitrary numbers in tests).
nonisolated struct FrameStabilityGate: Sendable {
    nonisolated struct Configuration: Sendable, Equatable {
        /// No change for this long = stable. 12 fps → at least one more frame.
        var stableInterval: TimeInterval = 0.12
        /// Sampling period while the content is moving.
        var movingSampleInterval: TimeInterval = 1.0 / 6.0
        /// Up to this fraction of rows may differ and still count as "same".
        var changeTolerance: Double = 0.02

        init(stableInterval: TimeInterval = 0.12, movingSampleInterval: TimeInterval = 1.0 / 6.0, changeTolerance: Double = 0.02) {
            self.stableInterval = stableInterval
            self.movingSampleInterval = movingSampleInterval
            self.changeTolerance = changeTolerance
        }
    }

    nonisolated enum Decision: Sendable, Equatable {
        case hold
        case forwardStable
        case forwardMoving
    }

    let configuration: Configuration
    /// Forward frames while moving (manual mode). Auto-scroll sets `false`.
    var samplesWhileMoving = true

    /// Signature the content is compared against (updated on every change).
    private(set) var anchor: FrameSignature?
    /// Time of the last observed content change (first frame counts as one).
    private(set) var lastChangeTime: TimeInterval = -.infinity
    private(set) var lastForwardTime: TimeInterval = -.infinity
    /// The current content (since the last change) was already forwarded.
    private(set) var currentForwarded = false
    private(set) var hasForwarded = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// A new frame arrived at `time`.
    mutating func observe(_ signature: FrameSignature, at time: TimeInterval) -> Decision {
        let changed: Bool
        if let anchor {
            changed = signature.differenceFraction(from: anchor) > configuration.changeTolerance
        } else {
            changed = true
        }
        guard changed else { return tick(at: time) }

        anchor = signature
        lastChangeTime = time
        currentForwarded = false
        if samplesWhileMoving, hasForwarded, time - lastForwardTime >= configuration.movingSampleInterval {
            markForwarded(at: time)
            return .forwardMoving
        }
        return .hold
    }

    /// No new frame (or an unchanged one) at `time`: forward the current
    /// content once it has been still for `stableInterval`.
    mutating func tick(at time: TimeInterval) -> Decision {
        guard anchor != nil, !currentForwarded, isStable(at: time) else { return .hold }
        markForwarded(at: time)
        return .forwardStable
    }

    func isStable(at time: TimeInterval) -> Bool {
        anchor != nil && time - lastChangeTime >= configuration.stableInterval
    }

    /// Record that the current frame was fed to the stitcher (also used by
    /// auto-scroll's forced feeds).
    mutating func markForwarded(at time: TimeInterval) {
        currentForwarded = true
        hasForwarded = true
        lastForwardTime = time
    }
}

// MARK: - Events

/// What the scrolling session tells its UI / flow.
nonisolated enum ScrollingSessionEvent: Sendable, Equatable {
    /// The first frame became the base of the image.
    case started(length: Int)
    /// New content was stitched; `length` = stitched pixels along the axis.
    case progress(length: Int)
    /// Show (`true`) or hide the "Slow down" hint.
    case slowDown(Bool)
    /// Auto-scroll saw the same content `duplicatesForEnd` steps in a row.
    case contentEnded
    /// The length cap was reached; the session should finish.
    case limitReached(length: Int)
}

/// Maps ``StitchEvent``s to ``ScrollingSessionEvent``s and does the
/// end-of-content counting (WP6.1: 3 consecutive duplicates during
/// auto-scroll = end).
nonisolated struct ScrollingEventMapper: Sendable {
    static let duplicatesForEnd = 3

    private(set) var consecutiveDuplicates = 0
    private(set) var showsSlowDown = false
    private(set) var hasStarted = false
    private(set) var contentEnded = false
    private(set) var limitReached = false

    init() {}

    /// Starts a fresh duplicate count (auto-scroll (re)started or stopped).
    mutating func resetEndDetection() {
        consecutiveDuplicates = 0
        contentEnded = false
    }

    mutating func map(_ event: StitchEvent, stitchedLength: Int, autoScrolling: Bool) -> [ScrollingSessionEvent] {
        var out: [ScrollingSessionEvent] = []
        switch event {
        case .started:
            hasStarted = true
            consecutiveDuplicates = 0
            out.append(.started(length: stitchedLength))
        case .appended(let step):
            consecutiveDuplicates = 0
            if showsSlowDown {
                showsSlowDown = false
                out.append(.slowDown(false))
            }
            out.append(.progress(length: step.totalLength))
        case .duplicate:
            guard autoScrolling else {
                consecutiveDuplicates = 0
                break
            }
            consecutiveDuplicates += 1
            if consecutiveDuplicates >= Self.duplicatesForEnd, !contentEnded {
                contentEnded = true
                out.append(.contentEnded)
            }
        case .rejected:
            // Backward / unreadable frames are neither progress nor duplicates.
            if event.suggestsSlowingDown, !showsSlowDown {
                showsSlowDown = true
                out.append(.slowDown(true))
            }
        case .limitReached(let total):
            if !limitReached {
                limitReached = true
                out.append(.limitReached(length: total))
            }
        }
        return out
    }
}
