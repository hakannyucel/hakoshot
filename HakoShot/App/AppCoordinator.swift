import os
import AppKit
import HakoKit
import UniformTypeIdentifiers

/// Single entry point for every command (plan §3.2). Hotkeys, the menu bar and
/// URL schemes all call `perform(_:)`.
///
/// To add a command: add a case to `AppCommand`, map a URL in `URLSchemeHandler`
/// if needed, and handle it in the `switch` below (usually by calling a feature
/// controller owned here).
///
/// M2 wiring (plan §3.3): captures → `PostCaptureRouter` → history (always) +
/// Quick Access / pin per Settings > General > After capture. Quick Access
/// card events keep the history entry's "closed" flag in sync so Restore
/// Recently Closed works, also after a relaunch (falls back to history).
final class AppCoordinator {
    let permissions: PermissionsService
    let activationPolicy: ActivationPolicyController
    let quickAccess: QuickAccessController
    /// Screen recording (kayit-teknik-plan §2.2); R0: area → mp4.
    let recording: RecordingCoordinator

    /// Called when a dynamic menu item may have changed (pins, restorable cards, recording).
    var onMenuStateChanged: (() -> Void)?
    /// The status item's current title (set by `MenuBarController`; DEBUG state dumps).
    var menuBarTitleProvider: (() -> String?)?

    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let captureFlow: CaptureFlowController
    private let settings: AppSettings
    private let history: HistoryStore
    private let historyOverlay: HistoryOverlayController
    private let pins: PinController

    /// History writes still in flight, so later updates (closed, saved URL) wait for them.
    private var pendingHistoryWrites: [UUID: Task<HistoryItem?, Never>] = [:]
    /// Last project write per history entry, so saves land in order.
    private var historyProjectWrites: [UUID: Task<Void, Never>] = [:]
    /// Cached `history.lastClosed() != nil` for the (synchronous) menu.
    private var historyHasClosedEntry = false
    /// Sources with a Convert to GIF running (one conversion per file).
    private var gifConversions: Set<URL> = []
    private let desktopIcons: DesktopIconsToggle

    init(
        permissions: PermissionsService = PermissionsService(),
        activationPolicy: ActivationPolicyController = ActivationPolicyController(),
        captureFlow: CaptureFlowController = CaptureFlowController(),
        settings: AppSettings = .shared,
        quickAccess: QuickAccessController? = nil,
        history: HistoryStore = .shared,
        historyOverlay: HistoryOverlayController = .shared,
        pins: PinController = .shared,
        desktopIcons: DesktopIconsToggle = .shared,
        recording: RecordingCoordinator? = nil
    ) {
        self.permissions = permissions
        self.activationPolicy = activationPolicy
        self.captureFlow = captureFlow
        self.settings = settings
        self.quickAccess = quickAccess ?? QuickAccessController(settings: settings)
        self.history = history
        self.historyOverlay = historyOverlay
        self.pins = pins
        self.desktopIcons = desktopIcons
        self.recording = recording ?? RecordingCoordinator(settings: settings)

        captureFlow.permissions = permissions
        captureFlow.onPermissionDenied = { [weak self] in
            self?.permissions.refresh()
            self?.showOnboarding()
        }
        connectPostCapture()
        connectQuickAccess()
        connectHistoryOverlay()
        connectPins()
        connectEditor()
        connectRecording()
        desktopIcons.onChange = { [weak self] _ in self?.onMenuStateChanged?() }
        // Settings › About "Show Welcome Guide…" posts this (no coordinator reference there).
        NotificationCenter.default.addObserver(forName: .showOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding(step: .welcome) }
        }
    }

    /// Launch-time work (not run when hosting unit tests).
    func start() {
        let history = history
        Task {
            await history.startMaintenance()
            await refreshHistoryClosedState()
        }
        Task.detached(priority: .background) { RecordingOutputRouter.purgeRetainedFiles() }
        // Focus left on by a recording the app didn't get to end (plan §4.11).
        RecordingEnvironment.recoverAfterCrash(settings: settings)
        // Recordings the app didn't get to finish (plan §4.22).
        RecordingRecovery.recoverAtLaunch(
            historyStore: history, studioDefaults: StudioRecordingFinalizer.defaults(settings: settings)
        ) { [weak self] report in
            self?.showRecovered(report)
        }
    }

    /// Launch recovery result: a toast and a Quick Access card per recording.
    private func showRecovered(_ report: RecoveryReport) {
        guard let message = report.message else { return }
        Log.recording.notice("recovery at launch: \(message, privacy: .public)")
        ToastHUD.show(.message(message))
        for recovered in report.recovered {
            // Studio sessions come back as a project: open it like a normal Studio stop.
            if let package = recovered.studioPackageURL {
                StudioWindowController.open(url: package)
            } else {
                quickAccess.show(recording: recovered.result, historyID: recovered.result.historyID)
            }
        }
        Task { await refreshHistoryClosedState() }
    }

    /// Read by the menu each time it opens.
    var menuState: MenuState {
        MenuState(
            desktopIconsHidden: desktopIcons.isHidden,
            hasPins: pins.hasPins,
            hasLockedPins: pins.hasLockedPins,
            hasRecentlyClosed: quickAccess.canRestore || historyHasClosedEntry,
            isRecording: recording.isRecording,
            isRecordingPaused: recording.isPaused,
            recordingBusy: recording.isBusy
        )
    }

    func perform(_ command: AppCommand) async {
        Log.coordinator.notice("perform \(command.description, privacy: .public)")
        switch command {
        case .openSettings:
            showSettings()
        case .openOnboarding:
            showOnboarding(step: .welcome)
        case let .openSettingsPage(raw):
            showSettings(page: SettingsPage(rawValue: raw) ?? SettingsPage.allCases.first { $0.rawValue.lowercased() == raw })
        #if DEBUG
        case .showDesignSystemPreview:
            DesignSystemPreviewWindow.show()
        case .debugCaptureMainDisplay:
            await CaptureDebug.captureMainDisplayToDesktop()
        case .debugQuickAccessSample:
            if let result = QuickAccessDebug.sampleResult(pointSize: CGSize(width: 800, height: 500)) {
                route(result)
            }
        case .debugPinSample:
            PinDebug.pinSample(controller: pins)
        case .debugHistorySample:
            await HistoryDebug.seedSamples(count: 4, into: history)
            historyOverlay.show()
        case .debugCaptureFrontWindow:
            await WindowCaptureDebug.captureFrontmostWindowToDesktop()
        case let .debugEditorSaveProject(url):
            debugSaveSampleProject(to: url)
        case let .debugQuickAccessEdit(close):
            if !quickAccess.debugPerformOnNewest(close ? .close : .edit) {
                Log.coordinator.notice("debug: no Quick Access card to edit")
            }
        case .debugCloseEditors:
            EditorWindowController.closeAllDiscardingChanges()
        case .debugAnnotateAndSaveEditors:
            for editor in EditorWindowController.debugOpenEditors {
                EditorDebug.addSampleAnnotations(to: editor.model)
                editor.perform(.save)
            }
        case let .debugRemoveHistoryEntry(id):
            _ = await pendingHistoryWrites[id]?.value
            _ = await historyProjectWrites[id]?.value
            let removed = await history.remove(id: id) != nil
            Log.coordinator.notice("debug: removed history entry \(id.uuidString, privacy: .public): \(removed)")
            await refreshHistoryClosedState()
        case .debugFinishScrolling:
            if let flow = captureFlow.scrollingFlow {
                flow.requestDone()
            } else {
                Log.coordinator.notice("debug: no scrolling capture running")
            }
        case let .debugScrollingSample(options):
            captureFlow.debugDeliverScrollingSample(options)
        case let .debugSetShortcut(name, keyCode, modifiers):
            ShortcutBinding.debugSet(name: name, keyCode: keyCode, modifiers: modifiers)
        case .debugResetShortcuts:
            ShortcutBinding.resetAllToDefaults()
        case let .debugSnapshotSettings(page, url):
            showSettings(page: SettingsPage(rawValue: page))
            try? await Task.sleep(for: .milliseconds(800))
            await debugSnapshotSettingsWindow(to: url)
        case let .debugRecord(parameters):
            await RecordingDebug.run(parameters)
        case let .debugMediaInfo(file, out):
            await Self.debugWriteMediaInfo(file, to: out)
        case let .debugQuickAccessVideoSample(format, hover):
            await QuickAccessVideoDebug.showSample(format: format, hover: hover, on: quickAccess)
        case .debugHistorySampleVideo:
            let item = await HistoryDebug.addSampleVideo(into: history)
            Log.coordinator.notice("debug: history sample video \(item?.id.uuidString ?? "not added", privacy: .public)")
        case let .debugRecordingState(url):
            let titles = MenuBuilder.entries(for: menuState).compactMap { entry -> String? in
                if case let .command(title, _, _, _, _, enabled, _) = entry { return enabled ? title : "\(title) (disabled)" }
                return nil
            }
            await recording.debugWriteState(to: url, menuBarTitle: menuBarTitleProvider?(), menuTitles: titles)
        case let .debugRecordingChrome(parameters):
            Task { await RecordingChromeDebug.run(parameters) }
        case let .debugRecordingHUD(parameters):
            await RecordingHUDDebug.run(parameters)
        case let .debugMoveTestWindow(parameters):
            RecordingTargetDebug.showMovingTestWindow(parameters)
        case .debugCloseTestWindow:
            RecordingTargetDebug.closeTestWindow()
        case let .debugRecordWindow(parameters):
            Task { await RecordingTargetDebug.runRecordWindow(parameters) }
        case let .debugAudioDevices(url):
            RecordingAudioDebug.writeAudioDevices(to: url)
        case let .debugFinalize(parameters):
            await RecordingAudioDebug.finalize(parameters)
        case let .debugRender(parameters):
            await RenderDebug.run(parameters)
        case let .debugVideoEditor(parameters):
            await VideoEditorDebug.openAndSnapshot(parameters)
        case let .debugVideoEditorApply(parameters):
            await VideoEditorDebug.runApply(parameters)
        case let .debugCrashDuringRecording(parameters):
            await RecoveryDebug.crashDuringRecording(parameters)
        case let .debugRecoverRecordings(out):
            await RecoveryDebug.recoverNow(historyStore: history, out: out)
            await refreshHistoryClosedState()
        case let .debugCameraDevices(queryItems):
            CameraDebug.writeDevices(queryItems: queryItems)
        case let .debugRecordCamera(parameters):
            Task { _ = await CameraDebug.recordCamera(parameters) }
        case let .debugWebcamBubble(parameters):
            Task { _ = await CameraDebug.showBubble(parameters) }
        case let .debugInjectInput(parameters):
            InputDebug.inject(parameters)
        case let .debugRecordingEvents(url):
            InputDebug.writeEvents(to: url)
        case let .debugOverlayDemo(parameters):
            Task { await OverlayDemoDebug.run(parameters) }
        case let .debugStudio(command):
            Task { await StudioDebug.run(command) }
        case let .debugBenchmarkExport(spec):
            await StudioBenchmarkDebug.run(spec)
        case .debugCloseStudioWindows:
            for controller in StudioWindowController.debugOpenWindows { controller.closeWithoutSaving() }
        #endif
        case let .capture(mode, options):
            await captureFlow.capture(mode, options: options)
        case .openHistory:
            historyOverlay.toggle()
        case .restoreLastClosed:
            await restoreLastClosed()
        case .closeAllPins:
            pins.closeAll()
        case .unlockAllPins:
            pins.unlockAll()
        case let .captureText(lineBreaks, rect):
            await captureFlow.captureText(lineBreaks: lineBreaks, rect: rect)
        case .toggleDesktopIcons:
            DesktopIconsToggle.shared.toggle()
        case .openEditor(let url):
            if let url {
                await EditorDocumentOpener.open(fileURL: url)
            } else {
                EditorDocumentOpener.chooseAndOpen()
            }
        case .openFromClipboard:
            await EditorDocumentOpener.openFromClipboard()
        case .record, .stopRecording, .pauseRecording, .resumeRecording, .togglePauseRecording, .restartRecording, .discardRecording:
            await recording.run(command)
        case let .openVideoEditor(url):
            if let url {
                openVideoEditor(url)
            } else {
                chooseVideoAndOpen()
            }
        case let .convertToGIF(url, action):
            await convertToGIF(url, action: action)
        case let .openStudio(url):
            if let url {
                await openStudio(url)
            } else {
                StudioWindowController.chooseAndOpen()
            }
        }
    }

    #if DEBUG
    /// `debug-media-info`: the `scripts/media-info.swift` JSON, from inside the app.
    private static func debugWriteMediaInfo(_ file: URL, to out: URL) async {
        do {
            let info = try await MediaInspector.info(for: file)
            let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out, options: .atomic)
            Log.coordinator.notice("debug: media info \(file.lastPathComponent, privacy: .public) -> \(out.path, privacy: .public)")
        } catch {
            Log.coordinator.error("debug: media info failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func debugSnapshotSettingsWindow(to url: URL) async {
        guard let window = settingsWindowController?.window, let view = window.contentView else { return }
        // `-HakoSettingsSnapshotLight` / `-HakoSettingsSnapshotTall`: light appearance / 1400 pt tall window.
        let arguments = ProcessInfo.processInfo.arguments
        let oldFrame = window.frame
        let oldAppearance = window.appearance
        if arguments.contains("-HakoSettingsSnapshotLight") { window.appearance = NSAppearance(named: .aqua) }
        if arguments.contains("-HakoSettingsSnapshotTall") {
            window.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - 1400, width: oldFrame.width, height: 1400), display: true)
        }
        try? await Task.sleep(for: .milliseconds(500))
        defer {
            window.appearance = oldAppearance
            window.setFrame(oldFrame, display: true)
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
            Log.coordinator.notice("debug: settings snapshot \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(url.path, privacy: .public)")
        } catch {
            Log.coordinator.error("debug: settings snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// DEBUG automation hook (`CaptureFlowDebug`).
    func debugConfigureCaptureFlow(_ configure: (CaptureFlowController) -> Void) {
        configure(captureFlow)
    }
    #endif

    // MARK: Files

    /// Finder double-click / "Open With" / drop on the app: images and
    /// `.hakoshot` projects → the editor; movies → the video editor;
    /// `.hakostudio` packages → Studio.
    func openFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                Log.coordinator.notice("open file \(url.lastPathComponent, privacy: .public)")
                if Self.isStudioPackage(url) {
                    StudioWindowController.open(url: url)
                } else if Self.opensInVideoEditor(url) {
                    openVideoEditor(url)
                } else {
                    await EditorDocumentOpener.open(fileURL: url)
                }
            }
        }
    }

    /// Movies (mp4, mov, m4v, …) open in the video editor; GIFs are images here.
    nonisolated static func opensInVideoEditor(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie)
    }

    // MARK: Studio

    nonisolated static func isStudioPackage(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == StudioProjectFile.fileExtension
    }

    /// `open-studio?filepath=`: a package opens as is; a video is wrapped in
    /// a package first ("Open in Studio", cursor baked in). A video that is a
    /// History entry's media reuses / records the entry's package.
    func openStudio(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.coordinator.error("studio: no file at \(url.path, privacy: .public)")
            NSSound.beep()
            return
        }
        if Self.isStudioPackage(url) {
            StudioWindowController.open(url: url)
            return
        }
        guard Self.opensInVideoEditor(url) else {
            Log.coordinator.notice("studio: \(url.lastPathComponent, privacy: .public) is not a video or Studio project")
            NSSound.beep()
            return
        }
        let target = url.standardizedFileURL.path
        if let item = await history.recent(filter: .recordings).first(where: { history.mediaURL(for: $0)?.standardizedFileURL.path == target }) {
            await openInStudio(item)
        } else {
            await StudioWindowController.openVideo(url)
        }
    }

    /// History / Quick Access "Open in Studio": the entry's package when it
    /// has one, else its video wrapped in a new package next to it (with the
    /// entry's `events.json` for auto zoom); the package is recorded on the
    /// entry (`studioPackageName`), so History cleanup removes it too.
    func openInStudio(_ item: HistoryItem) async {
        if let package = history.studioPackageURL(for: item), FileManager.default.fileExists(atPath: package.path) {
            StudioWindowController.open(url: package)
            return
        }
        guard !HistoryCardAction.isGIF(item), let media = history.mediaURL(for: item),
              FileManager.default.fileExists(atPath: media.path)
        else {
            Log.coordinator.notice("history entry \(item.id.uuidString, privacy: .public) can't open in Studio")
            NSSound.beep()
            return
        }
        let placement = StudioDocumentOpener.HistoryPlacement(rootURL: history.rootURL, id: item.id, date: item.date)
        let events = item.eventsFileName.map(history.fileURL)
        guard await StudioWindowController.openVideo(media, eventsURL: events, history: placement, scale: item.scale) != nil else { return }
        let name = HistoryLayout.studioPackageName(id: item.id, date: item.date)
        await history.setStudioPackageName(name, for: item.id)
        Log.coordinator.notice("history entry \(item.id.uuidString, privacy: .public) opened in Studio: \(name, privacy: .public)")
    }

    /// Quick Access video card "Open in Studio".
    private func openInStudio(_ request: QuickAccessRecordingRequest) async {
        if let id = request.historyID ?? request.recording.historyID, let item = await history.item(id: id) {
            await openInStudio(item)
            return
        }
        await StudioWindowController.openVideo(request.savedURL ?? request.recording.fileURL, scale: Double(request.recording.raw?.scale ?? 1))
    }

    // MARK: Video editor

    /// `historyID`: the History entry the file came from (its saves are recorded there).
    func openVideoEditor(_ url: URL, historyID: UUID? = nil) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.coordinator.error("video editor: no file at \(url.path, privacy: .public)")
            NSSound.beep()
            return
        }
        guard Self.opensInVideoEditor(url) else {
            Log.coordinator.notice("video editor: \(url.lastPathComponent, privacy: .public) is not a video")
            NSSound.beep()
            return
        }
        VideoEditorWindowController.open(url: url, historyID: historyID)
    }

    /// Menu "Open Video…" / `open-video-editor` without a file.
    private func chooseVideoAndOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.movie] + [UTType(filenameExtension: StudioProjectFile.fileExtension)].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                for url in urls {
                    if Self.isStudioPackage(url) { StudioWindowController.open(url: url) } else { self?.openVideoEditor(url) }
                }
            }
        }
    }

    // MARK: Convert to GIF

    /// Quick Access ⌘G, History "Convert to GIF", `convert-to-gif`: the video
    /// → GIF with Settings › Screen Recording › GIF → History + a new Quick
    /// Access GIF card (`action` `.save` / `.copy`: that instead of the card).
    /// Progress shows on the asking card (`cardID`), else in a small HUD with
    /// Cancel. Over 50 MB (estimated) asks first.
    func convertToGIF(_ source: URL, action: PostCaptureAction? = nil, cardID: UUID? = nil, targetKind: RecordingTargetKind = .area) async {
        let key = source.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            Log.recording.error("convert to GIF: no file at \(source.path, privacy: .public)")
            NSSound.beep()
            return
        }
        guard !gifConversions.contains(key) else {
            Log.recording.notice("convert to GIF: already converting \(source.lastPathComponent, privacy: .public)")
            return
        }
        let options = GIFConversion.options(settings: settings)
        if let bytes = await GIFConversion.estimatedBytes(for: source, options: options),
           GIFConversion.isLarge(bytes), !GIFConversionPrompt.confirmLarge(bytes: bytes) {
            Log.recording.notice("convert to GIF: declined (estimated \(bytes) bytes)")
            return
        }
        gifConversions.insert(key)
        defer { gifConversions.remove(key) }

        let quickAccess = quickAccess
        var hud: GIFProgressHUD?
        let onCard = cardID.map { quickAccess.setConversionProgress(0, for: $0) } ?? false
        let relay = GIFProgressRelay { progress in
            if onCard, let cardID { quickAccess.setConversionProgress(progress, for: cardID) } else { hud?.update(progress) }
        }
        let report = relay.report
        let destination = GIFConversion.newWorkFileURL()
        let started = Date.now
        let task = Task {
            try await GIFConversion.convert(source: source, options: options, to: destination, targetKind: targetKind, progress: report)
        }
        if !onCard {
            let progressHUD = GIFProgressHUD()
            progressHUD.show { task.cancel() }
            hud = progressHUD
        }
        defer {
            relay.finish()
            if let cardID { quickAccess.setConversionProgress(nil, for: cardID) }
            hud?.close()
        }

        let gif: RecordingResult
        do {
            gif = try await task.value
        } catch is CancellationError {
            Log.recording.notice("convert to GIF: cancelled")
            return
        } catch {
            Log.recording.error("convert to GIF failed: \(String(describing: error), privacy: .public)")
            ToastHUD.show(.message("Couldn't convert to GIF"))
            return
        }
        Log.recording.notice("convert to GIF: \(source.lastPathComponent, privacy: .public) -> \(Int(gif.pixelSize.width))x\(Int(gif.pixelSize.height)), \(String(format: "%.2f", gif.duration), privacy: .public) s in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s")
        let outcome = await recording.router.route(gif, overriding: action, config: GIFConversion.deliveryConfig)
        // History (or the saved file) holds the GIF now; drop the work copy.
        if outcome.fileURL != gif.fileURL { try? FileManager.default.removeItem(at: gif.fileURL) }
        Log.recording.notice("convert to GIF: card \(outcome.quickAccessCardID?.uuidString ?? "-", privacy: .public), history \(outcome.historyID?.uuidString ?? "-", privacy: .public), saved \(outcome.savedURL?.path ?? "-", privacy: .public)")
    }

    // MARK: URL scheme

    func handle(url: URL) {
        do {
            let command = try URLSchemeHandler.parse(url)
            Log.urlScheme.notice("\(url.absoluteString, privacy: .public) -> \(command.description, privacy: .public)")
            Task { await perform(command) }
        } catch {
            Log.urlScheme.error("rejected \(url.absoluteString, privacy: .public): \(error.description, privacy: .public)")
        }
    }

    // MARK: Post-capture wiring

    private func connectPostCapture() {
        captureFlow.postCaptureDestinations = PostCaptureDestinations(
            addToHistory: { [weak self] result, savedURL in
                self?.addToHistory(result, savedURL: savedURL)
            },
            showQuickAccess: { [weak self] result, savedURL, historyID in
                guard let self else { return UUID() }
                return self.quickAccess.show(result, savedURL: savedURL, historyID: historyID)
            },
            pin: { [weak self] result in
                self?.pins.pin(result)
            },
            openEditor: { [weak self] result, savedURL, historyID in
                self?.openEditor(result, savedURL: savedURL, historyID: historyID)
            }
        )
    }

    /// Routes a result that didn't come from `CaptureFlowController` (DEBUG samples).
    private func route(_ result: CaptureResult) {
        let router = PostCaptureRouter(settings: settings, destinations: captureFlow.postCaptureDestinations)
        _ = try? router.route(result)
    }

    /// Starts the history write and returns the entry id right away.
    private func addToHistory(_ result: CaptureResult, savedURL: URL?) -> UUID {
        let id = UUID()
        let history = history
        let write = Task { await history.add(result, savedURL: savedURL, id: id) }
        pendingHistoryWrites[id] = write
        Task { [weak self] in
            let item = await write.value
            self?.pendingHistoryWrites[id] = nil
            if item != nil {
                Log.history.notice("recorded capture \(id.uuidString, privacy: .public)")
            }
        }
        return id
    }

    /// Runs `update` on the history entry `id` once its write (if still running) is done.
    private func updateHistory(_ id: UUID, _ update: @escaping @Sendable (HistoryStore) async -> Void) {
        let pending = pendingHistoryWrites[id]
        let history = history
        Task { [weak self] in
            _ = await pending?.value
            await update(history)
            await self?.refreshHistoryClosedState()
        }
    }

    private func refreshHistoryClosedState() async {
        historyHasClosedEntry = await history.lastClosed() != nil
        onMenuStateChanged?()
    }

    // MARK: Quick Access

    private func connectQuickAccess() {
        quickAccess.onPin = { [weak self] result in
            self?.pins.pin(result)
        }
        quickAccess.onEdit = { [weak self] request in
            self?.openEditor(request.result, savedURL: request.savedURL, historyID: request.historyID)
        }
        quickAccess.onHistoryEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .closed(let id):
                updateHistory(id) { await $0.markClosed(id: id) }
            case .saved(let id, let url):
                updateHistory(id) { await $0.setSavedURL(url, for: id) }
            case .restored(let id):
                updateHistory(id) { await $0.markReopened(id: id) }
            }
            onMenuStateChanged?()
        }
    }

    /// Quick Access's in-memory list first; after a relaunch, the newest closed history entry.
    private func restoreLastClosed() async {
        if quickAccess.restoreLastClosed() {
            Log.coordinator.notice("restored the last closed Quick Access card")
            return
        }
        guard let item = await history.lastClosed(), let image = await history.image(for: item),
              !item.kind.isVideo || history.mediaURL(for: item).map({ FileManager.default.fileExists(atPath: $0.path) }) == true
        else {
            Log.coordinator.notice("nothing to restore")
            NSSound.beep()
            return
        }
        await history.markReopened(id: item.id)
        showCard(for: item, image: image)
        Log.coordinator.notice("restored history entry \(item.id.uuidString, privacy: .public)")
        await refreshHistoryClosedState()
    }

    private func showCard(for item: HistoryItem, image: CGImage) {
        let savedURL = item.savedFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if item.kind == .studio {
            // Studio Mode projects have no card (plan §4.14): Restore opens Studio.
            Task { await openInStudio(item) }
            return
        }
        if item.kind.isVideo {
            guard let mediaURL = history.mediaURL(for: item), FileManager.default.fileExists(atPath: mediaURL.path) else {
                Log.coordinator.error("history entry \(item.id.uuidString, privacy: .public) has no media file")
                NSSound.beep()
                return
            }
            quickAccess.show(recording: Self.recordingResult(for: item, mediaURL: mediaURL, thumbnail: image), savedURL: savedURL, historyID: item.id)
            return
        }
        quickAccess.show(item.captureResult(image: image), savedURL: savedURL, historyID: item.id)
    }

    /// A History video / GIF entry as a Quick Access recording (Restore).
    nonisolated static func recordingResult(for item: HistoryItem, mediaURL: URL, thumbnail: CGImage) -> RecordingResult {
        RecordingResult(
            fileURL: mediaURL,
            format: item.mediaFormat == .gif || item.kind == .gif ? .gif : .video,
            duration: item.durationSeconds ?? 0,
            pixelSize: CGSize(width: item.pixelWidth, height: item.pixelHeight),
            thumbnail: thumbnail,
            date: item.date,
            targetKind: .area,
            historyID: item.id
        )
    }

    // MARK: History overlay

    private func connectHistoryOverlay() {
        historyOverlay.onRestore = { [weak self] item, image in
            // The overlay already marked the entry reopened.
            self?.showCard(for: item, image: image)
            Task { await self?.refreshHistoryClosedState() }
        }
        historyOverlay.onPin = { [weak self] item, image in
            guard !item.kind.isVideo else {
                Log.coordinator.notice("pinning a recording isn't supported")
                return
            }
            self?.pins.pin(item.captureResult(image: image))
        }
        historyOverlay.onEdit = { [weak self] item, image in
            if item.kind == .studio {
                Task { await self?.openInStudio(item) }
                return
            }
            guard !item.kind.isVideo else {
                self?.openVideoEditor(for: item)
                return
            }
            let savedURL = item.savedFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            self?.openEditor(item.captureResult(image: image), savedURL: savedURL, historyID: item.id)
        }
        historyOverlay.onOpenInStudio = { [weak self] item in
            Task { await self?.openInStudio(item) }
        }
        historyOverlay.onConvertToGIF = { [weak self] item in
            guard let self, let url = history.mediaURL(for: item) else {
                NSSound.beep()
                return
            }
            Task { await self.convertToGIF(url) }
        }
    }

    /// A History recording in the video editor (GIF entries can't be edited there).
    private func openVideoEditor(for item: HistoryItem) {
        guard !HistoryCardAction.isGIF(item), let url = history.mediaURL(for: item) else {
            Log.coordinator.notice("history entry \(item.id.uuidString, privacy: .public) can't open in the video editor")
            NSSound.beep()
            return
        }
        openVideoEditor(url, historyID: item.id)
    }

    // MARK: Recording

    private func connectRecording() {
        recording.onStateChanged = { [weak self] in self?.onMenuStateChanged?() }
        recording.onPermissionDenied = { [weak self] in
            self?.permissions.refresh()
            self?.showOnboarding()
        }
        let history = history
        recording.router.destinations = RecordingOutputDestinations(
            addToHistory: { [weak self] result, savedURL in
                guard let item = await history.addRecording(result) else { return nil }
                if let savedURL { await history.setSavedURL(savedURL, for: item.id) }
                await self?.refreshHistoryClosedState()
                return (item.id, history.mediaURL(for: item))
            },
            showQuickAccess: { [weak self] result, savedURL in
                self?.quickAccess.show(recording: result, savedURL: savedURL) ?? UUID()
            },
            openVideoEditor: { [weak self] result, savedURL in
                self?.openVideoEditor(savedURL ?? result.fileURL, historyID: result.historyID)
            },
            newStudioPackage: { date in
                let id = UUID()
                guard let url = await history.newStudioPackageURL(id: id, date: date) else { return nil }
                return (id, url)
            },
            addStudioToHistory: { [weak self] id, output, raw in
                let item = await history.addStudioProject(
                    id: id, date: raw.startDate, preview: output.preview, pixelSize: output.project.source.pixelSize,
                    scale: Double(raw.scale), duration: output.project.source.duration
                )
                await self?.refreshHistoryClosedState()
                return item != nil
            },
            openStudio: { url in
                StudioWindowController.open(url: url)
            }
        )
        // Studio editor: Dock icon while open; an export shows a Quick Access card.
        StudioWindowController.activationPolicy = activationPolicy
        StudioWindowController.onExported = { [weak self] result in
            self?.quickAccess.show(recording: result, savedURL: result.fileURL, historyID: nil)
        }
        // Video card Edit / Convert to GIF: set before any `show` (the card's controls read them).
        VideoEditorWindowController.activationPolicy = activationPolicy
        quickAccess.onEditRecording = { [weak self] request in
            self?.openVideoEditor(request.savedURL ?? request.recording.fileURL, historyID: request.historyID ?? request.recording.historyID)
        }
        quickAccess.onOpenInStudio = { [weak self] request in
            Task { await self?.openInStudio(request) }
        }
        quickAccess.onConvertToGIF = { [weak self] request in
            let source = request.savedURL ?? request.recording.fileURL
            Task { await self?.convertToGIF(source, cardID: request.cardID, targetKind: request.recording.targetKind) }
        }
    }

    // MARK: Pins

    private func connectPins() {
        pins.onPinsChanged = { [weak self] in self?.onMenuStateChanged?() }
        pins.onEdit = { content in
            EditorWindowController.open(image: content.image, scale: content.scale)
        }
        pins.onRecognizeText = { content in
            let result = CaptureResult(
                image: content.image, pointSize: content.pointSize, scale: content.scale, mode: .text
            )
            Task { await TextCaptureFlow.handle(result, lineBreaks: true) }
        }
    }

    // MARK: Editor

    private func connectEditor() {
        EditorWindowController.activationPolicy = activationPolicy
        EditorWindowController.onPin = { [weak self] image, size in
            self?.pins.pin(image, pointSize: size)
        }
        EditorDocumentEvents.onSaved = { [weak self] event in
            self?.editorDidSave(event)
        }
        // ⇧⌘I: area capture straight back into the editor that asked (no Quick Access / history).
        EditorViewModel.captureForCombine = { [weak self] deliver in
            guard let self else { return }
            Task {
                guard let result = await self.captureFlow.captureForCombine() else { return }
                NSApp.activate()
                deliver(result.image, result.scale)
            }
        }
    }

    /// Opens a capture in the editor. When its History entry has an editable
    /// project (an earlier editor save), that project opens instead of the
    /// flat image, with every annotation editable (M5 #5).
    func openEditor(_ result: CaptureResult, savedURL: URL?, historyID: UUID?) {
        // A capture whose history write is still running has no project yet.
        guard let historyID, pendingHistoryWrites[historyID] == nil else {
            EditorWindowController.open(result: result, savedURL: savedURL, historyID: historyID)
            return
        }
        Task {
            if let project = await historyProject(for: historyID) {
                if EditorWindowController.open(project: project, projectURL: nil, sourceURL: savedURL, historyID: historyID) != nil {
                    return
                }
            }
            EditorWindowController.open(result: result, savedURL: savedURL, historyID: historyID)
        }
    }

    private func historyProject(for id: UUID) async -> ProjectFile.Contents? {
        _ = await historyProjectWrites[id]?.value
        guard let item = await history.item(id: id), let name = item.projectFileName else { return nil }
        let url = history.fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try await EditorDocumentOpener.readProject(at: url)
        } catch {
            Log.history.error("history project \(name, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Every editor save: keep an editable `.hakoshot` of it in History
    /// (creating an entry for editors that had none) and record the flat file.
    private func editorDidSave(_ event: EditorSaveEvent) -> UUID {
        let id: UUID
        if let existing = event.historyID {
            id = existing
            if let url = event.imageURL {
                updateHistory(id) { await $0.setSavedURL(url, for: id) }
            }
        } else {
            let scale = max(event.scale, 1)
            let base = event.baseImage
            let result = CaptureResult(
                image: base,
                pointSize: CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale),
                scale: scale,
                mode: event.mode,
                date: event.date
            )
            id = addToHistory(result, savedURL: event.imageURL)
        }

        let contents = event.contents
        let history = history
        let pending = pendingHistoryWrites[id]
        let previous = historyProjectWrites[id]
        let write = Task {
            _ = await pending?.value
            _ = await previous?.value
            guard let item = await history.item(id: id) else { return }  // history off
            let name = item.projectFileName ?? HistoryLayout.projectFileName(id: id, date: item.date)
            do {
                try await Self.writeProject(contents, to: history.fileURL(name))
                await history.setProjectFileName(name, for: id)
                Log.history.notice("stored project \(name, privacy: .public) (\(contents.document.annotations.count) annotations)")
            } catch {
                Log.history.error("storing project failed: \(String(describing: error), privacy: .public)")
            }
        }
        historyProjectWrites[id] = write
        Task { [weak self] in
            await write.value
            if self?.historyProjectWrites[id] == write { self?.historyProjectWrites[id] = nil }
        }
        return id
    }

    /// Encodes the package off the main thread.
    private nonisolated static func writeProject(_ contents: ProjectFile.Contents, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try ProjectFile.write(contents.document, assets: contents.assets, to: url)
        }.value
    }

    #if DEBUG
    private func debugSaveSampleProject(to url: URL) {
        guard let controller = EditorDebug.openSample(annotated: true) else { return }
        let saved = controller.model.save(as: .project, to: url)
        Log.coordinator.notice("debug: saved sample project \(url.path, privacy: .public): \(saved), \(controller.model.document.annotations.count) annotations")
        controller.window?.close()
    }
    #endif

    // MARK: Windows

    func showSettings(page: SettingsPage? = nil) {
        let controller = settingsWindowController
            ?? SettingsWindowController(permissions: permissions, activationPolicy: activationPolicy)
        settingsWindowController = controller
        controller.show(page: page)
    }

    /// Shows onboarding on first launch, or whenever Screen Recording is
    /// missing (then on the Screen Recording step).
    func showOnboardingIfNeeded() {
        permissions.refresh()
        let completed = settings.value(for: .onboardingCompleted)
        guard !completed || !permissions.screenRecordingGranted else { return }
        showOnboarding(step: completed ? .screenRecording : .welcome)
    }

    /// `step` `nil` = the permission step when Screen Recording is missing, else the start.
    func showOnboarding(step: OnboardingStep? = nil) {
        permissions.refresh()
        let step = step ?? (permissions.screenRecordingGranted ? .welcome : .screenRecording)
        if let existing = onboardingWindowController {
            existing.present(step: step)
            return
        }
        let controller = OnboardingWindowController(
            permissions: permissions, activationPolicy: activationPolicy, startStep: step
        )
        controller.onClose = { [weak self] in
            self?.settings.set(true, for: .onboardingCompleted)
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.present()
    }
}

extension SettingsKey where Value == Bool {
    /// The onboarding window was closed at least once. Same UserDefaults name as
    /// the M0 `DefaultsKey`, so existing installs keep their value.
    static var onboardingCompleted: SettingsKey<Bool> {
        SettingsKey("onboardingCompleted", default: false)
    }
}
