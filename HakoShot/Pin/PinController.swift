import AppKit
import CoreGraphics
import HakoKit
import Observation
import os

/// Owns every pin window (plan §4.12). `hasPins` / `hasLockedPins` are observable
/// (and mirrored by `onPinsChanged`) so the menu bar can show
/// "Unlock All Pins" / "Close All Pins" only when relevant (plan §5.2).
@Observable
final class PinController {
    static let shared = PinController()

    private(set) var pinCount = 0
    private(set) var hasLockedPins = false
    var hasPins: Bool { pinCount > 0 }

    /// Called after any pin is added, closed, locked or unlocked.
    @ObservationIgnored var onPinsChanged: (() -> Void)?
    /// "Open in Editor" (hover bar, ⌘E, double-click, context menu). `nil` = disabled.
    @ObservationIgnored var onEdit: ((PinContent) -> Void)?
    /// "Recognize Text" (context menu). `nil` = disabled.
    @ObservationIgnored var onRecognizeText: ((PinContent) -> Void)?

    @ObservationIgnored private var panels: [PinPanel] = []
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    // MARK: Pinning

    /// Pins `result` over the area it was captured from (centered on the active
    /// display when the capture has no source rect, e.g. window captures).
    @discardableResult
    func pin(_ result: CaptureResult) -> PinPanel {
        pin(result.image, pointSize: result.pointSize, at: result.sourceRect)
    }

    /// Pins `image` (`pointSize × scale` pixels) at `origin` (Quartz global points)
    /// or centered on the display under the pointer. Shown at point size, so a
    /// Retina capture appears 1:1 with what was on screen.
    @discardableResult
    func pin(_ image: CGImage, pointSize: CGSize, at origin: GlobalRect? = nil) -> PinPanel {
        let size = pointSize.width > 0 && pointSize.height > 0
            ? pointSize
            : CGSize(width: image.width, height: image.height)
        let content = PinContent(image: image, pointSize: size)
        let panel = PinPanel(
            content: content,
            frame: initialFrame(for: size, origin: origin),
            appearance: PinAppearance(settings: settings),
            settings: settings
        )
        panel.pinDelegate = self
        panel.model.canEdit = onEdit != nil
        panels.append(panel)
        panel.show()
        Log.pin.notice("pinned \(image.width)x\(image.height) px as \(Int(size.width))x\(Int(size.height)) pt")
        stateChanged()
        return panel
    }

    // MARK: Bulk actions

    func closeAll() {
        let closing = panels
        panels.removeAll()
        for panel in closing { panel.dismiss {} }
        stateChanged()
    }

    func unlockAll() {
        for panel in panels where panel.isLocked { panel.setLocked(false) }
        stateChanged()
    }

    func close(_ panel: PinPanel) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        panels.remove(at: index)
        panel.dismiss {}
        stateChanged()
        // Hand keyboard focus to the most recent remaining pin.
        if let next = panels.last(where: { !$0.isLocked }), NSApp.keyWindow == nil || NSApp.keyWindow === panel {
            next.makeKey()
        }
    }

    // MARK: Private

    private func stateChanged() {
        if pinCount != panels.count { pinCount = panels.count }
        let locked = panels.contains { $0.isLocked }
        if hasLockedPins != locked { hasLockedPins = locked }
        onPinsChanged?()
    }

    private func initialFrame(for size: CGSize, origin: GlobalRect?) -> CGRect {
        if let origin {
            let rect = GlobalRect(origin: origin.origin, size: size)
            if let appKit = ScreenGeometry.appKitRect(fromGlobal: rect, layout: DisplayLayoutProvider.currentLayout()) {
                return appKit
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return PinGeometry.centeredFrame(pointSize: size, in: visible)
    }
}

extension PinController: PinPanelDelegate {
    var canEditPins: Bool { onEdit != nil }
    var canRecognizeTextInPins: Bool { onRecognizeText != nil }

    func pinPanelDidRequestClose(_ panel: PinPanel) { close(panel) }
    func pinPanelDidRequestCloseAll(_ panel: PinPanel) { closeAll() }
    func pinPanelDidChangeLock(_ panel: PinPanel) { stateChanged() }
    func pinPanelDidRequestEdit(_ panel: PinPanel) { onEdit?(panel.content) }
    func pinPanelDidRequestRecognizeText(_ panel: PinPanel) { onRecognizeText?(panel.content) }
}
