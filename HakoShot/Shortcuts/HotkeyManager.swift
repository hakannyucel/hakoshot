import AppKit
import KeyboardShortcuts
import os

/// Registers the global hotkeys (plan §1.5) and forwards each press as an
/// `AppCommand` to `AppCoordinator.perform(_:)`.
final class HotkeyManager {
    private weak var coordinator: AppCoordinator?
    private var isStarted = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Call once after launch. Handlers stay registered for the app's lifetime;
    /// shortcuts changed later (Settings, M7) take effect without re-registering.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        for binding in ShortcutBinding.all {
            let command = binding.command
            let name = binding.name
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                self?.fire(command, name: name)
            }
        }
        let summary = ShortcutBinding.all.map { binding in
            "\(binding.name.rawValue)=\(KeyboardShortcuts.getShortcut(for: binding.name).map { "\($0)" } ?? "none")"
        }.joined(separator: ", ")
        Log.shortcuts.notice("registered \(ShortcutBinding.all.count) hotkeys: \(summary, privacy: .public)")
    }

    private func fire(_ command: AppCommand, name: KeyboardShortcuts.Name) {
        guard let coordinator else { return }
        Log.shortcuts.notice("hotkey \(name.rawValue, privacy: .public)")
        Task { await coordinator.perform(command) }
    }
}
