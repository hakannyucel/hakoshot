import AppKit
import KeyboardShortcuts
import Testing
@testable import HakoShot

@Suite("ShortcutNames")
@MainActor
struct ShortcutNamesTests {
    /// Plan §5.1 defaults.
    @Test func defaultsMatchPlan() throws {
        let expected: [(AppCommand, KeyboardShortcuts.Key)] = [
            (.capture(.allInOne), .one),
            (.captureText(lineBreaks: true), .two),
            (.capture(.fullscreen(.preferred)), .three),
            (.capture(.area), .four),
            (.capture(.window), .five),
            (.capture(.previousArea), .six),
            (.capture(.scrolling), .seven),
            (.capture(.selfTimer), .eight),
        ]
        for (command, key) in expected {
            let name = try #require(ShortcutBinding.name(for: command))
            let shortcut = try #require(name.initialShortcut)
            #expect(shortcut.key == key)
            #expect(shortcut.modifiers == [.command, .shift])
        }
    }

    @Test func unassignedByDefault() {
        for command in [AppCommand.openHistory, .toggleDesktopIcons, .closeAllPins, .openFromClipboard, .captureText(lineBreaks: false)] {
            #expect(ShortcutBinding.name(for: command)?.initialShortcut == nil)
        }
    }

    @Test func everyBindingHasTitleAndGroupOrder() {
        #expect(ShortcutBinding.all.allSatisfy { !$0.title.isEmpty })
        #expect(Set(ShortcutBinding.all.map(\.title)).count == ShortcutBinding.all.count)
        // Listed group by group, Capture → Text → Tools.
        let order = ShortcutBinding.all.map { ShortcutGroup.allCases.firstIndex(of: $0.group) ?? -1 }
        #expect(order == order.sorted())
        #expect(ShortcutBinding.binding(named: "SCROLLINGCAPTURE")?.command == .capture(.scrolling))
        #expect(ShortcutBinding.binding(named: "nope") == nil)
    }

    @Test func namesAreUnique() {
        let names = ShortcutBinding.all.map(\.name.rawValue)
        #expect(Set(names).count == names.count)
    }
}
