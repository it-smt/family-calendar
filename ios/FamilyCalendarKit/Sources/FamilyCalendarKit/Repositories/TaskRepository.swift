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

    /// Everything that could land on this day, repeats included.
    ///
    /// A repeating task is stored once, on the day it started; the instants it
    /// falls on afterwards are worked out on the device. So the day cannot ask
    /// for "tasks whose `starts_at` is today" any more — it asks for today's
    /// tasks *and* every rule that began before today ends, and expands them.
    public func tasksTouching(
        _ day: Date, calendar: Calendar = .current
    ) -> AsyncValueObservation<[CalendarTask]> {
        let start = Timestamp.string(from: calendar.startOfDay(for: day))
        let end = Timestamp.string(
            from: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
                ?? calendar.startOfDay(for: day)
        )

        return ValueObservation
            .tracking { db in
                try CalendarTask
                    .filter(CalendarTask.Columns.deletedAt == nil)
                    .filter(
                        (CalendarTask.Columns.startsAt >= start
                            && CalendarTask.Columns.startsAt < end)
                            || (CalendarTask.Columns.rrule != nil
                                && CalendarTask.Columns.startsAt < end)
                    )
                    .order(CalendarTask.Columns.startsAt)
                    .fetchAll(db)
            }
            .values(in: database.reader)
    }

    public func task(id: UUID) throws -> CalendarTask? {
        try database.reader.read { db in try CalendarTask.fetchOne(db, key: id.storedKey) }
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

    /// Cancels one instant of a repeating task, leaving the rule alone.
    ///
    /// This is what "done" means for a repeat as well as "not this week":
    /// there is one row for the whole series and nowhere to record that one
    /// Tuesday went differently, so the instant is struck out of the rule.
    /// Ticking off "вынести мусор" therefore makes today's disappear rather
    /// than showing it crossed out — the honest consequence of a shape that
    /// keeps a repeat as a single row.
    public func skip(_ task: CalendarTask, occurrence: Date) throws {
        var draft = task
        var exceptions = draft.recurrenceExceptionDates
        let moment = Timestamp.truncatedToMilliseconds(occurrence)
        guard !exceptions.contains(moment) else { return }
        exceptions.append(moment)
        draft.recurrenceExceptionDates = exceptions
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
