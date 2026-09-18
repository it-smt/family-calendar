import Foundation
import GRDB

/// Keeps the "when to leave" answers current.
///
/// Three things make an answer go out of date: the phone moving, the clock
/// getting closer to the event, and the task itself changing. This reacts to
/// the first two; the third already reschedules through the repositories.
///
/// Nothing here is ever awaited by the interface. The alerts are rebuilt from
/// the cache after a refresh lands, which means a failed measurement changes
/// nothing rather than breaking something.
public actor LeaveTimeCoordinator {
    private let database: AppDatabase
    private let estimator: TravelEstimator
    private let onRoutesChanged: @Sendable () async -> Void

    private var monitor: LeaveTimeMonitor?
    private var ticker: Task<Void, Never>?
    private var origin: GeoPoint?

    /// How often to look again while an event is close. Traffic moves while the
    /// phone does not.
    public static let tick: Duration = .seconds(10 * 60)

    public init(
        database: AppDatabase,
        onRoutesChanged: @escaping @Sendable () async -> Void
    ) {
        self.database = database
        self.estimator = TravelEstimator(database: database)
        self.onRoutesChanged = onRoutesChanged
    }

    public func start() async {
        guard monitor == nil else { return }

        let monitor = LeaveTimeMonitor { [weak self] point in
            Task { await self?.locationChanged(to: point) }
        }
        monitor.start()
        self.monitor = monitor

        // Fall back to the last position written down, so a launch before the
        // first location update still has somewhere to measure from.
        if let known = monitor.lastKnown {
            self.origin = known
        } else {
            self.origin = try? await database.writer.read { db in
                try SyncState.current(db).origin
            } ?? nil
        }

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRoutes()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        monitor?.stop()
        monitor = nil
    }

    private func locationChanged(to point: GeoPoint) async {
        origin = point
        // Written down so the widget, which has no location permission of its
        // own, can work out the same answer from the same cache.
        try? await database.writer.write { db in try SyncState.setOrigin(point, in: db) }
        await refreshRoutes()
    }

    /// Measures the journeys that matter now, and rebuilds the alerts if any
    /// answer moved.
    public func refreshRoutes(now: Date = Date()) async {
        guard let origin else { return }

        let needed: [(task: CalendarTask, occurrence: Date, destination: GeoPoint)]
        do {
            needed = try await database.writer.read { db in
                try TravelEstimator.tasksNeedingRoutes(db, now: now)
            }
        } catch {
            Log.database.error("could not list journeys: \(error.localizedDescription, privacy: .public)")
            return
        }

        var changed = false
        for item in needed {
            let updated = await estimator.refresh(
                from: origin, to: item.destination, mode: item.task.travelMode, now: now
            )
            changed = changed || updated
        }

        // Old measurements are worse than useless once nobody would trust them.
        try? await database.writer.write { db in
            try RouteCacheEntry.prune(db, before: now.addingTimeInterval(-30 * 24 * 60 * 60))
        }

        if changed {
            await onRoutesChanged()
        }
    }

    /// The estimate for one task, read from the cache alone.
    public nonisolated static func estimates(
        _ db: Database, origin: GeoPoint?, now: Date
    ) throws -> [UUID: TravelEstimate] {
        guard let origin else { return [:] }

        var estimates: [UUID: TravelEstimate] = [:]
        for item in try TravelEstimator.tasksNeedingRoutes(db, now: now, within: 24 * 60 * 60) {
            guard estimates[item.task.id] == nil else { continue }
            estimates[item.task.id] = try TravelEstimator.cachedEstimate(
                db, from: origin, to: item.destination, mode: item.task.travelMode, now: now
            )
        }
        return estimates
    }
}
