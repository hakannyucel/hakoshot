import AppKit
import Foundation
import HakoKit
import SwiftUI
import Testing
@testable import HakoShot

/// Manual visual QA for crop mode + the Background panel (WP5.1 / WP5.2).
/// Same protocol as `EditorVisualCheck` (`HAKO_EDITOR_VISUAL_DIR`, `state.txt`,
/// `ack-<phase>`); run it alone with `-only-testing`.
@MainActor
@Suite struct CropBackgroundVisualCheck {
    @Test(.enabled(if: EditorVisualCheck.directory != nil))
    func cropAndBackground() async throws {
        let dir = try #require(EditorVisualCheck.directory)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let controller = try #require(EditorDebug.openSample(annotated: true))
        let model = controller.model
        let window = try #require(controller.window)

        // 1. Crop mode, 16:9, slightly inset.
        model.selectTool(.crop)
        model.updateCrop { $0.setAspect(.ratio(width: 16, height: 9)) }
        model.updateCrop { s in
            s.rect = CropMath.resize(s.rect, handle: .topLeft, to: CGPoint(x: s.rect.minX + 200, y: s.rect.minY + 100),
                                     ratio: s.ratio, bounds: s.bounds)
        }
        var barWidth: CGFloat = 0
        if let session = model.cropSession {
            barWidth = NSHostingView(rootView: CropBar(model: model, session: session)).fittingSize.width
        }
        let available = window.frame.width - EditorMetrics.toolbarLeadingInset - EditorMetrics.toolbarTrailingInset - 64 - 21
        try await phase(1, window: window, dir: dir, note: "crop \(model.cropSession.map { "\($0.rect)" } ?? "-") cropBar=\(barWidth) available=\(available)")

        // 2. Applied + background panel with the default gradient.
        model.applyCrop()
        model.selectTool(.background)
        model.setBackgroundEnabled(true)
        model.selectTool(.rectangle)
        try await Task.sleep(for: .milliseconds(300))
        let clickNote = dragReport(controller)
        try await phase(2, window: window, dir: dir, note: "crop=\(model.document.crop ?? .null) canvas=\(controller.canvas.frame.size) \(clickNote)")

        // 3. Blurred fill, bottom alignment, 16:9 ratio, dark mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.updateBackground { $0.fill = .blurredScreenshot; $0.alignment = .bottom; $0.aspectRatio = .sixteenNine }
        try await phase(3, window: window, dir: dir, note: "")
        NSApp.appearance = nil

        // 4. Export with a gradient background.
        model.updateBackground { $0.fill = .preset("sunset"); $0.alignment = .center; $0.aspectRatio = .auto; $0.autoBalance = false }
        let url = dir.appending(path: "export.png")
        if let image = model.renderImage(), let data = try? ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions.defaults(for: .png, scale: 2)) {
            try data.write(to: url)
        }
        let crop = model.document.crop ?? .null
        try "crop=\(crop.width)x\(crop.height) expected=\(crop.width + 256)x\(crop.height + 256)"
            .write(to: dir.appending(path: "export.txt"), atomically: true, encoding: .utf8)
        try await phase(4, window: window, dir: dir, note: "")

        model.store.markSaved()
        window.close()
    }

    /// Rectangle drag through real events while the background is on: the
    /// annotation must land where the mouse was (inverse output transform).
    private func dragReport(_ controller: EditorWindowController) -> String {
        guard let window = controller.window else { return "no window" }
        let model = controller.model
        let canvas = controller.canvas
        let crop = model.document.crop ?? model.document.canvas.rect
        let a = CGPoint(x: crop.minX + 100, y: crop.minY + 100)
        let b = CGPoint(x: crop.minX + 400, y: crop.minY + 260)
        func windowPoint(_ p: CGPoint) -> CGPoint { canvas.convert(canvas.geometry.viewPoint(fromCanvas: p), to: nil) }
        let before = model.document.annotations.count
        for (type, p) in [(NSEvent.EventType.leftMouseDown, a), (.leftMouseDragged, b), (.leftMouseUp, b)] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            window.sendEvent(event)
        }
        guard model.document.annotations.count == before + 1, let made = model.document.annotations.last else {
            return "drag=FAIL"
        }
        let bounds = made.bounds
        let ok = abs(bounds.midX - (a.x + b.x) / 2) < 8 && abs(bounds.midY - (a.y + b.y) / 2) < 8
        model.undo()
        return "drag=\(ok ? "ok" : "OFF") bounds=\(bounds)"
    }

    private func phase(_ number: Int, window: NSWindow, dir: URL, note: String) async throws {
        try await Task.sleep(for: .milliseconds(700))
        // In-process snapshot too (works while the display sleeps / is locked).
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "snap\(number).png"))
        }
        try note.write(to: dir.appending(path: "note\(number).txt"), atomically: true, encoding: .utf8)
        try "\(number) \(window.windowNumber)\n\(note)\n".write(to: dir.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        let ack = dir.appending(path: "ack-\(number)")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ack.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
