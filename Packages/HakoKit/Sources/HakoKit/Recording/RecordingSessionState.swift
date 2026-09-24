/// Lifecycle of one recording session (plan §4.6, R1.3).
///
/// ```
/// idle → preparing → countdown → recording ⇄ paused → finalizing → finished
///           └──────────────────→ recording
/// recording | paused ──restart──→ recording
/// preparing | countdown | recording | paused ──discard──→ discarded
/// preparing … finalizing ──fail──→ failed
/// failed ──stop──→ finalizing (salvage what was written) | ──discard──→ discarded
/// finished | discarded | failed ──reset──→ idle
/// ```
///
/// Pure value type: `RecordingSession` (app) applies events and drives the
/// engine. An invalid event leaves the state unchanged (`apply` returns
/// `false`; the caller logs it).
public enum RecordingSessionState: Hashable, Sendable {
    /// No session.
    case idle
    /// Target chosen, HUD / permissions / environment being set up.
    case preparing
    /// Countdown before the first frame.
    case countdown
    case recording
    case paused
    /// Stopping the source and finalizing the file.
    case finalizing
    /// The raw recording was written.
    case finished
    /// Thrown away by the user (folder removed).
    case discarded
    /// Source, writer or finalize error. The engine session may still be open:
    /// `stop` salvages what was written, `discard` throws it away.
    case failed(reason: String)

    /// Payload-free case, for tables and tests.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case idle, preparing, countdown, recording, paused, finalizing, finished, discarded, failed
    }

    public var kind: Kind {
        switch self {
        case .idle: .idle
        case .preparing: .preparing
        case .countdown: .countdown
        case .recording: .recording
        case .paused: .paused
        case .finalizing: .finalizing
        case .finished: .finished
        case .discarded: .discarded
        case .failed: .failed
        }
    }

    /// The failure reason in `.failed`.
    public var failureReason: String? {
        if case let .failed(reason) = self { return reason }
        return nil
    }

    /// The engine is capturing (recording or paused): the session UI is up.
    public var isCapturing: Bool { self == .recording || self == .paused }

    /// A session is in progress (anything between `idle` and a result).
    public var isActive: Bool {
        switch kind {
        case .preparing, .countdown, .recording, .paused, .finalizing: true
        case .idle, .finished, .discarded, .failed: false
        }
    }

    /// Ended: only `reset` (or cleanup from `failed`) leaves it.
    public var isTerminal: Bool {
        switch kind {
        case .finished, .discarded, .failed: true
        default: false
        }
    }

    public var isPaused: Bool { self == .paused }

    /// The state after `event`, or `nil` when the event is invalid here.
    public func next(on event: RecordingSessionEvent) -> RecordingSessionState? {
        guard let target = Self.transitions[kind]?[event.kind] else { return nil }
        switch target {
        case .idle: return .idle
        case .preparing: return .preparing
        case .countdown: return .countdown
        case .recording: return .recording
        case .paused: return .paused
        case .finalizing: return .finalizing
        case .finished: return .finished
        case .discarded: return .discarded
        case .failed: return .failed(reason: event.failureReason ?? "")
        }
    }

    /// Applies `event`; returns `false` (state unchanged) when it is invalid.
    @discardableResult
    public mutating func apply(_ event: RecordingSessionEvent) -> Bool {
        guard let next = next(on: event) else { return false }
        self = next
        return true
    }

    public func accepts(_ event: RecordingSessionEvent) -> Bool {
        Self.transitions[kind]?[event.kind] != nil
    }

    /// Every valid transition: state → event → next state. Anything missing
    /// is invalid.
    public static let transitions: [Kind: [RecordingSessionEvent.Kind: Kind]] = [
        .idle: [
            .prepare: .preparing,
        ],
        .preparing: [
            .beginCountdown: .countdown,
            .startRecording: .recording,
            .discard: .discarded,
            .fail: .failed,
        ],
        .countdown: [
            .startRecording: .recording,
            .discard: .discarded,
            .fail: .failed,
        ],
        .recording: [
            .pause: .paused,
            .restart: .recording,
            .stop: .finalizing,
            .discard: .discarded,
            .fail: .failed,
        ],
        .paused: [
            .resume: .recording,
            .restart: .recording,
            .stop: .finalizing,
            .discard: .discarded,
            .fail: .failed,
        ],
        .finalizing: [
            .finish: .finished,
            .fail: .failed,
        ],
        .finished: [
            .reset: .idle,
        ],
        .discarded: [
            .reset: .idle,
        ],
        .failed: [
            .stop: .finalizing,
            .discard: .discarded,
            .reset: .idle,
        ],
    ]
}

/// Inputs of `RecordingSessionState`.
public enum RecordingSessionEvent: Hashable, Sendable {
    /// A recording flow starts (target chosen).
    case prepare
    case beginCountdown
    /// The engine started capturing.
    case startRecording
    case pause
    case resume
    /// Throw away what was recorded, start a fresh file (same target).
    case restart
    /// Stop and finalize.
    case stop
    /// Finalize succeeded.
    case finish
    case discard
    case fail(reason: String)
    /// Back to `idle` after a result.
    case reset

    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case prepare, beginCountdown, startRecording, pause, resume, restart, stop, finish, discard, fail, reset
    }

    public var kind: Kind {
        switch self {
        case .prepare: .prepare
        case .beginCountdown: .beginCountdown
        case .startRecording: .startRecording
        case .pause: .pause
        case .resume: .resume
        case .restart: .restart
        case .stop: .stop
        case .finish: .finish
        case .discard: .discard
        case .fail: .fail
        case .reset: .reset
        }
    }

    public var failureReason: String? {
        if case let .fail(reason) = self { return reason }
        return nil
    }
}
