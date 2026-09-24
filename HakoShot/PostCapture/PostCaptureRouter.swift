import CoreGraphics
import Foundation
import os

/// What `PostCaptureRouter.route(_:overriding:)` actually did with one capture.
struct PostCaptureOutcome: Sendable, Equatable {
    var savedURL: URL?
    var copiedToClipboard: Bool
    /// `HistoryStore` entry id (the write finishes asynchronously; `nil` when
    /// no history destination is connected).
    var historyID: UUID?
    /// Quick Access card id, if a card was shown.
    var quickAccessCardID: UUID?
    var pinned: Bool
    var openedInEditor: Bool

    init(
        savedURL: URL? = nil,
        copiedToClipboard: Bool = false,
        historyID: UUID? = nil,
        quickAccessCardID: UUID? = nil,
        pinned: Bool = false,
        openedInEditor: Bool = false
    ) {
        self.savedURL = savedURL
        self.copiedToClipboard = copiedToClipboard
        self.historyID = historyID
        self.quickAccessCardID = quickAccessCardID
        self.pinned = pinned
        self.openedInEditor = openedInEditor
    }

    static let none = PostCaptureOutcome()
}

/// Errors surfaced when an *explicitly requested* action fails outright.
enum PostCaptureRouterError: Error, Sendable {
    case saveFailed(underlying: any Error)
    case clipboardFailed(underlying: any Error)
}

/// The UI/persistence targets a capture can go to. Connected by
/// `AppCoordinator`; a `nil` destination is simply unavailable (tests leave
/// them all `nil`).
struct PostCaptureDestinations {
    /// Records the capture in history and returns its entry id (the write may
    /// finish later). Called for every routed capture.
    var addToHistory: ((CaptureResult, _ savedURL: URL?) -> UUID?)?
    /// Shows a Quick Access card; returns the card id.
    var showQuickAccess: ((CaptureResult, _ savedURL: URL?, _ historyID: UUID?) -> UUID)?
    var pin: ((CaptureResult) -> Void)?
    /// Opens the annotation editor with the saved file and History entry (if any).
    var openEditor: ((CaptureResult, _ savedURL: URL?, _ historyID: UUID?) -> Void)?

    init(
        addToHistory: ((CaptureResult, URL?) -> UUID?)? = nil,
        showQuickAccess: ((CaptureResult, URL?, UUID?) -> UUID)? = nil,
        pin: ((CaptureResult) -> Void)? = nil,
        openEditor: ((CaptureResult, URL?, UUID?) -> Void)? = nil
    ) {
        self.addToHistory = addToHistory
        self.showQuickAccess = showQuickAccess
        self.pin = pin
        self.openEditor = openEditor
    }
}

/// Routes one finished `CaptureResult` to its after-capture destinations (plan
/// §3.3): file / clipboard, history (always), Quick Access, Pin, editor.
///
/// - No override: Settings > General > After capture (`AfterCaptureConfig`,
///   default "Show Quick Access" only). Order: save → copy → history → Quick
///   Access → pin → editor, so later steps see the saved file.
/// - `.save` / `.copy` override (`hakoshot://…?action=`): exactly that, no card.
///   `.copy` also saves when `outputCopyAlsoSavesToDisk` is on.
/// - `.pin` override: pin only. `.annotate`: editor only (falls back to the
///   default route when no editor destination is connected).
final class PostCaptureRouter {
    var destinations: PostCaptureDestinations

    private let settings: AppSettings
    private let outputService: OutputService
    private let clipboardWriter: ClipboardWriter

    init(
        settings: AppSettings,
        outputService: OutputService? = nil,
        clipboardWriter: ClipboardWriter = ClipboardWriter(),
        destinations: PostCaptureDestinations = PostCaptureDestinations()
    ) {
        self.settings = settings
        self.outputService = outputService ?? OutputService(settings: settings)
        self.clipboardWriter = clipboardWriter
        self.destinations = destinations
    }

    /// Performs the after-capture actions for `result` and reports what happened.
    ///
    /// - An *explicit* `.save`/`.copy` override throws `PostCaptureRouterError`
    ///   if that specific action fails: the caller asked for exactly one thing.
    /// - The default route never throws: a failing step is logged and left out
    ///   of the outcome, so e.g. an unwritable folder doesn't cancel the card.
    @discardableResult
    func route(_ result: CaptureResult, overriding override: PostCaptureAction? = nil) throws -> PostCaptureOutcome {
        switch override {
        case .save:
            var outcome = PostCaptureOutcome(savedURL: try performSave(result))
            outcome.historyID = addToHistory(result, savedURL: outcome.savedURL)
            return outcome

        case .copy:
            var outcome = PostCaptureOutcome()
            if settings.value(for: .outputCopyAlsoSavesToDisk) {
                outcome.savedURL = try? performSave(result)
            }
            outcome.copiedToClipboard = try performCopy(result, fileURL: outcome.savedURL)
            outcome.historyID = addToHistory(result, savedURL: outcome.savedURL)
            return outcome

        case .pin:
            guard let pin = destinations.pin else {
                Log.postCapture.notice("route: pin unavailable, using the after-capture settings")
                return defaultRoute(result)
            }
            var outcome = PostCaptureOutcome()
            outcome.historyID = addToHistory(result, savedURL: nil)
            pin(result)
            outcome.pinned = true
            return outcome

        case .annotate:
            guard let openEditor = destinations.openEditor else {
                Log.postCapture.notice("route: editor not connected, using the after-capture settings")
                return defaultRoute(result)
            }
            var outcome = PostCaptureOutcome()
            outcome.historyID = addToHistory(result, savedURL: nil)
            openEditor(result, nil, outcome.historyID)
            outcome.openedInEditor = true
            return outcome

        case nil:
            return defaultRoute(result)
        }
    }

    private func defaultRoute(_ result: CaptureResult) -> PostCaptureOutcome {
        let config = AfterCaptureConfig(settings: settings)
        var outcome = PostCaptureOutcome()

        if config.saveToDisk {
            do {
                outcome.savedURL = try performSave(result)
            } catch {
                Log.postCapture.error("default save failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.copyToClipboard {
            do {
                outcome.copiedToClipboard = try performCopy(result, fileURL: outcome.savedURL)
            } catch {
                Log.postCapture.error("default copy failed: \(String(describing: error), privacy: .public)")
            }
        }

        outcome.historyID = addToHistory(result, savedURL: outcome.savedURL)

        if config.showQuickAccess, let show = destinations.showQuickAccess {
            outcome.quickAccessCardID = show(result, outcome.savedURL, outcome.historyID)
        }
        if config.pin, let pin = destinations.pin {
            pin(result)
            outcome.pinned = true
        }
        if config.openEditor {
            if let openEditor = destinations.openEditor {
                openEditor(result, outcome.savedURL, outcome.historyID)
                outcome.openedInEditor = true
            } else {
                Log.postCapture.notice("after capture: open editor is on but no editor is connected")
            }
        }
        return outcome
    }

    private func addToHistory(_ result: CaptureResult, savedURL: URL?) -> UUID? {
        destinations.addToHistory?(result, savedURL)
    }

    private func performSave(_ result: CaptureResult) throws -> URL {
        do {
            return try outputService.save(result)
        } catch {
            throw PostCaptureRouterError.saveFailed(underlying: error)
        }
    }

    private func performCopy(_ result: CaptureResult, fileURL: URL?) throws -> Bool {
        do {
            return try clipboardWriter.write(result.image, fileURL: fileURL)
        } catch {
            throw PostCaptureRouterError.clipboardFailed(underlying: error)
        }
    }
}
