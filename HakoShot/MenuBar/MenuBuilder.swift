import AppKit
import KeyboardShortcuts

/// Dynamic bits of the menu, read every time the menu opens.
struct MenuState {
    var desktopIconsHidden = false
    var hasPins = false
    var hasLockedPins = false
    /// Quick Access or history has a closed capture to bring back.
    var hasRecentlyClosed = false
}

/// One entry in the status menu.
enum MenuEntry {
    /// `key` is a fixed key equivalent (modifiers default to ⇧⌘). Leave it empty
    /// for commands with a global shortcut: the menu then shows the current
    /// value from `ShortcutBinding` (display only; `HotkeyManager` handles the
    /// global hotkeys). Disabled entries stay visible but greyed out.
    case command(String, AppCommand, key: String = "", modifiers: NSEvent.ModifierFlags = [.command, .shift], checked: Bool = false, enabled: Bool = true)
    case separator
    case quit
}

/// Declarative menu layout (plan §5.2).
///
/// To add a menu item: add a `.command(title, AppCommand, key:)` entry below
/// and handle the `AppCommand` in `AppCoordinator.perform(_:)`.
enum MenuBuilder {
    static func entries(for state: MenuState) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .command("Capture Area", .capture(.area)),
            .command("Capture Previous Area", .capture(.previousArea)),
            .command("Capture Fullscreen", .capture(.fullscreen(.preferred))),
            .command("Capture Window", .capture(.window)),
            .command("Scrolling Capture", .capture(.scrolling)),
            .command("Self-Timer", .capture(.selfTimer)),
            .command("All-In-One", .capture(.allInOne)),
            .separator,
            .command("Capture Text", .captureText(lineBreaks: true)),
            .command("Capture Text Without Line Breaks", .captureText(lineBreaks: false)),
            .separator,
            .command("Capture History…", .openHistory),
            .command("Restore Recently Closed File", .restoreLastClosed, enabled: state.hasRecentlyClosed),
        ]
        entries += [
            .command("Open in Editor…", .openEditor(nil)),
            .command("Open from Clipboard", .openFromClipboard),
            .separator,
            .command("Hide Desktop Icons", .toggleDesktopIcons, checked: state.desktopIconsHidden),
        ]
        if state.hasLockedPins {
            entries.append(.command("Unlock All Pins", .unlockAllPins))
        }
        if state.hasPins {
            entries.append(.command("Close All Pins", .closeAllPins))
        }
        #if DEBUG
        entries += [
            .separator,
            .command("Design System Preview", .showDesignSystemPreview),
            .command("Debug: Capture Main Display", .debugCaptureMainDisplay),
            .command("Debug: Capture Front Window", .debugCaptureFrontWindow),
            .command("Debug: Quick Access Sample", .debugQuickAccessSample),
            .command("Debug: Pin Sample", .debugPinSample),
            .command("Debug: History Sample", .debugHistorySample),
        ]
        #endif
        entries += [
            .separator,
            .command("Settings…", .openSettings, key: ",", modifiers: .command),
            .quit,
        ]
        return entries
    }

    static func populate(_ menu: NSMenu, state: MenuState, target: MenuBarController) {
        menu.removeAllItems()
        for entry in entries(for: state) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .quit:
                menu.addItem(
                    NSMenuItem(
                        title: "Quit HakoShot",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q"
                    )
                )
            case let .command(title, command, key, modifiers, checked, enabled):
                let item = NSMenuItem(
                    title: title,
                    action: #selector(MenuBarController.performMenuCommand(_:)),
                    keyEquivalent: key
                )
                item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
                if key.isEmpty, let name = ShortcutBinding.name(for: command) {
                    item.setShortcut(KeyboardShortcuts.getShortcut(for: name))
                }
                item.target = target
                item.representedObject = CommandBox(command)
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
    }
}

/// Carries an `AppCommand` through `NSMenuItem.representedObject`.
final class CommandBox: NSObject {
    let command: AppCommand
    init(_ command: AppCommand) { self.command = command }
}
