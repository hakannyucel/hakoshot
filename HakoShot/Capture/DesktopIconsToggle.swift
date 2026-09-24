import AppKit
import CoreGraphics
import os
@preconcurrency import ScreenCaptureKit

/// The menu's "Hide Desktop Icons" toggle (plan §4.5 option B): one borderless
/// cover window per display, just above Finder's icon window, showing that
/// display's wallpaper. Icons stay hidden until toggled back; Finder is never
/// restarted. In-memory only — icons are visible again after relaunch.
///
/// Wallpaper source, per display: a ScreenCaptureKit still of the system
/// `Wallpaper` window (exact pixels, dynamic wallpapers included at the time
/// of capture), else `NSWorkspace.desktopImageURL(for:)` aspect-filled, else
/// black. Refreshed on Space and display changes.
///
/// HakoShot excludes its own windows from every capture, so while this is on
/// captures must also apply `DesktopIconFilter` (see the integration notes).
final class DesktopIconsToggle {
    static let shared = DesktopIconsToggle()

    /// True while the covers are (being) shown.
    private(set) var isHidden = false
    /// Called after `isHidden` changes, e.g. to refresh the menu checkmark.
    var onChange: (Bool) -> Void = { _ in }

    /// `kCGDesktopIconWindowLevel + 1` (plan §4.5 B). Measured on macOS 27:
    /// at this level the cover renders pixel-identical to a capture with the
    /// icon windows filtered out, because the Window Server `underbelly`
    /// (menu-bar backdrop, same level) stays above it. One level higher
    /// covers the underbelly and visibly changes the top ~70 pt. Desktop
    /// widgets (`+ 2`) therefore stay visible on screen; captures still drop
    /// them through `DesktopIconFilter`.
    static let coverLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private var covers: [CGDirectDisplayID: NSPanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var rebuildTask: Task<Void, Never>?

    init() {}

    func toggle() {
        setHidden(!isHidden)
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        Log.capture.notice("desktop icons \(hidden ? "hidden" : "shown", privacy: .public)")
        if hidden {
            startObserving()
            scheduleRebuild()
        } else {
            stopObserving()
            rebuildTask?.cancel()
            rebuildTask = nil
            removeCovers()
        }
        onChange(hidden)
    }

    // MARK: Covers

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            await self?.rebuildCovers()
        }
    }

    private func rebuildCovers() async {
        let wallpapers = await Self.wallpaperImages()
        guard !Task.isCancelled, isHidden else { return }

        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let displayID = DisplayLayoutProvider.displayID(of: screen) else { continue }
            seen.insert(displayID)
            let panel = covers[displayID] ?? makeCover()
            covers[displayID] = panel
            panel.setFrame(screen.frame, display: false)
            configure(panel, image: wallpapers[displayID], screen: screen)
            panel.orderFrontRegardless()
        }
        for (displayID, panel) in covers where !seen.contains(displayID) {
            panel.orderOut(nil)
            covers[displayID] = nil
        }
    }

    private func removeCovers() {
        for panel in covers.values { panel.orderOut(nil) }
        covers.removeAll()
    }

    private func makeCover() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = Self.coverLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = true
        panel.hasShadow = false
        panel.backgroundColor = .black
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Swallow clicks so hidden icons can't be dragged or opened.
        panel.ignoresMouseEvents = false
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    private func configure(_ panel: NSPanel, image: CGImage?, screen: NSScreen) {
        guard let layer = panel.contentView?.layer else { return }
        layer.contentsScale = screen.backingScaleFactor
        if let image {
            layer.contents = image
            layer.contentsGravity = .resize
            return
        }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let fallback = NSImage(contentsOf: url) {
            layer.contents = fallback
            layer.contentsGravity = .resizeAspectFill
            Log.capture.notice("desktop icon cover: using desktopImageURL for \(screen.localizedName, privacy: .public)")
            return
        }
        layer.contents = nil
        layer.backgroundColor = NSColor.black.cgColor
        Log.capture.warning("desktop icon cover: no wallpaper for \(screen.localizedName, privacy: .public)")
    }

    // MARK: Wallpaper capture

    /// Stills of each display's `Wallpaper` window, keyed by display. Empty
    /// without Screen Recording permission.
    private nonisolated static func wallpaperImages() async -> [CGDirectDisplayID: CGImage] {
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var images: [CGDirectDisplayID: CGImage] = [:]
            for display in content.displays {
                guard let window = DesktopIconFilter.wallpaperWindow(in: content, displayFrame: display.frame) else {
                    Log.capture.notice("desktop icon cover: no Wallpaper window on display \(display.displayID)")
                    continue
                }
                let scale = backingScale(for: display.displayID) ?? 1
                images[display.displayID] = try await shoot(window, pointSize: display.frame.size, scale: scale)
            }
            return images
        } catch {
            Log.capture.error("desktop icon cover: wallpaper capture failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private nonisolated static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return nil }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private nonisolated static func shoot(_ window: SCWindow, pointSize: CGSize, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((pointSize.width * scale).rounded())
        config.height = Int((pointSize.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let box = CoverCaptureBox(filter: filter, config: config)
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: box.config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.captureFailed(error?.localizedDescription ?? "no image"))
                }
            }
        }
    }

    // MARK: Observers

    private func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
    }

    private func stopObserving() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

/// `SCContentFilter`/`SCStreamConfiguration` aren't `Sendable`; created here
/// and handed to ScreenCaptureKit once.
private nonisolated struct CoverCaptureBox: @unchecked Sendable {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
}
