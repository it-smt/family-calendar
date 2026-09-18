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

        // Every local write asks for a sync and returns. Nothing waits for it.
        let requestSync: @Sendable () -> Void = { Task { await engine.schedule() } }

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
        Task { await engine.schedule() }
    }

    public func syncNow() {
        Task { await engine.schedule() }
    }
}
