import Foundation
import GRDB

/// Alerts attached to a task.
///
/// The scheduler has always been able to ring; until this existed there was
/// nothing to ring about. It reads `reminders`, and no screen in the app ever
/// wrote a row — which is why every log said `scheduled 0 notifications`.
public struct ReminderRepository: Sendable {
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

    public func observe(taskID: UUID) -> AsyncValueObservation<[Reminder]> {
        ValueObservation
            .tracking { db in
                try Reminder
                    .filter(Reminder.Columns.taskID == taskID.storedKey)
                    .filter(Reminder.Columns.deletedAt == nil)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    /// Which tasks have an alert on them, for the day list.
    public func observeTasksWithAlerts() -> AsyncValueObservation<Set<UUID>> {
        ValueObservation
            .tracking { db -> Set<UUID> in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT task_id AS task FROM reminders
                        WHERE deleted_at IS NULL AND kind != ?
                        """,
                    arguments: [ReminderKind.geo.rawValue]
                )
                var tasks: Set<UUID> = []
                for row in rows {
                    let identifier: DatabaseValue = row["task"]
                    guard
                        let text = String.fromDatabaseValue(identifier),
                        let taskID = UUID(uuidString: text)
                    else { continue }
                    tasks.insert(taskID)
                }
                return tasks
            }
            .values(in: database.reader)
    }

    public func make(
        for taskID: UUID, offsetMinutes: Int, kind: ReminderKind = .fixed
    ) -> Reminder {
        Reminder(
            householdID: householdID,
            taskID: taskID,
            offsetMinutes: offsetMinutes,
            kind: kind
        )
    }

    /// Several at once, in one transaction — an alert set on a task that does
    /// not exist yet, written the moment it is saved.
    public func insert(_ reminders: [Reminder]) throws {
        guard !reminders.isEmpty else { return }

        let records = reminders.map { reminder -> Reminder in
            var draft = reminder
            draft.touch(by: currentUserID)
            return draft
        }
        try database.writer.write { db in
            for record in records { try record.insert(db) }
        }
        onLocalChange()
    }

    public func add(to taskID: UUID, offsetMinutes: Int, kind: ReminderKind = .fixed) throws {
        try insert([make(for: taskID, offsetMinutes: offsetMinutes, kind: kind)])
    }

    /// A tombstone, like everything else: the other phone has to hear that the
    /// alert is gone, or it will keep ringing.
    public func delete(_ reminder: Reminder) throws {
        var draft = reminder
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }
}
