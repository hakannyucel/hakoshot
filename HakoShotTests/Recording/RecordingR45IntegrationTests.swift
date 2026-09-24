import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R4.I + R5.I: which of our windows a recording captures (classic vs
/// Studio), the webcam / input URL commands, the HUD camera and keystroke
/// logic, the coordinator's request overrides and History keeping
/// `events.json`.
@Suite("R4/R5 integration", .serialized)
struct RecordingR45IntegrationTests {
    private func parse(_ string: String) throws -> AppCommand {
        try URLSchemeHandler.parse(try #require(URL(string: string)))
    }

    private func parseError(_ string: String) throws -> URLSchemeError? {
        do {
            _ = try URLSchemeHandler.parse(try #require(URL(string: string)))
            return nil
        } catch {
            return error as? URLSchemeError
        }
    }

    private static func request(
        profile: RecordingProfile = .classic,
        camera: Bool = false,
        clicks: Bool = true,
        keys: Bool = false
    ) -> RecordingRequest {
        var options = RecordingOptions.default
        options.camera = camera ? CameraOptions() : nil
        options.highlightsClicks = clicks
        options.showsKeystrokes = keys
        return RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 640, height: 360), displayID: 1),
            options: options, format: .video, profile: profile, action: nil, source: .synthetic
        )
    }

    // MARK: Excepted windows (pure)

    @Test func classicCapturesBubbleAndOverlay() {
        let plan = RecordingCompanionPlan.make(Self.request(camera: true, clicks: true, keys: true))
        #expect(plan.showsCamera && plan.capturesCameraInVideo && !plan.writesCameraFile)
        #expect(plan.showsOverlay && plan.recordsKeystrokes)
        #expect(plan.exceptedWindowIDs(bubble: 11, overlay: 22) == [11, 22])
        // A window that couldn't open isn't listed.
        #expect(plan.exceptedWindowIDs(bubble: nil, overlay: 22) == [22])
    }

    @Test func studioCapturesNothing() {
        let plan = RecordingCompanionPlan.make(Self.request(profile: .studio, camera: true, clicks: true, keys: true))
        #expect(plan.showsCamera && !plan.capturesCameraInVideo && plan.writesCameraFile)
        #expect(!plan.showsOverlay)
        // Keys still go to events.json for the Studio badge.
        #expect(plan.recordsKeystrokes)
        #expect(plan.exceptedWindowIDs(bubble: 11, overlay: 22).isEmpty)
    }

    @Test func overlayOnlyWhenSomethingIsShown() {
        let none = RecordingCompanionPlan.make(Self.request(camera: false, clicks: false, keys: false))
        #expect(!none.showsCamera && !none.showsOverlay && !none.recordsKeystrokes)
        #expect(none.exceptedWindowIDs(bubble: 11, overlay: 22).isEmpty)
        #expect(RecordingCompanionPlan.make(Self.request(clicks: false, keys: true)).showsOverlay)
        #expect(RecordingCompanionPlan.make(Self.request(clicks: true, keys: false)).showsOverlay)
        let cameraOnly = RecordingCompanionPlan.make(Self.request(camera: true, clicks: false, keys: false))
        #expect(cameraOnly.exceptedWindowIDs(bubble: 11, overlay: nil) == [11])
    }

    @Test func keystrokeWarningNeedsKeysWithoutPermission() {
        #expect(RecordingCoordinator.needsKeystrokeWarning(Self.request(keys: true), inputMonitoringGranted: false))
        #expect(!RecordingCoordinator.needsKeystrokeWarning(Self.request(keys: true), inputMonitoringGranted: true))
        #expect(!RecordingCoordinator.needsKeystrokeWarning(Self.request(keys: false), inputMonitoringGranted: false))
    }

    @Test func cameraTimeConversion() {
        #expect(RecordingCompanions.cmTime(12.5).seconds == 12.5)
    }

    // MARK: URLs

    #if DEBUG
    @Test func recordScreenOverrides() throws {
        guard case let .record(kind, options) = try parse("hakoshot://record-screen?x=1&y=2&width=3&height=4&start=1&camera=pattern&clicks=0&keys=1") else {
            Issue.record("record-screen")
            return
        }
        #expect(kind == .area)
        #expect(options.camera == .pattern)
        #expect(options.highlightsClicks == false)
        #expect(options.showsKeystrokes == true)
        guard case let .record(_, on) = try parse("hakoshot://record-screen?camera=1") else { Issue.record("camera=1"); return }
        #expect(on.camera == .on && on.highlightsClicks == nil && on.showsKeystrokes == nil)
        guard case let .record(_, off) = try parse("hakoshot://record-screen?camera=off") else { Issue.record("camera=off"); return }
        #expect(off.camera == .off)
        #expect(try parseError("hakoshot://record-screen?camera=maybe") == .invalidParameter(name: "camera", value: "maybe"))
        #expect(try parseError("hakoshot://record-screen?clicks=2") == .invalidParameter(name: "clicks", value: "2"))
    }

    @Test func makeRequestAppliesOverrides() {
        let selection = RecordingHUDSelection(choice: .video)
        var base = RecordingOptions.default
        base.camera = nil
        base.highlightsClicks = true
        base.showsKeystrokes = false
        let target = RecordingTarget.area(GlobalRect(x: 0, y: 0, width: 10, height: 10), displayID: 1)
        let options = RecordingCommandOptions(camera: .pattern, highlightsClicks: false, showsKeystrokes: true)
        let request = RecordingCoordinator.makeRequest(target: target, options: options, selection: selection, base: base, source: .synthetic)
        #expect(request.options.camera == CameraOptions())
        #expect(!request.options.highlightsClicks)
        #expect(request.options.showsKeystrokes)

        base.camera = CameraOptions(shape: .circle)
        let off = RecordingCoordinator.makeRequest(
            target: target, options: RecordingCommandOptions(camera: .off), selection: selection, base: base, source: .synthetic
        )
        #expect(off.options.camera == nil)
        let kept = RecordingCoordinator.makeRequest(
            target: target, options: RecordingCommandOptions(camera: .on), selection: selection, base: base, source: .synthetic
        )
        #expect(kept.options.camera?.shape == .circle)
        let untouched = RecordingCoordinator.makeRequest(
            target: target, options: RecordingCommandOptions(), selection: selection, base: base, source: .synthetic
        )
        #expect(untouched.options == base)
    }

    @Test func cameraDebugURLs() throws {
        guard case let .debugCameraDevices(items) = try parse("hakoshot://debug-camera-devices?out=/tmp/c.json") else {
            Issue.record("debug-camera-devices"); return
        }
        #expect(items == [URLQueryItem(name: "out", value: "/tmp/c.json")])

        guard case let .debugRecordCamera(record) = try parse("hakoshot://debug-record-camera?seconds=2&out=/tmp/c.mov&source=pattern") else {
            Issue.record("debug-record-camera"); return
        }
        #expect(record.seconds == 2 && record.source == .pattern && record.out == URL(fileURLWithPath: "/tmp/c.mov"))
        #expect(try parseError("hakoshot://debug-record-camera?seconds=2") == .invalidParameter(name: "out", value: ""))

        guard case let .debugWebcamBubble(bubble) = try parse("hakoshot://debug-webcam-bubble?shape=circle&size=large&corner=topLeft&pattern=1&snapshot=/tmp/b.png") else {
            Issue.record("debug-webcam-bubble"); return
        }
        #expect(bubble.options.shape == .circle && bubble.options.size == .large && bubble.options.corner == .topLeft)
        #expect(bubble.forcePattern && bubble.snapshot == URL(fileURLWithPath: "/tmp/b.png"))
    }

    @Test func inputDebugURLs() throws {
        guard case let .debugInjectInput(click) = try parse("hakoshot://debug-inject-input?kind=click&x=10&y=20&button=right") else {
            Issue.record("debug-inject-input click"); return
        }
        #expect(click.kind == .click && click.point == CGPoint(x: 10, y: 20) && click.button == .right)
        guard case let .debugInjectInput(key) = try parse("hakoshot://debug-inject-input?kind=key&keys=cmd+shift+f") else {
            Issue.record("debug-inject-input key"); return
        }
        #expect(key.kind == .key && key.keys == "cmd+shift+f")
        #expect(try parseError("hakoshot://debug-inject-input?kind=tap") == .invalidParameter(name: "kind", value: "tap"))
        #expect(try parseError("hakoshot://debug-inject-input?kind=key&keys=cmd+nope") == .invalidParameter(name: "kind", value: "key"))

        #expect(try parse("hakoshot://debug-recording-events?out=/tmp/e.json") == .debugRecordingEvents(URL(fileURLWithPath: "/tmp/e.json")))
        #expect(try parseError("hakoshot://debug-recording-events") == .invalidParameter(name: "out", value: ""))

        guard case let .debugOverlayDemo(demo) = try parse("hakoshot://debug-overlay-demo?x=100&y=200&keys=%E2%8C%98Z") else {
            Issue.record("debug-overlay-demo"); return
        }
        #expect(demo.point == CGPoint(x: 100, y: 200) && demo.keys == "⌘Z")
        #expect(try parseError("hakoshot://debug-overlay-demo?x=1") == .invalidParameter(name: "x/y", value: ""))
    }

    @Test func debugSidecars() {
        let folder = URL(fileURLWithPath: "/tmp/session")
        let raw = RawRecording(
            id: UUID(), sessionFolder: folder, cameraURL: folder.appending(path: "camera.mov"),
            eventsURL: folder.appending(path: "events.json"), cursorURL: nil,
            target: .display(1), profile: .studio, pixelSize: CGSize(width: 2, height: 2),
            pointSize: CGSize(width: 1, height: 1), scale: 2, fps: 60, duration: 1, audioTracks: [], startDate: .now
        )
        let sidecars = RecordingCoordinator.debugSidecars(raw)
        #expect(sidecars.map(\.1) == [".events.json", ".camera.mov"])
        #expect(RecordingCoordinator.debugSidecars(nil).isEmpty)
    }
    #endif

    // MARK: HUD camera / keystrokes

    private static func settings() -> (AppSettings, UserDefaults, String) {
        let suite = "com.hakanyucel.hakoshot.tests.r45.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test func cameraAvailability() {
        #expect(!RecordingHUDToggle.camera.isAvailable(hasCamera: false))
        #expect(RecordingHUDToggle.camera.isAvailable(hasCamera: true))
        for toggle in RecordingHUDToggle.allCases where toggle != .camera {
            #expect(toggle.isAvailable(hasCamera: false))
        }
    }

    @Test func cameraToggleWithoutCameraIsIgnored() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings, cameras: CameraDevices(startObserving: false), hasCamera: { false },
                                      requestCameraAccess: { Issue.record("must not ask"); return false })
        #expect(!model.isAvailable(.camera))
        model.toggle(.camera)
        #expect(!model.isOn(.camera))
        #expect(!settings.value(for: .recordingCameraEnabled))
    }

    @Test func cameraGrantedStaysOn() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings, cameras: CameraDevices(startObserving: false), hasCamera: { true },
                                      requestCameraAccess: { true })
        model.toggle(.camera)
        await model.ensureCameraAccess()
        #expect(model.isOn(.camera))
        #expect(settings.value(for: .recordingCameraEnabled))
        #expect(!model.showsCameraWarning)
    }

    @Test func cameraDeniedTurnsBackOffWithWarning() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings, cameras: CameraDevices(startObserving: false), hasCamera: { true },
                                      requestCameraAccess: { false })
        model.toggle(.camera)
        #expect(model.isOn(.camera))
        await model.ensureCameraAccess()
        #expect(!model.isOn(.camera))
        #expect(!settings.value(for: .recordingCameraEnabled))
        #expect(model.showsCameraWarning)
    }

    @Test func cameraMenuSelection() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings, cameras: CameraDevices(startObserving: false), hasCamera: { true },
                                      requestCameraAccess: { true })
        model.selectCamera(deviceID: "cam-1")
        #expect(settings.value(for: .recordingCameraDeviceID) == "cam-1")
        #expect(model.isOn(.camera))
        // A saved camera that isn't connected stays listed.
        #expect(model.cameraOptions.first?.id == "")
        #expect(model.cameraOptions.contains { $0.id == "cam-1" })
        model.selectCameraShape(.vertical)
        #expect(settings.value(for: .recordingCameraShape) == .vertical)
        #expect(RecordingHUDModel(settings: settings, cameras: CameraDevices(startObserving: false)).cameraShape == .vertical)
    }

    @Test func keystrokeAccess() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        var status = InputMonitoringPermission.Status.notDetermined
        var requests = 0
        let model = RecordingHUDModel(
            settings: settings, cameras: CameraDevices(startObserving: false), hasCamera: { false },
            inputMonitoring: { status }, requestInputMonitoring: { requests += 1; status = .denied }
        )
        model.set(.showKeystrokes, true)
        model.checkKeystrokeAccess()
        #expect(requests == 1)
        #expect(model.showsKeystrokeWarning)
        // Denied: no second prompt.
        model.checkKeystrokeAccess()
        #expect(requests == 1)
        model.set(.showKeystrokes, false)
        model.checkKeystrokeAccess()
        #expect(!model.showsKeystrokeWarning)
        status = .granted
        model.set(.showKeystrokes, true)
        model.checkKeystrokeAccess()
        #expect(!model.showsKeystrokeWarning && requests == 1)
    }

    // MARK: History keeps events.json

    @Test func historyKeepsEventsForVideos() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "HakoShotR45-\(UUID().uuidString)", directoryHint: .isDirectory)
        let session = FileManager.default.temporaryDirectory.appending(path: "HakoShotR45Session-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: session)
        }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let media = session.appending(path: "recording.mp4")
        try Data(repeating: 1, count: 16).write(to: media)
        let events = session.appending(path: "events.json")
        let metadata = RecordingMetadata(
            hostTimeOrigin: 10, pauses: [],
            geometry: RecordingGeometryInfo(rect: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 1, scale: 2, pixelWidth: 20, pixelHeight: 20),
            clicks: [RecordingClickEvent(time: 1, x: 2, y: 3, button: .left, isDown: true, clickCount: 1)],
            cursorBakedIn: true
        )
        try metadata.jsonData().write(to: events)
        let raw = RawRecording(
            id: UUID(), sessionFolder: session, eventsURL: events, target: .display(1), profile: .classic,
            pixelSize: CGSize(width: 20, height: 20), pointSize: CGSize(width: 10, height: 10), scale: 2, fps: 60,
            duration: 2, audioTracks: [], startDate: .now
        )
        let thumbnail = PostCaptureFixture.image(pointWidth: 8, pointHeight: 8, scale: 1)
        var result = RecordingResult(fileURL: media, format: .video, duration: 2, pixelSize: CGSize(width: 20, height: 20),
                                     thumbnail: thumbnail, date: .now, targetKind: .area)
        result.raw = raw

        let store = HistoryStore(rootURL: root)
        let item = try #require(await store.addRecording(result))
        let name = try #require(item.eventsFileName)
        let copied = try RecordingMetadata(jsonData: Data(contentsOf: root.appending(path: name)))
        #expect(copied.clicks.count == 1)
        #expect(item.ownedFileNames.contains(name))

        // GIFs don't keep events.
        let gif = session.appending(path: "recording.gif")
        try Data(repeating: 2, count: 16).write(to: gif)
        var gifResult = RecordingResult(fileURL: gif, format: .gif, duration: 2, pixelSize: CGSize(width: 20, height: 20),
                                        thumbnail: thumbnail, date: .now, targetKind: .area)
        gifResult.raw = raw
        let gifItem = try #require(await store.addRecording(gifResult))
        #expect(gifItem.eventsFileName == nil)
    }
}
