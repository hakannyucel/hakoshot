import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Synchronization
import Testing
@testable import HakoShot

// R5.1 input recording: EventRecorder driven by a fake engine timeline and
// injected events (no real monitors, no TCC prompt). Real-tap check only
// runs when Input Monitoring is already granted (preflight only).

/// Engine timeline stand-in, changeable between refreshes.
nonisolated final class FakeTimeline: Sendable {
    private let state: Mutex<RecordingTimeline?>
    init(_ timeline: RecordingTimeline?) { state = Mutex(timeline) }
    func set(_ timeline: RecordingTimeline?) { state.withLock { $0 = timeline } }
    func get() -> RecordingTimeline? { state.withLock { $0 } }
}

@MainActor
@Suite("Input recording", .serialized)
struct InputRecordingTests {
    static let fps = 60.0
    static let frame = 1 / fps
    static let rect = CGRect(x: 200, y: 100, width: 800, height: 600)
    static let origin = 100.0

    final class Harness {
        let folder: URL
        let timeline: FakeTimeline
        let recorder: EventRecorder
        var clicks: [(CGPoint, RecordingMouseButton)] = []
        var keys: [String] = []
        var rect: CGRect

        init(timeline: RecordingTimeline? = RecordingTimeline(origin: InputRecordingTests.origin),
             recordsKeystrokes: Bool = true,
             filter: KeystrokeDisplayFilter = .shortcutsOnly,
             keystrokeEnvironment: KeystrokeTap.Environment = Harness.environment(permission: true, secure: false),
             hostNow: Double = 10_000) {
            folder = FileManager.default.temporaryDirectory.appending(path: "hakoshot-input-\(UUID().uuidString)", directoryHint: .isDirectory)
            let fake = FakeTimeline(timeline)
            self.timeline = fake
            rect = InputRecordingTests.rect
            var configuration = EventRecorder.Configuration(
                sessionFolder: folder, fps: Int(InputRecordingTests.fps),
                recordsKeystrokes: recordsKeystrokes, keystrokeFilter: filter
            )
            configuration.tracksCursor = false
            configuration.samplesCursorShapes = false
            configuration.monitorsClicks = false
            configuration.timelineRefreshInterval = .seconds(3600)
            var rectBox: () -> CGRect = { InputRecordingTests.rect }
            recorder = EventRecorder(
                configuration: configuration,
                timeline: { fake.get() },
                rect: { rectBox() },
                hostClock: { hostNow },
                keystrokeEnvironment: keystrokeEnvironment
            )
            rectBox = { [unowned self] in self.rect }
            recorder.onClick = { [unowned self] point, button in self.clicks.append((point, button)) }
            recorder.onKey = { [unowned self] text in self.keys.append(text) }
        }

        static func environment(permission: Bool, secure: Bool) -> KeystrokeTap.Environment {
            KeystrokeTap.Environment(
                isPermissionGranted: { permission },
                isSecureInputEnabled: { secure },
                characters: { KeystrokeFormatter.ansiKeys[$0]?.lowercased() }
            )
        }

        var metadataURL: URL { folder.appending(path: RecordingMetadata.fileName) }
        var cursorURL: URL { folder.appending(path: CursorTrackCodec.fileName) }

        /// Writes an engine-style `events.json` (no events yet).
        func writeEngineMetadata(pauses: [ClosedRange<Double>] = [], droppedFrames: Int = 0) throws -> RecordingMetadata {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let metadata = RecordingMetadata(
                hostTimeOrigin: InputRecordingTests.origin,
                pauses: pauses,
                geometry: RecordingGeometryInfo(rect: InputRecordingTests.rect, displayID: 1, scale: 2, pixelWidth: 1600, pixelHeight: 1200),
                cursorBakedIn: true,
                droppedFrames: droppedFrames
            )
            try metadata.jsonData().write(to: metadataURL)
            return metadata
        }

        func click(_ host: Double, _ global: CGPoint, _ button: RecordingMouseButton = .left, down: Bool = true) {
            recorder.ingestClick(MouseButtonEvent(hostTime: host, globalPoint: global, button: button, isDown: down, clickCount: 1))
        }

        func key(_ host: Double, _ keys: String, repeat isRepeat: Bool = false) throws {
            let parsed = try #require(InputDebug.parseKeys(keys))
            recorder.injectKey(TappedKeyEvent(hostTime: host, kind: .keyDown, keyCode: parsed.keyCode,
                                              modifierFlags: parsed.modifierFlags, characters: nil, isRepeat: isRepeat))
        }

        func cursor(_ host: Double, _ local: CGPoint, flags: CursorSampleFlags = []) {
            recorder.ingestCursor(CursorPositionSample(hostTime: host, localPoint: local, flags: flags))
        }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Clicks

    @Test func clickMediaTimeWithinOneFrameAndRelativePosition() async throws {
        let h = Harness()
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        await h.recorder.refreshTimeline()
        h.click(101.234, CGPoint(x: 250, y: 150))
        h.click(101.300, CGPoint(x: 250, y: 150), down: false)
        h.click(102.5, CGPoint(x: 999, y: 699), .right)

        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.clicks.count == 3)
        let first = try #require(metadata.clicks.first)
        #expect(abs(first.time - 1.234) <= Self.frame)
        #expect(first.x == 50 && first.y == 50)
        #expect(first.isDown && first.button == .left)
        #expect(metadata.clicks[1].isDown == false)
        #expect(metadata.clicks[2].button == .right)
        #expect(abs(metadata.clicks[2].time - 2.5) <= Self.frame)
        #expect(metadata.clicks[2].x == 799 && metadata.clicks[2].y == 599)
        // Live callback: downs only, global point.
        #expect(h.clicks.map(\.0) == [CGPoint(x: 250, y: 150), CGPoint(x: 999, y: 699)])
        #expect(h.clicks.map(\.1) == [.left, .right])
    }

    @Test func positionsFollowAMovingRect() async throws {
        let h = Harness()
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        h.click(101, CGPoint(x: 300, y: 200))
        h.rect = h.rect.offsetBy(dx: 50, dy: 20) // window moved
        h.click(102, CGPoint(x: 300, y: 200))
        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.clicks.map(\.point) == [CGPoint(x: 100, y: 100), CGPoint(x: 50, y: 80)])
    }

    @Test func eventsBeforeOriginAreDropped() async throws {
        let h = Harness()
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        h.click(99.9, CGPoint(x: 300, y: 200))
        h.click(100.0, CGPoint(x: 300, y: 200))
        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.clicks.map(\.time) == [0])
    }

    // MARK: Pauses

    @Test func eventsInsideAPauseAreDropped() async throws {
        let pause: ClosedRange<Double> = 102...104
        let h = Harness(timeline: RecordingTimeline(origin: Self.origin, pauses: [pause]))
        _ = try h.writeEngineMetadata(pauses: [pause])
        h.recorder.start()
        await h.recorder.refreshTimeline()
        h.click(101, CGPoint(x: 300, y: 200))
        h.click(103, CGPoint(x: 300, y: 200))  // paused
        h.click(105, CGPoint(x: 300, y: 200))  // 5 − 2 paused = 3
        try h.key(102.5, "cmd+z")               // paused
        try h.key(104.5, "cmd+c")
        h.cursor(101.0, CGPoint(x: 1, y: 1))
        h.cursor(103.0, CGPoint(x: 2, y: 2))    // paused
        h.cursor(105.0, CGPoint(x: 3, y: 3))

        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.clicks.map(\.time) == [1, 3])
        #expect(metadata.keys.count == 1)
        #expect(abs((metadata.keys.first?.time ?? -1) - 2.5) < 1e-9)
        let samples = try CursorTrackCodec.decode(Data(contentsOf: h.cursorURL))
        #expect(samples.map(\.time) == [1, 3])
        #expect(samples.map(\.x) == [1, 3])
        // Live callbacks skip the paused events.
        #expect(h.clicks.count == 2)
        #expect(h.keys == ["⌘C"])
    }

    @Test func openPauseSuppressesLiveCallbacks() async throws {
        var timeline = RecordingTimeline(origin: Self.origin)
        timeline.beginPause(at: 103)
        let h = Harness(timeline: timeline)
        h.recorder.start()
        await h.recorder.refreshTimeline()
        h.click(104, CGPoint(x: 300, y: 200))
        try h.key(104, "cmd+z")
        #expect(h.clicks.isEmpty)
        #expect(h.keys.isEmpty)
        h.recorder.discard()
    }

    // MARK: Keys

    @Test func shortcutsOnlyFilterKeepsCombosAndSpecialKeys() async throws {
        let h = Harness(filter: .shortcutsOnly)
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        try h.key(101.0, "a")            // plain letter: no
        try h.key(101.1, "shift+a")      // shift alone doesn't make a shortcut
        try h.key(101.2, "cmd+z")
        try h.key(101.3, "return")
        try h.key(101.4, "ctrl+opt+space")
        try h.key(101.5, "cmd+z", repeat: true) // stored, not shown live
        h.recorder.ingestKey(TappedKeyEvent(hostTime: 101.6, kind: .flagsChanged, keyCode: 0x37,
                                            modifierFlags: KeystrokeModifiers.command.rawValue, characters: nil, isRepeat: false))
        #expect(h.keys == ["⌘Z", "↩", "⌃⌥Space"])

        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.keys.map { KeystrokeFormatter.displayText(for: $0, filter: .shortcutsOnly) } == ["⌘Z", "↩", "⌃⌥Space", "⌘Z"])
        #expect(metadata.keys.map(\.isRepeat) == [false, false, false, true])
        #expect(metadata.keys.allSatisfy { $0.kind == .keyDown })
    }

    @Test func allKeysFilterKeepsPlainLetters() async throws {
        let h = Harness(filter: .allKeys)
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        try h.key(101.0, "a")
        try h.key(101.1, "shift+a")
        #expect(h.keys == ["A", "⇧A"])
        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.keys.map(\.characters) == ["a", "a"])
    }

    @Test func keysAreNotRecordedWhenShowKeystrokesIsOff() async throws {
        let h = Harness(recordsKeystrokes: false)
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        try h.key(101, "cmd+z")
        #expect(h.recorder.keystrokeState == .disabled)
        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.keys.isEmpty)
        #expect(h.keys.isEmpty)
    }

    // MARK: cursor.bin

    @Test func cursorTrackStreamsAndPatchesTheCount() async throws {
        let h = Harness(hostNow: 101.05)
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        // Header written with the unknown count.
        var data = try Data(contentsOf: h.cursorURL)
        #expect(data.count == CursorTrackCodec.headerSize)
        #expect(data[CursorTrackCodec.countOffset..<CursorTrackCodec.countOffset + 4] == CursorTrackCodec.countField(nil))

        h.cursor(101.00, CGPoint(x: 10, y: 20), flags: .leftDown)
        h.cursor(101.02, CGPoint(x: 11, y: 21))
        h.cursor(101.10, CGPoint(x: 12, y: 22))   // after the fetch time: stays pending
        await h.recorder.refreshTimeline()
        data = try Data(contentsOf: h.cursorURL)
        #expect(data.count == CursorTrackCodec.headerSize + 2 * CursorTrackCodec.recordSize)
        // Readable mid-recording (crash recovery).
        #expect(try CursorTrackCodec.decode(data).count == 2)

        // Idle run: only the last identical sample is written, before the move.
        h.cursor(101.20, CGPoint(x: 12, y: 22))
        h.cursor(101.30, CGPoint(x: 12, y: 22))
        h.cursor(101.40, CGPoint(x: 13, y: 22))
        h.cursor(101.50, CGPoint(x: 13, y: 22))   // idle tail: written at finish
        try h.recorder.finish(mergingInto: h.metadataURL)

        data = try Data(contentsOf: h.cursorURL)
        let samples = try CursorTrackCodec.decode(data)
        #expect(data[CursorTrackCodec.countOffset..<CursorTrackCodec.countOffset + 4] == CursorTrackCodec.countField(samples.count))
        let times = samples.map { ($0.time * 1000).rounded() / 1000 }
        #expect(times == [1.0, 1.02, 1.1, 1.3, 1.4, 1.5])
        #expect(samples.first?.flags == .leftDown)
        #expect(samples.first.map { ($0.x, $0.y) } ?? (0, 0) == (10, 20))
        #expect(samples.last.map { ($0.x, $0.y) } ?? (0, 0) == (13, 22))
    }

    @Test func originChangeRestartsTheCursorTrack() async throws {
        let h = Harness()
        h.recorder.start()
        h.cursor(101, CGPoint(x: 1, y: 1))
        await h.recorder.refreshTimeline()
        #expect(try CursorTrackCodec.decode(Data(contentsOf: h.cursorURL)).count == 1)

        // Engine restart: no timeline until the new first frame, then a new T0.
        h.timeline.set(nil)
        await h.recorder.refreshTimeline()
        h.cursor(150, CGPoint(x: 2, y: 2))       // before the new origin
        h.cursor(201, CGPoint(x: 3, y: 3))
        h.click(150, CGPoint(x: 300, y: 200))
        h.click(201, CGPoint(x: 300, y: 200))
        h.timeline.set(RecordingTimeline(origin: 200))
        await h.recorder.refreshTimeline()
        let samples = try CursorTrackCodec.decode(Data(contentsOf: h.cursorURL))
        #expect(samples.map(\.time) == [1])
        #expect(samples.map(\.x) == [3])
        h.recorder.discard()
    }

    // MARK: events.json merge

    @Test func mergeKeepsPausesGeometryAndOtherFields() async throws {
        let pause: ClosedRange<Double> = 102...103
        let h = Harness(timeline: RecordingTimeline(origin: Self.origin, pauses: [pause]))
        let engine = try h.writeEngineMetadata(pauses: [pause], droppedFrames: 4)
        h.recorder.start()
        h.click(101, CGPoint(x: 300, y: 200))
        try h.key(104, "cmd+s")
        let merged = try h.recorder.finish(mergingInto: h.metadataURL)

        let onDisk = try RecordingMetadata(jsonData: Data(contentsOf: h.metadataURL))
        #expect(onDisk == merged)
        #expect(onDisk.pauses == engine.pauses)
        #expect(onDisk.geometry == engine.geometry)
        #expect(onDisk.hostTimeOrigin == engine.hostTimeOrigin)
        #expect(onDisk.droppedFrames == 4)
        #expect(onDisk.cursorBakedIn == engine.cursorBakedIn)
        #expect(onDisk.clicks.count == 1)
        #expect(onDisk.keys.map(\.time) == [3])
        #expect(h.recorder.isFinished)
        #expect(EventRecorder.active == nil)
    }

    @Test func finishWithoutEventsJSONThrows() async throws {
        let h = Harness()
        h.recorder.start()
        #expect(throws: (any Error).self) { try h.recorder.finish(mergingInto: h.metadataURL) }
    }

    // MARK: Keystroke tap: permission and secure input

    @Test func missingPermissionLeavesTheTapOffWithAFlag() async throws {
        let h = Harness(keystrokeEnvironment: Harness.environment(permission: false, secure: false))
        h.recorder.start()
        #expect(h.recorder.keystrokeState == .permissionMissing)
        #expect(h.recorder.snapshot().keystrokeState == .permissionMissing)
        h.recorder.discard()

        var seen: [TappedKeyEvent] = []
        let tap = KeystrokeTap(environment: Harness.environment(permission: false, secure: false)) { seen.append($0) }
        #expect(tap.start() == .permissionMissing)
        #expect(!tap.isRunning)
        tap.stop()
        #expect(tap.status == .permissionMissing)
        #expect(seen.isEmpty)
    }

    @Test func secureInputDropsKeysWithAFlag() async throws {
        let h = Harness(keystrokeEnvironment: Harness.environment(permission: false, secure: true))
        _ = try h.writeEngineMetadata()
        h.recorder.start()
        try h.key(101, "cmd+z")
        #expect(h.keys.isEmpty)
        #expect(h.recorder.didSkipSecureInput)
        let metadata = try h.recorder.finish(mergingInto: h.metadataURL)
        #expect(metadata.keys.isEmpty)

        var seen: [TappedKeyEvent] = []
        let tap = KeystrokeTap(environment: Harness.environment(permission: true, secure: true)) { seen.append($0) }
        tap.ingest(TappedKeyEvent(hostTime: 1, kind: .keyDown, keyCode: 0x06, modifierFlags: 0, characters: nil, isRepeat: false))
        #expect(seen.isEmpty)
        #expect(tap.didSkipSecureInput)
        #expect(tap.skippedSecureInputEvents == 1)
    }

    @Test func tapFillsCharactersWithoutModifiers() {
        var seen: [TappedKeyEvent] = []
        let tap = KeystrokeTap(environment: Harness.environment(permission: true, secure: false)) { seen.append($0) }
        tap.ingest(TappedKeyEvent(hostTime: 1, kind: .keyDown, keyCode: 0x03, modifierFlags: KeystrokeModifiers.option.rawValue,
                                  characters: nil, isRepeat: false))
        tap.ingest(TappedKeyEvent(hostTime: 2, kind: .flagsChanged, keyCode: 0x37, modifierFlags: 0, characters: nil, isRepeat: false))
        #expect(seen.map(\.characters) == ["f", nil])
    }

    @Test(.enabled(if: InputMonitoringPermission.isGranted, "Input Monitoring not granted; real tap skipped"))
    func realTapStartsWhenAlreadyGranted() {
        let tap = KeystrokeTap { _ in }
        let status = tap.start()
        // Granted but not yet effective (needs relaunch) is also acceptable.
        #expect(status == .running || status == .tapFailed)
        tap.stop()
        #expect(!tap.isRunning)
    }

    @Test func liveCharactersIgnoreModifiers() {
        // US-like layouts map kVK_ANSI_A to "a"; any layout gives one visible character or nil.
        if let a = KeystrokeTap.characters(forKeyCode: 0x00) { #expect(a.count == 1) }
    }

    // MARK: Cursor shapes

    @Test func shapeSamplerDedupesByImageAndWritesPNGs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hakoshot-cursors-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cursors = folder.appending(path: "cursors", directoryHint: .isDirectory)
        let red = try #require(Self.solidImage(red: 1))
        let blue = try #require(Self.solidImage(red: 0))
        var next: CursorImageSnapshot? = CursorImageSnapshot(image: red, hotSpot: CGPoint(x: 4, y: 5), pointSize: CGSize(width: 8, height: 8))
        let sampler = CursorShapeSampler(cursorsFolder: cursors) { next }

        sampler.sampleNow()
        #expect(sampler.currentIndex == 0)
        next = CursorImageSnapshot(image: blue, hotSpot: .zero, pointSize: CGSize(width: 8, height: 8))
        sampler.sampleNow()
        #expect(sampler.currentIndex == 1)
        next = CursorImageSnapshot(image: Self.solidImage(red: 1)!, hotSpot: CGPoint(x: 4, y: 5), pointSize: CGSize(width: 8, height: 8))
        sampler.sampleNow()
        #expect(sampler.currentIndex == 0)
        #expect(sampler.shapes.count == 2)
        next = nil
        sampler.sampleNow()
        #expect(sampler.isHidden && sampler.currentIndex == 0)

        let first = try #require(sampler.shapes.first)
        #expect(first.hotSpotX == 4 && first.hotSpotY == 5 && first.width == 8)
        for shape in sampler.shapes {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: shape.fileName).path))
        }
        #expect(Set(sampler.shapes.map(\.hash)).count == 2)
    }

    @Test func systemCursorSnapshotIsHashable() {
        // Works headless too (spike: arrow on the lock screen); nil is tolerated.
        guard let snapshot = CursorShapeSampler.systemCursor() else { return }
        #expect(CursorShapeSampler.hash(of: snapshot.image) != nil)
        #expect(snapshot.pointSize.width > 0)
    }

    static func solidImage(red: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 1 - red, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }

    // MARK: Helpers and DEBUG parsing

    @Test func cursorHelpers() {
        #expect(CursorTracker.rate(forFPS: 30) == 60)
        #expect(CursorTracker.rate(forFPS: 60) == 60)
        #expect(CursorTracker.rate(forFPS: 240) == 120)
        #expect(CursorTracker.buttonFlags(0b101) == [.leftDown, .otherDown])
        #expect(CursorTracker.buttonFlags(0b10) == [.rightDown])
        #expect(CursorTracker.localPoint(CGPoint(x: 250, y: 150), in: Self.rect) == CGPoint(x: 50, y: 50))
    }

    @Test func debugKeyParsing() throws {
        let f = try #require(InputDebug.parseKeys("cmd+shift+f"))
        #expect(f.keyCode == 0x03)
        #expect(KeystrokeFormatter.displayText(keyCode: f.keyCode, modifierFlags: f.modifierFlags, characters: f.characters,
                                               filter: .shortcutsOnly) == "⇧⌘F")
        #expect(InputDebug.parseKeys("esc")?.keyCode == 0x35)
        #expect(InputDebug.parseKeys("ctrl+f12")?.keyCode == 0x6F)
        #expect(InputDebug.parseKeys("hyper+f") == nil)
        #expect(InputDebug.parseKeys("cmd+nope") == nil)

        let click = try #require(InputDebug.InjectParameters(queryItems: [
            URLQueryItem(name: "kind", value: "click"), URLQueryItem(name: "x", value: "10"), URLQueryItem(name: "y", value: "20"),
        ]))
        #expect(click.point == CGPoint(x: 10, y: 20))
        #expect(InputDebug.InjectParameters(queryItems: [URLQueryItem(name: "kind", value: "key"), URLQueryItem(name: "keys", value: "zz+q")]) == nil)
        #expect(InputDebug.InjectParameters(queryItems: []) == nil)
    }

    @Test func debugInjectionReachesTheActiveRecorder() async throws {
        let h = Harness()
        _ = try h.writeEngineMetadata()
        #expect(!InputDebug.inject(.init(queryItems: [URLQueryItem(name: "kind", value: "click")])!, into: nil))
        h.recorder.start()
        #expect(EventRecorder.active === h.recorder)
        // Host "now" is far after the fake origin, so these map to real media times.
        #expect(InputDebug.inject(.init(queryItems: [
            URLQueryItem(name: "kind", value: "click"), URLQueryItem(name: "x", value: "250"), URLQueryItem(name: "y", value: "150"),
        ])!))
        #expect(InputDebug.inject(.init(queryItems: [URLQueryItem(name: "kind", value: "key"), URLQueryItem(name: "keys", value: "cmd+shift+f")])!))
        #expect(h.keys == ["⇧⌘F"])
        #expect(h.clicks.map(\.0) == [CGPoint(x: 250, y: 150)])
        await h.recorder.refreshTimeline()

        let out = h.folder.appending(path: "events-debug.json")
        InputDebug.writeEvents(to: out)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        #expect(object["active"] as? Bool == true)
        #expect((object["clicks"] as? [Any])?.count == 2)
        #expect(((object["keys"] as? [[String: Any]])?.first?["text"] as? String) == "⇧⌘F")
        try h.recorder.finish(mergingInto: h.metadataURL)
    }
}
