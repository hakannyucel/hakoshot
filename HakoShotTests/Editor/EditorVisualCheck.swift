import AppKit
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Manual visual QA driver: only runs with `HAKO_EDITOR_VISUAL_DIR` set
/// (`TEST_RUNNER_HAKO_EDITOR_VISUAL_DIR=… xcodebuild test -only-testing:…`).
/// Opens the sample editor and steps through states; for each it writes
/// `state.txt` ("<phase> <windowNumber>") and waits for `ack-<phase>` so a
/// script can `screencapture -l` the window.
@MainActor
@Suite struct EditorVisualCheck {
    nonisolated static var directory: URL? {
        ProcessInfo.processInfo.environment["HAKO_EDITOR_VISUAL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @Test(.enabled(if: directory != nil))
    func stepThroughEditorStates() async throws {
        let dir = try #require(Self.directory)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let controller = try #require(EditorDebug.openSample(annotated: true))
        let model = controller.model
        let window = try #require(controller.window)

        let clickReport = interactionReport(controller)

        // 1. Move tool, curved arrow selected (handles + pink control point).
        model.perform(.setTool(.move))
        if let arrow = model.document.annotations.first(where: {
            if case .arrow(let s) = $0.kind { return s.arrowStyle == .curved }
            return false
        }) {
            model.perform(.select([arrow.id]))
        }
        try await phase(1, window: window, dir: dir, note: clickReport + "\n" + hitTestReport(window) + " frame=\(window.frame) content=\(window.contentView?.frame ?? .zero) min=\(window.minSize) fitting=\(window.contentView?.fittingSize ?? .zero)")

        // 2. Editing the narrow round-boxed text (long word must not break mid-word).
        model.perform(.setTool(.text))
        if let text = model.document.annotations.last(where: { $0.kind.tag == .text }) {
            controller.canvas.beginTextEditing(text.id, isNew: false)
        }
        var typing = "typing: no editor"
        if let editor = controller.canvas.textEditor {
            let depth = model.store.undoDepth
            editor.textView.insertText(" wow", replacementRange: NSRange(location: NSNotFound, length: 0))
            if case .text(let shape) = model.document.annotation(withID: editor.annotationID)?.kind {
                typing = "typing: text=\(shape.text) width=\(Int(shape.frame.width))"
            }
            try await phase(2, window: window, dir: dir, note: typing)
            model.commitTextEditing?()
            typing += " steps=\(model.store.undoDepth - depth) editing=\(controller.canvas.isEditingText)"
            try typing.write(to: dir.appending(path: "typing.txt"), atomically: true, encoding: .utf8)
        }

        // 3. Rectangle selected with rectangle tool options; dark mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.perform(.setTool(.rectangle))
        if let rect = model.document.annotations.first(where: { $0.kind.tag == .rectangle }) {
            model.perform(.select([rect.id]))
        }
        try await phase(3, window: window, dir: dir, note: "")
        NSApp.appearance = nil

        // 4. 200 % zoom, counter tool.
        model.perform(.clearSelection)
        model.selectTool(.counter)
        controller.applyZoom(.set(2))
        try await phase(4, window: window, dir: dir, note: "zoom \(model.zoom)")

        // 5. Light mode, Done button click (saves to a temp file, closes).
        NSApp.appearance = NSAppearance(named: .aqua)
        controller.applyZoom(.fit)
        model.selectTool(.arrow)
        try await phase(5, window: window, dir: dir, note: "")
        NSApp.appearance = nil
        let target = dir.appending(path: "done.png")
        model.saveTarget = target
        click(window, at: CGPoint(x: window.frame.width - EditorMetrics.toolbarTrailingInset - 36, y: window.frame.height - 26))
        try await Task.sleep(for: .milliseconds(300))
        let doneNote = "done: saved=\(FileManager.default.fileExists(atPath: target.path)) visible=\(window.isVisible)"
        try doneNote.write(to: dir.appending(path: "done.txt"), atomically: true, encoding: .utf8)
        if window.isVisible {
            model.store.markSaved()
            window.close()
        }
    }

    // MARK: Synthesized input

    private func mouse(_ type: NSEvent.EventType, _ window: NSWindow, at point: CGPoint, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        window.sendEvent(event)
    }

    private func click(_ window: NSWindow, at point: CGPoint) {
        mouse(.leftMouseDown, window, at: point)
        mouse(.leftMouseUp, window, at: point)
    }

    /// Clicks toolbar tools and drags on the canvas through real event dispatch.
    private func interactionReport(_ controller: EditorWindowController) -> String {
        guard let window = controller.window else { return "no window" }
        let model = controller.model
        var results: [String] = []
        let top = window.frame.height - 26
        // Tool centers: leading inset + capsule (2 × 30 + 4) + spacing/divider/spacing.
        let firstTool = EditorMetrics.toolbarLeadingInset + 64 + 21 + EditorMetrics.toolButtonSize / 2
        for (index, descriptor) in EditorToolDescriptor.drawingTools.enumerated() {
            let x = firstTool + CGFloat(index) * (EditorMetrics.toolButtonSize + EditorMetrics.toolbarItemSpacing)
            click(window, at: CGPoint(x: x, y: top))
            if model.tool != descriptor.tool { results.append("tool[\(index)] got \(model.tool)") }
        }
        results.append(results.isEmpty ? "toolClicks=ok" : "toolClicks=FAIL")
        // Rectangle drag on the canvas creates one annotation, one undo step.
        model.selectTool(.rectangle)
        let before = model.document.annotations.count
        let canvas = controller.canvas
        func windowPoint(_ canvasPixel: CGPoint) -> CGPoint {
            canvas.convert(canvas.geometry.viewPoint(fromCanvas: canvasPixel), to: nil)
        }
        let a = windowPoint(CGPoint(x: 1200, y: 1250))
        let b = windowPoint(CGPoint(x: 1500, y: 1330))
        mouse(.leftMouseDown, window, at: a)
        mouse(.leftMouseDragged, window, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        mouse(.leftMouseDragged, window, at: b)
        mouse(.leftMouseUp, window, at: b)
        let created = model.document.annotations.count == before + 1
        results.append("dragCreate=\(created) undo=\(model.store.undoActionName ?? "-")")
        if created {
            model.undo()
            results.append("undoRemoves=\(model.document.annotations.count == before)")
            model.redo()
            // Move tool: click the new rectangle's edge selects it; ⌫ deletes.
            model.selectTool(.move)
            click(window, at: windowPoint(CGPoint(x: 1200, y: 1290)))
            results.append("clickSelects=\(model.selection.count == 1)")
            model.deleteSelection()
            results.append("deleteOK=\(model.document.annotations.count == before)")
        }
        return results.joined(separator: " ")
    }

    private func phase(_ number: Int, window: NSWindow, dir: URL, note: String) async throws {
        try await Task.sleep(for: .milliseconds(600))
        let line = "\(number) \(window.windowNumber)\n\(note)\n"
        try line.write(to: dir.appending(path: "state.txt"), atomically: true, encoding: .utf8)
        let ack = dir.appending(path: "ack-\(number)")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ack.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Which view gets clicks in the toolbar (must not be the titlebar).
    private func hitTestReport(_ window: NSWindow) -> String {
        guard let frameView = window.contentView?.superview else { return "no frame view" }
        let height = window.frame.height
        let points: [(String, CGPoint)] = [
            ("traffic", CGPoint(x: 26, y: height - 26)),
            ("tool", CGPoint(x: 330, y: height - 26)),
            ("spacer", CGPoint(x: window.frame.width - 260, y: height - 26)),
            ("done", CGPoint(x: window.frame.width - 50, y: height - 26)),
        ]
        return points.map { name, point in
            "\(name)=\(frameView.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil")"
        }.joined(separator: " ")
    }
}
