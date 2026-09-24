import AppKit
import HakoKit
import SwiftUI

/// State shown by the countdown HUD.
@Observable
final class SelfTimerHUDModel {
    var remaining: Int

    init(remaining: Int) {
        self.remaining = remaining
    }
}

/// Borderless panel with the countdown circle, centered on the area being
/// captured. Never key (Esc comes from `EscapeHotKey`); a click on the
/// circle cancels. Above menus so it stays visible while the user opens one.
final class SelfTimerHUDPanel: NSPanel {
    var onClick: (() -> Void)?

    init(model: SelfTimerHUDModel) {
        let side = Tokens.SelfTimer.diameter + Tokens.SelfTimer.shadowInset * 2
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let hosting = ClickThroughHostingView(rootView: SelfTimerHUDView(model: model) { [weak self] in self?.onClick?() })
        hosting.frame = CGRect(x: 0, y: 0, width: side, height: side)
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centers the panel on `point` (AppKit global coordinates).
    func center(on point: CGPoint) {
        let size = frame.size
        setFrameOrigin(CGPoint(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded()))
    }
}

/// Accepts the first click without the panel becoming key.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SelfTimerHUDView: View {
    let model: SelfTimerHUDModel
    var onTap: () -> Void = {}

    var body: some View {
        ZStack {
            Text("\(model.remaining)")
                .font(.system(size: Tokens.SelfTimer.digitSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .id(model.remaining)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: Tokens.SelfTimer.pulseScale).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
        .frame(width: Tokens.SelfTimer.diameter, height: Tokens.SelfTimer.diameter)
        .animation(
            DSAnimation.respectingReduceMotion(.easeOut(duration: Tokens.SelfTimer.pulseDuration)),
            value: model.remaining
        )
        .hudPanel(cornerRadius: Tokens.SelfTimer.diameter / 2)
        .contentShape(Circle())
        .onTapGesture(perform: onTap)
        .help("Click or press Esc to cancel")
        .frame(
            width: Tokens.SelfTimer.diameter + Tokens.SelfTimer.shadowInset * 2,
            height: Tokens.SelfTimer.diameter + Tokens.SelfTimer.shadowInset * 2
        )
        .accessibilityLabel("Capturing in \(model.remaining) seconds")
    }
}
