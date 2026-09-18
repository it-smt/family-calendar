import Foundation
import GRDB

public struct Household: SyncRecord {
    public var id: UUID
    public var name: String
    public var inviteCode: String
    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        inviteCode: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension Household: TableRecord {
    public static let databaseTableName = "households"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let inviteCode = Column(CodingKeys.inviteCode)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }
}

public struct User: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var displayName: String
    public var color: String
    public var apnsToken: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        displayName: String,
        color: String = "#3478F6",
        apnsToken: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.displayName = displayName
        self.color = color
        self.apnsToken = apnsToken
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case displayName = "display_name"
        case color
        case apnsToken = "apns_token"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension User: TableRecord {
    public static let databaseTableName = "users"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let displayName = Column(CodingKeys.displayName)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }
}
