import AppKit
import HakoKit
import os

/// Settings > Screenshots > Fullscreen display (plan §4.7, §5.3).
nonisolated enum FullscreenDisplayPreference: String, Sendable, CaseIterable {
    /// The display under the mouse cursor (default, plan §5.4).
    case active
    /// Every display, one file each.
    case all
}

extension SettingsKey where Value == FullscreenDisplayPreference {
    static var screenshotFullscreenDisplay: SettingsKey<FullscreenDisplayPreference> {
        SettingsKey("screenshotFullscreenDisplay", default: .active)
    }
}

extension SettingsKey where Value == String {
    /// Last area rect for Capture Previous Area, `"x,y,width,height"` in
    /// Quartz global points; empty when nothing was captured yet.
    static var capturePreviousAreaRect: SettingsKey<String> {
        SettingsKey("capturePreviousAreaRect", default: "")
    }
}

/// Runs the capture flows (plan §3.3): area, window, fullscreen, previous
/// area, Capture Text (OCR/QR), Self-Timer and All-In-One.
/// Owned by `AppCoordinator`; one capture at a time.
final class CaptureFlowController {
    /// Called when a capture fails because Screen Recording isn't granted.
    var onPermissionDenied: () -> Void = {}

    private let settings: AppSettings
    private let overlay = SelectionOverlayController()
    private let selfTimer = SelfTimerController()
    private let router: PostCaptureRouter
    private var isBusy = false
    /// The running scrolling capture (for DEBUG automation's Done).
    private(set) var scrollingFlow: ScrollingCaptureFlow?

    /// Asks for event posting (auto-scroll) lazily; set by `AppCoordinator`.
    var permissions: PermissionsService?

    #if DEBUG
    /// DEBUG automation (`CaptureFlowDebug`): run URL/launch-arg rects through
    /// the overlay instead of skipping it, force freeze, and finish the
    /// overlay by itself.
    var debugShowsPresetInOverlay = false
    var debugForcesFreeze = false
    var debugAutoFinish: ((SelectionOverlayController, AllInOneBar?) -> Void)?
    #endif

    init(settings: AppSettings = .shared) {
        self.settings = settings
        router = PostCaptureRouter(settings: settings)
    }

    /// Where finished captures go (Quick Access, history, pin, editor); set by `AppCoordinator`.
    var postCaptureDestinations: PostCaptureDestinations {
        get { router.destinations }
        set { router.destinations = newValue }
    }

    /// Handles one `.capture` command. Returns immediately (logged) when
    /// another capture is still running, e.g. the hotkey pressed again while
    /// the overlay is open.
    func capture(_ mode: CaptureMode, options: CaptureOptions) async {
        await run(String(describing: mode)) {
            switch mode {
            case .area:
                try await captureArea(options)
            case .window:
                try await captureWindowFlow(options)
            case .previousArea:
                if let rect = previousArea {
                    try await captureRect(rect, mode: .previousArea, options: options)
                } else {
                    Log.coordinator.notice("no previous area yet; falling back to area selection")
                    try await captureArea(options)
                }
            case .fullscreen(let target):
                try await captureFullscreen(target, options: options)
            case .text:
                try await captureAndRecognizeText(lineBreaks: true, rect: options.rect)
            case .selfTimer:
                try await captureSelfTimer(options)
            case .allInOne:
                try await captureAllInOne(options)
            case .scrolling:
                await captureScrolling(
                    presetSkipsOverlay(options.rect),
                    options: options
                )
            }
        }
    }

    /// Capture Text (plan §4.13): area selection → OCR/QR → clipboard as
    /// plain text. No Quick Access, history, file or shutter sound.
    /// `rect` (Quartz global points, from the URL scheme) skips the overlay.
    func captureText(lineBreaks: Bool, rect: CGRect?) async {
        await run("text") {
            try await self.captureAndRecognizeText(lineBreaks: lineBreaks, rect: rect)
        }
    }

    /// ⇧⌘I "Add New Screenshot" in the editor: area selection (`Space` →
    /// window) → capture, handed back to the caller. No Quick Access, history,
    /// file or clipboard; `nil` when cancelled or failed.
    func captureForCombine() async -> CaptureResult? {
        var result: CaptureResult?
        await run("combine") {
            switch await runOverlay(overlayConfig(.area)) {
            case .area(let rect, _):
                result = try await ScreenCaptureService.shared.captureRect(rect, showsCursor: showsCursor, mode: .area)
            case .frozenArea(let rect, _, let snapshot):
                result = snapshot.captureResult(for: rect, mode: .area)
            case .window(let id):
                var windowOptions = settings.windowCaptureOptions
                windowOptions.showsCursor = showsCursor
                result = try await ScreenCaptureService.shared.captureWindow(id, options: windowOptions)
            case .fullscreen(let displayID):
                result = try await ScreenCaptureService.shared.captureDisplay(
                    displayID, showsCursor: showsCursor, mode: .fullscreen(.activeDisplay),
                    topInsetToCrop: NotchCropper.topInsetToCrop(for: displayID, settings: settings)
                )
            case .cancelled:
                break
            }
            if result != nil { ShutterSound.play() }
        }
        return result
    }

    /// One capture at a time, Screen Recording checked, errors logged.
    private func run(_ label: String, _ body: () async throws -> Void) async {
        guard !isBusy else {
            Log.coordinator.notice("capture \(label, privacy: .public) ignored: another capture is running")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            Log.coordinator.error("capture needs Screen Recording permission")
            onPermissionDenied()
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            await prepareCaptureOptions()
            try await body()
        } catch CaptureError.permissionDenied {
            Log.coordinator.error("capture failed: permission denied")
            onPermissionDenied()
        } catch {
            Log.coordinator.error("capture failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Overlay

    /// The overlay config with the user's magnifier / crosshair / freeze settings.
    private func overlayConfig(_ mode: OverlayConfig.Mode, initialRect: GlobalRect? = nil, editable: Bool = false) -> OverlayConfig {
        var config = OverlayConfig(mode: mode, initialRect: initialRect, editable: editable).applyingUserSettings(settings)
        #if DEBUG
        if debugForcesFreeze { config.freeze = true }
        #endif
        return config
    }

    /// Runs one overlay session. With freeze on, the snapshots are taken now
    /// (hotkey time), so an open menu is still on them (plan §4.2).
    private func runOverlay(_ config: OverlayConfig, accessory: AllInOneBar? = nil) async -> SelectionOutcome {
        var snapshots: [FrozenSnapshot]?
        if config.freeze {
            do {
                snapshots = try await ScreenCaptureService.shared.snapshotAllDisplays()
            } catch {
                Log.coordinator.error("freeze snapshot failed: \(String(describing: error), privacy: .public); overlay takes its own")
            }
        }
        // Refresh window/app lists while the user selects.
        let refresh = Task { await ScreenCaptureService.shared.refreshShareableContent() }
        #if DEBUG
        if let debugAutoFinish {
            let overlay = overlay
            Task {
                while !overlay.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
                debugAutoFinish(overlay, accessory)
            }
        }
        #endif
        let outcome = await overlay.run(config, snapshots: snapshots, accessory: accessory)
        await refresh.value
        Log.coordinator.notice("overlay \(String(describing: config.mode), privacy: .public) -> \(Self.describe(outcome), privacy: .public)")
        return outcome
    }

    /// `preset` → rect from a URL command; shown in the overlay only in DEBUG automation.
    private func presetSkipsOverlay(_ preset: CGRect?) -> GlobalRect? {
        guard let preset else { return nil }
        #if DEBUG
        if debugShowsPresetInOverlay { return nil }
        #endif
        return GlobalRect(origin: preset.origin, size: preset.size)
    }

    private func delivered(_ outcome: SelectionOutcome, areaMode: CaptureMode, options: CaptureOptions) async throws {
        switch outcome {
        case .area(let rect, _):
            // `run` returns after the panels are ordered out; our own windows are
            // also excluded from every capture, so the overlay can't show up.
            try await captureRect(rect, mode: areaMode, options: options)
        case .frozenArea(let rect, _, let snapshot):
            guard let result = snapshot.captureResult(for: rect, mode: areaMode) else {
                Log.coordinator.error("frozen area outside its snapshot; nothing captured")
                NSSound.beep()
                return
            }
            Log.coordinator.notice("frozen area: cropped \(result.image.width)x\(result.image.height) px from the snapshot")
            previousArea = rect
            deliver([result], options: options)
        case .window(let id):
            try await captureWindow(id, options: options)
        case .fullscreen(let displayID):
            try await captureDisplays([displayID], target: .activeDisplay, options: options)
        case .cancelled:
            Log.coordinator.notice("selection cancelled")
        }
    }

    // MARK: Flows

    private func captureArea(_ options: CaptureOptions) async throws {
        if let rect = presetSkipsOverlay(options.rect) {
            try await captureRect(rect, mode: .area, options: options)
            return
        }
        let initial = options.rect.map { GlobalRect(origin: $0.origin, size: $0.size) }
        let outcome = await runOverlay(overlayConfig(.area, initialRect: initial))
        try await delivered(outcome, areaMode: .area, options: options)
    }

    /// ⇧⌘5 (plan §4.4): hover-highlight + click a window; `Space` switches to
    /// area. With freeze on, a window is still captured live.
    private func captureWindowFlow(_ options: CaptureOptions) async throws {
        let outcome = await runOverlay(overlayConfig(.window))
        try await delivered(outcome, areaMode: .area, options: options)
    }

    private func captureWindow(_ id: CGWindowID, options: CaptureOptions) async throws {
        var windowOptions = settings.windowCaptureOptions
        windowOptions.showsCursor = showsCursor
        let result = try await ScreenCaptureService.shared.captureWindow(id, options: windowOptions)
        deliver([result], options: options)
    }

    private func captureRect(_ rect: GlobalRect, mode: CaptureMode, options: CaptureOptions) async throws {
        let result = try await ScreenCaptureService.shared.captureRect(rect, showsCursor: showsCursor, mode: mode)
        previousArea = rect
        deliver([result], options: options)
    }

    private func captureAndRecognizeText(lineBreaks: Bool, rect preset: CGRect?) async throws {
        if let rect = presetSkipsOverlay(preset) {
            try await recognizeText(in: rect, lineBreaks: lineBreaks)
            return
        }
        let initial = preset.map { GlobalRect(origin: $0.origin, size: $0.size) }
        let outcome = await runOverlay(overlayConfig(.text, initialRect: initial))
        switch outcome {
        case .area(let rect, _):
            try await recognizeText(in: rect, lineBreaks: lineBreaks)
        case .frozenArea(let rect, _, let snapshot):
            guard let result = snapshot.captureResult(for: rect, mode: .text) else { return }
            await TextCaptureFlow.handle(result, lineBreaks: lineBreaks)
        case .window, .fullscreen, .cancelled:
            break
        }
    }

    private func recognizeText(in rect: GlobalRect, lineBreaks: Bool) async throws {
        // Never draw the cursor into an OCR source.
        let result = try await ScreenCaptureService.shared.captureRect(rect, showsCursor: false, mode: .text)
        await TextCaptureFlow.handle(result, lineBreaks: lineBreaks)
    }

    private func captureFullscreen(_ target: FullscreenTarget, options: CaptureOptions) async throws {
        let displayIDs: [CGDirectDisplayID]
        switch resolved(target) {
        case .allDisplays:
            displayIDs = NSScreen.screens.compactMap(DisplayLayoutProvider.displayID(of:))
        case .activeDisplay, .preferred:
            displayIDs = [DisplayLayoutProvider.displayUnderMouse() ?? CGMainDisplayID()]
        }
        try await captureDisplays(displayIDs, target: target, options: options)
    }

    private func captureDisplays(_ displayIDs: [CGDirectDisplayID], target: FullscreenTarget, options: CaptureOptions) async throws {
        var results: [CaptureResult] = []
        for displayID in displayIDs {
            results.append(
                try await ScreenCaptureService.shared.captureDisplay(
                    displayID, showsCursor: showsCursor, mode: .fullscreen(target),
                    topInsetToCrop: NotchCropper.topInsetToCrop(for: displayID, settings: settings)
                )
            )
        }
        deliver(results, options: options)
    }

    // MARK: Self-Timer (plan §4.14)

    /// ⇧⌘8: select an area (or `Space` → a window), count down, capture it live.
    /// Freeze is ignored: the point of the timer is to capture what changes.
    private func captureSelfTimer(_ options: CaptureOptions) async throws {
        if let rect = presetSkipsOverlay(options.rect) {
            try await timedCapture(rect, options: options)
            return
        }
        var config = overlayConfig(.area, initialRect: options.rect.map { GlobalRect(origin: $0.origin, size: $0.size) })
        config.freeze = false
        switch await runOverlay(config) {
        case .area(let rect, _), .frozenArea(let rect, _, _):
            try await timedCapture(rect, options: options)
        case .window(let id):
            try await timedWindowCapture(id, options: options)
        case .fullscreen, .cancelled:
            break
        }
    }

    private func timedCapture(_ rect: GlobalRect, options: CaptureOptions) async throws {
        guard await selfTimer.countdown(seconds: SelfTimerSettings.interval(settings), around: rect) else { return }
        try await captureRect(rect, mode: .selfTimer, options: options)
    }

    private func timedWindowCapture(_ id: CGWindowID, options: CaptureOptions) async throws {
        let frame = WindowLocator.snapshot().windows.first { $0.id == id }?.frame
            ?? OverlayScreens.current()?.displays.first?.globalFrame
        guard let frame else { return }
        guard await selfTimer.countdown(seconds: SelfTimerSettings.interval(settings), around: frame) else { return }
        try await captureWindow(id, options: options)
    }

    // MARK: Scrolling (plan §4.8, M6)

    /// ⇧⌘7: pick an area (unless `rect` is given), run the scrolling session,
    /// route the stitched image like any capture (Quick Access, history `.scrolling`).
    private func captureScrolling(_ rect: GlobalRect?, options: CaptureOptions) async {
        let flow = ScrollingCaptureFlow(settings: settings, permissions: permissions, overlay: overlay)
        scrollingFlow = flow
        defer { scrollingFlow = nil }
        guard let result = await flow.run(rect: rect, autoScroll: options.autoScroll, start: options.start) else {
            Log.coordinator.notice("scrolling capture ended without a result")
            return
        }
        deliver([result], options: options)
    }

    #if DEBUG
    /// A 480 × 2400 pt `.scrolling` sample through the same `deliver` path.
    func debugDeliverScrollingSample(_ options: CaptureOptions) {
        guard var result = QuickAccessDebug.sampleResult(pointSize: CGSize(width: 480, height: 2400)) else { return }
        result.mode = .scrolling
        deliver([result], options: options)
    }
    #endif

    // MARK: All-In-One (plan §4.14)

    /// ⇧⌘1: editable selection + HUD bar. Starts with the URL rect, else the
    /// remembered selection; the bar's mode decides what the outcome means.
    private func captureAllInOne(_ options: CaptureOptions) async throws {
        let initial = options.rect.map { GlobalRect(origin: $0.origin, size: $0.size) }
            ?? AllInOneSettings.rememberedSelection(settings)
        let bar = AllInOneBar()
        let outcome = await runOverlay(overlayConfig(.allInOne, initialRect: initial, editable: true), accessory: bar)
        if case .cancelled = outcome {} else if let selection = bar.finalSelection {
            AllInOneSettings.remember(selection, settings)
        }
        switch (bar.chosenMode, outcome) {
        case (.timer, .area(let rect, _)), (.timer, .frozenArea(let rect, _, _)):
            try await timedCapture(rect, options: options)
        case (.text, .area(let rect, _)):
            try await recognizeText(in: rect, lineBreaks: true)
        case (.text, .frozenArea(let rect, _, let snapshot)):
            guard let result = snapshot.captureResult(for: rect, mode: .text) else { return }
            await TextCaptureFlow.handle(result, lineBreaks: true)
        case (.scrolling, .area(let rect, _)), (.scrolling, .frozenArea(let rect, _, _)):
            // Scrolling always captures live frames, frozen selection or not.
            await captureScrolling(rect, options: options)
        default:
            try await delivered(outcome, areaMode: .area, options: options)
        }
    }

    static func describe(_ outcome: SelectionOutcome) -> String {
        switch outcome {
        case .area(let rect, let displayID):
            "area \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) display \(displayID)"
        case .frozenArea(let rect, let displayID, _):
            "frozenArea \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) display \(displayID)"
        case .window(let id):
            "window \(id)"
        case .fullscreen(let displayID):
            "fullscreen display \(displayID)"
        case .cancelled:
            "cancelled"
        }
    }

    // MARK: Capture options (plan §4.5, §5.3)

    private var showsCursor: Bool { settings.value(for: .captureCursor) }

    /// Desktop icons are filtered out when the setting is on, or while the
    /// "Hide Desktop Icons" covers are shown: the covers are our own windows
    /// and so excluded from captures, which would reveal the icons again.
    private func prepareCaptureOptions() async {
        let hidesIcons = settings.value(for: .hideDesktopIconsWhileCapturing) || DesktopIconsToggle.shared.isHidden
        await ScreenCaptureService.shared.setHidesDesktopIcons(hidesIcons)
    }

    private func resolved(_ target: FullscreenTarget) -> FullscreenTarget {
        guard target == .preferred else { return target }
        switch settings.value(for: .screenshotFullscreenDisplay) {
        case .active: return .activeDisplay
        case .all: return .allDisplays
        }
    }

    // MARK: Output

    private func deliver(_ results: [CaptureResult], options: CaptureOptions) {
        guard !results.isEmpty else { return }
        ShutterSound.play()
        for result in results {
            do {
                let outcome = try router.route(result, overriding: options.action)
                Log.postCapture.notice(
                    "\(result.image.width)x\(result.image.height) px @\(result.scale)x saved=\(outcome.savedURL?.lastPathComponent ?? "no", privacy: .public) copied=\(outcome.copiedToClipboard) quickAccess=\(outcome.quickAccessCardID?.uuidString ?? "no", privacy: .public) history=\(outcome.historyID?.uuidString ?? "no", privacy: .public) pinned=\(outcome.pinned)"
                )
            } catch {
                Log.postCapture.error("route failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
            }
        }
    }

    // MARK: Previous area

    private var previousArea: GlobalRect? {
        get {
            let parts = settings.value(for: .capturePreviousAreaRect)
                .split(separator: ",")
                .compactMap { Double($0) }
            guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
            return GlobalRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        set {
            let text = newValue.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? ""
            settings.set(text, for: .capturePreviousAreaRect)
        }
    }
}
