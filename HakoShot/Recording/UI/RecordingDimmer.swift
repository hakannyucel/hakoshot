import AppKit
import HakoKit
import QuartzCore

/// Dims everything outside the recorded rect while recording (plan §4.4):
/// `Tokens.Recording.dim` (black 40 %) outside the rect, one borderless,
/// click-through panel per currently connected display. Only the display
/// being recorded actually dims — every other display's panel exists (kept
/// in step with the display arrangement, same bookkeeping as
/// `DesktopIconsToggle`) but draws nothing (plan §4.4: "Diğer ekranlar
/// karartılmaz"). `recordedRect: nil` (a fullscreen target) hides the dim
/// everywhere (plan §4.4: "Fullscreen'de karartma yok").
@MainActor
final class RecordingDimmer {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var layers: [CGDirectDisplayID: RecordingDimLayer] = [:]

    /// `CGWindowID` of every panel currently shown. The engine excludes our
    /// whole app by default; this is for a coordinator that wants the IDs anyway.
    var windowIDs: [CGWindowID] { panels.values.compactMap(Self.windowID(of:)) }
    var isVisible: Bool { !panels.isEmpty }

    /// Shows the dim; `recordedRect` (Quartz global points) is punched out on
    /// `recordingDisplayID`. Safe to call again — e.g. `WindowFollower` moving
    /// the recorded rect, or a display reconfiguration — panels are reused /
    /// added / removed to match the current `NSScreen.screens`.
    func show(recordedRect: GlobalRect?, recordingDisplayID: CGDirectDisplayID) {
        guard let screens = OverlayScreens.current() else { return }
        var seen = Set<CGDirectDisplayID>()
        for display in screens.displays {
            seen.insert(display.id)
            let panel = panels[display.id] ?? Self.makePanel()
            let layer = layers[display.id] ?? RecordingDimLayer()
            if panels[display.id] == nil {
                panel.contentView?.layer?.addSublayer(layer.layer)
            }
            panels[display.id] = panel
            layers[display.id] = layer
            panel.setFrame(display.screen.frame, display: false)
            layer.layer.frame = CGRect(origin: .zero, size: display.screen.frame.size)
            if display.id == recordingDisplayID, let recordedRect {
                layer.update(.selection(screens.localRect(recordedRect, in: display)))
            } else {
                layer.update(.clear)
            }
            panel.orderFrontRegardless()
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
            layers[id] = nil
        }
    }

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        layers.removeAll()
    }

    // MARK: Panel

    /// Below the border and control bar, above normal app windows.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    private static func windowID(of panel: NSPanel) -> CGWindowID? {
        panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }
}

/// Same four-rect dim technique as `SelectionBackdropLayer` (cheap to move at
/// high frequency), but no selection frame — that's `RecordingAreaBorderLayer`.
final class RecordingDimLayer {
    let layer = CALayer()
    private let top = CALayer()
    private let bottom = CALayer()
    private let left = CALayer()
    private let right = CALayer()

    enum State: Equatable {
        case clear
        case selection(CGRect)
    }

    init() {
        for dim in [top, bottom, left, right] {
            dim.backgroundColor = Tokens.Recording.dim.cgColor
            layer.addSublayer(dim)
        }
        OverlayLayerActions.disable([layer, top, bottom, left, right])
        update(.clear)
    }

    /// Call inside a transaction with actions disabled (as `OverlayLayerActions.disable` did in `init`).
    func update(_ state: State) {
        let full = layer.bounds
        switch state {
        case .clear:
            [top, bottom, left, right].forEach { $0.isHidden = true }
        case .selection(let sel):
            top.frame = CGRect(x: full.minX, y: sel.maxY, width: full.width, height: max(full.maxY - sel.maxY, 0))
            bottom.frame = CGRect(x: full.minX, y: full.minY, width: full.width, height: max(sel.minY - full.minY, 0))
            left.frame = CGRect(x: full.minX, y: sel.minY, width: max(sel.minX - full.minX, 0), height: sel.height)
            right.frame = CGRect(x: sel.maxX, y: sel.minY, width: max(full.maxX - sel.maxX, 0), height: sel.height)
            [top, bottom, left, right].forEach { $0.isHidden = false }
        }
    }
}

#if DEBUG
extension RecordingDimmer {
    /// Every panel currently shown, keyed by display (`RecordingChromeDebug`).
    var debugPanels: [CGDirectDisplayID: NSPanel] { panels }
}
#endif
