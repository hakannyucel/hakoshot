import CoreGraphics
import Foundation
import HakoKit
import Observation
import os

/// One recording session for the UI (plan §2.2, §4.6): wraps
/// `RecordingEngine` with the HakoKit `RecordingSessionState` machine, a live
/// elapsed time (≈10×/s, pauses excluded) and the engine stats.
///
/// The coordinator drives it (`prepare` → `beginCountdown` → `start` →
/// `stop` / `discard`); the control bar binds to `state`, `elapsed`, `stats`
/// and calls `togglePause`, `restart`, `stop`, `discard`. UI-agnostic: no
/// windows, no confirmation dialogs.
///
/// Invalid actions for the current state are no-ops (logged) and return
/// `false` / throw `RecordingError.invalidState`.
@MainActor
@Observable
final class RecordingSession {
    private(set) var state: RecordingSessionState = .idle
    /// Media seconds recorded so far (pauses excluded; reset by `restart`).
    private(set) var elapsed: Double = 0
    private(set) var stats: RecordingStats = .zero
    private(set) var handle: RecordingHandle?
    /// The raw recording after a successful `stop`.
    private(set) var result: RawRecording?
    /// The error that moved the session to `.failed`.
    private(set) var lastError: RecordingError?

    /// Called on the main actor when the source or writer fails while
    /// capturing. The state is `.failed` then; the engine session is still
    /// open: call `stop()` to keep what was written or `discard()`.
    @ObservationIgnored var onUnexpectedStop: ((RecordingError) -> Void)?
    /// Called on every state change (old, new), e.g. for the menu bar timer.
    @ObservationIgnored var onStateChange: ((RecordingSessionState, RecordingSessionState) -> Void)?

    @ObservationIgnored let engine: RecordingEngine
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The engine holds a session for us (between `engine.start` and a
    /// finished `stop` / `discard`).
    @ObservationIgnored private var engineOpen = false

    init(engine: RecordingEngine = .shared, tickInterval: Duration = .milliseconds(100)) {
        self.engine = engine
        self.tickInterval = tickInterval
    }

    // MARK: Flow (coordinator)

    /// idle → preparing (target chosen; HUD, permissions, environment next).
    /// A finished / discarded / failed session is reset first.
    @discardableResult
    func prepare() -> Bool {
        if state.isTerminal, !engineMayBeOpen { resetToIdle() }
        return send(.prepare)
    }

    /// preparing → countdown.
    @discardableResult
    func beginCountdown() -> Bool {
        send(.beginCountdown)
    }

    /// Starts the engine (from idle, preparing or countdown) and waits for the
    /// first frame. The state becomes `.recording` once the engine runs.
    @discardableResult
    func start(_ request: RecordingRequest, overlayWindowIDs: [CGWindowID] = []) async throws -> RecordingHandle {
        if state == .idle || (state.isTerminal && !engineMayBeOpen) { prepare() }
        guard state == .preparing || state == .countdown else {
            throw invalid("start")
        }
        result = nil
        lastError = nil
        elapsed = 0
        stats = .zero
        await engine.setUnexpectedStopHandler { [weak self] error in
            Task { @MainActor in self?.handleUnexpectedStop(error) }
        }
        let handle: RecordingHandle
        do {
            handle = try await engine.start(request, overlayWindowIDs: overlayWindowIDs)
        } catch {
            let recordingError = (error as? RecordingError) ?? .sourceFailed(error.localizedDescription)
            lastError = recordingError
            send(.fail(reason: recordingError.description))
            throw recordingError
        }
        // A discard while the engine was starting wins.
        guard state == .preparing || state == .countdown else {
            await engine.discard()
            Log.recording.notice("session: discarded while starting")
            throw RecordingError.cancelled
        }
        self.handle = handle
        engineOpen = true
        send(.startRecording)
        startTicker()
        _ = await engine.waitForFirstFrame()
        return handle
    }

    // MARK: Actions (control bar, URL commands)

    /// recording → paused. `false` when not recording.
    @discardableResult
    func pause() async -> Bool {
        guard send(.pause) else { return false }
        do {
            try await engine.pause()
        } catch {
            fail(error)
            return false
        }
        await refresh()
        return true
    }

    /// paused → recording. `false` when not paused.
    @discardableResult
    func resume() async -> Bool {
        guard send(.resume) else { return false }
        do {
            try await engine.resume()
        } catch {
            fail(error)
            return false
        }
        await refresh()
        return true
    }

    /// Pause ⇄ resume; `false` when neither applies.
    @discardableResult
    func togglePause() async -> Bool {
        switch state {
        case .recording: return await pause()
        case .paused: return await resume()
        default:
            Log.recording.notice("session: togglePause ignored in \(String(describing: self.state), privacy: .public)")
            return false
        }
    }

    /// Throws away the recording so far and starts a fresh file with the same
    /// target (recording or paused → recording). Elapsed time restarts at 0.
    func restart() async throws {
        guard send(.restart) else { throw invalid("restart") }
        elapsed = 0
        do {
            try await engine.restart()
        } catch {
            fail(error)
            throw error
        }
        _ = await engine.waitForFirstFrame()
        await refresh()
    }

    /// Stops and finalizes (recording, paused, or failed to salvage what was
    /// written) → finished. Throws engine errors (state `.failed`).
    func stop() async throws -> RawRecording {
        guard send(.stop) else { throw invalid("stop") }
        stopTicker()
        await refresh()
        defer { engineOpen = false }
        do {
            let raw = try await engine.stop()
            result = raw
            elapsed = raw.duration
            stats.duration = raw.duration
            stats.isPaused = false
            send(.finish)
            return raw
        } catch {
            let recordingError = (error as? RecordingError) ?? .finalizeFailed(error.localizedDescription)
            lastError = recordingError
            send(.fail(reason: recordingError.description))
            throw recordingError
        }
    }

    /// Stops and deletes the session folder (any state before a result, or
    /// failed) → discarded. `false` when there is nothing to discard.
    @discardableResult
    func discard() async -> Bool {
        guard send(.discard) else { return false }
        stopTicker()
        await engine.discard()
        engineOpen = false
        elapsed = 0
        stats = .zero
        handle = nil
        return true
    }

    /// finished / discarded / failed → idle (clears the values).
    func reset() {
        guard state.isTerminal else { return }
        resetToIdle()
    }

    // MARK: Internals

    /// `.failed` after a capture error keeps the engine session open.
    private var engineMayBeOpen: Bool { state.kind == .failed && engineOpen }

    private func resetToIdle() {
        stopTicker()
        send(.reset)
        elapsed = 0
        stats = .zero
        handle = nil
        result = nil
        lastError = nil
    }

    @discardableResult
    private func send(_ event: RecordingSessionEvent) -> Bool {
        let old = state
        guard state.apply(event) else {
            Log.recording.notice("session: \(String(describing: event), privacy: .public) ignored in \(String(describing: old), privacy: .public)")
            return false
        }
        if old != state { onStateChange?(old, state) }
        return true
    }

    private func invalid(_ action: String) -> RecordingError {
        .invalidState("\(action) in \(state)")
    }

    private func fail(_ error: any Error) {
        let recordingError = (error as? RecordingError) ?? .writerFailed(error.localizedDescription)
        lastError = recordingError
        stopTicker()
        send(.fail(reason: recordingError.description))
    }

    private func handleUnexpectedStop(_ error: RecordingError) {
        guard state.isCapturing else { return }
        lastError = error
        stopTicker()
        send(.fail(reason: error.description))
        onUnexpectedStop?(error)
    }

    private func startTicker() {
        stopTicker()
        let interval = tickInterval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Pulls the engine stats (elapsed = media duration, pauses excluded).
    func refresh() async {
        guard state.isCapturing else { return }
        let latest = await engine.stats
        // The state may have moved on while awaiting (stop / discard).
        guard state.isCapturing else { return }
        stats = latest
        elapsed = latest.duration
    }
}

#if DEBUG
extension RecordingSession {
    /// `debug-recording-state?out=<json>` payload.
    struct DebugSnapshot: Codable, Equatable {
        var state: String
        var failureReason: String?
        var elapsed: Double
        var isPaused: Bool
        var framesWritten: Int
        var droppedFrames: Int
        var fileSize: Int64
        /// Pause intervals so far (host seconds), from the engine timeline.
        var pauses: [[Double]]
        var sessionFolder: String?
        var resultFile: String?
    }

    func debugSnapshot() async -> DebugSnapshot {
        await refresh()
        let timeline = await engine.timeline
        var pauses = timeline?.pauses.map { [$0.lowerBound, $0.upperBound] } ?? []
        if let open = timeline?.openPauseStart { pauses.append([open]) }
        return DebugSnapshot(
            state: state.kind.rawValue,
            failureReason: state.failureReason,
            elapsed: elapsed,
            isPaused: state.isPaused,
            framesWritten: stats.framesWritten,
            droppedFrames: stats.droppedFrames,
            fileSize: stats.fileSize,
            pauses: pauses,
            sessionFolder: handle?.sessionFolder.path,
            resultFile: result?.screenURL.path
        )
    }

    /// Writes `debugSnapshot()` as pretty JSON to `url`.
    func writeDebugState(to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(await debugSnapshot())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
#endif
