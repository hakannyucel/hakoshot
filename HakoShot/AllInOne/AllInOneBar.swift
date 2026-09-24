import AppKit
import HakoKit
import os
import SwiftUI

extension Log {
    nonisolated static let allInOne = Logger(subsystem: subsystem, category: "all-in-one")
}

/// The All-In-One HUD (plan §4.14, UI report §3): a mode bar and a size bar,
/// embedded in the selection overlay at the bottom-center of the display.
///
/// The selection stays editable. A mode button runs that mode on the
/// selection (Area / Timer / Text), Fullscreen and Window ignore it.
/// `Return` / double-click / the capture button run the highlighted mode
/// (default Area). After `SelectionOverlayController.run` returns, read
/// `chosenMode` to know what to do with the outcome.
final class AllInOneBar: OverlayAccessory {
    let model = AllInOneModel()
    let view: NSView
    var placement: OverlayAccessoryPlacement { .bottomCenter }

    /// The mode that ended the session; valid after the overlay finished.
    private(set) var chosenMode: AllInOneMode = .area
    /// The selection when the session ended (for "remember last selection").
    private(set) var finalSelection: GlobalRect?

    private weak var host: (any OverlayAccessoryHost)?
    /// Selection to restore when leaving window mode (the overlay clears it).
    private var selectionBeforeWindowMode: GlobalRect?

    init() {
        let model = model
        let actions = AllInOneBarActions()
        let hosting = AllInOneHostingView(rootView: AllInOneBarView(model: model, actions: actions))
        hosting.frame.size = hosting.fittingSize
        view = hosting
        actions.bar = self
    }

    // MARK: OverlayAccessory

    func overlayDidStart(_ host: any OverlayAccessoryHost) {
        self.host = host
        model.isWindowMode = host.isWindowMode
        model.selectionSize = host.selection?.size
        model.updateSizeTexts()
    }

    func overlay(_ host: any OverlayAccessoryHost, selectionDidChange rect: GlobalRect?) {
        model.selectionSize = rect?.size
        model.updateSizeTexts()
    }

    func overlay(_ host: any OverlayAccessoryHost, windowModeDidChange isWindowMode: Bool) {
        model.isWindowMode = isWindowMode
        if isWindowMode {
            model.activeMode = .window
        } else if model.activeMode == .window {
            model.activeMode = .area
        }
    }

    func overlay(_ host: any OverlayAccessoryHost, willFinishWith outcome: SelectionOutcome) {
        switch outcome {
        case .fullscreen: chosenMode = .fullscreen
        case .window: chosenMode = .window
        case .area, .frozenArea: chosenMode = model.activeMode == .window ? .area : model.activeMode
        case .cancelled: break
        }
        finalSelection = host.selection
        Log.allInOne.notice("finishing with mode \(self.chosenMode.rawValue, privacy: .public)")
    }

    // MARK: Actions (also used by DEBUG automation)

    /// A mode button was clicked.
    func tap(_ mode: AllInOneMode) {
        guard let host else { return }
        guard mode.isAvailable else {
            NSSound.beep()
            return
        }
        switch mode {
        case .fullscreen:
            let displayID = host.selectionDisplayID ?? host.cursorDisplayID ?? CGMainDisplayID()
            host.finish(.fullscreen(displayID: displayID))
        case .window:
            selectionBeforeWindowMode = host.selection
            model.activeMode = .window
            host.setWindowMode(true)
        case .area, .timer, .text, .scrolling:
            model.activeMode = mode
            if host.isWindowMode {
                host.setWindowMode(false)
                if let selectionBeforeWindowMode { host.setSelection(selectionBeforeWindowMode) }
                selectionBeforeWindowMode = nil
                model.activeMode = mode
            } else if host.selection != nil {
                host.confirmSelection()
            }
        }
    }

    /// The capture button: run the highlighted mode on the selection.
    func captureTapped() {
        guard let host, host.selection != nil else {
            NSSound.beep()
            return
        }
        host.confirmSelection()
    }

    /// A size field was submitted; `width`/`height` is the edited side.
    func submitSize(editedWidth: Bool) {
        defer { returnFocusToOverlay() }
        guard let host else { return }
        let width = Double(model.widthText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let height = Double(model.heightText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let current = model.selectionSize ?? CGSize(width: width ?? height ?? 0, height: height ?? width ?? 0)
        let ratio = model.ratio.ratio
        var size = ratio == nil
            ? CGSize(width: width ?? current.width, height: height ?? current.height)
            : AspectRatioPreset.size(
                width: editedWidth ? width : nil, height: editedWidth ? nil : height, current: current, ratio: ratio
            )
        size.width = size.width.rounded()
        size.height = size.height.rounded()
        guard size.width >= 1, size.height >= 1 else {
            model.updateSizeTexts()
            return
        }
        Log.allInOne.notice("size field -> \(Int(size.width))x\(Int(size.height)) pt")
        host.setSelectionSize(size)
        model.updateSizeTexts()
    }

    func toggleRatioMenu() {
        model.showsRatioMenu.toggle()
        relayoutSoon()
    }

    func selectRatio(_ preset: AspectRatioPreset) {
        var preset = preset
        if case .custom = preset {
            guard let size = model.selectionSize, size.width > 0, size.height > 0 else {
                NSSound.beep()
                return
            }
            preset = .custom(size.width / size.height)
        }
        model.ratio = preset
        model.showsRatioMenu = false
        host?.aspectRatio = preset.ratio
        relayoutSoon()
    }

    // MARK: Layout

    /// The overlay sizes the bar on its next render; the ratio menu changes
    /// the size in between, so grow/shrink around the bottom-center now.
    private func relayoutSoon() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.relayout()
        }
    }

    private func relayout() {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = view.frame
        frame.origin.x = frame.midX - size.width / 2
        frame.size = size
        view.frame = frame.integral
    }

    private func returnFocusToOverlay() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view.superview)
    }
}

/// Indirection so the SwiftUI view doesn't retain the bar.
final class AllInOneBarActions {
    weak var bar: AllInOneBar?
}

/// Takes the first click even when its panel isn't key (other display).
private final class AllInOneHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
