import CoreLocation
import Foundation
import GRDB
import OSLog
import UserNotifications

/// Watches the chosen places and rings when one is crossed.
///
/// Region monitoring is delivered by the system even when the app is not
/// running, which is the only reason a "remind me at the shop" reminder is
/// worth having at all.
public final class GeofenceMonitor: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let database: AppDatabase
    private let center: UNUserNotificationCenter

    public init(database: AppDatabase, center: UNUserNotificationCenter = .current()) {
        self.database = database
        self.center = center
        super.init()
        manager.delegate = self
    }

    /// Region monitoring needs "always", unlike the significant-change service.
    /// Asked for separately, and only when the household actually uses a
    /// geofenced reminder.
    public func requestAuthorizationIfNeeded() {
        let wanted = (try? database.reader.read { db in
            try GeofencePlan.load(db)
        })
        guard let wanted, !wanted.reminders.isEmpty else { return }
        manager.requestAlwaysAuthorization()
    }

    public var monitored: [MonitoredRegion] {
        currentlyMonitored
    }

    private var currentlyMonitored: [MonitoredRegion] = []

    /// Refreshes from the last position the database knows about.
    public func refreshFromDatabase() {
        let origin = try? database.reader.read { db in try SyncState.current(db).origin }
        refresh(origin: origin ?? nil)
    }

    /// Replaces the watched set when it should change, and leaves it alone when
    /// it should not.
    public func refresh(origin: GeoPoint?) {
        let wanted: [MonitoredRegion]
        do {
            let loaded = try database.reader.read { db in try GeofencePlan.load(db) }
            wanted = GeofencePlan.select(
                tasks: loaded.tasks, reminders: loaded.reminders, origin: origin
            )
        } catch {
            Log.database.error("could not choose regions: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard GeofencePlan.differs(current: currentlyMonitored, wanted: wanted) else { return }

        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        for region in wanted {
            let circle = CLCircularRegion(
                center: CLLocationCoordinate2D(
                    latitude: region.centre.latitude, longitude: region.centre.longitude
                ),
                radius: region.radius,
                identifier: region.identifier
            )
            circle.notifyOnEntry = region.onEnter
            circle.notifyOnExit = region.onExit
            manager.startMonitoring(for: circle)
        }

        currentlyMonitored = wanted
        Log.network.info("watching \(wanted.count, privacy: .public) places")
    }

    public func locationManager(
        _ manager: CLLocationManager, didEnterRegion region: CLRegion
    ) {
        ring(for: region.identifier, entering: true)
    }

    public func locationManager(
        _ manager: CLLocationManager, didExitRegion region: CLRegion
    ) {
        ring(for: region.identifier, entering: false)
    }

    private func ring(for identifier: String, entering: Bool) {
        guard let region = currentlyMonitored.first(where: { $0.identifier == identifier })
        else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = region.title
        content.body = entering ? "You are here — this was the reminder." : "On your way — this was the reminder."
        content.sound = .default
        content.userInfo = ["task_id": region.taskID.uuidString]

        // Delivered now, not scheduled, so it does not touch the pending limit.
        center.add(
            UNNotificationRequest(identifier: "geo-\(identifier)-\(entering)", content: content, trigger: nil)
        ) { error in
            if let error {
                Log.sync.error("geofence alert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
