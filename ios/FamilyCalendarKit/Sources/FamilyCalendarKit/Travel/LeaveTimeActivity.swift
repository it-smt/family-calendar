import Foundation
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
@available(iOS 16.2, *)
public actor LeaveTimeActivities {
    /// How long before leaving the countdown appears.
    public static let leadTime: TimeInterval = 30 * 60

    private var running: [UUID: Activity<LeaveTimeAttributes>] = [:]

    public init() {}

    public func update(
        taskID: UUID,
        title: String,
        destinationName: String?,
        occurrence: Date,
        estimate: TravelEstimate,
        now: Date = Date()
    ) async {
        let leaveAt = Travel.leaveTime(for: occurrence, estimate: estimate)
        let state = LeaveTimeAttributes.ContentState(
            leaveAt: leaveAt,
            arriveBy: occurrence,
            travelMinutes: Int((estimate.duration / 60).rounded()),
            isApproximate: estimate.isApproximate
        )

        // Outside the window there is nothing to show.
        guard now >= leaveAt.addingTimeInterval(-Self.leadTime), now < occurrence else {
            await end(taskID: taskID)
            return
        }

        if let activity = running[taskID] {
            await activity.update(ActivityContent(state: state, staleDate: occurrence))
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            running[taskID] = try Activity.request(
                attributes: LeaveTimeAttributes(
                    taskID: taskID, taskTitle: title, destinationName: destinationName
                ),
                content: ActivityContent(state: state, staleDate: occurrence)
            )
        } catch {
            Log.sync.error("could not start the countdown: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func end(taskID: UUID) async {
        guard let activity = running.removeValue(forKey: taskID) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    public func endAll() async {
        for taskID in running.keys {
            await end(taskID: taskID)
        }
    }
}
#endif
