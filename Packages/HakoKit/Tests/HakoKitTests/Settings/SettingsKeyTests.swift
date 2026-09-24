import Testing
@testable import HakoKit

/// A feature would normally declare its keys via `extension SettingsKey`
/// constrained on `Value`, in its own file. Mirrored here to test the
/// pattern without adding a real feature key to HakoKit's public surface.
private extension SettingsKey where Value == Bool {
    static var testFlag: SettingsKey<Bool> {
        SettingsKey("testFlag", default: true)
    }
}

private extension SettingsKey where Value == Int {
    static var testCount: SettingsKey<Int> {
        SettingsKey("testCount", default: 0)
    }
}

@Suite("SettingsKey")
struct SettingsKeyTests {
    @Test func nameAndDefaultValueRoundTrip() {
        let key = SettingsKey<Bool>.testFlag
        #expect(key.name == "testFlag")
        #expect(key.defaultValue == true)
    }

    @Test func extensionPointDeclaresKeysPerFeature() {
        #expect(SettingsKey<Int>.testCount.name == "testCount")
        #expect(SettingsKey<Int>.testCount.defaultValue == 0)
    }

    @Test func keysWithSameNameAndValueTypeAreEqual() {
        let a = SettingsKey<Bool>("shared", default: true)
        let b = SettingsKey<Bool>("shared", default: false) // default differs, name doesn't
        #expect(a == b)
    }

    @Test func keysWithDifferentNamesAreNotEqual() {
        let a = SettingsKey<Bool>("one", default: true)
        let b = SettingsKey<Bool>("two", default: true)
        #expect(a != b)
    }

    @Test func keyIsUsableAsDictionaryKey() {
        var overrides: [SettingsKey<Bool>: Bool] = [:]
        overrides[.testFlag] = false
        #expect(overrides[.testFlag] == false)
    }
}
