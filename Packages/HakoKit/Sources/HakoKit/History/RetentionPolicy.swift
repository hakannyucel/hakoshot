import Foundation

/// How long history is kept (plan §4.12 / §5.4). Default `.oneMonth`.
///
/// `.never` means **keep nothing**: new captures are not stored and existing
/// entries are purged.
public enum HistoryRetention: String, Sendable, CaseIterable, Equatable, Codable {
    case never
    case oneDay
    case oneWeek
    case oneMonth

    public static let `default`: HistoryRetention = .oneMonth

    public var title: String {
        switch self {
        case .never: "Never"
        case .oneDay: "1 Day"
        case .oneWeek: "1 Week"
        case .oneMonth: "1 Month"
        }
    }

    /// Whether new captures should be recorded at all.
    public var keepsHistory: Bool { self != .never }
}

/// Decides which entries have expired. Pure: "now" and the calendar are injected.
public struct RetentionPolicy: Sendable, Equatable {
    public var retention: HistoryRetention
    public var calendar: Calendar

    public init(retention: HistoryRetention = .default, calendar: Calendar = .current) {
        self.retention = retention
        self.calendar = calendar
    }

    /// Entries dated strictly before this are expired; `nil` for `.never`
    /// (everything is expired).
    public func cutoff(now: Date) -> Date? {
        let component: (Calendar.Component, Int)
        switch retention {
        case .never: return nil
        case .oneDay: component = (.day, -1)
        case .oneWeek: component = (.day, -7)
        case .oneMonth: component = (.month, -1)
        }
        return calendar.date(byAdding: component.0, value: component.1, to: now)
    }

    public func isExpired(_ item: HistoryItem, now: Date) -> Bool {
        guard let cutoff = cutoff(now: now) else { return true }
        return item.date < cutoff
    }

    /// Entries to delete (files + index rows), in input order.
    public func itemsToPurge(in items: [HistoryItem], now: Date) -> [HistoryItem] {
        items.filter { isExpired($0, now: now) }
    }
}
