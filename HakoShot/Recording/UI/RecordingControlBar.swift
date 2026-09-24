import AppKit
import HakoKit
import SwiftUI

/// Floating control bar shown while recording (plan §4.4, UI report §2.4):
/// a dark 40 pt pill, bottom-center of the recorded display, with the red
/// Stop + elapsed timer, Pause/Resume, Restart and Trash (discard, with a
/// confirm popover). Binds to a `RecordingSession` (R1.3) and is the only one
/// of the R1.2 recording-chrome windows that accepts mouse events — it also
/// accepts drags (`RecordingControlBarDragArea`, `NSWindow.performDrag`).
@MainActor
final class RecordingControlBar {
    let panel: RecordingControlBarPanel

    /// `CGWindowID` of the bar panel while it's shown (`nil` while hidden —
    /// the window doesn't exist on screen yet). The engine excludes our whole
    /// app by default; this is for a coordinator that wants the ID anyway.
    var windowID: CGWindowID? {
        panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }

    var isVisible: Bool { panel.isVisible }

    init(
        session: RecordingSession,
        onStop: @escaping () -> Void,
        onTogglePause: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        panel = RecordingControlBarPanel()
        let content = RecordingControlBarContent(
            session: session, onStop: onStop, onTogglePause: onTogglePause, onRestart: onRestart, onDiscard: onDiscard
        )
        let hosting = RecordingControlBarHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.contentView = hosting
    }

    /// Wires the bar's four actions straight to `session`'s own methods
    /// (fire-and-forget; the session logs/exposes failures itself).
    convenience init(session: RecordingSession) {
        self.init(
            session: session,
            onStop: { Task { try? await session.stop() } },
            onTogglePause: { Task { await session.togglePause() } },
            onRestart: { Task { try? await session.restart() } },
            onDiscard: { Task { await session.discard() } }
        )
    }

    /// Shows (or moves) the bar for `recordedRect` (Quartz global points) on
    /// `displayID`, bottom-center per `RecordingControlBarLayout`. `false` if
    /// `displayID` isn't a connected display right now.
    @discardableResult
    func show(recordedRect: GlobalRect, displayID: CGDirectDisplayID) -> Bool {
        guard let screen = DisplayLayoutProvider.screen(for: displayID) else { return false }
        let layout = DisplayLayoutProvider.currentLayout()
        let appKitRect = ScreenGeometry.appKitRect(fromGlobal: recordedRect, layout: layout) ?? recordedRect.cgRect
        let origin = RecordingControlBarLayout.origin(barSize: panel.frame.size, displayFrame: screen.frame, recordedRect: appKitRect)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        return true
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// `mm:ss` / `h:mm:ss`, pauses excluded — the same formatting used by the
    /// Quick Access video card and History filmstrip (`QuickAccessDurationFormat`).
    nonisolated static func timerText(elapsed: Double) -> String {
        QuickAccessDurationFormat.string(seconds: elapsed)
    }
}

// MARK: - Placement (pure, testable)

/// Bar placement math (plan §4.4): bottom-center of the recording display,
/// `Tokens.Recording.controlBarBottomInset` from the bottom edge; moved below
/// (or above, if there's no room below) the recorded rect when the default
/// spot would sit on top of it. If neither below nor above fits (the recorded
/// rect fills the display's height, e.g. fullscreen) the bar falls back to
/// the default spot — our own windows are excluded from every recording, so
/// overlapping the recorded content there is harmless (plan §4.4: "zaten
/// kayda girmez").
///
/// Works in whatever coordinate space `displayFrame` / `recordedRect` share
/// ("bottom" = `minY`, AppKit convention); both may have negative origins
/// (a display to the left of / below the main display).
nonisolated enum RecordingControlBarLayout {
    /// Gap between the bar and the recorded rect when it has to move out of the way.
    static let rectGap = Tokens.Spacing.m

    static func origin(barSize: CGSize, displayFrame: CGRect, recordedRect: CGRect?) -> CGPoint {
        let defaultOrigin = CGPoint(
            x: displayFrame.midX - barSize.width / 2,
            y: displayFrame.minY + Tokens.Recording.controlBarBottomInset
        )
        guard let recordedRect else { return clampX(defaultOrigin, barSize: barSize, in: displayFrame) }

        let defaultRect = CGRect(origin: defaultOrigin, size: barSize)
        guard defaultRect.intersects(recordedRect) else {
            return clampX(defaultOrigin, barSize: barSize, in: displayFrame)
        }

        let centeredX = recordedRect.midX - barSize.width / 2
        let below = CGPoint(x: centeredX, y: recordedRect.minY - rectGap - barSize.height)
        if below.y >= displayFrame.minY {
            return clampX(below, barSize: barSize, in: displayFrame)
        }
        let above = CGPoint(x: centeredX, y: recordedRect.maxY + rectGap)
        if above.y + barSize.height <= displayFrame.maxY {
            return clampX(above, barSize: barSize, in: displayFrame)
        }
        // No room above or below: default spot, overlapping the recorded rect.
        return clampX(defaultOrigin, barSize: barSize, in: displayFrame)
    }

    /// Keeps the bar horizontally inside the display; `y` is left as computed
    /// (the default spot is already inset from the bottom, and the below/above
    /// spots were only chosen once they were checked to fit vertically).
    private static func clampX(_ origin: CGPoint, barSize: CGSize, in displayFrame: CGRect) -> CGPoint {
        let minX = displayFrame.minX
        let maxX = displayFrame.maxX - barSize.width
        guard minX <= maxX else { return CGPoint(x: displayFrame.midX - barSize.width / 2, y: origin.y) }
        return CGPoint(x: min(max(origin.x, minX), maxX), y: origin.y)
    }
}

// MARK: - Panel

/// Borderless, non-activating floating panel (plan §4.4). The only recording-chrome
/// window with `ignoresMouseEvents = false`.
final class RecordingControlBarPanel: NSPanel {
    /// Above the dim + border, same family as the countdown.
    static let level = NSWindow.Level.screenSaver

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI content draws its own `hudPanel` shadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Dragging goes through `RecordingControlBarDragArea` (`performDrag`), so
        // clicks on the buttons aren't swallowed by window-background dragging.
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        title = "Recording Controls"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click without the panel becoming key first.
private final class RecordingControlBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Content

private struct RecordingControlBarContent: View {
    let session: RecordingSession
    let onStop: () -> Void
    let onTogglePause: () -> Void
    let onRestart: () -> Void
    let onDiscard: () -> Void

    @State private var showsDiscardConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            stopSegment
            divider
            iconSegment(
                systemImage: session.state.isPaused ? "play.fill" : "pause.fill",
                label: session.state.isPaused ? "Resume Recording" : "Pause Recording",
                action: onTogglePause
            )
            divider
            iconSegment(systemImage: "arrow.counterclockwise", label: "Restart Recording", action: onRestart)
            divider
            iconSegment(systemImage: "trash", label: "Discard Recording") { showsDiscardConfirm = true }
                .popover(isPresented: $showsDiscardConfirm, arrowEdge: .bottom) {
                    RecordingDiscardConfirmView(
                        onCancel: { showsDiscardConfirm = false },
                        onConfirm: {
                            showsDiscardConfirm = false
                            onDiscard()
                        }
                    )
                }
        }
        .padding(.horizontal, Tokens.Recording.controlBarPaddingH)
        .frame(height: Tokens.Recording.controlBarHeight)
        .hudPanel(cornerRadius: Tokens.Recording.controlBarRadius, shadow: Tokens.Recording.controlBarShadow)
        .background(RecordingControlBarDragArea())
        .fixedSize()
    }

    private var stopSegment: some View {
        Button(action: onStop) {
            HStack(spacing: Tokens.Spacing.xs) {
                Circle()
                    .fill(Color(nsColor: Tokens.Recording.recordRed))
                    .frame(width: Tokens.Recording.stopDotDiameter, height: Tokens.Recording.stopDotDiameter)
                Text(RecordingControlBar.timerText(elapsed: session.elapsed))
                    .font(Tokens.Recording.timerFont)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
                    .lineLimit(1)
                if let level = session.stats.microphoneLevel {
                    RecordingMicLevelBar(level: level, isSilent: session.stats.microphoneSilent)
                }
            }
            .frame(width: Tokens.Recording.controlStopSegmentWidth, height: Tokens.Recording.controlBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop Recording")
        .help("Stop Recording")
    }

    private func iconSegment(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Tokens.Recording.controlIconSize, weight: .medium))
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
                .frame(width: Tokens.Recording.controlSegmentWidth, height: Tokens.Recording.controlBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: Tokens.Palette.hudTextPrimary).opacity(Tokens.Recording.controlDividerOpacity))
            .frame(width: Tokens.Stroke.hairline)
            .padding(.vertical, Tokens.Spacing.s)
    }
}

/// Mic level meter inside the Stop segment (plan §4.4: "Mikrofon açıksa Stop
/// segmentinde küçük seviye çubuğu"), dB-scaled (−60…0 dBFS). After 3 s of
/// silence it turns into a yellow dot with a hint (plan §1.4, CleanShot 4.6
/// "notification when your mic is muted").
private struct RecordingMicLevelBar: View {
    /// 0…1 linear peak (`RecordingStats.microphoneLevel`).
    let level: Float
    /// `RecordingStats.microphoneSilent`.
    let isSilent: Bool

    /// Bar height fraction for a linear level.
    static func position(level: Float) -> CGFloat {
        CGFloat(AudioLevelMath.meterPosition(dBFS: AudioLevelMath.dBFS(level)))
    }

    var body: some View {
        if isSilent {
            Circle()
                .fill(Color(nsColor: Tokens.Recording.micSilentColor))
                .frame(width: Tokens.Recording.micSilentDotDiameter, height: Tokens.Recording.micSilentDotDiameter)
                .frame(width: Tokens.Recording.micSilentDotDiameter, height: Tokens.Recording.levelBarHeight)
                .help("No sound from your microphone. Check that it isn't muted.")
                .accessibilityLabel("Microphone is silent")
        } else {
            Capsule()
                .fill(Color(nsColor: Tokens.Palette.hudTextSecondary))
                .frame(width: Tokens.Recording.levelBarWidth, height: max(2, Tokens.Recording.levelBarHeight * Self.position(level: level)))
                .frame(height: Tokens.Recording.levelBarHeight, alignment: .bottom)
                .accessibilityHidden(true)
        }
    }
}

/// Trash confirmation (plan §4.4: "Discard recording?").
private struct RecordingDiscardConfirmView: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Discard recording?").font(.headline)
            Text("The recording so far will be deleted. This can't be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Discard", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 260)
    }
}

/// A transparent background view: `mouseDown` starts an `NSWindow.performDrag`
/// so the bar can be dragged from any gap between its buttons (plan §4.4:
/// "Sürüklenebilir"), without the buttons themselves triggering a drag.
private struct RecordingControlBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
