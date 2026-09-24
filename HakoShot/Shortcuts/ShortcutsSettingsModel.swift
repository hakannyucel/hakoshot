import AppKit
import KeyboardShortcuts
import os

/// State behind Settings > Shortcuts: current shortcuts, which recorder is
/// listening, HakoShot duplicates and macOS screenshot-shortcut conflicts.
///
/// Recording: a local key monitor on the settings window; global hotkeys are
/// paused meanwhile (`KeyboardShortcuts.isEnabled = false`) so pressing an
/// existing HakoShot combo records it instead of starting a capture.
/// Esc cancels, ⌫ / ⌦ clear, any other valid combo is stored immediately
/// (`KeyboardShortcuts.setShortcut`) and the hotkey is live right away.
@Observable
final class ShortcutsSettingsModel {
    /// Raw name → combo, unassigned names left out.
    private(set) var assignments: [String: ShortcutCombo] = [:]
    /// Display strings ("⇧⌘4") by raw name.
    private(set) var labels: [String: String] = [:]
    /// Raw name of the recorder that is listening.
    private(set) var recordingName: String?
    /// Last rejected combo, shown under the recording row.
    private(set) var rejection: String?
    private(set) var systemConflicts: [SystemShortcutConflict] = []
    private(set) var systemShortcuts: [SystemScreenshotShortcut] = []

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let readSymbolicHotKeys: () -> [String: Any]?

    init(readSymbolicHotKeys: @escaping () -> [String: Any]? = ShortcutConflictDetector.readSymbolicHotKeys) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HakoShortcutsFakeSystemConflict") {
            // Visual check of the banner: macOS defaults, all on.
            self.readSymbolicHotKeys = { nil }
        } else {
            self.readSymbolicHotKeys = readSymbolicHotKeys
        }
        #else
        self.readSymbolicHotKeys = readSymbolicHotKeys
        #endif
        reload()
    }

    // MARK: Lifecycle (page appear / disappear)

    func activate() {
        reload()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // KeyboardShortcuts posts this (internal name) on every change, also from the DEBUG URL.
        observers.append(center.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadShortcuts() }
        })
        // Coming back from System Settings: re-read the symbolic hotkeys.
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSystemShortcuts() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        })
    }

    func deactivate() {
        stopRecording()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func reload() {
        reloadShortcuts()
        reloadSystemShortcuts()
    }

    private func reloadShortcuts() {
        assignments = ShortcutBinding.currentAssignments()
        var labels: [String: String] = [:]
        for binding in ShortcutBinding.all {
            if let shortcut = KeyboardShortcuts.getShortcut(for: binding.name) {
                labels[binding.name.rawValue] = shortcut.description
            }
        }
        self.labels = labels
        systemConflicts = ShortcutConflictDetector.systemConflicts(
            assignments: assignments, symbolicHotKeys: cachedSymbolicHotKeys
        )
    }

    @ObservationIgnored private var cachedSymbolicHotKeys: [String: Any]?

    private func reloadSystemShortcuts() {
        cachedSymbolicHotKeys = readSymbolicHotKeys()
        systemShortcuts = ShortcutConflictDetector.systemScreenshotShortcuts(symbolicHotKeys: cachedSymbolicHotKeys)
        systemConflicts = ShortcutConflictDetector.systemConflicts(
            assignments: assignments, symbolicHotKeys: cachedSymbolicHotKeys
        )
    }

    // MARK: Queries

    func label(for binding: ShortcutBinding) -> String? { labels[binding.id] }

    func isRecording(_ binding: ShortcutBinding) -> Bool { recordingName == binding.id }

    /// Titles of other HakoShot commands on the same combo.
    func duplicateTitles(for binding: ShortcutBinding) -> [String] {
        guard let combo = assignments[binding.id] else { return [] }
        return ShortcutConflictDetector.duplicates(of: combo, excluding: binding.id, in: assignments)
            .compactMap { ShortcutBinding.binding(named: $0)?.title }
    }

    /// The enabled macOS screenshot shortcut that swallows this binding's combo.
    func systemConflict(for binding: ShortcutBinding) -> SystemShortcutConflict? {
        systemConflicts.first { $0.names.contains(binding.id) }
    }

    // MARK: Editing

    func toggleRecording(_ binding: ShortcutBinding) {
        if recordingName == binding.id {
            stopRecording()
        } else {
            startRecording(binding)
        }
    }

    func startRecording(_ binding: ShortcutBinding) {
        stopRecording()
        recordingName = binding.id
        rejection = nil
        KeyboardShortcuts.isEnabled = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.rawValue
            let consumed = MainActor.assumeIsolated {
                guard let self, self.recordingName != nil else { return false }
                self.handleRecording(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: flags))
                return true
            }
            return consumed ? nil : event
        }
        Log.shortcuts.notice("recording \(binding.id, privacy: .public)")
    }

    func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if recordingName != nil {
            recordingName = nil
            KeyboardShortcuts.isEnabled = true
        }
    }

    func clear(_ binding: ShortcutBinding) {
        set(nil, for: binding)
    }

    func resetAll() {
        stopRecording()
        ShortcutBinding.resetAllToDefaults()
        reloadShortcuts()
    }

    private func set(_ shortcut: KeyboardShortcuts.Shortcut?, for binding: ShortcutBinding) {
        KeyboardShortcuts.setShortcut(shortcut, for: binding.name)
        reloadShortcuts()
        let text = shortcut.map(\.description) ?? "none"
        Log.shortcuts.notice("\(binding.id, privacy: .public) = \(text, privacy: .public)")
    }

    private func handleRecording(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let name = recordingName, let binding = ShortcutBinding.binding(named: name) else { return }
        let combo = ShortcutCombo(keyCode: Int(keyCode), modifiers: modifiers)
        switch (combo.keyCode, combo.modifiers.isEmpty) {
        case (Int(KeyCode.escape), true):
            stopRecording()
            return
        case (Int(KeyCode.delete), true), (Int(KeyCode.forwardDelete), true):
            stopRecording()
            clear(binding)
            return
        default:
            break
        }
        guard ShortcutValidation.isAcceptable(combo) else {
            rejection = "Use at least one of ⌘, ⌥ or ⌃ (or a function key)."
            NSSound.beep()
            return
        }
        stopRecording()
        rejection = nil
        set(KeyboardShortcuts.Shortcut(carbonKeyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers), for: binding)
    }

    private enum KeyCode {
        static let escape: UInt16 = 0x35
        static let delete: UInt16 = 0x33
        static let forwardDelete: UInt16 = 0x75
    }
}
