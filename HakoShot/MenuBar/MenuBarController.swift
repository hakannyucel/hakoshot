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
///
/// While recording (kayit-teknik-plan §4.4) the icon becomes a red dot (plus
/// the elapsed time with "Display recording time in menu bar"), the item stays
/// visible even with "Show menu bar icon" off, and the menu is the recording
/// menu (Stop, Pause/Resume, Restart, Discard).
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var coordinator: AppCoordinator?
    private let icon: NSImage?
    private let recordingIndicator = RecordingMenuBarIndicatorModel()
    /// Refreshes the timer while recording.
    private var indicatorTask: Task<Void, Never>?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "HakoShot")
        image?.isTemplate = true
        icon = image
        super.init()

        statusItem.button?.image = image

        menu.delegate = self
        menu.autoenablesItems = false
        MenuBuilder.populate(menu, state: coordinator.menuState, target: self)
        statusItem.menu = menu

        applyVisibilitySetting()
        coordinator.menuBarTitleProvider = { [weak self] in
            guard let button = self?.statusItem.button else { return nil }
            return button.attributedTitle.length > 0 ? button.attributedTitle.string : nil
        }
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

    /// Follows Settings > General "Show menu bar icon" (always visible while recording).
    private func applyVisibilitySetting() {
        let visible = AppSettings.shared.value(for: .showMenuBarIcon) || recordingIndicator.isRecording
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

    /// Rebuilds the menu from `AppCoordinator.menuState` (also called when pins
    /// or the recording change).
    func rebuild() {
        guard let coordinator else { return }
        MenuBuilder.populate(menu, state: coordinator.menuState, target: self)
        updateRecordingIndicator()
    }

    /// Red dot (+ timer) while recording, the normal icon otherwise.
    private func updateRecordingIndicator() {
        guard let coordinator, let button = statusItem.button else { return }
        let wasRecording = recordingIndicator.isRecording
        recordingIndicator.update(
            session: coordinator.recording.session,
            showsTimeInMenuBar: AppSettings.shared.value(for: .recordingShowTimeInMenuBar)
        )
        if let title = RecordingMenuBarIndicator.attributedTitle(recordingIndicator) {
            if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
            if button.image != nil {
                button.image = nil
                statusItem.length = NSStatusItem.variableLength
            }
            if indicatorTask == nil {
                indicatorTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        self?.updateRecordingIndicator()
                    }
                }
            }
        } else {
            indicatorTask?.cancel()
            indicatorTask = nil
            if button.image == nil {
                button.attributedTitle = NSAttributedString()
                button.image = icon
                statusItem.length = NSStatusItem.squareLength
            }
        }
        if wasRecording != recordingIndicator.isRecording { applyVisibilitySetting() }
    }

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox, let coordinator else { return }
        Log.menu.notice("menu item '\(sender.title, privacy: .public)'")
        Task { await coordinator.perform(box.command) }
    }
}
