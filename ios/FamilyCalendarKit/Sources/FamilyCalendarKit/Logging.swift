import Foundation
import OSLog

/// Logging categories. No `print` anywhere — a background sync that fails at
/// 3am has to leave something readable behind.
public enum Log {
    public static let subsystem = "com.example.familycalendar"

    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
}
