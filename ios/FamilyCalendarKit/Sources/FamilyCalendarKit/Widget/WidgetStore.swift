import Foundation
import GRDB

/// Reads the shared database for the widget.
///
/// Opened read-only, in the widget's own process, from the App Group container.
/// No app launch, no network, no waiting: the database is the source of truth
/// and it is already on disk.
public struct WidgetStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public static func shared() throws -> WidgetStore {
        // Unlike the app, the widget cannot fall back to its own container:
        // its own container is empty, and always will be. Without the App
        // Group there is genuinely nothing to show.
        guard AppDatabase.isSharedWithWidget else {
            throw AppDatabase.DatabaseError.appGroupUnavailable(AppDatabase.appGroupIdentifier)
        }
        return WidgetStore(database: try AppDatabase.shared())
    }

    /// Ticked off? For a task that happens once, its own flag; for a repeat,
    /// whether this instant has a row.
    private func isDone(
        _ task: CalendarTask, at occurrence: Date, in completed: Set<CompletedOccurrence>
    ) -> Bool {
        guard task.rrule != nil else { return task.isCompleted }
        return completed.contains(
            CompletedOccurrence(taskID: task.id, occurrence: occurrence)
        )
    }

    /// One snapshot per moment the widget should be redrawn at.
    public func timeline(now: Date = Date(), calendar: Calendar = .current) throws -> [WidgetSnapshot] {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        let (tasks, categories, shopping, unsynced, origin, completed) = try database.reader.read { db in
            let tasks = try CalendarTask
                .filter(CalendarTask.Columns.deletedAt == nil)
                .fetchAll(db)
            let categories = try TaskCategory
                .filter(TaskCategory.Columns.deletedAt == nil)
                .fetchAll(db)
            let shopping = try ShoppingItem
                .filter(ShoppingItem.Columns.deletedAt == nil)
                .filter(ShoppingItem.Columns.isBought == false)
                .order(ShoppingItem.Columns.updatedAt.desc)
                .limit(8)
                .fetchAll(db)
            let unsynced = try Outbox.collect(db, limit: Int.max).count
            let origin = try SyncState.current(db).origin

            // Какие именно разы уже отмечены: у повтора одна строка и правило,
            // и «сделано» живёт отдельной строкой.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT task_id AS task, occurrence AS at FROM occurrence_completions
                    WHERE deleted_at IS NULL AND occurrence >= ? AND occurrence < ?
                    """,
                arguments: [
                    Timestamp.string(from: startOfDay), Timestamp.string(from: endOfDay),
                ]
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
                completed.insert(CompletedOccurrence(taskID: taskID, occurrence: occurrence))
            }

            return (tasks, categories, shopping, unsynced, origin, completed)
        }

        // Read from the cache, never measured here: a widget that waited for
        // MapKit would be a widget that often showed nothing at all.
        let estimates = (try? database.reader.read { db in
            try LeaveTimeCoordinator.estimates(db, origin: origin, now: now)
        }) ?? [:]

        let colours = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.colorHex) })

        // A repeating task is several lines today, not one, so the widget shows
        // the same instants the alerts were scheduled for.
        var lines: [WidgetSnapshot.TaskLine] = []
        for task in tasks {
            // An all-day task is stored at the start of its day so that the
            // day list can find it, but it has no instant to show and none to
            // expand: it either belongs to today or it does not. A row left
            // over from when a task could have no date at all belongs to no
            // day, and is shown today rather than never.
            if task.isAllDay {
                let today = task.startsAt.map { $0 >= startOfDay && $0 < endOfDay } ?? true
                guard today else { continue }
                let occurrence = task.startsAt ?? startOfDay
                lines.append(
                    WidgetSnapshot.TaskLine(
                        id: task.id,
                        title: task.title,
                        startsAt: nil,
                        isAllDay: true,
                        occurrence: occurrence,
                        isCompleted: isDone(task, at: occurrence, in: completed),
                        assigneeID: task.assigneeID,
                        colorHex: task.categoryID.flatMap { colours[$0] },
                        locationName: task.locationName
                    )
                )
                continue
            }

            for occurrence in Recurrence.occurrences(of: task, in: startOfDay..<endOfDay) {
                lines.append(
                    WidgetSnapshot.TaskLine(
                        id: task.id,
                        title: task.title,
                        startsAt: occurrence,
                        isAllDay: false,
                        occurrence: occurrence,
                        isCompleted: isDone(task, at: occurrence, in: completed),
                        assigneeID: task.assigneeID,
                        colorHex: task.categoryID.flatMap { colours[$0] },
                        locationName: task.locationName,
                        leaveBy: estimates[task.id].map {
                            Travel.leaveTime(for: occurrence, estimate: $0)
                        }
                    )
                )
            }
        }

        lines.sort { left, right in
            switch (left.startsAt, right.startsAt) {
            case let (leftDate?, rightDate?): leftDate < rightDate
            case (nil, _): true   // all-day first
            case (_, nil): false
            }
        }

        let shoppingLines = shopping.map {
            WidgetSnapshot.ShoppingLine(id: $0.id, title: $0.title, quantity: $0.quantity)
        }

        let ends = lines.compactMap { line -> Date? in
            guard let startsAt = line.startsAt else { return nil }
            return startsAt.addingTimeInterval(60 * 60)
        }

        let points = WidgetTimeline.points(
            taskStarts: lines.compactMap(\.startsAt),
            taskEnds: ends,
            now: now,
            endOfDay: endOfDay
        )

        return points.map { moment in
            WidgetSnapshot(
                date: moment,
                today: lines,
                shopping: shoppingLines,
                unsyncedCount: unsynced
            )
        }
    }
}
