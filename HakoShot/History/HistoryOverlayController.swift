import AppKit
import HakoKit
import os
import SwiftUI

/// Full-screen History overlay (plan §4.12, report §10).
///
/// Keys: ←/→ browse, Tab cycles filters, Return restores, ⌘C copies, ⌘E edit,
/// ⌘P pin, Delete/⌫ removes from history, Esc (or ⌘W, or a click on the
/// backdrop) closes. Restore / Edit / Pin are delegated through the closures
/// below because Quick Access, the editor and Pin live elsewhere; the overlay
/// closes itself before calling them.
@MainActor
final class HistoryOverlayController {
    static let shared = HistoryOverlayController()
    /// Pixel size requested for the enlarged selected card.
    static let previewMaxPixelSize = 1800

    /// Return / Restore pill / double-click: open the capture in Quick Access.
    var onRestore: ((HistoryItem, CGImage) -> Void)?
    /// ⌘E: open in the editor.
    var onEdit: ((HistoryItem, CGImage) -> Void)?
    /// ⌘P: pin to screen.
    var onPin: ((HistoryItem, CGImage) -> Void)?

    let store: HistoryStore
    private let model = HistoryOverlayModel()
    private var panel: HistoryPanel?
    private var loadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var resignObserver: (any NSObjectProtocol)?

    init(store: HistoryStore = .shared) {
        self.store = store
    }

    var isVisible: Bool { panel != nil }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    /// Shows the overlay on `screen` (default: the screen under the mouse).
    func show(on screen: NSScreen? = nil) {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = screen ?? Self.screenUnderMouse() ?? NSScreen.main else { return }

        model.filter = .all
        model.selectedID = nil
        model.toast = nil
        model.thumbnails = [:]
        model.previews = [:]

        let panel = HistoryPanel(frame: screen.frame)
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let actions = HistoryFilmstripActions(
            selectFilter: { [weak self] filter in self?.select(filter: filter) },
            restore: { [weak self] in self?.performRestore() },
            close: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: HistoryFilmstripView(model: model, actions: actions))
        hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        DSAnimation.run(.overlayFadeIn) { _ in panel.animator().alphaValue = 1 }
        reload()
        Log.history.info("overlay shown")
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        loadTask?.cancel()
        toastTask?.cancel()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        DSAnimation.run(.toastOut) { _ in
            panel.animator().alphaValue = 0
        } completion: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Data

    private func select(filter: HistoryFilter) {
        guard filter != model.filter else { return }
        model.filter = filter
        model.selectedID = nil
        reload()
    }

    /// Reloads the list for the current filter, then thumbnails, then the selected preview.
    private func reload() {
        loadTask?.cancel()
        let filter = model.filter
        loadTask = Task { [weak self, store] in
            let items = await store.recent(filter: filter)
            guard let self, !Task.isCancelled else { return }
            self.model.setItems(items)
            await self.loadPreviewForSelection()
            for item in items where self.model.thumbnails[item.id] == nil {
                guard !Task.isCancelled else { return }
                if let cg = await store.thumbnail(for: item) {
                    self.model.thumbnails[item.id] = NSImage(cgImage: cg, size: .zero)
                }
            }
        }
    }

    private func loadPreviewForSelection() async {
        guard let item = model.selectedItem, model.previews[item.id] == nil else { return }
        if let cg = await store.preview(for: item, maxPixelSize: Self.previewMaxPixelSize) {
            model.previews[item.id] = NSImage(cgImage: cg, size: .zero)
        }
    }

    private func moveSelection(by delta: Int) {
        model.moveSelection(by: delta)
        Task { await loadPreviewForSelection() }
    }

    // MARK: - Actions

    private func performRestore() {
        withSelectedImage { [self] item, image in
            close()
            Task { [store] in await store.markReopened(id: item.id) }
            onRestore?(item, image)
        }
    }

    private func performEdit() {
        withSelectedImage { [self] item, image in
            close()
            onEdit?(item, image)
        }
    }

    private func performPin() {
        withSelectedImage { [self] item, image in
            close()
            onPin?(item, image)
        }
    }

    private func performCopy() {
        withSelectedImage { [weak self] item, image in
            do {
                try ClipboardWriter().write(image, fileURL: item.savedFileURL)
                self?.showToast("Copied to clipboard")
            } catch {
                Log.history.error("copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func performDelete() {
        guard let item = model.selectedItem else { return }
        Task { [weak self, store] in
            await store.remove(id: item.id)
            guard let self else { return }
            var items = self.model.items
            items.removeAll { $0.id == item.id }
            self.model.thumbnails[item.id] = nil
            self.model.previews[item.id] = nil
            self.model.setItems(items)
            await self.loadPreviewForSelection()
        }
    }

    private func withSelectedImage(_ body: @escaping @MainActor (HistoryItem, CGImage) -> Void) {
        guard let item = model.selectedItem else { return }
        Task { [store] in
            guard let image = await store.image(for: item) else {
                Log.history.error("original missing for \(item.id.uuidString, privacy: .public)")
                return
            }
            body(item, image)
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        model.toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Tokens.Duration.toastHold))
            guard !Task.isCancelled else { return }
            self?.model.toast = nil
        }
    }

    // MARK: - Keyboard

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    /// Returns whether the event was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": performCopy()
            case "e": performEdit()
            case "p": performPin()
            case "w": close()
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case KeyCode.left: moveSelection(by: -1)
        case KeyCode.right: moveSelection(by: 1)
        case KeyCode.returnKey, KeyCode.keypadEnter: performRestore()
        case KeyCode.delete, KeyCode.forwardDelete: performDelete()
        case KeyCode.escape: close()
        case KeyCode.tab:
            let all = HistoryFilter.allCases
            let current = all.firstIndex(of: model.filter) ?? 0
            let step = flags.contains(.shift) ? all.count - 1 : 1
            select(filter: all[(current + step) % all.count])
        default: return false
        }
        return true
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

/// Borderless, non-activating full-screen panel that still takes key events.
final class HistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Intercepts keys before SwiftUI (the scroll view would eat ←/→ otherwise).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}
