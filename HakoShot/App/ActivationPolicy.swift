import AppKit

/// HakoShot runs as `.accessory` (no Dock icon). While a "real" window such as
/// Settings or the editor is open it switches to `.regular` so the window gets
/// a Dock icon, ⌘-Tab entry and proper key focus (plan §2.3, §5.4).
///
/// Window controllers call `acquire(self)` when shown and `release(self)` when closed.
final class ActivationPolicyController {
    private var holders: Set<ObjectIdentifier> = []

    func acquire(_ owner: AnyObject) {
        pendingRelease?.cancel()
        pendingRelease = nil
        holders.insert(ObjectIdentifier(owner))
        apply()
    }

    func release(_ owner: AnyObject) {
        holders.remove(ObjectIdentifier(owner))
        // Going back to `.accessory` while a window's close animation still runs
        // leaves that window stuck on screen, so wait for the animation to end.
        pendingRelease?.cancel()
        pendingRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled, let self, self.holders.isEmpty else { return }
            self.apply()
        }
    }

    /// Longer than AppKit's window close animation.
    private static let releaseDelay: Duration = .milliseconds(400)
    private var pendingRelease: Task<Void, Never>?

    private func apply() {
        let desired: NSApplication.ActivationPolicy = holders.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
        if !holders.isEmpty {
            NSApp.activate()
        }
    }
}
