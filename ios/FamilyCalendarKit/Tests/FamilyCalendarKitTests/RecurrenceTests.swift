import Foundation
import Testing

@testable import FamilyCalendarKit

/// The expander, against the same fixtures python-dateutil validated.
///
/// The cases live in `Fixtures/recurrence.json` and are checked in CI against a
/// mature RFC 5545 implementation, so what these assert is the standard's
/// answers rather than this file's opinion of them.
struct RecurrenceTests {
    struct Case: Decodable {
        let name: String
        let rrule: String?
        let startsAt: String?
        let window: [String]
        let exceptions: [String]?
        let expected: [String]

        enum CodingKeys: String, CodingKey {
            case name, rrule, window, exceptions, expected
            case startsAt = "starts_at"
        }
    }

    struct Fixtures: Decodable {
        let cases: [Case]
    }

    static var cases: [Case] {
        guard
            let url = Bundle.module.url(forResource: "recurrence", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixtures = try? JSONDecoder().decode(Fixtures.self, from: data)
        else {
            return []
        }
        return fixtures.cases
    }

    @Test func fixturesAreAvailable() {
        #expect(!Self.cases.isEmpty, "recurrence.json did not load")
    }

    @Test(arguments: RecurrenceTests.cases)
    func expandsTheWayTheStandardSays(testCase: Case) throws {
        let household = UUID()
        let author = UUID()

        var task = CalendarTask(
            householdID: household,
            title: testCase.name,
            startsAt: testCase.startsAt.flatMap(Timestamp.date(from:)),
            rrule: testCase.rrule,
            createdBy: author
        )
        task.recurrenceExceptions = testCase.exceptions ?? []

        let start = try #require(Timestamp.date(from: testCase.window[0]))
        let end = try #require(Timestamp.date(from: testCase.window[1]))

        let produced = Recurrence.occurrences(of: task, in: start..<end)
            .map(Timestamp.string(from:))

        #expect(produced == testCase.expected, "\(testCase.name)")
    }
}

extension RecurrenceTests.Case: CustomTestStringConvertible {
    var testDescription: String { name }
}
