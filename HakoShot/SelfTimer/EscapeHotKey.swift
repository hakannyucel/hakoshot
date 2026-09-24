import AppKit
import Carbon.HIToolbox
import os

/// A temporary global `Esc` hot key (Carbon `RegisterEventHotKey`), so the
/// self-timer countdown can be cancelled while another app is frontmost.
/// Needs no Accessibility permission. While registered, `Esc` goes to us
/// system-wide, so keep it short-lived (the countdown only).
///
/// KeyboardShortcuts installs its own Carbon handler; it returns
/// `eventNotHandledErr` for our signature, so both coexist.
final class EscapeHotKey {
    private static let signature: OSType = 0x484B_5445 // 'HKTE'
    private static var active: EscapeHotKey?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    /// Registers `Esc`; `nil` if Carbon refuses (e.g. another app holds it).
    init?(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var handler: EventHandlerRef?
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), escapeHotKeyHandler, 1, &spec, nil, &handler)
        guard installed == noErr else {
            Log.selfTimer.error("InstallEventHandler failed: \(installed)")
            return nil
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape), 0,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.selfTimer.error("RegisterEventHotKey(Esc) failed: \(status)")
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        hotKeyRef = ref
        handlerRef = handler
        Self.active = self
    }

    /// Unregisters; safe to call more than once.
    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        if Self.active === self { Self.active = nil }
    }

    fileprivate static func handle(signature received: OSType) -> OSStatus {
        guard received == signature, let active else { return OSStatus(eventNotHandledErr) }
        active.onPress()
        return noErr
    }
}

/// Carbon delivers hot key events on the main thread.
private nonisolated func escapeHotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let signature = id.signature
    return MainActor.assumeIsolated { EscapeHotKey.handle(signature: signature) }
}
