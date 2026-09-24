import AppKit
import HakoKit
import QuartzCore

/// Border around the recorded rect while recording (plan §4.4): 1 pt white
/// line, then 1 pt black line, `Tokens.Recording.borderGap` outside the rect
/// — the same double-line style as the screenshot selection overlay
/// (`Overlay/SelectionBackdropLayer.swift`). One click-through panel per
/// currently connected display; only the recording display actually draws a
/// border (see `RecordingDimmer`, same reasoning). `recordedRect: nil` hides
/// the border everywhere.
@MainActor
final class RecordingAreaBorder {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var layers: [CGDirectDisplayID: RecordingAreaBorderLayer] = [:]

    /// `CGWindowID` of every panel currently shown. The engine excludes our
    /// whole app by default; this is for a coordinator that wants the IDs anyway.
    var windowIDs: [CGWindowID] { panels.values.compactMap(Self.windowID(of:)) }
    var isVisible: Bool { !panels.isEmpty }

    /// Shows/moves the border; `recordedRect` is in Quartz global points. Call
    /// again with a new rect to follow a moving window (`WindowFollower`) —
    /// cheap (four rect layers, no path rebuild).
    func show(recordedRect: GlobalRect?, recordingDisplayID: CGDirectDisplayID) {
        guard let screens = OverlayScreens.current() else { return }
        var seen = Set<CGDirectDisplayID>()
        for display in screens.displays {
            seen.insert(display.id)
            let panel = panels[display.id] ?? Self.makePanel()
            let layer = layers[display.id] ?? RecordingAreaBorderLayer()
            if panels[display.id] == nil {
                panel.contentView?.layer?.addSublayer(layer.layer)
            }
            panels[display.id] = panel
            layers[display.id] = layer
            panel.setFrame(display.screen.frame, display: false)
            layer.layer.frame = CGRect(origin: .zero, size: display.screen.frame.size)
            if display.id == recordingDisplayID, let recordedRect {
                layer.update(screens.localRect(recordedRect, in: display))
            } else {
                layer.update(nil)
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

    /// Above the dim, below the control bar / countdown.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

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

/// Inner (white) + outer (black) border layers, `Tokens.Recording.borderGap`
/// outside the recorded rect (plan §4.4).
final class RecordingAreaBorderLayer {
    let layer = CALayer()
    private let inner = CALayer()
    private let outer = CALayer()

    init() {
        inner.borderColor = Tokens.Recording.borderInnerColor.cgColor
        inner.borderWidth = Tokens.Recording.borderLineWidth
        outer.borderColor = Tokens.Recording.borderOuterColor.cgColor
        outer.borderWidth = Tokens.Recording.borderLineWidth
        layer.addSublayer(outer)
        layer.addSublayer(inner)
        OverlayLayerActions.disable([layer, inner, outer])
        update(nil)
    }

    /// `rect` is the recorded rect in the panel's own (AppKit, bottom-left)
    /// coordinates; `nil` hides the border.
    func update(_ rect: CGRect?) {
        guard let rect else {
            inner.isHidden = true
            outer.isHidden = true
            return
        }
        let gap = Tokens.Recording.borderGap
        let line = Tokens.Recording.borderLineWidth
        inner.frame = rect.insetBy(dx: -gap, dy: -gap)
        outer.frame = rect.insetBy(dx: -gap - line, dy: -gap - line)
        inner.isHidden = false
        outer.isHidden = false
    }
}

#if DEBUG
extension RecordingAreaBorder {
    /// Every panel currently shown, keyed by display (`RecordingChromeDebug`).
    var debugPanels: [CGDirectDisplayID: NSPanel] { panels }
}
#endif
