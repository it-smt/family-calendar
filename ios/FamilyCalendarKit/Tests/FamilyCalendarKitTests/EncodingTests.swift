import Foundation
import GRDB
import Testing

@testable import FamilyCalendarKit

/// What a record actually looks like once SQLite has it.
///
/// Identifiers are text and timestamps are RFC 3339, because the server's rows
/// arrive that way and the two databases hold the same bytes. GRDB's defaults
/// are a sixteen-byte blob and "YYYY-MM-DD HH:MM:SS.SSS", and a blob matches no
/// text primary key — so when the strategies that override them stopped being
/// called, every foreign key in the schema failed at COMMIT and the app could
/// not write a single row. Nothing said so: the overrides were static
/// properties where GRDB wants static functions taking a column name, which
/// compiles and is simply never read.
///
/// These are the tests that would have caught it in a second.
struct EncodingTests {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    private func storage(
        _ database: AppDatabase, table: String, column: String
    ) throws -> (kind: String, value: String?) {
        try database.reader.read { db in
            let row = try #require(
                try Row.fetchOne(
                    db, sql: "SELECT typeof(\(column)) AS kind, \(column) AS value FROM \(table)"
                )
            )
            let kind: DatabaseValue = row["kind"]
            let value: DatabaseValue = row["value"]
            return (String.fromDatabaseValue(kind) ?? "nothing", String.fromDatabaseValue(value))
        }
    }

    @Test func identifiersAreWrittenAsUppercaseText() throws {
        let database = try makeDatabase()
        let household = Household(name: "Дом", inviteCode: "ABCD2345")
        try database.writer.write { db in try household.insert(db) }

        let stored = try storage(database, table: "households", column: "id")

        #expect(stored.kind == "text")
        #expect(stored.value == household.id.uuidString)
        #expect(stored.value == stored.value?.uppercased())
    }

    @Test func timestampsAreWrittenInTheWireFormat() throws {
        let database = try makeDatabase()
        let household = Household(name: "Дом", inviteCode: "ABCD2345")
        try database.writer.write { db in try household.insert(db) }

        let stored = try storage(database, table: "households", column: "updated_at")

        #expect(stored.kind == "text")
        #expect(stored.value == Timestamp.string(from: household.updatedAt))
        #expect(stored.value?.contains("T") == true)
        #expect(stored.value?.hasSuffix("Z") == true)
    }

    /// The failure this all came from: a child row whose parent is right there.
    @Test func aRowCanReferAnotherRowWrittenTheSameWay() throws {
        let database = try makeDatabase()
        let household = Household(name: "Дом", inviteCode: "ABCD2345")
        let user = User(householdID: household.id, displayName: "Я")
        let category = TaskCategory(householdID: household.id, name: "Дом")
        let task = CalendarTask(
            householdID: household.id,
            title: "Врач",
            startsAt: Date(),
            createdBy: user.id,
            categoryID: category.id
        )

        try database.writer.write { db in
            try household.insert(db)
            try user.insert(db)
            try category.insert(db)
            try task.insert(db)
        }

        let count = try database.reader.read { db in try CalendarTask.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func aDateWrittenBeforeTheStrategiesWorkedIsStillReadable() {
        // Rows written while the encoding was being ignored are in SQLite's own
        // shape. A device has to be able to read its own old rows.
        let parsed = Timestamp.date(from: "2026-09-18 09:00:00.000")

        #expect(parsed == Timestamp.date(from: "2026-09-18T09:00:00.000Z"))
    }

    @Test func theLaunchCheckAcceptsTheSchemaAsShipped() throws {
        // `AppDatabase.inMemory()` runs it; reaching here means it passed.
        _ = try makeDatabase()
    }
}
