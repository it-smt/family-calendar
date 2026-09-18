import Foundation
import GRDB

/// Named lists of things to bring. "Swimming" is a cap, goggles, a towel and
/// the certificate, and applying it is one tap rather than four.
public struct PackingTemplateRepository: Sendable {
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

    public func observe() -> AsyncValueObservation<[PackingTemplate]> {
        ValueObservation
            .tracking { db in
                try PackingTemplate
                    .filter(PackingTemplate.Columns.deletedAt == nil)
                    .order(PackingTemplate.Columns.name)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    @discardableResult
    public func save(_ template: PackingTemplate) throws -> PackingTemplate {
        var draft = template
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.save(db) }
        onLocalChange()
        return record
    }

    public func create(name: String, items: [String]) throws {
        try save(PackingTemplate(householdID: householdID, name: name, items: items))
    }

    public func delete(_ template: PackingTemplate) throws {
        var draft = template
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }
}
