import Foundation
import GRDB

/// The "your edit was replaced" notices.
public struct SupersededEditRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observeOpen() -> AsyncValueObservation<[SupersededEdit]> {
        ValueObservation
            .tracking { db in try SupersededEdit.open(db) }
            .values(in: database.reader)
    }

    public func dismiss(_ notice: SupersededEdit) throws {
        guard let id = notice.id else { return }
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE superseded_edits SET dismissed = 1 WHERE id = ?", arguments: [id]
            )
        }
    }

    /// Puts the replaced values back as a fresh edit.
    ///
    /// Nothing special happens here: a newer stamp wins the same way any other
    /// edit does, and the partner's phone will take it on the next pull.
    public func restore(_ notice: SupersededEdit, using tasks: TaskRepository) throws {
        guard
            notice.entityType == SyncEntity.task.rawValue,
            let task = try tasks.task(id: notice.entityID),
            case .object(let mine) = try JSONValue(jsonText: notice.mine)
        else {
            try dismiss(notice)
            return
        }

        try tasks.update(task) { draft in
            if case .string(let title) = mine["title"] { draft.title = title }
            if case .string(let startsAt) = mine["starts_at"] {
                draft.startsAt = Timestamp.date(from: startsAt)
            }
            if case .null = mine["starts_at"] ?? .null { draft.startsAt = nil }
            if case .string(let notes) = mine["notes"] { draft.notes = notes }
            if case .string(let location) = mine["location_name"] {
                draft.locationName = location
            }
        }
        try dismiss(notice)
    }
}
