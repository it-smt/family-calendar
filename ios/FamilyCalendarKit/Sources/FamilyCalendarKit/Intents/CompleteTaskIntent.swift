import AppIntents
import Foundation
import GRDB
import WidgetKit

/// Ticking a task off from the widget.
///
/// Runs in the widget's process, writes to the shared database, and returns.
/// The write is the whole point: it is durable the moment it lands, marked for
/// the outbox, and the alerts are rescheduled on the spot because a finished
/// task should stop ringing.
///
/// A push is attempted afterwards and its failure is ignored. That is not
/// sloppiness: the change is already safe, and the alternative — holding up a
/// tap on a widget until a server answers — is the thing this whole application
/// is built to avoid.
public struct CompleteTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "Mark done"
    public static let description = IntentDescription("Ticks a task off from the widget.")

    @Parameter(title: "Task")
    public var taskID: String

    /// Какой именно раз, для повторов. Пусто — задача разовая.
    @Parameter(title: "Occurrence")
    public var occurrence: String

    @Parameter(title: "Done")
    public var completed: Bool

    public init() {
        self.taskID = ""
        self.occurrence = ""
        self.completed = true
    }

    public init(taskID: UUID, occurrence: Date?, completed: Bool) {
        self.taskID = taskID.uuidString
        self.occurrence = occurrence.map(Timestamp.string(from:)) ?? ""
        self.completed = completed
    }

    public func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }

        let database = try AppDatabase.shared()
        let session = await CredentialStore().session

        let moment = Timestamp.date(from: occurrence)

        try await database.writer.write { db in
            guard var task = try CalendarTask.fetchOne(db, key: id.storedKey) else { return }

            // Повтор — одна строка и правило, поэтому «сделано» для конкретного
            // вторника это своя строка. Иначе отметка с виджета пометила бы
            // выполненной всю серию, а в списке дня не изменилось бы ничего.
            if task.rrule != nil, let moment {
                let stamp = Timestamp.string(from: Timestamp.truncatedToMilliseconds(moment))
                let existing = try OccurrenceCompletion
                    .filter(OccurrenceCompletion.Columns.taskID == task.id.storedKey)
                    .filter(OccurrenceCompletion.Columns.occurrence == stamp)
                    .filter(OccurrenceCompletion.Columns.deletedAt == nil)
                    .fetchAll(db)

                if completed {
                    guard existing.isEmpty else { return }
                    var row = OccurrenceCompletion(
                        householdID: task.householdID,
                        taskID: task.id,
                        occurrence: Timestamp.truncatedToMilliseconds(moment),
                        completedBy: session?.userID
                    )
                    row.touch(by: session?.userID)
                    try row.insert(db)
                } else {
                    for row in existing {
                        var draft = row
                        draft.markDeleted(by: session?.userID)
                        try draft.update(db)
                    }
                }
                return
            }

            task.completedAt = completed ? Date() : nil
            task.touch(by: session?.userID)
            try task.update(db)
        }

        // The tap is done; everything after this is housekeeping.
        WidgetCenter.shared.reloadAllTimelines()
        await NotificationScheduler(database: database).rescheduleAll()

        if let session {
            let engine = try SyncEngine(
                database: database,
                api: SyncAPI(baseURL: ServerAddress.current),
                credentials: CredentialStore(),
                status: await SyncStatus(),
                currentUserID: session.userID
            )
            // Best effort, and deliberately not awaited beyond this call: an
            // extension gets little time, and the change is already safe.
            try? await engine.syncOnce()
        }

        return .result()
    }
}
