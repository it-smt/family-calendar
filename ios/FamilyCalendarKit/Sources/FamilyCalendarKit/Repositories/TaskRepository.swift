import Foundation
import GRDB

/// Reads and writes tasks. The only way the UI touches the database.
///
/// Every write goes through `touch(by:)`, which stamps the row and marks it
/// dirty, so no code path can save a change the sync layer will not notice.
/// Nothing here is async because nothing here waits for a network: a write
/// lands locally and returns, and the engine sends it whenever it can.
public struct TaskRepository: Sendable {
    private let database: AppDatabase
    private let currentUserID: UUID
    private let onLocalChange: @Sendable () -> Void

    public init(
        database: AppDatabase,
        currentUserID: UUID,
        onLocalChange: @escaping @Sendable () -> Void = {}
    ) {
        self.database = database
        self.currentUserID = currentUserID
        self.onLocalChange = onLocalChange
    }

    // MARK: Reading

    /// Live tasks for a day, as a stream that updates itself when the database
    /// changes — including when a sync applies the partner's edit.
    public func tasksOnDay(_ day: Date, calendar: Calendar = .current) -> AsyncValueObservation<[CalendarTask]> {
        // Compared as the strings the column actually holds. A `Date` put into
        // a query would be encoded by GRDB's default strategy, not the wire
        // format these records are written with, and the window would silently
        // match nothing.
        let start = Timestamp.string(from: calendar.startOfDay(for: day))
        let end = Timestamp.string(
            from: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
                ?? calendar.startOfDay(for: day)
        )

        return ValueObservation
            .tracking { db in
                try CalendarTask
                    .filter(CalendarTask.Columns.deletedAt == nil)
                    .filter(CalendarTask.Columns.startsAt >= start && CalendarTask.Columns.startsAt < end)
                    .order(CalendarTask.Columns.startsAt)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    public func task(id: UUID) throws -> CalendarTask? {
        try database.reader.read { db in try CalendarTask.fetchOne(db, key: id) }
    }

    // MARK: Writing

    @discardableResult
    public func create(_ task: CalendarTask) throws -> CalendarTask {
        var draft = task
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.insert(db) }
        onLocalChange()
        return record
    }

    public func update(_ task: CalendarTask, _ edit: (inout CalendarTask) -> Void) throws {
        var draft = task
        edit(&draft)
        draft.touch(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    /// A soft delete. The row stays so the tombstone can reach the other phone.
    public func delete(_ task: CalendarTask) throws {
        var draft = task
        draft.markDeleted(by: currentUserID)
        let record = draft
        try database.writer.write { db in try record.update(db) }
        onLocalChange()
    }

    public func setCompleted(_ task: CalendarTask, _ completed: Bool) throws {
        try update(task) { $0.completedAt = completed ? Date() : nil }
    }
}
