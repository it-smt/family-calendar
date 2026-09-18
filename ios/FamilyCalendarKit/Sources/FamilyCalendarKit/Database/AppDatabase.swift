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

    public enum DatabaseError: Error {
        case appGroupUnavailable(String)
        case schemaResourceMissing(String)
    }
}
