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
    }

    /// Opens the shared database. Both the app and the widget call this.
    public static func shared(appGroupIdentifier: String = appGroupIdentifier) throws -> AppDatabase {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            )
        else {
            throw DatabaseError.appGroupUnavailable(appGroupIdentifier)
        }

        let url = container.appendingPathComponent(fileName)
        log.debug("opening database at \(url.path, privacy: .public)")
        return try AppDatabase(writer: DatabasePool(path: url.path, configuration: configuration))
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

    public enum DatabaseError: Error {
        case appGroupUnavailable(String)
        case schemaResourceMissing(String)
    }
}
