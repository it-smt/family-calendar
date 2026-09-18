import Foundation
import GRDB

/// Named `TaskCategory`, not `Category`: the plain name is ambiguous the moment
/// a file imports SwiftUI or UIKit alongside this module, and every view that
/// shows a colour needs both. The same reasoning as `CalendarTask`. The table is
/// still `categories`.
public struct TaskCategory: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var name: String
    public var colorHex: String
    public var icon: String?

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        name: String,
        colorHex: String = "#8E8E93",
        icon: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case name
        case colorHex = "color_hex"
        case icon
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension TaskCategory: TableRecord {
    public static let databaseTableName = "categories"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let name = Column(CodingKeys.name)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }
}

/// A named list of things to bring. Applying it creates subtasks in one tap.
public struct PackingTemplate: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var name: String
    /// JSON array of strings; the items have no identity of their own.
    public var items: [String]

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        name: String,
        items: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case name
        case items
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension PackingTemplate: TableRecord {
    public static let databaseTableName = "packing_templates"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let name = Column(CodingKeys.name)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }
}

/// An entity of its own, not a task.
public struct ShoppingItem: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var title: String
    /// Free text: "2", "2 kg" and "a pack" all get typed into this field.
    public var quantity: String?
    public var isBought: Bool
    public var categoryID: UUID?
    public var addedBy: UUID

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        title: String,
        quantity: String? = nil,
        isBought: Bool = false,
        categoryID: UUID? = nil,
        addedBy: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.title = title
        self.quantity = quantity
        self.isBought = isBought
        self.categoryID = categoryID
        self.addedBy = addedBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case title
        case quantity
        case isBought = "is_bought"
        case categoryID = "category_id"
        case addedBy = "added_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension ShoppingItem: TableRecord {
    public static let databaseTableName = "shopping_items"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let isBought = Column(CodingKeys.isBought)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }
}
