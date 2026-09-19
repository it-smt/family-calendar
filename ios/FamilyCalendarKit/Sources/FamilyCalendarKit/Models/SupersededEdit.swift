import Foundation
import GRDB

/// An edit of this person's that an arriving row replaced.
///
/// Last-write-wins compares whole rows, so when two people edit one task
/// offline the later stamp takes the other's field with it — a field the winner
/// never touched. Changing that means per-column versions or a CRDT, which is a
/// different application. What it does not have to be is silent: the replaced
/// version is kept here so the app can say what was lost and offer to put it
/// back. Restoring is an ordinary local edit, and wins the same way anything
/// else does.
///
/// Device-only. Never synchronised, never pushed.
public struct SupersededEdit: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "superseded_edits"

    public var id: Int64?
    public var entityType: String
    public var entityID: UUID
    /// JSON of the values this person had, and the ones that replaced them.
    public var mine: String
    public var theirs: String
    public var actorID: UUID?
    public var supersededAt: Date
    public var dismissed: Bool
    /// Whether the person has been told. A banner only reaches someone who
    /// opens the app; losing an edit deserves more than that.
    public var notified: Bool

    public enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case entityID = "entity_id"
        case mine
        case theirs
        case actorID = "actor_id"
        case supersededAt = "superseded_at"
        case dismissed
        case notified
    }

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let entityType = Column(CodingKeys.entityType)
        public static let entityID = Column(CodingKeys.entityID)
        public static let supersededAt = Column(CodingKeys.supersededAt)
        public static let dismissed = Column(CodingKeys.dismissed)
        public static let notified = Column(CodingKeys.notified)
    }

    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .custom { Timestamp.string(from: $0) }
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .custom { dbValue in
            guard let string = String.fromDatabaseValue(dbValue) else { return nil }
            return Timestamp.date(from: string)
        }
    }

    public struct Difference: Identifiable, Sendable {
        public let field: String
        public let mine: JSONValue
        public let theirs: JSONValue

        public var id: String { field }
    }

    /// The fields that actually differ, for showing "was / now" rather than a
    /// wall of unchanged values.
    public func differences() -> [Difference] {
        guard
            let mineValues = try? JSONValue(jsonText: mine),
            let theirsValues = try? JSONValue(jsonText: theirs),
            case .object(let mineObject) = mineValues,
            case .object(let theirsObject) = theirsValues
        else {
            return []
        }

        return mineObject
            .filter { field, value in theirsObject[field] != value }
            .map { field, value in
                Difference(field: field, mine: value, theirs: theirsObject[field] ?? .null)
            }
            .sorted { $0.field < $1.field }
    }

    /// Open notices, newest first.
    public static func open(_ db: Database) throws -> [SupersededEdit] {
        try filter(Columns.dismissed == false)
            .order(Columns.supersededAt.desc)
            .fetchAll(db)
    }

    /// Notices the person has not been told about yet.
    public static func unnotified(_ db: Database) throws -> [SupersededEdit] {
        try filter(Columns.notified == false && Columns.dismissed == false)
            .order(Columns.id)
            .fetchAll(db)
    }

    public static func markNotified(_ notices: [SupersededEdit], in db: Database) throws {
        let ids = notices.compactMap(\.id)
        guard !ids.isEmpty else { return }
        try db.execute(
            sql: "UPDATE superseded_edits SET notified = 1 WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(ids)
        )
    }
}
