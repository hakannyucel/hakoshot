import AppKit
import CoreGraphics
import HakoKit
import Testing
@testable import HakoShot

@Suite("Editor shortcuts")
struct EditorShortcutsTests {
    private func key(_ characters: String, keyCode: UInt16 = 0, command: Bool = false, shift: Bool = false) -> EditorKeyInput {
        EditorKeyInput(characters: characters, keyCode: keyCode, command: command, shift: shift)
    }

    @Test func singleLettersSelectTools() {
        let expected: [String: AnnotationTool] = [
            "v": .move, "r": .rectangle, "f": .filledRectangle, "e": .ellipse, "l": .line, "a": .arrow,
            "t": .text, "d": .pencil, "m": .highlighter, "c": .counter, "p": .redaction, "h": .spotlight,
        ]
        for (letter, tool) in expected {
            #expect(EditorShortcuts.canvasKey(for: key(letter)) == .selectTool(tool), "\(letter)")
        }
        // Crop (K) and Background (B) toggle crop mode / the Background panel.
        #expect(EditorShortcuts.canvasKey(for: key("k")) == .selectTool(.crop))
        #expect(EditorShortcuts.canvasKey(for: key("b")) == .selectTool(.background))
        #expect(EditorShortcuts.canvasKey(for: key("x")) == nil)
    }

    @Test func digitsPickSizePresets() {
        #expect(EditorShortcuts.canvasKey(for: key("1")) == .sizePreset(0))
        #expect(EditorShortcuts.canvasKey(for: key("6")) == .sizePreset(5))
        #expect(EditorShortcuts.canvasKey(for: key("7")) == nil)
        #expect(EditorShortcuts.canvasKey(for: key("]")) == .increaseSize)
        #expect(EditorShortcuts.canvasKey(for: key("[")) == .decreaseSize)
    }

    @Test func editingKeys() {
        typealias K = EditorKeyInput.KeyCode
        #expect(EditorShortcuts.canvasKey(for: key("\u{7f}", keyCode: K.delete)) == .deleteSelection)
        #expect(EditorShortcuts.canvasKey(for: key("", keyCode: K.escape)) == .escape)
        #expect(EditorShortcuts.canvasKey(for: key("", keyCode: K.left)) == .nudge(dx: -1, dy: 0))
        #expect(EditorShortcuts.canvasKey(for: key("", keyCode: K.down, shift: true)) == .nudge(dx: 0, dy: 10))
        #expect(EditorShortcuts.canvasKey(for: key("", keyCode: K.returnKey)) == .editSelectedText)
    }

    @Test func commandShortcuts() {
        #expect(EditorShortcuts.commandShortcut(for: key("z", command: true)) == .undo)
        #expect(EditorShortcuts.commandShortcut(for: key("z", command: true, shift: true)) == .redo)
        #expect(EditorShortcuts.commandShortcut(for: key("c", command: true)) == .copy)
        #expect(EditorShortcuts.commandShortcut(for: key("c", command: true, shift: true)) == .copyImage)
        #expect(EditorShortcuts.commandShortcut(for: key("s", command: true)) == .save)
        #expect(EditorShortcuts.commandShortcut(for: key("s", command: true, shift: true)) == .saveAs)
        #expect(EditorShortcuts.commandShortcut(for: key("d", command: true)) == .duplicate)
        #expect(EditorShortcuts.commandShortcut(for: key("a", command: true)) == .selectAll)
        #expect(EditorShortcuts.commandShortcut(for: key("=", command: true)) == .zoomIn)
        #expect(EditorShortcuts.commandShortcut(for: key("-", command: true)) == .zoomOut)
        #expect(EditorShortcuts.commandShortcut(for: key("0", command: true)) == .zoomActualSize)
        #expect(EditorShortcuts.commandShortcut(for: key("9", command: true)) == .zoomToFit)
        // Plain letters are never command shortcuts, ⌘ letters never canvas keys.
        #expect(EditorShortcuts.commandShortcut(for: key("z")) == nil)
        #expect(EditorShortcuts.canvasKey(for: key("r", command: true)) == nil)
    }
}

@Suite("Text auto-grow")
struct TextAutoGrowTests {
    private func shape(_ text: String, width: Double, style: TextStyle = .standard) -> TextShape {
        TextShape(text: text, frame: CGRect(x: 10, y: 10, width: width, height: 10), fontSize: 60, textStyle: style)
    }

    @Test func narrowBoxGrowsToTheWidestWord() {
        let narrow = shape("Supercalifragilistic", width: 40, style: .roundBoxed)
        let frame = TextAutoGrow.fittedFrame(for: narrow, autoWidth: false)
        let font = TextLayout.font(for: .roundBoxed, size: 60)
        #expect(frame.width >= TextAutoGrow.widestWordWidth(narrow.text, font: font))
        var fitted = narrow
        fitted.frame = frame
        let layout = TextLayout(shape: fitted)
        // One line: the word is not broken mid-letters.
        #expect(abs(layout.usedRect.height - layout.lineHeight) < 0.5)
        #expect(abs(frame.height - TextLayout.fittedHeight(for: fitted)) < 0.001)
    }

    @Test func fixedWidthBoxesStillWrapBetweenWords() {
        let text = shape("one two three four five six", width: 200)
        let frame = TextAutoGrow.fittedFrame(for: text, autoWidth: false)
        #expect(frame.width == 200)
        var fitted = text
        fitted.frame = frame
        #expect(TextLayout(shape: fitted).usedRect.height > TextLayout(shape: fitted).lineHeight * 1.5)
    }

    @Test func autoWidthFollowsTheLongestLine() {
        let short = TextAutoGrow.fittedFrame(for: shape("Hi", width: 10), autoWidth: true)
        let long = TextAutoGrow.fittedFrame(for: shape("Hello there", width: 10), autoWidth: true)
        #expect(long.width > short.width)
        let clamped = TextAutoGrow.fittedFrame(for: shape("Hello there, a long line", width: 10), autoWidth: true, maxWidth: 150)
        // Clamped to the canvas edge, but never below the widest word.
        #expect(clamped.width <= max(150, TextAutoGrow.widestWordWidth("Hello there, a long line", font: TextLayout.font(for: .standard, size: 60)) + TextAutoGrow.slack + 1))
        var hugging = shape("Hello", width: 10)
        hugging.frame = TextAutoGrow.fittedFrame(for: hugging, autoWidth: true)
        #expect(TextAutoGrow.isAutoWidth(hugging))
        #expect(!TextAutoGrow.isAutoWidth(shape("Hello", width: 900)))
    }

    @Test func emptyTextKeepsRoomForTheCaret() {
        let frame = TextAutoGrow.fittedFrame(for: shape("", width: 1), autoWidth: true)
        #expect(frame.width >= 30)
        #expect(frame.height > 0)
    }
}

@MainActor
@Suite("Editor view model")
struct EditorViewModelTests {
    private func makeModel() -> EditorViewModel {
        let context = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        guard let image = context?.makeImage() else { fatalError("no test image") }
        return EditorViewModel(image: image, scale: 2, mode: .area)
    }

    private func addRectangle(_ model: EditorViewModel) -> Annotation {
        let rect = Annotation(kind: .rectangle(RectShape(rect: CGRect(x: 10, y: 10, width: 100, height: 50))), style: AnnotationStyle())
        model.perform(.add(rect))
        return rect
    }

    @Test func colorChangeRestylesSelectionInOneUndoStep() {
        let model = makeModel()
        let rect = addRectangle(model)
        let depth = model.store.undoDepth
        model.setColor(.annotationBlue)
        #expect(model.document.annotation(withID: rect.id)?.style.color == .annotationBlue)
        #expect(model.store.toolSettings.color == .annotationBlue)
        #expect(model.store.undoDepth == depth + 1)
        #expect(model.options?.color == .annotationBlue)
        model.undo()
        #expect(model.document.annotation(withID: rect.id)?.style.color == .defaultAnnotation)
    }

    @Test func sizePresetOnTextChangesFontAndRefits() {
        let model = makeModel()
        let text = Annotation(
            kind: .text(TextShape(text: "Hello", frame: CGRect(x: 0, y: 0, width: 50, height: 10), fontSize: 28)),
            style: AnnotationStyle()
        )
        model.perform(.add(text))
        model.setSizePreset(5)
        guard case .text(let shape) = model.document.annotation(withID: text.id)?.kind else {
            Issue.record("text missing")
            return
        }
        #expect(shape.fontSize == TextSizePreset.pixels(at: 5, scale: 2))
        #expect(abs(shape.frame.height - TextLayout.fittedHeight(for: shape)) < 0.001)
        #expect(model.options?.tool == .text)
        #expect(model.options?.sizeIndex == 5)
    }

    @Test func optionsFollowToolOrSelection() {
        let model = makeModel()
        #expect(model.options?.tool == .arrow)
        model.selectTool(.move)
        #expect(model.options == nil)
        _ = addRectangle(model)
        #expect(model.options?.tool == .rectangle)
        #expect(model.options?.isSelection == true)
        model.selectTool(.crop)
        #expect(model.tool == .move) // crop mode doesn't change the drawing tool
        #expect(model.isCropping)
        model.selectTool(.crop)
        #expect(!model.isCropping)
    }

    @Test func copyAndPasteObjectsThroughThePasteboard() {
        let model = makeModel()
        let rect = addRectangle(model)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hakoshot.editor.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(model.copySelectionToPasteboard(pasteboard))
        #expect(model.pasteFromPasteboard(pasteboard))
        #expect(model.document.annotations.count == 2)
        let pasted = model.store.selectedAnnotations.first
        #expect(pasted?.id != rect.id)
        #expect(pasted?.bounds.minX == rect.bounds.minX + EditorMetrics.duplicateOffset * 2)
        model.undo()
        #expect(model.document.annotations.count == 1)
    }

    @Test func dirtyTracksSaves() {
        let model = makeModel()
        #expect(!model.isDirty)
        _ = addRectangle(model)
        #expect(model.isDirty)
        model.store.markSaved()
        model.refreshMirrors()
        #expect(!model.isDirty)
    }
}
