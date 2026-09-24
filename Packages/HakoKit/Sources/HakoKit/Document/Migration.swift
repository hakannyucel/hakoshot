import Foundation

/// Upgrades `project.json` written by older HakoShot versions to
/// `ProjectDocument.currentFormatVersion` before it is decoded (plan §4.9).
///
/// How to change the format:
/// 1. Bump `ProjectDocument.currentFormatVersion` (say to 2).
/// 2. Append `Step(from: 1) { json in ... }` to `steps`, rewriting the raw
///    JSON object from the v1 shape to the v2 shape. The step does not touch
///    `formatVersion`; the runner sets it to `from + 1`.
/// 3. Keep the v1 fixture test green (it reads a real v1 bundle).
///
/// Additive changes (a new optional field) need no step: the model ignores
/// unknown keys and defaults missing optional ones.
public enum Migration {
    public enum Error: Swift.Error, Sendable, Equatable {
        /// Not a JSON object, or `formatVersion` missing / not an integer.
        case unreadable
        /// Written by a newer HakoShot.
        case newerVersion(Int)
        /// No step upgrades this (older or invalid) version.
        case noMigrationPath(from: Int)
        /// A step failed.
        case stepFailed(from: Int, reason: String)
    }

    /// One upgrade from version `from` to `from + 1`, on the raw JSON object.
    public struct Step: Sendable {
        public var from: Int
        public var migrate: @Sendable (inout [String: JSONValue]) throws -> Void

        public init(from: Int, migrate: @escaping @Sendable (inout [String: JSONValue]) throws -> Void) {
            self.from = from
            self.migrate = migrate
        }
    }

    /// Registered upgrades, oldest first. v1 is the first format; none yet.
    public static let steps: [Step] = []

    private struct VersionProbe: Decodable {
        var formatVersion: Int
    }

    /// `formatVersion` of a `project.json`, without decoding the rest.
    public static func formatVersion(of data: Data) throws(Error) -> Int {
        do {
            return try JSONDecoder().decode(VersionProbe.self, from: data).formatVersion
        } catch {
            throw .unreadable
        }
    }

    /// Returns `project.json` data at `ProjectDocument.currentFormatVersion`.
    /// Current-version data is returned unchanged (byte for byte).
    public static func upgrade(_ data: Data) throws(Error) -> Data {
        try upgrade(data, to: ProjectDocument.currentFormatVersion, steps: steps)
    }

    /// Dispatch with an explicit target and step list (testable).
    static func upgrade(_ data: Data, to target: Int, steps: [Step]) throws(Error) -> Data {
        var version = try formatVersion(of: data)
        if version == target { return data }
        if version > target { throw .newerVersion(version) }

        var object: [String: JSONValue]
        do {
            object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw .unreadable
        }
        while version < target {
            guard let step = steps.first(where: { $0.from == version }) else {
                throw .noMigrationPath(from: version)
            }
            do {
                try step.migrate(&object)
            } catch {
                throw .stepFailed(from: version, reason: String(describing: error))
            }
            version += 1
            object["formatVersion"] = .number(Double(version))
        }
        do {
            return try ProjectDocument.makeEncoder().encode(object)
        } catch {
            throw .stepFailed(from: version, reason: String(describing: error))
        }
    }
}
