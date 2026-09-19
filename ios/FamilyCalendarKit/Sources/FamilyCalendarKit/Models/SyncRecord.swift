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
    // The encoding strategies used to live here, which reads far better and
    // did nothing: GRDB looks them up on the concrete type, and an
    // implementation supplied by an extension of a protocol the type conforms
    // to indirectly is not found. They are in `RecordCoding.swift` now, one
    // per record, and `AppDatabase.verifyEncoding` checks the result rather
    // than anybody's belief about where they belong.

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
