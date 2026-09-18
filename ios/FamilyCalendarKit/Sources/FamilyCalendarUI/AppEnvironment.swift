import Foundation
import FamilyCalendarKit
import SwiftUI

/// Wires the layers together once, at launch.
///
/// The view layer gets repositories and a status flag. It has no way to reach
/// the network: `SyncEngine` is not handed out, and nothing above the
/// repositories can await anything that could block on a connection.
@MainActor
public final class AppEnvironment {
    public let database: AppDatabase
    public let status: SyncStatus
    public let tasks: TaskRepository
    public let subtasks: SubtaskRepository
    public let categories: CategoryRepository
    public let supersededEdits: SupersededEditRepository
    public let currentUserID: UUID
    public let householdID: UUID

    private let engine: SyncEngine
    private let monitor: NetworkMonitor
    private let notifications: NotificationScheduler

    public init(
        database: AppDatabase,
        api: SyncAPI,
        credentials: CredentialStore,
        householdID: UUID,
        currentUserID: UUID
    ) throws {
        self.database = database
        self.householdID = householdID
        self.currentUserID = currentUserID

        let status = SyncStatus()
        self.status = status

        let engine = try SyncEngine(
            database: database,
            api: api,
            credentials: credentials,
            status: status,
            currentUserID: currentUserID
        )
        self.engine = engine
        self.monitor = NetworkMonitor()

        let notifications = NotificationScheduler(database: database)
        self.notifications = notifications

        // Every local write asks for a sync and reschedules the alerts, then
        // returns. Neither waits for anything.
        let requestSync: @Sendable () -> Void = {
            Task {
                await notifications.rescheduleAll()
                await engine.schedule()
            }
        }

        self.tasks = TaskRepository(
            database: database, currentUserID: currentUserID, onLocalChange: requestSync
        )
        self.subtasks = SubtaskRepository(
            database: database,
            householdID: householdID,
            currentUserID: currentUserID,
            onLocalChange: requestSync
        )
        self.categories = CategoryRepository(
            database: database,
            householdID: householdID,
            currentUserID: currentUserID,
            onLocalChange: requestSync
        )
        self.supersededEdits = SupersededEditRepository(database: database)
    }

    /// Called at launch, and whenever the app comes back to the foreground.
    public func start() {
        monitor.start { [engine] in Task { await engine.schedule() } }

        Task { [engine, notifications] in
            await notifications.requestAuthorization()

            // A sync that changed anything invalidates the schedule: an alert
            // may now be for a task the other person moved, or deleted.
            await engine.onChangesApplied {
                await notifications.rescheduleAll()
                await notifications.notifyAboutReplacedEdits()
            }

            await notifications.rescheduleAll()
            await engine.schedule()
        }
    }

    public func syncNow() {
        Task { await engine.schedule() }
    }

    /// On the way to the background: one more sync, and a fresh schedule.
    ///
    /// The alerts have to be right before the app stops running, because from
    /// then until the next launch they are all there is.
    public func enteringBackground() {
        Task { [engine, notifications] in
            await notifications.rescheduleAll()
            await engine.schedule()
        }
    }
}
