import AppKit
import HakoKit
import SwiftUI

/// Menu bar recording indicator (plan §4.4): a red dot, shown while recording
/// even when "Display recording time in menu bar" is off (so Stop stays
/// reachable from the menu bar even with the control bar hidden/dragged off
/// screen), plus the `mm:ss` / `h:mm:ss` elapsed timer when
/// `recordingShowTimeInMenuBar` is on.
///
/// `MenuBarController` (hotspot, plan §7.0) owns the `NSStatusItem`; this
/// package only provides the model and the rendering (`attributedTitle` for
/// `statusItem.button`, plus a SwiftUI view for the recording menu row) — see
/// the integration snippet in the R1.2 report.
@MainActor
@Observable
final class RecordingMenuBarIndicatorModel {
    var isRecording: Bool
    var isPaused: Bool
    /// Media seconds recorded so far (pauses excluded), `RecordingSession.elapsed`.
    var elapsed: Double
    /// `recordingShowTimeInMenuBar` (Settings > Recording > General).
    var showsTime: Bool

    init(isRecording: Bool = false, isPaused: Bool = false, elapsed: Double = 0, showsTime: Bool = false) {
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.elapsed = elapsed
        self.showsTime = showsTime
    }

    /// Refreshes from a live `RecordingSession` + the current setting value.
    func update(session: RecordingSession, showsTimeInMenuBar: Bool) {
        isRecording = session.state.isCapturing
        isPaused = session.state.isPaused
        elapsed = session.elapsed
        showsTime = showsTimeInMenuBar
    }

    /// `nil` while idle, or while recording with the time hidden (the status
    /// item then shows only the dot).
    var timeText: String? {
        guard isRecording, showsTime else { return nil }
        return RecordingMenuBarIndicator.timeText(elapsed: elapsed)
    }
}

enum RecordingMenuBarIndicator {
    /// `mm:ss` / `h:mm:ss` — the same formatting as the control bar timer and
    /// the Quick Access video card / History filmstrip (`QuickAccessDurationFormat`).
    nonisolated static func timeText(elapsed: Double) -> String {
        QuickAccessDurationFormat.string(seconds: elapsed)
    }

    /// `NSStatusItem.button?.attributedTitle`: a red (or dimmed, while paused)
    /// dot, then the monospaced timer if `model.timeText` is set. `nil` while
    /// idle — the caller should fall back to its normal icon-only title.
    static func attributedTitle(_ model: RecordingMenuBarIndicatorModel) -> NSAttributedString? {
        guard model.isRecording else { return nil }
        let result = NSMutableAttributedString()
        let dot = NSTextAttachment()
        dot.image = dotImage(paused: model.isPaused)
        let diameter = Tokens.Recording.menuBarDotDiameter
        dot.bounds = CGRect(x: 0, y: -diameter / 4, width: diameter, height: diameter)
        result.append(NSAttributedString(attachment: dot))
        if let timeText = model.timeText {
            result.append(NSAttributedString(
                string: " \(timeText)",
                attributes: [.font: Tokens.Recording.menuBarTimerFont, .foregroundColor: NSColor.labelColor]
            ))
        }
        return result
    }

    private static func dotImage(paused: Bool) -> NSImage {
        let diameter = Tokens.Recording.menuBarDotDiameter
        let color = paused ? Tokens.Recording.recordRed.withAlphaComponent(0.5) : Tokens.Recording.recordRed
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// SwiftUI rendering of the same state, for the recording row inside the
/// status item's own menu (plan §4.4: "tık = kayıt menüsü").
struct RecordingMenuBarIndicatorView: View {
    let model: RecordingMenuBarIndicatorModel

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Circle()
                .fill(Color(nsColor: Tokens.Recording.recordRed))
                .opacity(model.isPaused ? 0.5 : 1)
                .frame(width: Tokens.Recording.menuBarDotDiameter, height: Tokens.Recording.menuBarDotDiameter)
            if let timeText = model.timeText {
                Text(timeText)
                    .font(Tokens.Recording.timerFont)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.isPaused ? "Recording paused" : "Recording")
    }
}
