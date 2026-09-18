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
        dirty: Bool = false
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
    }
}
