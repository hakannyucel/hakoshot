import HakoKit
import SwiftUI

/// `@AppStorage` from a `SettingsKey`, so settings pages share names and
/// defaults with `AppSettings.shared` (both use `UserDefaults.standard`) and
/// update live:
/// ```swift
/// @AppStorage(.afterCapturePin) private var pin: Bool
/// ```
extension AppStorage where Value == Bool {
    init(_ key: SettingsKey<Bool>) { self.init(wrappedValue: key.defaultValue, key.name) }
}

extension AppStorage where Value == Int {
    init(_ key: SettingsKey<Int>) { self.init(wrappedValue: key.defaultValue, key.name) }
}

extension AppStorage where Value == Double {
    init(_ key: SettingsKey<Double>) { self.init(wrappedValue: key.defaultValue, key.name) }
}

extension AppStorage where Value == String {
    init(_ key: SettingsKey<String>) { self.init(wrappedValue: key.defaultValue, key.name) }
}

extension AppStorage where Value: RawRepresentable & Sendable, Value.RawValue == String {
    init(_ key: SettingsKey<Value>) { self.init(wrappedValue: key.defaultValue, key.name) }
}
