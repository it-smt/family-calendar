import Foundation
import GRDB
import UserNotifications

/// Puts the plan into iOS, and tells someone when their edit was replaced.
///
/// Alerts are local, so they fire with no network and with the app killed —
/// which is the whole point. Nothing here waits for a server.
public actor NotificationScheduler {
    private let database: AppDatabase
    private let center: UNUserNotificationCenter

    public init(database: AppDatabase, center: UNUserNotificationCenter = .current()) {
        self.database = database
        self.center = center
    }

    public func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.sync.error("notification permission: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the database, drops every pending alert, and schedules the plan.
    ///
    /// Called at launch, on the way to the background, after every successful
    /// sync, and after any local change to a task. Replacing the whole set is
    /// cheaper to get right than reconciling it, and it is the only way an
    /// alert for a task the partner deleted reliably disappears.
    public func rescheduleAll(now: Date = Date()) async {
        let plan: [PlannedNotification]
        do {
            plan = try await database.writer.read { db in
                let loaded = try NotificationPlan.load(db)
                return NotificationPlan.make(
                    tasks: loaded.tasks, reminders: loaded.reminders, now: now
                )
            }
        } catch {
            Log.database.error("could not build the plan: \(error.localizedDescription, privacy: .public)")
            return
        }

        center.removeAllPendingNotificationRequests()

        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.userInfo = ["task_id": item.taskID.uuidString]
            content.threadIdentifier = item.taskID.uuidString

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: item.fireAt
            )
            let request = UNNotificationRequest(
                identifier: item.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )

            do {
                try await center.add(request)
            } catch {
                Log.sync.error("could not schedule: \(error.localizedDescription, privacy: .public)")
            }
        }

        Log.sync.info("scheduled \(plan.count, privacy: .public) notifications")
    }

    /// Tells this person that an edit of theirs was replaced.
    ///
    /// A banner in the app only reaches someone who opens the app, and losing
    /// an edit is exactly the thing they will not think to go looking for. The
    /// alert is delivered immediately rather than scheduled, so it costs
    /// nothing against the pending limit.
    ///
    /// The device can only notice this while applying a pull, so on a phone
    /// with the app killed and no background push yet, the alert arrives at the
    /// next sync. There is nowhere earlier it could come from.
    public func notifyAboutReplacedEdits() async {
        let notices: [SupersededEdit]
        do {
            notices = try await database.writer.read { db in try SupersededEdit.unnotified(db) }
        } catch {
            Log.database.error("could not read notices: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !notices.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = "superseded"

        if notices.count == 1, let difference = notices[0].differences().first {
            content.title = "Your change was replaced"
            content.body = "\(label(for: difference.field)) went back to what it was. Open to put yours back."
        } else {
            content.title = "\(notices.count) of your changes were replaced"
            content.body = "Open the calendar to see what changed and put them back."
        }

        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: "superseded-\(notices.compactMap(\.id).map(String.init).joined(separator: "-"))",
                    content: content,
                    // Delivered now. A nil trigger is not a pending request, so
                    // it does not compete for the 64 slots.
                    trigger: nil
                )
            )
            try await database.writer.write { db in
                try SupersededEdit.markNotified(notices, in: db)
            }
        } catch {
            Log.sync.error("could not deliver the notice: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func label(for field: String) -> String {
        switch field {
        case "title": "The title"
        case "starts_at": "The time"
        case "notes": "The notes"
        case "location_name": "The place"
        default: "Something"
        }
    }
}
