import Foundation
import GRDB

/// A task and one of the instants its rule puts it on.
public struct CompletedOccurrence: Hashable, Sendable {
    public let taskID: UUID
    public let occurrence: Date

    public init(taskID: UUID, occurrence: Date) {
        self.taskID = taskID
        self.occurrence = Timestamp.truncatedToMilliseconds(occurrence)
    }
}

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
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return tasksTouching(from: start, to: end)
    }

    /// The same, over any stretch — a week, a month.
    public func tasksTouching(from: Date, to: Date) -> AsyncValueObservation<[CalendarTask]> {
        let start = Timestamp.string(from: from)
        let end = Timestamp.string(from: to)

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

    /// Which instants of which repeats are ticked off.
    ///
    /// Read as a set of task-and-instant pairs rather than joined per line: the
    /// day asks once for the whole window, and a week or a month is the same
    /// one question.
    public func observeCompletions(from: Date, to: Date) -> AsyncValueObservation<Set<CompletedOccurrence>> {
        let start = Timestamp.string(from: from)
        let end = Timestamp.string(from: to)

        return ValueObservation
            .tracking { db -> Set<CompletedOccurrence> in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT task_id AS task, occurrence AS at
                        FROM occurrence_completions
                        WHERE deleted_at IS NULL AND occurrence >= ? AND occurrence < ?
                        """,
                    arguments: [start, end]
                )

                var completed: Set<CompletedOccurrence> = []
                for row in rows {
                    let identifier: DatabaseValue = row["task"]
                    let moment: DatabaseValue = row["at"]
                    guard
                        let text = String.fromDatabaseValue(identifier),
                        let taskID = UUID(uuidString: text),
                        let stamp = String.fromDatabaseValue(moment),
                        let occurrence = Timestamp.date(from: stamp)
                    else { continue }
                    completed.insert(
                        CompletedOccurrence(taskID: taskID, occurrence: occurrence)
                    )
                }
                return completed
            }
            .values(in: database.reader)
    }

    /// Ticks one instant of a repeat off, or un-ticks it.
    ///
    /// Un-ticking tombstones every row for that instant, not just one: two
    /// phones ticking the same Tuesday while both were offline each made a row,
    /// which is deliberate — a unique constraint the device can violate would
    /// have the loser retrying a rejected push for ever.
    public func setCompleted(_ task: CalendarTask, occurrence: Date, _ done: Bool) throws {
        let moment = Timestamp.truncatedToMilliseconds(occurrence)
        let stamp = Timestamp.string(from: moment)

        try database.writer.write { db in
            let existing = try OccurrenceCompletion
                .filter(OccurrenceCompletion.Columns.taskID == task.id.storedKey)
                .filter(OccurrenceCompletion.Columns.occurrence == stamp)
                .filter(OccurrenceCompletion.Columns.deletedAt == nil)
                .fetchAll(db)

            if done {
                guard existing.isEmpty else { return }
                var completion = OccurrenceCompletion(
                    householdID: task.householdID,
                    taskID: task.id,
                    occurrence: moment,
                    completedBy: currentUserID
                )
                completion.touch(by: currentUserID)
                try completion.insert(db)
            } else {
                for row in existing {
                    var draft = row
                    draft.markDeleted(by: currentUserID)
                    try draft.update(db)
                }
            }
        }
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
