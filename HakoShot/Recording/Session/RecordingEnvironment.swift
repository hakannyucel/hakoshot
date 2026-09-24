import AppKit
import Foundation
import HakoKit
import os

/// Desktop icon hiding, as `DesktopIconsToggle` does it (seam for tests).
protocol DesktopIconHiding: AnyObject {
    var isHidden: Bool { get }
    func setHidden(_ hidden: Bool)
}

extension DesktopIconsToggle: DesktopIconHiding {}

/// Keeps the display (and system) awake (seam for tests).
protocol SleepPreventing: AnyObject {
    func beginPreventingSleep(reason: String)
    func endPreventingSleep()
}

/// Runs a Shortcuts.app shortcut by name (seam for tests).
nonisolated protocol ShortcutRunning: Sendable {
    func run(_ name: String, timeout: Duration) async -> ShortcutRunResult
}

nonisolated enum ShortcutRunResult: Sendable, Equatable {
    case succeeded
    /// Non-zero exit (e.g. no shortcut with that name).
    case failed(status: Int32, message: String)
    case timedOut
    case launchFailed(String)

    var isSuccess: Bool { self == .succeeded }
}

/// What the recording changes around it, and puts back afterwards (plan
/// §4.11, §4.12, R1.4):
///
/// - desktop icons hidden with the screenshot mechanism
///   (`DesktopIconsToggle`); restored to the state they had before;
/// - display / idle sleep prevented (`ProcessInfo.beginActivity`
///   `.idleDisplaySleepDisabled`, which also keeps the screen from dimming);
/// - Do Not Disturb, layer 1: notification banners are left out of the video
///   by `ContentFilterBuilder` (`RecordingOptions.doNotDisturb` →
///   `RecordingSourceConfiguration.excludesNotifications`); nothing to do here;
/// - Do Not Disturb, layer 2: the user's "Focus On" / "Focus Off" shortcuts
///   (`recordingFocusOnShortcut` / `recordingFocusOffShortcut`) run through
///   `/usr/bin/shortcuts run` in the background with a timeout. The
///   recording never waits for them; "Off" waits for "On" to finish. A
///   failure warns once (`recordingFocusShortcutWarningShown`).
///
/// `begin` / `end` are idempotent; `end()` must run on every path (stop,
/// discard, failure, app termination). If the app dies while Focus is on,
/// `recoverAfterCrash()` at the next launch runs the "Off" shortcut.
final class RecordingEnvironment {
    struct Options: Sendable, Equatable {
        var hideDesktopIcons = false
        var preventSleep = true
        /// DND layer 2 names; empty / `nil` = not set up.
        var focusOnShortcut: String?
        var focusOffShortcut: String?

        /// From the recording options and the Focus shortcut settings.
        /// Shortcuts only run when "Do Not Disturb while recording" is on.
        init(recording options: RecordingOptions, settings: AppSettings) {
            hideDesktopIcons = options.hideDesktopIcons
            preventSleep = true
            if options.doNotDisturb {
                focusOnShortcut = Self.cleaned(settings.value(for: .recordingFocusOnShortcut))
                focusOffShortcut = Self.cleaned(settings.value(for: .recordingFocusOffShortcut))
            }
        }

        init(hideDesktopIcons: Bool = false, preventSleep: Bool = true, focusOnShortcut: String? = nil, focusOffShortcut: String? = nil) {
            self.hideDesktopIcons = hideDesktopIcons
            self.preventSleep = preventSleep
            self.focusOnShortcut = Self.cleaned(focusOnShortcut)
            self.focusOffShortcut = Self.cleaned(focusOffShortcut)
        }

        static func cleaned(_ name: String?) -> String? {
            guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    /// Per-shortcut timeout (plan §4.11; "never block the recording").
    nonisolated static let shortcutTimeout: Duration = .seconds(10)

    private let iconHider: any DesktopIconHiding
    private let sleepPreventer: any SleepPreventing
    private let shortcuts: any ShortcutRunning
    private let settings: AppSettings

    /// Called on the main actor when a Focus shortcut failed and the user
    /// hasn't been warned yet (e.g. show a toast).
    var onFocusShortcutWarning: ((String) -> Void)?

    private(set) var isActive = false
    private var active: Options?
    /// Icons were visible before `begin` and we hid them.
    private var didHideIcons = false
    private var focusOnTask: Task<ShortcutRunResult, Never>?
    private var focusTasks: [Task<Void, Never>] = []

    init(
        iconHider: any DesktopIconHiding = DesktopIconsToggle.shared,
        sleepPreventer: any SleepPreventing = ActivitySleepPreventer(),
        shortcuts: any ShortcutRunning = ShellShortcutRunner(),
        settings: AppSettings = .shared
    ) {
        self.iconHider = iconHider
        self.sleepPreventer = sleepPreventer
        self.shortcuts = shortcuts
        self.settings = settings
    }

    // MARK: Begin / end

    /// Applies `options`. Returns at once; Focus shortcuts run in the background.
    func begin(_ options: Options) {
        guard !isActive else {
            Log.recording.notice("environment: begin ignored (already active)")
            return
        }
        isActive = true
        active = options

        if options.hideDesktopIcons, !iconHider.isHidden {
            iconHider.setHidden(true)
            didHideIcons = true
        }
        if options.preventSleep {
            sleepPreventer.beginPreventingSleep(reason: "HakoShot screen recording")
        }
        if let name = options.focusOnShortcut {
            // Remember "Off" before running "On" so a crash in between still restores.
            if let off = options.focusOffShortcut { settings.set(off, for: .recordingFocusRestorePending) }
            let shortcuts = shortcuts
            let task = Task.detached(priority: .userInitiated) {
                await shortcuts.run(name, timeout: Self.shortcutTimeout)
            }
            focusOnTask = task
            focusTasks.append(Task { [weak self] in
                let result = await task.value
                self?.report(result, shortcut: name)
            })
        }
        Log.recording.notice("environment: begin (icons \(options.hideDesktopIcons), sleep \(options.preventSleep), focus \(options.focusOnShortcut != nil))")
    }

    /// Restores everything `begin` changed. Safe to call more than once and
    /// without `begin`.
    func end() {
        guard isActive, let options = active else { return }
        isActive = false
        active = nil

        if didHideIcons {
            iconHider.setHidden(false)
            didHideIcons = false
        }
        if options.preventSleep {
            sleepPreventer.endPreventingSleep()
        }
        if options.focusOnShortcut != nil, let off = options.focusOffShortcut {
            let onTask = focusOnTask
            let shortcuts = shortcuts
            let task = Task.detached(priority: .userInitiated) { () -> ShortcutRunResult in
                _ = await onTask?.value
                return await shortcuts.run(off, timeout: Self.shortcutTimeout)
            }
            let settings = settings
            focusTasks.append(Task { [weak self] in
                let result = await task.value
                settings.set("", for: .recordingFocusRestorePending)
                self?.report(result, shortcut: off)
            })
        }
        focusOnTask = nil
        Log.recording.notice("environment: end")
    }

    /// Waits for pending Focus shortcut runs (tests, app termination).
    func waitForShortcuts() async {
        while !focusTasks.isEmpty {
            let tasks = focusTasks
            focusTasks.removeAll()
            for task in tasks { await task.value }
        }
    }

    private func report(_ result: ShortcutRunResult, shortcut name: String) {
        switch result {
        case .succeeded:
            Log.recording.notice("environment: shortcut \"\(name, privacy: .public)\" ran")
            return
        case let .failed(status, message):
            Log.recording.error("environment: shortcut \"\(name, privacy: .public)\" failed (\(status)): \(message, privacy: .public)")
        case .timedOut:
            Log.recording.error("environment: shortcut \"\(name, privacy: .public)\" timed out")
        case let .launchFailed(message):
            Log.recording.error("environment: shortcuts launch failed: \(message, privacy: .public)")
        }
        guard !settings.value(for: .recordingFocusShortcutWarningShown) else { return }
        settings.set(true, for: .recordingFocusShortcutWarningShown)
        onFocusShortcutWarning?("Couldn't run the Focus shortcut “\(name)”. Notifications are still kept out of the recording.")
    }

    // MARK: Crash recovery

    /// Runs the "Focus Off" shortcut if the app quit while a recording had
    /// Focus on (call once at launch). Other changes don't outlive the
    /// process: the icon covers are our windows and the sleep assertion is
    /// released by the system.
    static func recoverAfterCrash(settings: AppSettings = .shared, shortcuts: any ShortcutRunning = ShellShortcutRunner()) {
        guard let name = Options.cleaned(settings.value(for: .recordingFocusRestorePending)) else { return }
        settings.set("", for: .recordingFocusRestorePending)
        Log.recording.notice("environment: restoring Focus after an interrupted recording")
        Task.detached(priority: .utility) {
            _ = await shortcuts.run(name, timeout: shortcutTimeout)
        }
    }
}

extension SettingsKey where Value == String {
    /// Internal: the "Focus Off" shortcut to run at next launch when a
    /// recording ended without `RecordingEnvironment.end()`. "" = nothing pending.
    static var recordingFocusRestorePending: SettingsKey<String> {
        SettingsKey("recordingFocusRestorePending", default: "")
    }
}

// MARK: - Live implementations

/// `ProcessInfo` activity: user-initiated work with idle display sleep off.
final class ActivitySleepPreventer: SleepPreventing {
    private var activity: (any NSObjectProtocol)?

    func beginPreventingSleep(reason: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: reason)
    }

    func endPreventingSleep() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

/// `/usr/bin/shortcuts run <name>`; terminated after `timeout`.
nonisolated struct ShellShortcutRunner: ShortcutRunning {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    func run(_ name: String, timeout: Duration) async -> ShortcutRunResult {
        await Self.execute(Self.executable, arguments: ["run", name], timeout: timeout).result
    }

    /// Names of the user's shortcuts (`shortcuts list`), for the setup sheet.
    static func listShortcuts(timeout: Duration = .seconds(10)) async -> [String] {
        let output = await execute(executable, arguments: ["list"], timeout: timeout)
        guard output.result.isSuccess else { return [] }
        return output.stdout.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.isEmpty }
    }

    /// Runs a process off the caller's executor; kills it after `timeout`.
    static func execute(_ url: URL, arguments: [String], timeout: Duration) async -> (result: ShortcutRunResult, stdout: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(result: ShortcutRunResult, stdout: String), Never>) in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { finished in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if box.didTimeOut {
                    once.resume((.timedOut, out))
                } else if finished.terminationStatus == 0 {
                    once.resume((.succeeded, out))
                } else {
                    once.resume((.failed(status: finished.terminationStatus, message: err.trimmingCharacters(in: .whitespacesAndNewlines)), out))
                }
            }
            do {
                try process.run()
            } catch {
                once.resume((.launchFailed(error.localizedDescription), ""))
                return
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                box.terminateIfRunning()
            }
        }
    }
}

/// Timeout flag + termination across the handler and the timer (`Process` isn't Sendable).
private nonisolated final class ProcessBox: @unchecked Sendable {
    // @unchecked: `timedOut` guarded by `lock`; `Process.terminate` is thread-safe.
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false

    init(_ process: Process) { self.process = process }

    var didTimeOut: Bool { lock.withLock { timedOut } }

    func terminateIfRunning() {
        guard process.isRunning else { return }
        lock.withLock { timedOut = true }
        process.terminate()
    }
}

private nonisolated final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    // @unchecked: `continuation` guarded by `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
