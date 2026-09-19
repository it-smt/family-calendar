import Foundation
import GRDB

/// How much of a task's list is ticked off.
///
/// Counted in SQL rather than by fetching the rows: the day list wants this
/// for every task on screen, and it is two numbers.
public struct SubtaskProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var isComplete: Bool { total > 0 && done == total }
}

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
                    .filter(Subtask.Columns.taskID == taskID.storedKey)
                    .filter(Subtask.Columns.deletedAt == nil)
                    .order(Subtask.Columns.sortOrder)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    /// Ticked-off counts for every task that has a list, in one query.
    public func observeProgress() -> AsyncValueObservation<[UUID: SubtaskProgress]> {
        ValueObservation
            .tracking { db -> [UUID: SubtaskProgress] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT task_id AS task, COUNT(*) AS total, SUM(is_done) AS done
                        FROM subtasks
                        WHERE deleted_at IS NULL
                        GROUP BY task_id
                        """
                )

                var progress: [UUID: SubtaskProgress] = [:]
                for row in rows {
                    // Read without converting: a value of an unexpected type
                    // should be skipped, not trip GRDB's conversion trap.
                    let identifier: DatabaseValue = row["task"]
                    guard
                        let text = String.fromDatabaseValue(identifier),
                        let taskID = UUID(uuidString: text)
                    else { continue }

                    let total: DatabaseValue = row["total"]
                    let done: DatabaseValue = row["done"]
                    progress[taskID] = SubtaskProgress(
                        done: Int.fromDatabaseValue(done) ?? 0,
                        total: Int.fromDatabaseValue(total) ?? 0
                    )
                }
                return progress
            }
            .values(in: database.reader)
    }

    /// Several at once, in one transaction.
    ///
    /// What a list attached to a task that does not exist yet turns into the
    /// moment that task is saved. The rows already carry the identifiers they
    /// were given in the editor, so nothing has to be matched up afterwards.
    public func insert(_ subtasks: [Subtask]) throws {
        guard !subtasks.isEmpty else { return }

        let records = subtasks.map { subtask -> Subtask in
            var draft = subtask
            draft.touch(by: currentUserID)
            return draft
        }
        try database.writer.write { db in
            for record in records { try record.insert(db) }
        }
        onLocalChange()
    }

    public func add(to taskID: UUID, title: String) throws {
        let nextOrder = try database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM subtasks WHERE task_id = ?",
                arguments: [taskID.storedKey]
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
