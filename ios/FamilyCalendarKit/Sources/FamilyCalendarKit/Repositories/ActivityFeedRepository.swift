import Foundation
import GRDB

/// The change feed: so data never changes silently.
///
/// The server stores the verb and the label, not a sentence. The phrasing is
/// built here, where the language and the reader's own name are known — "she
/// moved the doctor to 16:00" is not a string a database should be holding.
public struct ActivityFeedRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func observe(limit: Int = 100) -> AsyncValueObservation<[ActivityEntry]> {
        ValueObservation
            .tracking { db in try ActivityEntry.feed(db, limit: limit) }
            .values(in: database.reader)
    }

    public func people() -> AsyncValueObservation<[UUID: User]> {
        ValueObservation
            .tracking { db in
                Dictionary(
                    uniqueKeysWithValues: try User.fetchAll(db).map { ($0.id, $0) }
                )
            }
            .values(in: database.reader)
    }
}
