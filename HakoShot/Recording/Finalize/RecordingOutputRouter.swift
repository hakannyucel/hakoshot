import Foundation
import HakoKit
import os

/// What `RecordingOutputRouter` does with one finished recording, before any
/// file work (pure, tested).
nonisolated struct RecordingOutputDecision: Sendable, Equatable {
    var save = false
    var copy = false
    var showQuickAccess = false
    var openVideoEditor = false

    /// - No override: Settings > General > After recording.
    /// - `.save`: save only. `.copy`: copy only (+ save when "copy also saves"
    ///   is on). No card for either, like `PostCaptureRouter`.
    /// - `.pin` / `.annotate` don't apply to videos: the settings decide.
    /// - "Open Video Editor" applies to videos only (the editor can't open GIFs).
    static func make(
        config: AfterRecordingConfig,
        override: PostCaptureAction?,
        copyAlsoSaves: Bool,
        format: RecordingFormat = .video
    ) -> RecordingOutputDecision {
        switch override {
        case .save:
            return RecordingOutputDecision(save: true)
        case .copy:
            return RecordingOutputDecision(save: copyAlsoSaves, copy: true)
        case .pin, .annotate, nil:
            return RecordingOutputDecision(
                save: config.saveToDisk,
                copy: config.copyToClipboard,
                showQuickAccess: config.showQuickAccess,
                openVideoEditor: config.openVideoEditor && format == .video
            )
        }
    }
}

/// What the router actually did.
nonisolated struct RecordingOutputOutcome: Sendable, Equatable {
    var savedURL: URL?
    var copiedToClipboard = false
    var historyID: UUID?
    var quickAccessCardID: UUID?
    /// Where the delivered file lives after routing (history copy or the
    /// retained temp copy); the Quick Access card uses it.
    var fileURL: URL?
}

/// Targets connected by `AppCoordinator`; `nil` = unavailable (tests).
struct RecordingOutputDestinations {
    /// Adds the recording to History; returns the entry id and its media copy,
    /// or `nil` when History is off or the write failed.
    var addToHistory: ((RecordingResult, _ savedURL: URL?) async -> (id: UUID, mediaURL: URL?)?)?
    var showQuickAccess: ((RecordingResult, _ savedURL: URL?) -> UUID)?
    /// The classic video editor (After recording "Open Video Editor").
    var openVideoEditor: ((RecordingResult, _ savedURL: URL?) -> Void)?

    // Studio Mode recordings (plan §4.14, R6.3).

    /// A new History entry id and where its package goes (the entry's
    /// `studioPackageName`); `nil` = History off (the package goes to
    /// `StudioDocumentOpener.defaultFolder`).
    var newStudioPackage: ((_ date: Date) async -> (id: UUID, url: URL)?)?
    /// Indexes the finished package as a `.studio` History entry.
    var addStudioToHistory: ((_ id: UUID, StudioRecordingFinalizer.Output, RawRecording) async -> Bool)?
    /// Opens the package in the Studio editor.
    var openStudio: ((URL) -> Void)?

    init(
        addToHistory: ((RecordingResult, URL?) async -> (id: UUID, mediaURL: URL?)?)? = nil,
        showQuickAccess: ((RecordingResult, URL?) -> UUID)? = nil,
        openVideoEditor: ((RecordingResult, URL?) -> Void)? = nil,
        newStudioPackage: ((Date) async -> (id: UUID, url: URL)?)? = nil,
        addStudioToHistory: ((UUID, StudioRecordingFinalizer.Output, RawRecording) async -> Bool)? = nil,
        openStudio: ((URL) -> Void)? = nil
    ) {
        self.addToHistory = addToHistory
        self.showQuickAccess = showQuickAccess
        self.openVideoEditor = openVideoEditor
        self.newStudioPackage = newStudioPackage
        self.addStudioToHistory = addStudioToHistory
        self.openStudio = openStudio
    }
}

/// Routes a finalized recording (kayit-teknik-plan §2.2, §4.15): save → copy
/// → History (always) → Quick Access → video editor; then deletes the session
/// folder. The delivered file keeps living as the History copy, or (History
/// off) as a copy in `retainedFolder`, so the Quick Access card and the
/// clipboard stay valid.
final class RecordingOutputRouter {
    var destinations: RecordingOutputDestinations

    private let settings: AppSettings
    private let clipboardWriter: ClipboardWriter
    private let retainedFolder: URL
    private let dragFolder: URL

    /// `~/Library/Caches/HakoShot/Recordings/`: recordings kept for a card
    /// while History is off.
    nonisolated static var defaultRetainedFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "HakoShot/Recordings", directoryHint: .isDirectory)
    }

    init(
        settings: AppSettings,
        clipboardWriter: ClipboardWriter = ClipboardWriter(),
        destinations: RecordingOutputDestinations = RecordingOutputDestinations(),
        retainedFolder: URL = RecordingOutputRouter.defaultRetainedFolder,
        dragFolder: URL = DragSource.dragDirectory
    ) {
        self.settings = settings
        self.clipboardWriter = clipboardWriter
        self.destinations = destinations
        self.retainedFolder = retainedFolder
        self.dragFolder = dragFolder
    }

    /// Never throws: a failing step is logged and left out of the outcome.
    /// `config` `nil` = Settings › General › After recording; converted GIFs
    /// pass `GIFConversion.deliveryConfig` (card only).
    @discardableResult
    func route(
        _ result: RecordingResult,
        overriding override: PostCaptureAction? = nil,
        config: AfterRecordingConfig? = nil
    ) async -> RecordingOutputOutcome {
        let decision = RecordingOutputDecision.make(
            config: config ?? AfterRecordingConfig(settings: settings),
            override: override,
            copyAlsoSaves: settings.value(for: .outputCopyAlsoSavesToDisk),
            format: result.format
        )
        if override == .pin || override == .annotate {
            Log.recording.notice("route: action=\(override?.rawValue ?? "", privacy: .public) doesn't apply to recordings; using After recording settings")
        }
        var outcome = RecordingOutputOutcome()
        var result = result

        if decision.save {
            outcome.savedURL = save(result)
        }

        // History copy first, so the card and clipboard point at a file that outlives the session folder.
        if let addToHistory = destinations.addToHistory, let entry = await addToHistory(result, outcome.savedURL) {
            outcome.historyID = entry.id
            result.historyID = entry.id
            if let mediaURL = entry.mediaURL, FileManager.default.fileExists(atPath: mediaURL.path) {
                result.fileURL = mediaURL
            }
        }
        if Self.isInsideSessionFolder(result.fileURL, of: result), let retained = retain(result.fileURL) {
            result.fileURL = retained
        }
        outcome.fileURL = result.fileURL

        if decision.copy {
            outcome.copiedToClipboard = copy(result, savedURL: outcome.savedURL)
        }
        if decision.showQuickAccess, let show = destinations.showQuickAccess {
            outcome.quickAccessCardID = show(result, outcome.savedURL)
        }
        if decision.openVideoEditor {
            if let open = destinations.openVideoEditor {
                open(result, outcome.savedURL)
            } else {
                Log.recording.notice("after recording: Open Video Editor is on but no editor is connected")
            }
        }

        cleanUpSession(of: result)
        Log.recording.notice("routed \(result.format.rawValue, privacy: .public): saved \(outcome.savedURL?.lastPathComponent ?? "-", privacy: .public), copied \(outcome.copiedToClipboard), history \(outcome.historyID?.uuidString ?? "-", privacy: .public), card \(outcome.quickAccessCardID != nil)")
        return outcome
    }

    // MARK: Studio

    /// What `routeStudio` did.
    struct StudioOutcome: Sendable {
        var packageURL: URL
        var historyID: UUID?
        var output: StudioRecordingFinalizer.Output
    }

    /// Studio Mode recording (plan §4.14): `.hakostudio` package → History
    /// (`.studio` entry, package next to it; History off → the Studio folder)
    /// → the Studio editor (no Quick Access card, no save / copy). The
    /// session folder is deleted afterwards. Throws when the package can't be
    /// made; the session folder then still holds `screen.mov`, so the caller
    /// can fall back to a classic video.
    @discardableResult
    func routeStudio(
        _ raw: RawRecording,
        defaults: StudioProjectDefaults,
        overriding override: PostCaptureAction? = nil,
        opensEditor: Bool = true
    ) async throws -> StudioOutcome {
        if let override {
            Log.recording.notice("route studio: action=\(override.rawValue, privacy: .public) doesn't apply to Studio projects; opening Studio")
        }
        let entry = await destinations.newStudioPackage?(raw.startDate)
        let packageURL = entry?.url ?? Self.studioFallbackURL(date: raw.startDate)
        let output = try await StudioRecordingFinalizer.makePackage(from: raw, defaults: defaults, at: packageURL)
        var historyID: UUID?
        if let entry, let add = destinations.addStudioToHistory, await add(entry.id, output, raw) {
            historyID = entry.id
        }
        try? FileManager.default.removeItem(at: raw.sessionFolder)
        if opensEditor {
            if let open = destinations.openStudio {
                open(packageURL)
            } else {
                Log.recording.notice("route studio: no Studio editor connected")
            }
        }
        Log.recording.notice("routed studio: \(packageURL.path, privacy: .public), history \(historyID?.uuidString ?? "-", privacy: .public)")
        return StudioOutcome(packageURL: packageURL, historyID: historyID, output: output)
    }

    /// History off: `~/Library/Application Support/HakoShot/Studio/Studio Recording <date>.hakostudio` (never overwrites).
    nonisolated static func studioFallbackURL(date: Date, folder: URL = StudioDocumentOpener.defaultFolder) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Studio Recording \(formatter.string(from: date))"
        let ext = StudioProjectFile.fileExtension
        var url = folder.appending(path: "\(base).\(ext)", directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(n)).\(ext)", directoryHint: .isDirectory)
            n += 1
        }
        return url
    }

    // MARK: Steps

    /// Export folder + file name template, `.mp4`/`.gif`, never overwrites.
    private func save(_ result: RecordingResult) -> URL? {
        let folder = URL(
            fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let pattern = settings.value(for: .outputFileNameTemplate)
        let counter = FileNameCounter.take(pattern: pattern, settings: settings)
        do {
            let url = try RecordingFileExport.copy(
                result, toFolder: folder, template: FileNameTemplate(pattern: pattern), counter: counter
            )
            Log.recording.notice("saved recording \(url.path, privacy: .public)")
            return url
        } catch {
            Log.recording.error("saving recording failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// File URL on the pasteboard: the saved file, else a template-named link to the kept copy.
    private func copy(_ result: RecordingResult, savedURL: URL?) -> Bool {
        var url = savedURL ?? result.fileURL
        if savedURL == nil {
            let template = FileNameTemplate(pattern: settings.value(for: .outputFileNameTemplate))
            if let named = try? RecordingFileExport.writeDragFile(for: result, template: template, in: dragFolder) {
                url = named
            }
        }
        let copied = clipboardWriter.writeFile(url: url)
        if !copied { Log.recording.error("copying recording to the clipboard failed") }
        return copied
    }

    /// Moves the file out of the session folder (History off / failed).
    private func retain(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        let destination = retainedFolder.appending(path: "\(UUID().uuidString).\(url.pathExtension)")
        do {
            try fileManager.createDirectory(at: retainedFolder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            Log.recording.error("keeping the recording failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func cleanUpSession(of result: RecordingResult) {
        guard let folder = result.raw?.sessionFolder else { return }
        guard !Self.isInsideSessionFolder(result.fileURL, of: result) else {
            Log.recording.error("session folder kept: the recording is still inside it")
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    nonisolated static func isInsideSessionFolder(_ url: URL, of result: RecordingResult) -> Bool {
        guard let folder = result.raw?.sessionFolder else { return false }
        let folderPath = folder.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }

    /// Deletes retained copies older than `maxAge` (History-off recordings).
    nonisolated static func purgeRetainedFiles(in folder: URL = defaultRetainedFolder, olderThan maxAge: TimeInterval = 7 * 24 * 3600) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date.now.addingTimeInterval(-maxAge)
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fileManager.removeItem(at: file) }
        }
    }
}
