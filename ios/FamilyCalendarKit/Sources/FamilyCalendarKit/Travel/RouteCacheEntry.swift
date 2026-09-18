import Foundation
import GRDB

/// A route the device has measured. Device-only, never synchronised: a route is
/// measured from where *this* phone is, and the other phone is somewhere else.
public struct RouteCacheEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "route_cache"

    public var id: Int64?
    public var originCell: String
    public var destinationCell: String
    public var travelMode: TravelMode
    public var durationSeconds: Double
    public var distanceMeters: Double
    public var withTraffic: Bool
    public var measuredAt: Date

    public enum CodingKeys: String, CodingKey {
        case id
        case originCell = "origin_cell"
        case destinationCell = "destination_cell"
        case travelMode = "travel_mode"
        case durationSeconds = "duration_seconds"
        case distanceMeters = "distance_meters"
        case withTraffic = "with_traffic"
        case measuredAt = "measured_at"
    }

    public enum Columns {
        public static let originCell = Column(CodingKeys.originCell)
        public static let destinationCell = Column(CodingKeys.destinationCell)
        public static let travelMode = Column(CodingKeys.travelMode)
        public static let measuredAt = Column(CodingKeys.measuredAt)
    }

    public static var databaseDateEncodingStrategy: DatabaseDateEncodingStrategy {
        .custom { Timestamp.string(from: $0) }
    }

    public static var databaseDateDecodingStrategy: DatabaseDateDecodingStrategy {
        .custom { dbValue in
            guard let string = String.fromDatabaseValue(dbValue) else { return nil }
            return Timestamp.date(from: string)
        }
    }

    public init(
        id: Int64? = nil,
        originCell: String,
        destinationCell: String,
        travelMode: TravelMode,
        durationSeconds: Double,
        distanceMeters: Double,
        withTraffic: Bool,
        measuredAt: Date
    ) {
        self.id = id
        self.originCell = originCell
        self.destinationCell = destinationCell
        self.travelMode = travelMode
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.withTraffic = withTraffic
        self.measuredAt = measuredAt
    }

    public static func find(
        _ db: Database, origin: GeoPoint, destination: GeoPoint, mode: TravelMode
    ) throws -> RouteCacheEntry? {
        try filter(
            Columns.originCell == origin.cell()
                && Columns.destinationCell == destination.cell()
                && Columns.travelMode == mode.rawValue
        )
        .fetchOne(db)
    }

    /// Replaces whatever was there for this leg. One row per leg, always the
    /// most recent measurement.
    public static func store(
        _ db: Database,
        origin: GeoPoint,
        destination: GeoPoint,
        mode: TravelMode,
        duration: TimeInterval,
        distance: Double,
        withTraffic: Bool,
        measuredAt: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO route_cache
                    (origin_cell, destination_cell, travel_mode,
                     duration_seconds, distance_meters, with_traffic, measured_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(origin_cell, destination_cell, travel_mode) DO UPDATE SET
                    duration_seconds = excluded.duration_seconds,
                    distance_meters = excluded.distance_meters,
                    with_traffic = excluded.with_traffic,
                    measured_at = excluded.measured_at
                """,
            arguments: [
                origin.cell(), destination.cell(), mode.rawValue,
                duration, distance, withTraffic, Timestamp.string(from: measuredAt),
            ]
        )
    }

    /// Drops measurements old enough to be worthless even as a fallback.
    public static func prune(_ db: Database, before cutoff: Date) throws {
        try db.execute(
            sql: "DELETE FROM route_cache WHERE measured_at < ?",
            arguments: [Timestamp.string(from: cutoff)]
        )
    }
}
