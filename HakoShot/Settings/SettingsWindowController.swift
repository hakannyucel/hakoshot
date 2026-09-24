import os
import AppKit
import SwiftUI

/// Own `NSWindow` hosting the SwiftUI settings UI (custom sidebar, plan §1.2).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let activationPolicy: ActivationPolicyController
    private let model = SettingsWindowModel()

    init(permissions: PermissionsService, activationPolicy: ActivationPolicyController) {
        self.activationPolicy = activationPolicy
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsMetrics.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "HakoShot Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HakoShotSettings")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsRootView(model: model)
                .environment(permissions)
        )
        if !window.setFrameUsingName("HakoShotSettings") {
            window.center()
        }
        // Keep the restored position but always the current size (fixed-size window).
        window.setContentSize(SettingsMetrics.windowSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(page: SettingsPage? = nil) {
        if let page { model.selection = page }
        Log.settings.notice("show settings page=\(self.model.selection.rawValue, privacy: .public)")
        activationPolicy.acquire(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        activationPolicy.release(self)
    }
}

@Observable
final class SettingsWindowModel {
    var selection: SettingsPage = .general
}

struct SettingsRootView: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $model.selection)
            Divider()
            SettingsPageView(page: model.selection)
                .environment(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: SettingsMetrics.windowSize.width, minHeight: SettingsMetrics.windowSize.height)
        .ignoresSafeArea()
    }
}
