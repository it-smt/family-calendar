import Foundation
import GRDB

/// The entities the protocol moves, and the few facts the sync layer needs
/// about each one.
///
/// The sync layer works on rows rather than typed records: a change is a whole
/// row in both directions, and going through nine record types to move it would
/// add nine places to forget a column. Typed records are what the repositories
/// and the UI use.
public enum SyncEntity: String, CaseIterable, Sendable {
    case household
    case user
    case category
    case packingTemplate = "packing_template"
    case task
    case reminder
    case subtask
    case shoppingItem = "shopping_item"
    case activityEntry = "activity_entry"

    public var tableName: String {
        switch self {
        case .household: "households"
        case .user: "users"
        case .category: "categories"
        case .packingTemplate: "packing_templates"
        case .task: "tasks"
        case .reminder: "reminders"
        case .subtask: "subtasks"
        case .shoppingItem: "shopping_items"
        case .activityEntry: "activity_entries"
        }
    }

    /// The feed is written on the server. A device pushing one back would start
    /// a loop, and the server rejects it anyway.
    public var isPushable: Bool { self != .activityEntry }

    /// Columns holding JSON text, which travels as JSON rather than as a string.
    public var jsonColumns: Set<String> {
        switch self {
        case .task: ["recurrence_exceptions"]
        case .packingTemplate: ["items"]
        default: []
        }
    }

    /// Everything a device may send, in an order that reads naturally in a log.
    /// The server's foreign keys are deferred, so this is presentation, not a
    /// dependency sort.
    public static let pushable: [SyncEntity] = allCases.filter(\.isPushable)
}
