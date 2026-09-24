import AppKit
import AVFoundation
import HakoKit
import SwiftUI

/// Studio window content (plan §4.19): toolbar (Undo/Redo, play, time,
/// Export), preview + 300 pt inspector, timeline (video, zoom, clicks).
struct StudioRootView: View {
    let model: StudioViewModel
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(model: model, onExport: onExport)
            Divider()
            HStack(spacing: 0) {
                StudioPreviewPane(model: model)
                Divider()
                StudioInspectorView(model: model)
                    .frame(width: Tokens.Recording.studioInspectorWidth)
            }
            Divider()
            StudioTimelineView(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Toolbar

struct StudioToolbar: View {
    let model: StudioViewModel
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.xs) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.store.canUndo)
                    .help(model.store.undoActionName.map { "Undo \($0)" } ?? "Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.store.canRedo)
                    .help(model.store.redoActionName.map { "Redo \($0)" } ?? "Redo")
            }
            .buttonStyle(.borderless)

            Spacer()

            HStack(spacing: Tokens.Spacing.s) {
                Button { model.playback.togglePlay() } label: {
                    Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help("Play/Pause (Space)")
                Text("\(StudioTimeFormat.string(model.playback.currentTime)) / \(StudioTimeFormat.string(model.timeline.outputDuration))")
                    .font(Tokens.Recording.timerFont)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }

            Spacer()

            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .lineLimit(1)
            } else if model.hasUnsavedChanges {
                Text("Edited")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            Button(action: onExport) {
                Text("Export")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, Tokens.Spacing.pillPaddingH)
                    .frame(height: Tokens.Size.pillHeight)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .help("Export video or GIF (⌘E)")
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .frame(height: StudioLayout.toolbarHeight)
    }
}

/// `m:ss.f` for the toolbar and timeline.
nonisolated enum StudioTimeFormat {
    static func string(_ seconds: Double) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        let whole = Int(s)
        let tenths = Int((s - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}

// MARK: - Preview

struct StudioPreviewPane: View {
    let model: StudioViewModel

    var body: some View {
        ZStack {
            Color(nsColor: EditorMetrics.canvasBackground)
            StudioPlayerView(playback: model.playback)
                .padding(Tokens.Spacing.l)
            if let error = model.playback.buildError {
                VStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                    Text("Preview unavailable")
                        .font(.headline)
                    Text(error)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.playback.togglePlay() }
    }
}

/// `AVPlayerLayer` host; reports its pixel height as the preview size cap.
struct StudioPlayerView: NSViewRepresentable {
    let playback: StudioPlayback

    func makeNSView(context: Context) -> StudioPlayerNSView {
        let view = StudioPlayerNSView()
        view.playerLayer.player = playback.player
        view.onPixelHeight = { [weak playback] height in playback?.maxPreviewHeight = height }
        return view
    }

    func updateNSView(_ view: StudioPlayerNSView, context: Context) {
        if view.playerLayer.player !== playback.player { view.playerLayer.player = playback.player }
    }
}

final class StudioPlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onPixelHeight: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .clear
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        let scale = window?.backingScaleFactor ?? 2
        let pixels = Int((bounds.height * scale).rounded(.up))
        if pixels > 0 { onPixelHeight?(RecordingGeometry.evenFloor(Double(pixels))) }
    }

    /// The video's rect inside this view (aspect fit), `nil` before the first item.
    func videoFrameRect() -> CGRect? {
        let rect = playerLayer.videoRect
        return rect.isEmpty ? nil : rect
    }

    static func find(in view: NSView) -> StudioPlayerNSView? {
        if let match = view as? StudioPlayerNSView { return match }
        for sub in view.subviews {
            if let match = find(in: sub) { return match }
        }
        return nil
    }
}
