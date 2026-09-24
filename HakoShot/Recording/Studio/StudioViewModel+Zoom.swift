import Foundation
import HakoKit

/// Zoom lane actions (plan §4.20, R7.2). Every change is an undo step;
/// drags are coalesced into one ("Move Zoom" / "Resize Zoom"). Editing an
/// auto segment makes it manual (`StudioAction.updateZoomSegment`), so
/// "Regenerate auto zooms" keeps it.
extension StudioViewModel {
    /// Default length of a zoom added by double-click, seconds.
    static let newZoomDuration = 2.0
    /// Shortest zoom a resize allows, seconds.
    static let minimumZoomDuration = 0.3

    var zoomSegments: [ZoomSegment] { project.zoom.segments }
    var selectedZoomID: ZoomSegment.ID? { store.selectedZoomSegment }
    var selectedZoom: ZoomSegment? { store.state.selectedSegment }

    func selectZoom(_ id: ZoomSegment.ID?) {
        store.apply(.selectZoomSegment(id))
        if id != nil {
            selectedCut = nil
            rangeSelection = nil
            inspectorTab = .zoom
        }
    }

    /// Adds a manual zoom centered on source time `t` (default scale,
    /// following the cursor) and selects it.
    @discardableResult
    func addZoom(atSourceTime t: Double) -> ZoomSegment {
        let duration = min(Self.newZoomDuration, max(sourceDuration, Self.minimumZoomDuration))
        var start = t - duration / 2
        start = min(max(start, 0), max(sourceDuration - duration, 0))
        let segment = ZoomSegment(start: start, end: min(start + duration, sourceDuration),
                                  scale: project.zoom.defaultScale, focus: .followCursor, isManual: true)
        apply(.addZoomSegment(segment))
        selectedCut = nil
        rangeSelection = nil
        inspectorTab = .zoom
        return segment
    }

    /// Replaces the segment with the same ID (clamped to the source).
    func updateZoom(_ segment: ZoomSegment) {
        var s = segment
        s.start = min(max(s.start, 0), sourceDuration)
        s.end = min(max(s.end, s.start + Self.minimumZoomDuration), sourceDuration)
        if s.end - s.start < Self.minimumZoomDuration { s.start = max(0, s.end - Self.minimumZoomDuration) }
        apply(.updateZoomSegment(s))
    }

    /// `original` moved by `delta` seconds, keeping its length inside the source.
    func movedZoom(_ original: ZoomSegment, by delta: Double) -> ZoomSegment {
        var s = original
        let length = original.duration
        let start = min(max(original.start + delta, 0), max(sourceDuration - length, 0))
        s.start = start
        s.end = start + length
        return s
    }

    /// `original` with one edge moved by `delta` seconds.
    func resizedZoom(_ original: ZoomSegment, leading: Bool, by delta: Double) -> ZoomSegment {
        var s = original
        if leading {
            s.start = min(max(original.start + delta, 0), original.end - Self.minimumZoomDuration)
        } else {
            s.end = max(min(original.end + delta, sourceDuration), original.start + Self.minimumZoomDuration)
        }
        return s
    }

    func deleteZoom(_ id: ZoomSegment.ID) {
        apply(.removeZoomSegment(id))
    }

    /// Replaces the auto segments with a fresh plan from the clicks
    /// (`ZoomPlanner.regenerated`); manual segments stay.
    func regenerateAutoZooms() {
        let fresh = ZoomPlanner.regenerated(project: project, metadata: metadata).filter { !$0.isManual }
        apply(.replaceAutoZoomSegments(fresh))
        showStatus(fresh.isEmpty ? "No clicks to zoom on" : "\(fresh.count) auto zoom\(fresh.count == 1 ? "" : "s")")
    }

    /// Auto zoom on: plan auto segments; off: drop them. One undo step.
    func setAutoZoom(_ on: Bool) {
        beginInteraction("Auto Zoom")
        apply(.setAutoZoom(on))
        if on {
            let fresh = ZoomPlanner.regenerated(project: project, metadata: metadata).filter { !$0.isManual }
            apply(.replaceAutoZoomSegments(fresh))
        } else {
            apply(.replaceAutoZoomSegments([]))
        }
        endInteraction()
    }

    /// Edits the selected segment (scale / focus / easing), as one step
    /// per call (sliders wrap it in an interaction).
    func updateSelectedZoom(_ change: (inout ZoomSegment) -> Void) {
        guard var segment = selectedZoom else { return }
        change(&segment)
        apply(.updateZoomSegment(segment))
    }
}
