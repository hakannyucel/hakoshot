import AppKit
import HakoKit
import SwiftUI

/// Source time ↔ x mapping of the timeline lanes (all lanes share it).
nonisolated struct StudioTimelineScale: Equatable {
    var duration: Double
    var width: CGFloat

    func x(_ t: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(t / duration, 0), 1)) * width
    }

    func time(_ x: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }

    func seconds(_ dx: CGFloat) -> Double {
        width > 0 ? Double(dx / width) * duration : 0
    }
}

/// Timeline (plan §4.19): controls row, Video lane (thumbnails, trim
/// handles, cuts, range selection), Zoom lane (R7.2), Clicks lane, and
/// the playhead across all of them. Times are source seconds; the
/// playhead maps the player's output time back through the edit.
struct StudioTimelineView: View {
    let model: StudioViewModel

    var body: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            controls
            GeometryReader { proxy in
                let scale = StudioTimelineScale(duration: model.sourceDuration, width: proxy.size.width)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: StudioLayout.laneGap) {
                        StudioVideoLane(model: model, scale: scale)
                            .frame(height: StudioLayout.videoLaneHeight)
                        ZoomLaneView(model: model, scale: scale)
                            .frame(height: Tokens.Recording.studioLaneHeight)
                        StudioClicksLane(model: model, scale: scale)
                            .frame(height: StudioLayout.clicksLaneHeight)
                    }
                    StudioPlayhead(model: model, scale: scale, height: proxy.size.height)
                }
                .coordinateSpace(name: "studio.timeline")
            }
            .frame(height: StudioLayout.videoLaneHeight + Tokens.Recording.studioLaneHeight
                   + StudioLayout.clicksLaneHeight + 2 * StudioLayout.laneGap)
        }
        .padding(.horizontal, StudioLayout.timelineHorizontalInset)
        .padding(.vertical, Tokens.Spacing.s)
    }

    private var controls: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Button {
                model.cutSelection()
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .disabled((model.rangeSelection?.duration ?? 0) <= 0.01)
            .help("Remove the selected range (drag on the video lane to select; ⌫)")

            if let cut = model.selectedCut {
                Button {
                    model.restoreCut(cut)
                } label: {
                    Label("Restore Cut", systemImage: "arrow.uturn.backward")
                }
            }

            Divider().frame(height: 16)

            Button {
                model.addZoom(atSourceTime: model.playheadSourceTime)
            } label: {
                Label("Add Zoom", systemImage: "plus.magnifyingglass")
            }
            .help("Add a zoom at the playhead (or double-click the zoom lane)")

            Button {
                model.regenerateAutoZooms()
            } label: {
                Label("Regenerate Auto Zooms", systemImage: "wand.and.stars")
            }
            .disabled(model.metadata?.clicks.isEmpty ?? true)
            .help("Plan zooms from the recorded clicks again; edited zooms stay")

            Spacer()

            Text("Trim \(StudioTimeFormat.string(model.trimRange.start)) – \(StudioTimeFormat.string(model.trimRange.end))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(height: StudioLayout.timelineControlsHeight)
    }
}

// MARK: - Video lane

struct StudioVideoLane: View {
    let model: StudioViewModel
    let scale: StudioTimelineScale

    @State private var dragStart: Double?
    @State private var trimDragOrigin: EditTimeRange?

    private var radius: CGFloat { StudioLayout.zoomBlockRadius }

    var body: some View {
        let trim = model.trimRange
        ZStack(alignment: .topLeading) {
            thumbnails
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
                .gesture(bodyGesture)

            // Trimmed-away parts.
            dim(from: 0, to: trim.start)
            dim(from: trim.end, to: model.sourceDuration)

            // Cuts.
            ForEach(model.project.edit.cuts, id: \.self) { cut in
                let selected = cut == model.selectedCut
                Rectangle()
                    .fill(Color.black.opacity(Tokens.Recording.editorTrimmedDimOpacity))
                    .overlay(StripeOverlay().opacity(0.6))
                    .overlay(Rectangle().strokeBorder(selected ? Color.white : Color.red.opacity(0.8), lineWidth: selected ? 2 : 1))
                    .frame(width: max(scale.x(cut.end) - scale.x(cut.start), 2))
                    .offset(x: scale.x(cut.start))
                    .onTapGesture {
                        model.selectedCut = cut
                        model.rangeSelection = nil
                        model.selectZoom(nil)
                    }
                    .help("Cut \(StudioTimeFormat.string(cut.start)) – \(StudioTimeFormat.string(cut.end)) (⌫ restores)")
            }

            // Range selection.
            if let range = model.rangeSelection {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.3))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                    .frame(width: max(scale.x(range.end) - scale.x(range.start), 1))
                    .offset(x: scale.x(range.start))
                    .allowsHitTesting(false)
            }

            // Trim frame and handles.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color(nsColor: Tokens.Recording.editorTrimHandleColor), lineWidth: 2)
                .frame(width: max(scale.x(trim.end) - scale.x(trim.start), 2))
                .offset(x: scale.x(trim.start))
                .allowsHitTesting(false)
            trimHandle(leading: true, at: trim.start)
            trimHandle(leading: false, at: trim.end)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var thumbnails: some View {
        GeometryReader { proxy in
            let images = model.thumbnails
            HStack(spacing: 0) {
                if images.isEmpty {
                    Color(nsColor: Tokens.Palette.neutralPillFill)
                } else {
                    ForEach(images.indices, id: \.self) { i in
                        Image(decorative: images[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width / CGFloat(images.count), height: proxy.size.height)
                            .clipped()
                    }
                }
            }
        }
    }

    private func dim(from start: Double, to end: Double) -> some View {
        Rectangle()
            .fill(Color.black.opacity(Tokens.Recording.editorTrimmedDimOpacity))
            .frame(width: max(scale.x(end) - scale.x(start), 0))
            .offset(x: scale.x(start))
            .allowsHitTesting(false)
    }

    private func trimHandle(leading: Bool, at t: Double) -> some View {
        let width = Tokens.Recording.editorTrimHandleWidth
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(nsColor: Tokens.Recording.editorTrimHandleColor))
            .overlay(Capsule().fill(Color.black.opacity(0.45)).frame(width: 2, height: 14))
            .frame(width: width)
            .offset(x: leading ? scale.x(t) : scale.x(t) - width)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if trimDragOrigin == nil {
                            trimDragOrigin = model.trimRange
                            model.beginInteraction("Trim")
                        }
                        guard let origin = trimDragOrigin else { return }
                        let delta = scale.seconds(value.translation.width)
                        if leading {
                            model.setTrim(start: origin.start + delta)
                            model.seek(toSource: model.trimRange.start)
                        } else {
                            model.setTrim(end: origin.end + delta)
                            model.seek(toSource: max(model.trimRange.end - 0.01, 0))
                        }
                    }
                    .onEnded { _ in
                        trimDragOrigin = nil
                        model.endInteraction()
                    }
            )
            .help(leading ? "Trim start" : "Trim end")
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    /// Click = seek (and clear selections); drag = select a range to cut.
    private var bodyGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = scale.time(value.location.x)
                if dragStart == nil { dragStart = scale.time(value.startLocation.x) }
                guard let start = dragStart else { return }
                if abs(value.translation.width) > 3 {
                    model.rangeSelection = EditTimeRange(start: min(start, t), end: max(start, t))
                    model.selectedCut = nil
                    model.selectZoom(nil)
                }
            }
            .onEnded { value in
                defer { dragStart = nil }
                if abs(value.translation.width) <= 3 {
                    model.rangeSelection = nil
                    model.selectedCut = nil
                    model.selectZoom(nil)
                    model.seek(toSource: scale.time(value.location.x))
                }
            }
    }
}

/// Diagonal hatching for cut ranges.
struct StripeOverlay: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 8
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
        .clipped()
    }
}

// MARK: - Clicks lane

struct StudioClicksLane: View {
    let model: StudioViewModel
    let scale: StudioTimelineScale

    var body: some View {
        let clicks = (model.metadata?.clicks ?? []).filter(\.isDown)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(nsColor: Tokens.Palette.neutralPillFill))
                .frame(height: 2)
            ForEach(clicks.indices, id: \.self) { i in
                Circle()
                    .fill(Color(nsColor: Tokens.Recording.clickColor))
                    .frame(width: Tokens.Recording.studioClickMarkerDiameter, height: Tokens.Recording.studioClickMarkerDiameter)
                    .offset(x: scale.x(clicks[i].time) - Tokens.Recording.studioClickMarkerDiameter / 2)
                    .help("Click at \(StudioTimeFormat.string(clicks[i].time))")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Playhead

struct StudioPlayhead: View {
    let model: StudioViewModel
    let scale: StudioTimelineScale
    let height: CGFloat

    var body: some View {
        let x = scale.x(model.playheadSourceTime)
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: Tokens.Recording.editorPlayheadColor))
                .frame(width: StudioLayout.playheadWidth, height: height)
                .shadow(color: .black.opacity(0.4), radius: 1)
            Circle()
                .fill(Color(nsColor: Tokens.Recording.editorPlayheadColor))
                .frame(width: StudioLayout.playheadKnob, height: StudioLayout.playheadKnob)
                .offset(y: -StudioLayout.playheadKnob / 2)
                .shadow(color: .black.opacity(0.4), radius: 1)
        }
        .frame(width: StudioLayout.playheadKnob)
        .contentShape(Rectangle())
        .offset(x: x - StudioLayout.playheadKnob / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("studio.timeline"))
                .onChanged { value in
                    model.playback.pause()
                    model.seek(toSource: scale.time(value.location.x))
                }
        )
        .allowsHitTesting(true)
    }
}
