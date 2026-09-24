import SwiftUI

/// App entry point. HakoShot is a menu-bar-only agent (`LSUIElement = YES`);
/// all windows are created on demand by AppKit controllers owned by `AppCoordinator`.
@main
struct HakoShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI needs at least one scene. The Settings scene stays empty; its
        // menu command is redirected to our own settings window (plan §1.2).
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.coordinator.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
