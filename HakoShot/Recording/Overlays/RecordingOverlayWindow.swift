import AppKit
import HakoKit
import QuartzCore

/// Look of the live overlays, read from the Settings keys (plan §4.9,
/// §4.21). The HUD toggles (`RecordingOptions.highlightsClicks` /
/// `showsKeystrokes`) override the two `shows…` flags per recording.
nonisolated struct RecordingOverlayAppearance: Equatable, Sendable {
    var highlightsClicks: Bool
    var clickColor: RGBAColor
    var clickSize: RecordingElementSize
    var clickStyle: ClickHighlightStyle
    var clickAnimated: Bool

    var showsKeystrokes: Bool
    var keystrokePosition: KeystrokeBadgePosition
    var keystrokeSize: RecordingElementSize
    var keystrokeStyle: KeystrokeBadgeStyle
    var keystrokeFilter: KeystrokeFilter

    static let `default` = RecordingOverlayAppearance(
        highlightsClicks: true, clickColor: RGBAColor(hex: "#0A84FF") ?? .black, clickSize: .medium,
        clickStyle: .outline, clickAnimated: true, showsKeystrokes: false, keystrokePosition: .bottomCenter,
        keystrokeSize: .medium, keystrokeStyle: .dark, keystrokeFilter: .shortcutsOnly
    )

    init(highlightsClicks: Bool, clickColor: RGBAColor, clickSize: RecordingElementSize, clickStyle: ClickHighlightStyle,
         clickAnimated: Bool, showsKeystrokes: Bool, keystrokePosition: KeystrokeBadgePosition,
         keystrokeSize: RecordingElementSize, keystrokeStyle: KeystrokeBadgeStyle, keystrokeFilter: KeystrokeFilter) {
        self.highlightsClicks = highlightsClicks
        self.clickColor = clickColor
        self.clickSize = clickSize
        self.clickStyle = clickStyle
        self.clickAnimated = clickAnimated
        self.showsKeystrokes = showsKeystrokes
        self.keystrokePosition = keystrokePosition
        self.keystrokeSize = keystrokeSize
        self.keystrokeStyle = keystrokeStyle
        self.keystrokeFilter = keystrokeFilter
    }

    @MainActor
    init(settings: AppSettings) {
        self.init(
            highlightsClicks: settings.value(for: .recordingHighlightClicks),
            clickColor: RGBAColor(hex: settings.value(for: .recordingClickColor)) ?? Self.default.clickColor,
            clickSize: settings.value(for: .recordingClickSize),
            clickStyle: settings.value(for: .recordingClickStyle),
            clickAnimated: settings.value(for: .recordingClickAnimated),
            showsKeystrokes: settings.value(for: .recordingShowKeystrokes),
            keystrokePosition: settings.value(for: .recordingKeystrokePosition),
            keystrokeSize: settings.value(for: .recordingKeystrokeSize),
            keystrokeStyle: settings.value(for: .recordingKeystrokeStyle),
            keystrokeFilter: settings.value(for: .recordingKeystrokeFilter)
        )
    }

    // MARK: HakoKit models (values from `Tokens.Recording`)

    var clickModel: ClickEffectModel {
        ClickEffectModel(
            style: ClickEffectStyle(rawValue: clickStyle.rawValue) ?? .outline,
            scale: Double(Tokens.Recording.clickScale(clickSize)),
            animated: clickAnimated,
            duration: Tokens.Recording.clickDuration,
            startRadius: Double(Tokens.Recording.clickStartRadius),
            endRadius: Double(Tokens.Recording.clickEndRadius),
            lineWidth: Double(Tokens.Recording.clickLineWidth),
            fillOpacity: Double(Tokens.Recording.clickFillOpacity)
        )
    }

    var badgeMetrics: KeystrokeBadgeMetrics {
        KeystrokeBadgeMetrics(
            height: Double(Tokens.Recording.keystrokeBadgeHeight(keystrokeSize)),
            paddingH: Double(Tokens.Recording.keystrokePaddingH),
            edgeInset: Double(Tokens.Recording.keystrokeBottomInset),
            sideInset: Double(Tokens.Recording.keystrokeBottomInset)
        )
    }

    var badgeTiming: KeystrokeBadgeTiming {
        KeystrokeBadgeTiming(
            fadeIn: Tokens.Recording.keystrokeFadeIn,
            hold: Tokens.Recording.keystrokeHold,
            fadeOut: Tokens.Recording.keystrokeFadeOut,
            pulseScale: Double(Tokens.Recording.keystrokePulseScale)
        )
    }

    var badgePlacement: KeystrokeBadgePlacement {
        KeystrokeBadgePlacement(rawValue: keystrokePosition.rawValue) ?? .bottomCenter
    }

    /// For `KeystrokeFormatter.displayText(…, filter:)`.
    var displayFilter: KeystrokeDisplayFilter {
        KeystrokeDisplayFilter(rawValue: keystrokeFilter.rawValue) ?? .shortcutsOnly
    }

    var badgeFill: NSColor {
        keystrokeStyle == .dark ? Tokens.Recording.keystrokeDarkFill : Tokens.Recording.keystrokeLightFill
    }

    var badgeText: NSColor {
        keystrokeStyle == .dark ? Tokens.Recording.keystrokeDarkText : Tokens.Recording.keystrokeLightText
    }
}

/// Live click rings and keystroke badge while recording (plan §4.9): one
/// borderless, transparent, click-through, non-activating panel covering the
/// recorded display, kept open for the whole session. Unlike our other
/// recording chrome it is meant to be captured: the coordinator puts
/// `windowID` into `RecordingSourceConfiguration.exceptedWindowIDs` (the
/// engine otherwise excludes the whole app), so the panel must be on screen
/// before the engine fetches `SCShareableContent`. `sharingType` stays
/// `.readOnly` (capturable).
///
/// Coordinates: every public API takes Quartz global points (top-left of the
/// main display, y down) — the same space as `NSEvent`-derived Quartz points
/// and `GlobalRect`.
@MainActor
final class RecordingOverlayWindow {
    let displayID: CGDirectDisplayID
    private(set) var appearance: RecordingOverlayAppearance

    private let panel: NSPanel
    /// y-down, display-local points.
    private let container = CALayer()
    private let badge: KeystrokeBadgeLayer
    private var ripples: [ClickRippleLayer] = []
    private var cleanupTask: Task<Void, Never>?
    /// Quartz global bounds of the display.
    private(set) var displayBounds: CGRect

    /// At most this many rings at once (fast clicking).
    static let maxRipples = 12
    /// Above the recording dimmer (`screenSaver − 2`), with the area border,
    /// below the control bar (`screenSaver`) — plan §4.9.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    /// `nil` when `displayID` isn't connected.
    init?(displayID: CGDirectDisplayID, appearance: RecordingOverlayAppearance = RecordingOverlayAppearance(settings: .shared)) {
        guard let screen = Self.screen(for: displayID) else { return nil }
        self.displayID = displayID
        self.appearance = appearance
        self.displayBounds = CGDisplayBounds(displayID)

        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.sharingType = .readOnly
        panel.setFrame(screen.frame, display: false)

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view

        container.isGeometryFlipped = true
        container.frame = view.bounds
        OverlayLayerActions.disable([container])
        view.layer?.addSublayer(container)

        badge = KeystrokeBadgeLayer(
            metrics: appearance.badgeMetrics, placement: appearance.badgePlacement, timing: appearance.badgeTiming,
            fill: appearance.badgeFill, text: appearance.badgeText,
            container: CGRect(origin: .zero, size: screen.frame.size), contentsScale: screen.backingScaleFactor
        )
        container.addSublayer(badge.layer)
    }

    // MARK: Window

    /// The panel (tests, debug snapshots).
    var window: NSWindow { panel }

    /// `CGWindowID` for `exceptedWindowIDs`. Available right after `init`
    /// (the panel is created with `defer: false`); the panel still has to be
    /// shown before the engine fetches `SCShareableContent`.
    var windowID: CGWindowID? { panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
    }

    /// Hides and clears; `show()` brings it back.
    func hide() {
        clear()
        panel.orderOut(nil)
    }

    func close() {
        hide()
        panel.close()
    }

    /// Follows display reconfiguration (resolution / arrangement change).
    func refreshDisplayFrame() {
        guard let screen = Self.screen(for: displayID) else { return }
        displayBounds = CGDisplayBounds(displayID)
        panel.setFrame(screen.frame, display: false)
        container.frame = CGRect(origin: .zero, size: screen.frame.size)
        if badgeRegion == nil { badge.container = container.bounds }
    }

    func update(appearance: RecordingOverlayAppearance) {
        self.appearance = appearance
        badge.update(metrics: appearance.badgeMetrics, placement: appearance.badgePlacement,
                     fill: appearance.badgeFill, text: appearance.badgeText)
    }

    /// Where the badge is placed, Quartz global: the recorded area or window
    /// (plan §4.9: window mode uses the window frame); `nil` = the whole
    /// display. Call again when a followed window moves.
    var badgeRegion: CGRect? {
        didSet {
            badge.container = badgeRegion.map(localRect(_:))?.intersection(container.bounds)
                .nonEmpty ?? container.bounds
        }
    }

    // MARK: Effects

    /// A click ring at `point` (Quartz global). No-op when clicks aren't
    /// highlighted or the point is off this display.
    func showClick(at point: CGPoint, button: RecordingMouseButton, time: CFTimeInterval = CACurrentMediaTime()) {
        guard appearance.highlightsClicks, displayBounds.contains(point) else { return }
        let ripple = ClickRippleLayer(point: localPoint(point), button: button, model: appearance.clickModel,
                                      color: NSColor(rgba: appearance.clickColor), startTime: time)
        container.insertSublayer(ripple.layer, below: badge.layer)
        ripples.append(ripple)
        if ripples.count > Self.maxRipples {
            ripples.removeFirst().layer.removeFromSuperlayer()
        }
        ripple.animate()
        scheduleCleanup()
    }

    /// Shows an already formatted and filtered keystroke ("⇧⌘F"); repeats of
    /// the same text while visible become "⇧⌘F ×2". No-op when keystrokes
    /// are off.
    func showKeystroke(_ text: String, time: CFTimeInterval = CACurrentMediaTime()) {
        guard appearance.showsKeystrokes, !text.isEmpty else { return }
        badge.show(text, at: time)
    }

    /// Removes every ring and the badge immediately (pause, restart, stop).
    func clear() {
        cleanupTask?.cancel()
        cleanupTask = nil
        for ripple in ripples { ripple.layer.removeFromSuperlayer() }
        ripples.removeAll()
        badge.clear()
    }

    /// Rings currently alive (tests).
    var activeRippleCount: Int { ripples.count }

    /// The badge's current label (tests, debug).
    var keystrokeLabel: String? { badge.label }

    // MARK: Snapshot

    /// Freezes every effect `elapsed` seconds after it started (rings from
    /// their click, the badge from its latest press) and renders the panel
    /// content to an sRGB image at the display's backing scale. Live
    /// animations are removed; call `clear()` afterwards. Works off screen
    /// and without Screen Recording permission (only our own layers).
    func snapshot(at elapsed: TimeInterval) -> CGImage? {
        for ripple in ripples { ripple.apply(at: elapsed) }
        if let entry = badge.currentEntry { badge.apply(at: entry.lastTime + elapsed) }
        return render()
    }

    /// Renders the panel's layer tree as it currently is (model values).
    func render() -> CGImage? {
        guard let root = panel.contentView?.layer else { return nil }
        let scale = panel.screen?.backingScaleFactor ?? Self.screen(for: displayID)?.backingScaleFactor ?? 2
        let size = root.bounds.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        root.render(in: context)
        return context.makeImage()
    }

    // MARK: Geometry

    /// Quartz global → y-down display-local points.
    func localPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - displayBounds.minX, y: point.y - displayBounds.minY)
    }

    func localRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    // MARK: Cleanup

    /// Drops finished rings a little after the last one ends.
    private func scheduleCleanup() {
        cleanupTask?.cancel()
        let end = ripples.map(\.endTime).max() ?? CACurrentMediaTime()
        let delay = max(end - CACurrentMediaTime(), 0) + 0.05
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let now = CACurrentMediaTime()
            self.ripples.removeAll { ripple in
                guard ripple.endTime <= now else { return false }
                ripple.layer.removeFromSuperlayer()
                return true
            }
        }
    }
}

private extension CGRect {
    var nonEmpty: CGRect? { isNull || isEmpty ? nil : self }
}
