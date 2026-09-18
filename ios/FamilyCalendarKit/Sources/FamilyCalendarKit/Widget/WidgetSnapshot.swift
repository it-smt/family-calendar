import Foundation
import GRDB

/// What the widget shows at one moment.
///
/// A plain value, built from the database and nothing else. The widget process
/// never launches the app and never touches the network — it opens the shared
/// SQLite file in the App Group and reads it.
public struct WidgetSnapshot: Equatable, Sendable {
    public struct TaskLine: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        public let startsAt: Date?
        public let isAllDay: Bool
        public let isCompleted: Bool
        public let assigneeID: UUID?
        public let colorHex: String?
        public let locationName: String?
        /// Filled in at stage 8. Until then the widget shows the start time.
        public let leaveBy: Date?

        public init(
            id: UUID,
            title: String,
            startsAt: Date?,
            isAllDay: Bool,
            isCompleted: Bool,
            assigneeID: UUID?,
            colorHex: String?,
            locationName: String?,
            leaveBy: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.startsAt = startsAt
            self.isAllDay = isAllDay
            self.isCompleted = isCompleted
            self.assigneeID = assigneeID
            self.colorHex = colorHex
            self.locationName = locationName
            self.leaveBy = leaveBy
        }
    }

    public struct ShoppingLine: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        public let quantity: String?

        public init(id: UUID, title: String, quantity: String?) {
            self.id = id
            self.title = title
            self.quantity = quantity
        }
    }

    /// When this snapshot becomes the current one.
    public let date: Date
    public let today: [TaskLine]
    public let shopping: [ShoppingLine]
    /// Local changes the other phone has not seen. Shown as a small mark, the
    /// same as in the app.
    public let unsyncedCount: Int

    public init(
        date: Date,
        today: [TaskLine],
        shopping: [ShoppingLine],
        unsyncedCount: Int
    ) {
        self.date = date
        self.today = today
        self.shopping = shopping
        self.unsyncedCount = unsyncedCount
    }

    /// The next thing that has not happened yet, which is the whole of the small
    /// widget and the headline of the others.
    public var next: TaskLine? {
        today.first { line in
            guard !line.isCompleted else { return false }
            guard let startsAt = line.startsAt else { return line.isAllDay }
            return startsAt >= date
        }
    }

    public var remaining: Int {
        today.filter { !$0.isCompleted }.count
    }

    public static let placeholder = WidgetSnapshot(
        date: .now,
        today: [
            TaskLine(
                id: UUID(),
                title: "Doctor",
                startsAt: .now.addingTimeInterval(3600),
                isAllDay: false,
                isCompleted: false,
                assigneeID: nil,
                colorHex: "#3478F6",
                locationName: "Clinic"
            )
        ],
        shopping: [ShoppingLine(id: UUID(), title: "Milk", quantity: "2")],
        unsyncedCount: 0
    )
}
