import Foundation

/// The in-memory form of `history.json`: entries kept newest-first.
/// Value type; `HistoryStore` (app) owns the single mutable copy.
public struct HistoryIndex: Sendable, Equatable {
    public static let currentVersion = 1

    /// Newest first (by `date`, ties by id for determinism).
    public private(set) var items: [HistoryItem]

    public init(items: [HistoryItem] = []) {
        self.items = []
        for item in items { add(item) }
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    // MARK: Mutation

    /// Inserts `item` in date order; replaces an existing entry with the same id.
    public mutating func add(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        let position = items.firstIndex { Self.isOrderedBefore(item, $0) } ?? items.endIndex
        items.insert(item, at: position)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> HistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Removes every entry whose id is in `ids`; returns the removed entries.
    @discardableResult
    public mutating func remove(ids: Set<UUID>) -> [HistoryItem] {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        return removed
    }

    @discardableResult
    public mutating func removeAll() -> [HistoryItem] {
        defer { items = [] }
        return items
    }

    /// Applies `change` to the entry with `id` (date changes re-sort it).
    /// Returns the updated entry, or `nil` when there is no such entry.
    @discardableResult
    public mutating func update(id: UUID, _ change: (inout HistoryItem) -> Void) -> HistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = items[index]
        change(&item)
        item.id = id
        items.remove(at: index)
        add(item)
        return item
    }

    @discardableResult
    public mutating func markClosed(id: UUID, at date: Date) -> HistoryItem? {
        update(id: id) {
            $0.isClosed = true
            $0.closedDate = date
        }
    }

    @discardableResult
    public mutating func markReopened(id: UUID) -> HistoryItem? {
        update(id: id) {
            $0.isClosed = false
            $0.closedDate = nil
        }
    }

    // MARK: Queries

    public func item(id: UUID) -> HistoryItem? {
        items.first { $0.id == id }
    }

    /// Newest-first entries matching `filter`, at most `limit` (nil = all).
    public func recent(limit: Int? = nil, filter: HistoryFilter = .all) -> [HistoryItem] {
        let matching = items.lazy.filter { filter.matches($0.kind) }
        if let limit { return Array(matching.prefix(max(0, limit))) }
        return Array(matching)
    }

    /// The most recently closed entry ("Restore Recently Closed").
    public func lastClosed() -> HistoryItem? {
        items
            .filter(\.isClosed)
            .max { ($0.closedDate ?? $0.date) < ($1.closedDate ?? $1.date) }
    }

    private static func isOrderedBefore(_ lhs: HistoryItem, _ rhs: HistoryItem) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - JSON

/// Outcome of reading `history.json`.
public struct HistoryIndexLoadResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Parsed cleanly.
        case ok
        /// The envelope parsed but some entries were unreadable and dropped.
        case partiallyRecovered(droppedCount: Int)
        /// Not valid JSON / not an index at all; `index` is empty.
        case corrupt
    }

    public var index: HistoryIndex
    public var status: Status
}

extension HistoryIndex {
    private struct Envelope: Encodable {
        var version: Int
        var items: [HistoryItem]
    }

    /// Envelope decoded one entry at a time so a bad entry doesn't sink the rest.
    private struct LenientEnvelope: Decodable {
        var version: Int?
        var items: [LenientItem]

        private enum CodingKeys: String, CodingKey { case version, items }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(Int.self, forKey: .version)
            items = (try c.decodeIfPresent([LenientItem].self, forKey: .items)) ?? []
        }
    }

    private struct LenientItem: Decodable {
        var item: HistoryItem?
        init(from decoder: any Decoder) throws {
            item = try? HistoryItem(from: decoder)
        }
    }

    /// ISO 8601 with milliseconds, so capture dates survive a round trip
    /// closely enough for ordering; plain ISO 8601 is also accepted on read.
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainDateStyle = Date.ISO8601FormatStyle()

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalDateStyle))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? fractionalDateStyle.parse(text) { return date }
            if let date = try? plainDateStyle.parse(text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO 8601 date: \(text)"
            )
        }
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(Envelope(version: Self.currentVersion, items: items))
    }

    /// Never throws: corrupt or truncated data yields an empty index with
    /// `.corrupt`, unreadable entries are dropped with `.partiallyRecovered`.
    /// Duplicate ids keep the last occurrence.
    public static func load(from data: Data) -> HistoryIndexLoadResult {
        guard !data.isEmpty,
              let envelope = try? makeDecoder().decode(LenientEnvelope.self, from: data)
        else {
            return HistoryIndexLoadResult(index: HistoryIndex(), status: .corrupt)
        }
        let decoded = envelope.items.compactMap(\.item)
        let dropped = envelope.items.count - decoded.count
        return HistoryIndexLoadResult(
            index: HistoryIndex(items: decoded),
            status: dropped == 0 ? .ok : .partiallyRecovered(droppedCount: dropped)
        )
    }
}
