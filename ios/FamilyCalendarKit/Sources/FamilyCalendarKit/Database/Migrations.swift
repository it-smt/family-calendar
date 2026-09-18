import Foundation
import GRDB

extension AppDatabase {
    /// Migrations are append-only: a released version is never edited, because
    /// a device that has been offline for a month replays them in order.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Rebuild from scratch when the schema changes during development.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: schemaSQL(named: "v1_initial"))
        }

        migrator.registerMigration("v2_superseded_edits") { db in
            try db.execute(sql: schemaSQL(named: "v2_superseded_edits"))
        }

        migrator.registerMigration("v3_route_cache") { db in
            try db.execute(sql: schemaSQL(named: "v3_route_cache"))
        }

        return migrator
    }

    /// The schema lives in a `.sql` file rather than a Swift string so the very
    /// same text can be checked against the Postgres schema by the server's
    /// parity test.
    static func schemaSQL(named name: String) throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "sql", subdirectory: "SQL"
            )
        else {
            throw DatabaseError.schemaResourceMissing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
