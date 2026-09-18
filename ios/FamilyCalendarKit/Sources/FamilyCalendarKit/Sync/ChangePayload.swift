import Foundation
import GRDB

/// A row on the wire.
///
/// The device stores values in the shape the server serialises them, so this is
/// mostly a pass-through: UUIDs and timestamps are already the right strings,
/// booleans are 0/1, and only JSON columns need unwrapping. See schema/PARITY.md.
public struct ChangePayload: Sendable {
    public var entityType: SyncEntity
    public var values: [String: JSONValue]

    public var id: String? {
        if case .string(let value) = values["id"] { return value }
        return nil
    }

    public var updatedAt: String? {
        if case .string(let value) = values["updated_at"] { return value }
        return nil
    }

    /// Reads a database row into the wire shape.
    public init(entityType: SyncEntity, row: Row) throws {
        self.entityType = entityType
        var values: [String: JSONValue] = [:]

        for (column, databaseValue) in row {
            // The outbox flag is the device's own bookkeeping.
            guard column != "dirty" else { continue }

            if entityType.jsonColumns.contains(column) {
                let text = String.fromDatabaseValue(databaseValue) ?? "[]"
                values[column] = try JSONValue(jsonText: text)
            } else {
                values[column] = JSONValue(databaseValue)
            }
        }

        self.values = values
    }

    public init(entityType: SyncEntity, values: [String: JSONValue]) {
        self.entityType = entityType
        self.values = values
    }

    /// Named arguments for the generated apply statement, turning JSON columns
    /// back into the text the column holds.
    public func statementArguments() throws -> StatementArguments {
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        for (column, value) in values {
            if entityType.jsonColumns.contains(column) {
                arguments[column] = try value.jsonText()
            } else {
                arguments[column] = value.databaseValue
            }
        }
        return StatementArguments(arguments)
    }
}

/// The subset of JSON the protocol uses. Enough to carry a row without pulling
/// in a schema for every entity.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ databaseValue: DatabaseValue) {
        switch databaseValue.storage {
        case .null: self = .null
        case .int64(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .blob: self = .null  // no synchronised column stores a blob
        }
    }

    public init(jsonText: String) throws {
        let data = Data(jsonText.utf8)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func jsonText() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public var databaseValue: (any DatabaseValueConvertible)? {
        switch self {
        case .null: nil
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        // A JSON column that reached here unflagged is stored as its text.
        case .array, .object: try? jsonText()
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
