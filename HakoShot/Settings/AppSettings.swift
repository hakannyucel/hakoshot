import Foundation
import HakoKit
import Observation

/// The single `UserDefaults` reader/writer for every `SettingsKey` in the app
/// (plan §1.6: "`UserDefaults` + `@Observable final class AppSettings`").
/// `SettingsKey` itself (HakoKit) only carries a name + default value; this
/// type owns the storage mechanics so no feature needs its own UserDefaults
/// boilerplate. Each feature still declares its *own* keys as `extension
/// SettingsKey` in its own file (e.g. `PostCapture/OutputSettings.swift`) —
/// this file never grows a per-feature key list, so it doesn't become a
/// hotspot.
///
/// `@Observable` so SwiftUI settings pages can read `AppSettings.shared`
/// directly; because the underlying storage is `UserDefaults` rather than a
/// stored property, callers that need live updates while a page is open
/// should re-read after calling a `set` (SwiftUI view state / `@State`
/// already does this on the next user-driven read).
@Observable
final class AppSettings {
    /// The app's real preferences, backed by `UserDefaults.standard`.
    static let shared = AppSettings()

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests use a scratch suite (e.g.
    /// `UserDefaults(suiteName: "...")`) instead of touching the user's real
    /// preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
}

// MARK: - Typed accessors

/// One overload per plist-compatible primitive `SettingsKey<Value>` can hold.
/// `RawRepresentable<String>` enums (e.g. `ImageFormat`) go through the
/// bridging overload further down instead of storing the enum directly.
extension AppSettings {
    func value(for key: SettingsKey<Bool>) -> Bool {
        defaults.object(forKey: key.name) == nil ? key.defaultValue : defaults.bool(forKey: key.name)
    }

    func set(_ newValue: Bool, for key: SettingsKey<Bool>) {
        defaults.set(newValue, forKey: key.name)
    }

    func value(for key: SettingsKey<Int>) -> Int {
        defaults.object(forKey: key.name) == nil ? key.defaultValue : defaults.integer(forKey: key.name)
    }

    func set(_ newValue: Int, for key: SettingsKey<Int>) {
        defaults.set(newValue, forKey: key.name)
    }

    func value(for key: SettingsKey<Double>) -> Double {
        defaults.object(forKey: key.name) == nil ? key.defaultValue : defaults.double(forKey: key.name)
    }

    func set(_ newValue: Double, for key: SettingsKey<Double>) {
        defaults.set(newValue, forKey: key.name)
    }

    func value(for key: SettingsKey<String>) -> String {
        defaults.string(forKey: key.name) ?? key.defaultValue
    }

    func set(_ newValue: String, for key: SettingsKey<String>) {
        defaults.set(newValue, forKey: key.name)
    }
}

/// Bridges any `String`-backed `RawRepresentable` enum (e.g. `ImageFormat`)
/// to `UserDefaults` via its raw value, so features can declare
/// `SettingsKey<ImageFormat>` etc. without `AppSettings` knowing about
/// individual feature enums.
extension AppSettings {
    func value<Value>(for key: SettingsKey<Value>) -> Value
    where Value: RawRepresentable & Sendable, Value.RawValue == String {
        guard let raw = defaults.string(forKey: key.name), let resolved = Value(rawValue: raw) else {
            return key.defaultValue
        }
        return resolved
    }

    func set<Value>(_ newValue: Value, for key: SettingsKey<Value>)
    where Value: RawRepresentable & Sendable, Value.RawValue == String {
        defaults.set(newValue.rawValue, forKey: key.name)
    }
}
