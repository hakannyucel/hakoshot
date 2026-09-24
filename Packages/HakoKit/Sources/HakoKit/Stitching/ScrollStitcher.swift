import Accelerate
import CoreGraphics
import Foundation

/// Incremental scrolling-capture stitcher (plan §4.8).
///
/// Feed frames one at a time with ``append(_:expectedDelta:)``; each call
/// returns a ``StitchEvent`` the UI can react to ("Slow down", end of content,
/// length limit). ``makeImage()`` produces the stitched result at any time and
/// ``previewImage(maxDimension:)`` a cheap thumbnail for the live HUD.
///
/// Concurrency: a `Sendable` value type with mutating methods. Own exactly one
/// instance inside a single actor (e.g. the scrolling session's stitching
/// actor) and call it from there; `append` does CPU work (a few ms per frame),
/// so keep it off the main actor. Avoid copying a stitcher mid-session: the
/// canvas is copy-on-write and a copy would duplicate it on the next append.
///
/// How it works:
/// 1. Each frame is rendered to 32-bit pixels in its own color space (pixel
///    exact) and, for horizontal scrolling, transposed so the scroll axis is y.
/// 2. Per row: a 64-bit hash (trailing scroll-bar strip excluded) and a 32-cell
///    luminance descriptor. Rows that are very frequent (blank background) are
///    marked uninformative.
/// 3. Leading/trailing rows identical at the same position in both frames are
///    sticky header/footer bands and are excluded from matching.
/// 4. Every offset in the band (keeping ≥ 15 % overlap) is scored by the
///    hash match ratio of informative rows; ≥ 0.9 is accepted. Ties (repeating
///    content) go to the offset nearest the auto-scroll hint, otherwise to the
///    largest overlap. If nothing passes, a tolerant pass on the descriptors
///    handles noisy or anti-aliased frames.
/// 5. Only rows below what is already committed are appended; the header is
///    kept once from the first frame and the footer comes from the last frame.
public struct ScrollStitcher: Sendable {
    public let configuration: ScrollStitcherConfiguration

    /// Resolved scroll axis; `nil` while automatic detection has not decided.
    public private(set) var axis: StitchAxis?
    /// Frames accepted so far (the first frame plus every `.appended`).
    public private(set) var acceptedFrameCount = 0
    /// `true` after `.limitReached`; later frames are ignored.
    public private(set) var isAtLengthLimit = false

    private var colorSpace: CGColorSpace?
    private var rawWidth = 0
    private var rawHeight = 0
    /// Last accepted frame, canonical orientation (vertical until the axis is known).
    private var reference: StitchFrame?
    /// Stitched rows (canonical orientation), `canvasWidth` pixels each.
    private var canvas: [UInt32] = []
    private var canvasRows = 0
    /// Rows of `reference` from here on are not yet in `canvas`.
    private var committedEnd = 0
    private var hasCommitted = false

    public init(configuration: ScrollStitcherConfiguration = ScrollStitcherConfiguration()) {
        self.configuration = configuration
        self.axis = configuration.axis
    }

    // MARK: Public API

    /// Adds a frame. `expectedDelta` is the content movement since the last
    /// accepted frame in pixels along the axis, if known (auto-scroll); it only
    /// breaks ties between equally good offsets.
    public mutating func append(_ image: CGImage, expectedDelta: Int? = nil) -> StitchEvent {
        if isAtLengthLimit { return .limitReached(totalLength: stitchedLength) }
        let space = colorSpace ?? StitchPixels.workingColorSpace(for: image)
        guard let raw = StitchPixels(image: image, colorSpace: space) else {
            return .rejected(.unreadableFrame)
        }
        return append(raw: raw, colorSpace: space, expectedDelta: expectedDelta)
    }

    /// Current stitched length along the scroll axis, in pixels.
    public var stitchedLength: Int {
        guard let reference else { return 0 }
        let tail = hasCommitted ? reference.pixels.height - committedEnd : reference.pixels.height
        return min(canvasRows + tail, configuration.maximumLength)
    }

    /// Pixel size of ``makeImage()``'s result.
    public var stitchedPixelSize: (width: Int, height: Int) {
        guard let reference else { return (0, 0) }
        let across = reference.pixels.width
        return axis == .horizontal ? (stitchedLength, across) : (across, stitchedLength)
    }

    /// The stitched image so far (header once, all content, footer of the last
    /// accepted frame). `nil` before the first frame.
    public func makeImage() -> CGImage? {
        guard let reference, let colorSpace else { return nil }
        let w = reference.pixels.width
        let length = stitchedLength
        var rows: [UInt32]
        if hasCommitted {
            rows = canvas
            let tailRows = min(reference.pixels.height - committedEnd, max(0, length - canvasRows))
            if tailRows > 0 {
                rows.append(contentsOf: reference.pixels.pixels[(committedEnd * w)..<((committedEnd + tailRows) * w)])
            }
            if rows.count > length * w { rows.removeLast(rows.count - length * w) }
        } else {
            rows = Array(reference.pixels.pixels.prefix(length * w))
        }
        var out = StitchPixels(width: w, height: rows.count / max(1, w), pixels: rows)
        if axis == .horizontal { out = out.transposed() }
        return out.makeImage(colorSpace: colorSpace)
    }

    /// Downscaled thumbnail of the current result whose longer side is at most
    /// `maxDimension` pixels. Cost is proportional to the stitched area read
    /// once (vImage box/Lanczos scaling); fine at a few Hz.
    public func previewImage(maxDimension: Int) -> CGImage? {
        guard let reference, let colorSpace, maxDimension > 0 else { return nil }
        let w = reference.pixels.width
        let tailStart = hasCommitted ? committedEnd : 0
        let tailRows = max(0, min(reference.pixels.height - tailStart, stitchedLength - (hasCommitted ? canvasRows : 0)))
        let bodyRows = hasCommitted ? min(canvasRows, stitchedLength) : 0
        let length = bodyRows + tailRows
        guard length > 0 else { return nil }

        let scale = min(1, Double(maxDimension) / Double(max(w, length)))
        let outW = max(1, Int((Double(w) * scale).rounded()))
        let outBody = bodyRows > 0 ? max(1, Int((Double(bodyRows) * scale).rounded())) : 0
        let outTail = tailRows > 0 ? max(1, Int((Double(tailRows) * scale).rounded())) : 0
        let outH = outBody + outTail
        var out = [UInt32](repeating: 0, count: outW * outH)

        out.withUnsafeMutableBytes { dstRaw in
            guard let dstBase = dstRaw.baseAddress else { return }
            if outBody > 0 {
                canvas.withUnsafeBytes { srcRaw in
                    guard let srcBase = srcRaw.baseAddress else { return }
                    Self.scale(src: srcBase, width: w, rows: bodyRows, dst: dstBase, outW: outW, outRows: outBody)
                }
            }
            if outTail > 0 {
                reference.pixels.pixels.withUnsafeBytes { srcRaw in
                    guard let srcBase = srcRaw.baseAddress else { return }
                    Self.scale(
                        src: srcBase + tailStart * w * 4, width: w, rows: tailRows,
                        dst: dstBase + outBody * outW * 4, outW: outW, outRows: outTail
                    )
                }
            }
        }
        var thumb = StitchPixels(width: outW, height: outH, pixels: out)
        if axis == .horizontal { thumb = thumb.transposed() }
        return thumb.makeImage(colorSpace: colorSpace)
    }

    // MARK: Core

    mutating func append(raw: StitchPixels, colorSpace space: CGColorSpace, expectedDelta: Int?) -> StitchEvent {
        guard let previous = reference else {
            colorSpace = space
            rawWidth = raw.width
            rawHeight = raw.height
            let canonical = axis == .horizontal ? raw.transposed() : raw
            reference = StitchFrame(pixels: canonical, scrollBarInset: configuration.scrollBarInset)
            acceptedFrameCount = 1
            return .started
        }
        guard raw.width == rawWidth, raw.height == rawHeight else { return .rejected(.sizeMismatch) }

        let parameters = StitchMatcher.Parameters(
            minimumOverlapFraction: configuration.minimumOverlapFraction,
            matchThreshold: configuration.matchThreshold,
            noiseTolerance: configuration.noiseTolerance,
            hint: expectedDelta
        )

        if let axis {
            let current = StitchFrame(pixels: axis == .horizontal ? raw.transposed() : raw, scrollBarInset: configuration.scrollBarInset)
            let outcome = StitchMatcher.match(previous: previous.signatures, current: current.signatures, parameters: parameters)
            return apply(outcome, current: current)
        }

        // Automatic axis: try both orientations, lock the one that shows forward movement.
        let verticalCurrent = StitchFrame(pixels: raw, scrollBarInset: configuration.scrollBarInset)
        let vertical = StitchMatcher.match(previous: previous.signatures, current: verticalCurrent.signatures, parameters: parameters)
        let horizontalPrevious = StitchFrame(pixels: previous.pixels.transposed(), scrollBarInset: configuration.scrollBarInset)
        let horizontalCurrent = StitchFrame(pixels: raw.transposed(), scrollBarInset: configuration.scrollBarInset)
        let horizontal = StitchMatcher.match(previous: horizontalPrevious.signatures, current: horizontalCurrent.signatures, parameters: parameters)

        func forwardConfidence(_ outcome: StitchMatchOutcome) -> Double? {
            if case .match(let m) = outcome, m.offset > 0 { return m.confidence }
            return nil
        }
        switch (forwardConfidence(vertical), forwardConfidence(horizontal)) {
        case let (v?, h?):
            if h > v { return lock(.horizontal, previous: horizontalPrevious, outcome: horizontal, current: horizontalCurrent) }
            return lock(.vertical, previous: previous, outcome: vertical, current: verticalCurrent)
        case (_?, nil):
            return lock(.vertical, previous: previous, outcome: vertical, current: verticalCurrent)
        case (nil, _?):
            return lock(.horizontal, previous: horizontalPrevious, outcome: horizontal, current: horizontalCurrent)
        case (nil, nil):
            if vertical == .duplicate || horizontal == .duplicate { return .duplicate }
            if case .match(let m) = vertical { return .rejected(.backward(offset: -m.offset)) }
            if case .match(let m) = horizontal { return .rejected(.backward(offset: -m.offset)) }
            return .rejected(.tooFast)
        }
    }

    private mutating func lock(_ newAxis: StitchAxis, previous: StitchFrame, outcome: StitchMatchOutcome, current: StitchFrame) -> StitchEvent {
        axis = newAxis
        reference = previous
        return apply(outcome, current: current)
    }

    private mutating func apply(_ outcome: StitchMatchOutcome, current: StitchFrame) -> StitchEvent {
        let match: StitchMatch
        switch outcome {
        case .duplicate: return .duplicate
        case .noMatch: return .rejected(.tooFast)
        case .match(let m): match = m
        }
        guard match.offset > 0 else { return .rejected(.backward(offset: -match.offset)) }
        guard let previous = reference else { return .rejected(.tooFast) }

        let w = current.pixels.width
        let h = current.pixels.height
        let bandStart = match.leadingStatic
        let bandEnd = h - match.trailingStatic
        let d = match.offset

        var end = committedEnd
        if !hasCommitted {
            end = bandEnd
        }
        let start = end - d
        guard start >= bandStart else { return .rejected(.tooFast) }

        if !hasCommitted {
            canvas.reserveCapacity(min(configuration.maximumLength, h * 8) * w)
            canvas.append(contentsOf: previous.pixels.pixels[0..<(bandEnd * w)])
            canvasRows = bandEnd
            hasCommitted = true
        }
        let added = max(0, bandEnd - start)
        if added > 0 {
            canvas.append(contentsOf: current.pixels.pixels[(start * w)..<(bandEnd * w)])
            canvasRows += added
        }
        committedEnd = max(start, bandEnd)
        reference = current
        acceptedFrameCount += 1

        let total = canvasRows + (h - committedEnd)
        if total >= configuration.maximumLength {
            isAtLengthLimit = true
            return .limitReached(totalLength: stitchedLength)
        }
        return .appended(StitchStep(
            offset: d, addedLength: added, totalLength: total,
            confidence: match.confidence, ambiguous: match.ambiguous, axis: axis ?? .vertical
        ))
    }

    private static func scale(src: UnsafeRawPointer, width: Int, rows: Int, dst: UnsafeMutableRawPointer, outW: Int, outRows: Int) {
        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(rows),
            width: vImagePixelCount(width), rowBytes: width * 4
        )
        var destination = vImage_Buffer(
            data: dst, height: vImagePixelCount(outRows),
            width: vImagePixelCount(outW), rowBytes: outW * 4
        )
        _ = vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
    }
}
