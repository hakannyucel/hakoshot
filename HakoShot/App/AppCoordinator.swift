import os
import AppKit
import HakoKit

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

    /// Called when a dynamic menu item may have changed (pins, restorable cards).
    var onMenuStateChanged: (() -> Void)?

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
        desktopIcons: DesktopIconsToggle = .shared
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
    }

    /// Read by the menu each time it opens.
    var menuState: MenuState {
        MenuState(
            desktopIconsHidden: desktopIcons.isHidden,
            hasPins: pins.hasPins,
            hasLockedPins: pins.hasLockedPins,
            hasRecentlyClosed: quickAccess.canRestore || historyHasClosedEntry
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
        }
    }

    #if DEBUG
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

    /// Finder double-click / "Open With" / drop on the app: images and `.hakoshot` projects.
    func openFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                Log.coordinator.notice("open file \(url.lastPathComponent, privacy: .public)")
                await EditorDocumentOpener.open(fileURL: url)
            }
        }
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
        guard let item = await history.lastClosed(), let image = await history.image(for: item) else {
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
        quickAccess.show(item.captureResult(image: image), savedURL: savedURL, historyID: item.id)
    }

    // MARK: History overlay

    private func connectHistoryOverlay() {
        historyOverlay.onRestore = { [weak self] item, image in
            // The overlay already marked the entry reopened.
            self?.showCard(for: item, image: image)
            Task { await self?.refreshHistoryClosedState() }
        }
        historyOverlay.onPin = { [weak self] item, image in
            self?.pins.pin(item.captureResult(image: image))
        }
        historyOverlay.onEdit = { [weak self] item, image in
            let savedURL = item.savedFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            self?.openEditor(item.captureResult(image: image), savedURL: savedURL, historyID: item.id)
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
