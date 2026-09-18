import Foundation
import GRDB

/// Subtasks — the steps of a task, and the "what to bring" list.
public struct SubtaskRepository: Sendable {
    private let database: AppDatabase
    private let currentUserID: UUID
    private let householdID: UUID
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

    public func observe(taskID: UUID) -> AsyncValueObservation<[Subtask]> {
        ValueObservation
            .tracking { db in
                try Subtask
                    .filter(Subtask.Columns.taskID == taskID)
                    .filter(Subtask.Columns.deletedAt == nil)
                    .order(Subtask.Columns.sortOrder)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    public func add(to taskID: UUID, title: String) throws {
        let nextOrder = try database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM subtasks WHERE task_id = ?",
                arguments: [taskID]
            ) ?? 0
        }

        var subtask = Subtask(
            householdID: householdID, taskID: taskID, title: title, sortOrder: nextOrder
        )
        subtask.touch(by: currentUserID)
        let record = subtask
        try database.writer.write { db in try record.insert(db) }
        onLocalChange()
    }

    public func setDone(_ subtask: Subtask, _ done: Bool) throws {
        var draft = subtask
        draft.isDone = done
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    public func delete(_ subtask: Subtask) throws {
        var draft = subtask
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    /// Applying a packing template: one tap, several subtasks.
    public func apply(_ template: PackingTemplate, to taskID: UUID) throws {
        for item in template.items {
            try add(to: taskID, title: item)
        }
    }
}
