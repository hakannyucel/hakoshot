import Foundation
import HakoKit
import os

/// Capture history `SettingsKey`s (plan §4.12, §5.4).
extension SettingsKey where Value == Bool {
    /// Record every capture into history. Default on.
    static var historyEnabled: SettingsKey<Bool> {
        SettingsKey("historyEnabled", default: true)
    }
}

extension SettingsKey where Value == HistoryRetention {
    /// How long history is kept. Default 1 month (plan §5.4). `.never` = keep nothing.
    static var historyRetention: SettingsKey<HistoryRetention> {
        SettingsKey("historyRetention", default: .default)
    }
}

/// Snapshot of the history settings, handed to the `HistoryStore` actor.
nonisolated struct HistoryConfiguration: Sendable, Equatable {
    var isEnabled: Bool
    var retention: HistoryRetention

    /// Whether new captures are recorded.
    var records: Bool { isEnabled && retention.keepsHistory }

    static let `default` = HistoryConfiguration(isEnabled: true, retention: .default)
}

extension AppSettings {
    var historyConfiguration: HistoryConfiguration {
        HistoryConfiguration(isEnabled: value(for: .historyEnabled), retention: value(for: .historyRetention))
    }
}

extension Log {
    nonisolated static let history = Logger(subsystem: subsystem, category: "history")
}
