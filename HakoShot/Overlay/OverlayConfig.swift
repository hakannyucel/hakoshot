import HakoKit
import os

/// Input for one `SelectionOverlayController.run(_:)` session (plan §3.2, §4.1).
nonisolated struct OverlayConfig: Sendable, Equatable {
    nonisolated enum Mode: Sendable, Equatable {
        /// Drag a rectangle; `Space` before a drag toggles window mode.
        case area
        /// Hover-highlight + click a window; `Space` toggles back to area.
        case window
        /// Area + All-In-One HUD bar (set `editable` and pass an accessory).
        case allInOne
        /// Area selection that starts a scrolling capture (M6).
        case scrolling
        /// Area selection for OCR.
        case text
    }

    var mode: Mode
    /// Pre-selected rect in Quartz global points (e.g. from a URL command or
    /// "previous area"). Shown as the selection; `Return` confirms it, a new
    /// drag replaces it (or, when `editable`, it can be moved/resized).
    var initialRect: GlobalRect?
    /// Freeze Screen (plan §4.2): snapshot every display before the panels
    /// appear, show it as the backdrop and return `.frozenArea`.
    var freeze: Bool
    /// The selection stays after mouse-up with 8 resize handles; drag inside
    /// moves it, `Return` confirms, arrow keys move / resize it (All-In-One,
    /// scrolling; plan §4.14).
    var editable: Bool
    /// Loupe near the cursor (plan §4.3). `M` toggles it during a session.
    var showsMagnifier: Bool
    var crosshairMode: CrosshairMode
    /// Snap selection edges to window and display edges (plan §5.4; `⌘` held disables).
    var snapping: Bool

    init(
        mode: Mode = .area,
        initialRect: GlobalRect? = nil,
        freeze: Bool = false,
        editable: Bool = false,
        showsMagnifier: Bool = true,
        crosshairMode: CrosshairMode = .always,
        snapping: Bool = true
    ) {
        self.mode = mode
        self.initialRect = initialRect
        self.freeze = freeze
        self.editable = editable
        self.showsMagnifier = showsMagnifier
        self.crosshairMode = crosshairMode
        self.snapping = snapping
    }
}

extension Log {
    nonisolated static let overlay = Logger(subsystem: subsystem, category: "overlay")
}
