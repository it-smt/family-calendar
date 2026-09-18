import Foundation
import GRDB

public enum TravelMode: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case none
    case walking
    case driving
    case transit
}

/// Named `CalendarTask`, not `Task`: inside this module a type called `Task`
/// shadows Swift concurrency's `Task`, and every `Task { ... }` in a view model
/// would have to be written `_Concurrency.Task { ... }`. The table stays `tasks`.
public struct CalendarTask: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var title: String
    public var notes: String?

    public var startsAt: Date?
    public var durationMinutes: Int?
    public var isAllDay: Bool

    public var locationName: String?
    public var latitude: Double?
    public var longitude: Double?

    /// RFC 5545, stored verbatim and expanded into instances on the device.
    public var rrule: String?
    /// JSON array of RFC 3339 strings. Kept as strings rather than `[Date]` so
    /// the column holds exactly what the server stores; use
    /// `recurrenceExceptionDates` to work with them.
    public var recurrenceExceptions: [String]

    public var assigneeID: UUID?
    public var createdBy: UUID
    public var categoryID: UUID?

    public var completedAt: Date?
    public var travelMode: TravelMode

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        title: String,
        notes: String? = nil,
        startsAt: Date? = nil,
        durationMinutes: Int? = nil,
        isAllDay: Bool = false,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rrule: String? = nil,
        recurrenceExceptions: [String] = [],
        assigneeID: UUID? = nil,
        createdBy: UUID,
        categoryID: UUID? = nil,
        completedAt: Date? = nil,
        travelMode: TravelMode = .none,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.title = title
        self.notes = notes
        self.startsAt = startsAt
        self.durationMinutes = durationMinutes
        self.isAllDay = isAllDay
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.rrule = rrule
        self.recurrenceExceptions = recurrenceExceptions
        self.assigneeID = assigneeID
        self.createdBy = createdBy
        self.categoryID = categoryID
        self.completedAt = completedAt
        self.travelMode = travelMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public var isCompleted: Bool { completedAt != nil }

    public var recurrenceExceptionDates: [Date] {
        get { recurrenceExceptions.compactMap(Timestamp.date(from:)) }
        set { recurrenceExceptions = newValue.map(Timestamp.string(from:)) }
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case title
        case notes
        case startsAt = "starts_at"
        case durationMinutes = "duration_minutes"
        case isAllDay = "is_all_day"
        case locationName = "location_name"
        case latitude
        case longitude
        case rrule
        case recurrenceExceptions = "recurrence_exceptions"
        case assigneeID = "assignee_id"
        case createdBy = "created_by"
        case categoryID = "category_id"
        case completedAt = "completed_at"
        case travelMode = "travel_mode"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension CalendarTask: TableRecord {
    public static let databaseTableName = "tasks"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let title = Column(CodingKeys.title)
        public static let startsAt = Column(CodingKeys.startsAt)
        public static let assigneeID = Column(CodingKeys.assigneeID)
        public static let categoryID = Column(CodingKeys.categoryID)
        public static let completedAt = Column(CodingKeys.completedAt)
        public static let travelMode = Column(CodingKeys.travelMode)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }

    public static let reminders = hasMany(Reminder.self)
    public static let subtasks = hasMany(Subtask.self)
}

public enum ReminderKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case fixed
    case leaveTime = "leave_time"
    case geo
}

public struct Reminder: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var taskID: UUID
    /// Negative means before the start of the task.
    public var offsetMinutes: Int
    public var kind: ReminderKind

    public var latitude: Double?
    public var longitude: Double?
    public var radiusMeters: Double?
    public var onEnter: Bool
    public var onExit: Bool

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        taskID: UUID,
        offsetMinutes: Int = 0,
        kind: ReminderKind = .fixed,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radiusMeters: Double? = nil,
        onEnter: Bool = false,
        onExit: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.taskID = taskID
        self.offsetMinutes = offsetMinutes
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.onEnter = onEnter
        self.onExit = onExit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case taskID = "task_id"
        case offsetMinutes = "offset_minutes"
        case kind
        case latitude
        case longitude
        case radiusMeters = "radius_meters"
        case onEnter = "on_enter"
        case onExit = "on_exit"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension Reminder: TableRecord {
    public static let databaseTableName = "reminders"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let taskID = Column(CodingKeys.taskID)
        public static let kind = Column(CodingKeys.kind)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }

    public static let task = belongsTo(CalendarTask.self)
}

/// A step of a task, and also a "what to bring" item.
public struct Subtask: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var taskID: UUID
    public var title: String
    public var isDone: Bool
    public var sortOrder: Int

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        taskID: UUID,
        title: String,
        isDone: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.taskID = taskID
        self.title = title
        self.isDone = isDone
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case householdID = "household_id"
        case taskID = "task_id"
        case title
        case isDone = "is_done"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension Subtask: TableRecord {
    public static let databaseTableName = "subtasks"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let taskID = Column(CodingKeys.taskID)
        public static let isDone = Column(CodingKeys.isDone)
        public static let sortOrder = Column(CodingKeys.sortOrder)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }

    public static let task = belongsTo(CalendarTask.self)
}
