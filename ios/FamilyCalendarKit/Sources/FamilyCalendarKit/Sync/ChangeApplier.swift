import Foundation
import GRDB

/// Applies a pulled change to the device database.
///
/// The rules live in generated SQL (`Database/SQL/apply/*.sql`), not here,
/// because the device resolves conflicts too: a row arriving from a pull can be
/// older than an edit made offline and not yet pushed, and applying it blindly
/// would throw that edit away. The same statements are what the protocol tests
/// execute, so the rules are tested where they are written.
public struct ChangeApplier: Sendable {
    private let statements: [SyncEntity: String]

    public init(bundle: Bundle = .module) throws {
        var statements: [SyncEntity: String] = [:]
        for entity in SyncEntity.allCases {
            guard
                let url = bundle.url(
                    forResource: entity.rawValue,
                    withExtension: "sql",
                    subdirectory: "SQL/apply"
                )
            else {
                throw AppDatabase.DatabaseError.schemaResourceMissing(
                    "SQL/apply/\(entity.rawValue).sql"
                )
            }
            statements[entity] = try String(contentsOf: url, encoding: .utf8)
        }
        self.statements = statements
    }

    public func apply(_ payload: ChangePayload, to db: Database) throws {
        guard let statement = statements[payload.entityType] else {
            throw AppDatabase.DatabaseError.schemaResourceMissing(payload.entityType.rawValue)
        }
        try db.execute(sql: statement, arguments: payload.statementArguments())
    }
}
