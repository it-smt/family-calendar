import Foundation
import GRDB

/// One instant of a repeating task, ticked off.
///
/// A repeat is a single row and a rule, so there is nowhere on the task to
/// record that this Tuesday is done. Ticking one off used to strike it out of
/// the rule instead: the line vanished rather than going grey, and "пропустить"
/// and "сделано" became the same thing.
///
/// One row per completed instant, rather than a list of dates on the task. A
/// daily chore makes three hundred and sixty-five of them in a year, and as a
/// list inside the task's row the whole thing would travel on every edit — and
/// two people ticking different days offline would overwrite each other, since
/// last-write-wins replaces a row whole. Separate rows do not collide at all.
public struct OccurrenceCompletion: HouseholdScopedRecord {
    public var id: UUID
    public var householdID: UUID
    public var taskID: UUID
    /// The instant the rule put it on, not when it was ticked.
    public var occurrence: Date
    public var completedBy: UUID?

    public var createdAt: Date
    public var updatedAt: Date
    public var updatedBy: UUID?
    public var deletedAt: Date?
    public var dirty: Bool

    public init(
        id: UUID = UUID(),
        householdID: UUID,
        taskID: UUID,
        occurrence: Date,
        completedBy: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedBy: UUID? = nil,
        deletedAt: Date? = nil,
        dirty: Bool = true
    ) {
        self.id = id
        self.householdID = householdID
        self.taskID = taskID
        self.occurrence = occurrence
        self.completedBy = completedBy
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
        case occurrence
        case completedBy = "completed_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case deletedAt = "deleted_at"
        case dirty
    }
}

extension OccurrenceCompletion: TableRecord {
    public static let databaseTableName = "occurrence_completions"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let householdID = Column(CodingKeys.householdID)
        public static let taskID = Column(CodingKeys.taskID)
        public static let occurrence = Column(CodingKeys.occurrence)
        public static let updatedAt = Column(CodingKeys.updatedAt)
        public static let deletedAt = Column(CodingKeys.deletedAt)
        public static let dirty = Column(CodingKeys.dirty)
    }
}
