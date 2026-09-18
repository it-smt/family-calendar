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

    /// One snapshot per moment the widget should be redrawn at.
    public func timeline(now: Date = Date(), calendar: Calendar = .current) throws -> [WidgetSnapshot] {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        let (tasks, categories, shopping, unsynced, origin) = try database.reader.read { db in
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
            return (tasks, categories, shopping, unsynced, origin)
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
            for occurrence in Recurrence.occurrences(of: task, in: startOfDay..<endOfDay) {
                lines.append(
                    WidgetSnapshot.TaskLine(
                        id: task.id,
                        title: task.title,
                        startsAt: occurrence,
                        isAllDay: task.isAllDay,
                        isCompleted: task.isCompleted,
                        assigneeID: task.assigneeID,
                        colorHex: task.categoryID.flatMap { colours[$0] },
                        locationName: task.locationName,
                        leaveBy: estimates[task.id].map {
                            Travel.leaveTime(for: occurrence, estimate: $0)
                        }
                    )
                )
            }
            // All-day tasks have no instant to expand.
            if task.startsAt == nil && task.isAllDay {
                lines.append(
                    WidgetSnapshot.TaskLine(
                        id: task.id,
                        title: task.title,
                        startsAt: nil,
                        isAllDay: true,
                        isCompleted: task.isCompleted,
                        assigneeID: task.assigneeID,
                        colorHex: task.categoryID.flatMap { colours[$0] },
                        locationName: task.locationName
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
