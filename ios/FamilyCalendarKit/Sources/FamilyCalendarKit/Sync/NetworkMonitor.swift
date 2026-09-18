import Foundation
import Network
import OSLog
// OSAllocatedUnfairLock lives in `os`, which `OSLog` does not bring with it.
import os

/// Watches for the network coming back.
///
/// Only a hint. Nothing waits for it, and a sync is never skipped because this
/// says the network is down — `NWPathMonitor` can be wrong in both directions,
/// and the retry loop handles a failed attempt anyway.
public final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.example.familycalendar.network")

    public init() {}

    /// Fires every time the path becomes satisfied after not being satisfied.
    public func start(onReachable: @escaping @Sendable () -> Void) {
        let wasReachable = OSAllocatedUnfairLock(initialState: false)

        monitor.pathUpdateHandler = { path in
            let reachable = path.status == .satisfied
            let shouldFire = wasReachable.withLock { (previous: inout Bool) -> Bool in
                defer { previous = reachable }
                return reachable && !previous
            }
            if shouldFire {
                Log.network.info("network is back; syncing")
                onReachable()
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
