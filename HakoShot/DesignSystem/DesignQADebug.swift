#if DEBUG
import AppKit
import HakoKit
import os
import SwiftUI

/// DEBUG visual QA (plan §8.3): `-HakoDesignQA <dir>` shows every custom
/// surface with generated sample content, writes each of our windows as PNG
/// (in-process `cacheDisplay`, so it works with the displays asleep and
/// never contains other apps' pixels), in light and dark, then closes them.
/// Optional `-HakoDesignQAOnly quickAccess,pin,…` limits the surfaces.
///
/// Run a separate DEBUG build for this (not the installed app): it closes
/// every pin and Quick Access card of the debug controllers it opens.
enum DesignQADebug {
    static let launchArgument = "-HakoDesignQA"
    static let onlyArgument = "-HakoDesignQAOnly"

    enum Surface: String, CaseIterable {
        case allInOne, quickAccess, pin, history, editor, crop, background, toast, scrolling, selfTimer, onboarding
    }

    private static let log = Logger(subsystem: Log.subsystem, category: "design-qa")
    private static var historyController: HistoryOverlayController?

    static func runFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else { return }
        let dir = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        var surfaces = Surface.allCases
        if let only = arguments.firstIndex(of: onlyArgument), arguments.indices.contains(only + 1) {
            let names = Set(arguments[only + 1].split(separator: ",").map(String.init))
            surfaces = surfaces.filter { names.contains($0.rawValue) }
        }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1))
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for surface in surfaces {
                    await run(surface, into: dir, suffix: suffix)
                }
            }
            NSApp.appearance = nil
            log.notice("design QA snapshots written to \(dir.path, privacy: .public)")
        }
    }

    // MARK: Surfaces

    private static func run(_ surface: Surface, into dir: URL, suffix: String) async {
        let name = "\(surface.rawValue)-\(suffix)"
        switch surface {
        case .allInOne:
            let bar = AllInOneBar()
            await snapshotDetached(bar.view, name: name, dir: dir, backdrop: .darkWallpaper)

        case .quickAccess:
            QuickAccessDebug.showSample(count: 2, hoverNewest: true)
            try? await Task.sleep(for: .seconds(1))
            snapshotWindows(titled: "Quick Access", name: name, dir: dir, backdrop: .wallpaper)
            QuickAccessDebug.controller.closeAll()
            try? await Task.sleep(for: .seconds(0.8))
            let leftovers = NSApp.windows.filter { $0.title == "Quick Access" && $0.isVisible }.count
            log.notice("quick access panels still visible after closeAll: \(leftovers)")

        case .pin:
            guard let panel = PinDebug.pinSample(controller: .shared) else { return }
            try? await Task.sleep(for: .seconds(0.5))
            (panel.contentView as? PinContentView)?.setHoverVisible(true)
            try? await Task.sleep(for: .seconds(0.5))
            snapshot(panel, name: name, dir: dir, backdrop: .wallpaper)
            PinController.shared.closeAll()

        case .history:
            let root = dir.appending(path: "history-root", directoryHint: .isDirectory)
            let controller = historyController ?? HistoryOverlayController(store: HistoryStore(rootURL: root))
            historyController = controller
            await HistoryDebug.seedAndShow(controller: controller)
            try? await Task.sleep(for: .seconds(1.5))
            snapshotWindows(where: { $0 is HistoryPanel }, name: name, dir: dir, backdrop: .darkWallpaper)
            controller.close()

        case .editor, .crop, .background:
            guard let controller = EditorDebug.openSample(annotated: true) else { return }
            try? await Task.sleep(for: .seconds(0.8))
            if surface == .crop { controller.model.beginCrop() }
            if surface == .background { controller.model.toggleBackgroundPanel() }
            try? await Task.sleep(for: .seconds(0.8))
            if let window = controller.window { snapshot(window, name: name, dir: dir, backdrop: nil) }
            EditorWindowController.closeAllDiscardingChanges()

        case .toast:
            let center = CGPoint(x: NSScreen.main?.frame.midX ?? 400, y: NSScreen.main?.frame.midY ?? 400)
            for (index, content) in [ToastHUD.Content.commandV, .linkCopied(url: URL(string: "https://example.com")), .message("No text found")].enumerated() {
                ToastHUD.show(content, near: center)
                try? await Task.sleep(for: .seconds(0.4))
                snapshotWindows(where: { String(describing: type(of: $0)) == "ToastPanel" }, name: "\(name)-\(index)", dir: dir, backdrop: .wallpaper)
            }
            ToastHUD.dismiss()

        case .scrolling:
            guard let screen = NSScreen.main, let displayID = DisplayLayoutProvider.displayID(of: screen) else { return }
            let rect = GlobalRect(x: 300, y: 200, width: 600, height: 500)
            guard let ui = ScrollingOverlayUI(rect: rect, displayID: displayID) else { return }
            ui.model.phase = .capturing
            ui.model.hasProgress = true
            ui.model.isAutoScrolling = true
            ui.model.preview = QuickAccessDebug.sampleResult(pointSize: CGSize(width: 300, height: 900))?.image
            ui.show()
            try? await Task.sleep(for: .seconds(0.8))
            snapshotWindows(where: { String(describing: type(of: $0)) == "ScrollingPanel" && $0.frame.width < screen.frame.width }, name: name, dir: dir, backdrop: .wallpaper)
            ui.close()

        case .selfTimer:
            let timer = SelfTimerController()
            let run = Task { await timer.countdown(seconds: 3, around: GlobalRect(x: 400, y: 300, width: 400, height: 300)) }
            try? await Task.sleep(for: .seconds(0.9))
            snapshotWindows(where: { $0 is SelfTimerHUDPanel }, name: name, dir: dir, backdrop: .wallpaper)
            timer.cancel()
            _ = await run.value

        case .onboarding:
            // Not through AppCoordinator: its close handler would set `onboardingCompleted`.
            let controller = OnboardingWindowController(
                permissions: PermissionsService(), activationPolicy: ActivationPolicyController()
            )
            controller.present()
            for step in OnboardingStep.allCases {
                controller.debugShow(step: step)
                try? await Task.sleep(for: .seconds(0.6))
                if let window = controller.window { snapshot(window, name: "\(name)-\(step.rawValue)", dir: dir, backdrop: nil) }
            }
            controller.close()
        }
    }

    // MARK: Snapshot helpers

    private enum Backdrop {
        case wallpaper, darkWallpaper

        var colors: [NSColor] {
            switch self {
            case .wallpaper: [NSColor(hex: 0x9FB8D8), NSColor(hex: 0xD9C7E8)]
            case .darkWallpaper: [NSColor(hex: 0x23324A), NSColor(hex: 0x4A3A5C)]
            }
        }
    }

    private static func snapshotWindows(titled title: String, name: String, dir: URL, backdrop: Backdrop?) {
        snapshotWindows(where: { $0.title == title }, name: name, dir: dir, backdrop: backdrop)
    }

    private static func snapshotWindows(where predicate: (NSWindow) -> Bool, name: String, dir: URL, backdrop: Backdrop?) {
        let windows = NSApp.windows.filter { $0.isVisible && predicate($0) }
        for (index, window) in windows.enumerated() {
            snapshot(window, name: windows.count > 1 ? "\(name)-w\(index)" : name, dir: dir, backdrop: backdrop)
        }
        if windows.isEmpty { log.error("\(name, privacy: .public): no window") }
    }

    private static func snapshot(_ window: NSWindow, name: String, dir: URL, backdrop: Backdrop?) {
        // Title bar included for regular windows (traffic lights, toolbar).
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        write(view, name: name, dir: dir, backdrop: backdrop)
    }

    /// A view that isn't in a window yet (All-In-One bar): hosts it in a
    /// borderless offscreen window first.
    private static func snapshotDetached(_ view: NSView, name: String, dir: URL, backdrop: Backdrop?) async {
        let size = view.fittingSize == .zero ? view.frame.size : view.fittingSize
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width + 80, height: size.height + 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        let container = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        view.frame = CGRect(x: 40, y: 40, width: size.width, height: size.height)
        container.addSubview(view)
        window.contentView = container
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.5))
        write(container, name: name, dir: dir, backdrop: backdrop)
        window.orderOut(nil)
        view.removeFromSuperview()
    }

    private static func write(_ view: NSView, name: String, dir: URL, backdrop: Backdrop?) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let output: NSBitmapImageRep
        if let backdrop, let composed = compose(rep, over: backdrop) {
            output = composed
        } else {
            output = rep
        }
        guard let data = output.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appending(path: "\(name).png"))
        log.notice("snapshot \(name, privacy: .public) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// Draws the (mostly transparent) HUD over a neutral gradient so it can be judged.
    private static func compose(_ rep: NSBitmapImageRep, over backdrop: Backdrop) -> NSBitmapImageRep? {
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGradient(colors: backdrop.colors)?.draw(in: bounds, angle: 45)
        rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
#endif
