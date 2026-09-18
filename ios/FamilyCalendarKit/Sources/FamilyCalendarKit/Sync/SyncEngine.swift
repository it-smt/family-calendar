import Foundation
import GRDB

/// Drives the protocol: push what is ours, then pull what is theirs.
///
/// An actor, and nothing above it ever awaits a sync. `schedule()` returns
/// immediately; the UI reads the database, which is already up to date with
/// every local write.
public actor SyncEngine {
    public struct Configuration: Sendable {
        public var pushBatchSize: Int = 500
        public var pullPageSize: Int = 500
        public var firstRetryDelay: Duration = .seconds(1)
        public var maximumRetryDelay: Duration = .seconds(300)

        public init() {}
    }

    private let database: AppDatabase
    private let api: SyncAPI
    private let credentials: CredentialStore
    private let applier: ChangeApplier
    private let configuration: Configuration
    private let status: SyncStatus

    private var running: Task<Void, Never>?
    private var retryDelay: Duration

    /// Called after a sync changed anything. Stage 6 hangs notification
    /// rescheduling here, stage 7 the widget reload.
    private var changesAppliedHandler: (@Sendable () async -> Void)?

    public func onChangesApplied(_ handler: @escaping @Sendable () async -> Void) {
        changesAppliedHandler = handler
    }

    public init(
        database: AppDatabase,
        api: SyncAPI,
        credentials: CredentialStore,
        status: SyncStatus,
        currentUserID: UUID,
        configuration: Configuration = Configuration()
    ) throws {
        self.database = database
        self.api = api
        self.credentials = credentials
        self.status = status
        self.configuration = configuration
        self.applier = try ChangeApplier(currentUserID: currentUserID)
        self.retryDelay = configuration.firstRetryDelay
    }

    /// Ask for a sync. Returns at once; at most one runs at a time.
    public func schedule() {
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.runUntilQuiet()
            await self?.finished()
        }
    }

    private func finished() {
        running = nil
    }

    private func runUntilQuiet() async {
        do {
            try await syncOnce()
            retryDelay = configuration.firstRetryDelay
        } catch SyncAPI.Failure.unauthorized {
            // The token expired or was revoked. Credentials live in the
            // Keychain precisely so this does not become a login screen in the
            // middle of someone's morning.
            Log.auth.info("token rejected; re-authenticating")
            if await credentials.refresh(using: api) {
                await retryLater()
            } else {
                Log.auth.error("re-authentication failed; waiting for the user")
            }
        } catch SyncAPI.Failure.rejected(let status, let body) {
            // Retrying the same bytes will not help. Left for a person to see
            // in the log rather than spun on.
            Log.sync.error("server rejected the push (\(status, privacy: .public)): \(body, privacy: .private)")
        } catch {
            Log.sync.debug("sync failed, will retry: \(error.localizedDescription, privacy: .public)")
            await retryLater()
        }
        await refreshStatus(isSyncing: false)
    }

    private func retryLater() async {
        let delay = retryDelay
        // Exponential, with a ceiling, and a little jitter so two devices that
        // lost the network together do not come back in lockstep.
        let jitter = Double.random(in: 0.85...1.15)
        retryDelay = min(
            Duration.seconds(delay.components.seconds * 2), configuration.maximumRetryDelay
        )
        try? await Task.sleep(for: .seconds(Double(delay.components.seconds) * jitter))
        guard !Task.isCancelled else { return }
        await runUntilQuiet()
    }

    /// One round trip: send, then receive.
    public func syncOnce() async throws {
        guard let token = await credentials.token else {
            Log.sync.debug("no token yet; nothing to sync")
            return
        }
        await refreshStatus(isSyncing: true)

        try await pushOutbox(token: token)
        let applied = try await pullChanges(token: token)

        if applied > 0 {
            await changesAppliedHandler?()
        }
        try await recordSyncTime()
    }

    private func pushOutbox(token: String) async throws {
        while true {
            let items = try await database.writer.read { db in
                try Outbox.collect(db, limit: configuration.pushBatchSize)
            }
            guard !items.isEmpty else { return }

            _ = try await api.push(items.map(\.payload), token: token)

            try await database.writer.write { db in
                try Outbox.markClean(db, items: items)
            }
            Log.sync.info("pushed \(items.count, privacy: .public) changes")

            guard items.count == configuration.pushBatchSize else { return }
        }
    }

    private func pullChanges(token: String) async throws -> Int {
        var applied = 0
        while true {
            let cursor = try await database.writer.read { db in
                try SyncState.current(db).pullCursor
            }
            let page = try await api.pull(
                since: cursor, limit: configuration.pullPageSize, token: token
            )

            let applier = self.applier
            try await database.writer.write { db in
                for change in page.changes {
                    guard let entity = SyncEntity(rawValue: change.entityType) else {
                        // A type this build does not know about. Skipping it is
                        // safe: the cursor still advances, and a newer build
                        // will pull it again from a fresh install.
                        Log.sync.error("unknown entity type \(change.entityType, privacy: .public)")
                        continue
                    }
                    try applier.apply(
                        ChangePayload(entityType: entity, values: change.payload), to: db
                    )
                    applied += 1
                }
                try SyncState.setCursor(page.cursor, in: db)
            }

            if !page.hasMore { break }
        }

        if applied > 0 {
            Log.sync.info("applied \(applied, privacy: .public) changes")
        }
        return applied
    }

    private func recordSyncTime() async throws {
        try await database.writer.write { db in
            try SyncState.setLastSynced(Date(), in: db)
        }
    }

    private func refreshStatus(isSyncing: Bool) async {
        let pending = (try? await database.writer.read { db in
            try Outbox.collect(db, limit: Int.max).count
        }) ?? 0
        let lastSynced = try? await database.writer.read { db in
            try SyncState.current(db).lastSyncedAt
        }
        await status.update(
            pending: pending, lastSyncedAt: lastSynced ?? nil, isSyncing: isSyncing
        )
    }
}
