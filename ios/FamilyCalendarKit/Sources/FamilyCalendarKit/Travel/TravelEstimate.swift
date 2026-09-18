import Foundation

/// How long the journey takes, and how much that answer is worth.
public struct TravelEstimate: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// Measured just now, traffic included.
        case live
        /// Measured earlier and still fresh enough to use as it is.
        case cached
        /// Measured a while ago. Better than geometry, worse than a fresh look.
        case stale
        /// No measurement at all: distance in a straight line, bent and divided
        /// by a typical speed. The answer of last resort, and the reason the
        /// feature works on the underground.
        case estimated
    }

    public let duration: TimeInterval
    public let distance: Double
    public let source: Source
    public let measuredAt: Date

    public init(duration: TimeInterval, distance: Double, source: Source, measuredAt: Date) {
        self.duration = duration
        self.distance = distance
        self.source = source
        self.measuredAt = measuredAt
    }

    /// Whether to say "25 min" or "about 25 min".
    public var isApproximate: Bool {
        source == .stale || source == .estimated
    }
}

public enum Travel {
    /// A few minutes of slack, because nobody leaves the instant they mean to.
    public static let departureBuffer: TimeInterval = 5 * 60

    /// How long a measurement stays usable without being measured again.
    ///
    /// Traffic changes; walking does not. A driving estimate from half an hour
    /// ago is a guess about a different road.
    public static func freshness(for mode: TravelMode, withTraffic: Bool) -> TimeInterval {
        switch mode {
        case .none: 0
        case .walking: 24 * 60 * 60
        case .driving: withTraffic ? 15 * 60 : 60 * 60
        case .transit: 30 * 60
        }
    }

    /// Typical speeds for the fallback, in metres per second.
    ///
    /// Deliberately pessimistic. An estimate that makes someone leave early is
    /// an inconvenience; one that makes them leave late is the failure this
    /// whole feature exists to prevent.
    public static func typicalSpeed(for mode: TravelMode) -> Double {
        switch mode {
        case .none: 0
        case .walking: 5_000 / 3_600
        case .driving: 25_000 / 3_600
        case .transit: 18_000 / 3_600
        }
    }

    /// Straight-line distance bent by a factor, because roads are not straight.
    public static let detourFactor = 1.4

    /// The estimate when there is nothing measured to go on.
    public static func fallback(
        from origin: GeoPoint, to destination: GeoPoint, mode: TravelMode, now: Date
    ) -> TravelEstimate? {
        guard mode != .none else { return nil }
        let straightLine = origin.distance(to: destination)
        let travelled = straightLine * detourFactor
        let speed = typicalSpeed(for: mode)
        guard speed > 0 else { return nil }

        return TravelEstimate(
            duration: travelled / speed,
            distance: travelled,
            source: .estimated,
            measuredAt: now
        )
    }

    /// Picks the best answer available without going to the network.
    ///
    /// A cached route that is still fresh is used as it is. One that has gone
    /// stale is still used — and marked — because a measured road beats a
    /// straight line even when the traffic has moved on. Geometry is the floor.
    public static func offlineEstimate(
        cached: (duration: TimeInterval, distance: Double, withTraffic: Bool, measuredAt: Date)?,
        from origin: GeoPoint,
        to destination: GeoPoint,
        mode: TravelMode,
        now: Date
    ) -> TravelEstimate? {
        if let cached {
            let age = now.timeIntervalSince(cached.measuredAt)
            let limit = freshness(for: mode, withTraffic: cached.withTraffic)
            return TravelEstimate(
                duration: cached.duration,
                distance: cached.distance,
                source: age <= limit ? .cached : .stale,
                measuredAt: cached.measuredAt
            )
        }
        return fallback(from: origin, to: destination, mode: mode, now: now)
    }

    /// When to walk out of the door.
    public static func leaveTime(for start: Date, estimate: TravelEstimate) -> Date {
        start.addingTimeInterval(-estimate.duration - departureBuffer)
    }

    /// Whether a cached measurement is worth replacing yet.
    ///
    /// Asking MapKit again costs battery and, on a metered connection, data.
    /// There is no reason to before the answer could have changed.
    public static func needsRefresh(
        measuredAt: Date?, mode: TravelMode, withTraffic: Bool, now: Date
    ) -> Bool {
        guard let measuredAt else { return true }
        return now.timeIntervalSince(measuredAt) > freshness(for: mode, withTraffic: withTraffic)
    }
}
