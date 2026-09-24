import os
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var menuBarController: MenuBarController?
    private var hotkeyManager: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("launched v\(AppInfo.version, privacy: .public) (\(AppInfo.build, privacy: .public))")
        NSApp.setActivationPolicy(.accessory)

        // Unit tests use the app as host; keep it headless there.
        guard !AppInfo.isRunningTests else { return }

        let menuBar = MenuBarController(coordinator: coordinator)
        menuBarController = menuBar
        coordinator.onMenuStateChanged = { [weak menuBar] in menuBar?.rebuild() }
        coordinator.start()
        let hotkeys = HotkeyManager(coordinator: coordinator)
        hotkeys.start()
        hotkeyManager = hotkeys
        coordinator.showOnboardingIfNeeded()

        if coordinator.permissions.screenRecordingGranted {
            Task { await ScreenCaptureService.shared.warmUp() }
        }

        #if DEBUG
        OverlayDebug.runFromLaunchArgumentsIfRequested()
        PinDebug.pinFromLaunchArgumentsIfRequested()
        WindowCaptureDebug.runFromLaunchArgumentsIfRequested()
        CaptureFlowDebug.runFromLaunchArgumentsIfRequested(coordinator: coordinator)
        EditorDebug.openFromLaunchArgumentsIfRequested()
        ScrollingCaptureDebug.runFromLaunchArgumentsIfRequested()
        DesignQADebug.runFromLaunchArgumentsIfRequested()
        runDebugLaunchArguments()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == URLSchemeHandler.scheme {
                coordinator.handle(url: url)
            } else if url.isFileURL {
                coordinator.openFiles([url])
            }
        }
    }

    #if DEBUG
    /// `-HakoQuickAccessDebug`: one sample card through the real router.
    /// `-HakoHistoryDebug`: seed + show history with the app's wiring; with
    /// `-HakoHistoryDebugRoot <path>` the package's own scratch-folder helper runs instead.
    private func runDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-HakoQuickAccessDebug") {
            Task { await coordinator.perform(.debugQuickAccessSample) }
        }
        if arguments.contains(HistoryDebug.rootArgument) {
            HistoryDebug.runFromLaunchArgumentsIfRequested(arguments)
        } else if arguments.contains(HistoryDebug.launchArgument) {
            Task { await coordinator.perform(.debugHistorySample) }
        }
    }
    #endif

    /// Opening the app again (Finder, Spotlight, `open`) while it runs and
    /// no window is up: show Settings. With "Show menu bar icon" off this is
    /// the only way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppInfo.isRunningTests, !flag else { return false }
        Log.app.notice("reopen without visible windows: showing Settings (menu bar icon visible: \(self.menuBarController?.isVisible ?? false))")
        coordinator.showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
