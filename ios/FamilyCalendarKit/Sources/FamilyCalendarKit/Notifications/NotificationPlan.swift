import Foundation
import GRDB

/// What to schedule, worked out without touching iOS.
///
/// Kept separate from the scheduler so the decisions — which occurrences, in
/// what order, and where the line is drawn — can be reasoned about and tested
/// on their own. The scheduler below only hands the result to the system.
public struct PlannedNotification: Equatable, Sendable {
    public let taskID: UUID
    public let reminderID: UUID
    /// The instant of the task itself, not of the alert.
    public let occurrence: Date
    public let fireAt: Date
    public let title: String
    public let body: String

    /// Stable across reschedules, so replacing the set does not shuffle
    /// identifiers around.
    public var identifier: String {
        "\(taskID.uuidString)|\(reminderID.uuidString)|\(Int(occurrence.timeIntervalSince1970))"
    }
}

public enum NotificationPlan {
    /// iOS keeps at most 64 pending notifications per app and silently drops
    /// the rest. Staying well under leaves room for the ones scheduled between
    /// two reschedules, and for anything a later stage adds.
    public static let limit = 50

    /// How far ahead recurring tasks are expanded. Far enough that a phone left
    /// in a drawer for a fortnight still rings; short enough that one daily
    /// task cannot fill the whole budget.
    public static let horizon: TimeInterval = 60 * 24 * 60 * 60

    /// The nearest alerts that are still ahead, soonest first.
    ///
    /// Everything is recomputed from the database each time rather than kept in
    /// step with it: there is no separate schedule to fall out of date, and a
    /// reschedule after a sync cannot leave an alert for a task the other
    /// person has already deleted.
    public static func make(
        tasks: [CalendarTask],
        reminders: [UUID: [Reminder]],
        now: Date = Date(),
        limit: Int = limit,
        horizon: TimeInterval = horizon
    ) -> [PlannedNotification] {
        let window = now..<now.addingTimeInterval(horizon)
        var planned: [PlannedNotification] = []

        for task in tasks {
            guard !task.isDeleted, !task.isCompleted else { continue }
            guard let taskReminders = reminders[task.id], !taskReminders.isEmpty else { continue }

            for occurrence in Recurrence.occurrences(of: task, in: window) {
                for reminder in taskReminders {
                    guard !reminder.isDeleted else { continue }
                    // Geofences are regions, not scheduled alerts, and are
                    // rationed separately.
                    guard reminder.kind != .geo else { continue }

                    let fireAt = occurrence.addingTimeInterval(
                        TimeInterval(reminder.offsetMinutes) * 60
                    )
                    guard fireAt > now else { continue }

                    planned.append(
                        PlannedNotification(
                            taskID: task.id,
                            reminderID: reminder.id,
                            occurrence: occurrence,
                            fireAt: fireAt,
                            title: task.title,
                            body: body(for: task, occurrence: occurrence, reminder: reminder)
                        )
                    )
                }
            }
        }

        // Soonest first, then by identifier so two alerts at the same instant
        // always cut the same way.
        planned.sort {
            $0.fireAt == $1.fireAt ? $0.identifier < $1.identifier : $0.fireAt < $1.fireAt
        }
        return Array(planned.prefix(limit))
    }

    static func body(for task: CalendarTask, occurrence: Date, reminder: Reminder) -> String {
        var parts: [String] = [occurrence.formatted(date: .omitted, time: .shortened)]
        if let place = task.locationName, !place.isEmpty {
            parts.append(place)
        }
        if reminder.kind == .leaveTime {
            // Stage 8 replaces this with a real travel time. Until then the
            // offset is taken at face value, which is what a plain reminder
            // would have done anyway.
            parts.append("time to go")
        }
        return parts.joined(separator: " · ")
    }

    /// Everything the planner needs, in two queries.
    public static func load(_ db: Database) throws
        -> (tasks: [CalendarTask], reminders: [UUID: [Reminder]])
    {
        let tasks = try CalendarTask
            .filter(CalendarTask.Columns.deletedAt == nil)
            .filter(CalendarTask.Columns.completedAt == nil)
            .fetchAll(db)

        let reminders = try Reminder
            .filter(Reminder.Columns.deletedAt == nil)
            .fetchAll(db)

        return (tasks, Dictionary(grouping: reminders, by: \.taskID))
    }
}
