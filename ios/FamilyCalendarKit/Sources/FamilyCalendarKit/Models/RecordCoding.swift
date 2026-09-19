import Foundation
import GRDB

/// How every synchronised record is written: uppercase UUID strings and RFC
/// 3339 timestamps, matching the server byte for byte.
///
/// GRDB's own defaults are a sixteen-byte blob and "YYYY-MM-DD HH:MM:SS.SSS".
/// A blob matches no text primary key, so with them in force every foreign key
/// in this schema fails at COMMIT and the device cannot write a single row.
///
/// Spelled out once here and attached to each record type below, one by one.
/// It was attached to `SyncRecord` instead, which reads far better and does
/// nothing at all: GRDB looks these up on the concrete type, and an
/// implementation supplied by an extension of a protocol the type conforms to
/// indirectly is not found. Nothing warns about it — the app simply cannot
/// write, anywhere, and says `FOREIGN KEY constraint failed`. `AppDatabase`
/// checks the result at launch rather than trusting this file.
extension UUID {
    /// How an identifier is written into a query.
    ///
    /// The strategies below cover records on their way *into* a row. A `UUID`
    /// handed straight to a query expression, a statement argument or
    /// `fetchOne(db, key:)` does not go through them: GRDB converts it itself,
    /// to a sixteen-byte blob, which equals none of the text this schema
    /// stores. The query then matches nothing and reports nothing — the list
    /// of things to bring was written correctly and read back empty for
    /// exactly that reason.
    ///
    /// So every comparison against an id column goes through this, and reads
    /// as a deliberate act rather than a `UUID` that happens to be in the
    /// right place.
    public var storedKey: String { uuidString }
}

enum RecordCoding {
    static let uuid = DatabaseUUIDEncodingStrategy.uppercaseString

    static let dateEncoding = DatabaseDateEncodingStrategy.custom { date in
        Timestamp.string(from: date)
    }

    static let dateDecoding = DatabaseDateDecodingStrategy.custom { dbValue in
        guard let string = String.fromDatabaseValue(dbValue) else { return nil }
        return Timestamp.date(from: string)
    }
}

extension Household {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension User {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension TaskCategory {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension PackingTemplate {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension ShoppingItem {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension CalendarTask {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension Reminder {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension Subtask {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension ActivityEntry {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}

extension OccurrenceCompletion {
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        RecordCoding.uuid
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        RecordCoding.dateEncoding
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        RecordCoding.dateDecoding
    }
}
