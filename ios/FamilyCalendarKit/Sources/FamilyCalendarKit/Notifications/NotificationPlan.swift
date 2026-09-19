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
        estimates: [UUID: TravelEstimate] = [:],
        completed: Set<CompletedOccurrence> = [],
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
                // A chore already ticked off for this Tuesday must not ring on
                // Tuesday. An alert for something done is exactly what makes
                // people turn alerts off.
                guard !completed.contains(
                    CompletedOccurrence(taskID: task.id, occurrence: occurrence)
                ) else { continue }

                for reminder in taskReminders {
                    guard !reminder.isDeleted else { continue }
                    // Geofences are regions, not scheduled alerts, and are
                    // rationed separately.
                    guard reminder.kind != .geo else { continue }

                    // A "leave now" reminder counts back from the door, not
                    // from the appointment: its offset is how long before
                    // leaving to be warned. Without an estimate it behaves like
                    // an ordinary reminder rather than going silent.
                    let anchor: Date
                    if reminder.kind == .leaveTime, let estimate = estimates[task.id] {
                        anchor = Travel.leaveTime(for: occurrence, estimate: estimate)
                    } else {
                        anchor = occurrence
                    }

                    let fireAt = anchor.addingTimeInterval(
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
                            body: body(
                                for: task,
                                occurrence: occurrence,
                                reminder: reminder,
                                estimate: estimates[task.id]
                            )
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

    static func body(
        for task: CalendarTask,
        occurrence: Date,
        reminder: Reminder,
        estimate: TravelEstimate?
    ) -> String {
        var parts: [String] = []

        if reminder.kind == .leaveTime, let estimate {
            // What a person actually needs to know is not "in 30 minutes" but
            // "leave at 15:35, the journey is 25 minutes". The first is a
            // countdown to the wrong thing.
            let leaveAt = Travel.leaveTime(for: occurrence, estimate: estimate)
            let minutes = Int((estimate.duration / 60).rounded())
            parts.append("Leave \(leaveAt.formatted(date: .omitted, time: .shortened))")
            parts.append(
                estimate.isApproximate
                    ? "about \(minutes) min"
                    : "\(minutes) min with traffic"
            )
        } else {
            parts.append(occurrence.formatted(date: .omitted, time: .shortened))
        }

        if let place = task.locationName, !place.isEmpty {
            parts.append(place)
        }
        return parts.joined(separator: " · ")
    }

    /// Everything the planner needs, in two queries.
    public static func load(_ db: Database) throws -> (
        tasks: [CalendarTask],
        reminders: [UUID: [Reminder]],
        completed: Set<CompletedOccurrence>
    ) {
        let tasks = try CalendarTask
            .filter(CalendarTask.Columns.deletedAt == nil)
            .filter(CalendarTask.Columns.completedAt == nil)
            .fetchAll(db)

        let reminders = try Reminder
            .filter(Reminder.Columns.deletedAt == nil)
            .fetchAll(db)

        // Only what is still ahead: a tick from last month cannot silence
        // anything, and the set is what the planner checks every occurrence
        // against.
        let since = Timestamp.string(from: Date().addingTimeInterval(-24 * 60 * 60))
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT task_id AS task, occurrence AS at FROM occurrence_completions
                WHERE deleted_at IS NULL AND occurrence >= ?
                """,
            arguments: [since]
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

        return (tasks, Dictionary(grouping: reminders, by: \.taskID), completed)
    }
}
