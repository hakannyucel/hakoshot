import Testing
@testable import HakoKit

@Suite("RecordingSessionState")
struct RecordingSessionStateTests {
    typealias S = RecordingSessionState
    typealias E = RecordingSessionEvent

    /// One representative state per kind.
    static let states: [S] = [.idle, .preparing, .countdown, .recording, .paused, .finalizing, .finished, .discarded, .failed(reason: "boom")]
    /// One representative event per kind.
    static let events: [E] = [.prepare, .beginCountdown, .startRecording, .pause, .resume, .restart, .stop, .finish, .discard, .fail(reason: "disk full"), .reset]

    /// Written out independently of `RecordingSessionState.transitions`.
    static let expected: [S.Kind: [E.Kind: S.Kind]] = [
        .idle: [.prepare: .preparing],
        .preparing: [.beginCountdown: .countdown, .startRecording: .recording, .discard: .discarded, .fail: .failed],
        .countdown: [.startRecording: .recording, .discard: .discarded, .fail: .failed],
        .recording: [.pause: .paused, .restart: .recording, .stop: .finalizing, .discard: .discarded, .fail: .failed],
        .paused: [.resume: .recording, .restart: .recording, .stop: .finalizing, .discard: .discarded, .fail: .failed],
        .finalizing: [.finish: .finished, .fail: .failed],
        .finished: [.reset: .idle],
        .discarded: [.reset: .idle],
        .failed: [.stop: .finalizing, .discard: .discarded, .reset: .idle],
    ]

    @Test func representativesCoverEveryKind() {
        #expect(Set(Self.states.map(\.kind)) == Set(S.Kind.allCases))
        #expect(Set(Self.events.map(\.kind)) == Set(E.Kind.allCases))
    }

    /// All 9 × 11 = 99 (state, event) pairs: valid ones land on the expected
    /// state, invalid ones return nil and leave the state unchanged.
    @Test(arguments: states)
    func everyPair(state: S) {
        for event in Self.events {
            let expectedKind = Self.expected[state.kind]?[event.kind]
            #expect(state.next(on: event)?.kind == expectedKind, "\(state) + \(event)")
            #expect(state.accepts(event) == (expectedKind != nil), "\(state) accepts \(event)")
            var copy = state
            let applied = copy.apply(event)
            #expect(applied == (expectedKind != nil), "\(state) apply \(event)")
            if expectedKind == nil {
                #expect(copy == state, "invalid \(event) changed \(state)")
            } else {
                #expect(copy.kind == expectedKind)
            }
        }
    }

    @Test func tableMatchesExpected() {
        #expect(S.transitions == Self.expected)
        let valid = Self.expected.values.reduce(0) { $0 + $1.count }
        #expect(valid == 25)
        #expect(S.Kind.allCases.count * E.Kind.allCases.count - valid == 74)
    }

    @Test func failureCarriesReason() {
        var state = S.recording
        #expect(step(&state, .fail(reason: "source stopped")))
        #expect(state == .failed(reason: "source stopped"))
        #expect(state.failureReason == "source stopped")
        #expect(state.isTerminal)
        #expect(!state.isActive)
        // Finalize failure keeps its own reason.
        var finalizing = S.finalizing
        _ = step(&finalizing, .fail(reason: "finishWriting"))
        #expect(finalizing.failureReason == "finishWriting")
        #expect(E.fail(reason: "x").failureReason == "x")
        #expect(E.stop.failureReason == nil)
        #expect(S.paused.failureReason == nil)
    }

    @Test func happyPathWithPausesAndRestart() {
        var state = S.idle
        let path: [E] = [.prepare, .beginCountdown, .startRecording, .pause, .resume, .pause, .restart, .pause, .resume, .stop, .finish, .reset]
        var kinds: [S.Kind] = []
        for event in path {
            #expect(step(&state, event), "\(event) from \(state)")
            kinds.append(state.kind)
        }
        #expect(kinds == [.preparing, .countdown, .recording, .paused, .recording, .paused, .recording, .paused, .recording, .finalizing, .finished, .idle])
    }

    @Test func noCountdownAndDiscardDuringCountdown() {
        var state = S.idle
        #expect(step(&state, .prepare))
        #expect(step(&state, .startRecording))
        #expect(state == .recording)

        var counting = S.countdown
        #expect(step(&counting, .discard))
        #expect(counting == .discarded)
        #expect(!step(&counting, .discard)) // already discarded
    }

    @Test func salvageAfterFailure() {
        var state = S.failed(reason: "writer")
        #expect(!step(&state, .pause))
        #expect(!step(&state, .restart))
        #expect(step(&state, .stop))
        #expect(state == .finalizing)
        #expect(step(&state, .finish))
        #expect(state == .finished)
    }

    @Test func flags() {
        #expect(S.recording.isCapturing && S.paused.isCapturing)
        #expect(!S.countdown.isCapturing && !S.finalizing.isCapturing)
        #expect(S.paused.isPaused && !S.recording.isPaused)
        let active = Self.states.filter(\.isActive).map(\.kind)
        #expect(active == [.preparing, .countdown, .recording, .paused, .finalizing])
        let terminal = Self.states.filter(\.isTerminal).map(\.kind)
        #expect(terminal == [.finished, .discarded, .failed])
        #expect(!S.idle.isActive && !S.idle.isTerminal)
    }

    /// `apply` outside `#expect` (the macro can't take a mutating call).
    private func step(_ state: inout S, _ event: E) -> Bool {
        state.apply(event)
    }
}
