import HakoKit
import SwiftUI

/// `m:ss.d` for the timeline labels (plan §4.16: `0:03.2 / 0:42.0`).
nonisolated enum VideoEditorTimeFormat {
    static func string(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds.isFinite ? seconds : 0) * 10).rounded(.down))
        let minutes = tenths / 600
        let secs = (tenths / 10) % 60
        let fraction = tenths % 10
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d.%d", minutes / 60, minutes % 60, secs, fraction)
        }
        return String(format: "%d:%02d.%d", minutes, secs, fraction)
    }
}

/// Bottom bar (plan §4.16): play/pause, the 64 pt timeline (thumbnail strip,
/// yellow trim handles snapping to frames, dimmed trimmed-out parts,
/// playhead that scrubs when dragged) and the time labels.
struct VideoEditorBottomBar: View {
    let model: VideoEditorViewModel
    let thumbnails: ThumbnailLoader

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: VideoEditorMetrics.playButtonSize, height: VideoEditorMetrics.playButtonSize)
                    .background(Circle().fill(Color(nsColor: Tokens.Palette.neutralPillFill)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")

            VideoTimelineView(model: model, thumbnails: thumbnails)
                .frame(height: VideoEditorMetrics.timelineHeight)

            VStack(alignment: .trailing, spacing: Tokens.Spacing.xxs) {
                Text(verbatim: "\(VideoEditorTimeFormat.string(model.currentTime)) / \(VideoEditorTimeFormat.string(model.sourceDuration))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
                Text(verbatim: model.statusMessage ?? "Output \(VideoEditorTimeFormat.string(model.outputDuration))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .lineLimit(1)
            }
            .frame(width: VideoEditorMetrics.timeLabelWidth, alignment: .trailing)
        }
        .padding(.horizontal, VideoEditorMetrics.bottomBarPaddingH)
        .padding(.vertical, VideoEditorMetrics.bottomBarPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The timeline itself: strip + trim frame + playhead, one drag gesture
/// that moves a handle or scrubs depending on where it starts.
struct VideoTimelineView: View {
    let model: VideoEditorViewModel
    let thumbnails: ThumbnailLoader
    @State private var dragTarget: TimelineGeometry.DragTarget?
    /// Distance from the press to the dragged handle's inner edge.
    @State private var grabOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let geometry = TimelineGeometry(width: proxy.size.width, duration: model.sourceDuration)
            let height = proxy.size.height
            let trim = model.trimRange
            ZStack(alignment: .topLeading) {
                ThumbnailStrip(loader: thumbnails)
                    .frame(width: geometry.trackWidth, height: height - 2 * VideoEditorMetrics.trimBorderWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .offset(x: geometry.inset, y: VideoEditorMetrics.trimBorderWidth)
                TrimHandles(geometry: geometry, trim: trim, isActive: dragTarget == .trimStart || dragTarget == .trimEnd)
                playhead(x: geometry.x(for: model.currentTime), height: height)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drag(geometry))
            .onAppear { loadThumbnails(geometry, height: height) }
            .onChange(of: proxy.size) { _, _ in loadThumbnails(geometry, height: height) }
            .onChange(of: model.sourceDuration) { _, _ in loadThumbnails(geometry, height: height) }
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(Text(verbatim: VideoEditorTimeFormat.string(model.currentTime)))
    }

    private func loadThumbnails(_ geometry: TimelineGeometry, height: CGFloat) {
        guard model.sourceDuration > 0 else { return }
        thumbnails.load(asset: model.asset, duration: model.sourceDuration, width: geometry.trackWidth,
                        height: height - 2 * VideoEditorMetrics.trimBorderWidth)
    }

    private func playhead(x: CGFloat, height: CGFloat) -> some View {
        let color = Color(nsColor: VideoEditorMetrics.playheadColor)
        let knob = VideoEditorMetrics.playheadKnob
        // Fixed to the timeline height; the knob pokes out above it without
        // growing the layout.
        return Rectangle()
            .fill(color)
            .frame(width: VideoEditorMetrics.playheadWidth, height: height)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .overlay(alignment: .top) {
                Circle()
                    .fill(color)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .offset(y: -knob / 2)
            }
            .frame(width: knob, height: height)
            .offset(x: x - knob / 2)
        .allowsHitTesting(false)
    }

    private func drag(_ geometry: TimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragTarget == nil {
                    let target = geometry.dragTarget(at: value.startLocation.x, trim: model.trimRange)
                    dragTarget = target
                    switch target {
                    case .trimStart:
                        grabOffset = value.startLocation.x - geometry.x(for: model.trimRange.start)
                        model.pause()
                        model.beginInteraction()
                    case .trimEnd:
                        grabOffset = value.startLocation.x - geometry.x(for: model.trimRange.end)
                        model.pause()
                        model.beginInteraction()
                    case .playhead:
                        grabOffset = 0
                        model.pause()
                        model.isScrubbing = true
                    }
                }
                let time = geometry.time(for: value.location.x - grabOffset)
                switch dragTarget {
                case .trimStart: model.setTrimStart(time)
                case .trimEnd: model.setTrimEnd(time)
                case .playhead, nil: model.seek(to: time)
                }
            }
            .onEnded { _ in
                switch dragTarget {
                case .trimStart, .trimEnd: model.endInteraction()
                case .playhead, nil: model.isScrubbing = false
                }
                dragTarget = nil
            }
    }
}
