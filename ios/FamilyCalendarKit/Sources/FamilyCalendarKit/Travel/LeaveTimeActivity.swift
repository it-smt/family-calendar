import Foundation
import OSLog
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The Live Activity for a journey that is about to start.
///
/// Shared between the app, which starts and updates it, and the widget
/// extension, which draws it.
public struct LeaveTimeAttributes: Sendable, Codable, Hashable {
    public struct ContentState: Sendable, Codable, Hashable {
        public var leaveAt: Date
        public var arriveBy: Date
        public var travelMinutes: Int
        /// Whether to say "25 min" or "about 25 min". A guess presented as a
        /// measurement is worse than a guess admitted as one.
        public var isApproximate: Bool

        public init(leaveAt: Date, arriveBy: Date, travelMinutes: Int, isApproximate: Bool) {
            self.leaveAt = leaveAt
            self.arriveBy = arriveBy
            self.travelMinutes = travelMinutes
            self.isApproximate = isApproximate
        }
    }

    public var taskID: UUID
    public var taskTitle: String
    public var destinationName: String?

    public init(taskID: UUID, taskTitle: String, destinationName: String?) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.destinationName = destinationName
    }
}

#if canImport(ActivityKit)
extension LeaveTimeAttributes: ActivityAttributes {}

/// Starts, updates and ends the countdown.
///
/// A Live Activity is worth having for exactly one window — from shortly before
/// someone has to leave until they should have arrived — and is a nuisance
/// outside it, so it is started late and ended promptly.
///
/// Deliberately holds nothing. ActivityKit already keeps the running
/// activities, and a dictionary of our own would be a second answer to the same
/// question — one that goes stale the moment the system ends an activity itself,
/// which it does when the user swipes it away or the stale date passes. Looking
/// it up each time is also what keeps this free of isolation: an `Activity` is
/// not `Sendable`, so holding one in an actor and then awaiting a method on it
/// is sending it somewhere it must not go.
public enum LeaveTimeActivities {
    /// How long before leaving the countdown appears.
    public static let leadTime: TimeInterval = 30 * 60

    /// The running activity for this task, if there is one.
    static func current(for taskID: UUID) -> Activity<LeaveTimeAttributes>? {
        Activity<LeaveTimeAttributes>.activities.first { $0.attributes.taskID == taskID }
    }

    public static func update(
        taskID: UUID,
        title: String,
        destinationName: String?,
        occurrence: Date,
        estimate: TravelEstimate,
        now: Date = Date()
    ) async {
        let leaveAt = Travel.leaveTime(for: occurrence, estimate: estimate)
        let content = ActivityContent(
            state: LeaveTimeAttributes.ContentState(
                leaveAt: leaveAt,
                arriveBy: occurrence,
                travelMinutes: Int((estimate.duration / 60).rounded()),
                isApproximate: estimate.isApproximate
            ),
            staleDate: occurrence
        )

        // Outside the window there is nothing to show.
        guard now >= leaveAt.addingTimeInterval(-leadTime), now < occurrence else {
            await end(taskID: taskID)
            return
        }

        if let activity = current(for: taskID) {
            await activity.update(content)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            _ = try Activity.request(
                attributes: LeaveTimeAttributes(
                    taskID: taskID, taskTitle: title, destinationName: destinationName
                ),
                content: content
            )
        } catch {
            Log.sync.error("could not start the countdown: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func end(taskID: UUID) async {
        guard let activity = current(for: taskID) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    public static func endAll() async {
        for activity in Activity<LeaveTimeAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
