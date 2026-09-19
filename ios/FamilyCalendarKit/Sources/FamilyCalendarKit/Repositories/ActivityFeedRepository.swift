import Foundation
import GRDB

/// The change feed: so data never changes silently.
///
/// The server stores the verb and the label, not a sentence. The phrasing is
/// built here, where the language and the reader's own name are known — "she
/// moved the doctor to 16:00" is not a string a database should be holding.
/// A page of the feed with the people it mentions.
public struct FeedSnapshot: Sendable {
    public let entries: [ActivityEntry]
    public let people: [UUID: User]
    /// What was asked for. A full page means there is probably another.
    public let limit: Int

    public init(entries: [ActivityEntry], people: [UUID: User], limit: Int) {
        self.entries = entries
        self.people = people
        self.limit = limit
    }

    public var mayHaveMore: Bool { entries.count >= limit }
}

public struct ActivityFeedRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// How long the feed is kept, matching the server's rule exactly.
    ///
    /// Both sides drop the same rows by the same measure, so they converge
    /// without either having to tell the other. The device may delete outright:
    /// an activity entry is never pushed, so a row removed here was never this
    /// device's to keep.
    public static let retentionDays = 90

    @discardableResult
    public func prune(olderThanDays days: Int = retentionDays) throws -> Int {
        let cutoff = Timestamp.string(
            from: Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        )
        return try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM activity_entries WHERE created_at < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    /// The feed and the people in it, together.
    ///
    /// One observation rather than two: the entries are useless without the
    /// names, and two streams meant the whole screen was rebuilt twice for one
    /// change and could be caught between them.
    public func observe(limit: Int = 100) -> AsyncValueObservation<FeedSnapshot> {
        ValueObservation
            .tracking { db -> FeedSnapshot in
                FeedSnapshot(
                    entries: try ActivityEntry.feed(db, limit: limit),
                    people: Dictionary(
                        uniqueKeysWithValues: try User.fetchAll(db).map { ($0.id, $0) }
                    ),
                    limit: limit
                )
            }
            .values(in: database.reader)
    }
}
