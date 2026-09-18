import Foundation
import FamilyCalendarKit
import SwiftUI
import WidgetKit

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
    public let shopping: ShoppingRepository
    public let packingTemplates: PackingTemplateRepository
    public let activityFeed: ActivityFeedRepository
    public let currentUserID: UUID
    public let householdID: UUID

    private let engine: SyncEngine
    private let monitor: NetworkMonitor
    private let notifications: NotificationScheduler
    private let leaveTime: LeaveTimeCoordinator
    private let geofences: GeofenceMonitor

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

        let geofences = GeofenceMonitor(database: database)
        self.geofences = geofences

        // A route that changed makes the alerts wrong, so measuring one ends in
        // the same place a sync does: rebuild them. Moving also changes which
        // places are worth watching, and only twenty of them can be.
        self.leaveTime = LeaveTimeCoordinator(database: database) { [weak geofences] in
            await notifications.rescheduleAll()
            await geofences?.refreshFromDatabase()
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Every local write asks for a sync and reschedules the alerts, then
        // returns. Neither waits for anything.
        let requestSync: @Sendable () -> Void = {
            // The widget reads the same file, so it is already right — but it
            // is a separate process and has to be told to look again.
            WidgetCenter.shared.reloadAllTimelines()
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
        self.shopping = ShoppingRepository(
            database: database,
            householdID: householdID,
            currentUserID: currentUserID,
            onLocalChange: requestSync
        )
        self.packingTemplates = PackingTemplateRepository(
            database: database,
            householdID: householdID,
            currentUserID: currentUserID,
            onLocalChange: requestSync
        )
        self.activityFeed = ActivityFeedRepository(database: database)
    }

    /// Called at launch, and whenever the app comes back to the foreground.
    public func start() {
        monitor.start { [engine] in Task { await engine.schedule() } }

        Task { [engine, notifications, currentUserID] in
            await notifications.requestAuthorization()

            // A sync that changed anything invalidates the schedule: an alert
            // may now be for a task the other person moved, or deleted.
            await engine.onChangesApplied {
                await notifications.rescheduleAll()
                await notifications.notifyAboutReplacedEdits()
                await notifications.notifyAboutDelegatedWork(currentUserID: currentUserID)
                WidgetCenter.shared.reloadAllTimelines()
            }

            await notifications.rescheduleAll()
            await engine.schedule()
        }

        Task { [leaveTime, geofences] in
            await leaveTime.start()
            geofences.requestAuthorizationIfNeeded()
            await geofences.refreshFromDatabase()
        }
    }

    public func syncNow() {
        Task { [engine] in await engine.schedule() }
    }

    /// A background push woke us. Pull, then put the alerts right.
    ///
    /// Awaited, unlike every other sync in this file, because the system is
    /// holding the app awake only until this returns.
    public func syncFromBackground() async {
        await engine.syncNowAndWait()
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
