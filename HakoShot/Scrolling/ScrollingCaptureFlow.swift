import AppKit
import HakoKit
import os

/// Scrolling Capture end to end (plan §4.8, M6): pick the area (editable
/// overlay) unless a rect is given, show the scrolling UI, run a
/// ``ScrollingCaptureSession`` until Done / Cancel / end of content / length
/// limit, and return the stitched result. Routing it (Quick Access, history…)
/// is the caller's job.
///
/// ```swift
/// if let result = await ScrollingCaptureFlow.run(rect: nil, autoScroll: false) {
///     router.route(result)
/// }
/// ```
final class ScrollingCaptureFlow {
    private let settings: AppSettings
    private let permissions: PermissionsService?
    private let overlay: SelectionOverlayController
    private let options: ScrollingOptions

    private var session: ScrollingCaptureSession?
    private var ui: ScrollingOverlayUI?
    private var continuation: CheckedContinuation<CaptureResult?, Never>?
    private var previewTask: Task<Void, Never>?
    private var isEnding = false
    private var askedForPermission = false

    /// - Parameters:
    ///   - permissions: the app's service (asks for event posting lazily); a
    ///     fresh one is used when `nil`.
    ///   - overlay: selection overlay to pick the area with.
    init(
        settings: AppSettings = .shared,
        permissions: PermissionsService? = nil,
        overlay: SelectionOverlayController = SelectionOverlayController()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.overlay = overlay
        options = settings.scrollingOptions
    }

    /// Convenience: one flow with default dependencies.
    static func run(
        rect: GlobalRect?,
        autoScroll: Bool,
        start: Bool? = nil,
        permissions: PermissionsService? = nil
    ) async -> CaptureResult? {
        await ScrollingCaptureFlow(permissions: permissions).run(rect: rect, autoScroll: autoScroll, start: start)
    }

    /// - Parameters:
    ///   - rect: Quartz global points; `nil` runs the area overlay first.
    ///   - autoScroll: start auto-scrolling right away (URL `autoscroll=true`).
    ///   - start: start capturing without the "Start Capture" step (URL
    ///     `start=`); `nil` follows the setting. Auto-scroll implies it.
    /// - Returns: the stitched capture, or `nil` if cancelled / failed.
    func run(rect preset: GlobalRect?, autoScroll: Bool, start: Bool? = nil) async -> CaptureResult? {
        guard continuation == nil else {
            Log.scrolling.error("run() while a scrolling capture is active; ignoring")
            return nil
        }
        guard CGPreflightScreenCaptureAccess() else {
            Log.scrolling.error("scrolling capture needs Screen Recording permission")
            return nil
        }
        guard let rect = await selectArea(preset: preset) else { return nil }
        guard let session = ScrollingCaptureSession.make(rect: rect, options: options),
              let ui = ScrollingOverlayUI(rect: session.rect, displayID: session.displayID)
        else {
            Log.scrolling.error("selection is off-screen: \(String(describing: rect), privacy: .public)")
            return nil
        }
        self.session = session
        self.ui = ui
        wire(session, ui)
        ui.show()

        let startNow = autoScroll || (start ?? options.startAutomatically)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if startNow {
                Task { await self.beginCapture(autoScroll: autoScroll) }
            }
        }
    }

    // MARK: Test / automation hooks

    /// Same as clicking Done.
    func requestDone() { Task { await end(done: true) } }
    /// Same as clicking Cancel.
    func requestCancel() { Task { await end(done: false) } }

    // MARK: Steps

    private func selectArea(preset: GlobalRect?) async -> GlobalRect? {
        if let preset { return preset }
        let refresh = Task { await ScreenCaptureService.shared.refreshShareableContent() }
        let outcome = await overlay.run(OverlayConfig(mode: .scrolling, editable: true).applyingUserSettings())
        await refresh.value
        switch outcome {
        case .area(let rect, _), .frozenArea(let rect, _, _):
            // Frozen or not, scrolling always captures live frames.
            return rect
        case .window(let id):
            return WindowLocator.snapshot().window(withID: id)?.frame
        case .fullscreen(let displayID):
            let layout = DisplayLayoutProvider.currentLayout()
            return layout.display(withID: displayID).flatMap { ScreenGeometry.globalFrame(of: $0, layout: layout) }
        case .cancelled:
            Log.scrolling.notice("area selection cancelled")
            return nil
        }
    }

    private func wire(_ session: ScrollingCaptureSession, _ ui: ScrollingOverlayUI) {
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onAutoScrollChanged = { [weak ui] on in ui?.model.isAutoScrolling = on }
        session.onStreamStopped = { [weak self] reason in
            Log.scrolling.error("stream stopped (\(reason, privacy: .public)); finishing with what we have")
            self?.requestDone()
        }
        ui.actions = ScrollingOverlayActions(
            start: { [weak self] in Task { await self?.beginCapture(autoScroll: false) } },
            toggleAutoScroll: { [weak self] horizontal in Task { await self?.toggleAutoScroll(horizontal: horizontal) } },
            cancel: { [weak self] in self?.requestCancel() },
            done: { [weak self] in self?.requestDone() },
            openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
            dismissPermissionNotice: { [weak ui] in ui?.model.needsAccessibility = false }
        )
    }

    private func beginCapture(autoScroll: Bool) async {
        guard let session, let ui, !isEnding else { return }
        if !session.isCapturing {
            ui.model.phase = .capturing
            do {
                try await session.start()
            } catch {
                Log.scrolling.error("could not start the stream: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                await end(done: false)
                return
            }
            startPreviewLoop()
        }
        if autoScroll { await startAutoScroll(axis: nil) }
    }

    private func toggleAutoScroll(horizontal: Bool) async {
        guard let session, !isEnding else { return }
        if session.isAutoScrolling {
            session.stopAutoScroll()
            return
        }
        if !session.isCapturing { await beginCapture(autoScroll: false) }
        await startAutoScroll(axis: horizontal ? .horizontal : nil)
    }

    private func startAutoScroll(axis: StitchAxis?) async {
        guard let session, let ui else { return }
        switch await session.startAutoScroll(axis: axis) {
        case .started:
            ui.model.needsAccessibility = false
        case .permissionMissing:
            ui.model.needsAccessibility = true
            // Ask once per session (plan §2.1: lazily, on the first auto-scroll).
            if !askedForPermission {
                askedForPermission = true
                (permissions ?? PermissionsService()).requestPostEvent()
            }
        case .alreadyRunning, .notCapturing:
            break
        }
    }

    private func openAccessibilitySettings() {
        (permissions ?? PermissionsService()).openSystemSettings(.accessibility)
    }

    private func handle(_ event: ScrollingSessionEvent) {
        guard let ui else { return }
        switch event {
        case .started:
            break
        case .progress:
            ui.model.hasProgress = true
        case .slowDown(let on):
            ui.model.showsSlowDown = on
        case .contentEnded:
            if options.finishAtContentEnd { requestDone() }
        case .limitReached:
            requestDone()
        }
    }

    /// Thumbnail refresh, at most `Tokens.Scrolling.previewInterval` apart (≤ 4 Hz).
    private func startPreviewLoop() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            var revision = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Tokens.Scrolling.previewInterval)
                guard let self, let session = self.session else { return }
                if let (image, newRevision) = await session.preview(
                    ifNewerThan: revision, maxDimension: Tokens.Scrolling.previewMaxPixels
                ) {
                    revision = newRevision
                    self.ui?.model.preview = image
                }
            }
        }
    }

    private func end(done: Bool) async {
        guard !isEnding, let continuation else { return }
        isEnding = true
        previewTask?.cancel()
        previewTask = nil
        ui?.model.phase = .finishing
        var result: CaptureResult?
        if let session {
            if done {
                result = await session.finish()
            } else {
                await session.cancel()
            }
        }
        ui?.close()
        ui = nil
        session = nil
        self.continuation = nil
        isEnding = false
        continuation.resume(returning: result)
    }
}
