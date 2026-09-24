import os
import AppKit
import HakoKit

extension SettingsKey where Value == Bool {
    /// Settings > General "Show menu bar icon". Default on. When off, the
    /// status item is hidden; hotkeys, `hakoshot://open-settings` and
    /// reopening the app (Finder / Spotlight) still reach Settings.
    static var showMenuBarIcon: SettingsKey<Bool> {
        SettingsKey(MenuBarController.visibilityKeyName, default: true)
    }
}

/// Owns the `NSStatusItem`. The menu is rebuilt each time it opens so dynamic
/// items (checkmarks, pins) reflect `AppCoordinator.menuState`.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "HakoShot")
        image?.isTemplate = true
        statusItem.button?.image = image

        menu.delegate = self
        menu.autoenablesItems = false
        MenuBuilder.populate(menu, state: coordinator.menuState, target: self)
        statusItem.menu = menu

        applyVisibilitySetting()
        // KVO (not didChangeNotification) so `defaults write` from outside also applies.
        UserDefaults.standard.addObserver(self, forKeyPath: Self.visibilityKeyName, options: [.new], context: nil)
    }

    nonisolated static let visibilityKeyName = "showMenuBarIcon"

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.visibilityKeyName)
    }

    override nonisolated func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in self?.applyVisibilitySetting() }
    }

    /// Follows Settings > General "Show menu bar icon".
    private func applyVisibilitySetting() {
        let visible = AppSettings.shared.value(for: .showMenuBarIcon)
        guard statusItem.isVisible != visible else { return }
        statusItem.isVisible = visible
        Log.menu.notice("menu bar icon visible: \(visible)")
    }

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Rebuilds the menu from `AppCoordinator.menuState` (also called when pins change).
    func rebuild() {
        guard let coordinator else { return }
        MenuBuilder.populate(menu, state: coordinator.menuState, target: self)
    }

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox, let coordinator else { return }
        Log.menu.notice("menu item '\(sender.title, privacy: .public)'")
        Task { await coordinator.perform(box.command) }
    }
}
