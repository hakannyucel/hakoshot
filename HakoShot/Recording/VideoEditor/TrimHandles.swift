import HakoKit
import SwiftUI

/// Timeline x ↔ source time mapping. The track (thumbnail strip) sits
/// between the two trim handles' widths so the handles can sit outside the
/// kept range without covering it: track x = `inset … inset + trackWidth`.
nonisolated struct TimelineGeometry: Equatable {
    /// Whole timeline width in points.
    var width: CGFloat
    var duration: Double
    var handleWidth: CGFloat = VideoEditorMetrics.trimHandleWidth

    enum DragTarget: Equatable {
        case trimStart
        case trimEnd
        case playhead
    }

    var inset: CGFloat { handleWidth }
    var trackWidth: CGFloat { max(1, width - 2 * handleWidth) }

    func x(for time: Double) -> CGFloat {
        guard duration > 0 else { return inset }
        let fraction = min(max(time / duration, 0), 1)
        return inset + CGFloat(fraction) * trackWidth
    }

    func time(for x: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        let fraction = min(max((x - inset) / trackWidth, 0), 1)
        return Double(fraction) * duration
    }

    /// Left handle occupies `x(start) - handleWidth … x(start)`, the right
    /// one `x(end) … x(end) + handleWidth`.
    func startHandleRect(trim: EditTimeRange, height: CGFloat) -> CGRect {
        CGRect(x: x(for: trim.start) - handleWidth, y: 0, width: handleWidth, height: height)
    }

    func endHandleRect(trim: EditTimeRange, height: CGFloat) -> CGRect {
        CGRect(x: x(for: trim.end), y: 0, width: handleWidth, height: height)
    }

    /// What a press at `x` drags: a handle when it hits one (with `slop`
    /// points of tolerance; the nearer wins when both do), else the playhead.
    func dragTarget(at x: CGFloat, trim: EditTimeRange, slop: CGFloat = 4) -> DragTarget {
        let start = startHandleRect(trim: trim, height: 1).insetBy(dx: -slop, dy: 0)
        let end = endHandleRect(trim: trim, height: 1).insetBy(dx: -slop, dy: 0)
        let hitsStart = x >= start.minX && x <= start.maxX
        let hitsEnd = x >= end.minX && x <= end.maxX
        switch (hitsStart, hitsEnd) {
        case (true, true): return abs(x - start.maxX) <= abs(x - end.minX) ? .trimStart : .trimEnd
        case (true, false): return .trimStart
        case (false, true): return .trimEnd
        case (false, false): return .playhead
        }
    }
}

/// Yellow QuickTime-style trim frame (plan §4.16): the kept range framed in
/// `editorTrimHandleColor`, grip handles on both ends, trimmed-out parts of
/// the strip dimmed by `editorTrimmedDimOpacity`.
struct TrimHandles: View {
    let geometry: TimelineGeometry
    let trim: EditTimeRange
    var isActive = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let startX = geometry.x(for: trim.start)
            let endX = geometry.x(for: trim.end)
            let yellow = Color(nsColor: VideoEditorMetrics.trimHandleColor)
            let dim = Color.black.opacity(VideoEditorMetrics.trimmedDimOpacity)
            ZStack(alignment: .topLeading) {
                // Trimmed-out regions (over the strip only).
                let inset = VideoEditorMetrics.trimBorderWidth
                dim.frame(width: max(0, startX - geometry.inset), height: max(0, height - 2 * inset))
                    .offset(x: geometry.inset, y: inset)
                dim.frame(width: max(0, geometry.inset + geometry.trackWidth - endX), height: max(0, height - 2 * inset))
                    .offset(x: endX, y: inset)

                // Frame around the kept range, handles included.
                let frameRect = CGRect(x: startX - geometry.handleWidth, y: 0,
                                       width: endX - startX + 2 * geometry.handleWidth, height: height)
                RoundedRectangle(cornerRadius: VideoEditorMetrics.trimCornerRadius, style: .continuous)
                    .strokeBorder(yellow, lineWidth: VideoEditorMetrics.trimBorderWidth)
                    .frame(width: frameRect.width, height: frameRect.height)
                    .offset(x: frameRect.minX)
                handle(edge: .leading, color: yellow)
                    .frame(width: geometry.handleWidth, height: height)
                    .offset(x: startX - geometry.handleWidth)
                handle(edge: .trailing, color: yellow)
                    .frame(width: geometry.handleWidth, height: height)
                    .offset(x: endX)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func handle(edge: HorizontalEdge, color: Color) -> some View {
        let radius = VideoEditorMetrics.trimCornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? radius : 0,
            bottomLeadingRadius: edge == .leading ? radius : 0,
            bottomTrailingRadius: edge == .trailing ? radius : 0,
            topTrailingRadius: edge == .trailing ? radius : 0,
            style: .continuous
        )
        return shape
            .fill(color)
            .overlay {
                Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.7))
            }
    }
}
