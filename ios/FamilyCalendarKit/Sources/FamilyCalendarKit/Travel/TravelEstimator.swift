import Foundation
import GRDB
import OSLog
#if canImport(MapKit)
import MapKit
#endif

/// Works out how long a journey takes, and remembers the answer.
///
/// Split deliberately in two. `cachedEstimate` reads the database and returns
/// at once — that is what the notification scheduler and the widget use, and it
/// is why neither of them can ever be left waiting on MapKit. `refresh` is the
/// part that goes to the network, and it only ever improves what is already
/// stored.
public actor TravelEstimator {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The best answer available without a network. Never nil when the task has
    /// coordinates: geometry is the floor.
    public nonisolated static func cachedEstimate(
        _ db: Database,
        from origin: GeoPoint,
        to destination: GeoPoint,
        mode: TravelMode,
        now: Date = Date()
    ) throws -> TravelEstimate? {
        guard mode != .none else { return nil }
        let entry = try RouteCacheEntry.find(db, origin: origin, destination: destination, mode: mode)
        return Travel.offlineEstimate(
            cached: entry.map {
                ($0.durationSeconds, $0.distanceMeters, $0.withTraffic, $0.measuredAt)
            },
            from: origin,
            to: destination,
            mode: mode,
            now: now
        )
    }

    /// Measures the journey again if the stored answer could have changed, and
    /// writes the result to the cache.
    ///
    /// Returns whether anything changed, so the caller knows whether the alerts
    /// are now wrong and need rebuilding.
    @discardableResult
    public func refresh(
        from origin: GeoPoint,
        to destination: GeoPoint,
        mode: TravelMode,
        now: Date = Date()
    ) async -> Bool {
        guard mode != .none else { return false }

        let existing: RouteCacheEntry? = (try? await database.writer.read { db in
            try RouteCacheEntry.find(db, origin: origin, destination: destination, mode: mode)
        }) ?? nil

        guard
            Travel.needsRefresh(
                measuredAt: existing?.measuredAt,
                mode: mode,
                withTraffic: existing?.withTraffic ?? true,
                now: now
            )
        else {
            return false
        }

        guard let measured = await measure(from: origin, to: destination, mode: mode) else {
            // No network, or MapKit had nothing. The cache keeps whatever it
            // had, and the fallback covers the rest.
            Log.network.debug("no route available; keeping what is cached")
            return false
        }

        do {
            try await database.writer.write { db in
                try RouteCacheEntry.store(
                    db,
                    origin: origin,
                    destination: destination,
                    mode: mode,
                    duration: measured.duration,
                    distance: measured.distance,
                    withTraffic: measured.withTraffic,
                    measuredAt: now
                )
            }
            return true
        } catch {
            Log.database.error("could not store the route: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    #if canImport(MapKit)
    private func measure(
        from origin: GeoPoint, to destination: GeoPoint, mode: TravelMode
    ) async -> (duration: TimeInterval, distance: Double, withTraffic: Bool)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: origin.latitude, longitude: origin.longitude
                )
            )
        )
        request.destination = MKMapItem(
            placemark: MKPlacemark(
                coordinate: CLLocationCoordinate2D(
                    latitude: destination.latitude, longitude: destination.longitude
                )
            )
        )
        request.departureDate = Date()

        switch mode {
        case .walking: request.transportType = .walking
        case .transit: request.transportType = .transit
        case .driving, .none: request.transportType = .automobile
        }

        do {
            let response = try await MKDirections(request: request).calculateETA()
            return (
                duration: response.expectedTravelTime,
                distance: response.distance,
                // MapKit accounts for traffic when driving; walking has none to
                // account for, which is why a walking measurement lasts a day.
                withTraffic: mode == .driving || mode == .transit
            )
        } catch {
            Log.network.debug("ETA failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    #else
    private func measure(
        from origin: GeoPoint, to destination: GeoPoint, mode: TravelMode
    ) async -> (duration: TimeInterval, distance: Double, withTraffic: Bool)? {
        nil
    }
    #endif

    /// Every task worth measuring a route for right now.
    ///
    /// Only those close enough to matter: measuring a route for next Tuesday
    /// spends battery on an answer that will be stale long before anyone needs
    /// it.
    public nonisolated static func tasksNeedingRoutes(
        _ db: Database, now: Date, within horizon: TimeInterval = 3 * 60 * 60
    ) throws -> [(task: CalendarTask, occurrence: Date, destination: GeoPoint)] {
        let tasks = try CalendarTask
            .filter(CalendarTask.Columns.deletedAt == nil)
            .filter(CalendarTask.Columns.completedAt == nil)
            .filter(CalendarTask.Columns.travelMode != TravelMode.none.rawValue)
            .fetchAll(db)

        var needed: [(CalendarTask, Date, GeoPoint)] = []
        let window = now..<now.addingTimeInterval(horizon)

        for task in tasks {
            guard let latitude = task.latitude, let longitude = task.longitude else { continue }
            let destination = GeoPoint(latitude: latitude, longitude: longitude)
            for occurrence in Recurrence.occurrences(of: task, in: window) {
                needed.append((task, occurrence, destination))
            }
        }

        return needed.sorted { $0.1 < $1.1 }
    }
}
