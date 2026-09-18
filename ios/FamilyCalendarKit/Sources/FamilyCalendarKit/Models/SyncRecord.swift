import Foundation
import GRDB

/// Columns every synchronised record carries.
///
/// `dirty` is the outbox: a row written locally is dirty until the server has
/// acknowledged it. Nothing in the UI ever waits for that to happen.
public protocol SyncRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: UUID { get }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
    var updatedBy: UUID? { get set }
    var deletedAt: Date? { get set }
    var dirty: Bool { get set }
}

extension SyncRecord {
    /// Uppercase UUID strings and RFC 3339 timestamps, matching the server byte
    /// for byte. GRDB would otherwise store UUIDs as blobs and dates in its own
    /// format, and every change row would need translating on the way out.
    public static var databaseUUIDEncodingStrategy: DatabaseUUIDEncodingStrategy {
        .uppercaseString
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

    public var isDeleted: Bool { deletedAt != nil }

    /// Marks a local edit. Every write from the UI goes through this, so no code
    /// path can forget to queue the row for the next push — and no two versions
    /// of a row can end up sharing a version stamp.
    public mutating func touch(by userID: UUID?, at date: Date = Date()) {
        updatedAt = Timestamp.strictlyAfter(updatedAt, now: date)
        updatedBy = userID
        dirty = true
    }

    /// Soft delete. Rows are never removed: the tombstone is what tells the
    /// other device the row is gone.
    public mutating func markDeleted(by userID: UUID?, at date: Date = Date()) {
        deletedAt = date
        touch(by: userID, at: date)
    }
}

/// A record owned by the household, which is everything except the household.
public protocol HouseholdScopedRecord: SyncRecord {
    var householdID: UUID { get set }
}
