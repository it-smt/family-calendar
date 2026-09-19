import Foundation
import GRDB
import OSLog

/// The device database. The single source of truth for the app, the widget and
/// the notification scheduler.
///
/// The file lives in the App Group container so the widget can read it directly,
/// without launching the app and without a network round trip.
public final class AppDatabase: Sendable {
    public static let appGroupIdentifier = "group.com.example.familycalendar"
    private static let fileName = "family-calendar.sqlite"

    private static let log = Logger(subsystem: "com.example.familycalendar", category: "database")

    public let reader: any DatabaseReader
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        self.reader = writer
        try Self.migrator.migrate(writer)
        try writer.write { db in try Self.verifyEncoding(db) }
    }

    /// Proves that a record written through GRDB lands in the shape the schema
    /// expects, before anything is allowed to depend on it.
    ///
    /// Identifiers go in as uppercase text and timestamps as RFC 3339, because
    /// that is what arrives from the server and the two have to be the same
    /// bytes. GRDB's own defaults are a sixteen-byte blob and
    /// "YYYY-MM-DD HH:MM:SS.SSS", and a blob matches no text primary key: with
    /// the defaults in force every foreign key in this schema fails at COMMIT
    /// and the app cannot write a single row anywhere.
    ///
    /// Which is what it did, for days, because the strategies that override
    /// those defaults are static functions taking a column name and had been
    /// written as properties. That compiles. It is simply never called, and
    /// nothing says so. So this stops asking the code and asks SQLite, on a row
    /// that is rolled back.
    static func verifyEncoding(_ db: Database) throws {
        let probe = Household(id: UUID(), name: "probe", inviteCode: UUID().uuidString)
        var problems: [String] = []

        try db.inSavepoint {
            try probe.insert(db)

            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT typeof(id) AS idType, id AS id,
                           typeof(updated_at) AS stampType, updated_at AS stamp
                    FROM households WHERE rowid = last_insert_rowid()
                    """
            ) {
                let idType = text(row, "idType") ?? "nothing"
                let id = text(row, "id")
                let stampType = text(row, "stampType") ?? "nothing"
                let stamp = text(row, "stamp")

                if idType != "text" || id != probe.id.uuidString {
                    problems.append(
                        "identifiers are written as \(idType) (\(id ?? "unreadable"))"
                    )
                }
                // Compared against the exact bytes, not parsed: `Timestamp`
                // also reads the shape SQLite writes on its own, so parsing
                // would accept the very format this is here to rule out.
                if stampType != "text" || stamp != Timestamp.string(from: probe.updatedAt) {
                    problems.append(
                        "timestamps are written as \(stampType) (\(stamp ?? "unreadable"))"
                    )
                }
            } else {
                problems.append("the probe row could not be read back")
            }

            return .rollback
        }

        guard problems.isEmpty else {
            // What the record says it wants, alongside what SQLite got. The two
            // disagreeing means GRDB is not asking this type at all, which is a
            // different fault from the type answering wrongly.
            let declared = """
                declared: \(Household.databaseUUIDEncodingStrategy(for: "id")), \
                \(Household.databaseDateEncodingStrategy(for: "updated_at"))
                """
            let summary = problems.joined(separator: "; ")
            log.error(
                "the database encoding is wrong: \(summary, privacy: .public) [\(declared, privacy: .public)]"
            )
            throw DatabaseError.encodingMismatch(summary)
        }
    }

    /// Reads a column without converting it, so a value of the wrong type
    /// reports itself instead of tripping GRDB's conversion trap.
    private static func text(_ row: Row, _ column: String) -> String? {
        let value: DatabaseValue = row[column]
        return String.fromDatabaseValue(value)
    }

    /// Opens the shared database. Both the app and the widget call this.
    ///
    /// Falls back to the app's own container when the App Group is not
    /// available — which is what happens before the capability is switched on,
    /// and on a free developer account that cannot switch it on at all. The app
    /// then works completely; only the widget, which is a second process and
    /// has nowhere else to look, does not. Refusing to start would make the
    /// first run of this project a dead end for no good reason.
    public static func shared(appGroupIdentifier: String = appGroupIdentifier) throws -> AppDatabase {
        let url = try location(appGroupIdentifier: appGroupIdentifier)
        log.debug("opening database at \(url.path, privacy: .public)")
        return try AppDatabase(writer: DatabasePool(path: url.path, configuration: configuration))
    }

    /// Where the database file lives, and why.
    public static func location(appGroupIdentifier: String = appGroupIdentifier) throws -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return container.appendingPathComponent(fileName)
        }

        log.warning(
            """
            App Group \(appGroupIdentifier, privacy: .public) is not available, \
            so the database is going in this process's own container. The app \
            works; the widget will not see the data until the capability is on.
            """
        )

        let documents = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents.appendingPathComponent(fileName)
    }

    /// Whether the two processes really are looking at the same file.
    ///
    /// Worth showing in the app rather than leaving someone to wonder why the
    /// widget is empty.
    public static var isSharedWithWidget: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil
    }

    /// An in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    public static var configuration: Configuration {
        var configuration = Configuration()
        // Deferred checks let a batch of rows arrive in any order inside one
        // transaction, which is how both a sync pull and an outbox write land.
        configuration.foreignKeysEnabled = true
        // The widget and the app open the same file from the App Group. An
        // extension still holding a database lock when the system suspends it
        // is killed outright (0xdead10cc); this makes GRDB let go in time.
        configuration.observesSuspensionNotifications = true
        return configuration
    }

    public enum DatabaseError: Error, LocalizedError {
        case appGroupUnavailable(String)
        case schemaResourceMissing(String)
        case encodingMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable(let identifier):
                "Группа приложений \(identifier) недоступна."
            case .schemaResourceMissing(let name):
                "В сборку не попал файл схемы \(name).sql."
            case .encodingMismatch(let detail):
                "База пишет данные не в том виде: \(detail)."
            }
        }
    }
}
