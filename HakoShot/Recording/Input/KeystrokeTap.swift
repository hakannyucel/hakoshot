import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import HakoKit
import os

/// A key event from the tap, stamped in host seconds (plan §1.6).
nonisolated struct TappedKeyEvent: Sendable, Equatable {
    var hostTime: Double
    var kind: RecordingKeyEvent.Kind
    /// Virtual key code (`kVK_*`).
    var keyCode: UInt16
    /// Raw `CGEventFlags` bits.
    var modifierFlags: UInt64
    /// Characters with no modifiers applied (`UCKeyTranslate`); `nil` for
    /// `flagsChanged` and keys without a character.
    var characters: String?
    var isRepeat: Bool
}

/// Listen-only `CGEventTap` for `keyDown` / `flagsChanged` (plan §1.6).
///
/// - Needs **Input Monitoring**. `start()` only preflights
///   (`CGPreflightListenEventAccess`): without the permission it stays off
///   and reports `.permissionMissing` so the UI can warn. It never prompts.
/// - Never captures during Secure Event Input (password fields): every event
///   is dropped while `IsSecureEventInputEnabled()` is on, and
///   `didSkipSecureInput` is set.
/// - Characters come from `UCKeyTranslate` with no modifiers, so ⌥/⇧ don't
///   change the letter shown on the badge and non-US layouts show their own
///   letters.
///
/// The tap runs on the main run loop; events reach `onEvent` on the main actor.
@MainActor
final class KeystrokeTap {
    enum Status: String, Sendable, Equatable {
        /// Not started (or stopped).
        case off
        case running
        /// Input Monitoring not granted: silently off, the UI should warn.
        case permissionMissing
        /// `CGEvent.tapCreate` returned nil (usually the permission needs a relaunch).
        case tapFailed
    }

    /// The system checks, injectable for tests (so tests never touch TCC).
    struct Environment {
        var isPermissionGranted: () -> Bool
        var isSecureInputEnabled: () -> Bool
        var characters: (UInt16) -> String?

        static let live = Environment(
            isPermissionGranted: { InputMonitoringPermission.isGranted },
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            characters: { KeystrokeTap.characters(forKeyCode: $0) }
        )
    }

    private(set) var status: Status = .off
    /// At least one event was dropped because Secure Event Input was on.
    private(set) var didSkipSecureInput = false
    private(set) var skippedSecureInputEvents = 0

    private let environment: Environment
    private let onEvent: (TappedKeyEvent) -> Void
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var box: TapBox?

    init(environment: Environment = .live, onEvent: @escaping (TappedKeyEvent) -> Void) {
        self.environment = environment
        self.onEvent = onEvent
    }

    // `stop()` must run before release; the tap retains nothing of ours but
    // the box, which only holds a weak reference.

    var isRunning: Bool { status == .running }

    /// Starts the tap if Input Monitoring is granted; otherwise stays off.
    /// Returns the new status. Idempotent while running.
    @discardableResult
    func start() -> Status {
        if status == .running { return status }
        guard environment.isPermissionGranted() else {
            status = .permissionMissing
            Log.recording.notice("keystroke tap: Input Monitoring not granted; keystrokes are off")
            return status
        }
        let box = TapBox(tap: self)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keystrokeTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            status = .tapFailed
            Log.recording.error("keystroke tap: CGEvent.tapCreate failed (relaunch after granting Input Monitoring?)")
            return status
        }
        box.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.box = box
        self.port = port
        self.runLoopSource = source
        status = .running
        Log.recording.notice("keystroke tap running")
        return status
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        box?.port = nil
        box?.tap = nil
        port = nil
        runLoopSource = nil
        box = nil
        if status == .running { status = .off }
    }

    /// One tap event (or a synthetic one). Dropped while Secure Event Input
    /// is on. Fills `characters` for key downs when missing.
    func ingest(_ event: TappedKeyEvent) {
        guard !environment.isSecureInputEnabled() else {
            if !didSkipSecureInput { Log.recording.notice("keystroke tap: secure input on; skipping keys") }
            didSkipSecureInput = true
            skippedSecureInputEvents += 1
            return
        }
        var event = event
        if event.kind == .keyDown, event.characters == nil,
           !KeystrokeFormatter.modifierKeyCodes.contains(event.keyCode) {
            event.characters = environment.characters(event.keyCode)
        }
        onEvent(event)
    }

    /// The tap was disabled by the system (callback too slow / user input).
    fileprivate func reenable() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        Log.recording.notice("keystroke tap re-enabled")
    }

    // MARK: Characters

    /// The character a key produces with **no** modifiers on the current
    /// keyboard layout (`UCKeyTranslate`, no dead keys). Main thread (TIS).
    static func characters(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

/// Handed to the C callback; weak so the tap owner controls the lifetime.
private nonisolated final class TapBox: @unchecked Sendable {
    // Written on the main actor only; read by the callback on the main run loop.
    weak var tap: KeystrokeTap?
    var port: CFMachPort?

    init(tap: KeystrokeTap) { self.tap = tap }
}

/// Main-run-loop event tap callback (listen-only: always passes the event on).
private nonisolated func keystrokeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<TapBox>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { box.tap?.reenable() }
    case .keyDown, .flagsChanged:
        let tapped = TappedKeyEvent(
            hostTime: HostTime.seconds(fromCGEventTimestamp: event.timestamp),
            kind: type == .keyDown ? .keyDown : .flagsChanged,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            modifierFlags: event.flags.rawValue,
            characters: nil,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        MainActor.assumeIsolated { box.tap?.ingest(tapped) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
