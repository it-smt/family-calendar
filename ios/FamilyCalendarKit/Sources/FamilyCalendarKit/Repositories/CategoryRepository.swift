import Foundation
import GRDB

public struct CategoryRepository: Sendable {
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

    public func observeAll() -> AsyncValueObservation<[Category]> {
        ValueObservation
            .tracking { db in
                try Category
                    .filter(Category.Columns.deletedAt == nil)
                    .order(Category.Columns.name)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    @discardableResult
    public func create(name: String, colorHex: String, icon: String?) throws -> Category {
        var category = Category(
            householdID: householdID, name: name, colorHex: colorHex, icon: icon
        )
        category.touch(by: currentUserID)
        let record = category
        try database.writer.write { db in try record.insert(db) }
        onLocalChange()
        return record
    }

    public func rename(_ category: Category, to name: String) throws {
        var draft = category
        draft.name = name
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    public func delete(_ category: Category) throws {
        var draft = category
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }
}
