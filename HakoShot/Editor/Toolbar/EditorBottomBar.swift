import AppKit
import HakoKit
import SwiftUI
import UniformTypeIdentifiers

/// Bottom bar (report §9.2): zoom "100% ⌄" left, "Drag Me" center, round
/// quick actions right (Pin when available, Copy, Save).
struct EditorBottomBar: View {
    let model: EditorViewModel
    let onPin: (() -> Void)?
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: Tokens.Spacing.s) {
                ZoomMenu(model: model)
                if !model.isCropping {
                    ImageSizeButton(model: model)
                }
                if let session = model.cropSession {
                    // Report §9.4: "Snap to edges" + hint, bottom-left.
                    Toggle("Snap to edges", isOn: Binding(get: { session.snapping }, set: { model.setCropSnapping($0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Text("Hold ⌘ to toggle snapping")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
                Spacer()
                if let status = model.statusMessage {
                    Text(status)
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                        .transition(.opacity)
                }
                if let onPin {
                    CircleIconButton(systemImage: "pin", accessibilityLabel: "Pin to Screen", style: .light, action: onPin)
                }
                CircleIconButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy (⇧⌘C)", style: .light, action: onCopy)
                CircleIconButton(systemImage: "square.and.arrow.down", accessibilityLabel: "Save (⌘S)", style: .light, action: onSave)
            }
            if !model.isCropping {
                DragMeHandle(model: model)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Tokens.Spacing.l)
        .frame(maxWidth: .infinity, minHeight: EditorMetrics.bottomBarHeight, maxHeight: EditorMetrics.bottomBarHeight)
        .background(Color.editorCanvasBackground)
        .ignoresSafeArea()
        .animation(DSAnimation.hoverControls, value: model.statusMessage)
    }
}

/// "100% ⌄" zoom menu.
struct ZoomMenu: View {
    let model: EditorViewModel

    var body: some View {
        Menu {
            Button("Zoom In  ⌘+") { model.zoomHandler?(.zoomIn) }
            Button("Zoom Out  ⌘−") { model.zoomHandler?(.zoomOut) }
            Button("Actual Size  ⌘0") { model.zoomHandler?(.actualSize) }
            Button("Zoom to Fit  ⌘9") { model.zoomHandler?(.fit) }
            Divider()
            ForEach([0.5, 1, 2] as [CGFloat], id: \.self) { level in
                Button(ZoomMath.label(level)) { model.zoomHandler?(.set(level)) }
            }
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Text(ZoomMath.label(model.zoom))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
            .padding(.horizontal, Tokens.Spacing.m)
            .frame(height: Tokens.Size.pillHeight)
            .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.neutralPillFill)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Zoom")
    }
}

// MARK: - Drag Me

/// The "Drag Me" pill: dragging it drops the rendered PNG into any app
/// (file promise for Finder / Mail, plus PNG data for image-accepting apps).
struct DragMeHandle: NSViewRepresentable {
    let model: EditorViewModel

    func makeNSView(context: Context) -> DragMeView {
        DragMeView(model: model)
    }

    func updateNSView(_ nsView: DragMeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragMeView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct DragMeLabel: View {
    var body: some View {
        HStack(spacing: Tokens.Spacing.pillIconGap + 2) {
            Image(systemName: "line.3.horizontal")
                .imageScale(.small)
            Text("Drag Me")
            Image(systemName: "line.3.horizontal")
                .imageScale(.small)
        }
        .font(Tokens.Typography.pillLabel)
        .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
        .padding(.horizontal, Tokens.Spacing.pillPaddingH)
        .frame(height: Tokens.Size.pillHeight)
        .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.neutralPillFill)))
        .fixedSize()
    }
}

final class DragMeView: NSView, NSDraggingSource {
    private weak var model: EditorViewModel?
    private let label = NSHostingView(rootView: DragMeLabel())
    private var mouseDownEvent: NSEvent?
    /// Thumbnail size of the drag image, in points.
    private static let previewMaxSide: CGFloat = 180

    init(model: EditorViewModel) {
        self.model = model
        super.init(frame: .zero)
        label.sizingOptions = [.intrinsicContentSize]
        addSubview(label)
        toolTip = "Drag the image into another app"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { label.fittingSize }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    /// The whole pill is one drag handle; the SwiftUI label never gets events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        mouseDownEvent = nil
        startDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    private func startDrag(with event: NSEvent) {
        guard let model, let payload = model.dragPayload() else {
            NSSound.beep()
            return
        }
        let provider = EditorFilePromiseProvider(pngData: payload.data, fileName: payload.fileName)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let pixel = CGSize(width: payload.image.width, height: payload.image.height)
        let factor = min(1, Self.previewMaxSide / max(pixel.width, pixel.height, 1))
        let size = CGSize(width: max(pixel.width * factor, 1), height: max(pixel.height * factor, 1))
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            contents: NSImage(cgImage: payload.image, size: size)
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }
}

/// File promise (Finder, Mail) that also offers the PNG bytes directly (Slack,
/// browsers, Notes).
nonisolated final class EditorFilePromiseProvider: NSFilePromiseProvider {
    private let writer: PromiseWriter

    init(pngData: Data, fileName: String) {
        let writer = PromiseWriter(data: pngData, fileName: fileName)
        self.writer = writer
        super.init()
        self.fileType = UTType.png.identifier
        self.delegate = writer
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? writer.data : super.pasteboardPropertyList(forType: type)
    }

    nonisolated final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
        let data: Data
        let fileName: String

        init(data: Data, fileName: String) {
            self.data = data
            self.fileName = fileName
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            fileName
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            do {
                try data.write(to: url, options: .atomic)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
