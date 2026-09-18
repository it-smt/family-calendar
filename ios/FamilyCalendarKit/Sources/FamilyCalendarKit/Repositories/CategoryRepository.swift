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

    public func observeAll() -> AsyncValueObservation<[TaskCategory]> {
        ValueObservation
            .tracking { db in
                try TaskCategory
                    .filter(TaskCategory.Columns.deletedAt == nil)
                    .order(TaskCategory.Columns.name)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    @discardableResult
    public func create(name: String, colorHex: String, icon: String?) throws -> TaskCategory {
        var category = TaskCategory(
            householdID: householdID, name: name, colorHex: colorHex, icon: icon
        )
        category.touch(by: currentUserID)
        let record = category
        try database.writer.write { db in try record.insert(db) }
        onLocalChange()
        return record
    }

    /// The handful a brand-new household starts with.
    ///
    /// Colour in this app belongs to categories, so a household with none is a
    /// grey one — and the filter, the stripe on every card and the dot in the
    /// editor all have nothing to show. Seeding is a local write like any
    /// other: it goes into the outbox and reaches the other phone by the
    /// ordinary route.
    ///
    /// Only ever on an empty table. The second person joins by invite code and
    /// pulls the first person's categories, so seeding for them would leave the
    /// household with two of each.
    public func seedStarterCategories(_ starters: [(name: String, colorHex: String)]) throws {
        let inserted = try database.writer.write { db -> Bool in
            guard try TaskCategory.fetchCount(db) == 0 else { return false }
            for starter in starters {
                var category = TaskCategory(
                    householdID: householdID,
                    name: starter.name,
                    colorHex: starter.colorHex,
                    icon: nil
                )
                category.touch(by: currentUserID)
                try category.insert(db)
            }
            return true
        }
        if inserted { onLocalChange() }
    }

    public func rename(_ category: TaskCategory, to name: String) throws {
        var draft = category
        draft.name = name
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    public func delete(_ category: TaskCategory) throws {
        var draft = category
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }
}
