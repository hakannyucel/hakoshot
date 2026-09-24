import AppKit
import Carbon.HIToolbox
import HakoKit
import os
import SwiftUI

/// Recording countdown (plan §4.3, §5.2): a big number centered on the
/// recorded area (fullscreen: the whole display), one step per second. `Esc`
/// (a temporary global hot key, works while another app is frontmost) or a
/// click on the circle cancels.
///
/// Same visual language as the Self-Timer countdown (`SelfTimer/SelfTimerHUD.swift`,
/// via `Tokens.Recording.countdown*`, which mirror `Tokens.SelfTimer`) but a
/// separate implementation, so this package doesn't touch `SelfTimer/*` (not
/// one of its files, plan §7.0).
@MainActor
final class RecordingCountdown {
    private var task: Task<Void, any Error>?
    private var panel: RecordingCountdownPanel?
    private var escape: EscapeHotKey?
    private var localMonitor: Any?

    var isRunning: Bool { task != nil }

    /// `CGWindowID` of the countdown panel while it's visible (`nil` otherwise).
    /// The engine excludes our whole app by default; this is for a coordinator
    /// that wants the ID anyway.
    var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    /// Counts `seconds` down centered on `rect` (Quartz global points — the
    /// recorded area, or the whole display for a fullscreen target). Returns
    /// `true` when it ran to zero (the panel is already hidden), `false` when
    /// cancelled or already running.
    func run(seconds: Int, on rect: GlobalRect) async -> Bool {
        guard task == nil else {
            Log.recording.notice("recording countdown already running")
            return false
        }
        let total = max(seconds, 1)
        let model = RecordingCountdownModel(remaining: total)
        let panel = RecordingCountdownPanel(model: model)
        panel.onClick = { [weak self] in self?.cancel() }
        panel.center(on: Self.appKitCenter(of: rect))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        DSAnimation.run(.overlayFadeIn) { _ in panel.animator().alphaValue = 1 }
        self.panel = panel
        installEscape()

        let started = ContinuousClock.now
        Log.recording.notice("recording countdown \(total) s started")
        let countdown = Task {
            for value in stride(from: total, through: 1, by: -1) {
                model.remaining = value
                // Steps are anchored to the start so they don't drift.
                try await Task.sleep(until: started + .seconds(total - value + 1), clock: .continuous)
            }
        }
        task = countdown
        let completed = (try? await countdown.value) != nil
        tearDown()
        Log.recording.notice("recording countdown \(completed ? "finished" : "cancelled", privacy: .public)")
        return completed
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Private

    private func installEscape() {
        escape = EscapeHotKey { [weak self] in self?.cancel() }
        if escape == nil {
            Log.recording.notice("global Esc unavailable for the recording countdown; Esc works only while HakoShot is active")
        }
        // While one of our windows is key, Carbon may not see the key; catch it here too.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return event }
            self?.cancel()
            return nil
        }
    }

    private func tearDown() {
        task = nil
        escape?.invalidate()
        escape = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        // Our windows are excluded from every capture, but hide it before the shot anyway.
        panel?.orderOut(nil)
        panel = nil
    }

    private static func appKitCenter(of rect: GlobalRect) -> CGPoint {
        guard let screens = OverlayScreens.current(),
              let appKit = ScreenGeometry.appKitRect(fromGlobal: rect, layout: screens.layout) else {
            let frame = NSScreen.main?.frame ?? .zero
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return CGPoint(x: appKit.midX, y: appKit.midY)
    }
}

// MARK: - Panel / view

@Observable
final class RecordingCountdownModel {
    var remaining: Int

    init(remaining: Int) {
        self.remaining = remaining
    }
}

/// Borderless panel with the countdown circle, centered on the recorded area.
/// Never key (Esc comes from `EscapeHotKey`); a click on the circle cancels.
final class RecordingCountdownPanel: NSPanel {
    var onClick: (() -> Void)?

    init(model: RecordingCountdownModel) {
        let side = Tokens.Recording.countdownDiameter + Tokens.Recording.countdownShadowInset * 2
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
        let hosting = RecordingCountdownHostingView(rootView: RecordingCountdownView(model: model) { [weak self] in self?.onClick?() })
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
private final class RecordingCountdownHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct RecordingCountdownView: View {
    let model: RecordingCountdownModel
    var onTap: () -> Void = {}

    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: Tokens.Recording.countdownDigitSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .id(model.remaining)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: Tokens.Recording.countdownPulseScale).combined(with: .opacity),
                    removal: .opacity
                )
            )
            .frame(width: Tokens.Recording.countdownDiameter, height: Tokens.Recording.countdownDiameter)
            .animation(
                DSAnimation.respectingReduceMotion(.easeOut(duration: Tokens.Recording.countdownPulseDuration)),
                value: model.remaining
            )
            .hudPanel(cornerRadius: Tokens.Recording.countdownDiameter / 2)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            .help("Click or press Esc to cancel")
            .frame(
                width: Tokens.Recording.countdownDiameter + Tokens.Recording.countdownShadowInset * 2,
                height: Tokens.Recording.countdownDiameter + Tokens.Recording.countdownShadowInset * 2
            )
            .accessibilityLabel("Recording starts in \(model.remaining) seconds")
    }
}
