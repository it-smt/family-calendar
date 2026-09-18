import Foundation
import GRDB

/// Applies a pulled change to the device database.
///
/// The rules live in generated SQL (`Database/SQL/apply/*.sql` and
/// `supersede/*.sql`), not here, because the device resolves conflicts too: a
/// row arriving from a pull can be older than an edit made offline and not yet
/// pushed, and applying it blindly would throw that edit away. The same
/// statements are what the protocol tests execute, so the rules are tested
/// where they are written.
public struct ChangeApplier: Sendable {
    private let apply: [SyncEntity: String]
    private let supersede: [SyncEntity: String]
    private let currentUserID: UUID

    public init(currentUserID: UUID, bundle: Bundle = .module) throws {
        self.currentUserID = currentUserID
        self.apply = try Self.load(from: "SQL/apply", bundle: bundle)
        self.supersede = try Self.load(from: "SQL/supersede", bundle: bundle)
    }

    private static func load(from subdirectory: String, bundle: Bundle) throws -> [SyncEntity: String] {
        var statements: [SyncEntity: String] = [:]
        for entity in SyncEntity.allCases {
            guard
                let url = bundle.url(
                    forResource: entity.rawValue, withExtension: "sql", subdirectory: subdirectory
                )
            else {
                throw AppDatabase.DatabaseError.schemaResourceMissing(
                    "\(subdirectory)/\(entity.rawValue).sql"
                )
            }
            statements[entity] = try String(contentsOf: url, encoding: .utf8)
        }
        return statements
    }

    public func apply(_ payload: ChangePayload, to db: Database) throws {
        guard
            let applyStatement = apply[payload.entityType],
            let supersedeStatement = supersede[payload.entityType]
        else {
            throw AppDatabase.DatabaseError.schemaResourceMissing(payload.entityType.rawValue)
        }

        var arguments = try payload.statementArguments()
        arguments += ["current_user_id": currentUserID.uuidString]

        // Run first, while the row this person wrote is still there to be kept.
        try db.execute(sql: supersedeStatement, arguments: arguments)
        try db.execute(sql: applyStatement, arguments: arguments)
    }
}
