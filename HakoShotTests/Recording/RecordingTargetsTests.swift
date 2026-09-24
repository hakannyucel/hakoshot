import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
@preconcurrency import ScreenCaptureKit
import Testing
@testable import HakoShot

// R1.4 "Targets and environment": WindowFollower math, filter choices,
// RecordingEnvironment begin/end, DEBUG parameter parsing, and one real
// window-mode recording (skipped while the screen is locked).

// MARK: - WindowFollowMath

@Suite("Window follow math")
struct WindowFollowMathTests {
    let display = GlobalRect(x: 0, y: 0, width: 1920, height: 1080)
    let secondDisplay = GlobalRect(x: 1920, y: 0, width: 1920, height: 1080)
    let reference = CGSize(width: 400, height: 300)

    @Test func movedWindowGivesItsOwnFrame() {
        let placement = WindowFollowMath.placement(
            windowFrame: GlobalRect(x: 500, y: 200, width: 400, height: 300), displayFrame: display, referenceSize: reference
        )
        #expect(placement.sourceRect == CGRect(x: 500, y: 200, width: 400, height: 300))
        #expect(placement.visibility == .onDisplay)
        #expect(placement.visibleFraction == 1)
    }

    @Test func secondDisplayUsesLocalCoordinates() {
        let placement = WindowFollowMath.placement(
            windowFrame: GlobalRect(x: 2020, y: 50, width: 400, height: 300), displayFrame: secondDisplay, referenceSize: reference
        )
        #expect(placement.sourceRect == CGRect(x: 100, y: 50, width: 400, height: 300))
    }

    @Test func displayAboveMainHasNegativeGlobalY() {
        let above = GlobalRect(x: 0, y: -1440, width: 2560, height: 1440)
        let placement = WindowFollowMath.placement(
            windowFrame: GlobalRect(x: 10, y: -1000, width: 400, height: 300), displayFrame: above, referenceSize: reference
        )
        #expect(placement.sourceRect == CGRect(x: 10, y: 440, width: 400, height: 300))
    }

    @Test func windowOverRightEdgeIsClippedWithoutStretching() throws {
        // Half the window is past the right edge (on another display).
        let placement = WindowFollowMath.placement(
            windowFrame: GlobalRect(x: 1720, y: 100, width: 400, height: 300), displayFrame: display, referenceSize: reference
        )
        #expect(placement.visibility == .clipped)
        #expect(abs(placement.visibleFraction - 0.5) < 0.001)
        let rect = try #require(placement.sourceRect)
        // Same size as at start (no scaling), kept inside the display.
        #expect(rect == CGRect(x: 1520, y: 100, width: 400, height: 300))
    }

    @Test func windowEntirelyOnAnotherDisplayKeepsLastRect() {
        let placement = WindowFollowMath.placement(
            windowFrame: GlobalRect(x: 2200, y: 100, width: 400, height: 300), displayFrame: display, referenceSize: reference
        )
        #expect(placement.visibility == .offDisplay)
        #expect(placement.sourceRect == nil)
        #expect(placement.visibleFraction == 0)
    }

    @Test func resizedWindowKeepsTheOutputAspect() throws {
        // Twice as wide: the rect grows vertically around the center (4:3 kept).
        let placement = WindowFollowMath.placement(
            windowFrame: GlobalRect(x: 400, y: 400, width: 800, height: 300), displayFrame: display, referenceSize: reference
        )
        let rect = try #require(placement.sourceRect)
        #expect(abs(rect.width / rect.height - 4.0 / 3.0) < 0.0001)
        #expect(rect.width == 800)
        #expect(rect.height == 600)
        #expect(rect.midX == 800)
        #expect(rect.midY == 550)
    }

    @Test func fitAspectNeverShrinks() {
        let tall = WindowFollowMath.fitAspect(CGRect(x: 0, y: 0, width: 100, height: 300), to: CGSize(width: 4, height: 3))
        #expect(tall == CGRect(x: -150, y: 0, width: 400, height: 300))
        let same = CGRect(x: 5, y: 5, width: 400, height: 300)
        #expect(WindowFollowMath.fitAspect(same, to: reference) == same)
        #expect(WindowFollowMath.fitAspect(same, to: .zero) == same)
    }

    @Test func keepInsideClampsOversizedSides() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        #expect(WindowFollowMath.keep(CGRect(x: -20, y: 480, width: 100, height: 100), inside: bounds) == CGRect(x: 0, y: 400, width: 100, height: 100))
        #expect(WindowFollowMath.keep(CGRect(x: -20, y: 10, width: 1200, height: 100), inside: bounds) == CGRect(x: 0, y: 10, width: 1000, height: 100))
    }

    @Test func changeTolerance() {
        let base = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(!WindowFollowMath.hasChanged(base.offsetBy(dx: 0.4, dy: 0), from: base))
        #expect(WindowFollowMath.hasChanged(base.offsetBy(dx: 1, dy: 0), from: base))
        #expect(WindowFollowMath.hasChanged(base, from: nil))
    }
}

// MARK: - WindowFollower (fake window list)

/// Scripted window-list answers.
fileprivate nonisolated final class FakeWindowList: @unchecked Sendable {
    private let lock = NSLock()
    private var state: WindowFollower.WindowState?

    init(_ state: WindowFollower.WindowState?) { self.state = state }

    func set(_ new: WindowFollower.WindowState?) { lock.withLock { state = new } }
    func get() -> WindowFollower.WindowState? { lock.withLock { state } }
}

fileprivate nonisolated final class AppliedRects: @unchecked Sendable {
    private let lock = NSLock()
    private var rects: [CGRect] = []

    func append(_ rect: CGRect) { lock.withLock { rects.append(rect) } }
    var all: [CGRect] { lock.withLock { rects } }
}

@Suite("Window follower")
struct WindowFollowerTests {
    static let display = GlobalRect(x: 0, y: 0, width: 1920, height: 1080)

    fileprivate static func follower(_ list: FakeWindowList, applied: AppliedRects, closed: @escaping () -> Void = {}) -> WindowFollower {
        WindowFollower(
            configuration: .init(windowID: 42, displayID: 1, displayFrame: display, initialSourceRect: CGRect(x: 100, y: 100, width: 400, height: 300)),
            query: { _ in list.get() },
            apply: { applied.append($0) },
            onWindowClosed: closed
        )
    }

    @Test func updatesOnlyWhenTheWindowMoves() async {
        let list = FakeWindowList(.init(frame: GlobalRect(x: 100, y: 100, width: 400, height: 300), isOnScreen: true))
        let applied = AppliedRects()
        let follower = Self.follower(list, applied: applied)

        #expect(await follower.pollOnce())
        #expect(applied.all.isEmpty, "unchanged window must not update")

        list.set(.init(frame: GlobalRect(x: 160, y: 120, width: 400, height: 300), isOnScreen: true))
        await follower.pollOnce()
        await follower.pollOnce()
        #expect(applied.all == [CGRect(x: 160, y: 120, width: 400, height: 300)])
        #expect(follower.updateCount == 1)
    }

    @Test func hiddenWindowKeepsTheLastRect() async {
        let list = FakeWindowList(.init(frame: GlobalRect(x: 900, y: 100, width: 400, height: 300), isOnScreen: false))
        let applied = AppliedRects()
        let follower = Self.follower(list, applied: applied)
        #expect(await follower.pollOnce())
        #expect(applied.all.isEmpty)
        #expect(!follower.isClosed)
    }

    @Test func closedWindowCallsBackOnceAfterConfirmation() async {
        let list = FakeWindowList(nil)
        let applied = AppliedRects()
        var closedCount = 0
        let follower = Self.follower(list, applied: applied) { closedCount += 1 }

        #expect(await follower.pollOnce(), "one miss is not a close yet")
        #expect(closedCount == 0)
        #expect(await follower.pollOnce() == false)
        #expect(closedCount == 1)
        #expect(await follower.pollOnce() == false)
        #expect(closedCount == 1)
        #expect(follower.isClosed)
    }

    @Test func missThenBackResetsTheCloseCounter() async {
        let list = FakeWindowList(nil)
        let applied = AppliedRects()
        var closed = false
        let follower = Self.follower(list, applied: applied) { closed = true }
        await follower.pollOnce()
        list.set(.init(frame: GlobalRect(x: 100, y: 100, width: 400, height: 300), isOnScreen: true))
        await follower.pollOnce()
        list.set(nil)
        await follower.pollOnce()
        #expect(!closed)
    }

    @Test func pollingLoopFollowsAndStops() async throws {
        let list = FakeWindowList(.init(frame: GlobalRect(x: 100, y: 100, width: 400, height: 300), isOnScreen: true))
        let applied = AppliedRects()
        let follower = WindowFollower(
            configuration: .init(windowID: 7, displayID: 1, displayFrame: Self.display, initialSourceRect: CGRect(x: 100, y: 100, width: 400, height: 300), interval: .milliseconds(10)),
            query: { _ in list.get() },
            apply: { applied.append($0) },
            onWindowClosed: {}
        )
        follower.start()
        #expect(follower.isRunning)
        list.set(.init(frame: GlobalRect(x: 300, y: 100, width: 400, height: 300), isOnScreen: true))
        let deadline = ContinuousClock.now + .seconds(2)
        while applied.all.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        follower.stop()
        #expect(!follower.isRunning)
        #expect(applied.all.first == CGRect(x: 300, y: 100, width: 400, height: 300))
    }

    @Test func makeOnlyForWindowTargets() {
        let layout = DisplayLayout(
            displays: [DisplayDescriptor(id: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), backingScaleFactor: 2)],
            mainDisplayID: 1
        )
        func handle(_ target: RecordingTarget) -> RecordingHandle {
            RecordingHandle(
                id: UUID(), sessionFolder: URL(fileURLWithPath: "/tmp"), target: target, profile: .classic,
                sourceRect: GlobalRect(x: 100, y: 50, width: 400, height: 300), displayID: 1,
                pixelSize: CGSize(width: 800, height: 600), pointSize: CGSize(width: 400, height: 300), scale: 2, startDate: .now
            )
        }
        let follower = WindowFollower.make(for: handle(.window(9)), layout: layout, apply: { _ in }, onWindowClosed: {})
        #expect(follower?.configuration.windowID == 9)
        #expect(follower?.configuration.initialSourceRect == CGRect(x: 100, y: 50, width: 400, height: 300))
        #expect(WindowFollower.make(for: handle(.display(1)), layout: layout, apply: { _ in }, onWindowClosed: {}) == nil)
    }
}

// MARK: - ContentFilterBuilder

@Suite("Content filter choices")
struct ContentFilterBuilderTests {
    typealias Builder = ContentFilterBuilder
    static let ownPID: pid_t = 100
    static let otherPID: pid_t = 200
    static let finderPID: pid_t = 300
    static let notificationsPID: pid_t = 400

    static let snapshot = Builder.ContentSnapshot(
        windows: [
            .init(id: 1, pid: ownPID, bundleID: "com.hakanyucel.HakoShot", layer: 25), // control bar
            .init(id: 2, pid: ownPID, bundleID: "com.hakanyucel.HakoShot", layer: 3), // click overlay (excepted)
            .init(id: 10, pid: otherPID, bundleID: "com.example.Editor", layer: 0), // target
            .init(id: 11, pid: otherPID, bundleID: "com.example.Editor", layer: 0),
            .init(id: 20, pid: finderPID, bundleID: "com.apple.finder", layer: -2147483603), // desktop icons
            .init(id: 21, pid: finderPID, bundleID: "com.apple.finder", layer: 0), // Finder window
            .init(id: 30, pid: notificationsPID, bundleID: Builder.notificationCenterBundleID, layer: 23), // banner
            .init(id: 31, pid: notificationsPID, bundleID: Builder.notificationCenterBundleID, layer: -2147483601), // widget
        ],
        applications: [
            .init(pid: ownPID, bundleID: "com.hakanyucel.HakoShot"),
            .init(pid: otherPID, bundleID: "com.example.Editor"),
            .init(pid: finderPID, bundleID: "com.apple.finder"),
            .init(pid: notificationsPID, bundleID: Builder.notificationCenterBundleID),
        ]
    )

    static func options(window: Builder.WindowTarget? = nil, icons: Bool = false, notifications: Bool = false) -> Builder.Options {
        Builder.Options(displayID: 1, exceptedWindowIDs: [2], hidesDesktopIcons: icons, excludesNotifications: notifications, window: window, ownPID: ownPID)
    }

    @Test func areaExcludesOurAppAndKeepsExceptedOverlays() throws {
        let plan = try Builder.plan(Self.options(), snapshot: Self.snapshot)
        #expect(plan == .excludingApplications(pids: [Self.ownPID], exceptingWindows: [2]))
        #expect(!plan.isWindowMode)
    }

    @Test func notificationBannersDroppedWidgetsKept() throws {
        let plan = try Builder.plan(Self.options(notifications: true), snapshot: Self.snapshot)
        #expect(plan == .excludingApplications(pids: [Self.ownPID, Self.notificationsPID], exceptingWindows: [2, 31]))
    }

    @Test func hiddenIconsAndNotificationsTogether() throws {
        let plan = try Builder.plan(Self.options(icons: true, notifications: true), snapshot: Self.snapshot)
        guard case let .excludingApplications(pids, excepting) = plan else {
            Issue.record("unexpected plan \(plan)")
            return
        }
        #expect(Set(pids) == [Self.ownPID, Self.finderPID, Self.notificationsPID])
        #expect(Set(excepting) == [2, 21], "Finder's normal window stays, icons/widget/banner go")
    }

    @Test func ourAppNotListedFallsBackToExcludingWindows() throws {
        var snapshot = Self.snapshot
        snapshot.applications.removeAll { $0.pid == Self.ownPID }
        let plan = try Builder.plan(Self.options(notifications: true), snapshot: snapshot)
        #expect(plan == .excludingWindows([1, 30]))
    }

    @Test func windowModeIncludesOnlyTheWindowAndOverlays() throws {
        let plan = try Builder.plan(Self.options(window: .init(windowID: 10), notifications: true), snapshot: Self.snapshot)
        #expect(plan == .includingWindows([10, 2]))
        #expect(plan.isWindowMode)
    }

    @Test func applicationStrategyIncludesTheWholeApp() throws {
        let plan = try Builder.plan(Self.options(window: .init(windowID: 10, strategy: .application)), snapshot: Self.snapshot)
        #expect(plan == .includingApplications(pids: [Self.otherPID], exceptingWindows: [2]))
    }

    @Test func applicationStrategyOnOurOwnWindowStaysWindowOnly() throws {
        let plan = try Builder.plan(Self.options(window: .init(windowID: 1, strategy: .application)), snapshot: Self.snapshot)
        #expect(plan == .includingWindows([1, 2]))
    }

    @Test func missingWindowThrows() {
        #expect(throws: RecordingError.self) {
            try Builder.plan(Self.options(window: .init(windowID: 999)), snapshot: Self.snapshot)
        }
    }

    @Test func optionsFromSourceConfiguration() {
        let window = RecordingSourceConfiguration(
            target: .window(10), displayID: 3, sourceRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            pixelSize: CGSize(width: 20, height: 20), fps: 30, showsCursor: true,
            exceptedWindowIDs: [5], excludesNotifications: true
        )
        let options = Builder.options(for: window, hidesDesktopIcons: true)
        #expect(options.window == .init(windowID: 10, strategy: .window))
        #expect(options.displayID == 3)
        #expect(options.exceptedWindowIDs == [5])
        #expect(options.excludesNotifications, "DND layer 1 must reach the filter")
        #expect(options.hidesDesktopIcons)

        var display = window
        display.target = .display(3)
        display.excludesNotifications = false
        let displayOptions = Builder.options(for: display, hidesDesktopIcons: false)
        #expect(displayOptions.window == nil)
        #expect(!displayOptions.excludesNotifications)
    }
}

// MARK: - RecordingEnvironment

private final class FakeIconHider: DesktopIconHiding {
    var isHidden: Bool
    var calls: [Bool] = []
    init(hidden: Bool = false) { isHidden = hidden }
    func setHidden(_ hidden: Bool) {
        calls.append(hidden)
        isHidden = hidden
    }
}

private final class FakeSleepPreventer: SleepPreventing {
    var active = false
    var begins = 0
    func beginPreventingSleep(reason: String) {
        active = true
        begins += 1
    }

    func endPreventingSleep() { active = false }
}

private actor FakeShortcuts: ShortcutRunning {
    private(set) var runs: [String] = []
    private let results: [String: ShortcutRunResult]
    private let delay: Duration

    init(results: [String: ShortcutRunResult] = [:], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func run(_ name: String, timeout: Duration) async -> ShortcutRunResult {
        runs.append(name)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return results[name] ?? .succeeded
    }
}

@Suite("Recording environment", .serialized)
struct RecordingEnvironmentTests {
    static func settings() -> (AppSettings, UserDefaults, String) {
        let suite = "com.hakanyucel.hakoshot.tests.env.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test func beginEndRestoresIconsAndSleep() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let icons = FakeIconHider()
        let sleep = FakeSleepPreventer()
        let shortcuts = FakeShortcuts()
        let environment = RecordingEnvironment(iconHider: icons, sleepPreventer: sleep, shortcuts: shortcuts, settings: settings)

        environment.begin(.init(hideDesktopIcons: true))
        #expect(icons.isHidden)
        #expect(sleep.active)
        #expect(environment.isActive)

        environment.end()
        #expect(!icons.isHidden)
        #expect(!sleep.active)
        #expect(!environment.isActive)
        #expect(icons.calls == [true, false])

        environment.end() // idempotent
        #expect(icons.calls == [true, false])
        await environment.waitForShortcuts()
        #expect(await shortcuts.runs.isEmpty)
    }

    @Test func iconsAlreadyHiddenStayHidden() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let icons = FakeIconHider(hidden: true)
        let environment = RecordingEnvironment(iconHider: icons, sleepPreventer: FakeSleepPreventer(), shortcuts: FakeShortcuts(), settings: settings)
        environment.begin(.init(hideDesktopIcons: true))
        environment.end()
        #expect(icons.isHidden, "the user's own toggle state is kept")
        #expect(icons.calls.isEmpty)
    }

    @Test func focusShortcutsRunOnThenOff() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        // "On" is slow: begin must not wait for it, and "Off" must run after it.
        let shortcuts = FakeShortcuts(delay: .milliseconds(200))
        let environment = RecordingEnvironment(iconHider: FakeIconHider(), sleepPreventer: FakeSleepPreventer(), shortcuts: shortcuts, settings: settings)

        let started = ContinuousClock.now
        environment.begin(.init(focusOnShortcut: " HakoShot Focus On ", focusOffShortcut: "HakoShot Focus Off"))
        #expect(ContinuousClock.now - started < .milliseconds(100), "begin must not block on shortcuts")
        #expect(settings.value(for: .recordingFocusRestorePending) == "HakoShot Focus Off")
        environment.end()
        await environment.waitForShortcuts()
        #expect(await shortcuts.runs == ["HakoShot Focus On", "HakoShot Focus Off"])
        #expect(settings.value(for: .recordingFocusRestorePending) == "")
    }

    @Test func optionsFromSettingsNeedDoNotDisturb() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.set("On", for: .recordingFocusOnShortcut)
        settings.set("Off", for: .recordingFocusOffShortcut)
        var recording = RecordingOptions.default
        recording.hideDesktopIcons = true
        recording.doNotDisturb = false
        let off = RecordingEnvironment.Options(recording: recording, settings: settings)
        #expect(off.focusOnShortcut == nil)
        #expect(off.hideDesktopIcons)
        recording.doNotDisturb = true
        let on = RecordingEnvironment.Options(recording: recording, settings: settings)
        #expect(on.focusOnShortcut == "On")
        #expect(on.focusOffShortcut == "Off")
    }

    @Test func failingShortcutWarnsOnce() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = FakeShortcuts(results: ["Missing": .failed(status: 1, message: "not found")])
        let environment = RecordingEnvironment(iconHider: FakeIconHider(), sleepPreventer: FakeSleepPreventer(), shortcuts: shortcuts, settings: settings)
        var warnings: [String] = []
        environment.onFocusShortcutWarning = { warnings.append($0) }

        for _ in 0 ..< 2 {
            environment.begin(.init(focusOnShortcut: "Missing", focusOffShortcut: "Missing"))
            environment.end()
            await environment.waitForShortcuts()
        }
        #expect(warnings.count == 1)
        #expect(settings.value(for: .recordingFocusShortcutWarningShown))
        #expect(await shortcuts.runs.count == 4)
    }

    @Test func crashRecoveryRunsFocusOff() async throws {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.set("HakoShot Focus Off", for: .recordingFocusRestorePending)
        let shortcuts = FakeShortcuts()
        RecordingEnvironment.recoverAfterCrash(settings: settings, shortcuts: shortcuts)
        #expect(settings.value(for: .recordingFocusRestorePending) == "")
        let deadline = ContinuousClock.now + .seconds(2)
        while await shortcuts.runs.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await shortcuts.runs == ["HakoShot Focus Off"])
    }

    @Test func shellRunnerTimesOutAndReportsFailures() async {
        let sleep = await ShellShortcutRunner.execute(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(200))
        #expect(sleep.result == .timedOut)
        let failing = await ShellShortcutRunner.execute(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: .seconds(5))
        if case .failed = failing.result {} else { Issue.record("expected failure, got \(failing.result)") }
        let echo = await ShellShortcutRunner.execute(URL(fileURLWithPath: "/bin/echo"), arguments: ["a"], timeout: .seconds(5))
        #expect(echo.result == .succeeded)
        #expect(echo.stdout == "a\n")
        let missing = await ShellShortcutRunner.execute(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: .seconds(1))
        if case .launchFailed = missing.result {} else { Issue.record("expected launch failure, got \(missing.result)") }
    }
}

// MARK: - DEBUG parameters

@Suite("Recording target debug parameters")
struct RecordingTargetDebugTests {
    static func items(_ query: String) -> [URLQueryItem] {
        URLComponents(string: "hakoshot://record-screen?\(query)")?.queryItems ?? []
    }

    @Test func targetParameters() {
        let window = RecordingTargetDebug.TargetParameters(queryItems: Self.items("mode=window&window=frontmost&start=true"))
        #expect(window.mode == .window)
        #expect(window.window == .frontmost)
        let fullscreen = RecordingTargetDebug.TargetParameters(queryItems: Self.items("mode=fullscreen&display=2"))
        #expect(fullscreen.mode == .fullscreen)
        #expect(fullscreen.display == 2)
        #expect(RecordingTargetDebug.TargetParameters(queryItems: Self.items("window=1234")).mode == .window)
        #expect(RecordingTargetDebug.TargetParameters(queryItems: Self.items("window=1234")).window == .id(1234))
        #expect(RecordingTargetDebug.TargetParameters(queryItems: Self.items("display=0")).display == nil)
    }

    @Test func displayNumbersStartAtMain() {
        let layout = DisplayLayout(
            displays: [
                DisplayDescriptor(id: 5, appKitFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), backingScaleFactor: 1),
                DisplayDescriptor(id: 7, appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), backingScaleFactor: 2),
            ],
            mainDisplayID: 7
        )
        #expect(RecordingTargetDebug.displayID(number: 1, layout: layout) == 7)
        #expect(RecordingTargetDebug.displayID(number: 2, layout: layout) == 5)
        #expect(RecordingTargetDebug.displayID(number: 3, layout: layout) == nil)
        #expect(RecordingTargetDebug.target(for: .init(mode: .fullscreen, display: 2), layout: layout) == .display(5))
        #expect(RecordingTargetDebug.target(for: .init(mode: .fullscreen), layout: layout) == .display(7))
        #expect(RecordingTargetDebug.target(for: .init(mode: .window, window: .id(99)), layout: layout) == .window(99))
        #expect(RecordingTargetDebug.target(for: .init(mode: .area), layout: layout) == nil)
    }

    @Test func moveParameters() {
        let parameters = RecordingTargetDebug.MoveParameters(queryItems: Self.items("x=10&y=20&width=300&height=200&dx=5&interval=100&seconds=4"))
        #expect(parameters.rect == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(parameters.dx == 5)
        #expect(parameters.interval == .milliseconds(100))
        #expect(parameters.seconds == 4)
    }

    @Test func testWindowMovesAndBounces() throws {
        let layout = DisplayLayoutProvider.currentLayout()
        guard let main = layout.mainDisplay else { return }
        let window = RecordingTargetDebug.MovingTestWindow(global: GlobalRect(x: 100, y: 100, width: 200, height: 150), layout: layout)
        defer { window.close() }
        let start = window.window.frame.origin
        window.moveOnce(by: CGVector(dx: 30, dy: 0))
        #expect(window.window.frame.origin.x == start.x + 30)
        // At the right edge the step flips.
        window.window.setFrameOrigin(CGPoint(x: main.appKitFrame.maxX - 210, y: start.y))
        let next = window.moveOnce(by: CGVector(dx: 30, dy: 0))
        #expect(next.dx == -30)
        #expect(window.window.frame.maxX <= main.appKitFrame.maxX)
    }
}

// MARK: - Real window recording

@Suite("Window recording (real screen)", .serialized)
struct WindowRecordingRealTests {

    /// The window filter (`SCContentFilter(display:including:)` + source
    /// rect) shows the target window even with another window on top of it.
    @Test(.enabled(if: ScreenAvailability.isUsable, "Screen is locked or the test host has no Screen Recording permission"),
          .timeLimit(.minutes(1)))
    func windowFilterShowsOnlyTheTarget() async throws {
        let layout = DisplayLayoutProvider.currentLayout()
        let target = RecordingSpikeTests.colorWindow(.init(srgbRed: 0, green: 1, blue: 0, alpha: 1), global: GlobalRect(x: 300, y: 300, width: 200, height: 150), layout: layout)
        let cover = RecordingSpikeTests.colorWindow(.init(srgbRed: 1, green: 0, blue: 0, alpha: 1), global: GlobalRect(x: 350, y: 330, width: 100, height: 80), layout: layout)
        defer { target.close(); cover.close() }
        try await Task.sleep(for: .milliseconds(500))

        let windowID = CGWindowID(target.windowNumber)
        let resolved = try RecordingEngine.resolve(.window(windowID), layout: layout, windowBounds: RecordingEngine.windowBounds(of:))
        let configuration = RecordingSourceConfiguration(
            target: .window(windowID), displayID: resolved.displayID, sourceRect: resolved.sourceRect,
            pixelSize: CGSize(width: 400, height: 300), fps: 30, showsCursor: false, excludesNotifications: true
        )
        let content = try await ContentFilterBuilder.fetchContent()
        let options = ContentFilterBuilder.options(for: configuration, hidesDesktopIcons: false)
        #expect(try ContentFilterBuilder.plan(options, snapshot: ContentFilterBuilder.snapshot(of: content)) == .includingWindows([windowID]))
        let filter = try ContentFilterBuilder.makeFilter(options, content: content)
        let streamConfiguration = ScreenStreamSource.makeConfiguration(configuration)
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfiguration)
        // Center of the target (under the red cover) and its corner.
        let center = try #require(RecordingSpikeTests.pixel(image, x: image.width / 2, y: image.height / 2))
        let corner = try #require(RecordingSpikeTests.pixel(image, x: 10, y: 10))
        RecordingSpikeTests.log("r14 window filter: center \(center) corner \(corner) size \(image.width)x\(image.height)")
        #expect(center.g > 180 && center.r < 90, "covered center \(center)")
        #expect(corner.g > 180 && corner.r < 90, "corner \(corner)")
    }
    /// Records the moving test window for 3 s and checks that its quadrant
    /// colors stay in place in several frames. Only pixel values are checked;
    /// the file is deleted.
    @Test(.enabled(if: ScreenAvailability.isUsable, "Screen is locked or the test host has no Screen Recording permission"),
          .timeLimit(.minutes(1)))
    func followedWindowStaysInPlace() async throws {
        let window = RecordingTargetDebug.showMovingTestWindow(.init(
            rect: CGRect(x: 150, y: 150, width: 400, height: 300), dx: 30, dy: 10, interval: .milliseconds(250), seconds: 30
        ))
        defer { RecordingTargetDebug.closeTestWindow() }
        try await Task.sleep(for: .milliseconds(500))
        let startFrame = window.window.frame

        let out = FileManager.default.temporaryDirectory.appending(path: "hakoshot-r14-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await RecordingTargetDebug.recordFollowing(windowID: window.windowID, seconds: 3, out: out)
        // Manual check with scripts/frame-at + pixel-probe (delete afterwards).
        if let keep = ProcessInfo.processInfo.environment["HAKO_R14_KEEP_VIDEO"] {
            try? FileManager.default.removeItem(atPath: keep)
            try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: keep))
        }
        let endFrame = window.window.frame
        RecordingSpikeTests.log("r14 window: moved \(endFrame.minX - startFrame.minX),\(endFrame.minY - startFrame.minY) pt, \(result.sourceRectUpdates) updates, \(result.pixelSize), \(String(format: "%.3f", result.duration)) s")

        #expect(result.sourceRectUpdates >= 5, "follower updated \(result.sourceRectUpdates) times")
        #expect(abs(endFrame.minX - startFrame.minX) > 60, "window did not move")
        #expect(abs(result.duration - 3) < 0.5)

        let width = Int(result.pixelSize.width)
        let height = Int(result.pixelSize.height)
        for seconds in [0.2, 1.0, 1.8, 2.6] {
            let image = try await RecordingSpikeTests.frame(out, at: seconds)
            #expect(image.width == width && image.height == height)
            let tl = try #require(RecordingSpikeTests.pixel(image, x: width / 4, y: height / 4))
            let tr = try #require(RecordingSpikeTests.pixel(image, x: width * 3 / 4, y: height / 4))
            let bl = try #require(RecordingSpikeTests.pixel(image, x: width / 4, y: height * 3 / 4))
            let br = try #require(RecordingSpikeTests.pixel(image, x: width * 3 / 4, y: height * 3 / 4))
            RecordingSpikeTests.log("r14 t=\(seconds): tl \(tl) tr \(tr) bl \(bl) br \(br)")
            #expect(tl.r > 180 && tl.g < 90 && tl.b < 90, "t=\(seconds) top-left \(tl)")
            #expect(tr.g > 180 && tr.r < 90 && tr.b < 90, "t=\(seconds) top-right \(tr)")
            #expect(bl.b > 180 && bl.r < 90 && bl.g < 90, "t=\(seconds) bottom-left \(bl)")
            #expect(br.r > 180 && br.g > 180 && br.b < 90, "t=\(seconds) bottom-right \(br)")
        }
    }
}
