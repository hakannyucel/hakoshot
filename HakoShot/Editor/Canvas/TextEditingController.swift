import AppKit
import HakoKit

/// Inline text editing (plan §4.11): an `NSTextView` overlay on the canvas at
/// the annotation's frame, with the same font and line height. The model is
/// updated on every keystroke inside one store interaction, so the canvas
/// renders the real styled text (boxed, outlined …) while the overlay's glyphs
/// are transparent and only contribute the caret and selection. Ending the
/// edit commits one undo step; an empty box is removed.
final class TextEditingController: NSObject, NSTextViewDelegate {
    let annotationID: Annotation.ID
    let isNew: Bool
    let textView: EditorTextView
    private let model: EditorViewModel
    private weak var canvas: CanvasView?
    /// Auto-width boxes grow with their longest line; fixed boxes only grow to fit
    /// the widest word (no mid-word breaks).
    private var autoWidth: Bool
    /// Typing undo lives here, separate from the editor's bridged undo manager.
    private let typingUndoManager = UndoManager()
    private(set) var isActive = false

    init?(annotationID: Annotation.ID, isNew: Bool, canvas: CanvasView, model: EditorViewModel) {
        guard let annotation = model.document.annotation(withID: annotationID),
              case .text(let shape) = annotation.kind
        else { return nil }
        self.annotationID = annotationID
        self.isNew = isNew
        self.canvas = canvas
        self.model = model
        self.autoWidth = isNew || TextAutoGrow.isAutoWidth(shape)
        self.textView = EditorTextView(frame: .zero)
        super.init()
    }

    var shape: TextShape? {
        guard case .text(let shape) = model.document.annotation(withID: annotationID)?.kind else { return nil }
        return shape
    }

    func begin() {
        guard let canvas, let annotation = model.document.annotation(withID: annotationID),
              case .text(let shape) = annotation.kind
        else { return }
        isActive = true
        if !isNew { model.beginInteraction("Edit Text") }
        if model.selection != [annotationID] { model.perform(.select([annotationID])) }

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.usesFontLeading = true
        applyStyle(shape, style: annotation.style)
        textView.string = shape.text
        textView.setSelectedRange(NSRange(location: (shape.text as NSString).length, length: 0))
        layout(shape)
        canvas.addSubview(textView)
        canvas.window?.makeFirstResponder(textView)
    }

    /// Mirrors font, alignment, line height and caret color of `shape`.
    func applyStyle(_ shape: TextShape, style: AnnotationStyle) {
        let scale = max(model.canvasScale, 0.0001)
        let pointSize = shape.fontSize / scale
        let font = unsafeBitCast(TextLayout.font(for: shape.textStyle, size: pointSize), to: NSFont.self)
        let lineHeight = TextLayout(shape: shape).lineHeight / scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch shape.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let upright = isUpright
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // Rotated / flipped canvas: the rendered text is turned, so the
            // overlay shows its own upright glyphs on an opaque box instead.
            .foregroundColor: upright ? NSColor.black : NSColor.clear,
            .paragraphStyle: paragraph,
        ]
        textView.drawsBackground = upright
        textView.backgroundColor = .white
        textView.wantsLayer = true
        textView.layer?.borderWidth = upright ? Tokens.Stroke.hairline : 0
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.typingAttributes = attributes
        textView.defaultParagraphStyle = paragraph
        textView.font = font
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        let caret = shape.textStyle.isBoxed ? style.color.contrastingColor : style.color
        textView.insertionPointColor = upright ? .black : NSColor(
            srgbRed: caret.red, green: caret.green, blue: caret.blue, alpha: 1
        )
        textView.selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.28)]
    }

    /// The canvas is rotated / flipped: edit in an upright box centered on the
    /// (turned) text rather than an overlay that would not line up with it.
    var isUpright: Bool { !model.document.transform.isIdentity }

    private func layout(_ shape: TextShape) {
        guard let canvas else { return }
        let rect = Self.editorRect(for: shape.frame, geometry: canvas.geometry, upright: isUpright)
        textView.frame = rect
        textView.textContainer?.containerSize = NSSize(width: rect.width, height: .greatestFiniteMagnitude)
    }

    /// Overlay frame in view points: the text frame mapped to the view, or,
    /// when `upright`, a box of the unrotated size centered on it (pure, tested).
    nonisolated static func editorRect(for frame: CGRect, geometry: CanvasGeometry, upright: Bool) -> CGRect {
        let mapped = geometry.viewRect(fromCanvas: frame)
        guard upright else { return mapped }
        let size = CGSize(width: frame.width / geometry.scale, height: frame.height / geometry.scale)
        return CGRect(x: mapped.midX - size.width / 2, y: mapped.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Called when the annotation changed from outside (toolbar restyle while editing).
    func annotationDidChange() {
        guard isActive, let annotation = model.document.annotation(withID: annotationID),
              case .text(let shape) = annotation.kind
        else { return }
        applyStyle(shape, style: annotation.style)
        layout(shape)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard isActive, let annotation = model.document.annotation(withID: annotationID),
              case .text(var shape) = annotation.kind
        else { return }
        shape.text = textView.string
        shape = model.fitted(shape, autoWidth: autoWidth)
        model.perform(.update(model.withText(annotation, shape: shape)))
        layout(shape)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            end()
            return true
        }
        return false
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        typingUndoManager
    }

    // MARK: End

    /// Commits the edit (one undo step) or removes an empty box.
    func end() {
        guard isActive else { return }
        isActive = false
        let wasFirstResponder = textView.window?.firstResponder === textView
        textView.delegate = nil
        textView.removeFromSuperview()
        let text = shape?.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isNew {
                model.cancelInteraction()
            } else {
                model.perform(.delete([annotationID]))
                model.endInteraction()
            }
        } else {
            model.endInteraction()
        }
        if wasFirstResponder, let canvas { canvas.window?.makeFirstResponder(canvas) }
        canvas?.textEditingDidEnd(self)
    }
}

/// The overlay text view. Draws no background and keeps the canvas cursor
/// logic out of its way.
final class EditorTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
