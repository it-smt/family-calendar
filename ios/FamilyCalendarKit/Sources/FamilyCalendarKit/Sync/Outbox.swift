import Foundation
import GRDB

/// Everything written locally that the server has not acknowledged.
///
/// There is no queue to keep in step with the data: the outbox *is* the rows
/// with `dirty = 1`. A write that never reaches the network is not lost, and a
/// crash between writing and sending changes nothing.
public struct Outbox: Sendable {
    public struct Item: Sendable {
        public let entityType: SyncEntity
        public let payload: ChangePayload
        /// The version this was sent as. Used to decide whether clearing the
        /// flag afterwards is still honest.
        public let sentUpdatedAt: String
        public let id: String
    }

    public static func collect(_ db: Database, limit: Int) throws -> [Item] {
        var items: [Item] = []

        for entity in SyncEntity.pushable {
            guard items.count < limit else { break }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(entity.tableName)
                    WHERE dirty = 1
                    ORDER BY updated_at, id
                    LIMIT ?
                    """,
                arguments: [limit - items.count]
            )
            for row in rows {
                let payload = try ChangePayload(entityType: entity, row: row)
                guard let id = payload.id, let updatedAt = payload.updatedAt else {
                    Log.sync.error("row in \(entity.tableName, privacy: .public) has no id or updated_at; skipping")
                    continue
                }
                items.append(
                    Item(entityType: entity, payload: payload, sentUpdatedAt: updatedAt, id: id)
                )
            }
        }

        return items
    }

    /// Clears the flag on rows the server has seen — but only where the row has
    /// not been edited again since it was sent.
    ///
    /// The user can type while the request is in flight. Clearing every row that
    /// was sent would mark that edit as delivered when the server has never seen
    /// it, and nothing would ever send it.
    public static func markClean(_ db: Database, items: [Item]) throws {
        for item in items {
            try db.execute(
                sql: """
                    UPDATE \(item.entityType.tableName)
                    SET dirty = 0
                    WHERE id = ? AND updated_at = ?
                    """,
                arguments: [item.id, item.sentUpdatedAt]
            )
        }
    }
}
