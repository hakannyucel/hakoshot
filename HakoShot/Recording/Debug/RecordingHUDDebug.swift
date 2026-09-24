#if DEBUG
import AppKit
import HakoKit
import os

/// DEBUG: `hakoshot://debug-recording-hud?x=&y=&width=&height=&snapshot=<png>[&menu=format|microphone|camera|options|ratio]`
/// (plan §7 R1.1). Opens the pre-record HUD standalone in a borderless
/// window as if `width × height` were selected, writes the window content to
/// `snapshot` (works while the display sleeps, like `debug-snapshot-settings`)
/// and closes it. No overlay; the toggles show (and would change) the real settings.
enum RecordingHUDDebug {
    nonisolated struct Parameters: Equatable, Sendable {
        /// Pretend selection, Quartz global points.
        var rect = CGRect(x: 100, y: 100, width: 640, height: 360)
        var snapshot: URL?
        /// Dropdown to open before the snapshot.
        var menu: String?
        /// How long the window stays up (seconds).
        var hold: Double = 0.6

        init(rect: CGRect = CGRect(x: 100, y: 100, width: 640, height: 360), snapshot: URL? = nil, menu: String? = nil, hold: Double = 0.6) {
            self.rect = rect
            self.snapshot = snapshot
            self.menu = menu
            self.hold = hold
        }

        /// Lenient parse: keys `x y width|w height|h snapshot|out menu hold`.
        init(queryItems: [URLQueryItem]) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            func number(_ keys: String...) -> Double? { keys.lazy.compactMap { values[$0].flatMap(Double.init) }.first }
            if let w = number("width", "w"), let h = number("height", "h"), w > 0, h > 0 {
                rect = CGRect(x: number("x") ?? 0, y: number("y") ?? 0, width: w, height: h)
            }
            if let path = values["snapshot"] ?? values["out"], !path.isEmpty {
                snapshot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            menu = values["menu"]?.lowercased()
            hold = number("hold").map { max(0.1, $0) } ?? 0.6
        }
    }

    private static let backdrop = NSColor(white: 0.18, alpha: 1)

    /// What was written: the HUD's size in points and the PNG's in pixels.
    struct Snapshot: Equatable {
        var pointSize: CGSize
        var pixelSize: CGSize
    }

    /// Shows the HUD, snapshots it, closes it. `nil` without `snapshot` or on failure.
    @discardableResult
    static func run(_ parameters: Parameters, settings: AppSettings = .shared) async -> Snapshot? {
        let bar = RecordingOptionsBar(settings: settings)
        bar.model.selectionSize = parameters.rect.size
        bar.model.updateSizeTexts()
        if let menu = parameters.menu {
            switch menu {
            case "format": bar.model.openMenu = .format
            case "microphone", "mic": bar.model.openMenu = .microphone
            case "camera": bar.model.openMenu = .camera
            case "options": bar.model.openMenu = .options
            case "ratio": bar.model.openMenu = .ratio
            default: Log.recordingHUD.error("debug-recording-hud: unknown menu \(menu, privacy: .public)")
            }
        }
        let view = bar.view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = CGRect(origin: .zero, size: size)

        // Under the pretend selection (Quartz → AppKit on the primary display).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
        let origin = CGPoint(
            x: parameters.rect.midX - size.width / 2,
            y: primaryHeight - parameters.rect.maxY - Tokens.Overlay.accessoryGap - size.height
        )
        let window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()
        window.makeFirstResponder(nil) // no focus ring on the width field
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        try? await Task.sleep(for: .seconds(parameters.hold))

        guard let url = parameters.snapshot else {
            Log.recordingHUD.notice("debug-recording-hud shown \(Int(size.width))x\(Int(size.height)) pt (no snapshot)")
            return nil
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = composed(rep)?.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            Log.recordingHUD.notice("debug-recording-hud \(Int(size.width))x\(Int(size.height)) pt, \(rep.pixelsWide)x\(rep.pixelsHigh) px -> \(url.path, privacy: .public)")
            return Snapshot(pointSize: size, pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        } catch {
            Log.recordingHUD.error("debug-recording-hud write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The HUD over a flat dark backdrop so the translucent pills can be judged.
    private static func composed(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let bounds = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        backdrop.setFill()
        bounds.fill()
        rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        return out
    }
}
#endif
