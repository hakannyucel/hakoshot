/// A typed `UserDefaults` key: a name plus the default value used when
/// nothing has been stored yet (plan §1.6). `SettingsKey` itself carries no
/// storage or `UserDefaults` access — the app target's `@Observable
/// AppSettings` reads/writes through it. HakoKit only owns the pattern so it
/// stays testable and dependency-free.
///
/// Each feature declares its own keys as static members in its own file, via
/// an extension constrained on `Value`, so no shared file becomes a hotspot:
///
/// ```swift
/// extension SettingsKey where Value == Bool {
///     static var shutterSoundEnabled: SettingsKey<Bool> {
///         SettingsKey("shutterSoundEnabled", default: true)
///     }
/// }
/// ```
public struct SettingsKey<Value: Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

extension SettingsKey: Equatable {
    /// Keys compare by name only: two `SettingsKey<Value>` instances name the
    /// same stored entry iff their names match, regardless of whether `Value`
    /// itself is `Equatable`.
    public static func == (lhs: SettingsKey<Value>, rhs: SettingsKey<Value>) -> Bool {
        lhs.name == rhs.name
    }
}

extension SettingsKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
