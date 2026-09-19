import Foundation
import GRDB
import Testing

@testable import FamilyCalendarKit

/// Finding a row again by the identifier it was written with.
///
/// The encoding strategies put identifiers into rows as uppercase text. They do
/// nothing for a `UUID` handed to a query expression, a statement argument or
/// `fetchOne(db, key:)` — GRDB converts that one itself, into a sixteen-byte
/// blob, which equals none of the text in the table. The query then matches
/// nothing and says nothing: the list of things to bring was saved correctly,
/// counted correctly on the day card, and came back empty when the task was
/// opened.
///
/// Every lookup by identifier is exercised here, because that is the only way
/// this shows up.
struct LookupTests {
    private struct Fixture {
        let database: AppDatabase
        let householdID: UUID
        let userID: UUID

        var tasks: TaskRepository {
            TaskRepository(database: database, currentUserID: userID)
        }

        var subtasks: SubtaskRepository {
            SubtaskRepository(database: database, householdID: householdID, currentUserID: userID)
        }
    }

    private func makeFixture() throws -> Fixture {
        let database = try AppDatabase.inMemory()
        let householdID = UUID()
        let userID = UUID()
        try LocalIdentity.ensure(in: database, householdID: householdID, userID: userID)
        return Fixture(database: database, householdID: householdID, userID: userID)
    }

    private func makeTask(_ fixture: Fixture) throws -> CalendarTask {
        try fixture.tasks.create(
            CalendarTask(
                householdID: fixture.householdID,
                title: "Бассейн",
                startsAt: Date(),
                createdBy: fixture.userID
            )
        )
    }

    @Test func aTaskIsFoundByItsIdentifier() throws {
        let fixture = try makeFixture()
        let task = try makeTask(fixture)

        let found = try fixture.tasks.task(id: task.id)

        #expect(found?.id == task.id)
        #expect(found?.title == "Бассейн")
    }

    @Test func theThingsToBringComeBackWithTheTask() async throws {
        let fixture = try makeFixture()
        let task = try makeTask(fixture)
        try fixture.subtasks.add(to: task.id, title: "Шапочка")
        try fixture.subtasks.add(to: task.id, title: "Очки")

        var items = fixture.subtasks.observe(taskID: task.id).makeAsyncIterator()
        let first = try await items.next()

        #expect(first?.map(\.title) == ["Шапочка", "Очки"])
    }

    /// The second half of the same fault: the next position was read with a
    /// blob too, so every item was told it was the first one.
    @Test func eachThingKeepsThePositionItWasAddedIn() async throws {
        let fixture = try makeFixture()
        let task = try makeTask(fixture)
        for title in ["Шапочка", "Очки", "Полотенце"] {
            try fixture.subtasks.add(to: task.id, title: title)
        }

        var items = fixture.subtasks.observe(taskID: task.id).makeAsyncIterator()
        let first = try await items.next()

        #expect(first?.map(\.sortOrder) == [0, 1, 2])
    }

    @Test func aListBelongsToItsOwnTaskOnly() async throws {
        let fixture = try makeFixture()
        let mine = try makeTask(fixture)
        let theirs = try makeTask(fixture)
        try fixture.subtasks.add(to: mine.id, title: "Шапочка")

        var items = fixture.subtasks.observe(taskID: theirs.id).makeAsyncIterator()
        let first = try await items.next()

        #expect(first?.isEmpty == true)
    }

    @Test func whatIsPackedIsCountedPerTask() async throws {
        let fixture = try makeFixture()
        let task = try makeTask(fixture)
        try fixture.subtasks.add(to: task.id, title: "Шапочка")
        try fixture.subtasks.add(to: task.id, title: "Очки")

        var counts = fixture.subtasks.observeProgress().makeAsyncIterator()
        let first = try await counts.next()

        #expect(first?[task.id] == SubtaskProgress(done: 0, total: 2))
    }
}
