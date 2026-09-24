import AppKit
import Carbon.HIToolbox
import HakoKit
import os

extension Log {
    nonisolated static let selfTimer = Logger(subsystem: subsystem, category: "self-timer")
}

/// Self-Timer countdown (plan §4.14): a dark circle with a big digit in the
/// middle of the area, one step per second, then the caller captures. `Esc`
/// (a temporary global hot key, so it works while another app is frontmost)
/// or a click on the circle cancels.
final class SelfTimerController {
    private var task: Task<Void, any Error>?
    private var panel: SelfTimerHUDPanel?
    private var escape: EscapeHotKey?
    private var localMonitor: Any?

    var isRunning: Bool { task != nil }

    /// Counts `seconds` down over `rect` (Quartz global points). Returns
    /// `true` when it ran to zero (the HUD is already hidden), `false` when
    /// cancelled or already running.
    func countdown(seconds: Int, around rect: GlobalRect) async -> Bool {
        guard task == nil else {
            Log.selfTimer.notice("countdown already running")
            return false
        }
        let total = max(seconds, 1)
        let model = SelfTimerHUDModel(remaining: total)
        let panel = SelfTimerHUDPanel(model: model)
        panel.onClick = { [weak self] in self?.cancel() }
        panel.center(on: Self.appKitCenter(of: rect))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        DSAnimation.run(.overlayFadeIn) { _ in panel.animator().alphaValue = 1 }
        self.panel = panel
        installEscape()

        let started = ContinuousClock.now
        Log.selfTimer.notice("countdown \(total) s started")
        let countdown = Task {
            for value in stride(from: total, through: 1, by: -1) {
                model.remaining = value
                // Steps are anchored to the start so they don't drift.
                try await Task.sleep(until: started + .seconds(total - value + 1), clock: .continuous)
            }
        }
        task = countdown
        let completed = (try? await countdown.value) != nil
        let elapsed = ContinuousClock.now - started
        tearDown()
        Log.selfTimer.notice("countdown \(completed ? "finished" : "cancelled", privacy: .public) after \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
        return completed
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Private

    private func installEscape() {
        escape = EscapeHotKey { [weak self] in self?.cancel() }
        if escape == nil {
            Log.selfTimer.notice("global Esc unavailable; Esc works only while HakoShot is active")
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
