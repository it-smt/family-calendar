import Foundation
import GRDB

/// The change feed: "she moved the doctor to 16:00".
///
/// Written on the server during push and pulled down like everything else, so
/// the device never writes one itself and never marks one dirty.
public struct ActivityEntry: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var actorID: UUID
    public var entityType: String
    public var entityID: UUID
    public var action: String
    public var summary: String

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool
    /// Whether this person has been told. Device-only, like `dirty`: the two
    /// phones are told about different things.
    public var notified: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        actorID: UUID,
        entityType: String,
        entityID: UUID,
        action: String,
        summary: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = false,
        notified: Bool = false
    ) {
        self.id = id
        self.householdID = householdID
        self.actorID = actorID
        self.entityType = entityType
        self.entityID = entityID
        self.action = action
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
        self.notified = notified
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case actorID = "actor_id"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case action
        case summary
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
        case notified
    }
}

extension ActivityEntry: TableRecord {
    public static let databaseTableName = "activity_entries"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let entityType = Column(CodingKeys.entityType)
        public static let entityID = Column(CodingKeys.entityID)
        public static let actorID = Column(CodingKeys.actorID)
        public static let action = Column(CodingKeys.action)
        public static let notified = Column(CodingKeys.notified)
    }

    /// Work this person asked for that somebody else has now finished.
    ///
    /// Delegation is only worth having if the person who asked finds out. The
    /// feed already carries who did what to both phones, so this is a query
    /// rather than a new mechanism: entries about a task this person created,
    /// completed by the other one, that they have not been told about.
    public static func unreportedDelegatedWork(
        _ db: Database, currentUserID: UUID
    ) throws -> [(entry: ActivityEntry, task: CalendarTask)] {
        let entries = try ActivityEntry
            .filter(Columns.notified == false)
            .filter(Columns.action == "completed")
            .filter(Columns.entityType == SyncEntity.task.rawValue)
            .filter(Columns.actorID != currentUserID.storedKey)
            .order(Columns.createdAt)
            .fetchAll(db)

        return try entries.compactMap { entry in
            guard
                let task = try CalendarTask.fetchOne(db, key: entry.entityID.storedKey),
                task.createdBy == currentUserID
            else {
                return nil
            }
            return (entry, task)
        }
    }

    public static func markNotified(_ entries: [ActivityEntry], in db: Database) throws {
        guard !entries.isEmpty else { return }
        let placeholders = entries.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "UPDATE activity_entries SET notified = 1 WHERE id IN (\(placeholders))",
            arguments: StatementArguments(entries.map(\.id))
        )
    }

    /// Everything the feed shows, newest first.
    public static func feed(_ db: Database, limit: Int = 100) throws -> [ActivityEntry] {
        try order(Columns.createdAt.desc).limit(limit).fetchAll(db)
    }
}
