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

    @Parameter(title: "Done")
    public var completed: Bool

    public init() {
        self.taskID = ""
        self.completed = true
    }

    public init(taskID: UUID, completed: Bool) {
        self.taskID = taskID.uuidString
        self.completed = completed
    }

    public func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }

        let database = try AppDatabase.shared()
        let session = await CredentialStore().session

        try await database.writer.write { db in
            guard var task = try CalendarTask.fetchOne(db, key: id) else { return }
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
                api: SyncAPI(baseURL: WidgetServer.url),
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

/// Where the widget extension finds the server. The same value the app uses.
///
/// Not `WidgetConfiguration`: WidgetKit has a protocol by that name, and a
/// widget's `var body: some WidgetConfiguration` means that one.
public enum WidgetServer {
    public nonisolated(unsafe) static var url = URL(string: "http://localhost:8000")!
}
