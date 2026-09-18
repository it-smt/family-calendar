import Foundation

/// A coordinate, and the two things this application does with one.
public struct GeoPoint: Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Metres between two points along the surface, by the haversine formula.
    ///
    /// Good to a fraction of a percent at the distances a household travels,
    /// which is far better than the guess it feeds.
    public func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = latitude * .pi / 180
        let phi2 = other.latitude * .pi / 180
        let deltaPhi = (other.latitude - latitude) * .pi / 180
        let deltaLambda = (other.longitude - longitude) * .pi / 180

        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The cache key for this point: a grid cell rather than the point itself.
    ///
    /// Two attempts from the same flat should hit the same cached route. With
    /// exact coordinates they never would, because a phone never reports the
    /// same position twice.
    public func cell(precision: Double = GeoPoint.cellSize) -> String {
        let latitudeCell = (latitude / precision).rounded()
        let longitudeCell = (longitude / precision).rounded()
        return "\(Int(latitudeCell)):\(Int(longitudeCell))"
    }

    /// Roughly 500 m of latitude. Wide enough to hit, narrow enough that the
    /// answer is still about the journey being asked about.
    public static let cellSize = 0.005
}
