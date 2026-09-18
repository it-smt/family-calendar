import Foundation
import GRDB

/// Device-local bookkeeping. Exactly one row, never synchronised.
///
/// `pullCursor` is the `seq` of the last change the device has applied — a
/// server-assigned sequence number, not a timestamp, because two devices'
/// clocks drift and a time-based cursor eventually skips a row for good.
public struct SyncState: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "sync_state"
    public static let singletonID = 1

    public var id: Int
    public var pullCursor: Int64
    public var lastSyncedAt: Date?

    public init(id: Int = SyncState.singletonID, pullCursor: Int64 = 0, lastSyncedAt: Date? = nil) {
        self.id = id
        self.pullCursor = pullCursor
        self.lastSyncedAt = lastSyncedAt
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case pullCursor = "pull_cursor"
        case lastSyncedAt = "last_synced_at"
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

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let pullCursor = Column(CodingKeys.pullCursor)
        public static let lastSyncedAt = Column(CodingKeys.lastSyncedAt)
    }
}
