import Foundation
import GRDB

/// Which places the phone watches for.
///
/// iOS monitors at most 20 regions per application and refuses the rest, so
/// with more geofenced reminders than that, choosing is the feature. The
/// nearest ones win: a fence around the supermarket two streets away is worth
/// watching today, one around a shop in another city is not.
public struct MonitoredRegion: Equatable, Sendable {
    public let reminderID: UUID
    public let taskID: UUID
    public let centre: GeoPoint
    public let radius: Double
    public let onEnter: Bool
    public let onExit: Bool
    public let title: String

    public var identifier: String { reminderID.uuidString }
}

public enum GeofencePlan {
    /// The system limit, not a preference. Asking for a twenty-first region
    /// does not fail loudly — it simply never fires.
    public static let limit = 20

    /// A fence with no radius is a fence around nothing. Anything smaller than
    /// this is below what location can reliably resolve, so it would either
    /// never fire or fire at random.
    public static let minimumRadius: Double = 100

    /// The regions worth watching from here, nearest first.
    public static func select(
        tasks: [CalendarTask],
        reminders: [UUID: [Reminder]],
        origin: GeoPoint?,
        limit: Int = limit
    ) -> [MonitoredRegion] {
        var candidates: [(region: MonitoredRegion, distance: Double)] = []

        for task in tasks {
            guard !task.isDeleted, !task.isCompleted else { continue }
            for reminder in reminders[task.id] ?? [] {
                guard !reminder.isDeleted, reminder.kind == .geo else { continue }
                guard reminder.onEnter || reminder.onExit else { continue }
                guard let latitude = reminder.latitude, let longitude = reminder.longitude else {
                    continue
                }

                let centre = GeoPoint(latitude: latitude, longitude: longitude)
                let region = MonitoredRegion(
                    reminderID: reminder.id,
                    taskID: task.id,
                    centre: centre,
                    radius: max(reminder.radiusMeters ?? minimumRadius, minimumRadius),
                    onEnter: reminder.onEnter,
                    onExit: reminder.onExit,
                    title: task.title
                )
                // With nowhere to measure from, every fence is equally far, and
                // the tie-break alone decides — stable, if arbitrary.
                candidates.append((region, origin.map { $0.distance(to: centre) } ?? 0))
            }
        }

        candidates.sort {
            $0.distance == $1.distance
                ? $0.region.identifier < $1.region.identifier
                : $0.distance < $1.distance
        }
        return candidates.prefix(limit).map(\.region)
    }

    /// Whether the watched set needs replacing.
    ///
    /// Re-registering regions that are already being watched resets their state
    /// and can cost a fire, so it is worth checking rather than doing on every
    /// location update.
    public static func differs(
        current: [MonitoredRegion], wanted: [MonitoredRegion]
    ) -> Bool {
        Set(current.map(\.identifier)) != Set(wanted.map(\.identifier))
    }

    public static func load(_ db: Database) throws -> (tasks: [CalendarTask], reminders: [UUID: [Reminder]]) {
        let tasks = try CalendarTask
            .filter(CalendarTask.Columns.deletedAt == nil)
            .filter(CalendarTask.Columns.completedAt == nil)
            .fetchAll(db)
        let reminders = try Reminder
            .filter(Reminder.Columns.deletedAt == nil)
            .filter(Reminder.Columns.kind == ReminderKind.geo.rawValue)
            .fetchAll(db)
        return (tasks, Dictionary(grouping: reminders, by: \.taskID))
    }
}
