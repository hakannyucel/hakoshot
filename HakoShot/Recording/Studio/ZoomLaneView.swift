import AppKit
import HakoKit
import SwiftUI

/// Zoom lane (plan §4.19–§4.20, R7.2): one block per `ZoomSegment` on the
/// source-time scale.
///
/// - Double-click empty space: add a manual zoom there.
/// - Click a block: select it (inspector shows its scale / focus / easing).
/// - Drag a block: move; drag its edges: resize. One undo step per drag.
/// - ⌫ deletes the selected block (window key handler).
/// - Auto segments (planned from clicks) are lighter with a dashed border
///   and an "A" badge; editing one makes it manual (solid).
struct ZoomLaneView: View {
    let model: StudioViewModel
    let scale: StudioTimelineScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: StudioLayout.zoomBlockRadius, style: .continuous)
                .fill(Color(nsColor: Tokens.Palette.neutralPillFill))
                .overlay(alignment: .leading) {
                    if model.zoomSegments.isEmpty {
                        Text("Double-click to add a zoom")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                            .padding(.leading, Tokens.Spacing.s)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in model.addZoom(atSourceTime: scale.time(value.location.x)) }
                        .exclusively(before: SpatialTapGesture().onEnded { _ in model.selectZoom(nil) })
                )
            ForEach(model.zoomSegments) { segment in
                ZoomBlock(model: model, segment: segment, scale: scale,
                          isSelected: segment.id == model.selectedZoomID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One zoom segment block with move / resize gestures.
private struct ZoomBlock: View {
    let model: StudioViewModel
    let segment: ZoomSegment
    let scale: StudioTimelineScale
    let isSelected: Bool

    /// The segment as it was when the current drag began.
    @State private var origin: ZoomSegment?

    private enum DragKind { case move, leading, trailing }

    var body: some View {
        let x = scale.x(segment.start)
        let width = max(scale.x(segment.end) - x, 6)
        let color = Color(nsColor: Tokens.Recording.studioZoomSegmentColor)
        let auto = !segment.isManual
        ZStack {
            RoundedRectangle(cornerRadius: StudioLayout.zoomBlockRadius, style: .continuous)
                .fill(color.opacity(auto ? 0.55 : 0.95))
            RoundedRectangle(cornerRadius: StudioLayout.zoomBlockRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.white : color,
                              style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: auto && !isSelected ? [4, 3] : []))
            HStack(spacing: Tokens.Spacing.xs) {
                if auto {
                    Text("A")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.3)))
                        .help("Auto zoom (from clicks)")
                }
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(format: "%.1f×", segment.scale))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, StudioLayout.zoomEdgeHandle)
            .opacity(width > 44 ? 1 : 0)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .gesture(drag(.move))
        .simultaneousGesture(TapGesture().onEnded { model.selectZoom(segment.id) })
        .overlay(alignment: .leading) { edge(.leading) }
        .overlay(alignment: .trailing) { edge(.trailing) }
        .offset(x: x)
        .help("\(segment.isManual ? "Zoom" : "Auto zoom") \(String(format: "%.1f×", segment.scale)), \(StudioTimeFormat.string(segment.start)) – \(StudioTimeFormat.string(segment.end))")
    }

    private func edge(_ kind: DragKind) -> some View {
        Color.clear
            .frame(width: StudioLayout.zoomEdgeHandle)
            .contentShape(Rectangle())
            .gesture(drag(kind))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func drag(_ kind: DragKind) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if origin == nil {
                    origin = segment
                    model.selectZoom(segment.id)
                    model.beginInteraction(kind == .move ? "Move Zoom" : "Resize Zoom")
                }
                guard let origin else { return }
                let delta = scale.seconds(value.translation.width)
                let updated: ZoomSegment = switch kind {
                case .move: model.movedZoom(origin, by: delta)
                case .leading: model.resizedZoom(origin, leading: true, by: delta)
                case .trailing: model.resizedZoom(origin, leading: false, by: delta)
                }
                model.updateZoom(updated)
            }
            .onEnded { _ in
                origin = nil
                model.endInteraction()
            }
    }
}
