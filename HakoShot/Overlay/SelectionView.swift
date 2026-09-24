import AppKit
import HakoKit
import QuartzCore

/// Receives input from every display's `SelectionView`. Points are Quartz
/// global points.
protocol SelectionViewInput: AnyObject {
    func selectionView(_ view: SelectionView, mouseDownAt point: CGPoint, clickCount: Int)
    func selectionView(_ view: SelectionView, mouseDraggedTo point: CGPoint)
    func selectionView(_ view: SelectionView, mouseUpAt point: CGPoint)
    func selectionView(_ view: SelectionView, mouseMovedTo point: CGPoint)
    func selectionViewRightMouseDown(_ view: SelectionView)
    func selectionView(_ view: SelectionView, keyDown event: NSEvent)
    func selectionView(_ view: SelectionView, keyUp event: NSEvent)
    func selectionView(_ view: SelectionView, flagsChanged flags: NSEvent.ModifierFlags)
    /// Cursor to show at `point` (crosshair, resize arrows, hand, arrow).
    func selectionView(_ view: SelectionView, cursorAt point: CGPoint) -> NSCursor
}

/// What every display draws for the current overlay state (Quartz global).
struct OverlayRenderState {
    var cursor: CGPoint
    /// Crosshair lines follow the cursor.
    var showsCrosshair: Bool
    /// "X / Y" label next to the cursor (before a drag, no selection).
    var showsCursorLabel: Bool
    /// Current selection and the display it is confined to.
    var selection: GlobalRect?
    var selectionDisplayID: CGDirectDisplayID?
    /// Editable selection: draw the 8 resize handles.
    var showsHandles: Bool
    /// Window mode: the hovered window (`nil` = nothing under the cursor).
    var highlightedWindow: LocatedWindow?
    /// Loupe at the cursor (only on the display under the cursor).
    var showsMagnifier: Bool
    /// Loupe caption shows "W × H" of the selection instead of "X / Y".
    var magnifierShowsSize: Bool
}

/// Layer-backed content view of one `OverlayPanel`. Draws only through
/// sublayer frame changes (no `draw(_:)`), and forwards input to the controller.
///
/// Layer order (plan §4.1): frozen backdrop → dim + frame → window highlight
/// → handles → crosshair → label → magnifier. An accessory view (All-In-One
/// bar) sits above all layers as a subview.
final class SelectionView: NSView {
    let display: OverlayDisplay
    let screens: OverlayScreens
    weak var input: SelectionViewInput?

    private let frozen = FrozenBackdropLayer()
    private let backdrop = SelectionBackdropLayer()
    private let highlight = WindowHighlightLayer()
    private let handles = SelectionHandlesLayer()
    private let crosshair = CrosshairLayer()
    private let label = DimensionLabelLayer()
    private let magnifier = MagnifierLayer()

    private var fullSizeLayers: [CALayer] {
        [frozen.layer, backdrop.layer, highlight.layer, handles.layer, crosshair.layer, magnifier.layer]
    }

    init(display: OverlayDisplay, screens: OverlayScreens) {
        self.display = display
        self.screens = screens
        super.init(frame: CGRect(origin: .zero, size: display.screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor
        for sublayer in [frozen.layer, backdrop.layer, highlight.layer, handles.layer, crosshair.layer, label.layer, magnifier.layer] {
            sublayer.frame = bounds
            root.addSublayer(sublayer)
        }
        label.layer.frame = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fullSizeLayers.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    // MARK: Snapshot

    /// Display snapshot for the magnifier and, when `frozen`, the backdrop.
    func setSnapshot(_ snapshot: FrozenSnapshot?, frozen isFrozen: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifier.setSnapshot(snapshot)
        frozen.update(image: isFrozen ? snapshot?.image : nil)
        CATransaction.commit()
    }

    // MARK: Rendering

    func render(_ state: OverlayRenderState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = display.scale
        let cursorHere = screens.display(nearest: state.cursor)?.id == display.id
        let local = screens.localPoint(state.cursor, in: display)
        let magnifierHere = state.showsMagnifier && cursorHere && magnifier.hasSnapshot

        // Selection, dim, handles, size label.
        var sizeLabelShown = false
        if let selection = state.selection, let selectionDisplay = state.selectionDisplayID {
            if selectionDisplay == display.id {
                let localSelection = screens.localRect(selection, in: display)
                backdrop.update(.selection(localSelection))
                handles.update(selection: state.showsHandles ? localSelection : nil, scale: scale)
                if !(magnifierHere && state.magnifierShowsSize) {
                    label.show(Self.sizeText(selection), near: localSelection, within: bounds, scale: scale)
                    sizeLabelShown = true
                }
            } else {
                backdrop.update(.dimmedFully)
                handles.update(selection: nil, scale: scale)
            }
        } else {
            backdrop.update(.clear)
            handles.update(selection: nil, scale: scale)
        }

        // Window highlight.
        if let window = state.highlightedWindow, window.frame.cgRect.intersects(display.globalFrame.cgRect) {
            highlight.show(frame: screens.localRect(window.frame, in: display), title: window.displayName, scale: scale)
        } else {
            highlight.hide()
        }

        // Crosshair + cursor label.
        if state.showsCrosshair, cursorHere {
            crosshair.update(center: local, scale: scale)
        } else {
            crosshair.update(center: nil, scale: scale)
        }
        if state.showsCursorLabel, cursorHere, !magnifierHere, state.selection == nil {
            let text = Self.coordinateText(state.cursor, in: display)
            label.show(text, near: CGRect(origin: local, size: .zero), within: bounds, scale: scale)
        } else if !sizeLabelShown {
            label.hide()
        }

        // Magnifier.
        if magnifierHere {
            let caption = state.magnifierShowsSize
                ? (state.selection.map(Self.sizeText) ?? Self.coordinateText(state.cursor, in: display))
                : Self.coordinateText(state.cursor, in: display)
            magnifier.show(global: state.cursor, local: local, caption: caption, within: bounds, scale: scale)
        } else {
            magnifier.hide()
        }
    }

    /// "W × H" in points (plan §5.4).
    static func sizeText(_ rect: GlobalRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    /// "X / Y" in points, relative to the display's top-left corner.
    static func coordinateText(_ point: CGPoint, in display: OverlayDisplay) -> String {
        let x = Int((point.x - display.globalFrame.minX).rounded(.down))
        let y = Int((point.y - display.globalFrame.minY).rounded(.down))
        return "\(x) / \(y)"
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        guard let p = globalPoint(of: event) else {
            NSCursor.crosshair.set()
            return
        }
        (input?.selectionView(self, cursorAt: p) ?? .crosshair).set()
    }

    private func globalPoint(of event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        return screens.globalPoint(fromAppKit: window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = globalPoint(of: event) else { return }
        input?.selectionView(self, mouseDownAt: p, clickCount: event.clickCount)
        updateCursor(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = globalPoint(of: event) else { return }
        input?.selectionView(self, mouseDraggedTo: p)
        updateCursor(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = globalPoint(of: event) else { return }
        input?.selectionView(self, mouseUpAt: p)
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let p = globalPoint(of: event) else { return }
        input?.selectionView(self, mouseMovedTo: p)
        updateCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        guard let p = globalPoint(of: event) else { return }
        input?.selectionView(self, mouseMovedTo: p)
        updateCursor(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        input?.selectionViewRightMouseDown(self)
    }

    override func keyDown(with event: NSEvent) {
        input?.selectionView(self, keyDown: event)
    }

    override func keyUp(with event: NSEvent) {
        input?.selectionView(self, keyUp: event)
    }

    override func flagsChanged(with event: NSEvent) {
        input?.selectionView(self, flagsChanged: event.modifierFlags)
    }
}
