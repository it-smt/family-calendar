import CoreLocation
import Foundation
import OSLog

/// Watches where the phone is, so the journey is measured from there.
///
/// Uses significant location changes rather than continuous updates: the answer
/// only needs to change when the person has actually moved somewhere else, and
/// significant changes cost almost no battery and survive the app being killed.
///
/// The recalculation is also driven by a timer as the event approaches, because
/// traffic changes while the phone sits still on a table.
public final class LeaveTimeMonitor: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let onLocationChanged: @Sendable (GeoPoint) -> Void

    public private(set) var lastKnown: GeoPoint?

    public init(onLocationChanged: @escaping @Sendable (GeoPoint) -> Void) {
        self.onLocationChanged = onLocationChanged
        super.init()
        manager.delegate = self
    }

    public func start() {
        // "When in use" is enough: the significant-change service delivers to a
        // relaunched app without the always-on permission, and asking for more
        // than a feature needs is a good way to be refused all of it.
        manager.requestWhenInUseAuthorization()
        manager.startMonitoringSignificantLocationChanges()

        if let location = manager.location {
            lastKnown = GeoPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
    }

    public func stop() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    public func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        let point = GeoPoint(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude
        )

        // Only when the cached routes could no longer apply. Staying inside the
        // same cell means the answers already stored are still about this
        // journey.
        if let lastKnown, lastKnown.cell() == point.cell() {
            return
        }

        lastKnown = point
        Log.network.info("significant location change; routes need rechecking")
        onLocationChanged(point)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Location is a convenience here, not a dependency: without it the
        // estimate falls back and the reminder still rings.
        Log.network.debug("location failed: \(error.localizedDescription, privacy: .public)")
    }
}
