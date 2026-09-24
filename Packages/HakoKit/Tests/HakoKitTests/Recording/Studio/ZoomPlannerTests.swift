import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("ZoomPlanner")
struct ZoomPlannerTests {
    static let size = CGSize(width: 1000, height: 600)

    static func click(_ t: Double, _ x: Double, _ y: Double, down: Bool = true, count: Int = 1,
                      button: RecordingMouseButton = .left) -> RecordingClickEvent {
        RecordingClickEvent(time: t, x: x, y: y, button: button, isDown: down, clickCount: count)
    }

    static func plan(_ clicks: [RecordingClickEvent], duration: Double = 30, trim: EditTimeRange? = nil,
                     cuts: [EditTimeRange] = [], scale: Double = 2, speed: StudioZoomSpeed = .normal,
                     manual: [ZoomSegment] = [], parameters: ZoomPlanner.Parameters = .standard) -> [ZoomSegment] {
        ZoomPlanner.plan(clicks: clicks, pointSize: size,
                         timeline: EditTimeline(sourceDuration: duration, trim: trim, cuts: cuts),
                         scale: scale, speed: speed, manual: manual, parameters: parameters)
    }

    /// 1000 × 600 pt recording at 2 px/pt.
    static func metadata(clicks: [RecordingClickEvent], cursorBakedIn: Bool = false) -> RecordingMetadata {
        RecordingMetadata(hostTimeOrigin: 0,
                          geometry: RecordingGeometryInfo(rect: CGRect(x: 0, y: 0, width: 1000, height: 600), displayID: 1,
                                                          scale: 2, pixelWidth: 2000, pixelHeight: 1200),
                          clicks: clicks, cursorBakedIn: cursorBakedIn)
    }

    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func singleClickTiming() throws {
        let segments = Self.plan([Self.click(5, 100, 100)])
        let s = try #require(segments.first)
        #expect(segments.count == 1)
        #expect(Self.near(s.start, 4.4) && Self.near(s.end, 6.8)) // −0.6 / +1.8
        #expect(s.scale == 2)
        #expect(s.focus == .followCursor)
        #expect(!s.isManual)
        #expect(s.easing == .easeInOutCubic)
    }

    @Test func speedChangesLeadInAndOut() throws {
        let slow = try #require(Self.plan([Self.click(5, 100, 100)], speed: .slow).first)
        #expect(Self.near(slow.start, 4.1) && Self.near(slow.end, 7.1)) // 0.8 + 0.1 / 1.3 + 0.8
        let fast = try #require(Self.plan([Self.click(5, 100, 100)], speed: .fast).first)
        #expect(Self.near(fast.start, 4.4) && Self.near(fast.end, 6.6))
    }

    @Test func clustersCloseClicks() {
        // 2 s apart, 100 pt apart: one cluster → one segment 0.4 … 6.8.
        let segments = Self.plan([Self.click(1, 100, 100), Self.click(3, 200, 150), Self.click(5, 150, 120)])
        #expect(segments.count == 1)
        #expect(Self.near(segments[0].start, 0.4) && Self.near(segments[0].end, 6.8))
    }

    @Test func clusterSplitsOnTimeAndSpace() {
        let clicks = [Self.click(1, 100, 100), Self.click(4, 100, 100), // 3 s gap
                      Self.click(5, 900, 500)] // far away
        let groups = ZoomPlanner.clusters(clicks, pointSize: Self.size, scale: 2)
        #expect(groups.map(\.count) == [1, 1, 1])
        // Zoomed view at 2× is 500 × 300 pt; 80 % = 400 × 240.
        let fits = ZoomPlanner.clusters([Self.click(1, 0, 0), Self.click(2, 400, 240)], pointSize: Self.size, scale: 2)
        #expect(fits.count == 1)
        let tooWide = ZoomPlanner.clusters([Self.click(1, 0, 0), Self.click(2, 401, 0)], pointSize: Self.size, scale: 2)
        #expect(tooWide.count == 2)
    }

    @Test func mergesSegmentsWithSmallGap() {
        // Far apart in space → two clusters; segments 0.4…2.8 and 3.4…5.8 (gap 0.6 < 1) merge.
        let merged = Self.plan([Self.click(1, 50, 50), Self.click(4, 950, 550)])
        #expect(merged.count == 1)
        #expect(Self.near(merged[0].start, 0.4) && Self.near(merged[0].end, 5.8))
        // Gap 1.2 s → separate.
        let apart = Self.plan([Self.click(1, 50, 50), Self.click(4.6, 950, 550)])
        #expect(apart.count == 2)
        #expect(apart[1].start - apart[0].end >= 1.0)
    }

    @Test func clampsToTrim() throws {
        let head = try #require(Self.plan([Self.click(0.2, 100, 100)]).first)
        #expect(head.start == 0)
        #expect(head.end >= 1.5)
        let tail = try #require(Self.plan([Self.click(9.9, 100, 100)], duration: 10).first)
        #expect(tail.end == 10)
        #expect(Self.near(tail.start, 8.5)) // 9.3 … 10 widened back to 1.5 s
        let trimmed = try #require(Self.plan([Self.click(3, 100, 100)], trim: EditTimeRange(start: 2.8, end: 8)).first)
        #expect(trimmed.start == 2.8)
    }

    @Test func minimumDuration() throws {
        // Trim end 5.5: 4.4 … 5.5 is 1.1 s → widened back to 4.0 … 5.5.
        let s = try #require(Self.plan([Self.click(5, 100, 100)], trim: EditTimeRange(start: 0, end: 5.5)).first)
        #expect(Self.near(s.start, 4.0) && s.end == 5.5)
        // Plenty of room: never shorter than 1.5 s.
        for seg in Self.plan([Self.click(1, 10, 10), Self.click(8, 10, 10), Self.click(20, 10, 10)]) {
            #expect(seg.duration >= 1.5 - 1e-9)
        }
    }

    @Test func ignoresUpsCutsTrimAndDoubleClicks() {
        let clicks = [Self.click(1, 100, 100, down: false),
                      Self.click(3, 100, 100), Self.click(3.2, 100, 100, count: 2),
                      Self.click(12, 100, 100), // cut
                      Self.click(25, 100, 100)] // trimmed away
        let usable = ZoomPlanner.usableClicks(clicks, timeline: EditTimeline(
            sourceDuration: 30, trim: EditTimeRange(start: 0, end: 20), cuts: [EditTimeRange(start: 11, end: 13)]))
        #expect(usable.map(\.time) == [3])
        // Right clicks count.
        #expect(Self.plan([Self.click(5, 10, 10, button: .right)]).count == 1)
    }

    @Test func clusterCenterFocus() throws {
        var p = ZoomPlanner.Parameters()
        p.focus = .clusterCenter
        let s = try #require(Self.plan([Self.click(1, 100, 60), Self.click(2, 300, 180)], parameters: p).first)
        #expect(s.focus == .fixed(x: 0.2, y: 0.2))
    }

    @Test func defaultScaleIsUsedAndClamped() {
        #expect(Self.plan([Self.click(5, 10, 10)], scale: 3).first?.scale == 3)
        #expect(Self.plan([Self.click(5, 10, 10)], scale: 40).first?.scale == 6)
    }

    @Test func avoidsManualSegments() {
        let manual = ZoomSegment(start: 5, end: 6, scale: 3, isManual: true)
        // Auto would be 4.4 … 8.8 → cut to 6 … 8.8 (4.4 … 5 is 0.6 s, dropped).
        let auto = Self.plan([Self.click(5, 100, 100), Self.click(7, 100, 100)], manual: [manual])
        #expect(auto.count == 1)
        #expect(Self.near(auto[0].start, 6) && Self.near(auto[0].end, 8.8))
        for a in auto { #expect(a.end <= manual.start || a.start >= manual.end) }
    }

    @Test func regenerationKeepsManualSegments() {
        let manual = ZoomSegment(start: 2, end: 4, scale: 3, focus: .fixed(x: 0.1, y: 0.1), isManual: true)
        let staleAuto = ZoomSegment(start: 10, end: 12, isManual: false)
        var project = StudioProject(source: StudioSource(pixelWidth: 2000, pixelHeight: 1200, pointWidth: 1000,
                                                         pointHeight: 600, duration: 20))
        project.zoom.segments = [manual, staleAuto]
        let metadata = Self.metadata(clicks: [Self.click(3, 100, 100), Self.click(15, 500, 300)])

        let all = ZoomPlanner.regenerated(project: project, metadata: metadata)
        #expect(all.contains(manual))
        #expect(!all.contains { $0.id == staleAuto.id })
        let auto = all.filter { !$0.isManual }
        #expect(auto.count == 1)
        #expect(Self.near(auto[0].start, 14.4) && Self.near(auto[0].end, 16.8))
        for a in auto { #expect(a.end <= manual.start || a.start >= manual.end) }
        #expect(all == all.sorted { $0.start < $1.start })

        // Through the reducer: manual kept, auto replaced.
        var state = StudioEditorState(project: project)
        StudioReducer.reduce(&state, .replaceAutoZoomSegments(ZoomPlanner.autoSegments(project: project, metadata: metadata)))
        #expect(state.project.zoom.segments.filter(\.isManual) == [manual])
        #expect(state.project.zoom.segments.filter { !$0.isManual }.count == 1)
    }

    @Test func noMetadataNoSegments() {
        let project = StudioProject(source: StudioSource(pixelWidth: 100, pixelHeight: 100, duration: 5))
        #expect(ZoomPlanner.autoSegments(project: project, metadata: nil).isEmpty)
    }
}
