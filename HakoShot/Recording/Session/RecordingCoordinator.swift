import AppKit
import CoreMedia
import HakoKit
import os

/// Runs screen-recording commands (kayit-teknik-plan §2.2, §2.3, §4.1–§4.12).
///
/// Flow: target (selection overlay + pre-record HUD, the display picker for
/// fullscreen, or the URL rect / window / display) → request (HUD choice +
/// settings) → countdown (Esc cancels, nothing recorded) → environment
/// (desktop icons, sleep, Focus) → `RecordingSession.start` → session chrome
/// (dimmer, border, control bar; the menu bar indicator reads `session`) and,
/// in window mode, the `WindowFollower` → stop → `RecordingFinalizer` →
/// `RecordingOutputRouter`. Discard throws everything away; restart keeps
/// only the part recorded after it.
///
/// Every exit (stop, discard, failure to start, window closed, unexpected
/// source stop) hides the chrome, stops the follower and ends the
/// environment (`tearDownSession`). One session at a time; `.record` while
/// recording stops it (the ⇧⌘9 toggle), during the countdown cancels it.
@MainActor
final class RecordingCoordinator {
    enum Phase: Equatable {
        case idle
        /// Selection overlay or display picker on screen.
        case selecting
        case countdown
        case starting
        /// Recording or paused (`session.state` tells which).
        case recording(RecordingHandle)
        /// Stopping, finalizing and routing (or discarding).
        case finishing

        var name: String {
            switch self {
            case .idle: "idle"
            case .selecting: "selecting"
            case .countdown: "countdown"
            case .starting: "starting"
            case .recording: "recording"
            case .finishing: "finishing"
            }
        }
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onStateChanged?() } }
    }

    /// Menu refresh (Record Screen / recording menu, menu bar indicator).
    var onStateChanged: (() -> Void)?
    /// Screen Recording permission missing.
    var onPermissionDenied: (() -> Void)?

    let router: RecordingOutputRouter
    /// The live session (state, elapsed, stats) for the control bar and the menu bar indicator.
    let session: RecordingSession
    private let engine: RecordingEngine
    private let settings: AppSettings
    private let environment: RecordingEnvironment
    private let overlay = SelectionOverlayController()
    private let displayPicker = RecordingDisplayPicker()
    private let countdown = RecordingCountdown()
    private let dimmer = RecordingDimmer()
    private let border = RecordingAreaBorder()
    private lazy var controlBar = RecordingControlBar(
        session: session,
        onStop: { [weak self] in Task { await self?.stop() } },
        onTogglePause: { [weak self] in Task { await self?.togglePause() } },
        onRestart: { [weak self] in Task { await self?.restart() } },
        // The bar asks "Discard recording?" itself.
        onDiscard: { [weak self] in Task { await self?.discard(confirm: false) } }
    )
    private var windowFollower: WindowFollower?
    /// Webcam bubble / camera.mov, click and keystroke overlay, EventRecorder (R4.I, R5.I).
    private var companions: RecordingCompanions?
    private var activeRequest: RecordingRequest?
    /// What the chrome was last shown around (Quartz global points).
    private var chromeRect: GlobalRect?
    /// Asks for microphone access (prompts once); `true` = granted.
    private let requestMicrophoneAccess: () async -> Bool

    init(
        settings: AppSettings = .shared,
        engine: RecordingEngine = .shared,
        router: RecordingOutputRouter? = nil,
        environment: RecordingEnvironment? = nil,
        requestMicrophoneAccess: @escaping () async -> Bool = { await MediaPermissions.requestMicrophone() }
    ) {
        self.settings = settings
        self.engine = engine
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.router = router ?? RecordingOutputRouter(settings: settings)
        self.environment = environment ?? RecordingEnvironment(settings: settings)
        session = RecordingSession(engine: engine)
        session.onStateChange = { [weak self] _, _ in self?.onStateChanged?() }
        session.onUnexpectedStop = { [weak self] error in
            Task { await self?.handleUnexpectedStop(error) }
        }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isPaused: Bool { isRecording && session.state.isPaused }

    /// Any command state other than idle (selecting, countdown, starting, recording, finishing).
    var isBusy: Bool { phase != .idle }

    // MARK: Commands

    func run(_ command: AppCommand) async {
        switch command {
        case let .record(kind, options):
            switch phase {
            case .recording: await stop()
            case .countdown: countdown.cancel()
            case .idle: await record(kind, options: options)
            default: Log.recording.notice("record ignored: \(self.phase.name, privacy: .public)")
            }
        case .stopRecording:
            await stop()
        case let .discardRecording(confirm):
            await discard(confirm: confirm)
        case .togglePauseRecording:
            await togglePause()
        case .pauseRecording:
            guard isRecording else { return logNoSession(command) }
            await pause()
        case .resumeRecording:
            guard isRecording else { return logNoSession(command) }
            await resume()
        case .restartRecording:
            await restart()
        default:
            Log.recording.notice("RecordingCoordinator can't run \(command.description, privacy: .public)")
        }
    }

    private func logNoSession(_ command: AppCommand) {
        Log.recording.notice("\(command.description, privacy: .public): no recording running")
    }

    func togglePause() async {
        guard isRecording else { return logNoSession(.togglePauseRecording) }
        if session.state.isPaused {
            await resume()
        } else {
            await pause()
        }
    }

    /// Pauses the engine, then the camera file and the overlay at the same host instant.
    private func pause() async {
        guard await session.pause() else { return }
        if let host = await engine.timeline?.openPauseStart {
            companions?.didPause(at: host)
        }
    }

    private func resume() async {
        guard await session.resume() else { return }
        let host = await engine.timeline?.pauses.last?.upperBound ?? RecordingEngine.hostNow().seconds
        companions?.didResume(at: host)
    }

    func restart() async {
        guard isRecording else { return logNoSession(.restartRecording) }
        do {
            try await session.restart()
            companions?.didRestart()
            Log.recording.notice("recording restarted")
        } catch {
            Log.recording.error("restart failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Start

    private func record(_ kind: RecordingTargetKind, options: RecordingCommandOptions) async {
        let source = Self.source(for: options)
        if source == .screen, !CGPreflightScreenCaptureAccess() {
            Log.recording.error("recording needs Screen Recording permission")
            onPermissionDenied?()
            return
        }

        guard let (target, selection) = await chooseTarget(kind, options: options) else {
            phase = .idle
            return
        }
        var request = Self.makeRequest(
            target: target,
            options: options,
            selection: selection,
            base: selection.options(settings: settings),
            source: source
        )
        request = await withMicrophoneAccess(request)
        if case let .area(rect, _) = target, settings.value(for: .recordingRememberLastSelection) {
            settings.set(Self.lastRectString(rect), for: .recordingLastRect)
        }

        if request.options.countdownSeconds > 0 {
            guard await runCountdown(request) else {
                phase = .idle
                return
            }
        }
        await start(request, cameraSource: options.camera == .pattern ? .pattern : .live)
    }

    /// Target and HUD choice; `nil` = cancelled.
    private func chooseTarget(
        _ kind: RecordingTargetKind,
        options: RecordingCommandOptions
    ) async -> (RecordingTarget, RecordingHUDSelection)? {
        let layout = DisplayLayoutProvider.currentLayout()
        let urlSelection = Self.hudSelection(for: options)
        switch kind {
        case .fullscreen, .pickDisplay:
            if let number = options.display {
                return (.display(RecordingDisplayNumbering.displayID(number: number, layout: layout) ?? layout.mainDisplayID), urlSelection)
            }
            if options.start || layout.displays.count <= 1 {
                return (.display(DisplayLayoutProvider.displayUnderMouse() ?? layout.mainDisplayID), urlSelection)
            }
            phase = .selecting
            guard let displayID = await displayPicker.run(layout: layout) else { return nil }
            return (.display(displayID), urlSelection)
        case .window, .area:
            #if DEBUG
            if kind == .window, let raw = options.window {
                guard let id = RecordingTargetDebug.WindowSelector(raw).flatMap(RecordingTargetDebug.windowID(for:)) else {
                    Log.recording.error("record: no window for window=\(raw, privacy: .public)")
                    NSSound.beep()
                    return nil
                }
                return (.window(id), urlSelection)
            }
            #endif
            if kind == .area, let rect = options.rect, options.start {
                return (Self.areaTarget(rect, layout: layout), urlSelection)
            }
            phase = .selecting
            var initialRect = options.rect.map { GlobalRect(origin: $0.origin, size: $0.size) }
            if initialRect == nil, kind == .area, settings.value(for: .recordingRememberLastSelection) {
                initialRect = Self.parseLastRect(settings.value(for: .recordingLastRect))
            }
            var config = OverlayConfig(
                mode: kind == .window ? .window : .recording,
                initialRect: initialRect,
                editable: kind == .area
            ).applyingUserSettings(settings)
            config.freeze = false
            let hud = RecordingOptionsBar(settings: settings)
            let outcome = await overlay.run(config, accessory: hud)
            let selection = hud.selection ?? urlSelection
            switch outcome {
            case let .area(rect, displayID), let .frozenArea(rect, displayID, _):
                return (.area(rect, displayID: displayID), selection)
            case let .window(id):
                return (.window(id), selection)
            case let .fullscreen(displayID):
                return (.display(displayID), selection)
            case .cancelled:
                Log.recording.notice("recording selection cancelled")
                return nil
            }
        }
    }

    /// Mic on (real screen source): ask for access before anything starts (the
    /// prompt shows once). Still denied → record without the microphone and
    /// say so; the toast opens before `session.start`, so it isn't recorded.
    private func withMicrophoneAccess(_ request: RecordingRequest) async -> RecordingRequest {
        guard Self.needsMicrophoneAccess(request) else { return request }
        if await requestMicrophoneAccess() { return request }
        Log.recording.error("microphone access denied; recording without the microphone")
        ToastHUD.show(.message("Microphone access is off – recording without it"))
        return Self.withoutMicrophone(request)
    }

    /// The synthetic source makes its own tone and never opens the mic.
    nonisolated static func needsMicrophoneAccess(_ request: RecordingRequest) -> Bool {
        request.options.microphone != nil && request.source == .screen && request.format != .gif
    }

    nonisolated static func withoutMicrophone(_ request: RecordingRequest) -> RecordingRequest {
        var request = request
        request.options.microphone = nil
        return request
    }

    /// `true` when it ran to zero; `false` when cancelled (nothing recorded).
    private func runCountdown(_ request: RecordingRequest) async -> Bool {
        phase = .countdown
        let layout = DisplayLayoutProvider.currentLayout()
        let rect = Self.countdownRect(for: request.target, layout: layout, windowFrame: Self.windowFrame(of:))
            ?? GlobalRect(origin: .zero, size: CGSize(width: 1, height: 1))
        session.prepare()
        session.beginCountdown()
        let completed = await countdown.run(seconds: request.options.countdownSeconds, on: rect)
        if !completed {
            Log.recording.notice("recording countdown cancelled; nothing recorded")
            await session.discard()
            session.reset()
        }
        return completed
    }

    private func start(_ request: RecordingRequest, cameraSource: RecordingCameraSource) async {
        phase = .starting
        activeRequest = request
        environment.begin(RecordingEnvironment.Options(recording: request.options, settings: settings))
        // Show the chrome *before* the stream starts: the filter excludes our
        // whole app only if it has an on-screen window when the content is
        // fetched; otherwise it excludes the windows listed then, and a bar
        // created afterwards would be recorded (ContentFilterBuilder).
        let plan = Self.chromePlan(target: request.target, options: request.options)
        let layout = DisplayLayoutProvider.currentLayout()
        if Self.needsKeystrokeWarning(request, inputMonitoringGranted: InputMonitoringPermission.isGranted) {
            // Before the stream starts, so the toast isn't recorded. Never prompts.
            Log.recording.notice("Show keystrokes is on but Input Monitoring isn't granted; recording without keys")
            ToastHUD.show(.permission("Keystrokes need Input Monitoring", pane: .inputMonitoring))
        }
        let companions = RecordingCompanions(request: request, cameraSource: cameraSource, settings: settings)
        companions.onCornerChange = { [weak self] corner in
            self?.settings.set(corner, for: .recordingCameraCorner)
        }
        self.companions = companions
        var exceptedWindowIDs: [CGWindowID] = []
        if let rect = Self.countdownRect(for: request.target, layout: layout, windowFrame: Self.windowFrame(of:)) {
            let displayID = Self.displayID(for: request.target, rect: rect, layout: layout)
            showChrome(around: rect, displayID: displayID, plan: plan)
            // Bubble and overlay: on screen before the content is fetched;
            // classic captures them (excepted windows), Studio doesn't.
            exceptedWindowIDs = await companions.prepare(rect: rect, displayID: displayID)
            if !exceptedWindowIDs.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let handle: RecordingHandle
        do {
            // Our other windows (chrome, HUD, toasts) are left out by excluding the app.
            handle = try await session.start(request, overlayWindowIDs: exceptedWindowIDs)
        } catch {
            Log.recording.error("recording failed to start: \(String(describing: error), privacy: .public)")
            companions.discard()
            await tearDownCompanions()
            tearDownSession()
            activeRequest = nil
            session.reset()
            phase = .idle
            switch error {
            case RecordingError.permissionDenied: onPermissionDenied?()
            case RecordingError.cancelled: break
            default: NSSound.beep()
            }
            return
        }
        phase = .recording(handle)
        Log.recording.notice("recording \(handle.id.uuidString, privacy: .public): \(Int(handle.pointSize.width))x\(Int(handle.pointSize.height)) pt -> \(Int(handle.pixelSize.width))x\(Int(handle.pixelSize.height)) px, \(handle.target.kind.rawValue, privacy: .public)")

        // The engine's rect (clipped to the display) and display.
        showChrome(around: handle.sourceRect, displayID: handle.displayID, plan: plan)
        companions.didStart(handle, engine: engine)
        startFollowing(handle)
        scheduleAutoStop(request, handle: handle)
    }

    // MARK: Chrome and window following

    private func showChrome(around rect: GlobalRect, displayID: CGDirectDisplayID, plan: RecordingChromePlan) {
        chromeRect = rect
        if plan.showsDimmer { dimmer.show(recordedRect: rect, recordingDisplayID: displayID) }
        if plan.showsBorder { border.show(recordedRect: rect, recordingDisplayID: displayID) }
        if plan.showsControlBar { controlBar.show(recordedRect: rect, displayID: displayID) }
    }

    private func startFollowing(_ handle: RecordingHandle) {
        let layout = DisplayLayoutProvider.currentLayout()
        guard let display = layout.display(withID: handle.displayID),
              let displayFrame = ScreenGeometry.globalFrame(of: display, layout: layout)
        else { return }
        let engine = engine
        let id = handle.id
        windowFollower = WindowFollower.make(
            for: handle,
            layout: layout,
            apply: { [weak self] localRect in
                try await engine.updateSourceRect(localRect)
                await self?.windowMoved(localRect, displayFrame: displayFrame, displayID: handle.displayID)
            },
            onWindowClosed: { [weak self] in
                Log.recording.notice("recorded window closed; stopping")
                Task { await self?.stop(ifSession: id) }
            }
        )
        windowFollower?.start()
    }

    /// Moves the dimmer hole and the border with the followed window.
    private func windowMoved(_ localRect: CGRect, displayFrame: GlobalRect, displayID: CGDirectDisplayID) {
        guard isRecording else { return }
        let rect = Self.globalRect(local: localRect, displayFrame: displayFrame)
        chromeRect = rect
        if dimmer.isVisible { dimmer.show(recordedRect: rect, recordingDisplayID: displayID) }
        if border.isVisible { border.show(recordedRect: rect, recordingDisplayID: displayID) }
        companions?.recordedRectChanged(rect)
    }

    /// Hides the chrome, stops the follower, restores the environment. Safe to repeat.
    private func tearDownSession() {
        windowFollower?.stop()
        windowFollower = nil
        controlBar.hide()
        dimmer.hide()
        border.hide()
        chromeRect = nil
        environment.end()
    }

    /// Hides the bubble and the overlay, stops the camera. Safe to repeat.
    private func tearDownCompanions() async {
        guard let companions else { return }
        self.companions = nil
        await companions.tearDown()
    }

    private func scheduleAutoStop(_ request: RecordingRequest, handle: RecordingHandle) {
        guard let seconds = request.autoStopAfter, seconds > 0 else { return }
        let engine = engine
        Task { [weak self] in
            // `session.start` already waited for the first frame.
            // Follow the media clock (first frame = 0, pauses excluded), not wall time.
            while true {
                let remaining = seconds - (await engine.stats.duration)
                if remaining <= 0.002 { break }
                try? await Task.sleep(for: .seconds(min(remaining, 0.25)))
                guard let self, case let .recording(current) = self.phase, current.id == handle.id else { return }
            }
            await self?.stop(ifSession: handle.id)
        }
    }

    // MARK: Stop / discard

    /// Stops only if `id` is still the running session (auto-stop, window closed).
    private func stop(ifSession id: UUID) async {
        guard case let .recording(handle) = phase, handle.id == id else { return }
        await stop()
    }

    /// Stop → finalize → route. During the countdown (or the display picker) it cancels it.
    func stop() async {
        switch phase {
        case .countdown:
            countdown.cancel()
            return
        case .selecting where displayPicker.isRunning:
            displayPicker.cancel()
            return
        case .recording:
            break
        default:
            Log.recording.notice("stop: no recording running")
            return
        }
        let request = activeRequest
        phase = .finishing
        let stopHost = RecordingEngine.hostNow()
        companions?.stopInputs()
        tearDownSession()
        defer {
            activeRequest = nil
            session.reset()
            phase = .idle
        }

        var raw: RawRecording
        do {
            raw = try await session.stop()
        } catch {
            Log.recording.error("stop failed: \(String(describing: error), privacy: .public)")
            companions?.discard()
            await tearDownCompanions()
            NSSound.beep()
            return
        }
        // Bubble and overlay stay up until the stream stopped (last frames).
        if let companions {
            raw = await companions.finish(raw, stopHost: stopHost)
        }
        await tearDownCompanions()

        // Studio Mode: a .hakostudio package opened in Studio (plan §4.14);
        // if the package can't be made, the classic video is delivered instead.
        if request?.profile == .studio, request?.format != .gif, await finishStudio(raw, request: request) {
            return
        }

        var result: RecordingResult
        do {
            result = try await RecordingFinalizer.finalize(raw, audio: AudioMixSettings(request?.options ?? .default))
        } catch {
            // Keep the raw session folder: screen.mov is still playable (crash recovery, R7).
            Log.recording.error("finalize failed, raw kept at \(raw.sessionFolder.path, privacy: .public): \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }
        if request?.format == .gif {
            result = await convertToGIF(result)
        }

        #if DEBUG
        if let out = request?.outputURL {
            deliverDebugOutput(result, to: out)
            return
        }
        #endif
        await router.route(result, overriding: request?.action)
    }

    /// `.hakostudio` → History → Studio editor (`RecordingOutputRouter.routeStudio`).
    /// `false` = the package failed; `raw` still has `screen.mov` for the classic path.
    private func finishStudio(_ raw: RawRecording, request: RecordingRequest?) async -> Bool {
        let defaults = StudioRecordingFinalizer.defaults(settings: settings)
        #if DEBUG
        if let out = request?.outputURL {
            // URL `out=`: the package goes there; no History, no editor.
            let ext = StudioProjectFile.fileExtension
            let packageURL = out.pathExtension == ext ? out : out.appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: packageURL)
            do {
                _ = try await StudioRecordingFinalizer.makePackage(from: raw, defaults: defaults, at: packageURL)
                try? FileManager.default.removeItem(at: raw.sessionFolder)
                Log.recording.notice("studio recording written to \(packageURL.path, privacy: .public)")
                return true
            } catch {
                Log.recording.error("studio package failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        #endif
        do {
            try await router.routeStudio(raw, defaults: defaults, overriding: request?.action)
            return true
        } catch {
            Log.recording.error("studio package failed, delivering the video instead: \(String(describing: error), privacy: .public)")
            ToastHUD.show(.message("Couldn't create the Studio project – kept the video"))
            return false
        }
    }

    /// Deletes the session (nothing saved, nothing in History). During the countdown it cancels it.
    func discard(confirm: Bool) async {
        if phase == .countdown {
            countdown.cancel()
            return
        }
        guard isRecording else {
            Log.recording.notice("discard: no recording running")
            return
        }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Discard recording?"
            alert.informativeText = "The recording will be deleted."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, isRecording else { return }
        }
        phase = .finishing
        tearDownSession()
        companions?.discard()
        await session.discard()
        await tearDownCompanions()
        session.reset()
        activeRequest = nil
        phase = .idle
        Log.recording.notice("recording discarded")
    }

    /// Record GIF (plan §4.14, §4.17): the silent mp4 → GIF with Settings ›
    /// Screen Recording › GIF, next to it in the session folder (the router
    /// deletes the folder). Declining the size warning, cancelling (Esc /
    /// Cancel) or a failure keeps the video, which is delivered instead.
    private func convertToGIF(_ video: RecordingResult) async -> RecordingResult {
        let options = GIFConversion.options(settings: settings)
        if let bytes = await GIFConversion.estimatedBytes(for: video.fileURL, options: options),
           GIFConversion.isLarge(bytes), !GIFConversionPrompt.confirmLarge(bytes: bytes) {
            Log.recording.notice("GIF declined (estimated \(bytes) bytes); keeping the video")
            return video
        }
        let destination = video.fileURL.deletingLastPathComponent().appending(path: "recording.gif")
        let hud = GIFProgressHUD()
        let relay = GIFProgressRelay { hud.update($0) }
        let report = relay.report
        let task = Task {
            try await GIFConversion.convert(
                source: video.fileURL, options: options, to: destination,
                targetKind: video.targetKind, date: video.date, progress: report
            )
        }
        hud.show { task.cancel() }
        defer {
            relay.finish()
            hud.close()
        }
        let started = Date.now
        do {
            var gif = try await task.value
            gif.raw = video.raw
            Log.recording.notice("GIF \(Int(gif.pixelSize.width))x\(Int(gif.pixelSize.height)), \(String(format: "%.2f", gif.duration), privacy: .public) s in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s (\(options.fps) fps, width \(options.width))")
            return gif
        } catch is CancellationError {
            Log.recording.notice("GIF cancelled; keeping the video")
            return video
        } catch {
            Log.recording.error("GIF conversion failed: \(String(describing: error), privacy: .public); keeping the video")
            ToastHUD.show(.message("Couldn't make the GIF – kept the video"))
            return video
        }
    }

    private func handleUnexpectedStop(_ error: RecordingError) async {
        Log.recording.error("recording stopped unexpectedly: \(error.description, privacy: .public); keeping what was recorded")
        await stop()
    }

    #if DEBUG
    /// URL `out=`: move the mp4 / GIF there, skip the router, drop the session folder.
    private func deliverDebugOutput(_ result: RecordingResult, to out: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: out)
            try fileManager.moveItem(at: result.fileURL, to: out)
            Log.recording.notice("recording written to \(out.path, privacy: .public)")
        } catch {
            Log.recording.error("writing \(out.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        // Sidecars for smoke tests: <out>.events.json, <out>.cursor.bin, <out>.camera.mov.
        for (source, suffix) in Self.debugSidecars(result.raw) {
            let destination = URL(fileURLWithPath: out.path + suffix)
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: source, to: destination)
        }
        if let folder = result.raw?.sessionFolder { try? fileManager.removeItem(at: folder) }
    }

    /// `debug-recording-state?out=` payload: the session snapshot plus what
    /// the coordinator shows (chrome, follower, environment, menu).
    struct DebugState: Codable, Equatable {
        var phase: String
        var session: RecordingSession.DebugSnapshot
        var controlBarVisible: Bool
        /// `[x, y, width, height]`, AppKit screen coordinates (bottom-left origin).
        var controlBarFrame: [Double]?
        var dimmerVisible: Bool
        var borderVisible: Bool
        /// `[x, y, width, height]`, Quartz global points.
        var chromeRect: [Double]?
        var followingWindow: Bool
        var followerUpdates: Int
        var environmentActive: Bool
        /// Bubble, overlay, camera file, keystroke state (R4.I, R5.I).
        var companions: [String: String]?
        var menuBarTitle: String?
        var menuTitles: [String]
    }

    func debugWriteState(to url: URL, menuBarTitle: String?, menuTitles: [String]) async {
        let state = DebugState(
            phase: phase.name,
            session: await session.debugSnapshot(),
            controlBarVisible: controlBar.isVisible,
            controlBarFrame: controlBar.isVisible
                ? [controlBar.panel.frame.minX, controlBar.panel.frame.minY, controlBar.panel.frame.width, controlBar.panel.frame.height]
                : nil,
            dimmerVisible: dimmer.isVisible,
            borderVisible: border.isVisible,
            chromeRect: chromeRect.map { [$0.minX, $0.minY, $0.width, $0.height] },
            followingWindow: windowFollower?.isRunning ?? false,
            followerUpdates: windowFollower?.updateCount ?? 0,
            environmentActive: environment.isActive,
            companions: companions?.debugSummary,
            menuBarTitle: menuBarTitle,
            menuTitles: menuTitles
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: .atomic)
            Log.recording.notice("recording state written to \(url.path, privacy: .public)")
        } catch {
            Log.recording.error("writing recording state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func debugSidecars(_ raw: RawRecording?) -> [(URL, String)] {
        guard let raw else { return [] }
        return [(raw.eventsURL, ".events.json"), (raw.cursorURL, ".cursor.bin"), (raw.cameraURL, ".camera.mov")]
            .compactMap { url, suffix in url.map { ($0, suffix) } }
    }
    #endif

    // MARK: Pure helpers (tested)

    /// "Show keystrokes" on without Input Monitoring: warn before recording
    /// (keys stay off; the recording never prompts).
    nonisolated static func needsKeystrokeWarning(_ request: RecordingRequest, inputMonitoringGranted: Bool) -> Bool {
        request.options.showsKeystrokes && !inputMonitoringGranted
    }

    nonisolated static func source(for options: RecordingCommandOptions) -> RecordingSourceKind {
        #if DEBUG
        options.source ?? .screen
        #else
        .screen
        #endif
    }

    /// The format choice when the HUD isn't shown (`start=true`, fullscreen, URL window).
    nonisolated static func hudSelection(for options: RecordingCommandOptions) -> RecordingHUDSelection {
        RecordingHUDSelection(choice: options.studio ? .studio : (options.format == .gif ? .gif : .video))
    }

    /// The request for a chosen target: `base` = settings + HUD choice
    /// overrides (`RecordingHUDSelection.options(settings:)`); the URL's
    /// countdown / DEBUG values override it.
    nonisolated static func makeRequest(
        target: RecordingTarget,
        options: RecordingCommandOptions,
        selection: RecordingHUDSelection,
        base: RecordingOptions,
        source: RecordingSourceKind
    ) -> RecordingRequest {
        var recordingOptions = base
        if let countdown = options.countdownSeconds { recordingOptions.countdownSeconds = max(0, countdown) }
        // DEBUG URL overrides (nil in release builds).
        if let clicks = options.highlightsClicks { recordingOptions.highlightsClicks = clicks }
        if let keys = options.showsKeystrokes { recordingOptions.showsKeystrokes = keys }
        switch options.camera {
        case .off: recordingOptions.camera = nil
        case .on, .pattern: recordingOptions.camera = recordingOptions.camera ?? CameraOptions()
        case nil: break
        }
        var request = RecordingRequest(
            target: target,
            options: recordingOptions,
            format: selection.format,
            profile: selection.profile,
            action: options.action,
            source: source
        )
        #if DEBUG
        request.autoStopAfter = options.autoStopAfter
        request.outputURL = options.outputURL
        #endif
        return request
    }

    /// Which chrome a session shows (plan §4.4): no dimmer or border in
    /// fullscreen; the dimmer follows "Dim screen", the bar "Show controls".
    nonisolated static func chromePlan(target: RecordingTarget, options: RecordingOptions) -> RecordingChromePlan {
        let fullscreen = target.kind == .fullscreen || target.kind == .pickDisplay
        return RecordingChromePlan(
            showsDimmer: !fullscreen && options.dimScreen,
            showsBorder: !fullscreen,
            showsControlBar: options.showControls
        )
    }

    /// `.area` on the display under the rect's center (else the main display);
    /// the engine clips it to that display.
    nonisolated static func areaTarget(_ rect: CGRect, layout: DisplayLayout) -> RecordingTarget {
        let displayID = ScreenGeometry.display(containing: CGPoint(x: rect.midX, y: rect.midY), layout: layout)?.id
            ?? layout.mainDisplayID
        return .area(GlobalRect(origin: rect.origin, size: rect.size), displayID: displayID)
    }

    /// Where the countdown is centered: the area, the window, or the whole display.
    nonisolated static func countdownRect(
        for target: RecordingTarget,
        layout: DisplayLayout,
        windowFrame: (CGWindowID) -> GlobalRect?
    ) -> GlobalRect? {
        switch target {
        case let .area(rect, _):
            return rect
        case let .window(id):
            return windowFrame(id) ?? layout.mainDisplay.flatMap { ScreenGeometry.globalFrame(of: $0, layout: layout) }
        case let .display(id):
            return layout.display(withID: id).flatMap { ScreenGeometry.globalFrame(of: $0, layout: layout) }
        }
    }

    /// The display a target records on (a window: the one under its center).
    nonisolated static func displayID(for target: RecordingTarget, rect: GlobalRect, layout: DisplayLayout) -> CGDirectDisplayID {
        switch target {
        case let .area(_, displayID): displayID
        case let .display(displayID): displayID
        case .window:
            ScreenGeometry.display(containing: CGPoint(x: rect.midX, y: rect.midY), layout: layout)?.id ?? layout.mainDisplayID
        }
    }

    nonisolated static func windowFrame(of id: CGWindowID) -> GlobalRect? {
        WindowFollower.liveWindowState(of: id)?.frame
    }

    /// A display-local source rect back in Quartz global points.
    nonisolated static func globalRect(local: CGRect, displayFrame: GlobalRect) -> GlobalRect {
        GlobalRect(x: displayFrame.minX + local.minX, y: displayFrame.minY + local.minY, width: local.width, height: local.height)
    }

    /// `recordingLastRect` encoding (same as `capturePreviousAreaRect`).
    nonisolated static func lastRectString(_ rect: GlobalRect) -> String {
        "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)"
    }

    nonisolated static func parseLastRect(_ text: String) -> GlobalRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return GlobalRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}

/// What `RecordingCoordinator` shows while recording (plan §4.4).
nonisolated struct RecordingChromePlan: Equatable, Sendable {
    var showsDimmer: Bool
    var showsBorder: Bool
    var showsControlBar: Bool
}
