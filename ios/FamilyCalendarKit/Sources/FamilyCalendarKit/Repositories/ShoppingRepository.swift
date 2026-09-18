import Foundation
import GRDB

/// The shopping list. Its own entity, not a task.
public struct ShoppingRepository: Sendable {
    private let database: AppDatabase
    private let householdID: UUID
    private let currentUserID: UUID
    private let onLocalChange: @Sendable () -> Void

    public init(
        database: AppDatabase,
        householdID: UUID,
        currentUserID: UUID,
        onLocalChange: @escaping @Sendable () -> Void = {}
    ) {
        self.database = database
        self.householdID = householdID
        self.currentUserID = currentUserID
        self.onLocalChange = onLocalChange
    }

    /// Unbought first, then what was bought recently, so a mistaken tap is easy
    /// to undo and the list still reads as a list.
    public func observe() -> AsyncValueObservation<[ShoppingItem]> {
        ValueObservation
            .tracking { db in
                try ShoppingItem
                    .filter(ShoppingItem.Columns.deletedAt == nil)
                    .order(ShoppingItem.Columns.isBought, ShoppingItem.Columns.updatedAt.desc)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    public func add(title: String, quantity: String? = nil) throws {
        var item = ShoppingItem(
            householdID: householdID,
            title: title,
            quantity: quantity,
            addedBy: currentUserID
        )
        item.touch(by: currentUserID)
        let record = item
        try database.writer.write { db in try record.insert(db) }
        onLocalChange()
    }

    public func setBought(_ item: ShoppingItem, _ bought: Bool) throws {
        var draft = item
        draft.isBought = bought
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    public func delete(_ item: ShoppingItem) throws {
        var draft = item
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    /// Clears what has been bought, once the shopping is done.
    public func clearBought() throws {
        let bought = try database.writer.read { db in
            try ShoppingItem
                .filter(ShoppingItem.Columns.deletedAt == nil)
                .filter(ShoppingItem.Columns.isBought == true)
                .fetchAll(db)
        }
        for item in bought {
            try delete(item)
        }
    }
}
