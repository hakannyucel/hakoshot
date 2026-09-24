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

    /// Hard cap on total video/GIF/Studio media bytes kept in history
    /// (kayit-teknik-plan §4.15, §5: "video saklama: tam kopya", 10 GB, oldest
    /// evicted first). Independent of the date-based retention above — it
    /// applies even when `self == .oneMonth` etc. Decimal GB (10 × 1000³),
    /// matching Finder / `df` sizes.
    public static let videoByteCap: Int64 = 10_000_000_000

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

/// Decides which video/GIF/Studio history entries to evict once their
/// combined media size passes `HistoryRetention.videoByteCap` (kayit-teknik-plan
/// §4.15, §5). Pure: the app measures each entry's media file on disk and
/// passes the sizes in; this type only decides oldest-first eviction order.
public struct VideoRetentionPolicy: Sendable, Equatable {
    public var byteCap: Int64

    public init(byteCap: Int64 = HistoryRetention.videoByteCap) {
        self.byteCap = byteCap
    }

    /// Entries to delete, oldest (`date`) first, until the remaining total
    /// fits under `byteCap`. `sizes` maps an entry's id to its media file
    /// size in bytes; entries missing from `sizes` are never evicted here
    /// (e.g. screenshots, or an entry whose size couldn't be read).
    public func itemsToEvict(in items: [HistoryItem], sizes: [UUID: Int64]) -> [HistoryItem] {
        let known = items.filter { sizes[$0.id] != nil }
        var total = known.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
        guard total > byteCap else { return [] }

        let oldestFirst = known.sorted { $0.date < $1.date }
        var evicted: [HistoryItem] = []
        for item in oldestFirst {
            guard total > byteCap else { break }
            evicted.append(item)
            total -= sizes[item.id] ?? 0
        }
        return evicted
    }
}
