#if DEBUG
import AppKit
import CoreGraphics
import HakoKit
import os

/// DEBUG helpers: open the editor on a generated test image (no screen capture,
/// no permission). Wiring is in the WP4.3 report's "Entegrasyon parçası".
enum EditorDebug {
    /// Launch argument: open the sample editor at launch.
    static let launchArgument = "-HakoEditorDebug"
    /// With `launchArgument`: also add one annotation of each type.
    static let annotatedArgument = "-HakoEditorDebugAnnotated"

    /// With `launchArgument`: also combine a second generated image (WP5.4).
    static let combineArgument = "-HakoEditorDebugCombine"
    /// Environment: folder for `snapshot.png` (window, in-process) and
    /// `export.png` a moment after a debug launch.
    static let snapshotEnvironment = "HAKO_EDITOR_SNAPSHOT_DIR"

    /// Call from `applicationDidFinishLaunching`; does nothing without `launchArgument`.
    static func openFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }
        guard let controller = openSample(annotated: arguments.contains(annotatedArgument)) else { return }
        if arguments.contains(combineArgument) { combineSample(into: controller.model) }
        if let dir = ProcessInfo.processInfo.environment[snapshotEnvironment] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                writeSnapshot(of: controller, to: URL(fileURLWithPath: dir, isDirectory: true))
            }
        }
    }

    /// Combines a generated portrait "phone" image to the right, plus a small
    /// badge dropped onto the content (two undo steps).
    static func combineSample(into model: EditorViewModel) {
        let scale = model.canvasScale
        guard let tall = sampleImage(pointSize: CGSize(width: 420, height: 820), scale: scale),
              let badge = sampleImage(pointSize: CGSize(width: 160, height: 100), scale: scale)
        else { return }
        model.combine([(tall, scale)])
        let visible = model.document.visibleRect
        model.insertImage(badge, scale: scale, centeredAt: CGPoint(x: visible.minX + 300 * scale, y: visible.midY))
        model.store.markSaved()
        model.refreshMirrors()
    }

    /// Window snapshot (works while the display sleeps) + rendered export.
    static func writeSnapshot(of controller: EditorWindowController, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let view = controller.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "snapshot.png"))
        }
        if let image = controller.model.renderImage(),
           let data = try? ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions.defaults(for: .png, scale: controller.model.canvasScale)) {
            try? data.write(to: dir.appending(path: "export.png"))
        }
        let doc = controller.model.document
        let note = "canvas=\(doc.canvas.width)x\(doc.canvas.height) images=\(doc.annotations.filter { $0.kind.tag == .image }.count) undo=\(controller.model.store.undoDepth)"
        try? note.write(to: dir.appending(path: "note.txt"), atomically: true, encoding: .utf8)
        EditorViewModel.log.notice("debug snapshot written: \(note, privacy: .public)")
    }

    /// Opens an editor on a fake app screenshot (1100×680 pt @2x).
    @discardableResult
    static func openSample(annotated: Bool = false) -> EditorWindowController? {
        guard let image = sampleImage(pointSize: CGSize(width: 1100, height: 680), scale: 2) else {
            EditorViewModel.log.error("debug: could not render sample image")
            return nil
        }
        let controller = EditorWindowController.open(image: image, scale: 2)
        if annotated { addSampleAnnotations(to: controller.model) }
        return controller
    }

    /// One annotation of each kind, created through `AnnotationFactory` like a drag would.
    static func addSampleAnnotations(to model: EditorViewModel) {
        let s = Double(model.canvasScale)
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        func drag(_ tool: AnnotationTool, from a: CGPoint, to b: CGPoint, via: [CGPoint] = [], configure: (inout ToolSettings) -> Void = { _ in }) {
            var settings = model.store.toolSettings
            configure(&settings)
            model.perform(.setToolSettings(settings))
            guard var annotation = AnnotationFactory.begin(
                tool: tool, at: a, settings: settings, scale: s, nextCounterNumber: model.store.nextCounterNumber, seed: 7
            ) else { return }
            for point in via + [b] {
                annotation = AnnotationFactory.update(annotation, anchor: a, to: point, constrained: false)
            }
            guard let finished = AnnotationFactory.finish(annotation) else { return }
            model.perform(.add(finished, select: false))
        }

        func text(_ string: String, at origin: CGPoint, style: TextStyle, width: Double? = nil) {
            var settings = model.store.toolSettings
            settings.textStyle = style
            guard var annotation = AnnotationFactory.begin(
                tool: .text, at: origin, settings: settings, scale: s, nextCounterNumber: 1
            ), case .text(var shape) = annotation.kind else { return }
            shape.text = string
            if let width { shape.frame.size.width = width * s }
            shape = model.fitted(shape, autoWidth: width == nil)
            annotation.kind = .text(shape)
            model.perform(.add(annotation, select: false))
        }

        let original = model.store.toolSettings
        drag(.rectangle, from: p(40, 96), to: p(250, 220))
        drag(.filledRectangle, from: p(880, 560), to: p(1040, 620)) { $0.color = .annotationBlue }
        drag(.ellipse, from: p(610, 90), to: p(790, 170)) { $0.color = .annotationOrange }
        drag(.line, from: p(300, 610), to: p(520, 640)) { $0.color = .annotationGreen }
        drag(.arrow, from: p(420, 300), to: p(285, 190)) { $0.color = .annotationPink }
        drag(.arrow, from: p(840, 300), to: p(960, 180)) { $0.arrowStyle = .curved; $0.color = .annotationPurple }
        drag(.arrow, from: p(700, 460), to: p(820, 400)) { $0.arrowStyle = .thick; $0.color = .annotationRed }
        drag(.arrow, from: p(560, 520), to: p(720, 520)) { $0.arrowStyle = .doubleHeaded; $0.color = .black }
        let wave = stride(from: 0.0, through: 180, by: 6).map { p(60 + $0, 560 + 18 * sin($0 / 18)) }
        drag(.pencil, from: wave[0], to: wave[wave.count - 1], via: Array(wave.dropFirst())) { $0.color = .annotationPink }
        drag(.highlighter, from: p(300, 262), to: p(560, 262), via: [p(400, 263), p(480, 262)])
        for (i, point) in [p(300, 240), p(300, 330), p(300, 420)].enumerated() {
            drag(.counter, from: point, to: point) { $0.counterStyle = [.filledCircle, .outlinedCircle, .filledSquare][i] }
        }
        drag(.redaction, from: p(420, 296), to: p(720, 322)) { $0.redactionMethod = .pixelate }
        drag(.redaction, from: p(345, 346), to: p(560, 372)) { $0.redactionMethod = .secureBlur }
        drag(.spotlight, from: p(880, 440), to: p(1080, 530))
        text("Click here", at: p(60, 240), style: .standard)
        text("Boxed label", at: p(60, 300), style: .boxed)
        text("Outlined", at: p(60, 360), style: .outlined)
        text("Supercalifragilistic", at: p(60, 420), style: .roundBoxed, width: 60)
        model.perform(.setToolSettings(original))
        model.store.markSaved()
        model.refreshMirrors()
    }

    /// A light "app window" with a sidebar, headings and text lines, so
    /// redaction and highlighting have something to work on.
    static func sampleImage(pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Draw in points, y-down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(hex: 0xFAFAFC).setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        NSColor(hex: 0xEEF0F4).setFill()
        NSRect(x: 0, y: 0, width: pointSize.width, height: 52).fill()
        NSColor(hex: 0xF2F2F6).setFill()
        NSRect(x: 0, y: 52, width: 250, height: pointSize.height - 52).fill()

        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor(hex: 0x1D1D1F)]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(hex: 0x3A3A3C)]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(hex: 0x6E6E73)]
        ("HakoShot — Editor sample" as NSString).draw(at: NSPoint(x: 20, y: 14), withAttributes: title)
        for (i, item) in ["Inbox", "Drafts", "Sent", "Archive", "Projects", "Screenshots"].enumerated() {
            (item as NSString).draw(at: NSPoint(x: 28, y: 110 + CGFloat(i) * 34), withAttributes: small)
        }
        let lines = [
            "Release notes for version 2.4 — please review before Friday.",
            "Contact: hakan.test@example.com  ·  +90 555 123 45 67",
            "API key: sk-live-8f3a9c2e7b1d4f6a",
            "The quick brown fox jumps over the lazy dog, twice.",
            "Numbers: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16",
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
        ]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 290, y: 250 + CGFloat(i) * 50), withAttributes: body)
        }
        NSColor(hex: 0x0A84FF).setFill()
        NSBezierPath(roundedRect: NSRect(x: 880, y: 460, width: 180, height: 44), xRadius: 10, yRadius: 10).fill()
        ("Get Started" as NSString).draw(
            at: NSPoint(x: 925, y: 472),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
        )
        return context.makeImage()
    }
}
#endif
