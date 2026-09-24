import AppKit
import HakoKit

/// A view embedded in the selection overlay, e.g. the All-In-One HUD bar
/// (WP3.4, plan §4.14). Pass it to `SelectionOverlayController.run(_:accessory:)`.
///
/// The overlay adds `view` to the panel of the display that has the
/// selection (else the display under the cursor), sizes it with
/// `view.fittingSize` (or its frame size when that is zero) and positions it
/// per `placement`. Mouse and keyboard
/// events inside `view` go to it (text fields work: the overlay panel is key).
protocol OverlayAccessory: AnyObject {
    /// Typically an `NSHostingView` with the SwiftUI bar.
    var view: NSView { get }
    var placement: OverlayAccessoryPlacement { get }
    /// Called once the panels are up; keep `host` weakly to change the selection.
    func overlayDidStart(_ host: any OverlayAccessoryHost)
    /// Selection created / moved / resized / cleared (`nil`). Quartz global points.
    func overlay(_ host: any OverlayAccessoryHost, selectionDidChange rect: GlobalRect?)
    /// `Space` or `setWindowMode(_:)` switched between area and window picking.
    func overlay(_ host: any OverlayAccessoryHost, windowModeDidChange isWindowMode: Bool)
    /// The session is ending with `outcome` (panels are about to close).
    func overlay(_ host: any OverlayAccessoryHost, willFinishWith outcome: SelectionOutcome)
}

extension OverlayAccessory {
    var placement: OverlayAccessoryPlacement { .belowSelection }
    func overlayDidStart(_ host: any OverlayAccessoryHost) {}
    func overlay(_ host: any OverlayAccessoryHost, selectionDidChange rect: GlobalRect?) {}
    func overlay(_ host: any OverlayAccessoryHost, windowModeDidChange isWindowMode: Bool) {}
    func overlay(_ host: any OverlayAccessoryHost, willFinishWith outcome: SelectionOutcome) {}
}

nonisolated enum OverlayAccessoryPlacement: Sendable, Equatable {
    /// Centered under the selection (`Tokens.Overlay.accessoryGap`), above it
    /// when there is no room below, inside its bottom edge as a last resort.
    /// Without a selection: bottom-center of the display under the cursor.
    case belowSelection
    /// Always bottom-center of the display (All-In-One bar position).
    case bottomCenter
}

/// What the overlay offers an accessory (implemented by `SelectionOverlayController`).
/// All rects are Quartz global points; setters clamp into one display and
/// pixel-align like a dragged selection.
protocol OverlayAccessoryHost: AnyObject {
    var selection: GlobalRect? { get }
    var selectionDisplayID: CGDirectDisplayID? { get }
    /// Display under the cursor (e.g. for an All-In-One "Fullscreen" button).
    var cursorDisplayID: CGDirectDisplayID? { get }
    var isWindowMode: Bool { get }
    /// Aspect lock (width / height) for new drags, handle resizes and
    /// `setSelectionSize`; `nil` = freeform. Setting it re-fits the current
    /// selection (keeps its width).
    var aspectRatio: CGFloat? { get set }

    /// Replaces the selection (becomes editable if the session is `editable`).
    func setSelection(_ rect: GlobalRect)
    /// Keeps the selection's origin, changes its size (size fields). Without
    /// a selection, creates one centered on the display under the cursor.
    func setSelectionSize(_ size: CGSize)
    func clearSelection()
    func setWindowMode(_ isWindowMode: Bool)
    /// Ends the session with the current selection (`.area` / `.frozenArea`);
    /// no-op without one.
    func confirmSelection()
    /// Ends the session with any outcome (e.g. `.fullscreen(displayID:)`).
    func finish(_ outcome: SelectionOutcome)
    func cancel()
}
