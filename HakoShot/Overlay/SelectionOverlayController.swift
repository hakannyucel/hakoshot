import AppKit
import Carbon.HIToolbox
import HakoKit
import os

/// Runs the full-screen selection overlay on every display and returns what the
/// user picked (plan §3.2, §4.1). One session at a time.
///
/// Area: drag to select; `⇧` square, `⌥` from center, `Space` held during a
/// drag moves the selection, `Space` before a drag toggles window mode, arrow
/// keys move the cursor 1 pt (`⇧` 10 pt), `⌘` held disables edge snapping,
/// `M` toggles the magnifier, `Esc` / right-click cancels, a click without a
/// drag cancels. Releasing the mouse finishes, unless `config.editable`: then
/// the selection stays with 8 handles (drag inside moves, handles resize,
/// arrows move 1/10 pt, `⌥` grows, `⌃⌥` shrinks, `Return` or double-click
/// confirms).
///
/// Window: hover highlights the window under the cursor, click returns
/// `.window(id)`, `Space` goes back to area.
///
/// The selection is confined to the display the drag started on. All
/// geometry is Quartz global points; returned rects are pixel-aligned.
final class SelectionOverlayController {
    private enum Phase {
        case idle
        /// Mouse is down for a new selection but has not moved past the drag threshold.
        case pressed(anchor: CGPoint, display: OverlayDisplay)
        /// `current` is the logical drag point: the pointer (snapped), or where `Space`-moving left it.
        case dragging(anchor: CGPoint, current: CGPoint, display: OverlayDisplay)
        /// A finished selection waiting for `Return` (initial rect, or an editable selection).
        case selected(GlobalRect, display: OverlayDisplay)
        /// Moving or resizing an editable selection with the mouse.
        case editing(EditDrag, rect: GlobalRect, display: OverlayDisplay)
        /// Window mode: mouse is down.
        case windowPressed
    }

    private enum EditDrag {
        case move(start: CGPoint, original: GlobalRect)
        case resize(SelectionHandle, original: GlobalRect)
    }

    private var continuation: CheckedContinuation<SelectionOutcome, Never>?
    private var starting = false
    private var config = OverlayConfig()
    private var screens: OverlayScreens?
    private var panels: [OverlayPanel] = []
    private var views: [SelectionView] = []
    private var phase = Phase.idle
    private var cursor = CGPoint.zero
    private var constraints: SelectionConstraints = []
    private var spaceHeld = false
    private var commandHeld = false
    private var shiftHeld = false
    private var windowMode = false
    private var hoveredWindow: LocatedWindow?
    private var locator = WindowLocator(windows: [])
    private var snapEngine = SnapEngine.disabled
    private var magnifierOn = true
    private var snapshots: [CGDirectDisplayID: FrozenSnapshot] = [:]
    private var snapshotTask: Task<Void, Never>?
    private var accessory: (any OverlayAccessory)?
    private var hasReportedSelection = false
    private var lastReportedSelection: GlobalRect?
    private var ratio: CGFloat?
    private var screenObserver: (any NSObjectProtocol)?

    var isRunning: Bool { continuation != nil || starting }

    init() {}

    /// Shows the overlay and suspends until the user finishes or cancels.
    /// Returns `.cancelled` immediately if a session is already running or
    /// there is no screen.
    ///
    /// - Parameters:
    ///   - snapshots: display snapshots the caller already took (e.g. freeze
    ///     taken at hotkey time). Otherwise, with `config.freeze` the overlay
    ///     takes them before its panels appear; without freeze it takes them
    ///     in the background for the magnifier (our windows are excluded from
    ///     every capture, so the overlay never shows up in them).
    ///   - accessory: a view embedded above the overlay (All-In-One bar).
    func run(
        _ config: OverlayConfig,
        snapshots provided: [FrozenSnapshot]? = nil,
        accessory: (any OverlayAccessory)? = nil
    ) async -> SelectionOutcome {
        guard !isRunning else {
            Log.overlay.error("run() while a session is active; ignoring")
            return .cancelled
        }
        starting = true
        var initialSnapshots = provided ?? []
        if config.freeze, provided == nil {
            do {
                initialSnapshots = try await ScreenCaptureService.shared.snapshotAllDisplays()
            } catch {
                Log.overlay.error("freeze snapshot failed: \(String(describing: error), privacy: .public); continuing live")
            }
        }
        guard let screens = OverlayScreens.current() else {
            starting = false
            Log.overlay.error("no screens; cancelling")
            return .cancelled
        }
        return await withCheckedContinuation { continuation in
            self.starting = false
            self.continuation = continuation
            self.start(config, screens: screens, snapshots: initialSnapshots, accessory: accessory)
        }
    }

    /// Ends the running session with `.cancelled` (e.g. another command arrived).
    func cancel() {
        finish(.cancelled)
    }

    // MARK: Session

    private var isFrozen: Bool { config.freeze && !snapshots.isEmpty }

    private func start(
        _ config: OverlayConfig,
        screens: OverlayScreens,
        snapshots initial: [FrozenSnapshot],
        accessory: (any OverlayAccessory)?
    ) {
        self.config = config
        self.accessory = accessory
        phase = .idle
        let flags = NSEvent.modifierFlags
        constraints = Self.constraints(from: flags)
        commandHeld = flags.contains(.command)
        shiftHeld = flags.contains(.shift)
        spaceHeld = false
        windowMode = config.mode == .window
        hoveredWindow = nil
        magnifierOn = config.showsMagnifier
        ratio = nil
        lastReportedSelection = nil
        hasReportedSelection = false
        snapshots = Dictionary(initial.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })

        // Window list once per session (plan §4.4), before our panels exist.
        locator = WindowLocator.snapshot()
        snapEngine = config.snapping
            ? SnapEngine(windowFrames: locator.windows.map(\.frame), displayFrames: screens.displays.map(\.globalFrame))
            : .disabled

        install(screens, fadeIn: true)
        if let initial = config.initialRect,
           let display = screens.display(nearest: CGPoint(x: initial.midX, y: initial.midY)) {
            let clipped = SelectionMath.pixelAligned(initial, scale: display.scale, within: display.globalFrame)
            if SelectionMath.isCapturable(clipped, scale: display.scale) {
                phase = .selected(clipped, display: display)
            }
        }
        if windowMode { hoveredWindow = locator.window(at: cursor) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        if snapshots.isEmpty && config.showsMagnifier {
            loadMagnifierSnapshots()
        }
        render()
        accessory?.overlayDidStart(self)
        Log.overlay.info("overlay shown on \(screens.displays.count) display(s), mode \(String(describing: config.mode), privacy: .public), frozen \(self.isFrozen)")
    }

    /// Background snapshot for the magnifier when not frozen (plan §4.3).
    private func loadMagnifierSnapshots() {
        snapshotTask = Task { [weak self] in
            do {
                let taken = try await ScreenCaptureService.shared.snapshotAllDisplays()
                guard !Task.isCancelled, let self, self.continuation != nil else { return }
                self.snapshots = Dictionary(taken.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
                self.applySnapshots()
                self.render()
            } catch {
                Log.overlay.error("magnifier snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func applySnapshots() {
        for view in views {
            view.setSnapshot(snapshots[view.display.id], frozen: config.freeze)
        }
    }

    /// Builds one panel + view per display and shows them.
    private func install(_ screens: OverlayScreens, fadeIn: Bool) {
        removePanels()
        self.screens = screens
        cursor = screens.globalPoint(fromAppKit: NSEvent.mouseLocation)
        for display in screens.displays {
            let panel = OverlayPanel(frame: display.screen.frame)
            let view = SelectionView(display: display, screens: screens)
            view.input = self
            view.setSnapshot(snapshots[display.id], frozen: config.freeze)
            panel.contentView = view
            panel.onCancel = { [weak self] in self?.cancel() }
            panels.append(panel)
            views.append(view)
            if fadeIn { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
        }
        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Tokens.Overlay.fadeIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for panel in panels { panel.animator().alphaValue = 1 }
            }
        }
        makeKeyPanel(at: cursor)
        NSCursor.crosshair.set()
    }

    private func removePanels() {
        accessory?.view.removeFromSuperview()
        for panel in panels {
            panel.onCancel = nil
            panel.orderOut(nil)
        }
        views.forEach { $0.input = nil }
        panels = []
        views = []
    }

    private func screensChanged() {
        guard continuation != nil else { return }
        switch phase {
        case .pressed, .dragging, .editing, .windowPressed:
            Log.overlay.notice("screens changed during a drag; cancelling")
            finish(.cancelled)
        case .idle, .selected:
            guard let screens = OverlayScreens.current() else {
                finish(.cancelled)
                return
            }
            Log.overlay.notice("screens changed; rebuilding overlay")
            phase = .idle
            // Frozen pixels no longer match the arrangement.
            if config.freeze { snapshots = [:] }
            locator = WindowLocator.snapshot()
            snapEngine = config.snapping
                ? SnapEngine(windowFrames: locator.windows.map(\.frame), displayFrames: screens.displays.map(\.globalFrame))
                : .disabled
            install(screens, fadeIn: false)
            render()
        }
    }

    /// Ends the session with `outcome` (also `OverlayAccessoryHost.finish`).
    func finish(_ outcome: SelectionOutcome) {
        guard let continuation else { return }
        accessory?.overlay(self, willFinishWith: outcome)
        self.continuation = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        removePanels()
        accessory = nil
        screens = nil
        phase = .idle
        spaceHeld = false
        hoveredWindow = nil
        snapshots = [:]
        locator = WindowLocator(windows: [])
        NSCursor.arrow.set()
        continuation.resume(returning: outcome)
    }

    /// `.area`, or `.frozenArea` when the session is frozen.
    private func areaOutcome(_ rect: GlobalRect, display: OverlayDisplay) -> SelectionOutcome {
        if config.freeze, let snapshot = snapshots[display.id] {
            return .frozenArea(rect, displayID: display.id, snapshot: snapshot)
        }
        return .area(rect, displayID: display.id)
    }

    private func makeKeyPanel(at point: CGPoint) {
        guard let screens, let display = screens.display(nearest: point),
              let index = views.firstIndex(where: { $0.display.id == display.id }) else { return }
        let panel = panels[index]
        guard !panel.isKeyWindow else { return }
        panel.makeKey()
        // Don't steal focus from a text field in the accessory.
        if let responder = panel.firstResponder as? NSView, responder !== views[index], responder.isDescendant(of: views[index]) { return }
        panel.makeFirstResponder(views[index])
    }

    // MARK: Selection state

    private var snappingActive: Bool { config.snapping && !commandHeld }

    private func snapped(_ point: CGPoint) -> CGPoint {
        snappingActive ? snapEngine.snap(point) : point
    }

    private func dragRect(anchor: CGPoint, current: CGPoint, display: OverlayDisplay) -> GlobalRect {
        if let ratio, !constraints.contains(.fromCenter) {
            return SelectionEditing.rect(anchor: anchor, current: current, ratio: ratio, bounds: display.globalFrame)
        }
        return SelectionMath.rect(anchor: anchor, current: current, constraints: constraints, bounds: display.globalFrame)
    }

    private func aligned(_ rect: GlobalRect, _ display: OverlayDisplay) -> GlobalRect {
        SelectionMath.pixelAligned(rect, scale: display.scale, within: display.globalFrame)
    }

    private func currentSelection() -> (rect: GlobalRect, display: OverlayDisplay)? {
        switch phase {
        case .idle, .pressed, .windowPressed:
            return nil
        case .dragging(let anchor, let current, let display):
            return (aligned(dragRect(anchor: anchor, current: current, display: display), display), display)
        case .selected(let rect, let display), .editing(_, let rect, let display):
            return (rect, display)
        }
    }

    private func render() {
        let selection = windowMode ? nil : currentSelection()
        let crosshairAllowed: Bool
        switch config.crosshairMode {
        case .always: crosshairAllowed = true
        case .holdCommand: crosshairAllowed = commandHeld
        case .off: crosshairAllowed = false
        }
        var showsCrosshair = false
        var showsMagnifier = false
        var showsCursorLabel = false
        var magnifierShowsSize = false
        if !windowMode {
            switch phase {
            case .idle, .pressed:
                showsCrosshair = crosshairAllowed
                showsCursorLabel = true
                showsMagnifier = magnifierOn
            case .selected:
                // Initial rect (non-editable) keeps crosshair + loupe for a new drag.
                showsCrosshair = crosshairAllowed && !config.editable
                showsMagnifier = magnifierOn && !config.editable
            case .dragging:
                showsMagnifier = magnifierOn
                magnifierShowsSize = true
            case .editing(let drag, _, _):
                if case .resize = drag {
                    showsMagnifier = magnifierOn
                    magnifierShowsSize = true
                }
            case .windowPressed:
                break
            }
        }
        let showsHandles: Bool
        switch phase {
        case .selected, .editing: showsHandles = config.editable
        default: showsHandles = false
        }
        let state = OverlayRenderState(
            cursor: cursor,
            showsCrosshair: showsCrosshair,
            showsCursorLabel: showsCursorLabel,
            selection: selection?.rect,
            selectionDisplayID: selection?.display.id,
            showsHandles: showsHandles,
            highlightedWindow: windowMode ? hoveredWindow : nil,
            showsMagnifier: showsMagnifier,
            magnifierShowsSize: magnifierShowsSize
        )
        views.forEach { $0.render(state) }
        layoutAccessory(selection: selection)
    }

    // MARK: Accessory

    private func layoutAccessory(selection: (rect: GlobalRect, display: OverlayDisplay)?) {
        guard let accessory, let screens else { return }
        let reported: GlobalRect? = selection?.rect
        if !hasReportedSelection || lastReportedSelection != reported {
            hasReportedSelection = true
            lastReportedSelection = reported
            accessory.overlay(self, selectionDidChange: reported)
        }
        let display = selection?.display ?? screens.display(nearest: cursor)
        guard let display, let host = views.first(where: { $0.display.id == display.id }) else { return }
        let view = accessory.view
        if view.superview !== host {
            view.removeFromSuperview()
            host.addSubview(view)
        }
        // Auto Layout views (NSHostingView) report `fittingSize`; plain views keep their frame size.
        let fitting = view.fittingSize
        let size = fitting.width > 0 && fitting.height > 0 ? fitting : view.frame.size
        let bounds = host.bounds
        let gap = Tokens.Overlay.accessoryGap
        var frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.minY + Tokens.Overlay.accessoryBottomInset,
            width: size.width, height: size.height
        )
        if accessory.placement == .belowSelection, let selection {
            let local = screens.localRect(selection.rect, in: display)
            frame.origin.x = local.midX - size.width / 2
            if local.minY - gap - size.height >= bounds.minY + gap {
                frame.origin.y = local.minY - gap - size.height
            } else if local.maxY + gap + size.height <= bounds.maxY - gap {
                frame.origin.y = local.maxY + gap
            } else {
                frame.origin.y = local.minY + gap
            }
        }
        frame.origin.x = min(max(frame.origin.x, bounds.minX + gap), bounds.maxX - gap - size.width)
        frame = frame.integral
        if view.frame != frame { view.frame = frame }
    }

    // MARK: Pointer

    private func pointerMoved(to point: CGPoint) {
        switch phase {
        case .idle, .selected, .windowPressed:
            cursor = point
            makeKeyPanel(at: point)
            if windowMode { hoveredWindow = locator.window(at: point) }
        case .pressed(let anchor, let display):
            cursor = point
            if SelectionMath.isDrag(from: anchor, to: point) {
                let current = snapped(SelectionMath.clamp(point, to: display.globalFrame))
                phase = .dragging(anchor: anchor, current: current, display: display)
            }
        case .dragging(var anchor, var current, let display):
            if spaceHeld {
                // Move the whole selection with the pointer, stopping at the display edges.
                let raw = dragRect(anchor: anchor, current: current, display: display)
                let delta = CGVector(dx: point.x - cursor.x, dy: point.y - cursor.y)
                let applied = SelectionMath.clampedTranslation(of: raw, by: delta, within: display.globalFrame)
                anchor.x += applied.dx
                anchor.y += applied.dy
                current.x += applied.dx
                current.y += applied.dy
            } else {
                current = snapped(SelectionMath.clamp(point, to: display.globalFrame))
            }
            cursor = point
            phase = .dragging(anchor: anchor, current: current, display: display)
        case .editing(let drag, _, let display):
            cursor = point
            let bounds = display.globalFrame
            var rect: GlobalRect
            switch drag {
            case .move(let start, let original):
                let delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
                let applied = SelectionMath.clampedTranslation(of: original, by: delta, within: bounds)
                rect = GlobalRect(x: original.minX + applied.dx, y: original.minY + applied.dy, width: original.width, height: original.height)
                if snappingActive {
                    rect = SelectionEditing.fitted(snapEngine.snapTranslation(of: rect), within: bounds)
                }
            case .resize(let handle, let original):
                let lock = ratio ?? (shiftHeld && original.height > 0 ? original.width / original.height : nil)
                let target = lock == nil ? snapped(point) : point
                rect = SelectionEditing.resize(original, handle: handle, to: target, ratio: lock, bounds: bounds)
            }
            phase = .editing(drag, rect: aligned(rect, display), display: display)
        }
        render()
    }

    private func pointerDown(at point: CGPoint, clickCount: Int) {
        guard let screens, let display = screens.display(nearest: point) else { return }
        cursor = point
        if windowMode {
            hoveredWindow = locator.window(at: point)
            phase = .windowPressed
            render()
            return
        }
        if config.editable, case .selected(let rect, let selectionDisplay) = phase {
            if let handle = SelectionEditing.handle(at: point, of: rect) {
                phase = .editing(.resize(handle, original: rect), rect: rect, display: selectionDisplay)
                render()
                return
            }
            if rect.contains(point) {
                if clickCount >= 2 {
                    finish(areaOutcome(rect, display: selectionDisplay))
                    return
                }
                phase = .editing(.move(start: point, original: rect), rect: rect, display: selectionDisplay)
                render()
                return
            }
        }
        let anchor = snapped(SelectionMath.clamp(point, to: display.globalFrame))
        phase = .pressed(anchor: anchor, display: display)
        render()
    }

    private func pointerUp(at point: CGPoint) {
        switch phase {
        case .windowPressed:
            phase = .idle
            if let window = locator.window(at: point) {
                finish(.window(window.id))
            } else {
                render()
            }
        case .pressed:
            if config.editable {
                // Click without a drag clears the selection; the session stays.
                phase = .idle
                render()
            } else {
                // Click without a drag cancels (plan §5.4).
                finish(.cancelled)
            }
        case .dragging:
            pointerMoved(to: point)
            guard let selection = currentSelection(),
                  SelectionMath.isCapturable(selection.rect, scale: selection.display.scale) else {
                if config.editable {
                    phase = .idle
                    render()
                } else {
                    finish(.cancelled)
                }
                return
            }
            if config.editable {
                phase = .selected(selection.rect, display: selection.display)
                render()
            } else {
                finish(areaOutcome(selection.rect, display: selection.display))
            }
        case .editing(_, let rect, let display):
            phase = .selected(rect, display: display)
            render()
        case .idle, .selected:
            break
        }
    }

    private func cursorShape(at point: CGPoint) -> NSCursor {
        if windowMode { return .arrow }
        switch phase {
        case .editing(.move, _, _):
            return .closedHand
        case .editing(.resize(let handle, _), _, _):
            return Self.resizeCursor(handle)
        case .selected(let rect, _) where config.editable:
            if let handle = SelectionEditing.handle(at: point, of: rect) { return Self.resizeCursor(handle) }
            if rect.contains(point) { return .openHand }
            return .crosshair
        default:
            return .crosshair
        }
    }

    private static func resizeCursor(_ handle: SelectionHandle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    // MARK: Keyboard

    private func handleKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(.cancelled)
        case kVK_Space:
            if case .dragging = phase {
                // During a drag: hold to move.
                spaceHeld = true
            } else if !event.isARepeat, canToggleWindowMode {
                setWindowMode(!windowMode)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if windowMode {
                if let hoveredWindow { finish(.window(hoveredWindow.id)) }
            } else if case .selected(let rect, let display) = phase {
                finish(areaOutcome(rect, display: display))
            }
        case kVK_LeftArrow:
            arrow(.left, flags: flags)
        case kVK_RightArrow:
            arrow(.right, flags: flags)
        case kVK_UpArrow:
            arrow(.up, flags: flags)
        case kVK_DownArrow:
            arrow(.down, flags: flags)
        case kVK_ANSI_M:
            guard !event.isARepeat, flags.isDisjoint(with: [.command, .control, .option]) else { return }
            magnifierOn.toggle()
            if magnifierOn && snapshots.isEmpty && snapshotTask == nil { loadMagnifierSnapshots() }
            render()
        default:
            break
        }
    }

    /// `Space` before a drag toggles window mode (plan §4.4) in area/window sessions.
    private var canToggleWindowMode: Bool {
        switch config.mode {
        case .area, .window, .allInOne: break
        case .scrolling, .text: return false
        }
        switch phase {
        case .idle: return true
        case .selected: return !config.editable
        default: return false
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Space {
            spaceHeld = false
        }
    }

    private func arrow(_ direction: NudgeDirection, flags: NSEvent.ModifierFlags) {
        let large = flags.contains(.shift)
        if config.editable, !windowMode, case .selected(let rect, let display) = phase {
            // Plan §5.4: move 1/10 pt; ⌥ grows, ⌃⌥ shrinks the right/bottom edge.
            let kind: SelectionNudgeKind = flags.contains(.option) ? (flags.contains(.control) ? .shrink : .grow) : .move
            let moved = SelectionEditing.nudged(rect, direction, kind: kind, large: large, within: display.globalFrame)
            phase = .selected(aligned(moved, display), display: display)
            render()
            return
        }
        nudgeCursor(direction, large: large)
    }

    /// Arrow keys move the real cursor (plan §5.4), before and during a drag.
    private func nudgeCursor(_ direction: NudgeDirection, large: Bool) {
        guard let screens else { return }
        let bounds: GlobalRect?
        switch phase {
        case .pressed(_, let display), .dragging(_, _, let display), .editing(_, _, let display): bounds = display.globalFrame
        case .idle, .selected, .windowPressed: bounds = nil
        }
        let target = SelectionMath.nudge(cursor, direction, large: large, within: bounds)
        guard screens.display(nearest: target) != nil,
              bounds != nil || screens.display(containing: target) != nil else { return }
        CGWarpMouseCursorPosition(target)
        pointerMoved(to: target)
    }

    private static func constraints(from flags: NSEvent.ModifierFlags) -> SelectionConstraints {
        var result: SelectionConstraints = []
        if flags.contains(.shift) { result.insert(.square) }
        if flags.contains(.option) { result.insert(.fromCenter) }
        return result
    }
}

// MARK: - SelectionViewInput

extension SelectionOverlayController: SelectionViewInput {
    func selectionView(_ view: SelectionView, mouseDownAt point: CGPoint, clickCount: Int) {
        pointerDown(at: point, clickCount: clickCount)
    }

    func selectionView(_ view: SelectionView, mouseDraggedTo point: CGPoint) {
        pointerMoved(to: point)
    }

    func selectionView(_ view: SelectionView, mouseUpAt point: CGPoint) {
        pointerUp(at: point)
    }

    func selectionView(_ view: SelectionView, mouseMovedTo point: CGPoint) {
        pointerMoved(to: point)
    }

    func selectionViewRightMouseDown(_ view: SelectionView) {
        finish(.cancelled)
    }

    func selectionView(_ view: SelectionView, keyDown event: NSEvent) {
        handleKeyDown(event)
    }

    func selectionView(_ view: SelectionView, keyUp event: NSEvent) {
        handleKeyUp(event)
    }

    func selectionView(_ view: SelectionView, flagsChanged flags: NSEvent.ModifierFlags) {
        constraints = Self.constraints(from: flags)
        commandHeld = flags.contains(.command)
        shiftHeld = flags.contains(.shift)
        render()
    }

    func selectionView(_ view: SelectionView, cursorAt point: CGPoint) -> NSCursor {
        cursorShape(at: point)
    }
}

// MARK: - OverlayAccessoryHost

extension SelectionOverlayController: OverlayAccessoryHost {
    var selection: GlobalRect? { windowMode ? nil : currentSelection()?.rect }
    var selectionDisplayID: CGDirectDisplayID? { windowMode ? nil : currentSelection()?.display.id }
    var cursorDisplayID: CGDirectDisplayID? { screens?.display(nearest: cursor)?.id }
    var isWindowMode: Bool { windowMode }

    var aspectRatio: CGFloat? {
        get { ratio }
        set {
            ratio = newValue.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            guard let ratio, case .selected(let rect, let display) = phase else { return }
            let fitted = SelectionEditing.resized(rect, to: CGSize(width: rect.width, height: rect.width / ratio), within: display.globalFrame)
            // Keep the ratio if the height had to be clamped.
            let final = fitted.height < rect.width / ratio
                ? SelectionEditing.resized(rect, to: CGSize(width: fitted.height * ratio, height: fitted.height), within: display.globalFrame)
                : fitted
            phase = .selected(aligned(final, display), display: display)
            render()
        }
    }

    func setSelection(_ rect: GlobalRect) {
        guard continuation != nil, let screens,
              let display = screens.display(nearest: CGPoint(x: rect.midX, y: rect.midY)) else { return }
        let fitted = aligned(SelectionEditing.fitted(rect, within: display.globalFrame), display)
        guard SelectionMath.isCapturable(fitted, scale: display.scale) else { return }
        if windowMode { setWindowMode(false) }
        phase = .selected(fitted, display: display)
        render()
    }

    func setSelectionSize(_ size: CGSize) {
        guard continuation != nil, let screens else { return }
        if case .selected(let rect, let display) = phase {
            setSelection(SelectionEditing.resized(rect, to: size, within: display.globalFrame))
        } else if let display = screens.display(nearest: cursor) {
            let frame = display.globalFrame
            let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
            setSelection(SelectionEditing.resized(GlobalRect(origin: origin, size: .zero), to: size, within: frame))
        }
    }

    func clearSelection() {
        guard continuation != nil else { return }
        phase = .idle
        render()
    }

    func setWindowMode(_ isWindowMode: Bool) {
        guard continuation != nil, isWindowMode != windowMode else { return }
        windowMode = isWindowMode
        hoveredWindow = isWindowMode ? locator.window(at: cursor) : nil
        if !isWindowMode { phase = .idle }
        Log.overlay.info("window mode \(isWindowMode ? "on" : "off", privacy: .public)")
        render()
        cursorShape(at: cursor).set()
        accessory?.overlay(self, windowModeDidChange: isWindowMode)
    }

    func confirmSelection() {
        guard let selection = currentSelection() else { return }
        finish(areaOutcome(selection.rect, display: selection.display))
    }
}
