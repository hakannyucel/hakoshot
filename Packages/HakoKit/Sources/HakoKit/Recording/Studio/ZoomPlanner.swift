import CoreGraphics
import Foundation

/// Auto zoom segments from clicks (plan §4.20, "Smart Zooms").
///
/// 1. Only mouse-downs inside the edit (not trimmed or cut away) count; all
///    buttons; the second down of a double-click is dropped. Click times are
///    media seconds, so pauses are already gone.
/// 2. Clustering: consecutive clicks at most `clusterMaxGap` apart **and**
///    the cluster's bounding box fits `clusterFitFraction` of the zoomed
///    view (`recording size / scale`).
/// 3. Segment: `first − leadIn … last + holdAfterLastClick + transition`
///    (normal speed: −0.6 / +1.8 s), at least `minimumDuration`, clamped to
///    the trim range; segments less than `mergeGap` apart merge.
/// 4. Focus: `.followCursor` (default) or the cluster centroid (`.fixed`).
/// 5. Auto segments never overlap manual ones: they are cut around them and
///    fragments shorter than `minimumFragment` are dropped.
///
/// Every threshold lives in `Parameters` (plan: default choices).
public enum ZoomPlanner {
    public enum FocusMode: String, Sendable, Hashable, CaseIterable {
        /// `ZoomFocus.followCursor` (plan default).
        case followCursor
        /// `ZoomFocus.fixed` at the cluster's centroid.
        case clusterCenter
    }

    public struct Parameters: Sendable, Hashable {
        /// Largest gap between consecutive clicks of one cluster, seconds.
        public var clusterMaxGap: Double
        /// The cluster's bounding box must fit this fraction of the zoomed view.
        public var clusterFitFraction: Double
        /// Zoom starts at least this long before the first click, seconds.
        public var leadIn: Double
        /// …and at least `transition + transitionMargin` before it, so the
        /// zoom-in has finished when the click lands (slow speed).
        public var transitionMargin: Double
        /// Full zoom kept after the last click before the zoom-out starts;
        /// `end = last + hold + transition` (normal: 1.3 + 0.5 = 1.8 s).
        public var holdAfterLastClick: Double
        public var minimumDuration: Double
        /// Segments closer than this merge, seconds.
        public var mergeGap: Double
        /// A down with `clickCount ≥ 2` this close to the previous one is
        /// part of a double-click and ignored.
        public var doubleClickInterval: Double
        /// Auto fragments left after cutting around manual segments are kept
        /// only when at least this long, seconds.
        public var minimumFragment: Double
        public var focus: FocusMode

        public init(
            clusterMaxGap: Double = 2.5,
            clusterFitFraction: Double = 0.8,
            leadIn: Double = 0.6,
            transitionMargin: Double = 0.1,
            holdAfterLastClick: Double = 1.3,
            minimumDuration: Double = 1.5,
            mergeGap: Double = 1.0,
            doubleClickInterval: Double = 0.5,
            minimumFragment: Double = 1.0,
            focus: FocusMode = .followCursor
        ) {
            self.clusterMaxGap = clusterMaxGap
            self.clusterFitFraction = clusterFitFraction
            self.leadIn = leadIn
            self.transitionMargin = transitionMargin
            self.holdAfterLastClick = holdAfterLastClick
            self.minimumDuration = minimumDuration
            self.mergeGap = mergeGap
            self.doubleClickInterval = doubleClickInterval
            self.minimumFragment = minimumFragment
            self.focus = focus
        }

        public static let standard = Parameters()

        /// Seconds before the first click the zoom starts at `speed`.
        public func leadIn(for speed: StudioZoomSpeed) -> Double {
            max(leadIn, speed.transitionDuration + transitionMargin)
        }

        /// Seconds after the last click the zoom ends at `speed`.
        public func leadOut(for speed: StudioZoomSpeed) -> Double {
            holdAfterLastClick + speed.transitionDuration
        }
    }

    // MARK: Project

    /// Fresh auto segments for `project` (not overlapping its manual
    /// segments), ready for `StudioAction.replaceAutoZoomSegments`. Empty
    /// without metadata.
    public static func autoSegments(
        project: StudioProject,
        metadata: RecordingMetadata?,
        parameters: Parameters = .standard
    ) -> [ZoomSegment] {
        guard let metadata else { return [] }
        return plan(
            clicks: metadata.clicks,
            pointSize: pointSize(project: project, metadata: metadata),
            timeline: project.timeline,
            scale: project.zoom.defaultScale,
            speed: project.zoom.speed,
            manual: project.zoom.segments.filter(\.isManual),
            parameters: parameters
        )
    }

    /// The project's manual segments plus fresh auto segments, sorted.
    public static func regenerated(
        project: StudioProject,
        metadata: RecordingMetadata?,
        parameters: Parameters = .standard
    ) -> [ZoomSegment] {
        let manual = project.zoom.segments.filter(\.isManual)
        let auto = autoSegments(project: project, metadata: metadata, parameters: parameters)
        return (manual + auto).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Recording rect size in the points clicks and cursor samples use.
    public static func pointSize(project: StudioProject, metadata: RecordingMetadata?) -> CGSize {
        let ppp = metadata?.geometry.pixelsPerPoint ?? project.source.pixelsPerPoint
        let k = ppp > 0 && ppp.isFinite ? ppp : 1
        return CGSize(width: Double(project.source.pixelWidth) / k, height: Double(project.source.pixelHeight) / k)
    }

    // MARK: Core

    /// Auto segments (`isManual == false`) for `clicks`, sorted.
    ///
    /// - Parameters:
    ///   - pointSize: recording rect size in points (click coordinate space).
    ///   - timeline: segments are clamped to its trim; clicks it removes are ignored.
    ///   - scale: zoom scale of the new segments (settings "Default zoom").
    ///   - manual: segments the result must not overlap.
    public static func plan(
        clicks: [RecordingClickEvent],
        pointSize: CGSize,
        timeline: EditTimeline,
        scale: Double,
        speed: StudioZoomSpeed = .normal,
        manual: [ZoomSegment] = [],
        parameters: Parameters = .standard
    ) -> [ZoomSegment] {
        let scale = clampFinite(scale, ZoomSegment.scaleRange.lowerBound, ZoomSegment.scaleRange.upperBound,
                                fallback: StudioZoomSettings.defaultScale)
        let usable = usableClicks(clicks, timeline: timeline, parameters: parameters)
        let groups = clusters(usable, pointSize: pointSize, scale: scale, parameters: parameters)
        let lo = timeline.trim.start, hi = timeline.trim.end
        guard hi > lo else { return [] }

        // Cluster → interval.
        var intervals: [(start: Double, end: Double, clicks: [RecordingClickEvent])] = []
        let leadIn = parameters.leadIn(for: speed), leadOut = parameters.leadOut(for: speed)
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            var start = max(lo, first.time - leadIn)
            var end = min(hi, last.time + leadOut)
            if end - start < parameters.minimumDuration {
                end = min(hi, start + parameters.minimumDuration)
                start = max(lo, end - parameters.minimumDuration)
            }
            guard end > start else { continue }
            intervals.append((start, end, group))
        }

        // Merge close ones.
        intervals.sort { $0.start < $1.start }
        var merged: [(start: Double, end: Double, clicks: [RecordingClickEvent])] = []
        for item in intervals {
            if let last = merged.last, item.start - last.end < parameters.mergeGap {
                merged[merged.count - 1].end = max(last.end, item.end)
                merged[merged.count - 1].clicks += item.clicks
            } else {
                merged.append(item)
            }
        }

        // Cut around manual segments.
        let blocked = manual.map { $0.normalized() }.filter { $0.end > $0.start }
            .map { (start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        var result: [ZoomSegment] = []
        for item in merged {
            let focus = focus(for: item.clicks, pointSize: pointSize, mode: parameters.focus)
            for piece in subtract(start: item.start, end: item.end, blocked: blocked)
            where piece.end - piece.start >= parameters.minimumFragment - 1e-9 {
                result.append(ZoomSegment(start: piece.start, end: piece.end, scale: scale, focus: focus,
                                          easing: .easeInOutCubic, isManual: false))
            }
        }
        return result
    }

    /// Mouse-downs inside the edit, time-sorted, double-click repeats removed.
    public static func usableClicks(
        _ clicks: [RecordingClickEvent],
        timeline: EditTimeline,
        parameters: Parameters = .standard
    ) -> [RecordingClickEvent] {
        let downs = clicks
            .filter { $0.isDown && $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
            .filter { timeline.outputTime(forSource: $0.time) != nil }
            .sorted { $0.time < $1.time }
        var kept: [RecordingClickEvent] = []
        for click in downs {
            if click.clickCount >= 2, let previous = kept.last,
               click.time - previous.time <= parameters.doubleClickInterval {
                continue
            }
            kept.append(click)
        }
        return kept
    }

    /// Groups time-sorted clicks (plan §4.20 step 2).
    public static func clusters(
        _ clicks: [RecordingClickEvent],
        pointSize: CGSize,
        scale: Double,
        parameters: Parameters = .standard
    ) -> [[RecordingClickEvent]] {
        let s = max(scale, 1)
        let maxWidth = Double(pointSize.width) / s * parameters.clusterFitFraction
        let maxHeight = Double(pointSize.height) / s * parameters.clusterFitFraction
        var groups: [[RecordingClickEvent]] = []
        var current: [RecordingClickEvent] = []
        var box = (minX: 0.0, minY: 0.0, maxX: 0.0, maxY: 0.0)
        for click in clicks {
            if let last = current.last, click.time - last.time <= parameters.clusterMaxGap {
                let grown = (minX: min(box.minX, click.x), minY: min(box.minY, click.y),
                             maxX: max(box.maxX, click.x), maxY: max(box.maxY, click.y))
                if grown.maxX - grown.minX <= maxWidth, grown.maxY - grown.minY <= maxHeight {
                    current.append(click)
                    box = grown
                    continue
                }
            }
            if !current.isEmpty { groups.append(current) }
            current = [click]
            box = (click.x, click.y, click.x, click.y)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: Internals

    static func focus(for clicks: [RecordingClickEvent], pointSize: CGSize, mode: FocusMode) -> ZoomFocus {
        guard mode == .clusterCenter, !clicks.isEmpty, pointSize.width > 0, pointSize.height > 0 else {
            return .followCursor
        }
        let n = Double(clicks.count)
        let cx = clicks.reduce(0) { $0 + $1.x } / n
        let cy = clicks.reduce(0) { $0 + $1.y } / n
        return .fixed(x: clampFinite(cx / Double(pointSize.width), 0, 1, fallback: 0.5),
                      y: clampFinite(cy / Double(pointSize.height), 0, 1, fallback: 0.5))
    }

    /// `[start, end]` minus the (sorted) blocked intervals.
    static func subtract(start: Double, end: Double,
                         blocked: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        var pieces: [(start: Double, end: Double)] = []
        var cursor = start
        for b in blocked where b.end > cursor && b.start < end {
            if b.start > cursor { pieces.append((cursor, b.start)) }
            cursor = max(cursor, b.end)
            if cursor >= end { break }
        }
        if end > cursor { pieces.append((cursor, end)) }
        return pieces
    }
}
