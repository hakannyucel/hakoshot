import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import Testing
@testable import HakoShot

@Suite("ShortcutConflictDetector")
struct ShortcutConflictDetectorTests {
    private let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
    private let ctrlCmdShift: NSEvent.ModifierFlags = [.command, .shift, .control]

    private func combo(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) -> ShortcutCombo {
        ShortcutCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// An `AppleSymbolicHotKeys` entry as macOS writes it.
    private func entry(enabled: Bool, ascii: Int, keyCode: Int, flags: Int) -> [String: Any] {
        [
            "enabled": NSNumber(value: enabled),
            "value": ["parameters": [NSNumber(value: ascii), NSNumber(value: keyCode), NSNumber(value: flags)], "type": "standard"] as [String: Any],
        ]
    }

    /// The five screenshot hotkeys with macOS's default combos.
    private func systemDictionary(enabled: [Int: Bool]) -> [String: Any] {
        let defaults: [Int: (Int, Int, Int)] = [
            28: (51, 20, 1_179_648), 29: (51, 20, 1_441_792),
            30: (52, 21, 1_179_648), 31: (52, 21, 1_441_792),
            184: (53, 23, 1_179_648),
        ]
        var result: [String: Any] = ["60": entry(enabled: true, ascii: 32, keyCode: 49, flags: 262_144)]
        for (id, value) in defaults {
            result[String(id)] = entry(enabled: enabled[id] ?? true, ascii: value.0, keyCode: value.1, flags: value.2)
        }
        return result
    }

    private var hakoDefaults: [String: ShortcutCombo] {
        [
            "allInOne": combo(kVK_ANSI_1, cmdShift),
            "captureText": combo(kVK_ANSI_2, cmdShift),
            "captureFullscreen": combo(kVK_ANSI_3, cmdShift),
            "captureArea": combo(kVK_ANSI_4, cmdShift),
            "captureWindow": combo(kVK_ANSI_5, cmdShift),
            "capturePreviousArea": combo(kVK_ANSI_6, cmdShift),
        ]
    }

    // MARK: Combo

    @Test func comboIgnoresNonShortcutModifiers() {
        let a = combo(kVK_ANSI_4, [.command, .shift, .capsLock, .numericPad, .function])
        #expect(a == combo(kVK_ANSI_4, cmdShift))
        #expect(a.modifierSymbols == "⇧⌘")
        #expect(combo(kVK_ANSI_4, ctrlCmdShift).modifierSymbols == "⌃⇧⌘")
        #expect(a.carbonModifiers == cmdKey | shiftKey)
    }

    @Test @MainActor func comboMatchesKeyboardShortcutsShortcut() {
        let shortcut = KeyboardShortcuts.Shortcut(.four, modifiers: [.command, .shift])
        #expect(ShortcutCombo(shortcut) == combo(kVK_ANSI_4, cmdShift))
        let back = KeyboardShortcuts.Shortcut(carbonKeyCode: kVK_ANSI_4, carbonModifiers: ShortcutCombo(shortcut).carbonModifiers)
        #expect(back == shortcut)
    }

    // MARK: HakoShot duplicates

    @Test func duplicatesAmongHakoShotShortcuts() {
        var assignments = hakoDefaults
        #expect(ShortcutConflictDetector.duplicateGroups(in: assignments).isEmpty)
        #expect(ShortcutConflictDetector.duplicates(of: combo(kVK_ANSI_4, cmdShift), excluding: "captureArea", in: assignments).isEmpty)

        assignments["openHistory"] = combo(kVK_ANSI_4, cmdShift)
        assignments["closeAllPins"] = combo(kVK_ANSI_4, cmdShift)
        #expect(
            ShortcutConflictDetector.duplicates(of: combo(kVK_ANSI_4, cmdShift), excluding: "openHistory", in: assignments)
                == ["captureArea", "closeAllPins"]
        )
        let groups = ShortcutConflictDetector.duplicateGroups(in: assignments)
        #expect(groups.count == 1)
        #expect(groups[combo(kVK_ANSI_4, cmdShift)] == ["captureArea", "closeAllPins", "openHistory"])
        // Same key, different modifiers is not a duplicate.
        #expect(ShortcutConflictDetector.duplicates(of: combo(kVK_ANSI_4, ctrlCmdShift), excluding: "x", in: assignments).isEmpty)
    }

    // MARK: macOS screenshot shortcuts

    @Test func allSystemShortcutsOffMeansNoConflicts() {
        let dict = systemDictionary(enabled: [28: false, 29: false, 30: false, 31: false, 184: false])
        let system = ShortcutConflictDetector.systemScreenshotShortcuts(symbolicHotKeys: dict)
        #expect(system.map(\.id) == [28, 29, 30, 31, 184])
        #expect(system.allSatisfy { !$0.isEnabled })
        #expect(ShortcutConflictDetector.systemConflicts(assignments: hakoDefaults, symbolicHotKeys: dict).isEmpty)
    }

    @Test func enabledSystemShortcutConflictsWithHakoShot() {
        let dict = systemDictionary(enabled: [28: false, 29: false, 30: true, 31: true, 184: false])
        let conflicts = ShortcutConflictDetector.systemConflicts(assignments: hakoDefaults, symbolicHotKeys: dict)
        // ⌃⇧⌘4 (31) is on but HakoShot doesn't use it.
        #expect(conflicts.map(\.system.id) == [30])
        #expect(conflicts.first?.names == ["captureArea"])
        #expect(conflicts.first?.system.combo == combo(kVK_ANSI_4, cmdShift))
    }

    @Test func missingDictionaryOrEntryMeansMacOSDefaultsOn() {
        let none = ShortcutConflictDetector.systemConflicts(assignments: hakoDefaults, symbolicHotKeys: nil)
        #expect(none.map(\.system.id) == [28, 30, 184])
        #expect(none.map(\.names) == [["captureFullscreen"], ["captureArea"], ["captureWindow"]])

        // Only 28 customised (off); the others fall back to "on".
        let partial = ShortcutConflictDetector.systemConflicts(
            assignments: hakoDefaults,
            symbolicHotKeys: ["28": entry(enabled: false, ascii: 51, keyCode: 20, flags: 1_179_648)]
        )
        #expect(partial.map(\.system.id) == [30, 184])
    }

    @Test func remappedSystemShortcutUsesItsStoredCombo() {
        // The user moved "selected area to file" to ⌃⇧⌘9 and left it on.
        var dict = systemDictionary(enabled: [28: false, 29: false, 31: false, 184: false])
        dict["30"] = entry(enabled: true, ascii: 57, keyCode: kVK_ANSI_9, flags: 1_441_792)
        #expect(ShortcutConflictDetector.systemConflicts(assignments: hakoDefaults, symbolicHotKeys: dict).isEmpty)

        var assignments = hakoDefaults
        assignments["openHistory"] = combo(kVK_ANSI_9, ctrlCmdShift)
        let conflicts = ShortcutConflictDetector.systemConflicts(assignments: assignments, symbolicHotKeys: dict)
        #expect(conflicts.map(\.names) == [["openHistory"]])
    }

    @Test func entryWithoutValueOrWithOddTypesStillParses() {
        let dict: [String: Any] = [
            "28": ["enabled": "0"] as [String: Any],
            "30": ["enabled": 1] as [String: Any],
            "184": ["enabled": false, "value": ["parameters": [65_535, 65_535, 0]]] as [String: Any],
        ]
        let system = ShortcutConflictDetector.systemScreenshotShortcuts(symbolicHotKeys: dict)
        let byID = Dictionary(uniqueKeysWithValues: system.map { ($0.id, $0) })
        #expect(byID[28]?.isEnabled == false)
        #expect(byID[30]?.isEnabled == true)
        #expect(byID[30]?.combo == combo(kVK_ANSI_4, cmdShift))
        #expect(byID[184]?.isEnabled == false)
        #expect(byID[184]?.combo == combo(kVK_ANSI_5, cmdShift))
    }

    // MARK: Validation

    @Test func recorderValidation() {
        #expect(ShortcutValidation.isAcceptable(combo(kVK_ANSI_4, cmdShift)))
        #expect(ShortcutValidation.isAcceptable(combo(kVK_ANSI_A, [.option])))
        #expect(ShortcutValidation.isAcceptable(combo(kVK_F5, [])))
        #expect(!ShortcutValidation.isAcceptable(combo(kVK_ANSI_A, [])))
        #expect(!ShortcutValidation.isAcceptable(combo(kVK_ANSI_A, [.shift])))
        #expect(!ShortcutValidation.isAcceptable(combo(kVK_Command, [.command])))
    }
}
